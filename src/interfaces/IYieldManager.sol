// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IYieldManager
 * @notice Interface for yield management contracts that handle deposited funds
 * @dev Yield managers receive ERC20 tokens from the deposit contract and manage them
 *      to generate yield. They track positions and return funds with interest.
 */
interface IYieldManager {
    /// @notice Position tracking for allocated funds
    struct Position {
        address token;           // ERC20 token address
        uint256 principal;       // Original amount deposited
        uint256 expectedYield;   // Expected yield at maturity
        uint256 maturity;        // Unix timestamp when funds are due back
        uint256 timestamp;       // When position was created
        bool active;             // Whether position is still active
    }

    /// @notice Aggregate stats for a token
    struct TokenStats {
        uint256 totalDeposited;      // Total principal deposited
        uint256 totalExpectedYield;  // Total expected yield
        uint256 availableLiquidity;  // Funds available for immediate withdrawal
        uint256 pendingMaturities;   // Funds locked until maturity
    }

    // Events
    event PositionCreated(uint256 indexed positionId, address indexed token, uint256 principal, uint256 maturity);
    event PositionRedeemed(uint256 indexed positionId, uint256 principal, uint256 yield);
    event LiquidityAdded(address indexed token, uint256 amount);
    event LiquidityRemoved(address indexed token, uint256 amount);
    event YieldAccrued(address indexed token, uint256 amount);

    // ============================================================================
    // Core Functions
    // ============================================================================

    /**
     * @notice Deposit funds into the yield manager
     * @param token ERC20 token to deposit
     * @param principal Amount to deposit
     * @param maturity Unix timestamp when funds should be available
     * @param annualRateBps Expected annual rate in basis points
     * @return positionId Unique identifier for this position
     */
    function deposit(
        address token,
        uint256 principal,
        uint256 maturity,
        uint256 annualRateBps
    ) external returns (uint256 positionId);

    /**
     * @notice Withdraw funds from a matured position
     * @param positionId Position to redeem
     * @return principal Original principal amount
     * @return yield Yield earned on the position
     */
    function redeem(uint256 positionId) external returns (uint256 principal, uint256 yield);

    /**
     * @notice Get current value of a position (principal + accrued yield)
     * @param positionId Position to query
     * @return currentValue Total current value
     * @return accruedYield Yield accrued so far
     */
    function getPositionValue(uint256 positionId) external view returns (uint256 currentValue, uint256 accruedYield);

    /**
     * @notice Get position details
     * @param positionId Position to query
     * @return position Full position details
     */
    function getPosition(uint256 positionId) external view returns (Position memory position);

    // ============================================================================
    // Liquidity Management (Admin)
    // ============================================================================

    /**
     * @notice Add liquidity to the yield manager (owner/treasury operation)
     * @param token ERC20 token to add
     * @param amount Amount to add
     */
    function addLiquidity(address token, uint256 amount) external;

    /**
     * @notice Remove excess liquidity (owner/treasury operation)
     * @param token ERC20 token to remove
     * @param amount Amount to remove
     * @param recipient Where to send the funds
     */
    function removeLiquidity(address token, uint256 amount, address recipient) external;

    // ============================================================================
    // View Functions
    // ============================================================================

    /**
     * @notice Get aggregate stats for a token
     * @param token ERC20 token to query
     * @return stats Aggregate statistics
     */
    function getTokenStats(address token) external view returns (TokenStats memory stats);

    /**
     * @notice Get total assets under management
     * @param token ERC20 token to query
     * @return totalAssets Total value (deposits + yield)
     */
    function totalAssets(address token) external view returns (uint256 totalAssets);

    /**
     * @notice Get total liabilities (what's owed to depositors)
     * @param token ERC20 token to query
     * @return totalLiabilities Total owed (principal + expected yield)
     */
    function totalLiabilities(address token) external view returns (uint256 totalLiabilities);

    /**
     * @notice Get manager name/type for display
     * @return name Human-readable name
     */
    function name() external view returns (string memory name);

    /**
     * @notice Check if manager supports a specific token
     * @param token ERC20 token to check
     * @return supported Whether the token is supported
     */
    function supportsToken(address token) external view returns (bool supported);

    /**
     * @notice Get the current APY being offered for a token
     * @param token ERC20 token to query
     * @return apyBps Annual percentage yield in basis points
     */
    function currentApyBps(address token) external view returns (uint256 apyBps);
}
