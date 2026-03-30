// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interfaces/IHaircutRegistry.sol";

/**
 * @title HaircutRegistryUpgradeable
 * @notice On-chain registry of per-token haircut configurations for collateral and borrowing
 * @dev Follows the prime brokerage model:
 *      - Collateral haircut: BTC 30%, ETH 25%, USDT/USDC 5%
 *      - Borrow haircut: additional risk factor when borrowing volatile assets
 *      - MaxLTV: maximum loan-to-value before borrow is rejected
 *      - Liquidation threshold: health ratio below which position can be liquidated
 *
 *      Operator (rate server) pushes haircut updates; POLICY_ADMIN can override in emergencies.
 */
contract HaircutRegistryUpgradeable is Initializable, AccessControlUpgradeable, UUPSUpgradeable, IHaircutRegistry {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant POLICY_ADMIN_ROLE = keccak256("POLICY_ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Maximum allowed haircut (99.99%)
    uint256 public constant MAX_HAIRCUT_BPS = 9999;
    /// @notice Maximum allowed LTV (99.99%)
    uint256 public constant MAX_LTV_BPS = 9999;

    /// @notice Token address => haircut configuration
    mapping(address => HaircutConfig) private _haircuts;

    /// @notice List of all registered tokens for enumeration
    address[] private _registeredTokens;
    mapping(address => bool) private _isRegistered;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin) public initializer {
        require(admin != address(0), "admin=0");
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(POLICY_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ============================================================================
    // Write Functions
    // ============================================================================

    /**
     * @notice Set haircut configuration for a token
     * @param token ERC20 token address
     * @param config Haircut configuration
     */
    function setHaircut(address token, HaircutConfig calldata config) external onlyRole(OPERATOR_ROLE) {
        _validateConfig(config);
        _setHaircut(token, config);
    }

    /**
     * @notice Batch set haircut configurations
     * @param tokens Array of ERC20 token addresses
     * @param configs Array of haircut configurations
     */
    function setBatchHaircuts(address[] calldata tokens, HaircutConfig[] calldata configs) external onlyRole(OPERATOR_ROLE) {
        require(tokens.length == configs.length, "length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            _validateConfig(configs[i]);
            _setHaircut(tokens[i], configs[i]);
        }
    }

    /**
     * @notice Emergency haircut override by policy admin
     * @param token ERC20 token address
     * @param config New haircut configuration
     */
    function emergencySetHaircut(address token, HaircutConfig calldata config) external onlyRole(POLICY_ADMIN_ROLE) {
        _validateConfig(config);
        _setHaircut(token, config);
    }

    /**
     * @notice Disable an asset (no longer accepted as collateral or for borrowing)
     * @param token ERC20 token address
     */
    function disableAsset(address token) external onlyRole(POLICY_ADMIN_ROLE) {
        _haircuts[token].enabled = false;
        emit AssetDisabled(token, msg.sender);
    }

    // ============================================================================
    // View Functions
    // ============================================================================

    /// @inheritdoc IHaircutRegistry
    function getHaircut(address token) external view override returns (HaircutConfig memory) {
        return _haircuts[token];
    }

    /// @inheritdoc IHaircutRegistry
    function getEffectiveCollateralValue(
        address token,
        uint256 amount,
        uint256 priceUsd
    ) external view override returns (uint256) {
        HaircutConfig memory config = _haircuts[token];
        require(config.enabled, "asset not accepted");
        // effectiveValue = amount * priceUsd * (10000 - haircutBps) / 10000
        // priceUsd is scaled to 8 decimals (like Chainlink)
        return (amount * priceUsd * (10000 - config.collateralHaircutBps)) / (10000 * 1e8);
    }

    /// @inheritdoc IHaircutRegistry
    function isAcceptedCollateral(address token) external view override returns (bool) {
        return _haircuts[token].enabled;
    }

    /// @inheritdoc IHaircutRegistry
    function isAcceptedBorrow(address token) external view override returns (bool) {
        return _haircuts[token].enabled;
    }

    /**
     * @notice Get all registered token addresses
     * @return tokens Array of registered token addresses
     */
    function getRegisteredTokens() external view returns (address[] memory) {
        return _registeredTokens;
    }

    /**
     * @notice Get haircut configs for all registered tokens
     * @return tokens Array of token addresses
     * @return configs Array of haircut configurations
     */
    function getAllHaircuts() external view returns (address[] memory tokens, HaircutConfig[] memory configs) {
        tokens = _registeredTokens;
        configs = new HaircutConfig[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            configs[i] = _haircuts[tokens[i]];
        }
    }

    /**
     * @notice Check if a token is registered in the registry
     */
    function isTokenRegistered(address token) external view returns (bool) {
        return _isRegistered[token];
    }

    // ============================================================================
    // Internal
    // ============================================================================

    function _setHaircut(address token, HaircutConfig calldata config) internal {
        require(token != address(0), "token=0");
        _haircuts[token] = config;

        if (!_isRegistered[token]) {
            _registeredTokens.push(token);
            _isRegistered[token] = true;
        }

        if (config.enabled) {
            emit AssetEnabled(token, msg.sender);
        }
        emit HaircutUpdated(token, config, msg.sender);
    }

    function _validateConfig(HaircutConfig calldata config) internal pure {
        require(config.collateralHaircutBps <= MAX_HAIRCUT_BPS, "collateral haircut too high");
        require(config.borrowHaircutBps <= MAX_HAIRCUT_BPS, "borrow haircut too high");
        require(config.maxLtvBps <= MAX_LTV_BPS, "maxLTV too high");
        require(config.liquidationThresholdBps <= MAX_LTV_BPS, "liquidation threshold too high");
        if (config.enabled) {
            require(config.maxLtvBps > 0, "maxLTV must be > 0 when enabled");
            require(config.liquidationThresholdBps > config.maxLtvBps, "liquidation threshold must exceed maxLTV");
        }
    }

    /// @dev Reserved storage space for future upgrades
    uint256[46] private __gap;
}
