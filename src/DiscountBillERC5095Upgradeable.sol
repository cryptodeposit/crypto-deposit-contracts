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
    error NotExpired();
    error AlreadyRedeemed();
    error SeriesBillCannotMerge();
    error InvalidClaimWindow();
    error SeriesNotFound();
    error SeriesExhausted();

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

    // Escheatment events
    event BillExpiredAndBurned(uint256 indexed billId, address indexed lastOwner, uint256 liability, uint256 principalReturned, address returnedTo);
    event DefaultClaimWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event BillClaimDeadlineSet(uint256 indexed billId, uint256 deadline);

    // Series events
    event SeriesCreated(uint256 indexed seriesId, string name, address token, uint256 principalPerBill, uint256 maxBills);
    event SeriesDeactivated(uint256 indexed seriesId);
    event SeriesBillIssued(uint256 indexed seriesId, uint256 indexed billId, address indexed owner);

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

    /// @notice Base URI for ERC-721 metadata (set via setBaseURI)
    string private _customBaseURI;

    /// @notice Contract-level metadata URI (for OpenSea collection-level branding)
    string private _customContractURI;

    // ════════════════════════════════════════════════════════════════════
    // Escheatment — unclaimed bill expiry and return to treasury
    // ════════════════════════════════════════════════════════════════════

    /// @notice Default claim window after maturity (standard deposits)
    uint256 public defaultClaimWindow;

    /// @notice Timestamp when defaultClaimWindow was first set (non-zero).
    /// @dev Bills issued before this timestamp are NOT subject to the default window
    ///      (prevents retroactive escheatment of legacy bills on upgrade).
    uint256 public claimWindowEffectiveFrom;

    /// @notice Per-bill claim deadline override (0 = use default)
    mapping(uint256 => uint256) public claimDeadline;

    // ════════════════════════════════════════════════════════════════════
    // Bill Series — airdrop campaigns with custom parameters
    // ════════════════════════════════════════════════════════════════════

    struct BillSeries {
        string name;                // "USDT $5 Airdrop Q2 2026"
        address token;              // ERC20 token for this series
        uint256 principalPerBill;   // Principal amount per bill
        uint256 annualRateBps;      // APY for this series
        uint256 durationInDays;     // Maturity duration
        uint256 claimWindowDays;    // Days after maturity before escheatment
        uint256 maxBills;           // Total bills in series (0 = unlimited)
        uint256 issuedCount;        // Bills issued so far
        address fundingSource;      // Where unclaimed funds return to (treasury if 0)
        bool active;                // Can new bills be issued from this series
    }

    /// @notice Series registry
    BillSeries[] public seriesRegistry;

    /// @notice Maps billId to its series (0 = no series / standard deposit)
    mapping(uint256 => uint256) public billSeries;

    /// @notice Next series ID (starts at 1; 0 means "no series")
    uint256 public nextSeriesId;

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

        bills[billId] = BillInfo({
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
        emit BillIssued(billId, owner_, bills[billId]);
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

        // Compute pro-rata principal for correct depositClaims accounting
        uint256 principalRedeemed = bill.redemptionValue > 0
            ? Math.mulDiv(bill.principal, request.amount, bill.redemptionValue)
            : 0;

        // Process the payout
        if (address(treasury) != address(0)) {
            _enforceComplianceAndTravel(bill.token, address(treasury), bill.depositWallet, request.payoutAmount);

            // Liability breakdown for this early redemption:
            //   request.amount      = portion of redemptionValue being settled
            //   request.payoutAmount = cash to depositor
            //   totalForfeit        = liability cancelled without cash movement
            //
            // Treasury only holds principal. Cash actually retained after payout:
            //   cashRetained = principalRedeemed - payoutAmount (if positive)
            // This is the maximum that can go to ownedCapital.
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
            //    principalInPayout = principalRedeemed - cashRetained (what goes out as principal)
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
            // Series bills cannot be merged — they have sponsor-specific escheatment rules
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

    // ════════════════════════════════════════════════════════════════════
    // NFT Metadata — ERC-721 tokenURI + collection-level contractURI
    // ════════════════════════════════════════════════════════════════════

    /// @notice Set the base URI for token metadata. tokenURI(id) = baseURI + id.
    /// @dev Admin-only. Point to your metadata API, e.g. "https://api.cryptodeposit.org/nft/1/"
    function setBaseURI(string calldata baseURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _customBaseURI = baseURI_;
    }

    /// @dev Override ERC721 _baseURI to return the custom base URI
    function _baseURI() internal view override returns (string memory) {
        return _customBaseURI;
    }

    /// @notice Collection-level metadata (OpenSea, wallets, marketplaces)
    /// @dev See https://docs.opensea.io/docs/contract-level-metadata
    function contractURI() external view returns (string memory) {
        return _customContractURI;
    }

    /// @notice Set the contract-level metadata URI
    function setContractURI(string calldata contractURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _customContractURI = contractURI_;
    }

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
        BillInfo memory b = bills[billId];
        if (b.redemptionValue == 0) revert BillInvalid();
        if (deadline != 0 && deadline < b.maturity + 30 days) revert InvalidClaimWindow();
        claimDeadline[billId] = deadline;
        emit BillClaimDeadlineSet(billId, deadline);
    }

    /// @notice Get the effective claim deadline for a bill
    function getClaimDeadline(uint256 billId) public view returns (uint256) {
        uint256 explicit = claimDeadline[billId];
        if (explicit != 0) return explicit;
        BillInfo memory b = bills[billId];
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
        BillInfo memory b = bills[billId];
        if (b.redemptionValue == 0) return false; // Already redeemed or burned
        return block.timestamp > deadline;
    }

    /// @notice Burn an expired unclaimed bill and return funds to treasury/issuer
    /// @dev Only callable by OPERATOR_ROLE. Bill must be past its claim deadline.
    ///      Always clears the treasury liability. Enforces compliance/travel for external transfers.
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
        BillInfo storage b = bills[billId];
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
            // Clears depositLiabilities (full), depositClaims (principal), maturity bucket.
            // Principal goes to ownedCapital. No protocolRevenue impact.
            treasury.writeOffExpiredDeposit(tokenAddr, expiredPrincipal, expiredLiability, expiredMaturity);

            if (returnTo != address(treasury)) {
                // Step 2: Transfer the principal to external destination.
                // Only principal is real funded capital — interest was a promise, never in treasury.
                _enforceComplianceAndTravel(tokenAddr, address(treasury), returnTo, expiredPrincipal);
                treasury.disburseExpiredFunds(tokenAddr, expiredPrincipal, returnTo);
                travel.consume(tokenAddr, address(treasury), returnTo, expiredPrincipal);
                principalReturned = expiredPrincipal;
            }
            // If returnTo == treasury: ownedCapital holds the principal, no cash moved.
        } else {
            // No treasury mode: funds are with issuer.
            if (returnTo != issuer) {
                // Series fundingSource in no-treasury mode: actually transfer from issuer.
                // Only transfer the principal (issuer only holds principal, not interest).
                _enforceComplianceAndTravel(tokenAddr, issuer, returnTo, expiredPrincipal);
                // slither-disable-next-line arbitrary-send-erc20
                IERC20(tokenAddr).safeTransferFrom(issuer, returnTo, expiredPrincipal);
                travel.consume(tokenAddr, issuer, returnTo, expiredPrincipal);
                principalReturned = expiredPrincipal;
            }
            // If returnTo == issuer, funds already there — no transfer needed
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

        // Issue using the standard issue path
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
                // Commission is pure interest — principalPortion = 0
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

        emit BillRedeemed(billId, redeemer, amount);
    }

    /// @dev Reserved storage space for future upgrades
    /// Original 50 - 12 (base fields) - 2 (NFT metadata) - 5 (escheatment + series) = 31
    /// @dev Original 50 - 12 (base) - 2 (NFT metadata) - 6 (escheatment + series) = 30
    uint256[30] private __gap;
}
