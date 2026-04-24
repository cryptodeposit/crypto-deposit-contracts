// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./DiscountBillStorage.sol";
import "./interfaces/IDiscountBill.sol";
import "./interfaces/IERC5095.sol";
import {BillMathLib} from "./libraries/BillMathLib.sol";

/**
 * @title DiscountBillCore
 * @notice The UUPS proxy implementation for the DiscountBill system.
 * @dev Contains initialize, upgrade auth, issue/redeem, admin setters, and
 *      a fallback that routes unknown selectors to Lifecycle or Campaigns
 *      extension contracts via delegatecall.
 *
 *      Storage layout is inherited from DiscountBillStorage (shared with extensions).
 */
contract DiscountBillCore is DiscountBillStorage, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address issuer_,
        IComplianceRegistry compliance_,
        ITravelRuleRegistry travel_
    ) public initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        if (issuer_ == address(0)) revert ZeroAddress();
        if (address(compliance_) == address(0)) revert ZeroAddress();
        if (address(travel_) == address(0)) revert ZeroAddress();

        __ERC721_init("DiscountBill", "DBILL");
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ISSUER_ROLE, issuer_);
        _grantRole(OPERATOR_ROLE, admin_);
        _grantRole(UPGRADER_ROLE, admin_);

        issuer = issuer_;
        compliance = compliance_;
        travel = travel_;
        commissionBps = 1500; // 15%
        nextBillId = 1;
        defaultBreakFeeBps = 500; // 5% default break fee
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ════════════════════════════════════════════════════════════════════
    // Admin setters
    // ════════════════════════════════════════════════════════════════════

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        address old = address(treasury);
        treasury = ITreasury(treasury_);
        emit TreasuryUpdated(old, treasury_);
    }

    function setComplianceRegistry(address compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (compliance_ == address(0)) revert ZeroAddress();
        address old = address(compliance);
        compliance = IComplianceRegistry(compliance_);
        emit ComplianceRegistryUpdated(old, compliance_);
    }

    function setBillTokenFactory(address factory_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (factory_ == address(0)) revert ZeroAddress();
        billTokenFactory = BillTokenFactory(factory_);
    }

    function setMaxDepositAmount(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxDepositAmount[token] = amount;
        emit IDiscountBill.MaxDepositAmountSet(token, amount);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ════════════════════════════════════════════════════════════════════
    // Extension address management
    // ════════════════════════════════════════════════════════════════════

    function setLifecycleImpl(address impl_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (impl_ == address(0)) revert ZeroAddress();
        lifecycleImpl = impl_;
    }

    function setCampaignsImpl(address impl_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (impl_ == address(0)) revert ZeroAddress();
        campaignsImpl = impl_;
    }

    // ════════════════════════════════════════════════════════════════════
    // Issue / Redeem
    // ════════════════════════════════════════════════════════════════════

    function issue(
        address owner,
        address depositor,
        address depositWallet,
        address introducingWallet,
        address token,
        uint256 principal,
        uint256 annualRateBps,
        uint256 durationInDays
    ) external onlyRole(OPERATOR_ROLE) nonReentrant whenNotPaused returns (uint256 billId) {
        billId = _issueInternal(owner, depositor, depositWallet, introducingWallet, token, principal, annualRateBps, durationInDays);
    }

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

    function redeem(uint256 billId) external nonReentrant {
        if (!isMature(billId)) revert NotMature();
        if (ownerOf(billId) != msg.sender) revert NotOwner();

        IDiscountBill.BillInfo memory bill = bills[billId];
        if (bill.redemptionValue == 0) revert BillInvalid();

        _processRedemption(billId, bill.redemptionValue, bill.depositWallet, msg.sender, true);
        billInvalidated[billId] = true;
    }

    function redeemViaToken(uint256 billId, uint256 amount, address receiver, address redeemer)
        external
        nonReentrant
        returns (uint256 netPayment)
    {
        if (billInvalidated[billId]) revert BillInvalidated();
        if (msg.sender != billTokens[billId]) revert NotBillToken();
        if (!isMature(billId)) revert NotMature();
        if (amount == 0) revert InvalidAmount();

        netPayment = _processRedemption(billId, amount, receiver, redeemer, false);
    }

    // ════════════════════════════════════════════════════════════════════
    // View functions
    // ════════════════════════════════════════════════════════════════════

    function getBillInfo(uint256 billId) external view returns (IDiscountBill.BillInfo memory) {
        return bills[billId];
    }

    function redeemableValue(uint256 billId) external view returns (uint256) {
        return bills[billId].redemptionValue;
    }

    function previewRedeem(uint256 billId, uint256 amount) external view returns (uint256) {
        IDiscountBill.BillInfo memory bill = bills[billId];
        if (amount > bill.redemptionValue) revert ExceedsValue();
        if (bill.redemptionValue == 0) return 0;
        uint256 commission = bill.commissionAmount > 0
            ? Math.mulDiv(bill.commissionAmount, amount, bill.redemptionValue)
            : 0;
        return amount - commission;
    }

    function canRedeem(uint256 billId, uint256 amount) external view returns (bool) {
        IDiscountBill.BillInfo memory bill = bills[billId];
        if (block.timestamp < bill.maturity || amount == 0 || amount > bill.redemptionValue) return false;
        if (address(treasury) != address(0)) return true;
        return IERC20(bill.token).balanceOf(issuer) >= amount;
    }

    function isMature(uint256 billId) public view returns (bool) {
        return block.timestamp >= bills[billId].maturity;
    }

    function ownerOf(uint256 billId) public view override(ERC721Upgradeable) returns (address) {
        return ERC721Upgradeable.ownerOf(billId);
    }

    function complianceRegistry() external view returns (IComplianceRegistry) {
        return compliance;
    }

    function travelRuleRegistry() external view returns (ITravelRuleRegistry) {
        return travel;
    }

    function commissionRateBps() external view returns (uint256) {
        return commissionBps;
    }

    // ════════════════════════════════════════════════════════════════════
    // ERC-721 overrides
    // ════════════════════════════════════════════════════════════════════

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable)
        returns (address previousOwner)
    {
        previousOwner = super._update(to, tokenId, auth);
        emit IDiscountBill.BillTransferred(tokenId, previousOwner, to);
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
    // NFT Metadata
    // ════════════════════════════════════════════════════════════════════

    /// @notice Set the base URI for token metadata. tokenURI(id) = baseURI + id.
    function setBaseURI(string calldata baseURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCustomBaseURI(baseURI_);
    }

    /// @dev Override ERC721 _baseURI to return the custom base URI
    function _baseURI() internal view override returns (string memory) {
        return _customBaseURIValue();
    }

    /// @notice Collection-level metadata (OpenSea, wallets, marketplaces)
    function contractURI() external view returns (string memory) {
        return _customContractURIValue();
    }

    /// @notice Set the contract-level metadata URI
    function setContractURI(string calldata contractURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCustomContractURI(contractURI_);
    }

    // ════════════════════════════════════════════════════════════════════
    // Internal helpers
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

    function _processRedemption(
        uint256 billId,
        uint256 amount,
        address payoutTarget,
        address redeemer,
        bool burnNft
    ) internal returns (uint256 netPayment) {
        IDiscountBill.BillInfo storage bill = bills[billId];
        if (amount > bill.redemptionValue) revert ExceedsValue();

        address fundSource = address(treasury) != address(0) ? address(treasury) : issuer;

        if (address(treasury) == address(0)) {
            if (IERC20(bill.token).balanceOf(issuer) < amount) {
                emit Defaulted(billId);
                return 0;
            }
        }

        uint256 startingRedemption = bill.redemptionValue;
        uint256 startingPrincipal = bill.principal;
        uint256 commission =
            bill.commissionAmount > 0 ? Math.mulDiv(bill.commissionAmount, amount, startingRedemption) : 0;
        netPayment = amount - commission;

        // Pro-rata principal being redeemed (for correct depositClaims accounting)
        uint256 principalRedeemed = startingRedemption > 0
            ? Math.mulDiv(startingPrincipal, amount, startingRedemption)
            : 0;

        _enforceComplianceAndTravel(bill.token, fundSource, payoutTarget, netPayment);

        // Update bill state BEFORE external calls
        bill.redemptionValue = startingRedemption - amount;
        if (bill.commissionAmount >= commission) {
            bill.commissionAmount -= commission;
        } else {
            bill.commissionAmount = 0;
        }

        if (startingRedemption > 0 && bill.redemptionValue > 0) {
            bill.principal = Math.mulDiv(startingPrincipal, bill.redemptionValue, startingRedemption);
        } else if (bill.redemptionValue == 0) {
            bill.principal = 0;
        }

        if (burnNft && bill.redemptionValue == 0) {
            _burn(billId);
        }

        // External calls AFTER state updates
        if (address(treasury) != address(0)) {
            if (
                commission > 0 &&
                bill.introducingWallet != address(0) &&
                compliance.isAllowed(bill.introducingWallet) &&
                travel.isCompliant(bill.token, address(treasury), bill.introducingWallet, commission)
            ) {
                // Commission is pure interest -- principalPortion = 0
                treasury.withdrawForRedemption(bill.token, commission, 0, bill.maturity, bill.introducingWallet);
                travel.consume(bill.token, address(treasury), bill.introducingWallet, commission);
            }
            // Net payment carries the full pro-rata principal
            treasury.withdrawForRedemption(bill.token, netPayment, principalRedeemed, bill.maturity, payoutTarget);
            travel.consume(bill.token, address(treasury), payoutTarget, netPayment);
        } else {
            IERC20 erc20 = IERC20(bill.token);
            if (
                commission > 0 &&
                bill.introducingWallet != address(0) &&
                compliance.isAllowed(bill.introducingWallet) &&
                travel.isCompliant(bill.token, issuer, bill.introducingWallet, commission)
            ) {
                // Security: issuer is a trusted state variable set at initialization, not arbitrary
                // slither-disable-next-line arbitrary-send-erc20
                erc20.safeTransferFrom(issuer, bill.introducingWallet, commission);
                travel.consume(bill.token, issuer, bill.introducingWallet, commission);
            }
            // Security: issuer is a trusted state variable set at initialization, not arbitrary
            // slither-disable-next-line arbitrary-send-erc20
            erc20.safeTransferFrom(issuer, payoutTarget, netPayment);
            travel.consume(bill.token, issuer, payoutTarget, netPayment);
        }

        emit IDiscountBill.BillRedeemed(billId, redeemer, amount);
    }

    // ════════════════════════════════════════════════════════════════════
    // Fallback — routes to Lifecycle or Campaigns via delegatecall
    // ════════════════════════════════════════════════════════════════════

    fallback() external payable {
        address impl;
        bytes4 sig = msg.sig;

        // ── Lifecycle selectors ──
        if (
            sig == bytes4(keccak256("setBreakFee(address,uint256)")) ||
            sig == bytes4(keccak256("getBreakFee(address)")) ||
            sig == bytes4(keccak256("requestEarlyRedemption(uint256,bool,uint256)")) ||
            sig == bytes4(keccak256("previewEarlyRedemption(uint256,bool,uint256)")) ||
            sig == bytes4(keccak256("approveEarlyRedemption(uint256)")) ||
            sig == bytes4(keccak256("rejectEarlyRedemption(uint256,string)")) ||
            sig == bytes4(keccak256("cancelEarlyRedemption(uint256)")) ||
            sig == bytes4(keccak256("getEarlyRedemptionRequest(uint256)")) ||
            sig == bytes4(keccak256("getBillRequests(uint256)")) ||
            sig == bytes4(keccak256("merge(uint256[],uint256)")) ||
            sig == bytes4(keccak256("updateDepositWallet(uint256,address)"))
        ) {
            impl = lifecycleImpl;
        }
        // ── Campaigns selectors ──
        else if (
            sig == bytes4(keccak256("setDefaultClaimWindow(uint256)")) ||
            sig == bytes4(keccak256("setBillClaimDeadline(uint256,uint256)")) ||
            sig == bytes4(keccak256("getClaimDeadline(uint256)")) ||
            sig == bytes4(keccak256("isExpired(uint256)")) ||
            sig == bytes4(keccak256("burnExpired(uint256)")) ||
            sig == bytes4(keccak256("batchBurnExpired(uint256[])")) ||
            sig == bytes4(keccak256("createSeries(string,address,uint256,uint256,uint256,uint256,uint256,address)")) ||
            sig == bytes4(keccak256("deactivateSeries(uint256)")) ||
            sig == bytes4(keccak256("issueFromSeries(uint256,address,address,address,address)")) ||
            sig == bytes4(keccak256("getSeriesInfo(uint256)")) ||
            sig == bytes4(keccak256("seriesCount()"))
        ) {
            impl = campaignsImpl;
        }
        else {
            revert("unknown selector");
        }

        require(impl != address(0), "extension not set");

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
