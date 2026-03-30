// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IAggregatorV3
 * @notice Minimal Chainlink AggregatorV3Interface for price feed consumption
 * @dev Only includes the functions needed by ChainlinkFallbackOracleUpgradeable.
 *      See https://docs.chain.link/data-feeds/api-reference
 */
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
