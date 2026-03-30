// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IHaircutRegistry
 * @notice Interface for per-token collateral haircut configuration
 * @dev Haircuts determine effective collateral value and borrowing limits.
 *      Collateral haircut: reduces value of posted collateral (volatile = higher haircut)
 *      Borrow haircut: additional risk factor for borrowing specific assets
 *      MaxLTV: maximum loan-to-value ratio before borrow is rejected
 *      Liquidation threshold: health factor below which liquidation is permitted
 */
interface IHaircutRegistry {
    struct HaircutConfig {
        uint256 collateralHaircutBps;   // e.g., 3000 = 30% haircut on BTC collateral
        uint256 borrowHaircutBps;       // e.g., 500 = 5% additional cost for borrowing this asset
        uint256 maxLtvBps;              // e.g., 7500 = 75% max LTV
        uint256 liquidationThresholdBps;// e.g., 8250 = 82.5% threshold triggers liquidation
        bool enabled;                   // Whether this asset is accepted
    }

    event HaircutUpdated(address indexed token, HaircutConfig config, address indexed updatedBy);
    event AssetEnabled(address indexed token, address indexed enabledBy);
    event AssetDisabled(address indexed token, address indexed disabledBy);

    function getHaircut(address token) external view returns (HaircutConfig memory);
    function getEffectiveCollateralValue(address token, uint256 amount, uint256 priceUsd) external view returns (uint256);
    function isAcceptedCollateral(address token) external view returns (bool);
    function isAcceptedBorrow(address token) external view returns (bool);
}
