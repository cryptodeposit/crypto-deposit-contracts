// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IComplianceRegistry.sol";
import "../interfaces/ITravelRuleRegistry.sol";

interface IDiscountBill {
    struct BillInfo {
        address token;
        uint256 issuance;
        uint256 maturity;
        uint256 principal;
        uint256 redemptionValue;
        uint256 commissionBps;
        uint256 commissionAmount;
        address depositor;
        address depositWallet;
        address introducingWallet;
    }

    event BillIssued(uint256 indexed billId, address indexed owner, BillInfo info);
    event BillRedeemed(uint256 indexed billId, address indexed redeemer, uint256 amount);
    event BillTransferred(uint256 indexed billId, address indexed from, address indexed to);
    event BillMerged(
        uint256 indexed newBillId,
        address indexed owner,
        address indexed token,
        uint256 mergedCount,
        uint256 sumPrincipal,
        uint256 sumRedemptionValue,
        uint256 newMaturity
    );

    function issue(
        address owner,
        address depositor,
        address depositWallet,
        address introducingWallet,
        address token,
        uint256 principal,
        uint256 annualRateBps,
        uint256 durationInDays
    ) external returns (uint256 billId);

    function redeem(uint256 billId) external;

    function merge(uint256[] calldata billIds, uint256 rolloverAnnualRateBps) external returns (uint256 newBillId);

    function getBillInfo(uint256 billId) external view returns (BillInfo memory);

    function isMature(uint256 billId) external view returns (bool);

    function ownerOf(uint256 billId) external view returns (address);

    function complianceRegistry() external view returns (IComplianceRegistry);

    function travelRuleRegistry() external view returns (ITravelRuleRegistry);

    function commissionRateBps() external view returns (uint256);

    function maxDepositAmount(address token) external view returns (uint256);

    function setMaxDepositAmount(address token, uint256 amount) external;

    event MaxDepositAmountSet(address indexed token, uint256 amount);

    // pause(), unpause(), paused() are provided by PausableUpgradeable
    // on implementations that support it — not required by this interface.
}

