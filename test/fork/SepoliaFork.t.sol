// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DiscountBillERC5095Upgradeable} from "../../src/DiscountBillERC5095Upgradeable.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {ITravelRuleRegistry} from "../../src/interfaces/ITravelRuleRegistry.sol";
import {IDiscountBill} from "../../src/interfaces/IDiscountBill.sol";

/**
 * @title SepoliaForkTest
 * @notice Integration tests against real deployed contracts on Sepolia testnet
 * @dev Run with: forge test --match-contract SepoliaForkTest --fork-url $SEPOLIA_RPC_URL -vvv
 *
 * These tests verify the deployed contract state and simulate the full deposit lifecycle
 * using real USDC on a Sepolia fork. They complement the unit tests in DiscountBillERC5095Upgradeable.t.sol.
 */
contract SepoliaForkTest is Test {
    // ═══════════════════════════════════════════════════════════════════
    // Deployed contract addresses (from deployments/sepolia.json)
    // ═══════════════════════════════════════════════════════════════════
    address constant DISCOUNT_BILL = 0x7396d169DE124C5827A22f3750cfE39855Efd708;
    address constant COMPLIANCE    = 0x1B4C23Ba79A435242cD10756D90676389CE564f7;
    address constant TRAVEL_RULE   = 0x2446Cb30B8bd698A25B8664ebF49D4c359222893;
    address constant USDC          = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant ADMIN         = 0x940b12C8eEdC33dD8f28102f12067160717D1acc;

    DiscountBillERC5095Upgradeable bill;
    IERC20 usdc;

    // Test actors
    address depositor;
    address recipient;

    function setUp() public {
        // Fork Sepolia — reads SEPOLIA_RPC_URL from environment
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl);

        bill = DiscountBillERC5095Upgradeable(DISCOUNT_BILL);
        usdc = IERC20(USDC);

        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Deployment Verification
    // ═══════════════════════════════════════════════════════════════════

    function test_contractsDeployed() public view {
        // Verify contracts have code (are deployed)
        assertTrue(address(bill).code.length > 0, "DiscountBill not deployed");
        assertTrue(COMPLIANCE.code.length > 0, "ComplianceRegistry not deployed");
        assertTrue(TRAVEL_RULE.code.length > 0, "TravelRuleRegistry not deployed");
        assertTrue(USDC.code.length > 0, "USDC not deployed");
    }

    function test_billInitializedCorrectly() public view {
        // Verify name and symbol (set during deployment)
        assertEq(bill.name(), "DiscountBill");
        assertEq(bill.symbol(), "DBILL");

        // Verify compliance and travel rule registries are set
        assertEq(address(bill.compliance()), COMPLIANCE);
        assertEq(address(bill.travel()), TRAVEL_RULE);

        // Verify issuer is the admin/deployer
        assertEq(bill.issuer(), ADMIN);
    }

    function test_adminHasAllRoles() public view {
        bytes32 DEFAULT_ADMIN = 0x00;
        bytes32 ISSUER_ROLE = keccak256("ISSUER_ROLE");
        bytes32 OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
        bytes32 UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

        assertTrue(bill.hasRole(DEFAULT_ADMIN, ADMIN), "Missing DEFAULT_ADMIN_ROLE");
        assertTrue(bill.hasRole(ISSUER_ROLE, ADMIN), "Missing ISSUER_ROLE");
        assertTrue(bill.hasRole(OPERATOR_ROLE, ADMIN), "Missing OPERATOR_ROLE");
        assertTrue(bill.hasRole(UPGRADER_ROLE, ADMIN), "Missing UPGRADER_ROLE");
    }

    function test_usdcIsStandard() public view {
        // Verify USDC has expected properties
        assertEq(IERC20Metadata(USDC).decimals(), 6);
        assertEq(IERC20Metadata(USDC).symbol(), "USDC");
    }

    function test_contractNotPaused() public view {
        assertFalse(bill.paused(), "Contract should not be paused");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Compliance Registry Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_complianceAllowsNewAddress() public view {
        // Fresh addresses should be allowed (not blocked)
        assertTrue(IComplianceRegistry(COMPLIANCE).isAllowed(depositor));
        assertTrue(IComplianceRegistry(COMPLIANCE).isAllowed(recipient));
    }

    function test_complianceBlockAndUnblock() public {
        // Admin blocks an address
        vm.prank(ADMIN);
        IComplianceRegistryAdmin(COMPLIANCE).setBlocked(depositor, true);
        assertFalse(IComplianceRegistry(COMPLIANCE).isAllowed(depositor));

        // Admin unblocks
        vm.prank(ADMIN);
        IComplianceRegistryAdmin(COMPLIANCE).setBlocked(depositor, false);
        assertTrue(IComplianceRegistry(COMPLIANCE).isAllowed(depositor));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Full Deposit Lifecycle (Issue → Hold → Redeem)
    // ═══════════════════════════════════════════════════════════════════

    function test_issueDepositWithRealUSDC() public {
        uint256 principal = 1000e6; // 1000 USDC
        uint256 rateBps = 500;      // 5% APR
        uint256 termDays = 90;

        // Deal USDC to depositor (simulates real funding)
        deal(USDC, depositor, principal);
        assertEq(usdc.balanceOf(depositor), principal);

        // Depositor approves DiscountBill to spend USDC
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        // Track bill counter before
        uint256 nextBillBefore = bill.nextBillId();

        // Issue bill as operator (admin has OPERATOR_ROLE)
        vm.prank(ADMIN);
        uint256 billId = bill.issue(
            depositor,  // owner (receives NFT)
            depositor,  // depositor
            depositor,  // depositWallet
            address(0), // no introducing wallet
            USDC,
            principal,
            rateBps,
            termDays
        );

        // Verify bill created
        assertEq(billId, nextBillBefore);
        assertEq(bill.nextBillId(), nextBillBefore + 1);

        // Verify NFT ownership
        assertEq(bill.ownerOf(billId), depositor);

        // Verify bill info
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        assertEq(info.token, USDC);
        assertEq(info.principal, principal);
        assertEq(info.depositor, depositor);
        assertEq(info.depositWallet, depositor);
        assertTrue(info.redemptionValue > principal, "Redemption should exceed principal");
        assertTrue(info.maturity > block.timestamp, "Maturity should be in the future");

        // Verify USDC transferred from depositor (to issuer since no treasury)
        assertEq(usdc.balanceOf(depositor), 0);

        // Verify bill is not yet mature
        assertFalse(bill.isMature(billId));
    }

    function test_fullLifecycle_issueAndRedeem() public {
        uint256 principal = 500e6; // 500 USDC
        uint256 rateBps = 300;     // 3% APR
        uint256 termDays = 30;

        // Fund and approve
        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        // Issue
        vm.prank(ADMIN);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, rateBps, termDays
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        uint256 redemptionValue = info.redemptionValue;

        // Fund the issuer/treasury with enough to pay redemption
        // (since no treasury contract, issuer pays out)
        deal(USDC, ADMIN, redemptionValue);
        vm.prank(ADMIN);
        usdc.approve(DISCOUNT_BILL, redemptionValue);

        // Warp to maturity
        vm.warp(info.maturity + 1);
        assertTrue(bill.isMature(billId));

        // Redeem
        uint256 balanceBefore = usdc.balanceOf(depositor);
        vm.prank(depositor);
        bill.redeem(billId);

        // Verify payout (redemption minus commission)
        uint256 balanceAfter = usdc.balanceOf(depositor);
        assertTrue(balanceAfter > balanceBefore, "Depositor should receive payout");

        // Bill should be burned
        vm.expectRevert();
        bill.ownerOf(billId);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Access Control Tests (against real deployment)
    // ═══════════════════════════════════════════════════════════════════

    function test_nonOperatorCannotIssue() public {
        uint256 principal = 100e6;
        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        // Random address tries to issue — should revert
        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        vm.expectRevert();
        bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, 500, 90
        );
    }

    function test_blockedRecipientCannotReceiveDeposit() public {
        // issue() calls _enforceComplianceAndTravel(token, depositor, issuer, principal)
        // compliance checks isAllowed(to) where to=issuer — so blocking the issuer blocks issue
        // Instead, test the redeem path: block the depositWallet (recipient of redemption payout)

        uint256 principal = 100e6;
        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        // Issue normally
        vm.prank(ADMIN);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, 500, 90
        );

        // Fund issuer for redemption payout
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        deal(USDC, ADMIN, info.redemptionValue);
        vm.prank(ADMIN);
        usdc.approve(DISCOUNT_BILL, info.redemptionValue);

        // Warp to maturity
        vm.warp(info.maturity + 1);

        // Block the depositor/depositWallet (recipient of redeem payout)
        vm.prank(ADMIN);
        IComplianceRegistryAdmin(COMPLIANCE).setBlocked(depositor, true);

        // Redeem should fail — compliance blocks the recipient
        vm.prank(depositor);
        vm.expectRevert("Compliance: recipient blocked");
        bill.redeem(billId);

        // Unblock and verify redeem works
        vm.prank(ADMIN);
        IComplianceRegistryAdmin(COMPLIANCE).setBlocked(depositor, false);

        vm.prank(depositor);
        bill.redeem(billId);
    }

    function test_cannotRedeemBeforeMaturity() public {
        uint256 principal = 100e6;
        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        vm.prank(ADMIN);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, 500, 90
        );

        // Try to redeem immediately
        vm.prank(depositor);
        vm.expectRevert("Not mature");
        bill.redeem(billId);
    }

    function test_nonOwnerCannotRedeem() public {
        uint256 principal = 100e6;
        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        vm.prank(ADMIN);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, 500, 90
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        vm.warp(info.maturity + 1);

        // Random user tries to redeem
        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert("Not owner");
        bill.redeem(billId);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Pause Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_pauseBlocksIssue() public {
        uint256 principal = 100e6;
        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        // Pause
        vm.prank(ADMIN);
        bill.pause();
        assertTrue(bill.paused());

        // Issue should revert while paused
        vm.prank(ADMIN);
        vm.expectRevert();
        bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, 500, 90
        );

        // Unpause
        vm.prank(ADMIN);
        bill.unpause();
        assertFalse(bill.paused());
    }

    // ═══════════════════════════════════════════════════════════════════
    // Edge Cases / Validation
    // ═══════════════════════════════════════════════════════════════════

    function test_zeroPrincipalReverts() public {
        vm.prank(ADMIN);
        vm.expectRevert("Zero principal");
        bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, 0, 500, 90
        );
    }

    function test_invalidTermReverts() public {
        uint256 principal = 100e6;
        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        vm.prank(ADMIN);
        vm.expectRevert("Invalid duration");
        bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, 500, 0  // zero days
        );

        vm.prank(ADMIN);
        vm.expectRevert("Invalid duration");
        bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, 500, 365 * 5 + 1  // exceeds 5 years
        );
    }

    function test_rateValidation() public {
        uint256 principal = 100e6;
        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        vm.prank(ADMIN);
        vm.expectRevert("Rate too low");
        bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, 0, 90  // 0 bps
        );

        vm.prank(ADMIN);
        vm.expectRevert("Rate > 100%");
        bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, 100001, 90  // > 100%
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Multiple Bills & Merge
    // ═══════════════════════════════════════════════════════════════════

    function test_issueTwoAndMerge() public {
        uint256 principal1 = 1000e6;
        uint256 principal2 = 2000e6;
        uint256 totalPrincipal = principal1 + principal2;

        deal(USDC, depositor, totalPrincipal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, totalPrincipal);

        // Issue two bills with same token and wallet
        vm.prank(ADMIN);
        uint256 bill1 = bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal1, 500, 90
        );

        vm.prank(ADMIN);
        uint256 bill2 = bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal2, 500, 90
        );

        // Both should exist
        assertEq(bill.ownerOf(bill1), depositor);
        assertEq(bill.ownerOf(bill2), depositor);

        // Merge them
        uint256[] memory ids = new uint256[](2);
        ids[0] = bill1;
        ids[1] = bill2;

        vm.prank(depositor);
        uint256 mergedId = bill.merge(ids, 500);

        // Merged bill should exist with combined value
        IDiscountBill.BillInfo memory mergedInfo = bill.getBillInfo(mergedId);
        assertEq(mergedInfo.depositor, depositor);
        assertTrue(mergedInfo.principal >= totalPrincipal, "Merged principal should be at least sum");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Interest Calculation Verification
    // ═══════════════════════════════════════════════════════════════════

    function test_interestCalculation_90day() public {
        uint256 principal = 10_000e6; // 10,000 USDC
        uint256 rateBps = 500;        // 5% APR
        uint256 termDays = 90;

        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        vm.prank(ADMIN);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, rateBps, termDays
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Contract uses daily compound interest: principal * (1 + rate/365)^days
        // 10000 * (1 + 0.05/365)^90 ≈ 10,124.04 USDC
        // Allow 0.1% tolerance for compound vs simple interest rounding
        uint256 simpleExpected = principal + (principal * rateBps * termDays) / (10000 * 365);
        assertTrue(info.redemptionValue >= simpleExpected, "Compound should exceed simple interest");
        // Compound interest should be within 1% of simple for short terms
        assertApproxEqRel(info.redemptionValue, simpleExpected, 0.01e18, "Interest exceeds 1% tolerance");
    }

    function test_interestCalculation_365day() public {
        uint256 principal = 10_000e6;
        uint256 rateBps = 1000; // 10% APR

        deal(USDC, depositor, principal);
        vm.prank(depositor);
        usdc.approve(DISCOUNT_BILL, principal);

        vm.prank(ADMIN);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            USDC, principal, rateBps, 365
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Compound: 10000 * (1 + 0.10/365)^365 ≈ 11,051.56 USDC
        // Simple:   10000 * (1 + 0.10) = 11,000 USDC
        uint256 simpleExpected = principal + (principal * rateBps * 365) / (10000 * 365);
        assertTrue(info.redemptionValue >= simpleExpected, "Compound should exceed simple interest");
        // For 10% APR, compound exceeds simple by ~0.5%
        assertApproxEqRel(info.redemptionValue, simpleExpected, 0.01e18, "Interest exceeds 1% tolerance");
    }
}

// ═══════════════════════════════════════════════════════════════════
// Helper interfaces for admin functions not in IComplianceRegistry
// ═══════════════════════════════════════════════════════════════════
interface IComplianceRegistryAdmin {
    function setBlocked(address account, bool blocked) external;
    function setBlockedBatch(address[] calldata accounts, bool blocked) external;
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
}
