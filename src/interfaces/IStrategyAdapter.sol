// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IStrategyAdapter
 * @notice Interface for yield strategy adapters used by the Treasury
 * @dev Each adapter wraps a single yield protocol (Aave V3, off-chain facility, etc.).
 *      Only callable by the Treasury contract.
 */
interface IStrategyAdapter {
    /**
     * @notice Deploy tokens into the yield strategy
     * @param token ERC20 token to deploy
     * @param amount Amount to deploy
     */
    function deploy(address token, uint256 amount) external;

    /**
     * @notice Withdraw tokens from the yield strategy
     * @param token ERC20 token to withdraw
     * @param amount Requested withdrawal amount
     * @return withdrawn Actual amount withdrawn (may differ due to slippage/fees)
     */
    function withdraw(address token, uint256 amount) external returns (uint256 withdrawn);

    /**
     * @notice Get total principal deployed for a token
     * @param token ERC20 token
     * @return amount Total deployed principal
     */
    function totalDeployed(address token) external view returns (uint256 amount);

    /**
     * @notice Get current market value of deployed tokens (principal + yield)
     * @param token ERC20 token
     * @return value Current value including accrued yield
     */
    function currentValue(address token) external view returns (uint256 value);

    /**
     * @notice Check if the strategy supports a specific token
     * @param token ERC20 token to check
     * @return supported True if the token can be deployed
     */
    function supportsToken(address token) external view returns (bool supported);

    /**
     * @notice Whether the strategy supports same-block withdrawals
     * @dev Aave V3 = true (instant liquidity), off-chain facility = false
     * @return liquid True if withdrawals are immediate
     */
    function isLiquid() external view returns (bool liquid);

    /**
     * @notice Human-readable strategy name
     * @return name Strategy identifier (e.g., "Aave V3", "Treasury Facility")
     */
    function name() external view returns (string memory name);
}
