// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IYieldManager} from "./interfaces/IYieldManager.sol";

/**
 * @title TreasuryYieldManager
 * @notice In-house yield manager backed by off-chain real estate facility
 * @dev This contract manages deposits that are backed by a bank facility secured
 *      by real estate. The $10M facility provides immediate liquidity and yield
 *      guarantee. Actual yield generation happens off-chain through the facility.
 *
 * Key features:
 * - Pre-funded liquidity from real estate facility ($10M equivalent)
 * - Guaranteed yield rates (backed by facility agreement)
 * - On-call liquidity for all depositor redemptions
 * - Admin functions for treasury management
 */
contract TreasuryYieldManager is IYieldManager, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================================
    // Constants & Roles
    // ============================================================================

    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant FACILITY_AMOUNT_USD = 10_000_000 * 1e6; // $10M in 6 decimals
    uint256 public constant DEFAULT_APY_BPS = 450; // 4.5% default APY
    uint256 public constant MAX_APY_BPS = 1000; // 10% max APY cap

    // ============================================================================
    // State
    // ============================================================================

    /// @notice Next position ID
    uint256 public nextPositionId;

    /// @notice All positions by ID
    mapping(uint256 => Position) public positions;

    /// @notice Supported tokens and their APY rates
    mapping(address => uint256) public tokenApyBps;

    /// @notice Whether a token is supported
    mapping(address => bool) public supportedTokens;

    /// @notice Total principal deposited per token
    mapping(address => uint256) public totalPrincipalDeposited;

    /// @notice Total expected yield per token
    mapping(address => uint256) public totalExpectedYield;

    /// @notice Additional liquidity added per token (beyond deposits)
    mapping(address => uint256) public additionalLiquidity;

    /// @notice Facility commitment per token (virtual liquidity from facility)
    mapping(address => uint256) public facilityCommitment;

    /// @notice List of supported token addresses
    address[] public tokenList;

    event TokenApyUpdated(address indexed token, uint256 oldApyBps, uint256 newApyBps);

    // ============================================================================
    // Constructor
    // ============================================================================

    constructor(address admin) {
        require(admin != address(0), "admin=0");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        nextPositionId = 1;
    }

    // ============================================================================
    // Token Management
    // ============================================================================

    /**
     * @notice Add a supported token with facility commitment
     * @param token ERC20 token address
     * @param apyBps Annual yield in basis points
     * @param facilityAmount Virtual facility commitment for this token
     */
    function addSupportedToken(
        address token,
        uint256 apyBps,
        uint256 facilityAmount
    ) external onlyRole(TREASURY_ROLE) {
        require(token != address(0), "token=0");
        require(apyBps <= MAX_APY_BPS, "apy too high");
        require(!supportedTokens[token], "already supported");

        supportedTokens[token] = true;
        tokenApyBps[token] = apyBps;
        facilityCommitment[token] = facilityAmount;
        tokenList.push(token);

        emit LiquidityAdded(token, facilityAmount);
    }

    /**
     * @notice Update APY for a token
     * @param token ERC20 token address
     * @param apyBps New APY in basis points
     */
    function setTokenApy(address token, uint256 apyBps) external onlyRole(TREASURY_ROLE) {
        require(supportedTokens[token], "not supported");
        require(apyBps <= MAX_APY_BPS, "apy too high");
        uint256 old = tokenApyBps[token];
        tokenApyBps[token] = apyBps;
        emit TokenApyUpdated(token, old, apyBps);
    }

    /**
     * @notice Update facility commitment for a token
     * @param token ERC20 token address
     * @param amount New facility commitment amount
     */
    function setFacilityCommitment(address token, uint256 amount) external onlyRole(TREASURY_ROLE) {
        require(supportedTokens[token], "not supported");
        uint256 oldAmount = facilityCommitment[token];
        facilityCommitment[token] = amount;

        if (amount > oldAmount) {
            emit LiquidityAdded(token, amount - oldAmount);
        } else if (amount < oldAmount) {
            emit LiquidityRemoved(token, oldAmount - amount);
        }
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
        require(annualRateBps <= MAX_APY_BPS, "rate too high");

        // Calculate expected yield
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

        // Transfer tokens in
        IERC20(token).safeTransferFrom(msg.sender, address(this), principal);

        emit PositionCreated(positionId, token, principal, maturity);
    }

    /// @inheritdoc IYieldManager
    function redeem(uint256 positionId) external override nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 principal, uint256 yield) {
        Position storage pos = positions[positionId];
        require(pos.active, "position not active");
        require(block.timestamp >= pos.maturity, "not mature");

        principal = pos.principal;
        yield = pos.expectedYield;
        address token = pos.token;

        // Mark position as redeemed
        pos.active = false;

        // Update totals
        totalPrincipalDeposited[token] -= principal;
        totalExpectedYield[token] -= yield;

        // Transfer tokens out (principal + yield)
        uint256 totalPayout = principal + yield;
        require(IERC20(token).balanceOf(address(this)) >= totalPayout, "Insufficient on-chain balance");
        IERC20(token).safeTransfer(msg.sender, totalPayout);

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

        additionalLiquidity[token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit LiquidityAdded(token, amount);
    }

    /// @inheritdoc IYieldManager
    function removeLiquidity(address token, uint256 amount, address recipient) external override nonReentrant onlyRole(TREASURY_ROLE) {
        require(supportedTokens[token], "not supported");
        require(recipient != address(0), "recipient=0");
        require(amount > 0, "amount=0");

        // Can only remove excess liquidity, not depositor funds
        uint256 excessLiquidity = _getExcessLiquidity(token);
        require(amount <= excessLiquidity, "insufficient excess liquidity");

        if (amount <= additionalLiquidity[token]) {
            additionalLiquidity[token] -= amount;
        } else {
            additionalLiquidity[token] = 0;
        }

        IERC20(token).safeTransfer(recipient, amount);

        emit LiquidityRemoved(token, amount);
    }

    /// @inheritdoc IYieldManager
    function getTokenStats(address token) external view override returns (TokenStats memory stats) {
        uint256 balance = IERC20(token).balanceOf(address(this));

        stats = TokenStats({
            totalDeposited: totalPrincipalDeposited[token],
            totalExpectedYield: totalExpectedYield[token],
            availableLiquidity: balance,
            pendingMaturities: totalPrincipalDeposited[token] + totalExpectedYield[token]
        });
    }

    /// @inheritdoc IYieldManager
    function totalAssets(address token) external view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Total assets including off-chain facility commitment (for reporting only)
    function totalAssetsIncludingFacility(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this)) + facilityCommitment[token];
    }

    /// @inheritdoc IYieldManager
    function totalLiabilities(address token) external view override returns (uint256) {
        return totalPrincipalDeposited[token] + totalExpectedYield[token];
    }

    /// @inheritdoc IYieldManager
    function name() external pure override returns (string memory) {
        return "Treasury Yield Manager";
    }

    /// @inheritdoc IYieldManager
    function supportsToken(address token) external view override returns (bool) {
        return supportedTokens[token];
    }

    /// @inheritdoc IYieldManager
    function currentApyBps(address token) external view override returns (uint256) {
        return tokenApyBps[token];
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
     * @notice Get facility utilization percentage
     * @param token ERC20 token address
     * @return utilizationBps Utilization in basis points (10000 = 100%)
     */
    function getFacilityUtilization(address token) external view returns (uint256 utilizationBps) {
        uint256 commitment = facilityCommitment[token];
        if (commitment == 0) return 0;

        uint256 liabilities = totalPrincipalDeposited[token] + totalExpectedYield[token];
        return (liabilities * 10_000) / commitment;
    }

    /**
     * @notice Get balance sheet summary for a token
     * @param token ERC20 token address
     * @return assets Total assets (actual balance + facility)
     * @return liabilities Total liabilities (principal + expected yield)
     * @return equity Assets minus liabilities
     */
    function getBalanceSheet(address token) external view returns (
        uint256 assets,
        uint256 liabilities,
        int256 equity
    ) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        assets = balance;
        liabilities = totalPrincipalDeposited[token] + totalExpectedYield[token];
        equity = int256(assets) - int256(liabilities);
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
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 liabilities = totalPrincipalDeposited[token] + totalExpectedYield[token];

        if (balance > liabilities) {
            return balance - liabilities;
        }
        return 0;
    }
}
