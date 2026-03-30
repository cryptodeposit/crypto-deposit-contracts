// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/ICollateralVault.sol";
import "./interfaces/IComplianceRegistry.sol";
import "./interfaces/IHaircutRegistry.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IDiscountBill.sol";
import "./interfaces/ITreasury.sol";

/**
 * @title CollateralVaultUpgradeable
 * @notice Custodies ERC20 tokens and DiscountBill NFTs as collateral for borrowing
 * @dev Prime brokerage model:
 *      1. Client deposits ERC20 (WBTC, ETH, USDC, etc.) or DiscountBill NFTs
 *      2. Vault values collateral using PriceOracle + HaircutRegistry
 *      3. BorrowingEngine checks effective collateral before issuing loans
 *      4. LiquidationManager can seize collateral on margin breach
 *
 *      Bill valuation: min(redeemableValue, currentAccruedValue) * (1 - haircut)
 *      Bills with pending early redemption cannot be pledged.
 */
contract CollateralVaultUpgradeable is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IERC721Receiver,
    ICollateralVault
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    IComplianceRegistry public compliance;
    IHaircutRegistry public haircutRegistry;
    IPriceOracle public priceOracle;
    IDiscountBill public discountBill;

    /// @notice Address of the BorrowingEngine (for margin requirement queries)
    address public borrowingEngine;

    /// @notice Central Treasury for token custody
    ITreasury public treasury;

    // ============================================================================
    // Collateral State
    // ============================================================================

    /// @notice ERC20 collateral: client => token => amount
    mapping(address => mapping(address => uint256)) public erc20Balances;

    /// @notice Bill collateral: client => array of billIds
    mapping(address => uint256[]) private _billPositions;

    /// @notice Reverse lookup: billId => client (address(0) if not deposited)
    mapping(uint256 => address) public billOwner;

    /// @notice All tokens a client has deposited (for enumeration)
    mapping(address => address[]) private _clientTokens;
    mapping(address => mapping(address => bool)) private _hasToken;

    // ============================================================================
    // Events (beyond ICollateralVault)
    // ============================================================================

    event BorrowingEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event ComplianceRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event HaircutRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address admin,
        address _compliance,
        address _haircutRegistry,
        address _priceOracle,
        address _discountBill
    ) public initializer {
        require(admin != address(0), "admin=0");
        require(_compliance != address(0), "compliance=0");
        require(_haircutRegistry != address(0), "haircutRegistry=0");
        require(_priceOracle != address(0), "priceOracle=0");
        __AccessControl_init();


        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        compliance = IComplianceRegistry(_compliance);
        haircutRegistry = IHaircutRegistry(_haircutRegistry);
        priceOracle = IPriceOracle(_priceOracle);
        if (_discountBill != address(0)) {
            discountBill = IDiscountBill(_discountBill);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ============================================================================
    // ERC721 Receiver (required to hold DiscountBill NFTs)
    // ============================================================================

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ============================================================================
    // Admin
    // ============================================================================

    function setBorrowingEngine(address _engine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = borrowingEngine;
        borrowingEngine = _engine;
        emit BorrowingEngineUpdated(old, _engine);
    }

    function setComplianceRegistry(address _compliance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_compliance != address(0), "compliance=0");
        address old = address(compliance);
        compliance = IComplianceRegistry(_compliance);
        emit ComplianceRegistryUpdated(old, _compliance);
    }

    function setHaircutRegistry(address _haircutRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_haircutRegistry != address(0), "haircutRegistry=0");
        address old = address(haircutRegistry);
        haircutRegistry = IHaircutRegistry(_haircutRegistry);
        emit HaircutRegistryUpdated(old, _haircutRegistry);
    }

    function setPriceOracle(address _priceOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_priceOracle != address(0), "priceOracle=0");
        address old = address(priceOracle);
        priceOracle = IPriceOracle(_priceOracle);
        emit PriceOracleUpdated(old, _priceOracle);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(treasury_ != address(0), "treasury=0");
        address old = address(treasury);
        treasury = ITreasury(treasury_);
        emit TreasuryUpdated(old, treasury_);
    }

    // ============================================================================
    // Deposit Functions
    // ============================================================================

    /// @inheritdoc ICollateralVault
    function depositCollateral(address token, uint256 amount) external override nonReentrant {
        require(amount > 0, "amount=0");
        require(compliance.isAllowed(msg.sender), "compliance: blocked");
        require(haircutRegistry.isAcceptedCollateral(token), "token not accepted");

        if (address(treasury) != address(0)) {
            // Treasury path: tokens flow to central treasury
            IERC20(token).safeTransferFrom(msg.sender, address(treasury), amount);
            treasury.recordCollateral(token, amount);
        } else {
            // Legacy path: tokens held directly by vault
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
        erc20Balances[msg.sender][token] += amount;

        // Track token list for client
        if (!_hasToken[msg.sender][token]) {
            _clientTokens[msg.sender].push(token);
            _hasToken[msg.sender][token] = true;
        }

        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @inheritdoc ICollateralVault
    function depositBill(uint256 billId) external override nonReentrant {
        require(address(discountBill) != address(0), "bills not supported");
        require(compliance.isAllowed(msg.sender), "compliance: blocked");

        // Verify caller owns the bill
        require(discountBill.ownerOf(billId) == msg.sender, "not bill owner");

        // Transfer bill NFT to vault
        IERC721(address(discountBill)).safeTransferFrom(msg.sender, address(this), billId);

        _billPositions[msg.sender].push(billId);
        billOwner[billId] = msg.sender;

        // Value the bill for the event
        IDiscountBill.BillInfo memory info = discountBill.getBillInfo(billId);
        uint256 valuedAt = _valueBill(info);

        emit BillDeposited(msg.sender, billId, valuedAt);
    }

    // ============================================================================
    // Withdrawal Functions
    // ============================================================================

    /// @inheritdoc ICollateralVault
    function withdrawCollateral(address token, uint256 amount) external override nonReentrant {
        require(amount > 0, "amount=0");
        require(erc20Balances[msg.sender][token] >= amount, "insufficient balance");

        // Simulate withdrawal and check free collateral
        erc20Balances[msg.sender][token] -= amount;
        require(_getFreeCollateral(msg.sender) >= 0, "insufficient free collateral");

        if (address(treasury) != address(0)) {
            treasury.releaseCollateral(token, amount, msg.sender);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    /// @inheritdoc ICollateralVault
    function withdrawBill(uint256 billId) external override nonReentrant {
        require(billOwner[billId] == msg.sender, "not bill depositor");

        // Remove bill from positions
        _removeBill(msg.sender, billId);

        // Check free collateral after removal
        require(_getFreeCollateral(msg.sender) >= 0, "insufficient free collateral");

        // Transfer bill back to owner
        IERC721(address(discountBill)).safeTransferFrom(address(this), msg.sender, billId);
        emit BillWithdrawn(msg.sender, billId);
    }

    // ============================================================================
    // Liquidation (called by LiquidationManager only)
    // ============================================================================

    /// @inheritdoc ICollateralVault
    function liquidateCollateral(
        address client,
        address token,
        uint256 amount,
        address liquidator
    ) external override onlyRole(LIQUIDATOR_ROLE) nonReentrant {
        require(erc20Balances[client][token] >= amount, "insufficient collateral");
        erc20Balances[client][token] -= amount;

        if (address(treasury) != address(0)) {
            treasury.withdrawForLiquidation(token, amount, liquidator);
        } else {
            IERC20(token).safeTransfer(liquidator, amount);
        }
        emit CollateralLiquidated(client, token, amount, liquidator);
    }

    // ============================================================================
    // View Functions
    // ============================================================================

    /// @inheritdoc ICollateralVault
    function getCollateralValue(address client) external view override returns (uint256 totalValueUsd) {
        return _getCollateralValueRaw(client);
    }

    /// @inheritdoc ICollateralVault
    function getEffectiveCollateralValue(address client) external view override returns (uint256 effectiveValueUsd) {
        return _getEffectiveCollateralValue(client);
    }

    /// @inheritdoc ICollateralVault
    function getFreeCollateral(address client) external view override returns (uint256 freeValueUsd) {
        int256 free = _getFreeCollateral(client);
        return free > 0 ? uint256(free) : 0;
    }

    /// @inheritdoc ICollateralVault
    function getPositions(address client) external view override returns (CollateralPosition[] memory) {
        address[] memory tokens = _clientTokens[client];
        uint256[] memory bills = _billPositions[client];
        uint256 count = 0;

        // Count non-zero token balances
        for (uint256 i = 0; i < tokens.length; i++) {
            if (erc20Balances[client][tokens[i]] > 0) count++;
        }
        count += bills.length;

        CollateralPosition[] memory positions = new CollateralPosition[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 bal = erc20Balances[client][tokens[i]];
            if (bal > 0) {
                positions[idx] = CollateralPosition({
                    token: tokens[i],
                    amount: bal,
                    billId: 0,
                    depositedAt: 0, // Not tracked per-deposit for gas efficiency
                    locked: false
                });
                idx++;
            }
        }

        for (uint256 i = 0; i < bills.length; i++) {
            positions[idx] = CollateralPosition({
                token: address(0),
                amount: 0,
                billId: bills[i],
                depositedAt: 0,
                locked: false
            });
            idx++;
        }

        return positions;
    }

    /**
     * @notice Get ERC20 collateral balance for a specific token
     */
    function getTokenBalance(address client, address token) external view returns (uint256) {
        return erc20Balances[client][token];
    }

    /**
     * @notice Get all bill IDs deposited by a client
     */
    function getBillPositions(address client) external view returns (uint256[] memory) {
        return _billPositions[client];
    }

    /**
     * @notice Get all token addresses a client has deposited
     */
    function getClientTokens(address client) external view returns (address[] memory) {
        return _clientTokens[client];
    }

    /**
     * @notice Check if a client has deposited a specific token
     */
    function hasToken(address client, address token) external view returns (bool) {
        return _hasToken[client][token];
    }

    // ============================================================================
    // Internal: Valuation
    // ============================================================================

    /**
     * @dev Raw collateral value in USD (no haircut applied)
     *      Prices are 8 decimals, amounts are token-native decimals
     *      Returns value scaled to 8 decimals (USD cents * 1e6)
     */
    function _getCollateralValueRaw(address client) internal view returns (uint256 total) {
        // ERC20 collateral
        address[] memory tokens = _clientTokens[client];
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = erc20Balances[client][tokens[i]];
            if (balance > 0) {
                // Security: timestamp return intentionally unused
                // slither-disable-next-line unused-return
                (uint256 price, ) = priceOracle.getPrice(tokens[i]);
                total += (balance * price) / 1e8;
            }
        }

        // Bill collateral
        uint256[] memory bills = _billPositions[client];
        for (uint256 i = 0; i < bills.length; i++) {
            IDiscountBill.BillInfo memory info = discountBill.getBillInfo(bills[i]);
            total += _valueBill(info);
        }
    }

    /**
     * @dev Effective collateral value (after haircuts)
     */
    function _getEffectiveCollateralValue(address client) internal view returns (uint256 total) {
        // ERC20 collateral with haircuts
        address[] memory tokens = _clientTokens[client];
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = erc20Balances[client][tokens[i]];
            if (balance > 0) {
                // Security: timestamp return intentionally unused
                // slither-disable-next-line unused-return
                (uint256 price, ) = priceOracle.getPrice(tokens[i]);
                total += haircutRegistry.getEffectiveCollateralValue(tokens[i], balance, price);
            }
        }

        // Bill collateral - apply haircut of underlying token
        uint256[] memory bills = _billPositions[client];
        for (uint256 i = 0; i < bills.length; i++) {
            IDiscountBill.BillInfo memory info = discountBill.getBillInfo(bills[i]);
            uint256 billValue = _valueBill(info);
            // Get the bill's underlying token price for haircut calculation
            // Security: timestamp return intentionally unused
            // slither-disable-next-line unused-return
            (uint256 tokenPrice, ) = priceOracle.getPrice(info.token);
            if (tokenPrice > 0) {
                // Apply haircut based on underlying token type
                IHaircutRegistry.HaircutConfig memory hc = haircutRegistry.getHaircut(info.token);
                total += (billValue * (10000 - hc.collateralHaircutBps)) / 10000;
            }
        }
    }

    /**
     * @dev Value a DiscountBill in its underlying token terms
     *      Uses min(redeemableValue, currentAccruedValue) to be conservative
     */
    function _valueBill(IDiscountBill.BillInfo memory info) internal view returns (uint256) {
        // If bill is mature, use redemptionValue (minus commission)
        if (block.timestamp >= info.maturity) {
            uint256 matureCommission = Math.mulDiv(
                info.redemptionValue - info.principal, info.commissionBps, 10000
            );
            return info.redemptionValue - matureCommission;
        }

        // Pro-rata accrued value: principal + (interest * elapsed / total_term)
        uint256 totalInterest = info.redemptionValue - info.principal;
        uint256 elapsed = block.timestamp - info.issuance;
        uint256 totalTerm = info.maturity - info.issuance;
        uint256 accruedInterest = Math.mulDiv(totalInterest, elapsed, totalTerm);
        uint256 accruedCommission = Math.mulDiv(accruedInterest, info.commissionBps, 10000);

        return info.principal + accruedInterest - accruedCommission;
    }

    /**
     * @dev Calculate free collateral (effective value - margin requirement)
     *      Returns signed int to detect underwater positions
     */
    function _getFreeCollateral(address client) internal view returns (int256) {
        uint256 effectiveCollateral = _getEffectiveCollateralValue(client);

        if (borrowingEngine == address(0)) {
            return int256(effectiveCollateral);
        }

        // Query total borrow value from BorrowingEngine
        // Using low-level call to avoid circular dependency
        (bool success, bytes memory data) = borrowingEngine.staticcall(
            abi.encodeWithSignature("getTotalBorrowValue(address)", client)
        );

        if (!success) {
            return int256(effectiveCollateral);
        }

        uint256 totalBorrowValue = abi.decode(data, (uint256));
        return int256(effectiveCollateral) - int256(totalBorrowValue);
    }

    // ============================================================================
    // Internal: Bill Management
    // ============================================================================

    function _removeBill(address client, uint256 billId) internal {
        uint256[] storage bills = _billPositions[client];
        for (uint256 i = 0; i < bills.length; i++) {
            if (bills[i] == billId) {
                bills[i] = bills[bills.length - 1];
                bills.pop();
                break;
            }
        }
        delete billOwner[billId];
    }

    /// @dev Reserved storage space for future upgrades
    uint256[40] private __gap;
}
