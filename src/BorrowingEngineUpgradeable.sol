// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IBorrowingEngine.sol";
import "./interfaces/ICollateralVault.sol";
import "./interfaces/IComplianceRegistry.sol";
import "./interfaces/ITravelRuleRegistry.sol";
import "./interfaces/IHaircutRegistry.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/ITreasury.sol";

/**
 * @title BorrowingEngineUpgradeable
 * @notice Manages loan positions with operator-set fixed interest rates
 * @dev Prime brokerage borrowing:
 *      1. Client has collateral in CollateralVault
 *      2. Client borrows tokens - must maintain health factor >= MIN_HEALTH_FACTOR
 *      3. Interest accrues per-second at operator-set fixed rate
 *      4. Repayment reduces loan principal + interest
 *      5. LiquidationManager can force-repay if health factor breaches threshold
 *
 *      Health factor = effectiveCollateralValue / totalBorrowValue
 *      Expressed in basis points: 10000 = 1.0x, 12500 = 1.25x
 *
 *      Interest rate model: operator-set fixed rates per token (not utilization-based).
 *      Rates stored as ray (1e27) per second for precision.
 */
contract BorrowingEngineUpgradeable is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IBorrowingEngine
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Minimum health factor to borrow (1.25x = 12500 bps)
    uint256 public constant MIN_HEALTH_FACTOR_BPS = 12500;

    /// @notice Ray unit for interest rate precision (1e27)
    uint256 public constant RAY = 1e27;

    /// @notice Seconds per year for rate conversion
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    ICollateralVault public collateralVault;
    IComplianceRegistry public compliance;
    ITravelRuleRegistry public travelRule;
    IPriceOracle public priceOracle;
    ITreasury public treasury;

    // ============================================================================
    // Loan State
    // ============================================================================

    mapping(uint256 => Loan) public loans;
    mapping(address => uint256[]) private _userLoans;
    uint256 public nextLoanId;

    // ============================================================================
    // Pool State (per token)
    // ============================================================================

    /// @notice Total borrowed amount per token
    mapping(address => uint256) public totalBorrowed;

    /// @notice Available liquidity per token (supplied by treasury)
    mapping(address => uint256) public totalLiquidity;

    /// @notice Operator-set borrow rate per token (ray per second)
    mapping(address => uint256) public borrowRates;

    /// @notice Reserve factor per token (bps of interest going to protocol)
    mapping(address => uint256) public reserveFactors;

    /// @notice Accumulated protocol reserves per token
    mapping(address => uint256) public protocolReserves;

    /// @notice Supported borrow tokens
    mapping(address => bool) public supportedTokens;

    // ============================================================================
    // Events (beyond IBorrowingEngine)
    // ============================================================================

    event TokenSupported(address indexed token, uint256 ratePerSecond);
    event ReserveFactorUpdated(address indexed token, uint256 oldFactor, uint256 newFactor);
    event LoanLiquidated(uint256 indexed loanId, address indexed borrower, uint256 repaidAmount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ComplianceRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address admin,
        address _collateralVault,
        address _compliance,
        address _travelRule,
        address _priceOracle
    ) public initializer {
        require(admin != address(0), "admin=0");
        require(_collateralVault != address(0), "vault=0");
        require(_compliance != address(0), "compliance=0");
        require(_priceOracle != address(0), "oracle=0");
        __AccessControl_init();


        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        collateralVault = ICollateralVault(_collateralVault);
        compliance = IComplianceRegistry(_compliance);
        if (_travelRule != address(0)) {
            travelRule = ITravelRuleRegistry(_travelRule);
        }
        priceOracle = IPriceOracle(_priceOracle);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(treasury_ != address(0), "treasury=0");
        address old = address(treasury);
        treasury = ITreasury(treasury_);
        emit TreasuryUpdated(old, treasury_);
    }

    function setComplianceRegistry(address compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(compliance_ != address(0), "compliance=0");
        address old = address(compliance);
        compliance = IComplianceRegistry(compliance_);
        emit ComplianceRegistryUpdated(old, compliance_);
    }

    // ============================================================================
    // Admin / Operator
    // ============================================================================

    /**
     * @notice Add a supported borrow token with initial rate
     * @param token ERC20 token address
     * @param annualRateBps Annual interest rate in basis points (e.g., 500 = 5%)
     */
    function addSupportedToken(address token, uint256 annualRateBps) external onlyRole(OPERATOR_ROLE) {
        require(token != address(0), "token=0");
        require(annualRateBps > 0 && annualRateBps <= 10000, "rate out of range");
        supportedTokens[token] = true;
        borrowRates[token] = _annualBpsToRayPerSecond(annualRateBps);
        emit TokenSupported(token, borrowRates[token]);
    }

    /**
     * @notice Update borrow rate for a token (annual bps, converted to ray/sec internally)
     * @param token ERC20 token address
     * @param annualRateBps Annual rate in basis points (e.g., 500 = 5%)
     */
    function updateBorrowRate(address token, uint256 annualRateBps) external onlyRole(OPERATOR_ROLE) {
        require(supportedTokens[token], "token not supported");
        require(annualRateBps > 0 && annualRateBps <= 10000, "rate out of range");
        uint256 oldRate = borrowRates[token];
        borrowRates[token] = _annualBpsToRayPerSecond(annualRateBps);
        emit RateUpdated(token, oldRate, borrowRates[token]);
    }

    function setReserveFactor(address token, uint256 factorBps) external onlyRole(OPERATOR_ROLE) {
        require(factorBps <= 5000, "reserve factor too high"); // Max 50%
        uint256 old = reserveFactors[token];
        reserveFactors[token] = factorBps;
        emit ReserveFactorUpdated(token, old, factorBps);
    }

    /**
     * @notice Treasury adds liquidity for lending
     */
    function addLiquidity(address token, uint256 amount) external onlyRole(OPERATOR_ROLE) nonReentrant {
        require(supportedTokens[token], "token not supported");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        totalLiquidity[token] += amount;
        emit LiquidityAdded(token, amount);
    }

    /**
     * @notice Treasury removes excess liquidity
     */
    function removeLiquidity(address token, uint256 amount) external onlyRole(OPERATOR_ROLE) nonReentrant {
        uint256 available = totalLiquidity[token] - totalBorrowed[token];
        require(amount <= available, "insufficient available liquidity");
        totalLiquidity[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit LiquidityRemoved(token, amount);
    }

    // ============================================================================
    // Borrow / Repay
    // ============================================================================

    /// @inheritdoc IBorrowingEngine
    function borrow(address token, uint256 amount) external override nonReentrant returns (uint256 loanId) {
        require(supportedTokens[token], "token not supported");
        require(amount > 0, "amount=0");
        require(compliance.isAllowed(msg.sender), "compliance: blocked");

        uint256 available = totalLiquidity[token] - totalBorrowed[token];
        require(amount <= available, "insufficient liquidity");

        // Accrue interest on all existing loans first
        _accrueAllLoans(msg.sender);

        // Create new loan
        loanId = nextLoanId++;
        loans[loanId] = Loan({
            borrower: msg.sender,
            token: token,
            principal: amount,
            accruedInterest: 0,
            lastAccrualTime: block.timestamp,
            ratePerSecond: borrowRates[token],
            active: true
        });
        _userLoans[msg.sender].push(loanId);

        // Update pool state
        totalBorrowed[token] += amount;

        // Check health factor AFTER the new borrow
        uint256 healthFactor = _getHealthFactor(msg.sender);
        require(healthFactor >= MIN_HEALTH_FACTOR_BPS, "insufficient collateral");

        // Travel rule check if configured
        if (address(travelRule) != address(0)) {
            require(
                travelRule.isCompliant(token, address(this), msg.sender, amount),
                "travel rule: not compliant"
            );
            travelRule.consume(token, address(this), msg.sender, amount);
        }

        // Transfer tokens to borrower
        if (address(treasury) != address(0)) {
            treasury.withdrawForLoan(token, amount, msg.sender);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit LoanCreated(loanId, msg.sender, token, amount, borrowRates[token]);
    }

    /// @inheritdoc IBorrowingEngine
    // Security: protected by nonReentrant modifier
    // slither-disable-next-line reentrancy-no-eth
    function repay(uint256 loanId, uint256 amount) external override nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.active, "loan not active");
        require(amount > 0, "amount=0");

        // Accrue interest first
        _accrueInterest(loanId);

        uint256 totalOwed = loan.principal + loan.accruedInterest;
        uint256 repayAmount = amount > totalOwed ? totalOwed : amount;

        // Travel rule on repayment
        if (address(travelRule) != address(0)) {
            require(
                travelRule.isCompliant(loan.token, msg.sender, address(this), repayAmount),
                "travel rule: not compliant"
            );
            travelRule.consume(loan.token, msg.sender, address(this), repayAmount);
        }

        // Apply repayment: interest first, then principal
        uint256 interestRepaid = 0;
        uint256 principalRepaid = 0;

        if (repayAmount >= loan.accruedInterest) {
            interestRepaid = loan.accruedInterest;
            principalRepaid = repayAmount - interestRepaid;
            loan.accruedInterest = 0;
            loan.principal -= principalRepaid;
        } else {
            interestRepaid = repayAmount;
            loan.accruedInterest -= repayAmount;
        }

        // Transfer repayment from borrower
        if (address(treasury) != address(0)) {
            IERC20(loan.token).safeTransferFrom(msg.sender, address(treasury), repayAmount);
            treasury.recordRepayment(loan.token, principalRepaid, interestRepaid);
        } else {
            IERC20(loan.token).safeTransferFrom(msg.sender, address(this), repayAmount);
            // Protocol reserve from interest (legacy path only)
            uint256 reserveShare = (interestRepaid * reserveFactors[loan.token]) / 10000;
            protocolReserves[loan.token] += reserveShare;
        }

        // Update pool state
        totalBorrowed[loan.token] -= principalRepaid;

        // Close loan if fully repaid
        if (loan.principal == 0 && loan.accruedInterest == 0) {
            loan.active = false;
        }

        emit LoanRepaid(loanId, msg.sender, principalRepaid, interestRepaid);
    }

    /**
     * @notice Force repayment during liquidation
     * @dev Called by LiquidationManager only
     */
    // Security: protected by nonReentrant modifier
    // slither-disable-next-line reentrancy-no-eth
    function liquidateRepay(uint256 loanId, uint256 amount, address payer) external onlyRole(LIQUIDATOR_ROLE) nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.active, "loan not active");

        _accrueInterest(loanId);

        uint256 totalOwed = loan.principal + loan.accruedInterest;
        uint256 repayAmount = amount > totalOwed ? totalOwed : amount;

        uint256 interestRepaid = 0;
        uint256 principalRepaid = 0;

        if (repayAmount >= loan.accruedInterest) {
            interestRepaid = loan.accruedInterest;
            principalRepaid = repayAmount - interestRepaid;
            loan.accruedInterest = 0;
            loan.principal -= principalRepaid;
        } else {
            interestRepaid = repayAmount;
            loan.accruedInterest -= repayAmount;
        }

        if (address(treasury) != address(0)) {
            // Security: payer is controlled by LIQUIDATOR_ROLE caller, not arbitrary user input
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(loan.token).safeTransferFrom(payer, address(treasury), repayAmount);
            treasury.recordRepayment(loan.token, principalRepaid, interestRepaid);
        } else {
            // Security: payer is controlled by LIQUIDATOR_ROLE caller, not arbitrary user input
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(loan.token).safeTransferFrom(payer, address(this), repayAmount);
        }

        totalBorrowed[loan.token] -= principalRepaid;

        if (loan.principal == 0 && loan.accruedInterest == 0) {
            loan.active = false;
        }

        emit LoanLiquidated(loanId, loan.borrower, repayAmount);
    }

    // ============================================================================
    // Interest Accrual
    // ============================================================================

    /// @inheritdoc IBorrowingEngine
    function accrueInterest(uint256 loanId) external override {
        _accrueInterest(loanId);
    }

    function _accrueInterest(uint256 loanId) internal {
        Loan storage loan = loans[loanId];
        if (!loan.active) return;

        uint256 elapsed = block.timestamp - loan.lastAccrualTime;
        // Security: elapsed == 0 is a valid early-return guard
        // slither-disable-next-line incorrect-equality
        if (elapsed == 0) return;

        // Simple interest: principal * ratePerSecond * elapsed / RAY
        uint256 interest = (loan.principal * loan.ratePerSecond * elapsed) / RAY;
        loan.accruedInterest += interest;
        loan.lastAccrualTime = block.timestamp;

        emit InterestAccrued(loanId, interest, loan.accruedInterest);
    }

    function _accrueAllLoans(address borrower) internal {
        uint256[] memory loanIds = _userLoans[borrower];
        for (uint256 i = 0; i < loanIds.length; i++) {
            if (loans[loanIds[i]].active) {
                _accrueInterest(loanIds[i]);
            }
        }
    }

    // ============================================================================
    // View Functions
    // ============================================================================

    /// @inheritdoc IBorrowingEngine
    function getHealthFactor(address client) external view override returns (uint256 healthFactorBps) {
        return _getHealthFactor(client);
    }

    /// @inheritdoc IBorrowingEngine
    function getTotalBorrowValue(address client) external view override returns (uint256 totalValueUsd) {
        return _getTotalBorrowValue(client);
    }

    /// @inheritdoc IBorrowingEngine
    function getLoan(uint256 loanId) external view override returns (Loan memory) {
        return loans[loanId];
    }

    /// @inheritdoc IBorrowingEngine
    function getUserLoans(address client) external view override returns (uint256[] memory loanIds) {
        return _userLoans[client];
    }

    /// @inheritdoc IBorrowingEngine
    function getAvailableLiquidity(address token) external view override returns (uint256) {
        return totalLiquidity[token] - totalBorrowed[token];
    }

    /// @inheritdoc IBorrowingEngine
    function getTotalBorrowed(address token) external view override returns (uint256) {
        return totalBorrowed[token];
    }

    /// @inheritdoc IBorrowingEngine
    function getBorrowRate(address token) external view override returns (uint256 ratePerSecond) {
        return borrowRates[token];
    }

    /**
     * @notice Get annual borrow rate in basis points for display
     */
    function getBorrowRateAnnualBps(address token) external view returns (uint256) {
        return _rayPerSecondToAnnualBps(borrowRates[token]);
    }

    /**
     * @notice Get current loan balance including accrued interest
     */
    function getLoanBalance(uint256 loanId) external view returns (uint256 principal, uint256 interest, uint256 total) {
        Loan memory loan = loans[loanId];
        if (!loan.active) return (0, 0, 0);

        uint256 elapsed = block.timestamp - loan.lastAccrualTime;
        uint256 pendingInterest = (loan.principal * loan.ratePerSecond * elapsed) / RAY;

        principal = loan.principal;
        interest = loan.accruedInterest + pendingInterest;
        total = principal + interest;
    }

    // ============================================================================
    // Internal: Health Factor
    // ============================================================================

    function _getHealthFactor(address client) internal view returns (uint256) {
        uint256 totalBorrow = _getTotalBorrowValue(client);
        if (totalBorrow == 0) return type(uint256).max; // No borrows = infinite health

        uint256 effectiveCollateral = collateralVault.getEffectiveCollateralValue(client);
        // Health factor in bps: (collateral / borrow) * 10000
        return (effectiveCollateral * 10000) / totalBorrow;
    }

    function _getTotalBorrowValue(address client) internal view returns (uint256 total) {
        uint256[] memory loanIds = _userLoans[client];
        for (uint256 i = 0; i < loanIds.length; i++) {
            Loan memory loan = loans[loanIds[i]];
            if (!loan.active) continue;

            // Calculate pending interest
            uint256 elapsed = block.timestamp - loan.lastAccrualTime;
            uint256 pendingInterest = (loan.principal * loan.ratePerSecond * elapsed) / RAY;
            uint256 loanTotal = loan.principal + loan.accruedInterest + pendingInterest;

            // Convert to USD using price oracle
            // Security: timestamp return intentionally unused
            // slither-disable-next-line unused-return
            (uint256 price, ) = priceOracle.getPrice(loan.token);
            total += (loanTotal * price) / 1e8;
        }
    }

    // ============================================================================
    // Internal: Rate Conversion
    // ============================================================================

    /**
     * @dev Convert annual rate in bps to ray-per-second
     *      e.g., 500 bps (5%) → 5e25 / 31536000 ≈ 1585489599 ray/sec
     */
    function _annualBpsToRayPerSecond(uint256 annualBps) internal pure returns (uint256) {
        return (annualBps * RAY) / (10000 * SECONDS_PER_YEAR);
    }

    /**
     * @dev Convert ray-per-second back to annual bps for display
     */
    function _rayPerSecondToAnnualBps(uint256 ratePerSecond) internal pure returns (uint256) {
        return (ratePerSecond * 10000 * SECONDS_PER_YEAR) / RAY;
    }

    /// @dev Reserved storage space for future upgrades
    uint256[40] private __gap;
}
