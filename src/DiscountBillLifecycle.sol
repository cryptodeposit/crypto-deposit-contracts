// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./DiscountBillStorage.sol";
import "./interfaces/IDiscountBill.sol";
import {BillMathLib} from "./libraries/BillMathLib.sol";

/**
 * @title DiscountBillLifecycle
 * @notice Extension for bill lifecycle operations: early redemption, merging, deposit wallet updates.
 * @dev Called via delegatecall from DiscountBillCore's fallback(). Shares the SAME storage
 *      layout via DiscountBillStorage inheritance. Does NOT inherit UUPSUpgradeable.
 *
 *      CRITICAL: Storage layout must remain identical to DiscountBillCore.
 */
contract DiscountBillLifecycle is DiscountBillStorage {
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════
    // Break fee management
    // ════════════════════════════════════════════════════════════════════

    function setBreakFee(address token, uint256 feeBps) external onlyRole(OPERATOR_ROLE) {
        if (feeBps > MAX_BREAK_FEE_BPS) revert FeeExceedsMax();
        if (token == address(0)) {
            defaultBreakFeeBps = feeBps;
        } else {
            breakFeeBps[token] = feeBps;
        }
        emit BreakFeeUpdated(token, feeBps);
    }

    function getBreakFee(address token) public view returns (uint256) {
        uint256 fee = breakFeeBps[token];
        return fee > 0 ? fee : defaultBreakFeeBps;
    }

    // ════════════════════════════════════════════════════════════════════
    // Early redemption
    // ════════════════════════════════════════════════════════════════════

    function requestEarlyRedemption(
        uint256 billId,
        bool isPartial,
        uint256 amount
    ) external returns (uint256 requestId) {
        if (ownerOf(billId) != msg.sender) revert NotOwner();
        IDiscountBill.BillInfo memory bill = bills[billId];
        if (bill.redemptionValue == 0) revert BillInvalid();
        if (isMature(billId)) revert AlreadyMature();

        // Check no pending request exists for this bill
        uint256[] memory existingRequests = billToRequests[billId];
        for (uint256 i = 0; i < existingRequests.length; i++) {
            if (earlyRedemptionRequests[existingRequests[i]].status == RedemptionStatus.Pending)
                revert PendingRequestExists();
        }

        uint256 redeemAmount = isPartial ? amount : bill.redemptionValue;
        if (redeemAmount == 0 || redeemAmount > bill.redemptionValue) revert InvalidAmount();

        (uint256 breakFee, uint256 accruedInterest, uint256 payoutAmount) = BillMathLib.calculateEarlyRedemption(
            bill.principal, bill.redemptionValue, bill.issuance, bill.maturity,
            block.timestamp, isPartial, redeemAmount, getBreakFee(bill.token)
        );

        requestId = earlyRedemptionRequests.length;
        earlyRedemptionRequests.push(EarlyRedemptionRequest({
            billId: billId,
            requester: msg.sender,
            requestedAt: block.timestamp,
            amount: redeemAmount,
            isPartial: isPartial,
            breakFee: breakFee,
            accruedInterest: accruedInterest,
            payoutAmount: payoutAmount,
            status: RedemptionStatus.Pending
        }));

        billToRequests[billId].push(requestId);
        emit EarlyRedemptionRequested(requestId, billId, msg.sender, redeemAmount, isPartial);
    }

    function previewEarlyRedemption(uint256 billId, bool isPartial, uint256 amount)
        external
        view
        returns (
            uint256 breakFee,
            uint256 accruedInterest,
            uint256 payoutAmount,
            uint256 daysRemaining
        )
    {
        IDiscountBill.BillInfo memory bill = bills[billId];
        if (bill.redemptionValue == 0) revert BillInvalid();

        uint256 redeemAmount = isPartial ? amount : bill.redemptionValue;
        uint256 totalTerm = bill.maturity - bill.issuance;
        uint256 elapsed = block.timestamp > bill.issuance ? block.timestamp - bill.issuance : 0;
        uint256 remaining = totalTerm > elapsed ? totalTerm - elapsed : 0;
        daysRemaining = remaining / 1 days;

        (breakFee, accruedInterest, payoutAmount) = BillMathLib.calculateEarlyRedemption(
            bill.principal, bill.redemptionValue, bill.issuance, bill.maturity,
            block.timestamp, isPartial, redeemAmount, getBreakFee(bill.token)
        );
    }

    // Security: protected by nonReentrant modifier
    // slither-disable-next-line reentrancy-no-eth
    function approveEarlyRedemption(uint256 requestId) external onlyRole(OPERATOR_ROLE) nonReentrant {
        if (requestId >= earlyRedemptionRequests.length) revert InvalidRequest();
        EarlyRedemptionRequest storage request = earlyRedemptionRequests[requestId];
        if (request.status != RedemptionStatus.Pending) revert NotPending();

        IDiscountBill.BillInfo storage bill = bills[request.billId];
        if (bill.redemptionValue == 0) revert BillInvalid();

        // Verify requester still owns the bill
        if (ownerOf(request.billId) != request.requester) revert NotOwner();

        request.status = RedemptionStatus.Approved;

        // Compute pro-rata principal for correct depositClaims accounting
        uint256 principalRedeemed = bill.redemptionValue > 0
            ? Math.mulDiv(bill.principal, request.amount, bill.redemptionValue)
            : 0;

        // Process the payout
        if (address(treasury) != address(0)) {
            _enforceComplianceAndTravel(bill.token, address(treasury), bill.depositWallet, request.payoutAmount);

            uint256 totalForfeit = request.amount - request.payoutAmount;
            uint256 cashRetained = principalRedeemed > request.payoutAmount
                ? principalRedeemed - request.payoutAmount
                : 0;

            // 1. Settle the non-payout portion (liability write-off, no revenue)
            if (totalForfeit > 0) {
                treasury.settleEarlyRedemptionForfeit(
                    bill.token, 0, totalForfeit,
                    cashRetained, bill.maturity
                );
            }
            // 2. Withdraw the payout: reduces liability, transfers cash
            uint256 principalInPayout = principalRedeemed - cashRetained;
            treasury.withdrawForRedemption(
                bill.token, request.payoutAmount, principalInPayout, bill.maturity, bill.depositWallet
            );
            travel.consume(bill.token, address(treasury), bill.depositWallet, request.payoutAmount);
        } else {
            if (IERC20(bill.token).balanceOf(issuer) < request.payoutAmount) revert InsufficientBalance();
            _enforceComplianceAndTravel(bill.token, issuer, bill.depositWallet, request.payoutAmount);
            // Security: issuer is a trusted state variable set at initialization, not arbitrary
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(bill.token).safeTransferFrom(issuer, bill.depositWallet, request.payoutAmount);
            travel.consume(bill.token, issuer, bill.depositWallet, request.payoutAmount);
        }

        // Update bill state
        if (request.isPartial) {
            uint256 startingValue = bill.redemptionValue;
            bill.redemptionValue -= request.amount;
            bill.principal = Math.mulDiv(bill.principal, bill.redemptionValue, startingValue);
            if (bill.commissionAmount > 0) {
                bill.commissionAmount = Math.mulDiv(bill.commissionAmount, bill.redemptionValue, startingValue);
            }
        } else {
            bill.redemptionValue = 0;
            bill.principal = 0;
            _burn(request.billId);
            billInvalidated[request.billId] = true;
        }

        request.status = RedemptionStatus.Executed;
        emit EarlyRedemptionApproved(requestId, request.payoutAmount);
    }

    function rejectEarlyRedemption(uint256 requestId, string calldata reason) external onlyRole(OPERATOR_ROLE) {
        if (requestId >= earlyRedemptionRequests.length) revert InvalidRequest();
        EarlyRedemptionRequest storage request = earlyRedemptionRequests[requestId];
        if (request.status != RedemptionStatus.Pending) revert NotPending();

        request.status = RedemptionStatus.Rejected;
        emit EarlyRedemptionRejected(requestId, reason);
    }

    function cancelEarlyRedemption(uint256 requestId) external {
        if (requestId >= earlyRedemptionRequests.length) revert InvalidRequest();
        EarlyRedemptionRequest storage request = earlyRedemptionRequests[requestId];
        if (request.status != RedemptionStatus.Pending) revert NotPending();
        if (request.requester != msg.sender) revert NotRequester();

        request.status = RedemptionStatus.Rejected;
        emit EarlyRedemptionRejected(requestId, "Cancelled by user");
    }

    function getEarlyRedemptionRequest(uint256 requestId) external view returns (EarlyRedemptionRequest memory) {
        if (requestId >= earlyRedemptionRequests.length) revert InvalidRequest();
        return earlyRedemptionRequests[requestId];
    }

    function getBillRequests(uint256 billId) external view returns (uint256[] memory) {
        return billToRequests[billId];
    }

    // ════════════════════════════════════════════════════════════════════
    // Bill merging
    // ════════════════════════════════════════════════════════════════════

    // Security: protected by nonReentrant modifier
    // slither-disable-next-line reentrancy-no-eth
    function merge(
        uint256[] calldata billIds,
        uint256 rolloverAnnualRateBps
    ) external nonReentrant whenNotPaused returns (uint256 newBillId) {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && ownerOf(billIds[0]) != msg.sender) revert NotAuthorized();
        if (billIds.length < 2) revert NeedTwoBills();

        address originalOwner = ownerOf(billIds[0]);
        IDiscountBill.BillInfo memory first = bills[billIds[0]];
        if (first.redemptionValue == 0) revert BillInvalid();
        if (isMature(billIds[0])) revert AlreadyMature();

        // Snapshot old liabilities for treasury adjustment
        uint256[] memory oldLiabilities = new uint256[](billIds.length);
        uint256[] memory oldMaturities = new uint256[](billIds.length);
        uint256 oldTotalLiability = 0;
        if (address(treasury) != address(0)) {
            for (uint256 i = 0; i < billIds.length; i++) {
                oldLiabilities[i] = bills[billIds[i]].redemptionValue;
                oldMaturities[i] = bills[billIds[i]].maturity;
                oldTotalLiability += bills[billIds[i]].redemptionValue;
            }
        }

        uint256 ratePerDayScaled = (rolloverAnnualRateBps * 1e18) / (365 * 10_000);
        (uint256 maxMaturity, uint256 sumPrincipal, uint256 sumAdjustedRedemption) =
            _aggregateBills(billIds, ratePerDayScaled, first);

        uint256 newInterest = sumAdjustedRedemption > sumPrincipal ? sumAdjustedRedemption - sumPrincipal : 0;
        uint256 newCommission = (newInterest * first.commissionBps) / 10_000;

        newBillId = nextBillId++;
        bills[newBillId] = IDiscountBill.BillInfo({
            token: first.token,
            issuance: block.timestamp,
            maturity: maxMaturity,
            principal: sumPrincipal,
            redemptionValue: sumAdjustedRedemption,
            commissionBps: first.commissionBps,
            commissionAmount: newCommission,
            depositor: first.depositor,
            depositWallet: first.depositWallet,
            introducingWallet: first.introducingWallet
        });

        // Notify treasury of liability adjustment
        if (address(treasury) != address(0)) {
            treasury.adjustDepositOnMerge(
                first.token, oldTotalLiability, sumAdjustedRedemption,
                maxMaturity, oldLiabilities, oldMaturities
            );
        }

        _safeMint(originalOwner, newBillId);
        billTokens[newBillId] = _deployBillToken(newBillId, first.token, maxMaturity, originalOwner, sumAdjustedRedemption);
        emit BillTokenCreated(newBillId, billTokens[newBillId]);
        emit IDiscountBill.BillIssued(newBillId, originalOwner, bills[newBillId]);
        emit IDiscountBill.BillMerged(
            newBillId,
            originalOwner,
            first.token,
            billIds.length,
            sumPrincipal,
            sumAdjustedRedemption,
            maxMaturity
        );
    }

    function _aggregateBills(uint256[] calldata billIds, uint256 ratePerDayScaled, IDiscountBill.BillInfo memory first)
        internal
        returns (uint256 maxMaturity, uint256 sumPrincipal, uint256 sumAdjustedRedemption)
    {
        maxMaturity = first.maturity;
        for (uint256 i = 0; i < billIds.length; i++) {
            uint256 id = billIds[i];
            IDiscountBill.BillInfo memory b = bills[id];
            if (b.redemptionValue == 0) revert BillInvalid();
            if (ownerOf(id) != msg.sender && !hasRole(OPERATOR_ROLE, msg.sender)) revert NotAuthorized();
            if (isMature(id)) revert AlreadyMature();
            if (billInvalidated[id]) revert BillInvalidated();
            // Series bills cannot be merged -- they have sponsor-specific escheatment rules
            if (billSeries[id] != 0) revert SeriesBillCannotMerge();
            if (b.token != first.token) revert MismatchedField();
            if (b.depositWallet != first.depositWallet) revert MismatchedField();
            if (b.introducingWallet != first.introducingWallet) revert MismatchedField();
            if (b.commissionBps != first.commissionBps) revert MismatchedField();

            // Reject bills with pending early redemption requests
            for (uint256 j = 0; j < billToRequests[id].length; j++) {
                if (earlyRedemptionRequests[billToRequests[id][j]].status == RedemptionStatus.Pending)
                    revert PendingRequestExists();
            }

            {
                uint256 extraDays = (maxMaturity > b.maturity) ? (maxMaturity - b.maturity) / 1 days : 0;
                maxMaturity = Math.max(maxMaturity, b.maturity);

                uint256 adjustedRed = b.redemptionValue;
                if (extraDays > 0 && ratePerDayScaled > 0) {
                    adjustedRed = BillMathLib.applyGrowth(b.redemptionValue, ratePerDayScaled, extraDays);
                }

                sumPrincipal += b.principal;
                sumAdjustedRedemption += adjustedRed;
            }

            _burn(id);
            bills[id].redemptionValue = 0;
            billInvalidated[id] = true;
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Deposit wallet update
    // ════════════════════════════════════════════════════════════════════

    function updateDepositWallet(uint256 billId, address newDepositWallet) external {
        if (ownerOf(billId) != msg.sender) revert NotOwner();
        if (newDepositWallet == address(0)) revert ZeroAddress();
        if (!compliance.isAllowed(newDepositWallet)) revert ComplianceBlocked();

        IDiscountBill.BillInfo storage bill = bills[billId];
        if (bill.redemptionValue == 0) revert BillInvalid();

        address oldWallet = bill.depositWallet;
        bill.depositWallet = newDepositWallet;

        emit DepositWalletUpdated(billId, oldWallet, newDepositWallet);
    }

    // ════════════════════════════════════════════════════════════════════
    // View helpers (needed by this contract)
    // ════════════════════════════════════════════════════════════════════

    function isMature(uint256 billId) public view returns (bool) {
        return block.timestamp >= bills[billId].maturity;
    }

    function ownerOf(uint256 billId) public view override(ERC721Upgradeable) returns (address) {
        return ERC721Upgradeable.ownerOf(billId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(DiscountBillStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ════════════════════════════════════════════════════════════════════
    // Internal: deploy bill token (duplicated from Core — needed for merge)
    // ════════════════════════════════════════════════════════════════════

    function _deployBillToken(
        uint256 billId,
        address token,
        uint256 maturity,
        address receiver,
        uint256 amount
    ) internal returns (address tokenAddress) {
        // Security: always set in try/catch before use
        // slither-disable-next-line uninitialized-local
        uint8 decimals_;
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            decimals_ = dec;
        } catch {
            decimals_ = 18;
        }
        tokenAddress = billTokenFactory.deployBillToken(
            address(this), billId, token, maturity, decimals_, receiver, amount
        );
    }

}
