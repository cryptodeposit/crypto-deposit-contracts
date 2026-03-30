// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IDiscountBill.sol";

/**
 * @title DiscountBillBatchHelper
 * @notice Gas-efficient batch operations for DiscountBill.
 *         Deployed separately to keep the main contract under EIP-170 size limit.
 *         Requires OPERATOR_ROLE on the DiscountBill contract.
 */
contract DiscountBillBatchHelper {
    IDiscountBill public immutable bill;

    struct IssueParams {
        address owner;
        address depositor;
        address depositWallet;
        address introducingWallet;
        address token;
        uint256 principal;
        uint256 annualRateBps;
        uint256 durationInDays;
    }

    error EmptyBatch();

    constructor(address bill_) {
        bill = IDiscountBill(bill_);
    }

    /**
     * @notice Issue multiple bills in a single transaction
     * @param params Array of issue parameters
     * @return billIds Array of newly created bill IDs
     */
    function batchIssue(IssueParams[] calldata params) external returns (uint256[] memory billIds) {
        if (params.length == 0) revert EmptyBatch();
        billIds = new uint256[](params.length);
        for (uint256 i = 0; i < params.length; i++) {
            billIds[i] = bill.issue(
                params[i].owner,
                params[i].depositor,
                params[i].depositWallet,
                params[i].introducingWallet,
                params[i].token,
                params[i].principal,
                params[i].annualRateBps,
                params[i].durationInDays
            );
        }
    }

    /**
     * @notice Fetch bill info for multiple IDs in one call
     * @param billIds Array of bill IDs to query
     * @return infos Array of BillInfo structs
     */
    function getBillsBatch(uint256[] calldata billIds) external view returns (IDiscountBill.BillInfo[] memory infos) {
        infos = new IDiscountBill.BillInfo[](billIds.length);
        for (uint256 i = 0; i < billIds.length; i++) {
            infos[i] = bill.getBillInfo(billIds[i]);
        }
    }

    /**
     * @notice Merge multiple sets of bills in a single transaction
     * @param billIdSets Array of bill ID arrays (each set is merged independently)
     * @param rolloverRates Array of rollover annual rate BPS for each merge
     * @return newBillIds Array of newly created merged bill IDs
     */
    function batchMerge(
        uint256[][] calldata billIdSets,
        uint256[] calldata rolloverRates
    ) external returns (uint256[] memory newBillIds) {
        require(billIdSets.length == rolloverRates.length, "length mismatch");
        if (billIdSets.length == 0) revert EmptyBatch();
        newBillIds = new uint256[](billIdSets.length);
        for (uint256 i = 0; i < billIdSets.length; i++) {
            newBillIds[i] = bill.merge(billIdSets[i], rolloverRates[i]);
        }
    }
}
