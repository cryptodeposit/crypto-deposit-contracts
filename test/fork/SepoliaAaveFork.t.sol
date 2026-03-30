// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AaveV3YieldManager} from "../../src/AaveV3YieldManager.sol";
import {AaveV3StrategyAdapter} from "../../src/adapters/AaveV3StrategyAdapter.sol";
import {IYieldManager} from "../../src/interfaces/IYieldManager.sol";

/**
 * @title SepoliaAaveForkTest
 * @notice Fork test against real Aave V3 on Sepolia
 * @dev Run: FORK_RPC_URL=<sepolia_rpc> forge test --match-contract SepoliaAaveForkTest -vvv
 *
 * Addresses (from bgd-labs/aave-address-book AaveV3Sepolia.sol):
 *   Pool:           0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
 *   USDC:           0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8  (Aave test USDC, 6 decimals)
 *   aUSDC:          0x16dA4541aD1807f4443d92D26044C1147406EB80
 *
 * Note: Aave V3 on Sepolia uses its own test USDC, NOT Circle's Sepolia USDC.
 */
contract SepoliaAaveForkTest is Test {
    // Sepolia Aave V3 addresses
    address constant AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant AAVE_USDC = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;
    address constant AAVE_AUSDC = 0x16dA4541aD1807f4443d92D26044C1147406EB80;

    AaveV3YieldManager public yieldManager;
    AaveV3StrategyAdapter public adapter;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");

    uint256 constant PRINCIPAL = 10_000e6; // 10,000 USDC

    function setUp() public {
        // Fork Sepolia
        string memory forkUrl = vm.envString("FORK_RPC_URL");
        vm.createSelectFork(forkUrl);

        // Verify chain
        assertEq(block.chainid, 11155111, "Not Sepolia");

        // Verify Aave contracts exist
        assertTrue(AAVE_POOL.code.length > 0, "Aave Pool not deployed");
        assertTrue(AAVE_USDC.code.length > 0, "Aave USDC not deployed");
        assertTrue(AAVE_AUSDC.code.length > 0, "Aave aUSDC not deployed");

        // Deploy our contracts
        vm.startPrank(admin);

        // 1. AaveV3YieldManager
        yieldManager = new AaveV3YieldManager(admin, AAVE_POOL);
        yieldManager.grantRole(yieldManager.OPERATOR_ROLE(), operator);
        yieldManager.addSupportedToken(AAVE_USDC);

        // 2. AaveV3StrategyAdapter
        adapter = new AaveV3StrategyAdapter(admin, AAVE_POOL);
        adapter.addSupportedToken(AAVE_USDC);

        vm.stopPrank();
    }

    // ========================================================================
    // Basic Connectivity
    // ========================================================================

    function test_aavePoolExists() public view {
        assertTrue(AAVE_POOL.code.length > 0, "Pool not deployed");
    }

    function test_aaveUsdcIsERC20() public view {
        // Verify we can read basic ERC20 properties
        string memory sym = ERC20(AAVE_USDC).symbol();
        assertTrue(bytes(sym).length > 0, "Symbol should be non-empty");

        uint8 decimals = ERC20(AAVE_USDC).decimals();
        assertEq(decimals, 6, "USDC should be 6 decimals");
    }

    function test_aaveReserveDataReturnsAToken() public view {
        address aToken = yieldManager.aTokens(AAVE_USDC);
        assertEq(aToken, AAVE_AUSDC, "aToken mismatch");
    }

    // ========================================================================
    // YieldManager — Real Aave V3
    // ========================================================================

    function test_yieldManager_depositToRealAave() public {
        // Give operator USDC
        deal(AAVE_USDC, operator, PRINCIPAL);
        assertEq(IERC20(AAVE_USDC).balanceOf(operator), PRINCIPAL);

        uint256 maturity = block.timestamp + 90 days;

        vm.startPrank(operator);
        IERC20(AAVE_USDC).approve(address(yieldManager), PRINCIPAL);
        uint256 positionId = yieldManager.deposit(AAVE_USDC, PRINCIPAL, maturity, 500);
        vm.stopPrank();

        // Position created
        IYieldManager.Position memory pos = yieldManager.getPosition(positionId);
        assertEq(pos.principal, PRINCIPAL);
        assertTrue(pos.active);
        assertEq(pos.token, AAVE_USDC);

        // aToken balance should be approximately PRINCIPAL
        uint256 aTokenBal = IERC20(AAVE_AUSDC).balanceOf(address(yieldManager));
        assertApproxEqAbs(aTokenBal, PRINCIPAL, 2, "aToken balance should match principal");
    }

    function test_yieldManager_aTokenBalanceGrowsOverTime() public {
        deal(AAVE_USDC, operator, PRINCIPAL);

        vm.startPrank(operator);
        IERC20(AAVE_USDC).approve(address(yieldManager), PRINCIPAL);
        yieldManager.deposit(AAVE_USDC, PRINCIPAL, block.timestamp + 365 days, 500);
        vm.stopPrank();

        uint256 balanceBefore = IERC20(AAVE_AUSDC).balanceOf(address(yieldManager));

        // Warp 30 days — aToken balance should grow via Aave's interest accrual
        vm.warp(block.timestamp + 30 days);

        uint256 balanceAfter = IERC20(AAVE_AUSDC).balanceOf(address(yieldManager));

        // On testnet, rates might be zero or very low. Just verify it's >= what we deposited.
        assertTrue(balanceAfter >= balanceBefore, "aToken balance should not decrease");
    }

    function test_yieldManager_redeemFromRealAave() public {
        deal(AAVE_USDC, operator, PRINCIPAL);

        vm.startPrank(operator);
        IERC20(AAVE_USDC).approve(address(yieldManager), PRINCIPAL);
        uint256 positionId = yieldManager.deposit(AAVE_USDC, PRINCIPAL, block.timestamp + 90 days, 500);
        vm.stopPrank();

        // Warp to maturity
        vm.warp(block.timestamp + 90 days);

        uint256 operatorBalBefore = IERC20(AAVE_USDC).balanceOf(operator);

        vm.prank(operator);
        (uint256 principal,) = yieldManager.redeem(positionId);

        uint256 operatorBalAfter = IERC20(AAVE_USDC).balanceOf(operator);

        assertEq(principal, PRINCIPAL);
        assertTrue(operatorBalAfter >= operatorBalBefore + PRINCIPAL, "should receive at least principal");

        // Position deactivated
        IYieldManager.Position memory pos = yieldManager.getPosition(positionId);
        assertFalse(pos.active);
    }

    function test_yieldManager_currentApyBps() public view {
        uint256 apyBps = yieldManager.currentApyBps(AAVE_USDC);
        // On testnet, APY could be anything including 0
        // Just verify it doesn't revert and returns a sane value
        assertTrue(apyBps < 100_000, "APY should be less than 1000%");
    }

    function test_yieldManager_balanceSheet() public {
        deal(AAVE_USDC, operator, PRINCIPAL);

        vm.startPrank(operator);
        IERC20(AAVE_USDC).approve(address(yieldManager), PRINCIPAL);
        yieldManager.deposit(AAVE_USDC, PRINCIPAL, block.timestamp + 90 days, 500);
        vm.stopPrank();

        (uint256 assets, uint256 liabilities,) = yieldManager.getBalanceSheet(AAVE_USDC);

        assertApproxEqAbs(assets, PRINCIPAL, 2, "assets should be approx principal");
        assertTrue(liabilities > PRINCIPAL, "liabilities should include expected yield");
    }

    // ========================================================================
    // StrategyAdapter — Real Aave V3
    // ========================================================================

    function test_adapter_deployToRealAave() public {
        deal(AAVE_USDC, admin, PRINCIPAL);

        vm.startPrank(admin);
        IERC20(AAVE_USDC).transfer(address(adapter), PRINCIPAL);
        adapter.deploy(AAVE_USDC, PRINCIPAL);
        vm.stopPrank();

        assertEq(adapter.totalDeployed(AAVE_USDC), PRINCIPAL);

        uint256 currentVal = adapter.currentValue(AAVE_USDC);
        assertApproxEqAbs(currentVal, PRINCIPAL, 2, "current value should match deployed");
    }

    function test_adapter_withdrawFromRealAave() public {
        deal(AAVE_USDC, admin, PRINCIPAL);

        vm.startPrank(admin);
        IERC20(AAVE_USDC).transfer(address(adapter), PRINCIPAL);
        adapter.deploy(AAVE_USDC, PRINCIPAL);

        uint256 withdrawn = adapter.withdraw(AAVE_USDC, PRINCIPAL / 2);
        vm.stopPrank();

        assertApproxEqAbs(withdrawn, PRINCIPAL / 2, 2);
        assertEq(adapter.totalDeployed(AAVE_USDC), PRINCIPAL / 2);
    }

    function test_adapter_valueGrowsOverTime() public {
        deal(AAVE_USDC, admin, PRINCIPAL);

        vm.startPrank(admin);
        IERC20(AAVE_USDC).transfer(address(adapter), PRINCIPAL);
        adapter.deploy(AAVE_USDC, PRINCIPAL);
        vm.stopPrank();

        uint256 valueBefore = adapter.currentValue(AAVE_USDC);

        vm.warp(block.timestamp + 30 days);

        uint256 valueAfter = adapter.currentValue(AAVE_USDC);
        assertTrue(valueAfter >= valueBefore, "value should not decrease over time");
    }

    function test_adapter_isLiquid() public view {
        assertTrue(adapter.isLiquid(), "Aave V3 should be liquid");
    }

    function test_adapter_supportsToken() public view {
        assertTrue(adapter.supportsToken(AAVE_USDC));
        assertFalse(adapter.supportsToken(address(1)));
    }

    // ========================================================================
    // Multiple Positions & Larger Amounts
    // ========================================================================

    function test_multipleDepositsAndRedeems() public {
        uint256 amount1 = 5_000e6;
        uint256 amount2 = 15_000e6;
        uint256 amount3 = 25_000e6;

        deal(AAVE_USDC, operator, amount1 + amount2 + amount3);

        vm.startPrank(operator);
        IERC20(AAVE_USDC).approve(address(yieldManager), amount1 + amount2 + amount3);

        uint256 id1 = yieldManager.deposit(AAVE_USDC, amount1, block.timestamp + 30 days, 400);
        uint256 id2 = yieldManager.deposit(AAVE_USDC, amount2, block.timestamp + 90 days, 500);
        uint256 id3 = yieldManager.deposit(AAVE_USDC, amount3, block.timestamp + 180 days, 600);
        vm.stopPrank();

        assertEq(yieldManager.activePositionCount(), 3);
        assertEq(yieldManager.totalPrincipalDeposited(AAVE_USDC), amount1 + amount2 + amount3);

        // Redeem position 1 at maturity
        vm.warp(block.timestamp + 30 days);
        vm.prank(operator);
        (uint256 p1,) = yieldManager.redeem(id1);
        assertEq(p1, amount1);

        assertEq(yieldManager.activePositionCount(), 2);
        assertEq(yieldManager.totalPrincipalDeposited(AAVE_USDC), amount2 + amount3);

        // Redeem position 2
        vm.warp(block.timestamp + 60 days);
        vm.prank(operator);
        (uint256 p2,) = yieldManager.redeem(id2);
        assertEq(p2, amount2);

        // Position 3 still active
        assertTrue(yieldManager.getPosition(id3).active);
    }

    function test_largeDeposit_100k() public {
        uint256 largeAmount = 100_000e6;
        deal(AAVE_USDC, operator, largeAmount);

        vm.startPrank(operator);
        IERC20(AAVE_USDC).approve(address(yieldManager), largeAmount);
        uint256 posId = yieldManager.deposit(AAVE_USDC, largeAmount, block.timestamp + 365 days, 500);
        vm.stopPrank();

        IYieldManager.Position memory pos = yieldManager.getPosition(posId);
        assertEq(pos.principal, largeAmount);

        uint256 aTokenBal = IERC20(AAVE_AUSDC).balanceOf(address(yieldManager));
        assertApproxEqAbs(aTokenBal, largeAmount, 10, "large deposit aToken balance");
    }
}
