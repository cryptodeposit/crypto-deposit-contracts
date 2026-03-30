// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";

contract TravelRuleRegistryUpgradeableTest is Test {
    TravelRuleRegistryUpgradeable private registry;
    address private admin = makeAddr("admin");
    address private ordering = makeAddr("ordering");
    address private otherOrdering = makeAddr("otherOrdering");
    address private payer = makeAddr("payer");
    address private payee = makeAddr("payee");
    address private token = makeAddr("token");

    uint256 private constant MIN_AMOUNT = 100;
    uint64 private constant TTL = 1 days;

    event PolicySet(address indexed token, uint256 minAmount, bool alwaysOn, uint64 ttl);
    event Precleared(
        bytes32 indexed key,
        address indexed token,
        address indexed payer,
        address payee,
        uint256 amount,
        uint64 expiresAt,
        address ordering
    );
    event Consumed(bytes32 indexed key);
    event Cancelled(bytes32 indexed key);

    function setUp() public {
        TravelRuleRegistryUpgradeable impl = new TravelRuleRegistryUpgradeable();
        registry = TravelRuleRegistryUpgradeable(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(TravelRuleRegistryUpgradeable.initialize, (admin))))
        );
        vm.startPrank(admin);
        registry.grantRole(registry.ORDERING_ROLE(), ordering);
        vm.stopPrank();
    }

    function testInitializeGrantsRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.POLICY_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.UPGRADER_ROLE(), admin));
    }

    function testSetPolicyRequiresPolicyAdmin() public {
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, registry.POLICY_ADMIN_ROLE()
            )
        );
        registry.setPolicy(token, MIN_AMOUNT, false, TTL);
        vm.stopPrank();
    }

    function testSetPolicyStoresValuesAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit PolicySet(token, MIN_AMOUNT, true, TTL);
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, true, TTL);

        (uint256 minAmount, bool alwaysOn, uint64 ttl) = registry.policyOf(token);
        assertEq(minAmount, MIN_AMOUNT);
        assertTrue(alwaysOn);
        assertEq(ttl, TTL);
    }

    function testPreclearRequiresOrderingRole() public {
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, false, TTL);

        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, registry.ORDERING_ROLE()
            )
        );
        registry.preclear(token, payer, payee, MIN_AMOUNT + 1, bytes32(0), bytes32(0), bytes32(0));
        vm.stopPrank();
    }

    function testPreclearSetsRecordAndAllowsCompliance() public {
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, false, TTL);
        vm.warp(1_000);

        uint256 amount = MIN_AMOUNT + 10;
        bytes32 expectedKey = keccak256(abi.encode(token, payer, payee, amount));
        vm.expectEmit(true, true, true, true);
        emit Precleared(expectedKey, token, payer, payee, amount, uint64(block.timestamp) + TTL, ordering);
        vm.prank(ordering);
        bytes32 key =
            registry.preclear(token, payer, payee, amount, keccak256("payer"), keccak256("payee"), keccak256("ref"));

        assertEq(key, expectedKey);
        assertTrue(registry.isCompliant(token, payer, payee, amount));
    }

    function testPreclearRevertsWhenPolicyUnset() public {
        vm.expectRevert(bytes("policy unset"));
        vm.prank(ordering);
        registry.preclear(token, payer, payee, MIN_AMOUNT, bytes32(0), bytes32(0), bytes32(0));
    }

    function testCancelRequiresOrderingAuthority() public {
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, false, TTL);
        vm.startPrank(ordering);
        bytes32 key = registry.preclear(token, payer, payee, MIN_AMOUNT, bytes32(0), bytes32(0), bytes32(0));
        vm.stopPrank();

        address outsider = makeAddr("outsider");
        vm.startPrank(outsider);
        vm.expectRevert(bytes("not ordering"));
        registry.cancel(key);
        vm.stopPrank();

        vm.startPrank(admin);
        registry.grantRole(registry.ORDERING_ROLE(), otherOrdering);
        vm.stopPrank();
        vm.expectEmit(true, false, false, true);
        emit Cancelled(key);
        vm.startPrank(otherOrdering);
        registry.cancel(key);
        vm.stopPrank();
        assertFalse(registry.isCompliant(token, payer, payee, MIN_AMOUNT));
    }

    function testConsumeMovesToConsumedAndEmits() public {
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, false, TTL);
        uint256 amount = MIN_AMOUNT + 5;
        vm.prank(ordering);
        bytes32 key = registry.preclear(token, payer, payee, amount, bytes32(0), bytes32(0), bytes32(0));

        vm.expectEmit(true, false, false, true);
        emit Consumed(key);
        registry.consume(token, payer, payee, amount);
        assertFalse(registry.isCompliant(token, payer, payee, amount));
    }

    function testConsumeRevertsWhenExpiredAndAllowsReclear() public {
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, false, 1);
        vm.warp(10);
        uint256 amount = MIN_AMOUNT + 2;
        vm.startPrank(ordering);
        bytes32 key = registry.preclear(token, payer, payee, amount, bytes32(0), bytes32(0), bytes32(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 2);
        vm.expectRevert(bytes("travel: expired"));
        registry.consume(token, payer, payee, amount);

        vm.expectEmit(true, true, true, true);
        emit Precleared(key, token, payer, payee, amount, uint64(block.timestamp) + 1, ordering);
        vm.startPrank(ordering);
        registry.preclear(token, payer, payee, amount, bytes32(0), bytes32(0), bytes32(0));
        vm.stopPrank();
        assertTrue(registry.isCompliant(token, payer, payee, amount));
    }

    function testIsCompliantBelowThresholdBypassesPreclear() public {
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, false, TTL);
        assertTrue(registry.isCompliant(token, payer, payee, MIN_AMOUNT - 1));
    }

    // ========== DIGITAL TWIN GETTER TESTS ==========

    function testGetRecordReturnsCorrectData() public {
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, false, TTL);

        uint256 amount = 200;
        bytes32 payerHash = keccak256("payer-data");
        bytes32 payeeHash = keccak256("payee-data");
        bytes32 refHash = keccak256("ref-123");

        vm.prank(ordering);
        bytes32 key = registry.preclear(token, payer, payee, amount, payerHash, payeeHash, refHash);

        TravelRuleRegistryUpgradeable.Record memory record = registry.getRecord(key);
        assertEq(record.payerHash, payerHash);
        assertEq(record.payeeHash, payeeHash);
        assertEq(record.customerRefHash, refHash);
        assertEq(record.ordering, ordering);
        assertEq(uint256(record.status), uint256(TravelRuleRegistryUpgradeable.Status.Ready));
        assertTrue(record.expiresAt > block.timestamp);
    }

    function testGetRecordReflectsConsumed() public {
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, false, TTL);

        uint256 amount = 200;
        vm.prank(ordering);
        bytes32 key = registry.preclear(token, payer, payee, amount, bytes32(0), bytes32(0), bytes32(0));

        registry.consume(token, payer, payee, amount);

        TravelRuleRegistryUpgradeable.Record memory record = registry.getRecord(key);
        assertEq(uint256(record.status), uint256(TravelRuleRegistryUpgradeable.Status.Consumed));
    }

    function testComputeKeyMatchesPreclearKey() public {
        vm.prank(admin);
        registry.setPolicy(token, MIN_AMOUNT, false, TTL);

        uint256 amount = 200;
        bytes32 computedKey = registry.computeKey(token, payer, payee, amount);

        vm.prank(ordering);
        bytes32 preclearKey = registry.preclear(token, payer, payee, amount, bytes32(0), bytes32(0), bytes32(0));

        assertEq(computedKey, preclearKey);
    }

    function testGetRecordEmptyForUnknownKey() public view {
        bytes32 unknownKey = keccak256("nonexistent");
        TravelRuleRegistryUpgradeable.Record memory record = registry.getRecord(unknownKey);
        assertEq(uint256(record.status), uint256(TravelRuleRegistryUpgradeable.Status.None));
        assertEq(record.expiresAt, 0);
    }
}
