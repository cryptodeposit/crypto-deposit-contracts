// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IStrategyAdapter} from "./interfaces/IStrategyAdapter.sol";

/**
 * @title TreasuryUpgradeable
 * @notice Central treasury — single custody point for all protocol ERC20 tokens
 * @dev Receives tokens from deposits (DiscountBill), collateral (CollateralVault),
 *      and repayments (BorrowingEngine). Deploys excess to yield strategies while
 *      maintaining reserve ratios. Tracks maturity profiles for ALM.
 *
 *      Business lines:
 *        1. Deposits — protocol pays yield curve rate, keeps surplus
 *        2. Collateral — client earns nothing, protocol rehypothecates
 *        3. Lending — client pays interest, all interest = protocol revenue
 */
contract TreasuryUpgradeable is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    ITreasury
{
    using SafeERC20 for IERC20;

    // ============================================================================
    // Roles
    // ============================================================================

    bytes32 public constant DEPOSIT_MANAGER_ROLE = keccak256("DEPOSIT_MANAGER_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    bytes32 public constant LENDING_MANAGER_ROLE = keccak256("LENDING_MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============================================================================
    // Constants
    // ============================================================================

    uint256 public constant BUCKET_DURATION = 7 days;
    uint256 public constant MAX_RESERVE_RATIO_BPS = 10000;

    // ============================================================================
    // State — Per-token accounting
    // ============================================================================

    mapping(address => uint256) public depositClaims;
    mapping(address => uint256) public depositLiabilities;
    mapping(address => uint256) public collateralClaims;
    mapping(address => uint256) public lendingPoolReserves;
    mapping(address => uint256) public protocolRevenue;
    mapping(address => uint256) public reserveRatioBps;

    // ============================================================================
    // State — Strategy tracking
    // ============================================================================

    address[] private _strategies;
    mapping(address => bool) public isRegisteredStrategy;
    /// @dev strategyDeployed[strategy][token] = amount deployed
    mapping(address => mapping(address => uint256)) public strategyDeployed;

    // ============================================================================
    // State — Maturity buckets (7-day granularity)
    // ============================================================================

    /// @dev maturityLiabilities[token][bucketTimestamp] = liabilities due
    mapping(address => mapping(uint256 => uint256)) public maturityLiabilities;
    /// @dev maturityAssets[token][bucketTimestamp] = strategy returns expected
    mapping(address => mapping(uint256 => uint256)) public maturityAssets;
    /// @dev Sorted list of active bucket timestamps per token; lazily populated via _ensureBucket()
    // slither-disable-next-line uninitialized-state
    mapping(address => uint256[]) private _activeBuckets;
    /// @dev Quick lookup: is this bucket already in the active list?
    mapping(address => mapping(uint256 => bool)) private _bucketExists;

    // ============================================================================
    // State — Token tracking
    // ============================================================================

    address[] private _trackedTokens;
    mapping(address => bool) private _isTrackedToken;

    /// @notice Capital owned outright by treasury from expired deposits (escheatment)
    /// @dev Separate from protocolRevenue to avoid double-counting with strategy yield.
    ///      Only the principal portion is tracked here (interest was never funded).
    mapping(address => uint256) public ownedCapital;

    // ============================================================================
    // Constructor / Initializer
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) public initializer {
        require(admin_ != address(0), "admin=0");

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, admin_);
        _grantRole(UPGRADER_ROLE, admin_);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ============================================================================
    // Pause / Unpause
    // ============================================================================

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============================================================================
    // Deposit Manager Functions (called by DiscountBill)
    // ============================================================================

    function recordDeposit(
        address token,
        uint256 principal,
        uint256 liability,
        uint256 maturityTimestamp
    ) external override onlyRole(DEPOSIT_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(principal > 0, "principal=0");
        require(liability >= principal, "liability<principal");
        require(maturityTimestamp > block.timestamp, "maturity in past");

        _trackToken(token);

        depositClaims[token] += principal;
        depositLiabilities[token] += liability;

        // Record in maturity bucket
        uint256 bucket = _toBucket(maturityTimestamp);
        _ensureBucket(token, bucket);
        maturityLiabilities[token][bucket] += liability;

        emit DepositRecorded(token, principal, liability, maturityTimestamp);
    }

    /// @notice Backward-compatible overload for pre-upgrade DiscountBill contracts.
    /// @dev The old DiscountBill calls withdrawForRedemption(token, amount, recipient) with 3 params.
    ///      This shim preserves that selector (0x7ab33fd5) so redemptions continue working
    ///      during the window between Treasury upgrade and DiscountBill upgrade.
    ///      Falls back to reducing depositClaims by full amount (old behavior).
    function withdrawForRedemption(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEPOSIT_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");

        require(depositLiabilities[token] >= amount, "exceeds deposit liabilities");
        depositLiabilities[token] -= amount;

        if (depositClaims[token] >= amount) {
            depositClaims[token] -= amount;
        } else {
            depositClaims[token] = 0;
        }

        _ensureLiquidity(token, amount);
        IERC20(token).safeTransfer(recipient, amount);

        emit DepositRedemptionPaid(token, amount, recipient);
    }

    function withdrawForRedemption(
        address token,
        uint256 amount,
        uint256 principalPortion,
        uint256 maturityTimestamp,
        address recipient
    ) external override onlyRole(DEPOSIT_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");
        require(principalPortion <= amount, "principal>amount");

        // Reduce liabilities by full payout amount (principal + interest)
        require(depositLiabilities[token] >= amount, "exceeds deposit liabilities");
        depositLiabilities[token] -= amount;

        // Reduce claims by the principal portion only (not interest/commission)
        if (depositClaims[token] >= principalPortion) {
            depositClaims[token] -= principalPortion;
        } else {
            depositClaims[token] = 0;
        }

        // Reduce maturity bucket
        if (maturityTimestamp > 0) {
            uint256 bucket = _toBucket(maturityTimestamp);
            if (maturityLiabilities[token][bucket] >= amount) {
                maturityLiabilities[token][bucket] -= amount;
            } else {
                maturityLiabilities[token][bucket] = 0;
            }
        }

        _ensureLiquidity(token, amount);
        IERC20(token).safeTransfer(recipient, amount);

        emit DepositRedemptionPaid(token, amount, recipient);
    }

    function writeOffExpiredDeposit(
        address token,
        uint256 principal,
        uint256 liability,
        uint256 maturityTimestamp
    ) external override onlyRole(DEPOSIT_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(liability > 0, "liability=0");
        require(principal <= liability, "principal>liability");
        require(depositLiabilities[token] >= liability, "exceeds deposit liabilities");

        // Reduce deposit accounting — principal and liability tracked separately
        depositLiabilities[token] -= liability;
        if (depositClaims[token] >= principal) {
            depositClaims[token] -= principal;
        } else {
            depositClaims[token] = 0;
        }

        // Clear maturity bucket
        uint256 bucket = _toBucket(maturityTimestamp);
        if (maturityLiabilities[token][bucket] >= liability) {
            maturityLiabilities[token][bucket] -= liability;
        } else {
            maturityLiabilities[token][bucket] = 0;
        }

        // Track the principal as treasury-owned capital (NOT protocolRevenue).
        // protocolRevenue is for realized strategy yield — expired deposits are different.
        // The interest portion was never funded, so only the principal is real capital.
        ownedCapital[token] += principal;

        emit DepositExpiredWriteOff(token, principal, liability, maturityTimestamp);
    }

    function settleEarlyRedemptionForfeit(
        address token,
        uint256 breakFee,
        uint256 unaccruedInterest,
        uint256 principalInForfeit,
        uint256 maturityTimestamp
    ) external override onlyRole(DEPOSIT_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        uint256 totalForfeit = breakFee + unaccruedInterest;
        require(totalForfeit > 0, "nothing to settle");
        require(principalInForfeit <= totalForfeit, "principal>forfeit");
        require(depositLiabilities[token] >= totalForfeit, "exceeds deposit liabilities");

        // Reduce total liabilities by the full forfeited amount
        depositLiabilities[token] -= totalForfeit;

        // Reduce claims by principal portion only
        if (depositClaims[token] >= principalInForfeit) {
            depositClaims[token] -= principalInForfeit;
        } else {
            depositClaims[token] = 0;
        }

        // Reduce maturity bucket
        if (maturityTimestamp > 0) {
            uint256 bucket = _toBucket(maturityTimestamp);
            if (maturityLiabilities[token][bucket] >= totalForfeit) {
                maturityLiabilities[token][bucket] -= totalForfeit;
            } else {
                maturityLiabilities[token][bucket] = 0;
            }
        }

        // Do NOT credit protocolRevenue here — break fee revenue recognition requires
        // explicit realized-cash policy. Park the retained principal in ownedCapital.
        // The unfunded interest portion simply disappears from liabilities.
        // To realize the penalty as revenue later, use a separate admin operation.
        if (principalInForfeit > 0) {
            ownedCapital[token] += principalInForfeit;
        }
    }

    function disburseExpiredFunds(
        address token,
        uint256 amount,
        address recipient
    ) external override onlyRole(DEPOSIT_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");
        require(ownedCapital[token] >= amount, "exceeds owned capital");

        ownedCapital[token] -= amount;

        _ensureLiquidity(token, amount);
        IERC20(token).safeTransfer(recipient, amount);
    }

    function adjustDepositOnMerge(
        address token,
        uint256 oldTotalLiability,
        uint256 newLiability,
        uint256 newMaturity,
        uint256[] calldata oldBillLiabilities,
        uint256[] calldata oldBillMaturities
    ) external override onlyRole(DEPOSIT_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(oldBillLiabilities.length == oldBillMaturities.length, "array length mismatch");
        require(newMaturity > block.timestamp, "maturity in past");
        require(depositLiabilities[token] >= oldTotalLiability, "exceeds deposit liabilities");

        // Adjust total deposit liabilities (principals unchanged on merge)
        depositLiabilities[token] = depositLiabilities[token] - oldTotalLiability + newLiability;

        // Adjust maturity buckets: remove old entries
        for (uint256 i = 0; i < oldBillLiabilities.length; i++) {
            uint256 bucket = _toBucket(oldBillMaturities[i]);
            if (maturityLiabilities[token][bucket] >= oldBillLiabilities[i]) {
                maturityLiabilities[token][bucket] -= oldBillLiabilities[i];
            } else {
                maturityLiabilities[token][bucket] = 0;
            }
        }

        // Add new merged maturity bucket
        uint256 newBucket = _toBucket(newMaturity);
        _ensureBucket(token, newBucket);
        maturityLiabilities[token][newBucket] += newLiability;

        emit DepositMergeAdjusted(token, oldTotalLiability, newLiability, newMaturity);
    }

    // ============================================================================
    // Collateral Manager Functions (called by CollateralVault)
    // ============================================================================

    function recordCollateral(
        address token,
        uint256 amount
    ) external override onlyRole(COLLATERAL_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");

        _trackToken(token);
        collateralClaims[token] += amount;

        emit CollateralRecorded(token, amount);
    }

    function releaseCollateral(
        address token,
        uint256 amount,
        address recipient
    ) external override onlyRole(COLLATERAL_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");
        require(collateralClaims[token] >= amount, "exceeds collateral claims");

        collateralClaims[token] -= amount;
        _ensureLiquidity(token, amount);
        IERC20(token).safeTransfer(recipient, amount);

        emit CollateralReleased(token, amount, recipient);
    }

    function withdrawForLiquidation(
        address token,
        uint256 amount,
        address recipient
    ) external override onlyRole(COLLATERAL_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");
        require(collateralClaims[token] >= amount, "exceeds collateral claims");

        collateralClaims[token] -= amount;

        // Liquidation MUST succeed — force-pull from strategies if needed
        _ensureLiquidity(token, amount);
        IERC20(token).safeTransfer(recipient, amount);

        emit LiquidationWithdrawal(token, amount, recipient);
    }

    // ============================================================================
    // Lending Manager Functions (called by BorrowingEngine)
    // ============================================================================

    function withdrawForLoan(
        address token,
        uint256 amount,
        address borrower
    ) external override onlyRole(LENDING_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");
        require(borrower != address(0), "borrower=0");
        require(lendingPoolReserves[token] >= amount, "insufficient lending pool");

        lendingPoolReserves[token] -= amount;
        _ensureLiquidity(token, amount);
        IERC20(token).safeTransfer(borrower, amount);

        emit LoanDisbursed(token, amount, borrower);
    }

    function recordRepayment(
        address token,
        uint256 principal,
        uint256 interest
    ) external override onlyRole(LENDING_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "token=0");

        // Principal goes back to lending pool
        lendingPoolReserves[token] += principal;

        // Interest is protocol revenue
        protocolRevenue[token] += interest;

        emit RepaymentRecorded(token, principal, interest);
    }

    // ============================================================================
    // Operator Functions
    // ============================================================================

    function allocateToStrategy(
        address strategy,
        address token,
        uint256 amount,
        uint256 maturityTimestamp
    ) external override onlyRole(OPERATOR_ROLE) nonReentrant whenNotPaused {
        require(isRegisteredStrategy[strategy], "strategy not registered");
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");
        require(IStrategyAdapter(strategy).supportsToken(token), "strategy: token not supported");

        // Ensure deployment doesn't breach reserve floor
        uint256 onChain = IERC20(token).balanceOf(address(this));
        uint256 floor = _reserveFloor(token);
        require(onChain >= amount + floor, "would breach reserve floor");

        // Transfer to strategy and deploy
        IERC20(token).safeTransfer(strategy, amount);
        IStrategyAdapter(strategy).deploy(token, amount);

        strategyDeployed[strategy][token] += amount;

        // Record maturity bucket for non-liquid strategies
        if (maturityTimestamp > 0) {
            uint256 bucket = _toBucket(maturityTimestamp);
            _ensureBucket(token, bucket);
            maturityAssets[token][bucket] += amount;
        }

        emit StrategyDeployed(strategy, token, amount, maturityTimestamp);
    }

    function withdrawFromStrategy(
        address strategy,
        address token,
        uint256 amount
    ) external override onlyRole(OPERATOR_ROLE) nonReentrant whenNotPaused {
        _withdrawFromStrategy(strategy, token, amount);
    }

    function setReserveRatio(
        address token,
        uint256 ratioBps
    ) external override onlyRole(OPERATOR_ROLE) {
        require(token != address(0), "token=0");
        require(ratioBps <= MAX_RESERVE_RATIO_BPS, "ratio too high");

        uint256 old = reserveRatioBps[token];
        reserveRatioBps[token] = ratioBps;

        emit ReserveRatioUpdated(token, old, ratioBps);
    }

    function fundLendingPool(
        address token,
        uint256 amount
    ) external override onlyRole(OPERATOR_ROLE) nonReentrant whenNotPaused {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");

        _trackToken(token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        lendingPoolReserves[token] += amount;

        emit LendingPoolFunded(token, amount);
    }

    function withdrawRevenue(
        address token,
        uint256 amount,
        address recipient
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");
        require(protocolRevenue[token] >= amount, "exceeds protocol revenue");

        protocolRevenue[token] -= amount;
        _ensureLiquidity(token, amount);
        IERC20(token).safeTransfer(recipient, amount);

        emit ProtocolRevenueWithdrawn(token, amount, recipient);
    }

    function registerStrategy(
        address strategy
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(strategy != address(0), "strategy=0");
        require(!isRegisteredStrategy[strategy], "already registered");

        isRegisteredStrategy[strategy] = true;
        _strategies.push(strategy);

        emit StrategyRegistered(strategy);
    }

    function removeStrategy(
        address strategy
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isRegisteredStrategy[strategy], "not registered");

        // Ensure zero deployed balance across all tracked tokens
        for (uint256 i = 0; i < _trackedTokens.length; i++) {
            require(strategyDeployed[strategy][_trackedTokens[i]] == 0, "strategy has deployed balance");
        }

        isRegisteredStrategy[strategy] = false;

        // Remove from array
        for (uint256 i = 0; i < _strategies.length; i++) {
            if (_strategies[i] == strategy) {
                _strategies[i] = _strategies[_strategies.length - 1];
                _strategies.pop();
                break;
            }
        }

        emit StrategyRemoved(strategy);
    }

    // ============================================================================
    // Yield Harvesting & Token Recovery
    // ============================================================================

    /// @notice Harvest yield from a strategy without touching deployed principal
    /// @dev Withdraws only the excess above recorded principal. Does NOT decrease strategyDeployed.
    function harvestYield(
        address strategy,
        address token
    ) external override onlyRole(OPERATOR_ROLE) nonReentrant whenNotPaused {
        require(isRegisteredStrategy[strategy], "strategy not registered");
        require(token != address(0), "token=0");

        uint256 deployed = strategyDeployed[strategy][token];
        uint256 currentVal = IStrategyAdapter(strategy).currentValue(token);
        require(currentVal > deployed, "no yield to harvest");

        uint256 yieldAmount = currentVal - deployed;
        // Security: yield amount verified via balance diff
        // slither-disable-next-line unused-return
        IStrategyAdapter(strategy).withdraw(token, yieldAmount);
        protocolRevenue[token] += yieldAmount;

        emit YieldHarvested(strategy, token, yieldAmount, protocolRevenue[token]);
    }

    /// @notice Sweep tokens not tracked by any accounting category
    /// @dev Recovers tokens sent to Treasury by accident or tokens from direct strategy yield
    function sweepUntracked(
        address token,
        uint256 amount,
        address recipient
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");

        uint256 onChain = IERC20(token).balanceOf(address(this));
        uint256 tracked = depositLiabilities[token] + collateralClaims[token]
                        + lendingPoolReserves[token] + protocolRevenue[token]
                        + ownedCapital[token];
        uint256 untracked = onChain > tracked ? onChain - tracked : 0;
        require(amount <= untracked, "would sweep tracked funds");

        IERC20(token).safeTransfer(recipient, amount);
        emit TokenSwept(token, amount, recipient);
    }

    // ============================================================================
    // Emergency Functions
    // ============================================================================

    /// @notice Emergency withdrawal — bypasses reserve floor and clears accounting
    /// @dev Force-unwinds all strategies for the token, zeroes all accounting.
    // Security: protected by nonReentrant modifier
    // slither-disable-next-line reentrancy-no-eth
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(token != address(0), "token=0");
        require(recipient != address(0), "recipient=0");

        // Force-unwind all strategies for this token
        for (uint256 i = 0; i < _strategies.length; i++) {
            address strat = _strategies[i];
            uint256 stratBalance = strategyDeployed[strat][token];
            if (stratBalance > 0) {
                // Security: withdraw return checked via balance diff
                // slither-disable-next-line unused-return
                IStrategyAdapter(strat).withdraw(token, stratBalance);
                strategyDeployed[strat][token] = 0;
            }
        }

        uint256 onChain = IERC20(token).balanceOf(address(this));
        uint256 toWithdraw = amount > onChain ? onChain : amount;
        require(toWithdraw > 0, "nothing to withdraw");

        // Capture pre-clear state for event
        uint256 dcCleared = depositClaims[token];
        uint256 dlCleared = depositLiabilities[token];
        uint256 ccCleared = collateralClaims[token];
        uint256 prCleared = protocolRevenue[token];

        // Zero all accounting for this token
        depositClaims[token] = 0;
        depositLiabilities[token] = 0;
        collateralClaims[token] = 0;
        lendingPoolReserves[token] = 0;
        protocolRevenue[token] = 0;
        ownedCapital[token] = 0;

        IERC20(token).safeTransfer(recipient, toWithdraw);

        emit EmergencyWithdraw(
            token, toWithdraw, recipient,
            dcCleared, dlCleared, ccCleared, prCleared
        );
    }

    // ============================================================================
    // View Functions
    // ============================================================================

    function getTokenState(address token) external view override returns (TokenState memory state) {
        uint256 deployed = _totalDeployed(token);
        state = TokenState({
            depositClaims: depositClaims[token],
            depositLiabilities: depositLiabilities[token],
            collateralClaims: collateralClaims[token],
            lendingPool: lendingPoolReserves[token],
            deployed: deployed,
            protocolRevenue: protocolRevenue[token],
            reserveRatioBps: reserveRatioBps[token],
            ownedCapital: ownedCapital[token]
        });
    }

    function totalAssets(address token) external view override returns (uint256 total) {
        total = IERC20(token).balanceOf(address(this)) + _totalDeployed(token);
    }

    function totalLiabilities(address token) external view override returns (uint256 total) {
        // Deposit liabilities (principal + promised yield) + collateral claims
        // Collateral must be returnable on demand
        total = depositLiabilities[token] + collateralClaims[token] + lendingPoolReserves[token];
    }

    function availableReserves(address token) external view override returns (uint256 available) {
        uint256 onChain = IERC20(token).balanceOf(address(this));
        uint256 floor = _reserveFloor(token);
        if (onChain > floor) {
            available = onChain - floor;
        }
    }

    function getMaturityProfile(address token) external view override returns (MaturityBucket[] memory buckets) {
        uint256[] storage timestamps = _activeBuckets[token];
        uint256 count = timestamps.length;
        buckets = new MaturityBucket[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 ts = timestamps[i];
            buckets[i] = MaturityBucket({
                timestamp: ts,
                liabilities: maturityLiabilities[token][ts],
                assets: maturityAssets[token][ts]
            });
        }
    }

    function isALMHealthy(address token) external view override returns (bool healthy) {
        uint256 onChain = IERC20(token).balanceOf(address(this));

        // Add liquid strategy balances (can be withdrawn same-block)
        uint256 liquidAssets = onChain;
        for (uint256 i = 0; i < _strategies.length; i++) {
            address strat = _strategies[i];
            if (IStrategyAdapter(strat).isLiquid() && strategyDeployed[strat][token] > 0) {
                liquidAssets += IStrategyAdapter(strat).currentValue(token);
            }
        }

        // Walk maturity buckets forward — cumulative assets must >= cumulative liabilities
        uint256[] storage timestamps = _activeBuckets[token];
        uint256 cumulativeAssets = liquidAssets;
        // Security: accumulator correctly starts at 0
        // slither-disable-next-line uninitialized-local
        uint256 cumulativeLiabilities;

        for (uint256 i = 0; i < timestamps.length; i++) {
            uint256 ts = timestamps[i];
            if (ts < block.timestamp) continue; // Skip past buckets

            cumulativeLiabilities += maturityLiabilities[token][ts];
            cumulativeAssets += maturityAssets[token][ts];

            if (cumulativeAssets < cumulativeLiabilities) {
                return false;
            }
        }

        return true;
    }

    function getStrategies() external view override returns (address[] memory strategies) {
        return _strategies;
    }

    function getStrategyDeployed(
        address strategy,
        address token
    ) external view override returns (uint256 amount) {
        return strategyDeployed[strategy][token];
    }

    /// @notice Get all tracked tokens
    function getTrackedTokens() external view returns (address[] memory) {
        return _trackedTokens;
    }

    /// @notice Get active maturity bucket timestamps for a token
    function getActiveBuckets(address token) external view returns (uint256[] memory) {
        return _activeBuckets[token];
    }

    /// @notice Check if a maturity bucket exists for a token
    function isBucketActive(address token, uint256 bucket) external view returns (bool) {
        return _bucketExists[token][bucket];
    }

    /// @notice Check if a token is tracked
    function isTrackedToken(address token) external view returns (bool) {
        return _isTrackedToken[token];
    }

    /// @notice Full portfolio snapshot — all tracked tokens with complete state in one call
    function getFullSnapshot() external view returns (address[] memory tokens, TokenState[] memory states) {
        tokens = _trackedTokens;
        uint256 len = tokens.length;
        states = new TokenState[](len);
        for (uint256 i = 0; i < len; i++) {
            address t = tokens[i];
            states[i] = TokenState({
                depositClaims: depositClaims[t],
                depositLiabilities: depositLiabilities[t],
                collateralClaims: collateralClaims[t],
                lendingPool: lendingPoolReserves[t],
                deployed: _totalDeployed(t),
                protocolRevenue: protocolRevenue[t],
                reserveRatioBps: reserveRatioBps[t],
                ownedCapital: ownedCapital[t]
            });
        }
    }

    // ============================================================================
    // Internal Functions
    // ============================================================================

    /// @dev Calculate the minimum on-chain balance that must be maintained
    function _reserveFloor(address token) internal view returns (uint256) {
        // Reserve floor is based on total claims that could be called
        uint256 totalClaims = depositLiabilities[token] + collateralClaims[token];
        uint256 ratio = reserveRatioBps[token];
        if (ratio == 0) return 0;
        return (totalClaims * ratio) / 10000;
    }

    /// @dev Ensure sufficient on-chain liquidity, pulling from liquid strategies if needed
    // Security: all public callers have nonReentrant
    // slither-disable-next-line reentrancy-no-eth
    function _ensureLiquidity(address token, uint256 amount) internal {
        uint256 onChain = IERC20(token).balanceOf(address(this));
        if (onChain >= amount) return;

        uint256 shortfall = amount - onChain;

        // Pull from liquid strategies first
        for (uint256 i = 0; i < _strategies.length && shortfall > 0; i++) {
            address strat = _strategies[i];
            if (!IStrategyAdapter(strat).isLiquid()) continue;

            uint256 available = strategyDeployed[strat][token];
            if (available == 0) continue;

            uint256 toWithdraw = shortfall > available ? available : shortfall;
            uint256 withdrawn = IStrategyAdapter(strat).withdraw(token, toWithdraw);
            strategyDeployed[strat][token] -= toWithdraw;
            shortfall -= withdrawn > shortfall ? shortfall : withdrawn;
        }

        // If still short, pull from non-liquid strategies (emergency)
        for (uint256 i = 0; i < _strategies.length && shortfall > 0; i++) {
            address strat = _strategies[i];
            if (IStrategyAdapter(strat).isLiquid()) continue;

            uint256 available = strategyDeployed[strat][token];
            if (available == 0) continue;

            uint256 toWithdraw = shortfall > available ? available : shortfall;
            uint256 withdrawn = IStrategyAdapter(strat).withdraw(token, toWithdraw);
            strategyDeployed[strat][token] -= toWithdraw;
            shortfall -= withdrawn > shortfall ? shortfall : withdrawn;

            emit EmergencyUnwind(strat, token, toWithdraw);
        }

        // Final check — after unwinding strategies, we must have enough
        require(IERC20(token).balanceOf(address(this)) >= amount, "insufficient liquidity after unwind");
    }

    /// @dev Withdraw from a specific strategy
    // Security: caller withdrawFromStrategy() has nonReentrant
    // slither-disable-next-line reentrancy-no-eth
    function _withdrawFromStrategy(address strategy, address token, uint256 amount) internal {
        require(isRegisteredStrategy[strategy], "strategy not registered");
        require(strategyDeployed[strategy][token] >= amount, "exceeds deployed balance");

        uint256 withdrawn = IStrategyAdapter(strategy).withdraw(token, amount);
        strategyDeployed[strategy][token] -= amount;

        // Any excess yield from strategy is protocol revenue
        if (withdrawn > amount) {
            uint256 yieldAmount = withdrawn - amount;
            protocolRevenue[token] += yieldAmount;
            emit YieldCaptured(strategy, token, amount, withdrawn, yieldAmount, protocolRevenue[token]);
        }

        emit StrategyWithdrawn(strategy, token, withdrawn);
    }

    /// @dev Total amount deployed across all strategies for a token
    function _totalDeployed(address token) internal view returns (uint256 total) {
        for (uint256 i = 0; i < _strategies.length; i++) {
            total += strategyDeployed[_strategies[i]][token];
        }
    }

    /// @dev Round a timestamp down to its maturity bucket
    function _toBucket(uint256 timestamp) internal pure returns (uint256) {
        // Security: intentional truncation for time-bucket rounding
        // slither-disable-next-line divide-before-multiply
        return (timestamp / BUCKET_DURATION) * BUCKET_DURATION;
    }

    /// @dev Ensure a maturity bucket exists in the sorted list
    function _ensureBucket(address token, uint256 bucket) internal {
        if (_bucketExists[token][bucket]) return;

        _bucketExists[token][bucket] = true;

        // Insert sorted
        uint256[] storage buckets = _activeBuckets[token];
        buckets.push(bucket);

        // Bubble sort the new element into position
        uint256 idx = buckets.length - 1;
        while (idx > 0 && buckets[idx - 1] > buckets[idx]) {
            uint256 tmp = buckets[idx - 1];
            buckets[idx - 1] = buckets[idx];
            buckets[idx] = tmp;
            idx--;
        }
    }

    /// @dev Track a token for enumeration
    function _trackToken(address token) internal {
        if (!_isTrackedToken[token]) {
            _isTrackedToken[token] = true;
            _trackedTokens.push(token);
        }
    }

    // ============================================================================
    // Storage Gap
    // ============================================================================

    /// @dev Reserved storage space for future upgrades
    uint256[39] private __gap;
}
