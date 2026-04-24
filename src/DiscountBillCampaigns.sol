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
 * @title DiscountBillCampaigns
 * @notice Extension for escheatment (unclaimed bill expiry) and bill series (airdrop campaigns).
 * @dev Called via delegatecall from DiscountBillCore's fallback(). Shares the SAME storage
 *      layout via DiscountBillStorage inheritance. Does NOT inherit UUPSUpgradeable.
 *
 *      CRITICAL: Storage layout must remain identical to DiscountBillCore.
 *
 *      issueFromSeries() duplicates _issueInternal() from Core. This is intentional —
 *      since Campaigns runs via delegatecall in Core's context, it writes to Core's storage
 *      directly. Duplicating the ~50 lines avoids cross-contract call complexity.
 */
contract DiscountBillCampaigns is DiscountBillStorage {
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════
    // Escheatment — unclaimed bill expiry and return to treasury
    // ════════════════════════════════════════════════════════════════════

    /// @notice Set the default claim window for standard deposits (admin only)
    /// @param window Duration in seconds after maturity. Minimum 30 days.
    function setDefaultClaimWindow(uint256 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (window != 0 && window < 30 days) revert InvalidClaimWindow();
        uint256 old = defaultClaimWindow;
        defaultClaimWindow = window;
        // Record when the window was first enabled — legacy bills (issued before this)
        // are not subject to the default window (prevents retroactive escheatment).
        if (window != 0 && claimWindowEffectiveFrom == 0) {
            claimWindowEffectiveFrom = block.timestamp;
        }
        emit DefaultClaimWindowUpdated(old, window);
    }

    /// @notice Override the claim deadline for a specific bill (operator/admin)
    /// @param billId The bill to override
    /// @param deadline Absolute timestamp. Must be >= bill maturity + 30 days, or 0 to reset to default.
    function setBillClaimDeadline(uint256 billId, uint256 deadline) external onlyRole(OPERATOR_ROLE) {
        IDiscountBill.BillInfo memory b = bills[billId];
        if (b.redemptionValue == 0) revert BillInvalid();
        if (deadline != 0 && deadline < b.maturity + 30 days) revert InvalidClaimWindow();
        claimDeadline[billId] = deadline;
        emit BillClaimDeadlineSet(billId, deadline);
    }

    /// @notice Get the effective claim deadline for a bill
    function getClaimDeadline(uint256 billId) public view returns (uint256) {
        uint256 explicit = claimDeadline[billId];
        if (explicit != 0) return explicit;
        IDiscountBill.BillInfo memory b = bills[billId];
        if (b.maturity == 0) return 0;
        uint256 window = defaultClaimWindow;
        if (window == 0) return 0; // No escheatment configured
        // Don't apply default window retroactively to bills issued before it was configured
        if (claimWindowEffectiveFrom != 0 && b.issuance < claimWindowEffectiveFrom) return 0;
        return b.maturity + window;
    }

    /// @notice Check if a bill is expired (past claim deadline and unredeemed)
    function isExpired(uint256 billId) public view returns (bool) {
        uint256 deadline = getClaimDeadline(billId);
        if (deadline == 0) return false; // No escheatment
        IDiscountBill.BillInfo memory b = bills[billId];
        if (b.redemptionValue == 0) return false; // Already redeemed or burned
        return block.timestamp > deadline;
    }

    /// @notice Burn an expired unclaimed bill and return funds to treasury/issuer
    function burnExpired(uint256 billId) external onlyRole(OPERATOR_ROLE) nonReentrant {
        _burnExpiredSingle(billId);
    }

    /// @notice Batch burn multiple expired bills
    function batchBurnExpired(uint256[] calldata billIds) external onlyRole(OPERATOR_ROLE) nonReentrant {
        for (uint256 i = 0; i < billIds.length; i++) {
            _burnExpiredSingle(billIds[i]);
        }
    }

    function _burnExpiredSingle(uint256 billId) internal {
        if (!isExpired(billId)) revert NotExpired();
        IDiscountBill.BillInfo storage b = bills[billId];
        if (b.redemptionValue == 0) revert AlreadyRedeemed();

        address lastOwner = ownerOf(billId);
        uint256 expiredLiability = b.redemptionValue;
        uint256 expiredPrincipal = b.principal;
        uint256 expiredMaturity = b.maturity;
        address tokenAddr = b.token;

        // Determine return destination
        address returnTo;
        uint256 sid = billSeries[billId];
        if (sid != 0 && seriesRegistry[sid - 1].fundingSource != address(0)) {
            returnTo = seriesRegistry[sid - 1].fundingSource;
        } else if (address(treasury) != address(0)) {
            returnTo = address(treasury);
        } else {
            returnTo = issuer;
        }

        // Clear bill state before external calls
        b.redemptionValue = 0;
        b.principal = 0;
        billInvalidated[billId] = true;
        _burn(billId);

        uint256 principalReturned = 0;

        if (address(treasury) != address(0)) {
            // Step 1: Always write off the full deposit accounting.
            treasury.writeOffExpiredDeposit(tokenAddr, expiredPrincipal, expiredLiability, expiredMaturity);

            if (returnTo != address(treasury)) {
                // Step 2: Transfer the principal to external destination.
                _enforceComplianceAndTravel(tokenAddr, address(treasury), returnTo, expiredPrincipal);
                treasury.disburseExpiredFunds(tokenAddr, expiredPrincipal, returnTo);
                travel.consume(tokenAddr, address(treasury), returnTo, expiredPrincipal);
                principalReturned = expiredPrincipal;
            }
            // If returnTo == treasury: ownedCapital holds the principal, no cash moved.
        } else {
            // No treasury mode: funds are with issuer.
            if (returnTo != issuer) {
                _enforceComplianceAndTravel(tokenAddr, issuer, returnTo, expiredPrincipal);
                // slither-disable-next-line arbitrary-send-erc20
                IERC20(tokenAddr).safeTransferFrom(issuer, returnTo, expiredPrincipal);
                travel.consume(tokenAddr, issuer, returnTo, expiredPrincipal);
                principalReturned = expiredPrincipal;
            }
            // If returnTo == issuer, funds already there -- no transfer needed
        }

        emit BillExpiredAndBurned(billId, lastOwner, expiredLiability, principalReturned, returnTo);
    }

    // ════════════════════════════════════════════════════════════════════
    // Bill Series — airdrop campaigns with custom parameters
    // ════════════════════════════════════════════════════════════════════

    /// @notice Create a new bill series (airdrop campaign)
    /// @return seriesId The 1-based series ID
    function createSeries(
        string calldata name_,
        address token_,
        uint256 principalPerBill_,
        uint256 annualRateBps_,
        uint256 durationInDays_,
        uint256 claimWindowDays_,
        uint256 maxBills_,
        address fundingSource_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 seriesId) {
        if (token_ == address(0)) revert ZeroAddress();
        if (principalPerBill_ == 0) revert InvalidAmount();
        if (annualRateBps_ > 100_000 || annualRateBps_ < 1) revert InvalidRate();
        if (durationInDays_ == 0 || durationInDays_ > 365 * 5) revert InvalidDuration();
        if (claimWindowDays_ < 30) revert InvalidClaimWindow();

        seriesRegistry.push(BillSeries({
            name: name_,
            token: token_,
            principalPerBill: principalPerBill_,
            annualRateBps: annualRateBps_,
            durationInDays: durationInDays_,
            claimWindowDays: claimWindowDays_,
            maxBills: maxBills_,
            issuedCount: 0,
            fundingSource: fundingSource_,
            active: true
        }));

        seriesId = seriesRegistry.length; // 1-based
        if (nextSeriesId < seriesId) nextSeriesId = seriesId;

        emit SeriesCreated(seriesId, name_, token_, principalPerBill_, maxBills_);
    }

    /// @notice Deactivate a series (no more bills can be issued from it)
    function deactivateSeries(uint256 seriesId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (seriesId == 0 || seriesId > seriesRegistry.length) revert SeriesNotFound();
        seriesRegistry[seriesId - 1].active = false;
        emit SeriesDeactivated(seriesId);
    }

    /// @notice Issue a bill from a series (airdrop). Uses series parameters, caller provides recipient.
    /// @param seriesId 1-based series ID
    /// @param recipient Address that will own the bill NFT
    /// @param depositor_ Address that funds the bill (must have approved tokens)
    /// @param depositWallet_ Address that receives redemption payout
    function issueFromSeries(
        uint256 seriesId,
        address recipient,
        address depositor_,
        address depositWallet_,
        address introducingWallet_
    ) external onlyRole(OPERATOR_ROLE) nonReentrant whenNotPaused returns (uint256 billId) {
        if (seriesId == 0 || seriesId > seriesRegistry.length) revert SeriesNotFound();
        BillSeries storage s = seriesRegistry[seriesId - 1];
        if (!s.active) revert SeriesNotFound();
        if (s.maxBills != 0 && s.issuedCount >= s.maxBills) revert SeriesExhausted();
        if (recipient == address(0)) revert ZeroAddress();
        if (depositor_ == address(0)) revert ZeroAddress();
        if (depositWallet_ == address(0)) revert ZeroAddress();

        s.issuedCount++;

        // Issue using duplicated _issueInternal logic
        billId = _issueInternal(
            recipient, depositor_, depositWallet_, introducingWallet_,
            s.token, s.principalPerBill, s.annualRateBps, s.durationInDays
        );

        // Tag bill to this series and set claim deadline
        billSeries[billId] = seriesId;
        claimDeadline[billId] = bills[billId].maturity + (s.claimWindowDays * 1 days);

        emit SeriesBillIssued(seriesId, billId, recipient);
    }

    /// @notice Get series info
    function getSeriesInfo(uint256 seriesId) external view returns (BillSeries memory) {
        if (seriesId == 0 || seriesId > seriesRegistry.length) revert SeriesNotFound();
        return seriesRegistry[seriesId - 1];
    }

    /// @notice Get total number of series
    function seriesCount() external view returns (uint256) {
        return seriesRegistry.length;
    }

    // ════════════════════════════════════════════════════════════════════
    // Internal: _issueInternal (duplicated from Core)
    // ════════════════════════════════════════════════════════════════════

    /// @dev Duplicated from DiscountBillCore. This is intentional -- Campaigns runs via
    ///      delegatecall in Core's context, so it writes to Core's storage directly.
    ///      Duplicating avoids cross-contract call complexity.
    function _issueInternal(
        address owner_,
        address depositor_,
        address depositWallet_,
        address introducingWallet_,
        address token_,
        uint256 principal_,
        uint256 annualRateBps_,
        uint256 durationInDays_
    ) internal returns (uint256 billId) {
        if (depositor_ == address(0)) revert ZeroAddress();
        if (depositWallet_ == address(0)) revert ZeroAddress();
        if (token_ == address(0)) revert ZeroAddress();
        if (principal_ == 0) revert InvalidAmount();
        if (annualRateBps_ > 100_000 || annualRateBps_ < 1) revert InvalidRate();
        if (durationInDays_ == 0 || durationInDays_ > 365 * 5) revert InvalidDuration();

        uint256 cap = maxDepositAmount[token_];
        if (cap != 0 && principal_ > cap) revert ExceedsDepositCap();

        uint256 maturity = block.timestamp + durationInDays_ * 1 days;
        (uint256 finalAmount, uint256 commission) =
            BillMathLib.calculateTerms(principal_, annualRateBps_, durationInDays_, commissionBps);

        _enforceComplianceAndTravel(token_, depositor_, issuer, principal_);

        billId = nextBillId++;

        bills[billId] = IDiscountBill.BillInfo({
            token: token_,
            issuance: block.timestamp,
            maturity: maturity,
            principal: principal_,
            redemptionValue: finalAmount,
            commissionBps: commissionBps,
            commissionAmount: commission,
            depositor: depositor_,
            depositWallet: depositWallet_,
            introducingWallet: introducingWallet_
        });

        if (address(treasury) != address(0)) {
            // Security: depositor is set by OPERATOR_ROLE, not user input
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(token_).safeTransferFrom(depositor_, address(treasury), principal_);
            treasury.recordDeposit(token_, principal_, finalAmount, maturity);
        } else {
            // Security: depositor is set by OPERATOR_ROLE, not user input
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(token_).safeTransferFrom(depositor_, issuer, principal_);
        }

        // Set claim deadline if default window is configured
        if (defaultClaimWindow != 0) {
            claimDeadline[billId] = maturity + defaultClaimWindow;
        }

        _safeMint(owner_, billId);
        billTokens[billId] = _deployBillToken(billId, token_, maturity, owner_, finalAmount);
        emit BillTokenCreated(billId, billTokens[billId]);
        emit IDiscountBill.BillIssued(billId, owner_, bills[billId]);
    }

    // ════════════════════════════════════════════════════════════════════
    // Internal: deploy bill token (duplicated from Core)
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

}
