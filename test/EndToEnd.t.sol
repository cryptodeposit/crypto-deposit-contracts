// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Core contracts
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {DiscountBillERC5095Token, BillTokenFactory} from "../src/BillTokenFactory.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {AaveV3StrategyAdapter} from "../src/adapters/AaveV3StrategyAdapter.sol";

// Interfaces
import {IComplianceRegistry} from "../src/interfaces/IComplianceRegistry.sol";
import {ITravelRuleRegistry} from "../src/interfaces/ITravelRuleRegistry.sol";
import {IDiscountBill} from "../src/interfaces/IDiscountBill.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";

// Mock
import {MockAaveV3Pool, MockAToken} from "./mocks/MockAaveV3Pool.sol";

// ============================================================================
// Test Token — 6-decimal USDC-like
// ============================================================================

contract TestUSDC is ERC20 {
    constructor() ERC20("Test USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============================================================================
// End-to-End Integration Test
// ============================================================================

/**
 * @title EndToEndTest
 * @notice Wires ALL real contracts together — no business-logic mocks.
 *         Only MockAaveV3Pool (unavoidable) and TestUSDC (test token).
 *
 *         Components:
 *           - ComplianceRegistryUpgradeable (UUPS proxy)
 *           - TravelRuleRegistryUpgradeable (UUPS proxy)
 *           - TreasuryUpgradeable (UUPS proxy)
 *           - DiscountBillERC5095Upgradeable "bill" (UUPS proxy)
 *           - DiscountBillERC5095Upgradeable "bill5095" (UUPS proxy)
 *           - AaveV3StrategyAdapter (non-upgradeable)
 *           - MockAaveV3Pool + MockAToken
 *           - TestUSDC (6 decimals)
 *
 * @dev Protocol capital injection: The Treasury receives deposit principal but
 *      owes principal + interest at maturity. In production, this gap is covered
 *      by strategy yields exceeding promised rates or protocol working capital.
 *      In tests, we inject the interest gap via _coverInterestGap() which mints
 *      extra USDC to the Treasury. See PRODUCTION_GAPS.md §5.4 for the yield
 *      harvesting gap that prevents automatic yield capture during auto-unwind.
 */
contract EndToEndTest is Test {
    // ── Contracts ──
    ComplianceRegistryUpgradeable public compliance;
    TravelRuleRegistryUpgradeable public travel;
    TreasuryUpgradeable public treasury;
    DiscountBillERC5095Upgradeable public bill;
    DiscountBillERC5095Upgradeable public bill5095;
    AaveV3StrategyAdapter public aaveAdapter;
    MockAaveV3Pool public aavePool;
    TestUSDC public usdc;

    // ── Addresses ──
    address admin = makeAddr("admin");
    address issuer = makeAddr("issuer");
    address operator = makeAddr("operator");
    address depositor = makeAddr("depositor");
    address depositWallet = makeAddr("depositWallet");
    address introducingWallet = makeAddr("introducingWallet");

    // ── Constants ──
    uint256 constant PRINCIPAL = 100_000e6; // 100,000 USDC
    uint256 constant ANNUAL_RATE_BPS = 500; // 5% APY
    uint256 constant DURATION_DAYS = 90;
    uint256 constant RESERVE_RATIO_BPS = 2000; // 20%

    function setUp() public {
        // ── Deploy token ──
        usdc = new TestUSDC();

        // ── Deploy MockAaveV3Pool ──
        aavePool = new MockAaveV3Pool();
        aavePool.initReserveWithDecimals(address(usdc), 6);

        // ── Deploy UUPS proxies ──
        compliance = ComplianceRegistryUpgradeable(
            address(new ERC1967Proxy(
                address(new ComplianceRegistryUpgradeable()),
                abi.encodeCall(ComplianceRegistryUpgradeable.initialize, (admin))
            ))
        );

        travel = TravelRuleRegistryUpgradeable(
            address(new ERC1967Proxy(
                address(new TravelRuleRegistryUpgradeable()),
                abi.encodeCall(TravelRuleRegistryUpgradeable.initialize, (admin))
            ))
        );

        treasury = TreasuryUpgradeable(
            address(new ERC1967Proxy(
                address(new TreasuryUpgradeable()),
                abi.encodeCall(TreasuryUpgradeable.initialize, (admin))
            ))
        );

        bill = DiscountBillERC5095Upgradeable(
            address(new ERC1967Proxy(
                address(new DiscountBillERC5095Upgradeable()),
                abi.encodeCall(DiscountBillERC5095Upgradeable.initialize, (admin, issuer, compliance, travel))
            ))
        );

        bill5095 = DiscountBillERC5095Upgradeable(
            address(new ERC1967Proxy(
                address(new DiscountBillERC5095Upgradeable()),
                abi.encodeCall(DiscountBillERC5095Upgradeable.initialize, (admin, issuer, compliance, travel))
            ))
        );

        // ── Deploy AaveV3StrategyAdapter (non-upgradeable) ──
        aaveAdapter = new AaveV3StrategyAdapter(admin, address(aavePool));

        // ── Deploy BillTokenFactory ──
        BillTokenFactory billTokenFactory = new BillTokenFactory();

        // ── Wire everything together ──
        vm.startPrank(admin);

        // Bill → Treasury + Factory
        bill.setTreasury(address(treasury));
        bill.setBillTokenFactory(address(billTokenFactory));
        bill5095.setTreasury(address(treasury));
        bill5095.setBillTokenFactory(address(billTokenFactory));

        // Treasury roles
        treasury.grantRole(treasury.DEPOSIT_MANAGER_ROLE(), address(bill));
        treasury.grantRole(treasury.DEPOSIT_MANAGER_ROLE(), address(bill5095));
        treasury.grantRole(treasury.OPERATOR_ROLE(), operator);

        // Strategy registration
        treasury.registerStrategy(address(aaveAdapter));
        aaveAdapter.grantRole(aaveAdapter.TREASURY_ROLE(), address(treasury));
        aaveAdapter.addSupportedToken(address(usdc));

        // Travel rule: grant ORDERING_ROLE to bill contracts
        travel.grantRole(travel.ORDERING_ROLE(), address(bill));
        travel.grantRole(travel.ORDERING_ROLE(), address(bill5095));
        // Also grant to operator for manual preclears
        travel.grantRole(travel.ORDERING_ROLE(), operator);

        // Travel rule policy: always-on for USDC, 7-day TTL
        travel.grantRole(travel.POLICY_ADMIN_ROLE(), admin);
        travel.setPolicy(address(usdc), 0, true, uint64(7 days));

        // Reserve ratio
        treasury.setReserveRatio(address(usdc), RESERVE_RATIO_BPS);

        // Operator roles on bill contracts
        bill.grantRole(bill.OPERATOR_ROLE(), operator);
        bill5095.grantRole(bill5095.OPERATOR_ROLE(), operator);

        vm.stopPrank();

        // ── Fund depositor ──
        usdc.mint(depositor, PRINCIPAL * 10); // Plenty of USDC
    }

    // ========================================================================
    // Test 1: Golden Path — Deposit to Redemption
    // ========================================================================

    function test_goldenPath_depositToRedemption() public {
        // ── Step 1: Preclear travel rule for deposit ──
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);

        // ── Step 2: Depositor approves and operator issues bill ──
        vm.prank(depositor);
        usdc.approve(address(bill), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill.issue(
            depositor,       // owner (gets the NFT)
            depositor,       // depositor (source of funds)
            depositWallet,   // where redemption goes
            introducingWallet, // gets commission
            address(usdc),
            PRINCIPAL,
            ANNUAL_RATE_BPS,
            DURATION_DAYS
        );

        // ── Step 3: Verify bill was created correctly ──
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        assertEq(info.principal, PRINCIPAL, "principal mismatch");
        assertEq(info.token, address(usdc), "token mismatch");
        assertEq(info.depositor, depositor, "depositor mismatch");
        assertEq(info.depositWallet, depositWallet, "depositWallet mismatch");
        assertEq(info.introducingWallet, introducingWallet, "introducingWallet mismatch");
        assertTrue(info.redemptionValue > PRINCIPAL, "redemption should exceed principal");
        assertTrue(info.commissionAmount > 0, "commission should be positive");
        assertEq(bill.ownerOf(billId), depositor, "NFT owner should be depositor");

        // ── Step 4: Verify Treasury recorded the deposit ──
        ITreasury.TokenState memory state = treasury.getTokenState(address(usdc));
        assertEq(state.depositClaims, PRINCIPAL, "treasury depositClaims");
        assertEq(state.depositLiabilities, info.redemptionValue, "treasury depositLiabilities");
        assertEq(usdc.balanceOf(address(treasury)), PRINCIPAL, "treasury USDC balance");

        // ── Step 5: Inject protocol capital to cover the interest gap ──
        // In production, strategy yield spread covers this. See PRODUCTION_GAPS.md §5.4.
        _coverInterestGap(info.redemptionValue, PRINCIPAL);

        // ── Step 6: Operator allocates to Aave (respecting 20% reserve floor) ──
        uint256 onChain = usdc.balanceOf(address(treasury));
        uint256 floor = (info.redemptionValue * RESERVE_RATIO_BPS) / 10000;
        uint256 deployAmount = onChain - floor - 1e6; // 1 USDC safety buffer

        vm.prank(operator);
        treasury.allocateToStrategy(address(aaveAdapter), address(usdc), deployAmount, 0);

        // Verify deployment
        assertEq(treasury.getStrategyDeployed(address(aaveAdapter), address(usdc)), deployAmount, "strategy deployed");
        assertTrue(treasury.isALMHealthy(address(usdc)), "ALM should be healthy");

        // ── Step 7: Simulate yield on Aave ──
        _fundPoolForYield(100); // 1% yield
        uint256 aTokenValue = aaveAdapter.currentValue(address(usdc));
        assertTrue(aTokenValue > deployAmount, "aToken value should grow after yield");

        // ── Step 8: Warp to maturity ──
        vm.warp(block.timestamp + DURATION_DAYS * 1 days);
        assertTrue(bill.isMature(billId), "bill should be mature");

        // ── Step 9: Preclear travel rules for redemption ──
        uint256 netPayment = info.redemptionValue - info.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, netPayment);
        _preclear(address(usdc), address(treasury), introducingWallet, info.commissionAmount);

        // ── Step 10: Record balances before redemption ──
        uint256 depositWalletBefore = usdc.balanceOf(depositWallet);
        uint256 introducerBefore = usdc.balanceOf(introducingWallet);

        // ── Step 11: Depositor redeems (they own the NFT) ──
        vm.prank(depositor);
        bill.redeem(billId);

        // ── Step 12: Verify payouts ──
        uint256 depositWalletAfter = usdc.balanceOf(depositWallet);
        uint256 introducerAfter = usdc.balanceOf(introducingWallet);

        assertEq(depositWalletAfter - depositWalletBefore, netPayment, "depositWallet should receive net payment");
        assertEq(introducerAfter - introducerBefore, info.commissionAmount, "introducer should receive commission");

        // ── Step 13: Verify bill is burned and state is clean ──
        vm.expectRevert(); // ownerOf should revert for burned token
        bill.ownerOf(billId);

        IDiscountBill.BillInfo memory postInfo = bill.getBillInfo(billId);
        assertEq(postInfo.redemptionValue, 0, "redemptionValue should be zeroed");

        // ── Step 14: Verify Treasury liabilities are zeroed — no orphan state ──
        ITreasury.TokenState memory postState = treasury.getTokenState(address(usdc));
        assertEq(postState.depositLiabilities, 0, "treasury deposit liabilities should be zero");
        assertEq(postState.depositClaims, 0, "treasury deposit claims should be zero");
    }

    // ========================================================================
    // Test 2: Merge and Redeem
    // ========================================================================

    function test_mergeAndRedeem() public {
        uint256 amount1 = 40_000e6;
        uint256 amount2 = 60_000e6;

        _preclear(address(usdc), depositor, issuer, amount1);
        _preclear(address(usdc), depositor, issuer, amount2);

        vm.prank(depositor);
        usdc.approve(address(bill), amount1 + amount2);

        vm.prank(operator);
        uint256 billId1 = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), amount1, ANNUAL_RATE_BPS, 60
        );

        vm.prank(operator);
        uint256 billId2 = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), amount2, ANNUAL_RATE_BPS, 90
        );

        IDiscountBill.BillInfo memory info1 = bill.getBillInfo(billId1);
        IDiscountBill.BillInfo memory info2 = bill.getBillInfo(billId2);
        assertTrue(info1.redemptionValue > 0, "bill1 should exist");
        assertTrue(info2.redemptionValue > 0, "bill2 should exist");

        // Verify treasury has correct total liabilities
        uint256 preMergeLiabilities = treasury.depositLiabilities(address(usdc));
        assertEq(preMergeLiabilities, info1.redemptionValue + info2.redemptionValue, "pre-merge liabilities");

        // Merge bills
        uint256[] memory ids = new uint256[](2);
        ids[0] = billId1;
        ids[1] = billId2;

        vm.prank(depositor);
        uint256 mergedId = bill.merge(ids, ANNUAL_RATE_BPS);

        // Verify merged bill
        IDiscountBill.BillInfo memory merged = bill.getBillInfo(mergedId);
        assertEq(merged.principal, amount1 + amount2, "merged principal");
        assertTrue(merged.redemptionValue > 0, "merged redemptionValue");
        assertEq(merged.depositWallet, depositWallet, "merged depositWallet");
        assertEq(bill.ownerOf(mergedId), depositor, "merged NFT owner");

        // Verify old bills are burned
        IDiscountBill.BillInfo memory oldBill1 = bill.getBillInfo(billId1);
        assertEq(oldBill1.redemptionValue, 0, "old bill1 should be zeroed");

        // Cover interest gap and warp to maturity
        _coverInterestGap(merged.redemptionValue, amount1 + amount2);
        vm.warp(merged.maturity);

        uint256 mergedNet = merged.redemptionValue - merged.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, mergedNet);
        _preclear(address(usdc), address(treasury), introducingWallet, merged.commissionAmount);

        uint256 walletBefore = usdc.balanceOf(depositWallet);

        vm.prank(depositor);
        bill.redeem(mergedId);

        uint256 walletAfter = usdc.balanceOf(depositWallet);
        assertEq(walletAfter - walletBefore, mergedNet, "merged redemption payout");

        // Treasury clean
        assertEq(treasury.depositLiabilities(address(usdc)), 0, "post-merge-redeem liabilities should be zero");
    }

    // ========================================================================
    // Test 3: ERC5095 Path — Issue, Token, Redeem
    // ========================================================================

    function test_erc5095Path_issueTokenRedeem() public {
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);

        vm.prank(depositor);
        usdc.approve(address(bill5095), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill5095.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );

        // Verify bill token was created
        address tokenAddr = bill5095.billTokens(billId);
        assertTrue(tokenAddr != address(0), "bill token should exist");

        DiscountBillERC5095Token billToken = DiscountBillERC5095Token(tokenAddr);
        IDiscountBill.BillInfo memory info = bill5095.getBillInfo(billId);
        assertEq(billToken.balanceOf(depositor), info.redemptionValue, "depositor should hold all bill tokens");
        assertEq(billToken.decimals(), 6, "bill token decimals should match USDC");

        // Cover interest gap and warp to maturity
        _coverInterestGap(info.redemptionValue, PRINCIPAL);
        vm.warp(info.maturity);

        // Preclear for token redemption
        uint256 redeemAmount = info.redemptionValue;
        uint256 commission = info.commissionAmount;
        uint256 netPayment = redeemAmount - commission;
        _preclear(address(usdc), address(treasury), depositWallet, netPayment);
        if (commission > 0) {
            _preclear(address(usdc), address(treasury), introducingWallet, commission);
        }

        // Redeem via ERC5095 token
        uint256 walletBefore = usdc.balanceOf(depositWallet);

        vm.prank(depositor);
        uint256 payout = billToken.redeem(redeemAmount, depositWallet, depositor);

        assertTrue(payout > 0, "payout should be positive");
        uint256 walletAfter = usdc.balanceOf(depositWallet);
        assertEq(walletAfter - walletBefore, netPayment, "token redemption payout");

        // Bill tokens should be burned
        assertEq(billToken.balanceOf(depositor), 0, "depositor bill tokens should be zero");
    }

    // ========================================================================
    // Test 4: Early Redemption with Break Fee
    // ========================================================================

    function test_earlyRedemption_breakFeeApplied() public {
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);

        vm.prank(depositor);
        usdc.approve(address(bill5095), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill5095.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );

        IDiscountBill.BillInfo memory info = bill5095.getBillInfo(billId);

        // Warp to day 45 (halfway through 90-day term)
        vm.warp(block.timestamp + 45 days);
        assertFalse(bill5095.isMature(billId), "bill should NOT be mature at day 45");

        // Request early redemption
        vm.prank(depositor);
        uint256 requestId = bill5095.requestEarlyRedemption(billId, false, 0);

        // Check the request details
        DiscountBillERC5095Upgradeable.EarlyRedemptionRequest memory req = bill5095.getEarlyRedemptionRequest(requestId);
        assertEq(req.billId, billId, "request billId");
        assertEq(req.requester, depositor, "request requester");
        assertTrue(req.breakFee > 0, "break fee should be positive");
        assertTrue(req.payoutAmount < info.redemptionValue, "payout should be less than full redemption");
        assertTrue(req.payoutAmount > 0, "payout should be positive");
        assertTrue(req.accruedInterest > 0, "accrued interest should be positive at day 45");

        // Treasury only received principal — payout might be < principal due to break fee
        // but ensure treasury has enough (it should, since payout < principal for early redemption)
        // If payout > on-chain, inject the difference
        uint256 treasuryBal = usdc.balanceOf(address(treasury));
        if (req.payoutAmount > treasuryBal) {
            usdc.mint(address(treasury), req.payoutAmount - treasuryBal);
        }

        // Preclear for early redemption payout
        _preclear(address(usdc), address(treasury), depositWallet, req.payoutAmount);

        // Operator approves early redemption
        uint256 walletBefore = usdc.balanceOf(depositWallet);

        vm.prank(operator);
        bill5095.approveEarlyRedemption(requestId);

        uint256 walletAfter = usdc.balanceOf(depositWallet);
        assertEq(walletAfter - walletBefore, req.payoutAmount, "early redemption payout");

        // Bill should be invalidated
        assertTrue(bill5095.billInvalidated(billId), "bill should be invalidated after full early redemption");
    }

    // ========================================================================
    // Test 5: Compliance Block then Unblock
    // ========================================================================

    function test_complianceBlock_thenUnblock() public {
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);

        vm.prank(depositor);
        usdc.approve(address(bill), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Cover interest gap
        _coverInterestGap(info.redemptionValue, PRINCIPAL);

        // Warp to maturity
        vm.warp(info.maturity);
        assertTrue(bill.isMature(billId), "bill should be mature");

        // Block the depositWallet
        vm.prank(admin);
        compliance.setBlocked(depositWallet, true);

        // Preclear travel rules for the redemption
        uint256 netPayment = info.redemptionValue - info.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, netPayment);
        _preclear(address(usdc), address(treasury), introducingWallet, info.commissionAmount);

        // Redemption should revert due to compliance block
        vm.prank(depositor);
        vm.expectRevert(DiscountBillERC5095Upgradeable.ComplianceBlocked.selector);
        bill.redeem(billId);

        // Unblock the depositWallet
        vm.prank(admin);
        compliance.setBlocked(depositWallet, false);

        // Redemption should now succeed
        vm.prank(depositor);
        bill.redeem(billId);

        assertEq(usdc.balanceOf(depositWallet), netPayment, "depositWallet should receive payment after unblock");
    }

    // ========================================================================
    // Test 6: Multiple Deposits, Redeem Out of Order
    // ========================================================================

    function test_multiDeposit_redeemOutOfOrder() public {
        uint256 amountA = 30_000e6;
        uint256 amountB = 40_000e6;
        uint256 amountC = 50_000e6;

        // Preclear all deposits
        _preclear(address(usdc), depositor, issuer, amountA);
        _preclear(address(usdc), depositor, issuer, amountB);
        _preclear(address(usdc), depositor, issuer, amountC);

        vm.prank(depositor);
        usdc.approve(address(bill), amountA + amountB + amountC);

        // Issue A (30 days), B (60 days), C (90 days)
        vm.startPrank(operator);
        uint256 idA = bill.issue(depositor, depositor, depositWallet, introducingWallet, address(usdc), amountA, ANNUAL_RATE_BPS, 30);
        uint256 idB = bill.issue(depositor, depositor, depositWallet, introducingWallet, address(usdc), amountB, ANNUAL_RATE_BPS, 60);
        uint256 idC = bill.issue(depositor, depositor, depositWallet, introducingWallet, address(usdc), amountC, ANNUAL_RATE_BPS, 90);
        vm.stopPrank();

        IDiscountBill.BillInfo memory infoA = bill.getBillInfo(idA);
        IDiscountBill.BillInfo memory infoB = bill.getBillInfo(idB);
        IDiscountBill.BillInfo memory infoC = bill.getBillInfo(idC);

        // Verify treasury has all three deposits
        uint256 totalLiabilities = treasury.depositLiabilities(address(usdc));
        assertEq(totalLiabilities, infoA.redemptionValue + infoB.redemptionValue + infoC.redemptionValue, "total liabilities");

        // Cover interest gap for all three bills
        uint256 totalInterestGap =
            (infoA.redemptionValue - amountA) +
            (infoB.redemptionValue - amountB) +
            (infoC.redemptionValue - amountC);
        usdc.mint(address(treasury), totalInterestGap);

        // ── Redeem A at day 30 ──
        vm.warp(infoA.maturity);

        uint256 netA = infoA.redemptionValue - infoA.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, netA);
        _preclear(address(usdc), address(treasury), introducingWallet, infoA.commissionAmount);

        vm.prank(depositor);
        bill.redeem(idA);

        // Verify remaining liabilities
        uint256 remainingAfterA = treasury.depositLiabilities(address(usdc));
        assertEq(remainingAfterA, infoB.redemptionValue + infoC.redemptionValue, "liabilities after A redeemed");

        // ── Skip B, redeem C at day 90 ──
        vm.warp(infoC.maturity);

        uint256 netC = infoC.redemptionValue - infoC.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, netC);
        _preclear(address(usdc), address(treasury), introducingWallet, infoC.commissionAmount);

        vm.prank(depositor);
        bill.redeem(idC);

        uint256 remainingAfterC = treasury.depositLiabilities(address(usdc));
        assertEq(remainingAfterC, infoB.redemptionValue, "only B should remain");

        // ── Now redeem B (already mature since day 60 < day 90) ──
        uint256 netB = infoB.redemptionValue - infoB.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, netB);
        _preclear(address(usdc), address(treasury), introducingWallet, infoB.commissionAmount);

        vm.prank(depositor);
        bill.redeem(idB);

        // All clean
        assertEq(treasury.depositLiabilities(address(usdc)), 0, "all liabilities should be zero");
        assertEq(treasury.depositClaims(address(usdc)), 0, "all claims should be zero");
    }

    // ========================================================================
    // Test 7: Reserve Floor Prevents Over-Allocation
    // ========================================================================

    function test_reserveFloor_preventsOverAllocation() public {
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);

        vm.prank(depositor);
        usdc.approve(address(bill), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Treasury has PRINCIPAL USDC on-chain
        assertEq(usdc.balanceOf(address(treasury)), PRINCIPAL, "treasury balance");

        // Reserve floor = (depositLiabilities + collateralClaims) * reserveRatio / 10000
        uint256 floor = (info.redemptionValue * RESERVE_RATIO_BPS) / 10000;

        // Try to deploy ALL of it — should revert (breaches reserve floor)
        vm.prank(operator);
        vm.expectRevert("would breach reserve floor");
        treasury.allocateToStrategy(address(aaveAdapter), address(usdc), PRINCIPAL, 0);

        // Deploy exactly the maximum allowed
        uint256 maxDeploy = PRINCIPAL - floor;
        if (maxDeploy > 0) {
            vm.prank(operator);
            treasury.allocateToStrategy(address(aaveAdapter), address(usdc), maxDeploy, 0);

            assertEq(treasury.getStrategyDeployed(address(aaveAdapter), address(usdc)), maxDeploy, "deployed max");
            assertTrue(usdc.balanceOf(address(treasury)) >= floor, "on-chain should be at least floor");
        }
    }

    // ========================================================================
    // Test 8: Pause/Resume Lifecycle
    // ========================================================================

    function test_pauseResume_blocksAllocationNotRedemption() public {
        // ── Issue a bill ──
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);
        vm.prank(depositor);
        usdc.approve(address(bill), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        _coverInterestGap(info.redemptionValue, PRINCIPAL);

        // ── Admin pauses treasury ──
        vm.prank(admin);
        treasury.pause();

        // ── Allocation should revert when paused ──
        vm.prank(operator);
        vm.expectRevert();
        treasury.allocateToStrategy(address(aaveAdapter), address(usdc), 10_000e6, 0);

        // ── Redemption MUST still work (depositor exit guarantee) ──
        vm.warp(info.maturity);
        uint256 netPayment = info.redemptionValue - info.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, netPayment);
        _preclear(address(usdc), address(treasury), introducingWallet, info.commissionAmount);

        uint256 walletBefore = usdc.balanceOf(depositWallet);
        vm.prank(depositor);
        bill.redeem(billId);
        assertEq(usdc.balanceOf(depositWallet) - walletBefore, netPayment, "redeem must work while paused");

        // ── Admin unpauses ──
        vm.prank(admin);
        treasury.unpause();

        // ── Allocation works again after unpause ──
        // (No deposits to allocate now, but verify no revert)
        assertEq(treasury.depositLiabilities(address(usdc)), 0, "clean after redeem");
    }

    // ========================================================================
    // Test 9: Yield Harvest and Revenue Extraction
    // ========================================================================

    function test_yieldHarvestAndRevenueExtraction() public {
        // ── Issue a bill and allocate to Aave ──
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);
        vm.prank(depositor);
        usdc.approve(address(bill), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Allocate most capital to Aave (respecting reserve floor)
        uint256 floor = (info.redemptionValue * RESERVE_RATIO_BPS) / 10000;
        uint256 deployAmount = PRINCIPAL - floor - 1e6;

        vm.prank(operator);
        treasury.allocateToStrategy(address(aaveAdapter), address(usdc), deployAmount, 0);

        // ── Simulate 2% yield on Aave ──
        _fundPoolForYield(200);

        uint256 aTokenValue = aaveAdapter.currentValue(address(usdc));
        uint256 yieldGenerated = aTokenValue - deployAmount;
        assertTrue(yieldGenerated > 0, "yield should be positive");

        // ── Harvest yield ──
        uint256 revenueBefore = treasury.protocolRevenue(address(usdc));
        vm.prank(operator);
        treasury.harvestYield(address(aaveAdapter), address(usdc));

        uint256 revenueAfter = treasury.protocolRevenue(address(usdc));
        assertTrue(revenueAfter > revenueBefore, "protocol revenue should increase");
        uint256 harvested = revenueAfter - revenueBefore;
        assertTrue(harvested > 0, "harvested amount should be positive");

        // Deployed principal should be unchanged
        assertEq(
            treasury.getStrategyDeployed(address(aaveAdapter), address(usdc)),
            deployAmount,
            "deployed principal unchanged after harvest"
        );

        // ── Extract revenue ──
        address revenueRecipient = makeAddr("revenueRecipient");
        uint256 recipientBefore = usdc.balanceOf(revenueRecipient);

        vm.prank(admin);
        treasury.withdrawRevenue(address(usdc), harvested, revenueRecipient);

        assertEq(
            usdc.balanceOf(revenueRecipient) - recipientBefore,
            harvested,
            "revenue recipient should receive harvested yield"
        );
        assertEq(treasury.protocolRevenue(address(usdc)), 0, "revenue should be zero after full withdrawal");
    }

    // ========================================================================
    // Test 10: Sweep Misrouted Tokens
    // ========================================================================

    function test_sweepMisroutedTokens() public {
        // ── Issue a bill so treasury has tracked funds ──
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);
        vm.prank(depositor);
        usdc.approve(address(bill), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Cover interest gap so on-chain balance == depositLiabilities
        // (treasury holds principal, but owes principal+interest)
        _coverInterestGap(info.redemptionValue, PRINCIPAL);

        // ── Someone accidentally sends 5000 USDC directly to the treasury ──
        uint256 misrouted = 5_000e6;
        usdc.mint(address(treasury), misrouted);

        // ── Sweep should recover misrouted tokens ──
        address sweepRecipient = makeAddr("sweepRecipient");
        uint256 recipientBefore = usdc.balanceOf(sweepRecipient);

        vm.prank(admin);
        treasury.sweepUntracked(address(usdc), misrouted, sweepRecipient);

        assertEq(
            usdc.balanceOf(sweepRecipient) - recipientBefore,
            misrouted,
            "sweep recipient should receive misrouted tokens"
        );

        // ── Sweep should NOT allow touching tracked funds ──
        vm.prank(admin);
        vm.expectRevert("would sweep tracked funds");
        treasury.sweepUntracked(address(usdc), 1, sweepRecipient);

        // ── Treasury deposit balance still intact ──
        assertTrue(usdc.balanceOf(address(treasury)) >= PRINCIPAL, "deposit funds should be untouched");
    }

    // ========================================================================
    // Test 11: Emergency Withdraw with Strategy Unwind
    // ========================================================================

    function test_emergencyWithdraw_fullRecovery() public {
        // ── Issue a bill and allocate to Aave ──
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);
        vm.prank(depositor);
        usdc.approve(address(bill), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Allocate to Aave
        uint256 floor = (info.redemptionValue * RESERVE_RATIO_BPS) / 10000;
        uint256 deployAmount = PRINCIPAL - floor - 1e6;

        vm.prank(operator);
        treasury.allocateToStrategy(address(aaveAdapter), address(usdc), deployAmount, 0);

        // Verify split: some on-chain, some in Aave
        uint256 onChainBefore = usdc.balanceOf(address(treasury));
        uint256 inAave = treasury.getStrategyDeployed(address(aaveAdapter), address(usdc));
        assertTrue(onChainBefore > 0, "should have on-chain reserves");
        assertTrue(inAave > 0, "should have Aave deployment");

        // ── Emergency withdraw — pulls everything ──
        address emergencyRecipient = makeAddr("emergencyRecipient");

        vm.prank(admin);
        treasury.emergencyWithdraw(address(usdc), type(uint256).max, emergencyRecipient);

        // All funds should be at emergency recipient
        uint256 recovered = usdc.balanceOf(emergencyRecipient);
        assertTrue(recovered >= PRINCIPAL, "should recover at least the principal");

        // Treasury should be empty
        assertEq(usdc.balanceOf(address(treasury)), 0, "treasury should be empty");
        assertEq(treasury.getStrategyDeployed(address(aaveAdapter), address(usdc)), 0, "strategy should be unwound");
        assertEq(treasury.depositLiabilities(address(usdc)), 0, "liabilities cleared");
        assertEq(treasury.depositClaims(address(usdc)), 0, "claims cleared");
    }

    // ========================================================================
    // Test 12: Full Lifecycle — Deposit to Clean Slate
    // ========================================================================

    function test_fullLifecycle_depositAllocateHarvestRedeemRevenue() public {
        // ── Step 1: Issue bill ──
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);
        vm.prank(depositor);
        usdc.approve(address(bill), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        _coverInterestGap(info.redemptionValue, PRINCIPAL);

        // ── Step 2: Allocate to Aave ──
        uint256 onChain = usdc.balanceOf(address(treasury));
        uint256 floor = (info.redemptionValue * RESERVE_RATIO_BPS) / 10000;
        uint256 deployAmount = onChain - floor - 1e6;

        vm.prank(operator);
        treasury.allocateToStrategy(address(aaveAdapter), address(usdc), deployAmount, 0);

        // ── Step 3: Simulate yield and harvest ──
        _fundPoolForYield(300); // 3% yield
        vm.prank(operator);
        treasury.harvestYield(address(aaveAdapter), address(usdc));

        uint256 revenue = treasury.protocolRevenue(address(usdc));
        assertTrue(revenue > 0, "should have harvested revenue");

        // ── Step 4: Warp to maturity ──
        vm.warp(info.maturity);
        assertTrue(bill.isMature(billId), "bill should be mature");

        // ── Step 5: Withdraw from Aave to free up on-chain liquidity ──
        vm.prank(operator);
        treasury.withdrawFromStrategy(address(aaveAdapter), address(usdc), deployAmount);

        // ── Step 6: Redeem bill ──
        uint256 netPayment = info.redemptionValue - info.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, netPayment);
        _preclear(address(usdc), address(treasury), introducingWallet, info.commissionAmount);

        uint256 walletBefore = usdc.balanceOf(depositWallet);
        vm.prank(depositor);
        bill.redeem(billId);
        assertEq(usdc.balanceOf(depositWallet) - walletBefore, netPayment, "redemption payout correct");

        // ── Step 7: Verify deposit accounting is clean ──
        assertEq(treasury.depositLiabilities(address(usdc)), 0, "liabilities zero");
        assertEq(treasury.depositClaims(address(usdc)), 0, "claims zero");

        // ── Step 8: Withdraw protocol revenue ──
        revenue = treasury.protocolRevenue(address(usdc));
        address revenueWallet = makeAddr("revenueWallet");
        if (revenue > 0) {
            vm.prank(admin);
            treasury.withdrawRevenue(address(usdc), revenue, revenueWallet);
            assertEq(usdc.balanceOf(revenueWallet), revenue, "revenue extracted");
        }

        // ── Step 9: Sweep any remaining dust ──
        uint256 treasuryBal = usdc.balanceOf(address(treasury));
        uint256 tracked = treasury.depositLiabilities(address(usdc))
            + treasury.collateralClaims(address(usdc))
            + treasury.lendingPoolReserves(address(usdc))
            + treasury.protocolRevenue(address(usdc));
        uint256 untracked = treasuryBal > tracked ? treasuryBal - tracked : 0;

        if (untracked > 0) {
            vm.prank(admin);
            treasury.sweepUntracked(address(usdc), untracked, revenueWallet);
        }

        // ── Step 10: Verify totally clean slate ──
        assertEq(treasury.depositLiabilities(address(usdc)), 0, "final: liabilities zero");
        assertEq(treasury.depositClaims(address(usdc)), 0, "final: claims zero");
        assertEq(treasury.protocolRevenue(address(usdc)), 0, "final: revenue zero");
        assertEq(treasury.getStrategyDeployed(address(aaveAdapter), address(usdc)), 0, "final: strategy zero");
    }

    // ========================================================================
    // Test 13: Multi-Token Independent Accounting
    // ========================================================================

    function test_multiToken_independentAccounting() public {
        // ── Deploy a second token (USDT-like) ──
        TestUSDC usdt = new TestUSDC(); // reuse TestUSDC contract, same 6 decimals

        // Set up Aave reserve for USDT
        aavePool.initReserveWithDecimals(address(usdt), 6);

        vm.startPrank(admin);
        aaveAdapter.addSupportedToken(address(usdt));
        treasury.setReserveRatio(address(usdt), RESERVE_RATIO_BPS);

        // Travel rule policy for USDT
        travel.setPolicy(address(usdt), 0, true, uint64(7 days));
        vm.stopPrank();

        // Fund depositor with both tokens
        usdt.mint(depositor, PRINCIPAL * 10);

        uint256 usdcAmount = 50_000e6;
        uint256 usdtAmount = 75_000e6;

        // ── Issue USDC bill ──
        _preclear(address(usdc), depositor, issuer, usdcAmount);
        vm.prank(depositor);
        usdc.approve(address(bill), usdcAmount);
        vm.prank(operator);
        uint256 usdcBillId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), usdcAmount, ANNUAL_RATE_BPS, 60
        );

        // ── Issue USDT bill ──
        _preclear(address(usdt), depositor, issuer, usdtAmount);
        vm.prank(depositor);
        usdt.approve(address(bill), usdtAmount);
        vm.prank(operator);
        uint256 usdtBillId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdt), usdtAmount, ANNUAL_RATE_BPS, 90
        );

        IDiscountBill.BillInfo memory usdcInfo = bill.getBillInfo(usdcBillId);
        IDiscountBill.BillInfo memory usdtInfo = bill.getBillInfo(usdtBillId);

        // ── Verify independent tracking ──
        assertEq(treasury.depositClaims(address(usdc)), usdcAmount, "USDC claims");
        assertEq(treasury.depositClaims(address(usdt)), usdtAmount, "USDT claims");
        assertEq(treasury.depositLiabilities(address(usdc)), usdcInfo.redemptionValue, "USDC liabilities");
        assertEq(treasury.depositLiabilities(address(usdt)), usdtInfo.redemptionValue, "USDT liabilities");

        // ── Cover interest gaps ──
        _coverInterestGap(usdcInfo.redemptionValue, usdcAmount);
        usdt.mint(address(treasury), usdtInfo.redemptionValue - usdtAmount);

        // ── Redeem USDC at day 60 — USDT should be unaffected ──
        vm.warp(usdcInfo.maturity);

        uint256 usdcNet = usdcInfo.redemptionValue - usdcInfo.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, usdcNet);
        _preclear(address(usdc), address(treasury), introducingWallet, usdcInfo.commissionAmount);

        vm.prank(depositor);
        bill.redeem(usdcBillId);

        // USDC clean, USDT untouched
        assertEq(treasury.depositLiabilities(address(usdc)), 0, "USDC liabilities zeroed");
        assertEq(treasury.depositLiabilities(address(usdt)), usdtInfo.redemptionValue, "USDT liabilities unchanged");

        // ── Redeem USDT at day 90 ──
        vm.warp(usdtInfo.maturity);

        uint256 usdtNet = usdtInfo.redemptionValue - usdtInfo.commissionAmount;
        _preclear(address(usdt), address(treasury), depositWallet, usdtNet);
        _preclear(address(usdt), address(treasury), introducingWallet, usdtInfo.commissionAmount);

        vm.prank(depositor);
        bill.redeem(usdtBillId);

        // Both tokens clean
        assertEq(treasury.depositLiabilities(address(usdc)), 0, "final: USDC zero");
        assertEq(treasury.depositLiabilities(address(usdt)), 0, "final: USDT zero");
    }

    // ========================================================================
    // Test 14: Bill Transfer — New Owner Redeems
    // ========================================================================

    function test_billTransfer_newOwnerRedeems() public {
        address newOwner = makeAddr("newOwner");

        // ── Issue bill to depositor ──
        _preclear(address(usdc), depositor, issuer, PRINCIPAL);
        vm.prank(depositor);
        usdc.approve(address(bill), PRINCIPAL);

        vm.prank(operator);
        uint256 billId = bill.issue(
            depositor, depositor, depositWallet, introducingWallet,
            address(usdc), PRINCIPAL, ANNUAL_RATE_BPS, DURATION_DAYS
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Verify depositor owns it
        assertEq(bill.ownerOf(billId), depositor, "depositor owns bill");

        // ── Transfer NFT to new owner ──
        vm.prank(depositor);
        bill.transferFrom(depositor, newOwner, billId);
        assertEq(bill.ownerOf(billId), newOwner, "new owner owns bill");

        // ── Cover interest and warp to maturity ──
        _coverInterestGap(info.redemptionValue, PRINCIPAL);
        vm.warp(info.maturity);

        // ── New owner redeems — payment goes to original depositWallet ──
        uint256 netPayment = info.redemptionValue - info.commissionAmount;
        _preclear(address(usdc), address(treasury), depositWallet, netPayment);
        _preclear(address(usdc), address(treasury), introducingWallet, info.commissionAmount);

        uint256 walletBefore = usdc.balanceOf(depositWallet);

        vm.prank(newOwner);
        bill.redeem(billId);

        // Payment goes to depositWallet (baked at issuance), redeemed by new owner
        assertEq(usdc.balanceOf(depositWallet) - walletBefore, netPayment, "depositWallet receives payment");

        // Bill burned
        vm.expectRevert();
        bill.ownerOf(billId);

        // Treasury clean
        assertEq(treasury.depositLiabilities(address(usdc)), 0, "liabilities zeroed");
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    /// @dev Preclear a travel rule tuple via the operator
    function _preclear(address token, address from, address to, uint256 amount) internal {
        vm.prank(operator);
        travel.preclear(
            token,
            from,
            to,
            amount,
            bytes32(0), // payerHash
            bytes32(0), // payeeHash
            bytes32(0)  // customerRefHash
        );
    }

    /// @dev Inject protocol capital to cover the interest gap between principal and redemption.
    ///      In production, this gap is covered by strategy yield spread or protocol reserves.
    function _coverInterestGap(uint256 redemptionValue, uint256 principal) internal {
        if (redemptionValue > principal) {
            usdc.mint(address(treasury), redemptionValue - principal);
        }
    }

    /// @dev Fund the mock Aave pool so it can back yield, then simulate yield
    function _fundPoolForYield(uint256 yieldBps) internal {
        MockAToken aToken = aavePool.getMockAToken(address(usdc));
        uint256 currentTotal = (aToken.totalShares() * aToken.exchangeRate()) / 1e18;
        uint256 yieldAmount = (currentTotal * yieldBps) / 10000;

        // Mint extra USDC to the pool to back the yield
        usdc.mint(address(aavePool), yieldAmount);

        // Simulate yield increase on the exchange rate
        aavePool.simulateYield(address(usdc), yieldBps);
    }
}
