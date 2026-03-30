// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ChainlinkFallbackOracleUpgradeable} from "../src/ChainlinkFallbackOracleUpgradeable.sol";
import {OperatorPriceOracleUpgradeable} from "../src/OperatorPriceOracleUpgradeable.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

// ============================================================================
// Mock Chainlink Feed
// ============================================================================

contract MockChainlinkFeed is IAggregatorV3 {
    int256 private _answer;
    uint256 private _updatedAt;
    uint8 private _decimals;
    bool private _shouldRevert;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function setAnswer(int256 answer, uint256 updatedAt) external {
        _answer = answer;
        _updatedAt = updatedAt;
    }

    function setShouldRevert(bool shouldRevert) external {
        _shouldRevert = shouldRevert;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!_shouldRevert, "feed reverted");
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

// ============================================================================
// Tests
// ============================================================================

contract ChainlinkFallbackOracleTest is Test {
    ChainlinkFallbackOracleUpgradeable public oracle;
    OperatorPriceOracleUpgradeable public operatorOracle;
    MockChainlinkFeed public ethFeed;
    MockChainlinkFeed public btcFeed;

    address admin = makeAddr("admin");
    address token1 = makeAddr("token1"); // "ETH-like"
    address token2 = makeAddr("token2"); // "BTC-like"
    address token3 = makeAddr("token3"); // no feed configured

    uint256 constant ETH_PRICE = 250_000_000_000; // $2,500.00 in 8 decimals
    uint256 constant BTC_PRICE = 6_500_000_000_000; // $65,000.00 in 8 decimals

    function setUp() public {
        // Warp to a realistic timestamp so subtraction doesn't underflow
        vm.warp(1_700_000_000);
        vm.startPrank(admin);

        // Deploy operator oracle (fallback)
        OperatorPriceOracleUpgradeable opImpl = new OperatorPriceOracleUpgradeable();
        ERC1967Proxy opProxy = new ERC1967Proxy(
            address(opImpl),
            abi.encodeCall(OperatorPriceOracleUpgradeable.initialize, (admin, admin, 300))
        );
        operatorOracle = OperatorPriceOracleUpgradeable(address(opProxy));

        // Deploy Chainlink fallback oracle
        ChainlinkFallbackOracleUpgradeable impl = new ChainlinkFallbackOracleUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ChainlinkFallbackOracleUpgradeable.initialize,
                (admin, address(operatorOracle), 500) // 5% deviation threshold
            )
        );
        oracle = ChainlinkFallbackOracleUpgradeable(address(proxy));

        // Deploy mock Chainlink feeds (8 decimals)
        ethFeed = new MockChainlinkFeed(8);
        btcFeed = new MockChainlinkFeed(8);

        // Configure feeds
        oracle.setFeed(token1, address(ethFeed), 3600); // 1 hour staleness
        oracle.setFeed(token2, address(btcFeed), 3600);

        // Set initial Chainlink prices (fresh)
        ethFeed.setAnswer(int256(ETH_PRICE), block.timestamp);
        btcFeed.setAnswer(int256(BTC_PRICE), block.timestamp);

        // Set operator oracle prices too
        operatorOracle.setPrice(token1, ETH_PRICE);
        operatorOracle.setPrice(token2, BTC_PRICE);
        operatorOracle.setPrice(token3, 100_000_000); // $1.00 — only in operator

        vm.stopPrank();
    }

    // ========================================================================
    // Initialization
    // ========================================================================

    function test_initialize() public view {
        assertEq(address(oracle.operatorOracle()), address(operatorOracle));
        assertEq(oracle.deviationThresholdBps(), 500);
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.OPERATOR_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.UPGRADER_ROLE(), admin));
    }

    function test_initialize_revert_zeroAdmin() public {
        ChainlinkFallbackOracleUpgradeable impl = new ChainlinkFallbackOracleUpgradeable();
        vm.expectRevert("admin=0");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ChainlinkFallbackOracleUpgradeable.initialize, (address(0), address(operatorOracle), 500))
        );
    }

    function test_initialize_revert_zeroOracle() public {
        ChainlinkFallbackOracleUpgradeable impl = new ChainlinkFallbackOracleUpgradeable();
        vm.expectRevert("oracle=0");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ChainlinkFallbackOracleUpgradeable.initialize, (admin, address(0), 500))
        );
    }

    // ========================================================================
    // Chainlink Primary
    // ========================================================================

    function test_getPrice_chainlinkPrimary() public view {
        (uint256 price, uint256 ts) = oracle.getPrice(token1);
        assertEq(price, ETH_PRICE);
        assertEq(ts, block.timestamp);
    }

    function test_getPrices_batch() public view {
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;
        (uint256[] memory prices, uint256 ts) = oracle.getPrices(tokens);
        assertEq(prices[0], ETH_PRICE);
        assertEq(prices[1], BTC_PRICE);
        assertEq(ts, block.timestamp);
    }

    function test_isPriceFresh_chainlink() public view {
        assertTrue(oracle.isPriceFresh(token1));
    }

    // ========================================================================
    // Fallback to Operator
    // ========================================================================

    function test_getPrice_fallbackToOperator_whenChainlinkStale() public {
        // Make Chainlink stale (set updatedAt to 2 hours ago)
        ethFeed.setAnswer(int256(ETH_PRICE), block.timestamp - 7200);

        (uint256 price, ) = oracle.getPrice(token1);
        assertEq(price, ETH_PRICE); // falls back to operator oracle
    }

    function test_getPrice_fallbackToOperator_whenChainlinkReverts() public {
        ethFeed.setShouldRevert(true);

        (uint256 price, ) = oracle.getPrice(token1);
        assertEq(price, ETH_PRICE); // falls back to operator oracle
    }

    function test_getPrice_fallbackToOperator_whenNegativeAnswer() public {
        ethFeed.setAnswer(-1, block.timestamp);

        (uint256 price, ) = oracle.getPrice(token1);
        assertEq(price, ETH_PRICE); // falls back to operator oracle
    }

    function test_getPrice_fallbackToOperator_whenZeroAnswer() public {
        ethFeed.setAnswer(0, block.timestamp);

        (uint256 price, ) = oracle.getPrice(token1);
        assertEq(price, ETH_PRICE); // falls back to operator oracle
    }

    function test_getPrice_operatorOnly_noFeedConfigured() public view {
        // token3 has no Chainlink feed, only operator oracle
        (uint256 price, ) = oracle.getPrice(token3);
        assertEq(price, 100_000_000); // $1.00
    }

    function test_getPrice_revert_noFreshPrice() public {
        // Make Chainlink stale
        ethFeed.setAnswer(int256(ETH_PRICE), block.timestamp - 7200);

        // Make operator oracle stale too
        vm.warp(block.timestamp + 600); // advance past 5-minute staleness

        vm.expectRevert("no fresh price available");
        oracle.getPrice(token1);
    }

    function test_isPriceFresh_fallbackToOperator() public {
        // Chainlink stale
        ethFeed.setAnswer(int256(ETH_PRICE), block.timestamp - 7200);

        // Operator still fresh
        assertTrue(oracle.isPriceFresh(token1));
    }

    function test_isPriceFresh_bothStale() public {
        // Chainlink stale
        ethFeed.setAnswer(int256(ETH_PRICE), block.timestamp - 7200);

        // Advance past operator staleness
        vm.warp(block.timestamp + 600);

        assertFalse(oracle.isPriceFresh(token1));
    }

    // ========================================================================
    // Decimal Normalization
    // ========================================================================

    function test_getPrice_normalizes18DecimalFeed() public {
        // Create a feed with 18 decimals
        MockChainlinkFeed feed18 = new MockChainlinkFeed(18);
        // $2,500.00 in 18 decimals = 2500 * 1e18
        feed18.setAnswer(int256(2500 * 1e18), block.timestamp);

        address tokenX = makeAddr("tokenX");
        vm.prank(admin);
        oracle.setFeed(tokenX, address(feed18), 3600);

        // Set operator price too
        vm.prank(admin);
        operatorOracle.setPrice(tokenX, ETH_PRICE);

        (uint256 price, ) = oracle.getPrice(tokenX);
        assertEq(price, ETH_PRICE); // normalized to 8 decimals
    }

    function test_getPrice_normalizes6DecimalFeed() public {
        // Create a feed with 6 decimals
        MockChainlinkFeed feed6 = new MockChainlinkFeed(6);
        // $1.00 in 6 decimals = 1_000_000
        feed6.setAnswer(int256(1_000_000), block.timestamp);

        address tokenY = makeAddr("tokenY");
        vm.prank(admin);
        oracle.setFeed(tokenY, address(feed6), 3600);

        vm.prank(admin);
        operatorOracle.setPrice(tokenY, 100_000_000);

        (uint256 price, ) = oracle.getPrice(tokenY);
        assertEq(price, 100_000_000); // $1.00 in 8 decimals
    }

    // ========================================================================
    // Deviation Detection
    // ========================================================================

    function test_checkDeviation_emitsEvent() public {
        // Set operator price 10% higher than Chainlink
        uint256 deviatedPrice = (ETH_PRICE * 110) / 100;
        vm.prank(admin);
        operatorOracle.setPrice(token1, deviatedPrice);

        // Should emit PriceDeviation since 10% > 5% threshold
        vm.expectEmit(true, false, false, false);
        emit ChainlinkFallbackOracleUpgradeable.PriceDeviation(token1, 0, 0, 0);

        oracle.checkDeviation(token1);
    }

    function test_checkDeviation_noEvent_withinThreshold() public {
        // Set operator price 2% higher (within 5% threshold)
        uint256 slightlyOff = (ETH_PRICE * 102) / 100;
        vm.prank(admin);
        operatorOracle.setPrice(token1, slightlyOff);

        // Record logs to verify no PriceDeviation event
        vm.recordLogs();
        oracle.checkDeviation(token1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Should have no logs (no deviation event)
        assertEq(logs.length, 0);
    }

    // ========================================================================
    // Admin Functions
    // ========================================================================

    function test_setFeed() public {
        MockChainlinkFeed newFeed = new MockChainlinkFeed(8);
        address newToken = makeAddr("newToken");

        vm.prank(admin);
        oracle.setFeed(newToken, address(newFeed), 1800);

        (address feed, uint256 staleness, uint8 dec) = oracle.getFeed(newToken);
        assertEq(feed, address(newFeed));
        assertEq(staleness, 1800);
        assertEq(dec, 8);
    }

    function test_removeFeed() public {
        vm.prank(admin);
        oracle.removeFeed(token1);

        (address feed, , ) = oracle.getFeed(token1);
        assertEq(feed, address(0));
    }

    function test_setOperatorOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(admin);
        oracle.setOperatorOracle(newOracle);
        assertEq(address(oracle.operatorOracle()), newOracle);
    }

    function test_setDeviationThreshold() public {
        vm.prank(admin);
        oracle.setDeviationThreshold(1000); // 10%
        assertEq(oracle.deviationThresholdBps(), 1000);
    }

    function test_setFeed_revert_unauthorized() public {
        address notAdmin = makeAddr("notAdmin");
        vm.prank(notAdmin);
        vm.expectRevert();
        oracle.setFeed(token1, address(ethFeed), 3600);
    }

    function test_setOperatorOracle_revert_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("oracle=0");
        oracle.setOperatorOracle(address(0));
    }

    function test_setDeviationThreshold_revert_outOfRange() public {
        vm.prank(admin);
        vm.expectRevert("deviation out of range");
        oracle.setDeviationThreshold(0);
    }

    // ========================================================================
    // Feed View
    // ========================================================================

    function test_getFeed_unconfigured() public {
        address unknown = makeAddr("unknown");
        (address feed, uint256 staleness, uint8 dec) = oracle.getFeed(unknown);
        assertEq(feed, address(0));
        assertEq(staleness, 0);
        assertEq(dec, 0);
    }
}
