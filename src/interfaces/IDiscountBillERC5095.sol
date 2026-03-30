// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IDiscountBillERC5095
 * @notice Interface for bill token → parent bill callbacks
 * @dev Used by DiscountBillERC5095Token to avoid circular imports
 */
interface IDiscountBillERC5095 {
    function redeemableValue(uint256 billId) external view returns (uint256);
    function previewRedeem(uint256 billId, uint256 amount) external view returns (uint256);
    function canRedeem(uint256 billId, uint256 amount) external view returns (bool);
    function redeemViaToken(uint256 billId, uint256 amount, address receiver, address redeemer) external returns (uint256);
}
