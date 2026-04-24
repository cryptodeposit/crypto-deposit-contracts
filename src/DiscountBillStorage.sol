// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IComplianceRegistry.sol";
import "./interfaces/ITravelRuleRegistry.sol";
import "./interfaces/IDiscountBill.sol";
import "./interfaces/ITreasury.sol";
import {BillTokenFactory} from "./BillTokenFactory.sol";

/**
 * @title DiscountBillStorage
 * @notice Shared storage layout for the DiscountBill contract system.
 * @dev ALL state variables live here. DiscountBillCore, DiscountBillLifecycle,
 *      and DiscountBillCampaigns inherit this EXACT layout so delegatecall works.
 *
 *      CRITICAL: Never reorder, remove, or change the type of any variable.
 *      Only append new variables BEFORE __gap, and reduce __gap accordingly.
 *
 *      Storage slot audit (from v1.0.0-mainnet-first-deposit):
 *        Inherited: ERC721Upgradeable, AccessControlUpgradeable, PausableUpgradeable
 *        Custom: 12 base + 2 NFT metadata + 6 escheatment/series = 20 custom slots
 *        __gap: 30 reserved slots
 */
abstract contract DiscountBillStorage is
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    // ════════════════════════════════════════════════════════════════════
    // Custom errors
    // ════════════════════════════════════════════════════════════════════

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
    error InvalidClaimWindow();
    error SeriesNotFound();
    error SeriesExhausted();
    error SeriesBillCannotMerge();

    // ════════════════════════════════════════════════════════════════════
    // Constants
    // ════════════════════════════════════════════════════════════════════

    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    uint256 public constant MAX_COMMISSION_BPS = 5000;
    uint256 public constant MAX_BREAK_FEE_BPS = 2000;

    // ════════════════════════════════════════════════════════════════════
    // Events
    // ════════════════════════════════════════════════════════════════════

    event Defaulted(uint256 indexed billId);
    event BillTokenCreated(uint256 indexed billId, address token);
    event EarlyRedemptionRequested(uint256 indexed requestId, uint256 indexed billId, address indexed requester, uint256 amount, bool isPartial);
    event EarlyRedemptionApproved(uint256 indexed requestId, uint256 payout);
    event EarlyRedemptionRejected(uint256 indexed requestId, string reason);
    event BreakFeeUpdated(address indexed token, uint256 newFeeBps);
    event DepositWalletUpdated(uint256 indexed billId, address indexed oldWallet, address indexed newWallet);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ComplianceRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event BillExpiredAndBurned(uint256 indexed billId, address indexed lastOwner, uint256 liability, uint256 principalReturned, address returnedTo);
    event DefaultClaimWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event BillClaimDeadlineSet(uint256 indexed billId, uint256 deadline);
    event SeriesCreated(uint256 indexed seriesId, string name, address token, uint256 principalPerBill, uint256 maxBills);
    event SeriesDeactivated(uint256 indexed seriesId);
    event SeriesBillIssued(uint256 indexed seriesId, uint256 indexed billId, address indexed owner);

    // ════════════════════════════════════════════════════════════════════
    // Storage — Base (12 slots)
    // ════════════════════════════════════════════════════════════════════

    IComplianceRegistry public compliance;          // slot +0
    ITravelRuleRegistry public travel;               // slot +1
    address public issuer;                           // slot +2
    ITreasury public treasury;                       // slot +3

    uint256 public nextBillId;                       // slot +4
    mapping(uint256 => IDiscountBill.BillInfo) public bills; // slot +5

    uint256 public commissionBps;                    // slot +6

    mapping(uint256 => address) public billTokens;   // slot +7

    // Early redemption
    enum RedemptionStatus { Pending, Approved, Rejected, Executed }

    struct EarlyRedemptionRequest {
        uint256 billId;
        address requester;
        uint256 requestedAt;
        uint256 amount;
        bool isPartial;
        uint256 breakFee;
        uint256 accruedInterest;
        uint256 payoutAmount;
        RedemptionStatus status;
    }

    mapping(address => uint256) public breakFeeBps;  // slot +8
    uint256 public defaultBreakFeeBps;               // slot +9

    EarlyRedemptionRequest[] internal earlyRedemptionRequests; // slot +10
    mapping(uint256 => uint256[]) internal billToRequests;     // slot +11
    mapping(uint256 => bool) public billInvalidated;           // slot +12

    BillTokenFactory public billTokenFactory;        // slot +13
    mapping(address => uint256) public maxDepositAmount; // slot +14

    // ════════════════════════════════════════════════════════════════════
    // Storage — NFT Metadata (2 slots)
    // ════════════════════════════════════════════════════════════════════

    string private _customBaseURI;                   // slot +15
    string private _customContractURI;               // slot +16

    // ════════════════════════════════════════════════════════════════════
    // Storage — Escheatment (3 slots)
    // ════════════════════════════════════════════════════════════════════

    uint256 public defaultClaimWindow;               // slot +17
    uint256 public claimWindowEffectiveFrom;         // slot +18
    mapping(uint256 => uint256) public claimDeadline; // slot +19

    // ════════════════════════════════════════════════════════════════════
    // Storage — Bill Series (3 slots)
    // ════════════════════════════════════════════════════════════════════

    struct BillSeries {
        string name;
        address token;
        uint256 principalPerBill;
        uint256 annualRateBps;
        uint256 durationInDays;
        uint256 claimWindowDays;
        uint256 maxBills;
        uint256 issuedCount;
        address fundingSource;
        bool active;
    }

    BillSeries[] public seriesRegistry;              // slot +20
    mapping(uint256 => uint256) public billSeries;   // slot +21
    uint256 public nextSeriesId;                     // slot +22

    // ════════════════════════════════════════════════════════════════════
    // Storage — Extension addresses (2 slots)
    // ════════════════════════════════════════════════════════════════════

    address public lifecycleImpl;                    // slot +23
    address public campaignsImpl;                    // slot +24

    // ════════════════════════════════════════════════════════════════════
    // Reserved storage gap
    // ════════════════════════════════════════════════════════════════════

    /// @dev Original 50 - 25 custom = 25 reserved
    uint256[25] private __gap;

    // ════════════════════════════════════════════════════════════════════
    // Required overrides (ERC721 + AccessControl both define supportsInterface)
    // ════════════════════════════════════════════════════════════════════

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ════════════════════════════════════════════════════════════════════
    // Shared internal helpers (used by multiple contracts)
    // ════════════════════════════════════════════════════════════════════

    function _enforceComplianceAndTravel(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal view {
        if (!compliance.isAllowed(to)) revert ComplianceBlocked();
        if (!travel.isCompliant(token, from, to, amount)) revert TravelRuleBlocked();
    }

    function _customBaseURIValue() internal view returns (string memory) {
        return _customBaseURI;
    }

    function _setCustomBaseURI(string calldata uri) internal {
        _customBaseURI = uri;
    }

    function _customContractURIValue() internal view returns (string memory) {
        return _customContractURI;
    }

    function _setCustomContractURI(string calldata uri) internal {
        _customContractURI = uri;
    }
}
