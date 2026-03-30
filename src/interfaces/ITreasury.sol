// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ITreasury
 * @notice Central treasury interface — single custody point for all protocol tokens
 * @dev Receives tokens from deposits, collateral, and repayments.
 *      Deploys excess capital to yield strategies while maintaining reserve ratios.
 *      Tracks maturity profiles for asset-liability management (ALM).
 *
 *      Three business lines:
 *        1. Deposits — client earns yield curve rate, protocol keeps surplus
 *        2. Collateral — client earns nothing, protocol rehypothecates freely
 *        3. Lending — client pays interest, all interest is protocol revenue
 */
interface ITreasury {
    /// @notice Per-token accounting state
    struct TokenState {
        uint256 depositClaims;          // Active deposit principals held
        uint256 depositLiabilities;     // Total owed to depositors (principal + promised yield)
        uint256 collateralClaims;       // Collateral held (no yield owed)
        uint256 lendingPool;            // Undeployed lending pool capital
        uint256 deployed;               // Capital currently in yield strategies
        uint256 protocolRevenue;        // Accumulated protocol earnings
        uint256 reserveRatioBps;        // Min on-chain reserve (e.g., 2000 = 20%)
    }

    /// @notice Time-bucketed liability/asset profile for ALM
    struct MaturityBucket {
        uint256 timestamp;      // Bucket start timestamp
        uint256 liabilities;    // Deposit redemptions due in this bucket
        uint256 assets;         // Strategy returns expected in this bucket
    }

    /// @notice Strategy deployment record
    struct StrategyAllocation {
        address strategy;           // Strategy adapter address
        address token;              // Token deployed
        uint256 amount;             // Amount deployed
        uint256 maturityTimestamp;  // When funds expected back (0 = liquid)
        uint256 deployedAt;         // Deployment timestamp
    }

    // ============================================================================
    // Events
    // ============================================================================

