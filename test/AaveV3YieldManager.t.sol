// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3YieldManager} from "../src/AaveV3YieldManager.sol";
import {IYieldManager} from "../src/interfaces/IYieldManager.sol";
import {MockAaveV3Pool, MockAToken} from "./mocks/MockAaveV3Pool.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract AaveV3YieldManagerTest is Test {
    AaveV3YieldManager public manager;
    MockAaveV3Pool public pool;
    MockUSDC public usdc;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address treasury = makeAddr("treasury");

    uint256 constant PRINCIPAL = 10_000e6;   // 10,000 USDC
    uint256 constant RATE_BPS = 500;          // 5% annual
    uint256 constant TERM_DAYS = 90;

    function setUp() public {
        // Deploy mock pool and token
        pool = new MockAaveV3Pool();
        usdc = new MockUSDC();

        // Init reserve before deploying manager (getReserveData needs aToken)
        pool.initReserve(address(usdc));

        // Deploy yield manager
        vm.prank(admin);
        manager = new AaveV3YieldManager(admin, address(pool));

        // Grant roles
        vm.startPrank(admin);
        manager.grantRole(manager.OPERATOR_ROLE(), operator);
        manager.grantRole(manager.TREASURY_ROLE(), treasury);

        // Add USDC as supported token
        manager.addSupportedToken(address(usdc));
        vm.stopPrank();
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    function _deposit(uint256 principal, uint256 rateBps, uint256 termDays)
        internal
        returns (uint256 positionId)
    {
        uint256 maturity = block.timestamp + termDays * 1 days;

        usdc.mint(operator, principal);
        vm.startPrank(operator);
        usdc.approve(address(manager), principal);
        positionId = manager.deposit(address(usdc), principal, maturity, rateBps);
        vm.stopPrank();
    }

    function _expectedYield(uint256 principal, uint256 rateBps, uint256 termDays)
        internal
        pure
        returns (uint256)
    {
        uint256 durationSeconds = termDays * 1 days;
        return (principal * rateBps * durationSeconds) / (365 days * 10_000);
    }

    // ========================================================================
    // Deployment Tests
    // ========================================================================

    function test_constructor_setsPool() public view {
        assertEq(address(manager.aavePool()), address(pool));
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert("admin=0");
        new AaveV3YieldManager(address(0), address(pool));
    }

    function test_constructor_revertsZeroPool() public {
        vm.expectRevert("pool=0");
        new AaveV3YieldManager(admin, address(0));
    }

    function test_addSupportedToken() public view {
        assertTrue(manager.supportsToken(address(usdc)));
        address aToken = manager.aTokens(address(usdc));
        assertEq(aToken, pool.aTokens(address(usdc)));
        assertTrue(aToken != address(0));
    }

    function test_addSupportedToken_revertsAlreadySupported() public {
        vm.prank(admin);
        vm.expectRevert("already supported");
        manager.addSupportedToken(address(usdc));
    }

    function test_name() public view {
        assertEq(manager.name(), "Aave V3 Yield Manager");
    }

    // ========================================================================
    // Deposit Tests
    // ========================================================================

    function test_deposit_createsPosition() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        IYieldManager.Position memory pos = manager.getPosition(positionId);
        assertEq(pos.token, address(usdc));
        assertEq(pos.principal, PRINCIPAL);
        assertTrue(pos.active);
        assertEq(pos.maturity, block.timestamp + TERM_DAYS * 1 days);

        uint256 expectedYield = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);
        assertEq(pos.expectedYield, expectedYield);
    }

    function test_deposit_transfersTokensToAave() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Tokens should be in the pool (supplied via aToken)
        assertEq(usdc.balanceOf(address(pool)), PRINCIPAL);
        assertEq(usdc.balanceOf(address(manager)), 0);
    }

    function test_deposit_mintsATokens() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        address aToken = manager.aTokens(address(usdc));
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(manager));
        assertEq(aTokenBalance, PRINCIPAL);
    }

    function test_deposit_updatesTotals() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        assertEq(manager.totalPrincipalDeposited(address(usdc)), PRINCIPAL);
        uint256 expectedYield = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);
        assertEq(manager.totalExpectedYield(address(usdc)), expectedYield);
    }

    function test_deposit_emitsEvent() public {
        uint256 maturity = block.timestamp + TERM_DAYS * 1 days;

        usdc.mint(operator, PRINCIPAL);
        vm.startPrank(operator);
        usdc.approve(address(manager), PRINCIPAL);

        vm.expectEmit(true, true, false, true);
        emit IYieldManager.PositionCreated(1, address(usdc), PRINCIPAL, maturity);
        manager.deposit(address(usdc), PRINCIPAL, maturity, RATE_BPS);
        vm.stopPrank();
    }

    function test_deposit_revertsUnsupportedToken() public {
        address fakeToken = makeAddr("fake");
        vm.prank(operator);
        vm.expectRevert("token not supported");
        manager.deposit(fakeToken, PRINCIPAL, block.timestamp + 1 days, RATE_BPS);
    }

    function test_deposit_revertsZeroPrincipal() public {
        vm.prank(operator);
        vm.expectRevert("principal=0");
        manager.deposit(address(usdc), 0, block.timestamp + 1 days, RATE_BPS);
    }

    function test_deposit_revertsPastMaturity() public {
        vm.prank(operator);
        vm.expectRevert("maturity in past");
        manager.deposit(address(usdc), PRINCIPAL, block.timestamp - 1, RATE_BPS);
    }

    function test_deposit_revertsUnauthorized() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert();
        manager.deposit(address(usdc), PRINCIPAL, block.timestamp + 1 days, RATE_BPS);
    }

    function test_deposit_multiplePositions() public {
        uint256 id1 = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);
        uint256 id2 = _deposit(PRINCIPAL * 2, 300, 180);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(manager.totalPrincipalDeposited(address(usdc)), PRINCIPAL * 3);
    }

    // ========================================================================
    // Redeem Tests (No Yield)
    // ========================================================================

    function test_redeem_returnsCapital() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Warp to maturity
        vm.warp(block.timestamp + TERM_DAYS * 1 days);

        uint256 operatorBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        (uint256 principal, uint256 yield) = manager.redeem(positionId);

        assertEq(principal, PRINCIPAL);
        // Without yield simulation, yield depends on aToken balance
        // With exchange rate = 1:1, yield should be 0
        assertEq(yield, 0);
        assertEq(usdc.balanceOf(operator), operatorBefore + PRINCIPAL);
    }

    function test_redeem_deactivatesPosition() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        vm.warp(block.timestamp + TERM_DAYS * 1 days);
        vm.prank(operator);
        manager.redeem(positionId);

        IYieldManager.Position memory pos = manager.getPosition(positionId);
        assertFalse(pos.active);
    }

    function test_redeem_updatesTotals() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        vm.warp(block.timestamp + TERM_DAYS * 1 days);
        vm.prank(operator);
        manager.redeem(positionId);

        assertEq(manager.totalPrincipalDeposited(address(usdc)), 0);
        assertEq(manager.totalExpectedYield(address(usdc)), 0);
    }

    function test_redeem_revertsNotMature() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        vm.prank(operator);
        vm.expectRevert("not mature");
        manager.redeem(positionId);
    }

    function test_redeem_revertsAlreadyRedeemed() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        vm.warp(block.timestamp + TERM_DAYS * 1 days);
        vm.prank(operator);
        manager.redeem(positionId);

        vm.prank(operator);
        vm.expectRevert("position not active");
        manager.redeem(positionId);
    }

    // ========================================================================
    // Yield Simulation Tests — The Core of This Test Suite
    // ========================================================================

    function test_yieldSimulation_aTokenBalanceGrows() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        address aToken = manager.aTokens(address(usdc));
        uint256 balanceBefore = IERC20(aToken).balanceOf(address(manager));
        assertEq(balanceBefore, PRINCIPAL);

        // Simulate 1% yield
        // Must also deal extra USDC to pool to back the yield
        uint256 yieldAmount = PRINCIPAL / 100; // 1%
        usdc.mint(address(pool), yieldAmount);
        pool.simulateYield(address(usdc), 100); // 100 bps = 1%

        uint256 balanceAfter = IERC20(aToken).balanceOf(address(manager));
        assertApproxEqAbs(balanceAfter, PRINCIPAL + yieldAmount, 1); // rounding tolerance
    }

    function test_yieldSimulation_redeemWithYield() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Simulate yield that matches expected (5% annual for 90 days ≈ 1.23%)
        uint256 expectedYield = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Simulate enough yield — use 125 bps as approximation of 90-day 5% APY
        uint256 yieldBps = 125; // ~1.25%
        usdc.mint(address(pool), (PRINCIPAL * yieldBps) / 10_000);
        pool.simulateYield(address(usdc), yieldBps);

        // Warp to maturity
        vm.warp(block.timestamp + TERM_DAYS * 1 days);

        vm.prank(operator);
        (uint256 principal, uint256 yield) = manager.redeem(positionId);

        assertEq(principal, PRINCIPAL);
        // Yield should be capped at expectedYield
        assertEq(yield, expectedYield);
    }

    function test_yieldSimulation_yieldCappedAtExpected() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);
        uint256 expectedYield = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Simulate way more yield than expected (10%)
        usdc.mint(address(pool), PRINCIPAL / 10);
        pool.simulateYield(address(usdc), 1000); // 10%

        vm.warp(block.timestamp + TERM_DAYS * 1 days);

        vm.prank(operator);
        (uint256 principal, uint256 yield) = manager.redeem(positionId);

        assertEq(principal, PRINCIPAL);
        // Should be capped at expected yield, not actual
        assertEq(yield, expectedYield);
    }

    function test_yieldSimulation_underperformance() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Simulate minimal yield (0.1%)
        usdc.mint(address(pool), PRINCIPAL / 1000);
        pool.simulateYield(address(usdc), 10); // 10 bps = 0.1%

        vm.warp(block.timestamp + TERM_DAYS * 1 days);

        vm.prank(operator);
        (uint256 principal, uint256 yield) = manager.redeem(positionId);

        assertEq(principal, PRINCIPAL);
        // Yield should be less than expected (underperformance)
        uint256 expectedYield = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);
        assertTrue(yield < expectedYield, "yield should be less than expected");
        assertTrue(yield > 0, "should still have some yield");
    }

    function test_yieldSimulation_multiplePositionsWithYield() public {
        uint256 id1 = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);
        uint256 id2 = _deposit(PRINCIPAL * 2, 300, 180);

        uint256 expectedYield1 = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Simulate 2% yield — enough for position 1
        uint256 totalPrincipal = PRINCIPAL * 3;
        usdc.mint(address(pool), totalPrincipal * 200 / 10_000);
        pool.simulateYield(address(usdc), 200);

        // Redeem position 1
        vm.warp(block.timestamp + TERM_DAYS * 1 days);

        vm.prank(operator);
        (uint256 p1, uint256 y1) = manager.redeem(id1);
        assertEq(p1, PRINCIPAL);
        assertEq(y1, expectedYield1); // capped at expected

        // Position 2 still active
        IYieldManager.Position memory pos2 = manager.getPosition(id2);
        assertTrue(pos2.active);
    }

    // ========================================================================
    // Position Value & Accrual Tests
    // ========================================================================

    function test_getPositionValue_atStart() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        (uint256 value, uint256 accrued) = manager.getPositionValue(positionId);
        assertEq(value, PRINCIPAL);
        assertEq(accrued, 0);
    }

    function test_getPositionValue_midTerm() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);
        uint256 expectedYield = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Warp to halfway
        vm.warp(block.timestamp + (TERM_DAYS * 1 days) / 2);

        (uint256 value, uint256 accrued) = manager.getPositionValue(positionId);
        assertApproxEqAbs(accrued, expectedYield / 2, 1);
        assertApproxEqAbs(value, PRINCIPAL + expectedYield / 2, 1);
    }

    function test_getPositionValue_atMaturity() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);
        uint256 expectedYield = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);

        vm.warp(block.timestamp + TERM_DAYS * 1 days);

        (uint256 value, uint256 accrued) = manager.getPositionValue(positionId);
        assertEq(accrued, expectedYield);
        assertEq(value, PRINCIPAL + expectedYield);
    }

    function test_getPositionValue_afterRedeem() public {
        uint256 positionId = _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        vm.warp(block.timestamp + TERM_DAYS * 1 days);
        vm.prank(operator);
        manager.redeem(positionId);

        (uint256 value, uint256 accrued) = manager.getPositionValue(positionId);
        assertEq(value, 0);
        assertEq(accrued, 0);
    }

    // ========================================================================
    // APY Reading Tests
    // ========================================================================

    function test_currentApyBps_returnsConvertedRate() public {
        // Set 5% APY in ray format: 0.05e27
        pool.setLiquidityRate(address(usdc), uint128(5e25));

        uint256 apyBps = manager.currentApyBps(address(usdc));
        assertEq(apyBps, 500); // 5% = 500 bps
    }

    function test_currentApyBps_zeroForUnsupported() public {
        address fake = makeAddr("fake");
        assertEq(manager.currentApyBps(fake), 0);
    }

    function test_currentApyBps_setViaBpsHelper() public {
        pool.setLiquidityRateBps(address(usdc), 350); // 3.5%

        uint256 apyBps = manager.currentApyBps(address(usdc));
        assertEq(apyBps, 350);
    }

    function test_currentApyBps_highRate() public {
        pool.setLiquidityRateBps(address(usdc), 2000); // 20%

        uint256 apyBps = manager.currentApyBps(address(usdc));
        assertEq(apyBps, 2000);
    }

    // ========================================================================
    // Liquidity Management Tests
    // ========================================================================

    function test_addLiquidity() public {
        usdc.mint(treasury, 5000e6);

        vm.startPrank(treasury);
        usdc.approve(address(manager), 5000e6);
        manager.addLiquidity(address(usdc), 5000e6);
        vm.stopPrank();

        // aToken balance should reflect added liquidity
        assertEq(manager.totalAssets(address(usdc)), 5000e6);
    }

    function test_removeLiquidity_fromExcess() public {
        // Add liquidity first
        usdc.mint(treasury, 5000e6);
        vm.startPrank(treasury);
        usdc.approve(address(manager), 5000e6);
        manager.addLiquidity(address(usdc), 5000e6);
        vm.stopPrank();

        // Remove some (all is excess since no positions)
        address recipient = makeAddr("recipient");
        vm.prank(treasury);
        manager.removeLiquidity(address(usdc), 2000e6, recipient);

        assertEq(usdc.balanceOf(recipient), 2000e6);
    }

    function test_removeLiquidity_revertsExceedsExcess() public {
        // Deposit creates liabilities
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        address recipient = makeAddr("recipient");
        vm.prank(treasury);
        vm.expectRevert("insufficient excess liquidity");
        manager.removeLiquidity(address(usdc), PRINCIPAL, recipient);
    }

    // ========================================================================
    // Balance Sheet & Yield Performance Tests
    // ========================================================================

    function test_getBalanceSheet_afterDeposit() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        (uint256 assets, uint256 liabilities, int256 equity) = manager.getBalanceSheet(address(usdc));

        assertEq(assets, PRINCIPAL);
        uint256 expectedYield = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);
        assertEq(liabilities, PRINCIPAL + expectedYield);
        assertEq(equity, -int256(expectedYield)); // negative since no yield yet
    }

    function test_getBalanceSheet_withYield() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Simulate yield that covers the expected amount
        uint256 expectedYield = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);
        uint256 yieldBps = (expectedYield * 10_000) / PRINCIPAL + 1;
        usdc.mint(address(pool), (PRINCIPAL * yieldBps) / 10_000);
        pool.simulateYield(address(usdc), yieldBps);

        (uint256 assets, uint256 liabilities, int256 equity) = manager.getBalanceSheet(address(usdc));

        assertTrue(assets >= liabilities, "should be solvent with yield");
        assertTrue(equity >= 0, "equity should be non-negative");
    }

    function test_getYieldPerformance_noYield() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        (uint256 actualYield, uint256 expectedYield, int256 surplus) = manager.getYieldPerformance(address(usdc));

        assertEq(actualYield, 0);
        assertTrue(expectedYield > 0);
        assertTrue(surplus < 0, "should show underperformance");
    }

    function test_getYieldPerformance_withYield() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);
        uint256 expected = _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);

        // Simulate exact expected yield
        uint256 yieldBps = (expected * 10_000) / PRINCIPAL + 1;
        usdc.mint(address(pool), (PRINCIPAL * yieldBps) / 10_000);
        pool.simulateYield(address(usdc), yieldBps);

        (uint256 actualYield, uint256 expectedYield,) = manager.getYieldPerformance(address(usdc));

        assertTrue(actualYield > 0);
        assertEq(expectedYield, expected);
    }

    // ========================================================================
    // Token Stats Tests
    // ========================================================================

    function test_getTokenStats() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        IYieldManager.TokenStats memory stats = manager.getTokenStats(address(usdc));
        assertEq(stats.totalDeposited, PRINCIPAL);
        assertEq(stats.totalExpectedYield, _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS));
        assertEq(stats.availableLiquidity, PRINCIPAL);
        assertEq(stats.pendingMaturities, PRINCIPAL + _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS));
    }

    function test_activePositionCount() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        assertEq(manager.activePositionCount(), 3);

        // Redeem one
        vm.warp(block.timestamp + TERM_DAYS * 1 days);
        vm.prank(operator);
        manager.redeem(1);

        assertEq(manager.activePositionCount(), 2);
    }

    function test_totalAssets_reflectsATokenBalance() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);
        assertEq(manager.totalAssets(address(usdc)), PRINCIPAL);

        // After yield simulation
        usdc.mint(address(pool), PRINCIPAL / 100);
        pool.simulateYield(address(usdc), 100);

        assertApproxEqAbs(manager.totalAssets(address(usdc)), PRINCIPAL + PRINCIPAL / 100, 1);
    }

    function test_totalLiabilities() public {
        _deposit(PRINCIPAL, RATE_BPS, TERM_DAYS);

        uint256 expected = PRINCIPAL + _expectedYield(PRINCIPAL, RATE_BPS, TERM_DAYS);
        assertEq(manager.totalLiabilities(address(usdc)), expected);
    }

    function test_getSupportedTokens() public view {
        address[] memory tokens = manager.getSupportedTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usdc));
    }
}

