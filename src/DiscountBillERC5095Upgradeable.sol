// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IComplianceRegistry.sol";
import "./interfaces/ITravelRuleRegistry.sol";
import "./interfaces/IDiscountBill.sol";
import "./interfaces/IERC5095.sol";
import "./interfaces/ITreasury.sol";
import {BillMathLib} from "./libraries/BillMathLib.sol";
import {BillTokenFactory} from "./BillTokenFactory.sol";

contract DiscountBillERC5095Upgradeable is Initializable, ERC721Upgradeable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable, ReentrancyGuard, IDiscountBill {
    using SafeERC20 for IERC20;

    // Custom errors (saves ~2KB vs string reverts)
    error ZeroAddress();
    error NotOwner();
    error NotAuthorized();
    error NotMature();
    error AlreadyMature();
    error BillInvalid();
    error BillInvalidated();
    error InvalidAmount();
    error InvalidRate();
    error InvalidDuration();
    error ExceedsDepositCap();
    error ExceedsValue();
    error NotBillToken();
    error FeeExceedsMax();
    error PendingRequestExists();
    error InvalidRequest();
    error NotPending();
    error NotRequester();
    error InsufficientBalance();
    error NeedTwoBills();
    error MismatchedField();
    error ComplianceBlocked();
    error TravelRuleBlocked();

    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    IComplianceRegistry public compliance;
    ITravelRuleRegistry public travel;
    address public issuer;
    ITreasury public treasury;

    uint256 public nextBillId;

    mapping(uint256 => BillInfo) public bills;

    uint256 public commissionBps;
    uint256 public constant MAX_COMMISSION_BPS = 5000; // 50%

    event Defaulted(uint256 indexed billId);

    event BillTokenCreated(uint256 indexed billId, address token);

    // Early redemption events
    event EarlyRedemptionRequested(uint256 indexed requestId, uint256 indexed billId, address indexed requester, uint256 amount, bool isPartial);
    event EarlyRedemptionApproved(uint256 indexed requestId, uint256 payout);
    event EarlyRedemptionRejected(uint256 indexed requestId, string reason);
    event BreakFeeUpdated(address indexed token, uint256 newFeeBps);
    event DepositWalletUpdated(uint256 indexed billId, address indexed oldWallet, address indexed newWallet);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ComplianceRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    mapping(uint256 => address) public billTokens;

    // Early redemption structures
    enum RedemptionStatus { Pending, Approved, Rejected, Executed }

    struct EarlyRedemptionRequest {
        uint256 billId;
        address requester;
        uint256 requestedAt;
        uint256 amount;           // Amount to redeem (full bill value if !isPartial)
        bool isPartial;
        uint256 breakFee;         // Calculated break fee
        uint256 accruedInterest;  // Pro-rata interest earned
        uint256 payoutAmount;     // Net amount after fees
        RedemptionStatus status;
    }

    // Break fee configuration per token (basis points, e.g., 500 = 5%)
    mapping(address => uint256) public breakFeeBps;
    uint256 public defaultBreakFeeBps;
    uint256 public constant MAX_BREAK_FEE_BPS = 2000; // Max 20%

    // Early redemption requests
    EarlyRedemptionRequest[] internal earlyRedemptionRequests;
    mapping(uint256 => uint256[]) internal billToRequests; // billId => requestIds
    mapping(uint256 => bool) public billInvalidated;

    // Bill token factory — deploys ERC5095 bill tokens without embedding creation code
    BillTokenFactory public billTokenFactory;

    /// @notice Per-token deposit cap (0 = no limit)
    mapping(address => uint256) public maxDepositAmount;

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
        emit MaxDepositAmountSet(token, amount);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

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
        if (depositor == address(0)) revert ZeroAddress();
        if (depositWallet == address(0)) revert ZeroAddress();
        if (token == address(0)) revert ZeroAddress();
        if (principal == 0) revert InvalidAmount();
        if (annualRateBps > 100_000 || annualRateBps < 1) revert InvalidRate();
        if (durationInDays == 0 || durationInDays > 365 * 5) revert InvalidDuration();

        uint256 cap = maxDepositAmount[token];
        if (cap != 0 && principal > cap) revert ExceedsDepositCap();

        uint256 maturity = block.timestamp + durationInDays * 1 days;
        (uint256 finalAmount, uint256 commission) =
            BillMathLib.calculateTerms(principal, annualRateBps, durationInDays, commissionBps);

        _enforceComplianceAndTravel(token, depositor, issuer, principal);

        billId = nextBillId++;

        bills[billId] = BillInfo({
            token: token,
            issuance: block.timestamp,
            maturity: maturity,
            principal: principal,
            redemptionValue: finalAmount,
            commissionBps: commissionBps,
            commissionAmount: commission,
            depositor: depositor,
            depositWallet: depositWallet,
            introducingWallet: introducingWallet
        });

        if (address(treasury) != address(0)) {
            // Security: depositor is set by OPERATOR_ROLE, not user input
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(token).safeTransferFrom(depositor, address(treasury), principal);
            treasury.recordDeposit(token, principal, finalAmount, maturity);
        } else {
            // Security: depositor is set by OPERATOR_ROLE, not user input
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(token).safeTransferFrom(depositor, issuer, principal);
        }

        _safeMint(owner, billId);
        billTokens[billId] = _deployBillToken(billId, token, maturity, owner, finalAmount);
        emit BillTokenCreated(billId, billTokens[billId]);
        emit BillIssued(billId, owner, bills[billId]);
    }

    function redeem(uint256 billId) external nonReentrant {
        if (!isMature(billId)) revert NotMature();
        if (ownerOf(billId) != msg.sender) revert NotOwner();

        BillInfo memory bill = bills[billId];
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

    // ========== EARLY REDEMPTION FUNCTIONS ==========

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

    function requestEarlyRedemption(
        uint256 billId,
        bool isPartial,
        uint256 amount
    ) external returns (uint256 requestId) {
        if (ownerOf(billId) != msg.sender) revert NotOwner();
        BillInfo memory bill = bills[billId];
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
        BillInfo memory bill = bills[billId];
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

        BillInfo storage bill = bills[request.billId];
        if (bill.redemptionValue == 0) revert BillInvalid();

        // Verify requester still owns the bill
        if (ownerOf(request.billId) != request.requester) revert NotOwner();

        request.status = RedemptionStatus.Approved;

        // Process the payout
        if (address(treasury) != address(0)) {
            _enforceComplianceAndTravel(bill.token, address(treasury), bill.depositWallet, request.payoutAmount);
            treasury.withdrawForRedemption(bill.token, request.payoutAmount, bill.depositWallet);
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

    // ========== BILL MERGING ==========

    // Security: protected by nonReentrant modifier
    // slither-disable-next-line reentrancy-no-eth
    function merge(
        uint256[] calldata billIds,
        uint256 rolloverAnnualRateBps
    ) external nonReentrant whenNotPaused returns (uint256 newBillId) {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && ownerOf(billIds[0]) != msg.sender) revert NotAuthorized();
        if (billIds.length < 2) revert NeedTwoBills();

        address originalOwner = ownerOf(billIds[0]);
        BillInfo memory first = bills[billIds[0]];
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
        bills[newBillId] = BillInfo({
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
        emit BillIssued(newBillId, originalOwner, bills[newBillId]);
        emit BillMerged(
            newBillId,
            originalOwner,
            first.token,
            billIds.length,
            sumPrincipal,
            sumAdjustedRedemption,
            maxMaturity
        );
    }

    function _aggregateBills(uint256[] calldata billIds, uint256 ratePerDayScaled, BillInfo memory first)
        internal
        returns (uint256 maxMaturity, uint256 sumPrincipal, uint256 sumAdjustedRedemption)
    {
        maxMaturity = first.maturity;
        for (uint256 i = 0; i < billIds.length; i++) {
            uint256 id = billIds[i];
            BillInfo memory b = bills[id];
            if (b.redemptionValue == 0) revert BillInvalid();
            if (ownerOf(id) != msg.sender && !hasRole(OPERATOR_ROLE, msg.sender)) revert NotAuthorized();
            if (isMature(id)) revert AlreadyMature();
            if (billInvalidated[id]) revert BillInvalidated();
            if (b.token != first.token) revert MismatchedField();
            if (b.depositWallet != first.depositWallet) revert MismatchedField();
            if (b.introducingWallet != first.introducingWallet) revert MismatchedField();
            if (b.commissionBps != first.commissionBps) revert MismatchedField();

            // Reject bills with pending early redemption requests
            uint256[] memory requests = billToRequests[id];
            for (uint256 j = 0; j < requests.length; j++) {
                if (earlyRedemptionRequests[requests[j]].status == RedemptionStatus.Pending)
                    revert PendingRequestExists();
            }

            uint256 extraDays = (maxMaturity > b.maturity) ? (maxMaturity - b.maturity) / 1 days : 0;
            maxMaturity = Math.max(maxMaturity, b.maturity);

            uint256 adjustedRed = b.redemptionValue;
            if (extraDays > 0 && ratePerDayScaled > 0) {
                adjustedRed = BillMathLib.applyGrowth(b.redemptionValue, ratePerDayScaled, extraDays);
            }

            sumPrincipal += b.principal;
            sumAdjustedRedemption += adjustedRed;

            _burn(id);
            bills[id].redemptionValue = 0;
            billInvalidated[id] = true;
        }
    }

    // ========== DEPOSIT WALLET UPDATE ==========

    function updateDepositWallet(uint256 billId, address newDepositWallet) external {
        if (ownerOf(billId) != msg.sender) revert NotOwner();
        if (newDepositWallet == address(0)) revert ZeroAddress();
        if (!compliance.isAllowed(newDepositWallet)) revert ComplianceBlocked();

        BillInfo storage bill = bills[billId];
        if (bill.redemptionValue == 0) revert BillInvalid();

        address oldWallet = bill.depositWallet;
        bill.depositWallet = newDepositWallet;

        emit DepositWalletUpdated(billId, oldWallet, newDepositWallet);
    }

    function getBillInfo(uint256 billId) external view returns (BillInfo memory) {
        return bills[billId];
    }

    function redeemableValue(uint256 billId) external view returns (uint256) {
        return bills[billId].redemptionValue;
    }

    function previewRedeem(uint256 billId, uint256 amount) external view returns (uint256) {
        BillInfo memory bill = bills[billId];
        if (amount > bill.redemptionValue) revert ExceedsValue();
        if (bill.redemptionValue == 0) return 0;
        uint256 commission = bill.commissionAmount > 0
            ? Math.mulDiv(bill.commissionAmount, amount, bill.redemptionValue)
            : 0;
        return amount - commission;
    }

    function canRedeem(uint256 billId, uint256 amount) external view returns (bool) {
        BillInfo memory bill = bills[billId];
        if (block.timestamp < bill.maturity || amount == 0 || amount > bill.redemptionValue) return false;
        if (address(treasury) != address(0)) return true;
        return IERC20(bill.token).balanceOf(issuer) >= amount;
    }

    function isMature(uint256 billId) public view returns (bool) {
        return block.timestamp >= bills[billId].maturity;
    }

    function ownerOf(uint256 billId) public view override(ERC721Upgradeable, IDiscountBill) returns (address) {
        return ERC721Upgradeable.ownerOf(billId);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable)
        returns (address previousOwner)
    {
        previousOwner = super._update(to, tokenId, auth);
        emit BillTransferred(tokenId, previousOwner, to);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
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

    function _enforceComplianceAndTravel(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal view {
        if (!compliance.isAllowed(to)) revert ComplianceBlocked();
        if (!travel.isCompliant(token, from, to, amount)) revert TravelRuleBlocked();
    }

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
        BillInfo storage bill = bills[billId];
        if (amount > bill.redemptionValue) revert ExceedsValue();

        address fundSource = address(treasury) != address(0) ? address(treasury) : issuer;

        if (address(treasury) == address(0)) {
            if (IERC20(bill.token).balanceOf(issuer) < amount) {
                emit Defaulted(billId);
                return 0;
            }
        }

        uint256 startingRedemption = bill.redemptionValue;
        uint256 commission =
            bill.commissionAmount > 0 ? Math.mulDiv(bill.commissionAmount, amount, startingRedemption) : 0;
        netPayment = amount - commission;

        _enforceComplianceAndTravel(bill.token, fundSource, payoutTarget, netPayment);

        // Update bill state BEFORE external calls
        bill.redemptionValue = startingRedemption - amount;
        if (bill.commissionAmount >= commission) {
            bill.commissionAmount -= commission;
        } else {
            bill.commissionAmount = 0;
        }

        if (startingRedemption > 0 && bill.redemptionValue > 0) {
            bill.principal = Math.mulDiv(bill.principal, bill.redemptionValue, startingRedemption);
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
                treasury.withdrawForRedemption(bill.token, commission, bill.introducingWallet);
                travel.consume(bill.token, address(treasury), bill.introducingWallet, commission);
            }
            treasury.withdrawForRedemption(bill.token, netPayment, payoutTarget);
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

        emit BillRedeemed(billId, redeemer, amount);
    }

    /// @dev Reserved storage space for future upgrades
    uint256[38] private __gap;
}
