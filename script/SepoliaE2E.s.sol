// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableTokenUpgradeable} from "../src/StableTokenUpgradeable.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {DiscountBillERC5095Token} from "../src/BillTokenFactory.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {AaveV3StrategyAdapter} from "../src/adapters/AaveV3StrategyAdapter.sol";
import {MockAaveV3Pool, MockAToken} from "../test/mocks/MockAaveV3Pool.sol";
import {IDiscountBill} from "../src/interfaces/IDiscountBill.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";

/**
 * @title SepoliaE2E
 * @notice Fork-based end-to-end test against live Sepolia deployment
 * @dev Forks live chain and uses vm.warp for maturity simulation.
 *      Run with --fork-url (not --rpc-url) and WITHOUT --broadcast.
 *
 * Usage:
 *   DEPLOYER_KEY=0x... STABLE_TOKEN=0x... COMPLIANCE=0x... TRAVEL_RULE=0x... \
 *   TREASURY=0x... DISCOUNT_BILL=0x... \
 *   AAVE_POOL=0x... AAVE_ADAPTER=0x... \
 *   forge script script/SepoliaE2E.s.sol:SepoliaE2E \
 *     --fork-url https://ethereum-sepolia-rpc.publicnode.com
 */
contract SepoliaE2E is Script {
    // Contracts
    StableTokenUpgradeable stableToken;
    ComplianceRegistryUpgradeable compliance;
    TravelRuleRegistryUpgradeable travel;
    TreasuryUpgradeable treasury;
    DiscountBillERC5095Upgradeable bill;
    AaveV3StrategyAdapter aaveAdapter;
    MockAaveV3Pool aavePool;

    // Addresses
    address admin;
    address depositor;
    address depositWallet;
    address introducingWallet;

    // Constants
    uint256 constant PRINCIPAL = 100_000e6;   // $100k
    uint256 constant ANNUAL_RATE_BPS = 500;   // 5%
    uint256 constant DURATION_DAYS = 90;
    uint256 constant RESERVE_RATIO_BPS = 2000; // 20%

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        admin = vm.addr(deployerKey);

        // Load deployed addresses
        stableToken = StableTokenUpgradeable(vm.envAddress("STABLE_TOKEN"));
        compliance = ComplianceRegistryUpgradeable(vm.envAddress("COMPLIANCE"));
        travel = TravelRuleRegistryUpgradeable(vm.envAddress("TRAVEL_RULE"));
        treasury = TreasuryUpgradeable(vm.envAddress("TREASURY"));
        bill = DiscountBillERC5095Upgradeable(vm.envAddress("DISCOUNT_BILL"));
        aaveAdapter = AaveV3StrategyAdapter(vm.envAddress("AAVE_ADAPTER"));
        aavePool = MockAaveV3Pool(vm.envAddress("AAVE_POOL"));

        // Create test addresses
        depositor = makeAddr("e2e_depositor");
        depositWallet = makeAddr("e2e_depositWallet");
        introducingWallet = makeAddr("e2e_introducer");

        console.log("=== SEPOLIA E2E TEST ===");
        console.log("Admin:", admin);
        console.log("Chain ID:", block.chainid);
        console.log("");

        // Fund depositor from admin's balance
        vm.prank(admin);
        stableToken.transfer(depositor, PRINCIPAL * 2);
        console.log("[OK] Funded depositor with", (PRINCIPAL * 2) / 1e6, "mUSD");

        // ================================================================
        // TEST 1: Full DiscountBillERC5095 Lifecycle
        // ================================================================
        console.log("");
        console.log("=== TEST 1: DiscountBillERC5095 Full Lifecycle ===");
        _testDiscountBillLifecycle();

        // ================================================================
        // TEST 2: ERC5095 Second Bill Path
        // ================================================================
        console.log("");
        console.log("=== TEST 2: ERC5095 Second Bill Path ===");
        _testERC5095Path();

        console.log("");
        console.log("=== ALL E2E TESTS PASSED ===");
    }

    function _testDiscountBillLifecycle() internal {
        // ── Step 1: Preclear travel rules ──
        _preclear(address(stableToken), depositor, admin, PRINCIPAL);
        console.log("[1] Travel rule precleared");

        // ── Step 2: Depositor approves, operator issues bill ──
        vm.prank(depositor);
        stableToken.approve(address(bill), PRINCIPAL);

        vm.prank(admin); // admin has OPERATOR_ROLE
        uint256 billId = bill.issue(
            depositor,          // owner
            depositor,          // depositor
            depositWallet,      // redemption wallet
            introducingWallet,  // commission wallet
            address(stableToken),
            PRINCIPAL,
            ANNUAL_RATE_BPS,
            DURATION_DAYS
        );
        console.log("[2] Bill issued, ID:", billId);

        // ── Step 3: Verify treasury state ──
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        ITreasury.TokenState memory state = treasury.getTokenState(address(stableToken));

        require(info.principal == PRINCIPAL, "E2E: principal mismatch");
        require(info.redemptionValue > PRINCIPAL, "E2E: redemption should exceed principal");
        require(state.depositClaims >= PRINCIPAL, "E2E: treasury depositClaims");
        require(state.depositLiabilities >= info.redemptionValue, "E2E: treasury liabilities");
        console.log("[3] Treasury state verified: claims=", state.depositClaims / 1e6,
            "liabilities=", state.depositLiabilities / 1e6);

        // ── Step 4: Inject interest gap (protocol capital) ──
        uint256 interestGap = info.redemptionValue - PRINCIPAL;
        vm.prank(admin);
        stableToken.transfer(address(treasury), interestGap);
        console.log("[4] Interest gap covered:", interestGap / 1e6, "mUSD");

        // ── Step 5: Allocate to Aave strategy ──
        uint256 onChain = stableToken.balanceOf(address(treasury));
        uint256 floor = (state.depositLiabilities * RESERVE_RATIO_BPS) / 10000;
        uint256 deployAmount = onChain - floor - 1e6; // safety buffer

        vm.prank(admin);
        treasury.allocateToStrategy(address(aaveAdapter), address(stableToken), deployAmount, 0);

        uint256 strategyDeployed = treasury.getStrategyDeployed(address(aaveAdapter), address(stableToken));
        require(strategyDeployed == deployAmount, "E2E: strategy deployed mismatch");
        require(treasury.isALMHealthy(address(stableToken)), "E2E: ALM unhealthy after allocation");
        console.log("[5] Allocated", deployAmount / 1e6, "to Aave strategy");

        // ── Step 6: Simulate yield ──
        _fundPoolForYield(100); // 1%
        uint256 aTokenValue = aaveAdapter.currentValue(address(stableToken));
        require(aTokenValue > deployAmount, "E2E: no yield accrued");
        console.log("[6] Yield simulated: aToken value=", aTokenValue / 1e6);

        // ── Step 7: Pause treasury — allocation blocked, redeem still works ──
        vm.prank(admin);
        treasury.pause();

        // Allocation should revert when paused
        bool allocReverted = false;
        vm.prank(admin);
        try treasury.allocateToStrategy(address(aaveAdapter), address(stableToken), 1e6, 0) {
            // Should not reach here
        } catch {
            allocReverted = true;
        }
        require(allocReverted, "E2E: allocation should revert when paused");
        console.log("[7] Pause verified: allocation blocked");

        vm.prank(admin);
        treasury.unpause();
        console.log("[7] Unpause: resumed");

        // ── Step 8: Harvest yield ──
        vm.prank(admin);
        treasury.harvestYield(address(aaveAdapter), address(stableToken));

        state = treasury.getTokenState(address(stableToken));
        require(state.protocolRevenue > 0, "E2E: no revenue after harvest");
        console.log("[8] Yield harvested: protocol revenue=", state.protocolRevenue / 1e6);

        // ── Step 9: Warp to maturity ──
        vm.warp(block.timestamp + DURATION_DAYS * 1 days);
        require(bill.isMature(billId), "E2E: bill should be mature");
        console.log("[9] Warped to maturity");

        // ── Step 10: Withdraw from strategy ──
        vm.prank(admin);
        treasury.withdrawFromStrategy(address(aaveAdapter), address(stableToken), deployAmount);
        console.log("[10] Withdrawn from strategy");

        // ── Step 11: Preclear and redeem ──
        uint256 netPayment = info.redemptionValue - info.commissionAmount;
        _preclear(address(stableToken), address(treasury), depositWallet, netPayment);
        _preclear(address(stableToken), address(treasury), introducingWallet, info.commissionAmount);

        uint256 walletBefore = stableToken.balanceOf(depositWallet);
        uint256 introducerBefore = stableToken.balanceOf(introducingWallet);

        vm.prank(depositor);
        bill.redeem(billId);

        uint256 walletPayout = stableToken.balanceOf(depositWallet) - walletBefore;
        uint256 introducerPayout = stableToken.balanceOf(introducingWallet) - introducerBefore;
        require(walletPayout == netPayment, "E2E: deposit wallet payout mismatch");
        require(introducerPayout == info.commissionAmount, "E2E: introducer payout mismatch");
        console.log("[11] Redeemed: deposit wallet=", walletPayout / 1e6,
            "introducer=", introducerPayout / 1e6);

        // ── Step 12: Verify clean state ──
        state = treasury.getTokenState(address(stableToken));
        require(state.depositClaims == 0, "E2E: claims should be zero");
        require(state.depositLiabilities == 0, "E2E: liabilities should be zero");
        console.log("[12] Clean state verified: claims=0, liabilities=0");

        // ── Step 13: Withdraw protocol revenue ──
        uint256 revenue = state.protocolRevenue;
        if (revenue > 0) {
            vm.prank(admin);
            treasury.withdrawRevenue(address(stableToken), revenue, admin);
            console.log("[13] Revenue withdrawn:", revenue / 1e6, "mUSD");
        }

        // ── Final balance sheet ──
        _logBalanceSheet();
    }

    function _testERC5095Path() internal {
        uint256 principal5095 = 50_000e6; // $50k

        // Fund depositor
        vm.prank(admin);
        stableToken.transfer(depositor, principal5095);

        // Preclear
        _preclear(address(stableToken), depositor, admin, principal5095);

        // Approve and issue
        vm.prank(depositor);
        stableToken.approve(address(bill), principal5095);

        vm.prank(admin);
        uint256 billId = bill.issue(
            depositor,
            depositor,
            depositWallet,
            introducingWallet,
            address(stableToken),
            principal5095,
            ANNUAL_RATE_BPS,
            DURATION_DAYS
        );
        console.log("[1] ERC5095 bill issued, ID:", billId);

        // Verify bill token was created
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        require(info.principal == principal5095, "E2E-5095: principal mismatch");
        console.log("[2] Bill verified: principal=", info.principal / 1e6,
            "redemption=", info.redemptionValue / 1e6);

        // Cover interest gap
        uint256 gap = info.redemptionValue - principal5095;
        vm.prank(admin);
        stableToken.transfer(address(treasury), gap);

        // Warp to maturity
        vm.warp(block.timestamp + DURATION_DAYS * 1 days);
        require(bill.isMature(billId), "E2E-5095: bill should be mature");

        // Preclear and redeem
        uint256 netPayment = info.redemptionValue - info.commissionAmount;
        _preclear(address(stableToken), address(treasury), depositWallet, netPayment);
        _preclear(address(stableToken), address(treasury), introducingWallet, info.commissionAmount);

        uint256 walletBefore = stableToken.balanceOf(depositWallet);

        vm.prank(depositor);
        bill.redeem(billId);

        uint256 payout = stableToken.balanceOf(depositWallet) - walletBefore;
        require(payout == netPayment, "E2E-5095: payout mismatch");
        console.log("[3] Redeemed via ERC5095: payout=", payout / 1e6);

        console.log("[OK] ERC5095 path complete");
    }

    // ============================================================================
    // Helpers
    // ============================================================================

    function _preclear(address token, address from, address to, uint256 amount) internal {
        vm.prank(admin); // admin has ORDERING_ROLE via operator
        travel.preclear(
            token,
            from,
            to,
            amount,
            bytes32(0),
            bytes32(0),
            bytes32(0)
        );
    }

    function _fundPoolForYield(uint256 yieldBps) internal {
        MockAToken aToken = aavePool.getMockAToken(address(stableToken));
        uint256 currentTotal = (aToken.totalShares() * aToken.exchangeRate()) / 1e18;
        uint256 yieldAmount = (currentTotal * yieldBps) / 10000;

        // Transfer extra mUSD from admin to pool to back the yield
        vm.prank(admin);
        stableToken.transfer(address(aavePool), yieldAmount);

        // Simulate yield increase on the exchange rate
        aavePool.simulateYield(address(stableToken), yieldBps);
    }

    function _logBalanceSheet() internal view {
        console.log("");
        console.log("--- Balance Sheet ---");
        ITreasury.TokenState memory state = treasury.getTokenState(address(stableToken));
        console.log("Deposit Claims:", state.depositClaims / 1e6);
        console.log("Deposit Liabilities:", state.depositLiabilities / 1e6);
        console.log("Collateral Claims:", state.collateralClaims / 1e6);
        console.log("Lending Pool:", state.lendingPool / 1e6);
        console.log("Deployed:", state.deployed / 1e6);
        console.log("Protocol Revenue:", state.protocolRevenue / 1e6);
        console.log("Reserve Ratio:", state.reserveRatioBps, "bps");
        console.log("On-chain balance:", stableToken.balanceOf(address(treasury)) / 1e6);
        console.log("Total Assets:", treasury.totalAssets(address(stableToken)) / 1e6);
        console.log("Total Liabilities:", treasury.totalLiabilities(address(stableToken)) / 1e6);
        console.log("ALM Healthy:", treasury.isALMHealthy(address(stableToken)));
    }
}
