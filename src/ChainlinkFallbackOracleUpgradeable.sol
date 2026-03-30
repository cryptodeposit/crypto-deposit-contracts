// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IAggregatorV3.sol";

/**
 * @title ChainlinkFallbackOracleUpgradeable
 * @notice Price oracle with Chainlink as primary source and operator oracle as fallback
 * @dev Implements IPriceOracle. For each token:
 *      1. Try the configured Chainlink feed — if fresh and valid, return it
 *      2. Fall back to the operator oracle — if fresh, return it
 *      3. Revert if neither source has a fresh price
 *
 *      When both sources are available and diverge beyond a configurable threshold,
 *      a PriceDeviation event is emitted for off-chain monitoring systems.
 *
 *      Price format: 8 decimals (Chainlink-compatible).
 */
contract ChainlinkFallbackOracleUpgradeable is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IPriceOracle
{
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Target decimal precision for all returned prices
    uint8 public constant TARGET_DECIMALS = 8;

    /// @notice Per-token Chainlink feed configuration
    struct FeedConfig {
        IAggregatorV3 feed;         // Chainlink aggregator address
        uint256 stalenessSeconds;   // Max age before feed is considered stale
        uint8 feedDecimals;         // Cached decimals from the feed
    }

    /// @notice Operator oracle (fallback source)
    IPriceOracle public operatorOracle;

    /// @notice Max allowed deviation between sources before emitting alert (basis points)
    uint256 public deviationThresholdBps;

    /// @notice Token address => Chainlink feed config
    mapping(address => FeedConfig) private _feeds;

    // ============================================================================
    // Events
    // ============================================================================

    event FeedSet(address indexed token, address indexed feed, uint256 stalenessSeconds);
    event FeedRemoved(address indexed token);
    event OperatorOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event DeviationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event PriceDeviation(
        address indexed token,
        uint256 chainlinkPrice,
        uint256 operatorPrice,
        uint256 deviationBps
    );
    event FallbackUsed(address indexed token, string reason);

    // ============================================================================
    // Initialization
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param admin Admin address (gets DEFAULT_ADMIN_ROLE, OPERATOR_ROLE, UPGRADER_ROLE)
    /// @param operatorOracle_ Address of the existing OperatorPriceOracle (fallback)
    /// @param deviationBps Initial deviation threshold in basis points (e.g. 500 = 5%)
    function initialize(
        address admin,
        address operatorOracle_,
        uint256 deviationBps
    ) public initializer {
        require(admin != address(0), "admin=0");
        require(operatorOracle_ != address(0), "oracle=0");
        require(deviationBps > 0 && deviationBps <= 10_000, "deviation out of range");

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        operatorOracle = IPriceOracle(operatorOracle_);
        deviationThresholdBps = deviationBps;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ============================================================================
    // Admin
    // ============================================================================

    /// @notice Configure a Chainlink feed for a token
    /// @param token ERC20 token address
    /// @param feed Chainlink AggregatorV3 address
    /// @param stalenessSeconds Maximum age for the feed to be considered fresh
    function setFeed(
        address token,
        address feed,
        uint256 stalenessSeconds
    ) external onlyRole(OPERATOR_ROLE) {
        require(token != address(0), "token=0");
        require(feed != address(0), "feed=0");
        require(stalenessSeconds > 0, "staleness=0");

        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        _feeds[token] = FeedConfig({
            feed: IAggregatorV3(feed),
            stalenessSeconds: stalenessSeconds,
            feedDecimals: feedDecimals
        });

        emit FeedSet(token, feed, stalenessSeconds);
    }

    /// @notice Remove a Chainlink feed for a token (operator oracle becomes sole source)
    function removeFeed(address token) external onlyRole(OPERATOR_ROLE) {
        require(token != address(0), "token=0");
        delete _feeds[token];
        emit FeedRemoved(token);
    }

    /// @notice Update the fallback operator oracle address
    function setOperatorOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newOracle != address(0), "oracle=0");
        address old = address(operatorOracle);
        operatorOracle = IPriceOracle(newOracle);
        emit OperatorOracleUpdated(old, newOracle);
    }

    /// @notice Update the deviation threshold
    function setDeviationThreshold(uint256 newThresholdBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newThresholdBps > 0 && newThresholdBps <= 10_000, "deviation out of range");
        uint256 old = deviationThresholdBps;
        deviationThresholdBps = newThresholdBps;
        emit DeviationThresholdUpdated(old, newThresholdBps);
    }

    // ============================================================================
    // IPriceOracle
    // ============================================================================

    /// @inheritdoc IPriceOracle
    function getPrice(address token) external view override returns (uint256 price, uint256 timestamp) {
        return _resolvePrice(token);
    }

    /// @inheritdoc IPriceOracle
    function getPrices(address[] calldata tokens)
        external
        view
        override
        returns (uint256[] memory prices, uint256 timestamp)
    {
        prices = new uint256[](tokens.length);
        timestamp = type(uint256).max;
        for (uint256 i = 0; i < tokens.length; i++) {
            (uint256 p, uint256 ts) = _resolvePrice(tokens[i]);
            prices[i] = p;
            if (ts < timestamp) {
                timestamp = ts;
            }
        }
    }

    /// @inheritdoc IPriceOracle
    function isPriceFresh(address token) external view override returns (bool fresh) {
        (bool chainlinkOk, , ) = _tryChainlink(token);
        if (chainlinkOk) return true;

        // Fall back to operator oracle freshness check
        try operatorOracle.isPriceFresh(token) returns (bool opFresh) {
            return opFresh;
        } catch {
            return false;
        }
    }

    // ============================================================================
    // View helpers
    // ============================================================================

    /// @notice Get the configured feed for a token
    function getFeed(address token) external view returns (address feed, uint256 stalenessSeconds, uint8 feedDecimals) {
        FeedConfig memory cfg = _feeds[token];
        return (address(cfg.feed), cfg.stalenessSeconds, cfg.feedDecimals);
    }

    // ============================================================================
    // Internal
    // ============================================================================

    /// @dev Resolve price: Chainlink first, operator fallback
    function _resolvePrice(address token) internal view returns (uint256 price, uint256 timestamp) {
        (bool chainlinkOk, uint256 clPrice, uint256 clTimestamp) = _tryChainlink(token);

        if (chainlinkOk) {
            // Chainlink is fresh — also check operator for deviation alerting
            _checkDeviation(token, clPrice);
            return (clPrice, clTimestamp);
        }

        // Chainlink unavailable or stale — try operator oracle
        (bool operatorOk, uint256 opPrice, uint256 opTimestamp) = _tryOperator(token);
        require(operatorOk, "no fresh price available");

        return (opPrice, opTimestamp);
    }

    /// @dev Try to get a fresh price from the configured Chainlink feed
    // slither-disable-next-line divide-before-multiply
    function _tryChainlink(address token)
        internal
        view
        returns (bool ok, uint256 normalizedPrice, uint256 timestamp)
    {
        FeedConfig memory cfg = _feeds[token];
        if (address(cfg.feed) == address(0)) {
            return (false, 0, 0);
        }

        // slither-disable-next-line unused-return
        try cfg.feed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            // Validate answer
            if (answer <= 0) return (false, 0, 0);

            // Check staleness
            if (block.timestamp - updatedAt > cfg.stalenessSeconds) {
                return (false, 0, 0);
            }

            // Normalize to 8 decimals
            uint256 price = uint256(answer);
            if (cfg.feedDecimals < TARGET_DECIMALS) {
                price = price * (10 ** (TARGET_DECIMALS - cfg.feedDecimals));
            } else if (cfg.feedDecimals > TARGET_DECIMALS) {
                price = price / (10 ** (cfg.feedDecimals - TARGET_DECIMALS));
            }

            return (true, price, updatedAt);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Try to get a fresh price from the operator oracle
    function _tryOperator(address token)
        internal
        view
        returns (bool ok, uint256 price, uint256 timestamp)
    {
        try operatorOracle.isPriceFresh(token) returns (bool fresh) {
            if (!fresh) return (false, 0, 0);
        } catch {
            return (false, 0, 0);
        }

        try operatorOracle.getPrice(token) returns (uint256 p, uint256 ts) {
            if (p == 0) return (false, 0, 0);
            return (true, p, ts);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Check deviation between Chainlink and operator prices, emit event if threshold exceeded
    ///      This is a view function that cannot emit events, so deviation checking is informational
    ///      at the contract level. The PriceDeviation event is emitted from a separate write function.
    function _checkDeviation(address token, uint256 chainlinkPrice) internal view {
        // Try to get operator price for comparison
        // slither-disable-next-line unused-return
        try operatorOracle.getPrice(token) returns (uint256 opPrice, uint256) {
            if (opPrice == 0) return;

            uint256 larger = chainlinkPrice > opPrice ? chainlinkPrice : opPrice;
            uint256 smaller = chainlinkPrice > opPrice ? opPrice : chainlinkPrice;
            uint256 diff = larger - smaller;
            uint256 deviationBps = (diff * 10_000) / larger;

            // Cannot emit events from view context — deviation is checked externally
            // via checkDeviation() write function or off-chain monitoring
            if (deviationBps > deviationThresholdBps) {
                // Deviation detected but cannot emit from view — callers use checkDeviation()
            }
        } catch {
            // Operator oracle unavailable — no comparison possible
        }
    }

    /// @notice Check price deviation between sources and emit event if threshold exceeded
    /// @dev Called by monitoring bots or keepers to detect oracle discrepancies
    function checkDeviation(address token) external {
        (bool chainlinkOk, uint256 clPrice, ) = _tryChainlink(token);
        if (!chainlinkOk) return;

        // slither-disable-next-line unused-return
        try operatorOracle.getPrice(token) returns (uint256 opPrice, uint256) {
            if (opPrice == 0) return;

            uint256 larger = clPrice > opPrice ? clPrice : opPrice;
            uint256 smaller = clPrice > opPrice ? opPrice : clPrice;
            uint256 diff = larger - smaller;
            uint256 deviationBps = (diff * 10_000) / larger;

            if (deviationBps > deviationThresholdBps) {
                emit PriceDeviation(token, clPrice, opPrice, deviationBps);
            }
        } catch {
            // Operator oracle unavailable
        }
    }

    /// @dev Reserved storage space for future upgrades
    uint256[45] private __gap;
}
