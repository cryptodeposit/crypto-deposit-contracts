// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./interfaces/IPriceOracle.sol";

/**
 * @title OperatorPriceOracleUpgradeable
 * @notice Price oracle backed by operator-signed price attestations
 * @dev The rate server signs (token, price, timestamp) tuples. This contract verifies
 *      the ECDSA signature against a trusted signer address, then stores the price.
 *      Designed as an interim solution - migrate to Chainlink for production.
 *
 *      Price format: 8 decimals (Chainlink-compatible).
 *      e.g., BTC at $65,000.00 → 6_500_000_000_000
 *
 *      Staleness: prices older than `maxStaleness` (default 5 minutes) are considered stale.
 */
contract OperatorPriceOracleUpgradeable is Initializable, AccessControlUpgradeable, UUPSUpgradeable, IPriceOracle {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Trusted signer address (operator's signing key)
    address public trustedSigner;

    /// @notice Maximum allowed price staleness in seconds
    uint256 public maxStaleness;

    /// @notice Token address => price data
    struct PriceData {
        uint256 price;      // USD price scaled to 8 decimals
        uint256 timestamp;  // When price was attested
    }
    mapping(address => PriceData) private _prices;

    /// @notice Nonces to prevent replay of signed attestations
    mapping(bytes32 => bool) private _usedNonces;

    event PriceUpdated(address indexed token, uint256 price, uint256 timestamp, address indexed updatedBy);
    event TrustedSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event MaxStalenessUpdated(uint256 oldStaleness, uint256 newStaleness);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin, address signer, uint256 stalenessSeconds) public initializer {
        require(admin != address(0), "admin=0");
        require(signer != address(0), "signer=0");
        require(stalenessSeconds > 0, "staleness=0");
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        trustedSigner = signer;
        maxStaleness = stalenessSeconds;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ============================================================================
    // Price Updates
    // ============================================================================

    /**
     * @notice Update price via operator direct call (no signature needed)
     * @param token ERC20 token address
     * @param price USD price scaled to 8 decimals
     */
    function setPrice(address token, uint256 price) external onlyRole(OPERATOR_ROLE) {
        require(token != address(0), "token=0");
        require(price > 0, "price=0");
        _prices[token] = PriceData(price, block.timestamp);
        emit PriceUpdated(token, price, block.timestamp, msg.sender);
    }

    /**
     * @notice Batch update prices via operator direct call
     * @param tokens Array of ERC20 token addresses
     * @param prices_ Array of USD prices scaled to 8 decimals
     */
    function setBatchPrices(address[] calldata tokens, uint256[] calldata prices_) external onlyRole(OPERATOR_ROLE) {
        require(tokens.length == prices_.length, "length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "token=0");
            require(prices_[i] > 0, "price=0");
            _prices[tokens[i]] = PriceData(prices_[i], block.timestamp);
            emit PriceUpdated(tokens[i], prices_[i], block.timestamp, msg.sender);
        }
    }

    /**
     * @notice Update price via signed attestation (can be called by anyone)
     * @param token ERC20 token address
     * @param price USD price scaled to 8 decimals
     * @param timestamp When the price was observed (server-side)
     * @param nonce Unique nonce to prevent replay
     * @param signature ECDSA signature from trusted signer
     */
    function updatePriceSigned(
        address token,
        uint256 price,
        uint256 timestamp,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(token != address(0), "token=0");
        require(price > 0, "price=0");
        require(timestamp <= block.timestamp, "future timestamp");
        require(block.timestamp - timestamp <= maxStaleness, "attestation too old");
        require(!_usedNonces[nonce], "nonce already used");

        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(token, price, timestamp, nonce, block.chainid));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(signature);
        require(signer == trustedSigner, "invalid signer");

        _usedNonces[nonce] = true;
        _prices[token] = PriceData(price, timestamp);
        emit PriceUpdated(token, price, timestamp, msg.sender);
    }

    // ============================================================================
    // Admin
    // ============================================================================

    function setTrustedSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newSigner != address(0), "signer=0");
        address old = trustedSigner;
        trustedSigner = newSigner;
        emit TrustedSignerUpdated(old, newSigner);
    }

    function setMaxStaleness(uint256 stalenessSeconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(stalenessSeconds > 0, "staleness=0");
        uint256 old = maxStaleness;
        maxStaleness = stalenessSeconds;
        emit MaxStalenessUpdated(old, stalenessSeconds);
    }

    // ============================================================================
    // IPriceOracle View Functions
    // ============================================================================

    /// @inheritdoc IPriceOracle
    function getPrice(address token) external view override returns (uint256 price, uint256 timestamp) {
        PriceData memory data = _prices[token];
        require(data.price > 0, "no price available");
        return (data.price, data.timestamp);
    }

    /// @inheritdoc IPriceOracle
    function getPrices(address[] calldata tokens) external view override returns (uint256[] memory prices_, uint256 timestamp) {
        prices_ = new uint256[](tokens.length);
        timestamp = type(uint256).max;
        for (uint256 i = 0; i < tokens.length; i++) {
            PriceData memory data = _prices[tokens[i]];
            require(data.price > 0, "no price available");
            prices_[i] = data.price;
            if (data.timestamp < timestamp) {
                timestamp = data.timestamp;
            }
        }
    }

    /// @inheritdoc IPriceOracle
    function isPriceFresh(address token) external view override returns (bool fresh) {
        PriceData memory data = _prices[token];
        // Security: zero price indicates uninitialized data
        // slither-disable-next-line incorrect-equality
        if (data.price == 0) return false;
        return (block.timestamp - data.timestamp) <= maxStaleness;
    }

    /// @dev Reserved storage space for future upgrades
    uint256[45] private __gap;
}
