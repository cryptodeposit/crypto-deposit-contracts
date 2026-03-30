// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPriceOracle
 * @notice Interface for retrieving asset prices in USD
 * @dev Prices are returned scaled to 8 decimals (like Chainlink).
 *      e.g., BTC at $65,000.00 = 65_000_00000000 (6500000000000)
 *      Implementations may use Chainlink feeds, operator-signed attestations, or other sources.
 */
interface IPriceOracle {
    /// @notice Get the USD price of a token
    /// @param token ERC20 token address
    /// @return price Price in USD scaled to 8 decimals
    /// @return timestamp When the price was last updated
    function getPrice(address token) external view returns (uint256 price, uint256 timestamp);

    /// @notice Get USD prices for multiple tokens
    /// @param tokens Array of ERC20 token addresses
    /// @return prices Array of prices in USD scaled to 8 decimals
    /// @return timestamp Oldest timestamp among returned prices
    function getPrices(address[] calldata tokens) external view returns (uint256[] memory prices, uint256 timestamp);

    /// @notice Check if a price is considered fresh (not stale)
    /// @param token ERC20 token address
    /// @return fresh True if price was updated within staleness threshold
    function isPriceFresh(address token) external view returns (bool fresh);
}
