// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IYieldManager} from "./interfaces/IYieldManager.sol";

/**
 * @title IAaveV3Pool
 * @notice Minimal interface for Aave V3 Pool
 */
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256 configuration,
        uint128 liquidityIndex,
        uint128 currentLiquidityRate,
        uint128 variableBorrowIndex,
        uint128 currentVariableBorrowRate,
        uint128 currentStableBorrowRate,
        uint40 lastUpdateTimestamp,
        uint16 id,
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress,
        address interestRateStrategyAddress,
        uint128 accruedToTreasury,
        uint128 unbacked,
        uint128 isolationModeTotalDebt
    );
}

/**
 * @title AaveV3YieldManager
 * @notice Yield manager that deploys funds to Aave V3 lending pools
 * @dev Deposits stablecoins into Aave V3 to earn variable supply APY.
 *      aTokens are held by this contract and redeemed when positions mature.
 *
 * Key features:
 * - Automatic yield generation via Aave V3
 * - Variable APY based on market conditions
 * - Liquid positions (can withdraw before maturity if needed)
 * - Real-time yield accrual through aToken rebasing
 */
contract AaveV3YieldManager is IYieldManager, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================================
    // Constants & Roles
    // ============================================================================

    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint16 public constant REFERRAL_CODE = 0;

    // ============================================================================
    // State
    // ============================================================================

    /// @notice Aave V3 Pool address
    IAaveV3Pool public immutable aavePool;

    /// @notice Next position ID
    uint256 public nextPositionId;

    /// @notice All positions by ID
    mapping(uint256 => Position) public positions;

    /// @notice Token to aToken mapping
    mapping(address => address) public aTokens;

    /// @notice Whether a token is supported
    mapping(address => bool) public supportedTokens;

    /// @notice Total principal deposited per token
    mapping(address => uint256) public totalPrincipalDeposited;

    /// @notice Total expected yield per token (at time of deposit)
    mapping(address => uint256) public totalExpectedYield;

    /// @notice List of supported token addresses
    address[] public tokenList;

    event TokenAdded(address indexed token, address indexed aToken);

    // ============================================================================
    // Constructor
    // ============================================================================

    constructor(address admin, address _aavePool) {
        require(admin != address(0), "admin=0");
        require(_aavePool != address(0), "pool=0");

        aavePool = IAaveV3Pool(_aavePool);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        nextPositionId = 1;
    }

    // ============================================================================
    // Token Management
    // ============================================================================

    /**
     * @notice Add a supported token
     * @param token ERC20 token address (underlying asset)
     */
    function addSupportedToken(address token) external onlyRole(TREASURY_ROLE) {
        require(token != address(0), "token=0");
        require(!supportedTokens[token], "already supported");

        // Get aToken address from Aave
        // Security: only aTokenAddress needed from Aave reserve data
        // slither-disable-next-line unused-return
        (,,,,,,,, address aTokenAddress,,,,,,) = aavePool.getReserveData(token);
        require(aTokenAddress != address(0), "no aave reserve");

        supportedTokens[token] = true;
        aTokens[token] = aTokenAddress;
        tokenList.push(token);

        emit TokenAdded(token, aTokenAddress);
    }

    // ============================================================================
    // IYieldManager Implementation
    // ============================================================================

    /// @inheritdoc IYieldManager
    function deposit(
        address token,
        uint256 principal,
        uint256 maturity,
        uint256 annualRateBps
    ) external override nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 positionId) {
        require(supportedTokens[token], "token not supported");
        require(principal > 0, "principal=0");
        require(maturity > block.timestamp, "maturity in past");

        // Calculate expected yield based on provided rate
        uint256 durationSeconds = maturity - block.timestamp;
        uint256 expectedYield = (principal * annualRateBps * durationSeconds) / (365 days * 10_000);

        // Create position
        positionId = nextPositionId++;
        positions[positionId] = Position({
            token: token,
            principal: principal,
            expectedYield: expectedYield,
            maturity: maturity,
            timestamp: block.timestamp,
            active: true
        });

        // Update totals
        totalPrincipalDeposited[token] += principal;
        totalExpectedYield[token] += expectedYield;

        // Transfer tokens from caller
        IERC20(token).safeTransferFrom(msg.sender, address(this), principal);

        // Supply to Aave V3
        IERC20(token).safeIncreaseAllowance(address(aavePool), principal);
        aavePool.supply(token, principal, address(this), REFERRAL_CODE);

        emit PositionCreated(positionId, token, principal, maturity);
    }

    /// @inheritdoc IYieldManager
    function redeem(uint256 positionId) external override nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 principal, uint256 yield) {
        Position storage pos = positions[positionId];
        require(pos.active, "position not active");
        require(block.timestamp >= pos.maturity, "not mature");

        principal = pos.principal;
        address token = pos.token;

        // Calculate actual yield from Aave aToken balance
        address aToken = aTokens[token];
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
        uint256 totalLiabilitiesExcluding = (totalPrincipalDeposited[token] - principal) + (totalExpectedYield[token] - pos.expectedYield);
        uint256 availableForPosition = aTokenBalance > totalLiabilitiesExcluding ? aTokenBalance - totalLiabilitiesExcluding : 0;

        // Use lesser of expected yield and what's actually available
        yield = availableForPosition > principal ? availableForPosition - principal : 0;
        if (yield > pos.expectedYield) {
            yield = pos.expectedYield; // Cap at expected (excess is profit)
        }

        // Mark position as redeemed
        pos.active = false;

        // Update totals
        totalPrincipalDeposited[token] -= principal;
        totalExpectedYield[token] -= pos.expectedYield;

        // Withdraw from Aave - use actual available amount
        uint256 totalPayout = principal + yield;
        uint256 withdrawn = aavePool.withdraw(token, totalPayout, address(this));
        require(withdrawn >= principal, "Aave withdraw shortfall");

        // Transfer to caller
        IERC20(token).safeTransfer(msg.sender, withdrawn);

        emit PositionRedeemed(positionId, principal, yield);
    }

    /// @inheritdoc IYieldManager
    function getPositionValue(uint256 positionId) external view override returns (uint256 currentValue, uint256 accruedYield) {
        Position memory pos = positions[positionId];
        if (!pos.active) {
            return (0, 0);
        }

        // Calculate pro-rated yield based on time elapsed
        uint256 elapsed = block.timestamp - pos.timestamp;
        uint256 totalDuration = pos.maturity - pos.timestamp;

        if (elapsed >= totalDuration) {
            accruedYield = pos.expectedYield;
        } else {
            accruedYield = (pos.expectedYield * elapsed) / totalDuration;
        }

        currentValue = pos.principal + accruedYield;
    }

    /// @inheritdoc IYieldManager
    function getPosition(uint256 positionId) external view override returns (Position memory position) {
        return positions[positionId];
    }

    /// @inheritdoc IYieldManager
    function addLiquidity(address token, uint256 amount) external override nonReentrant onlyRole(TREASURY_ROLE) {
        require(supportedTokens[token], "not supported");
        require(amount > 0, "amount=0");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).safeIncreaseAllowance(address(aavePool), amount);
        aavePool.supply(token, amount, address(this), REFERRAL_CODE);

        emit LiquidityAdded(token, amount);
    }

    /// @inheritdoc IYieldManager
    function removeLiquidity(address token, uint256 amount, address recipient) external override nonReentrant onlyRole(TREASURY_ROLE) {
        require(supportedTokens[token], "not supported");
        require(recipient != address(0), "recipient=0");
        require(amount > 0, "amount=0");

        // Check we have excess liquidity
        uint256 excessLiquidity = _getExcessLiquidity(token);
        require(amount <= excessLiquidity, "insufficient excess liquidity");

        uint256 withdrawn = aavePool.withdraw(token, amount, recipient);
        require(withdrawn >= amount, "Aave withdraw shortfall");

        emit LiquidityRemoved(token, amount);
    }

    /// @inheritdoc IYieldManager
    function getTokenStats(address token) external view override returns (TokenStats memory stats) {
        address aToken = aTokens[token];
        uint256 aTokenBalance = aToken != address(0) ? IERC20(aToken).balanceOf(address(this)) : 0;

        stats = TokenStats({
            totalDeposited: totalPrincipalDeposited[token],
            totalExpectedYield: totalExpectedYield[token],
            availableLiquidity: aTokenBalance,
            pendingMaturities: totalPrincipalDeposited[token] + totalExpectedYield[token]
        });
    }

    /// @inheritdoc IYieldManager
    function totalAssets(address token) external view override returns (uint256) {
        address aToken = aTokens[token];
        if (aToken == address(0)) return 0;
        return IERC20(aToken).balanceOf(address(this));
    }

    /// @inheritdoc IYieldManager
    function totalLiabilities(address token) external view override returns (uint256) {
        return totalPrincipalDeposited[token] + totalExpectedYield[token];
    }

    /// @inheritdoc IYieldManager
    function name() external pure override returns (string memory) {
        return "Aave V3 Yield Manager";
    }

    /// @inheritdoc IYieldManager
    function supportsToken(address token) external view override returns (bool) {
        return supportedTokens[token];
    }

    /// @inheritdoc IYieldManager
    function currentApyBps(address token) external view override returns (uint256) {
        if (!supportedTokens[token]) return 0;

        // Get current supply rate from Aave (in ray = 1e27)
        // Security: only currentLiquidityRate needed from Aave reserve data
        // slither-disable-next-line unused-return
        (,, uint128 currentLiquidityRate,,,,,,,,,,,,) = aavePool.getReserveData(token);

        // Convert from ray (1e27) to bps (1e4)
        // rate in ray / 1e23 = rate in bps
        return uint256(currentLiquidityRate) / 1e23;
    }

    // ============================================================================
    // View Functions
    // ============================================================================

    /**
     * @notice Get all supported tokens
     * @return tokens Array of supported token addresses
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return tokenList;
    }

    /**
     * @notice Get the aToken address for a token
     * @param token Underlying token address
     * @return aToken aToken address
     */
    function getAToken(address token) external view returns (address) {
        return aTokens[token];
    }

    /**
     * @notice Get balance sheet summary for a token
     * @param token ERC20 token address
     * @return assets Total assets (aToken balance)
     * @return liabilities Total liabilities (principal + expected yield)
     * @return equity Assets minus liabilities
     */
    function getBalanceSheet(address token) external view returns (
        uint256 assets,
        uint256 liabilities,
        int256 equity
    ) {
        address aToken = aTokens[token];
        assets = aToken != address(0) ? IERC20(aToken).balanceOf(address(this)) : 0;
        liabilities = totalPrincipalDeposited[token] + totalExpectedYield[token];
        equity = int256(assets) - int256(liabilities);
    }

    /**
     * @notice Get actual yield earned from Aave vs expected
     * @param token ERC20 token address
     * @return actualYield Yield from aToken balance growth
     * @return expectedYield Total expected yield from positions
     * @return surplus Actual minus expected (positive = outperformance)
     */
    function getYieldPerformance(address token) external view returns (
        uint256 actualYield,
        uint256 expectedYield,
        int256 surplus
    ) {
        address aToken = aTokens[token];
        uint256 aTokenBalance = aToken != address(0) ? IERC20(aToken).balanceOf(address(this)) : 0;
        uint256 principal = totalPrincipalDeposited[token];
        expectedYield = totalExpectedYield[token];

        if (aTokenBalance > principal) {
            actualYield = aTokenBalance - principal;
        }

        surplus = int256(actualYield) - int256(expectedYield);
    }

    /**
     * @notice Get count of active positions
     * @return count Number of active positions
     */
    function activePositionCount() external view returns (uint256 count) {
        for (uint256 i = 1; i < nextPositionId; i++) {
            if (positions[i].active) {
                count++;
            }
        }
    }

    // ============================================================================
    // Internal Functions
    // ============================================================================

    function _getExcessLiquidity(address token) internal view returns (uint256) {
        address aToken = aTokens[token];
        uint256 balance = aToken != address(0) ? IERC20(aToken).balanceOf(address(this)) : 0;
        uint256 liabilities = totalPrincipalDeposited[token] + totalExpectedYield[token];

        if (balance > liabilities) {
            return balance - liabilities;
        }
        return 0;
    }
}