    event DepositRecorded(address indexed token, uint256 principal, uint256 liability, uint256 maturityTimestamp);
    event DepositRedemptionPaid(address indexed token, uint256 amount, address indexed recipient);
    event CollateralRecorded(address indexed token, uint256 amount);
    event CollateralReleased(address indexed token, uint256 amount, address indexed recipient);
    event LiquidationWithdrawal(address indexed token, uint256 amount, address indexed recipient);
    event LoanDisbursed(address indexed token, uint256 amount, address indexed borrower);
    event RepaymentRecorded(address indexed token, uint256 principal, uint256 interest);
    event StrategyDeployed(address indexed strategy, address indexed token, uint256 amount, uint256 maturityTimestamp);
    event StrategyWithdrawn(address indexed strategy, address indexed token, uint256 amount);
    event ReserveRatioUpdated(address indexed token, uint256 oldRatioBps, uint256 newRatioBps);
    event ProtocolRevenueWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event StrategyRegistered(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event LendingPoolFunded(address indexed token, uint256 amount);

    /// @notice Emitted when yield is captured from a strategy withdrawal
    event YieldCaptured(
        address indexed strategy,
        address indexed token,
        uint256 principal,
        uint256 withdrawn,
        uint256 yieldAmount,
        uint256 newProtocolRevenue
    );

    /// @notice Emitted when admin executes emergency withdrawal
    event EmergencyWithdraw(
        address indexed token,
        uint256 amount,
        address indexed recipient,
        uint256 depositClaimsCleared,
        uint256 depositLiabilitiesCleared,
        uint256 collateralClaimsCleared,
        uint256 protocolRevenueCleared
    );

    /// @notice Emitted when strategies are unwound under emergency (liquidity shortfall)
    event EmergencyUnwind(
        address indexed strategy,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when commission is split on bill redemption
    event CommissionSplit(
        uint256 indexed billId,
        address indexed token,
        uint256 totalCommission,
        uint256 introducerShare,
        address indexed introducingWallet
    );

    /// @notice Emitted for periodic deposit interest accrual snapshots
    event DepositInterestAccrued(
        address indexed token,
        uint256 totalLiabilities,
        uint256 interestDelta,
        uint256 timestamp
    );

    /// @notice Emitted when deposit liabilities are adjusted during bill merge
    event DepositMergeAdjusted(
        address indexed token,
        uint256 oldTotalLiability,
        uint256 newLiability,
        uint256 newMaturity
    );

    /// @notice Emitted when yield is harvested from a strategy without touching principal
    event YieldHarvested(
        address indexed strategy,
        address indexed token,
        uint256 yieldAmount,
        uint256 newProtocolRevenue
    );

    /// @notice Emitted when untracked tokens are swept from the treasury
    event TokenSwept(address indexed token, uint256 amount, address indexed recipient);

    // ============================================================================
    // Deposit Manager Functions (called by DiscountBill)
    // ============================================================================

    /**
     * @notice Record a new deposit — tokens already transferred to Treasury
     * @param token ERC20 token deposited
     * @param principal Deposit principal amount
     * @param liability Total owed at maturity (principal + yield)
     * @param maturityTimestamp When the deposit matures
     */
    function recordDeposit(address token, uint256 principal, uint256 liability, uint256 maturityTimestamp) external;

    /**
     * @notice Withdraw tokens for a deposit redemption
     * @param token ERC20 token to withdraw
     * @param amount Amount to pay out
     * @param recipient Depositor's wallet
     */
    function withdrawForRedemption(address token, uint256 amount, address recipient) external;

    /**
     * @notice Adjust deposit accounting when bills are merged
     * @dev Called by DiscountBill during merge() — atomically removes old liabilities
     *      and records new merged liability with updated maturity bucket
     * @param token ERC20 token
     * @param oldTotalLiability Sum of old bills' liabilities being removed
     * @param newLiability New merged bill's liability
     * @param newMaturity New merged bill's maturity timestamp
     * @param oldBillLiabilities Array of individual old bill liabilities
     * @param oldBillMaturities Array of individual old bill maturity timestamps
     */
    function adjustDepositOnMerge(
        address token,
        uint256 oldTotalLiability,
        uint256 newLiability,
        uint256 newMaturity,
        uint256[] calldata oldBillLiabilities,
        uint256[] calldata oldBillMaturities
    ) external;

    // ============================================================================
    // Collateral Manager Functions (called by CollateralVault)
    // ============================================================================

    /**
     * @notice Record collateral deposited — tokens already transferred to Treasury
     * @param token ERC20 token
     * @param amount Collateral amount
     */
    function recordCollateral(address token, uint256 amount) external;

    /**
     * @notice Release collateral back to client
     * @param token ERC20 token
     * @param amount Amount to release
     * @param recipient Client address
     */
    function releaseCollateral(address token, uint256 amount, address recipient) external;

    /**
     * @notice Withdraw tokens for liquidation — MUST always succeed
     * @dev Pulls from strategies if on-chain balance is insufficient
     * @param token ERC20 token
     * @param amount Amount to liquidate
     * @param recipient Liquidator address
     */
    function withdrawForLiquidation(address token, uint256 amount, address recipient) external;

    // ============================================================================
    // Lending Manager Functions (called by BorrowingEngine)
    // ============================================================================

    /**
     * @notice Disburse a loan to borrower
     * @param token ERC20 token to lend
     * @param amount Loan amount
     * @param borrower Borrower address
     */
    function withdrawForLoan(address token, uint256 amount, address borrower) external;

    /**
     * @notice Record a loan repayment — tokens already transferred to Treasury
     * @param token ERC20 token
     * @param principal Principal portion repaid
     * @param interest Interest portion repaid (protocol revenue)
     */
    function recordRepayment(address token, uint256 principal, uint256 interest) external;

    // ============================================================================
    // Operator Functions
    // ============================================================================

    /**
     * @notice Deploy capital to a yield strategy
     * @param strategy Strategy adapter address
     * @param token ERC20 token to deploy
     * @param amount Amount to deploy
     * @param maturityTimestamp When funds expected back (0 for liquid strategies)
     */
    function allocateToStrategy(
        address strategy,
        address token,
        uint256 amount,
        uint256 maturityTimestamp
    ) external;

    /**
     * @notice Withdraw capital from a yield strategy
     * @param strategy Strategy adapter address
     * @param token ERC20 token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawFromStrategy(address strategy, address token, uint256 amount) external;

    /**
     * @notice Set the reserve ratio for a token
     * @param token ERC20 token
     * @param ratioBps Reserve ratio in basis points (e.g., 2000 = 20%)
     */
    function setReserveRatio(address token, uint256 ratioBps) external;

    /**
     * @notice Fund the lending pool with tokens
     * @param token ERC20 token
     * @param amount Amount to add to lending pool
     */
    function fundLendingPool(address token, uint256 amount) external;

    /**
     * @notice Withdraw accumulated protocol revenue
     * @param token ERC20 token
     * @param amount Amount to withdraw
     * @param recipient Revenue recipient
     */
    function withdrawRevenue(address token, uint256 amount, address recipient) external;

    /**
     * @notice Register a new strategy adapter
     * @param strategy Strategy adapter address
     */
    function registerStrategy(address strategy) external;

    /**
     * @notice Remove a strategy adapter (must have zero deployed balance)
     * @param strategy Strategy adapter address
     */
    function removeStrategy(address strategy) external;

    /**
     * @notice Harvest yield from a strategy without touching deployed principal
     * @param strategy Strategy adapter address
     * @param token ERC20 token to harvest yield for
     */
    function harvestYield(address strategy, address token) external;

    /**
     * @notice Sweep tokens not tracked by any accounting category
     * @param token ERC20 token to sweep
     * @param amount Amount to sweep
     * @param recipient Address to receive swept tokens
     */
    function sweepUntracked(address token, uint256 amount, address recipient) external;

    // ============================================================================
    // Emergency Functions
    // ============================================================================

    /**
     * @notice Emergency withdrawal — bypasses reserve floor and zeroes accounting
     * @dev ADMIN ONLY. Force-unwinds strategies, clears all accounting for the token.
     * @param token ERC20 token to withdraw
     * @param amount Amount to withdraw (use type(uint256).max for full balance)
     * @param recipient Address to receive the tokens
     */
    function emergencyWithdraw(address token, uint256 amount, address recipient) external;

    // ============================================================================
    // View Functions
    // ============================================================================

    /**
     * @notice Get full accounting state for a token
     * @param token ERC20 token
     * @return state Token accounting state
     */
    function getTokenState(address token) external view returns (TokenState memory state);

    /**
     * @notice Total assets for a token (on-chain + deployed)
     * @param token ERC20 token
     * @return total Total assets
     */
    function totalAssets(address token) external view returns (uint256 total);

    /**
     * @notice Total liabilities for a token (deposit claims + deposit yield owed)
     * @param token ERC20 token
     * @return total Total liabilities
     */
    function totalLiabilities(address token) external view returns (uint256 total);

    /**
     * @notice Available reserves (on-chain balance minus reserve floor)
     * @param token ERC20 token
     * @return available Deployable reserves
     */
    function availableReserves(address token) external view returns (uint256 available);

    /**
     * @notice Get maturity profile for ALM analysis
     * @param token ERC20 token
     * @return buckets Time-bucketed maturity schedule
     */
    function getMaturityProfile(address token) external view returns (MaturityBucket[] memory buckets);

    /**
     * @notice Check if ALM constraints are satisfied
     * @dev Walks maturity buckets ensuring cumulative assets >= cumulative liabilities
     * @param token ERC20 token
     * @return healthy True if ALM is healthy
     */
    function isALMHealthy(address token) external view returns (bool healthy);

    /**
     * @notice Get all registered strategies
     * @return strategies List of strategy adapter addresses
     */
    function getStrategies() external view returns (address[] memory strategies);

    /**
     * @notice Get amount deployed in a specific strategy for a token
     * @param strategy Strategy adapter address
     * @param token ERC20 token
     * @return amount Amount deployed
     */
    function getStrategyDeployed(address strategy, address token) external view returns (uint256 amount);
}
