// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICollateralVault
 * @notice Interface for the collateral custody contract
 * @dev Holds ERC20 tokens and DiscountBill NFTs as collateral for borrowing.
 *      Integrates with HaircutRegistry for effective value calculation
 *      and ComplianceRegistry for deposit/withdrawal checks.
 */
interface ICollateralVault {
    struct CollateralPosition {
        address token;          // ERC20 address (address(0) for bills)
        uint256 amount;         // ERC20 amount (0 for bills)
        uint256 billId;         // DiscountBill NFT ID (0 for ERC20)
        uint256 depositedAt;    // Timestamp
        bool locked;            // True if backing active borrows
    }

    event CollateralDeposited(address indexed client, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed client, address indexed token, uint256 amount);
    event CollateralLiquidated(address indexed client, address indexed token, uint256 amount, address indexed liquidator);
    event BillDeposited(address indexed client, uint256 indexed billId, uint256 valuedAt);
    event BillWithdrawn(address indexed client, uint256 indexed billId);

    function depositCollateral(address token, uint256 amount) external;
    function depositBill(uint256 billId) external;
    function withdrawCollateral(address token, uint256 amount) external;
    function withdrawBill(uint256 billId) external;

    function getCollateralValue(address client) external view returns (uint256 totalValueUsd);
    function getEffectiveCollateralValue(address client) external view returns (uint256 effectiveValueUsd);
    function getFreeCollateral(address client) external view returns (uint256 freeValueUsd);
    function getPositions(address client) external view returns (CollateralPosition[] memory);

    function liquidateCollateral(address client, address token, uint256 amount, address liquidator) external;
}