// ============================================================================
// AaveV3StrategyAdapter Tests
// ============================================================================

import {AaveV3StrategyAdapter} from "../src/adapters/AaveV3StrategyAdapter.sol";

contract AaveV3StrategyAdapterTest is Test {
    AaveV3StrategyAdapter public adapter;
    MockAaveV3Pool public pool;
    MockUSDC public usdc;

    address admin = makeAddr("admin");
    address treasuryAddr = makeAddr("treasury");

    function setUp() public {
        pool = new MockAaveV3Pool();
        usdc = new MockUSDC();
        pool.initReserve(address(usdc));

        adapter = new AaveV3StrategyAdapter(admin, address(pool));

        vm.startPrank(admin);
        adapter.grantRole(adapter.TREASURY_ROLE(), treasuryAddr);
        adapter.addSupportedToken(address(usdc));
        vm.stopPrank();
    }

    function test_deploy_suppliesTokens() public {
        uint256 amount = 5000e6;
        usdc.mint(treasuryAddr, amount);

        vm.startPrank(treasuryAddr);
        usdc.transfer(address(adapter), amount);
        adapter.deploy(address(usdc), amount);
        vm.stopPrank();

        assertEq(adapter.totalDeployed(address(usdc)), amount);
        assertEq(adapter.currentValue(address(usdc)), amount);
    }

    function test_deploy_multipleDeployments() public {
        uint256 amount1 = 3000e6;
        uint256 amount2 = 7000e6;

        usdc.mint(treasuryAddr, amount1 + amount2);

        vm.startPrank(treasuryAddr);
        usdc.transfer(address(adapter), amount1);
        adapter.deploy(address(usdc), amount1);
        usdc.transfer(address(adapter), amount2);
        adapter.deploy(address(usdc), amount2);
        vm.stopPrank();

        assertEq(adapter.totalDeployed(address(usdc)), amount1 + amount2);
    }

    function test_withdraw_returnsTokens() public {
        uint256 amount = 5000e6;
        usdc.mint(treasuryAddr, amount);

        vm.startPrank(treasuryAddr);
        usdc.transfer(address(adapter), amount);
        adapter.deploy(address(usdc), amount);

        uint256 withdrawn = adapter.withdraw(address(usdc), 2000e6);
        vm.stopPrank();

        assertEq(withdrawn, 2000e6);
        assertEq(adapter.totalDeployed(address(usdc)), 3000e6);
        assertEq(usdc.balanceOf(treasuryAddr), 2000e6);
    }

    function test_currentValue_withYield() public {
        uint256 amount = 10_000e6;
        usdc.mint(treasuryAddr, amount);

        vm.startPrank(treasuryAddr);
        usdc.transfer(address(adapter), amount);
        adapter.deploy(address(usdc), amount);
        vm.stopPrank();

        // Simulate 2% yield
        usdc.mint(address(pool), amount * 200 / 10_000);
        pool.simulateYield(address(usdc), 200);

        uint256 current = adapter.currentValue(address(usdc));
        uint256 deployed = adapter.totalDeployed(address(usdc));

        assertTrue(current > deployed, "current value should exceed deployed principal");
        assertApproxEqAbs(current, amount + amount * 200 / 10_000, 1);
    }

    function test_withdraw_withYield_capturesExtra() public {
        uint256 amount = 10_000e6;
        usdc.mint(treasuryAddr, amount);

        vm.startPrank(treasuryAddr);
        usdc.transfer(address(adapter), amount);
        adapter.deploy(address(usdc), amount);
        vm.stopPrank();

        // Simulate 5% yield
        usdc.mint(address(pool), amount * 500 / 10_000);
        pool.simulateYield(address(usdc), 500);

        // Withdraw full deployed amount
        vm.prank(treasuryAddr);
        uint256 withdrawn = adapter.withdraw(address(usdc), amount);

        assertEq(withdrawn, amount);
        assertEq(usdc.balanceOf(treasuryAddr), amount);

        // aToken balance should still have the yield portion
        uint256 remaining = adapter.currentValue(address(usdc));
        assertApproxEqAbs(remaining, amount * 500 / 10_000, 1);
    }

    function test_isLiquid() public {
        assertTrue(adapter.isLiquid());
    }

    function test_name() public {
        assertEq(adapter.name(), "Aave V3");
    }

    function test_supportsToken() public {
        assertTrue(adapter.supportsToken(address(usdc)));
        assertFalse(adapter.supportsToken(address(1)));
    }
}
