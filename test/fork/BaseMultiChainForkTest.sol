// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DiscountBillERC5095Upgradeable} from "../../src/DiscountBillERC5095Upgradeable.sol";
import {DiscountBillERC5095Token, BillTokenFactory} from "../../src/BillTokenFactory.sol";
import {ComplianceRegistryUpgradeable} from "../../src/ComplianceRegistryUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../../src/TravelRuleUpgradeable.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {ITravelRuleRegistry} from "../../src/interfaces/ITravelRuleRegistry.sol";
import {IDiscountBill} from "../../src/interfaces/IDiscountBill.sol";
import {ChainRegistry} from "./ChainRegistry.sol";

/**
 * @title BaseMultiChainForkTest
 * @notice Abstract base for multi-chain fork testing via Tenderly
 * @dev Deploys fresh contracts on each fork, then runs the full deposit lifecycle.
 *      Subclasses only need to override _getChainConfig().
 *
 * Run: FORK_RPC_URL=<tenderly_rpc> forge test --match-contract <ChainName>ForkTest -vvv
 */
abstract contract BaseMultiChainForkTest is Test {

    // ═══ Override in subclass ═══
    function _getChainConfig() internal pure virtual returns (ChainRegistry.ChainConfig memory);

    // ═══ State ═══
    DiscountBillERC5095Upgradeable bill;
    ComplianceRegistryUpgradeable complianceRegistry;
    TravelRuleRegistryUpgradeable travelRegistry;
    IERC20 usdc;

    address admin;
    address depositor;
    address recipient;

    ChainRegistry.ChainConfig chainConfig;

    uint256 constant TRAVEL_RULE_THRESHOLD = 1_000_000 * 1e6;
    uint64 constant TRAVEL_RULE_TTL = 24 hours;

    // ═══ Helpers ═══

    /// @dev Scales USD amount by chain's stablecoin decimals (handles BSC 18-decimal USDC)
    function _amount(uint256 usdWhole) internal view returns (uint256) {
        return usdWhole * (10 ** chainConfig.stablecoinDecimals);
    }

    // ═══ Setup ═══

    function setUp() public virtual {
        chainConfig = _getChainConfig();

        // Fork from environment variable
        string memory forkUrl = vm.envString("FORK_RPC_URL");
        vm.createSelectFork(forkUrl);

        // Verify we're on the expected chain
        assertEq(block.chainid, chainConfig.chainId, "Wrong chain ID for fork");

        admin = makeAddr("admin");
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        usdc = IERC20(chainConfig.usdc);

        // Deploy fresh contracts (replicates DeployProduction.s.sol)
        vm.startPrank(admin);

        // 1. ComplianceRegistry
        address compImpl = address(new ComplianceRegistryUpgradeable());
        complianceRegistry = ComplianceRegistryUpgradeable(
            address(new ERC1967Proxy(compImpl, abi.encodeCall(ComplianceRegistryUpgradeable.initialize, (admin))))
        );

        // 2. TravelRuleRegistry
        address travelImpl = address(new TravelRuleRegistryUpgradeable());
        travelRegistry = TravelRuleRegistryUpgradeable(
            address(new ERC1967Proxy(travelImpl, abi.encodeCall(TravelRuleRegistryUpgradeable.initialize, (admin))))
        );

        // 3. DiscountBill (ERC5095)
        address billImpl = address(new DiscountBillERC5095Upgradeable());
        bill = DiscountBillERC5095Upgradeable(
            address(new ERC1967Proxy(billImpl,
                abi.encodeCall(DiscountBillERC5095Upgradeable.initialize,
                    (admin, admin, IComplianceRegistry(address(complianceRegistry)),
                     ITravelRuleRegistry(address(travelRegistry))))))
        );

        // 3b. Deploy BillTokenFactory and wire to bill
        BillTokenFactory billTokenFactory = new BillTokenFactory();
        bill.setBillTokenFactory(address(billTokenFactory));

        // 4. Configure TravelRule policy for chain's stablecoin
        travelRegistry.setPolicy(chainConfig.usdc, TRAVEL_RULE_THRESHOLD, false, TRAVEL_RULE_TTL);

        // 5. Grant ORDERING_ROLE to DiscountBill on TravelRule
        travelRegistry.grantRole(travelRegistry.ORDERING_ROLE(), address(bill));

        // 6. Grant OPERATOR_ROLE to admin on DiscountBill
        bill.grantRole(bill.OPERATOR_ROLE(), admin);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Deployment Verification
    // ═══════════════════════════════════════════════════════════════════

    function test_stablecoinExists() public view {
        assertTrue(chainConfig.usdc.code.length > 0, "Stablecoin not deployed on this chain");
    }

    function test_contractsDeployed() public view {
        assertTrue(address(bill).code.length > 0, "DiscountBill not deployed");
        assertTrue(address(complianceRegistry).code.length > 0, "ComplianceRegistry not deployed");
        assertTrue(address(travelRegistry).code.length > 0, "TravelRuleRegistry not deployed");
    }

    function test_billInitializedCorrectly() public view {
        assertEq(bill.name(), "DiscountBill");
        assertEq(bill.symbol(), "DBILL");
        assertEq(address(bill.compliance()), address(complianceRegistry));
        assertEq(address(bill.travel()), address(travelRegistry));
        assertEq(bill.issuer(), admin);
    }

    function test_adminHasAllRoles() public view {
        bytes32 DEFAULT_ADMIN = 0x00;
        assertTrue(bill.hasRole(DEFAULT_ADMIN, admin), "Missing DEFAULT_ADMIN_ROLE");
        assertTrue(bill.hasRole(bill.ISSUER_ROLE(), admin), "Missing ISSUER_ROLE");
        assertTrue(bill.hasRole(bill.OPERATOR_ROLE(), admin), "Missing OPERATOR_ROLE");
        assertTrue(bill.hasRole(bill.UPGRADER_ROLE(), admin), "Missing UPGRADER_ROLE");
    }

    function test_contractNotPaused() public view {
        assertFalse(bill.paused(), "Contract should not be paused");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Compliance Registry Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_complianceAllowsNewAddress() public view {
        assertTrue(IComplianceRegistry(address(complianceRegistry)).isAllowed(depositor));
        assertTrue(IComplianceRegistry(address(complianceRegistry)).isAllowed(recipient));
    }

    function test_complianceBlockAndUnblock() public {
        vm.prank(admin);
        complianceRegistry.setBlocked(depositor, true);
        assertFalse(IComplianceRegistry(address(complianceRegistry)).isAllowed(depositor));

        vm.prank(admin);
        complianceRegistry.setBlocked(depositor, false);
        assertTrue(IComplianceRegistry(address(complianceRegistry)).isAllowed(depositor));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Full Deposit Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    function test_issueDepositWithRealStablecoin() public {
        uint256 principal = _amount(1000); // 1000 USDC
        uint256 rateBps = 500;
        uint256 termDays = 90;

        deal(chainConfig.usdc, depositor, principal);
        assertEq(usdc.balanceOf(depositor), principal);

        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        uint256 nextBillBefore = bill.nextBillId();

        vm.prank(admin);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            chainConfig.usdc, principal, rateBps, termDays
        );

        assertEq(billId, nextBillBefore);
        assertEq(bill.ownerOf(billId), depositor);

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        assertEq(info.token, chainConfig.usdc);
        assertEq(info.principal, principal);
        assertTrue(info.redemptionValue > principal, "Redemption should exceed principal");
        assertTrue(info.maturity > block.timestamp, "Maturity should be in the future");
        assertEq(usdc.balanceOf(depositor), 0);
        assertFalse(bill.isMature(billId));
    }

    function test_fullLifecycle_issueAndRedeem() public {
        uint256 principal = _amount(500);
        uint256 rateBps = 300;
        uint256 termDays = 30;

        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        vm.prank(admin);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            chainConfig.usdc, principal, rateBps, termDays
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        uint256 redemptionValue = info.redemptionValue;

        // Fund issuer for redemption payout (legacy path, no treasury)
        deal(chainConfig.usdc, admin, redemptionValue);
        vm.prank(admin);
        usdc.approve(address(bill), redemptionValue);

        // Warp to maturity
        vm.warp(info.maturity + 1);
        assertTrue(bill.isMature(billId));

        // Redeem
        uint256 balanceBefore = usdc.balanceOf(depositor);
        vm.prank(depositor);
        bill.redeem(billId);

        assertTrue(usdc.balanceOf(depositor) > balanceBefore, "Depositor should receive payout");

        // Bill should be burned
        vm.expectRevert();
        bill.ownerOf(billId);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Access Control
    // ═══════════════════════════════════════════════════════════════════

    function test_nonOperatorCannotIssue() public {
        uint256 principal = _amount(100);
        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        vm.expectRevert();
        bill.issue(depositor, depositor, depositor, address(0), chainConfig.usdc, principal, 500, 90);
    }

    function test_blockedRecipientCannotReceiveRedemption() public {
        uint256 principal = _amount(100);
        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        vm.prank(admin);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            chainConfig.usdc, principal, 500, 90
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        deal(chainConfig.usdc, admin, info.redemptionValue);
        vm.prank(admin);
        usdc.approve(address(bill), info.redemptionValue);

        vm.warp(info.maturity + 1);

        // Block depositor (recipient of redeem payout)
        vm.prank(admin);
        complianceRegistry.setBlocked(depositor, true);

        vm.prank(depositor);
        vm.expectRevert("Compliance: recipient blocked");
        bill.redeem(billId);

        // Unblock and verify redeem works
        vm.prank(admin);
        complianceRegistry.setBlocked(depositor, false);

        vm.prank(depositor);
        bill.redeem(billId);
    }

    function test_cannotRedeemBeforeMaturity() public {
        uint256 principal = _amount(100);
        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        vm.prank(admin);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            chainConfig.usdc, principal, 500, 90
        );

        vm.prank(depositor);
        vm.expectRevert("Not mature");
        bill.redeem(billId);
    }

    function test_nonOwnerCannotRedeem() public {
        uint256 principal = _amount(100);
        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        vm.prank(admin);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            chainConfig.usdc, principal, 500, 90
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        vm.warp(info.maturity + 1);

        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert("Not owner");
        bill.redeem(billId);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Pause
    // ═══════════════════════════════════════════════════════════════════

    function test_pauseBlocksIssue() public {
        uint256 principal = _amount(100);
        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        vm.prank(admin);
        bill.pause();
        assertTrue(bill.paused());

        vm.prank(admin);
        vm.expectRevert();
        bill.issue(depositor, depositor, depositor, address(0), chainConfig.usdc, principal, 500, 90);

        vm.prank(admin);
        bill.unpause();
        assertFalse(bill.paused());
    }

    // ═══════════════════════════════════════════════════════════════════
    // Validation
    // ═══════════════════════════════════════════════════════════════════

    function test_zeroPrincipalReverts() public {
        vm.prank(admin);
        vm.expectRevert("Zero principal");
        bill.issue(depositor, depositor, depositor, address(0), chainConfig.usdc, 0, 500, 90);
    }

    function test_invalidTermReverts() public {
        uint256 principal = _amount(100);
        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        vm.prank(admin);
        vm.expectRevert("Invalid duration");
        bill.issue(depositor, depositor, depositor, address(0), chainConfig.usdc, principal, 500, 0);

        vm.prank(admin);
        vm.expectRevert("Invalid duration");
        bill.issue(depositor, depositor, depositor, address(0), chainConfig.usdc, principal, 500, 365 * 5 + 1);
    }

    function test_rateValidation() public {
        uint256 principal = _amount(100);
        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        vm.prank(admin);
        vm.expectRevert("Rate too low");
        bill.issue(depositor, depositor, depositor, address(0), chainConfig.usdc, principal, 0, 90);

        vm.prank(admin);
        vm.expectRevert("Rate > 100%");
        bill.issue(depositor, depositor, depositor, address(0), chainConfig.usdc, principal, 100001, 90);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Merge
    // ═══════════════════════════════════════════════════════════════════

    function test_issueTwoAndMerge() public {
        uint256 principal1 = _amount(1000);
        uint256 principal2 = _amount(2000);
        uint256 totalPrincipal = principal1 + principal2;

        deal(chainConfig.usdc, depositor, totalPrincipal);
        vm.prank(depositor);
        usdc.approve(address(bill), totalPrincipal);

        vm.prank(admin);
        uint256 bill1 = bill.issue(
            depositor, depositor, depositor, address(0),
            chainConfig.usdc, principal1, 500, 90
        );

        vm.prank(admin);
        uint256 bill2 = bill.issue(
            depositor, depositor, depositor, address(0),
            chainConfig.usdc, principal2, 500, 90
        );

        assertEq(bill.ownerOf(bill1), depositor);
        assertEq(bill.ownerOf(bill2), depositor);

        uint256[] memory ids = new uint256[](2);
        ids[0] = bill1;
        ids[1] = bill2;

        vm.prank(depositor);
        uint256 mergedId = bill.merge(ids, 500);

        IDiscountBill.BillInfo memory mergedInfo = bill.getBillInfo(mergedId);
        assertEq(mergedInfo.depositor, depositor);
        assertTrue(mergedInfo.principal >= totalPrincipal, "Merged principal should be at least sum");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Interest Calculation
    // ═══════════════════════════════════════════════════════════════════

    function test_interestCalculation_90day() public {
        uint256 principal = _amount(10_000);
        uint256 rateBps = 500;
        uint256 termDays = 90;

        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        vm.prank(admin);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            chainConfig.usdc, principal, rateBps, termDays
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Contract uses daily compound interest
        uint256 simpleExpected = principal + (principal * rateBps * termDays) / (10000 * 365);
        assertTrue(info.redemptionValue >= simpleExpected, "Compound should exceed simple interest");
        assertApproxEqRel(info.redemptionValue, simpleExpected, 0.01e18, "Interest exceeds 1% tolerance");
    }

    function test_interestCalculation_365day() public {
        uint256 principal = _amount(10_000);
        uint256 rateBps = 1000;

        deal(chainConfig.usdc, depositor, principal);
        vm.prank(depositor);
        usdc.approve(address(bill), principal);

        vm.prank(admin);
        uint256 billId = bill.issue(
            depositor, depositor, depositor, address(0),
            chainConfig.usdc, principal, rateBps, 365
        );

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        uint256 simpleExpected = principal + (principal * rateBps * 365) / (10000 * 365);
        assertTrue(info.redemptionValue >= simpleExpected, "Compound should exceed simple interest");
        assertApproxEqRel(info.redemptionValue, simpleExpected, 0.01e18, "Interest exceeds 1% tolerance");
    }
}
