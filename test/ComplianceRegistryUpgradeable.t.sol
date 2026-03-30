// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";

contract ComplianceRegistryUpgradeableTest is Test {
    ComplianceRegistryUpgradeable private registry;
    address private admin = makeAddr("admin");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    event BlockStatusSet(address indexed account, bool blocked, address indexed by);

    function setUp() public {
        ComplianceRegistryUpgradeable impl = new ComplianceRegistryUpgradeable();
        registry = ComplianceRegistryUpgradeable(
            address(
                new ERC1967Proxy(address(impl), abi.encodeCall(ComplianceRegistryUpgradeable.initialize, (admin)))
            )
        );
    }

    function testInitializeAdminNotZero() public {
        ComplianceRegistryUpgradeable fresh = ComplianceRegistryUpgradeable(
            address(new ERC1967Proxy(address(new ComplianceRegistryUpgradeable()), ""))
        );
        vm.expectRevert(bytes("admin=0"));
        fresh.initialize(address(0));
    }

    function testInitializeGrantsRolesAndDefaultAllowed() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.COMPLIANCE_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.UPGRADER_ROLE(), admin));
        assertTrue(registry.isAllowed(alice));
    }

    function testSetBlockedRequiresComplianceAdmin() public {
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, registry.COMPLIANCE_ADMIN_ROLE()
            )
        );
        registry.setBlocked(alice, true);
        vm.stopPrank();
    }

    function testSetBlockedTogglesStatusAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit BlockStatusSet(alice, true, admin);
        vm.prank(admin);
        registry.setBlocked(alice, true);
        assertFalse(registry.isAllowed(alice));

        vm.expectEmit(true, true, false, true);
        emit BlockStatusSet(alice, false, admin);
        vm.prank(admin);
        registry.setBlocked(alice, false);
        assertTrue(registry.isAllowed(alice));
    }

    function testSetBlockedBatchUpdatesAll() public {
        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;

        vm.expectEmit(true, true, false, true);
        emit BlockStatusSet(alice, true, admin);
        vm.expectEmit(true, true, false, true);
        emit BlockStatusSet(bob, true, admin);
        vm.prank(admin);
        registry.setBlockedBatch(accounts, true);
        assertFalse(registry.isAllowed(alice));
        assertFalse(registry.isAllowed(bob));

        vm.prank(admin);
        registry.setBlockedBatch(accounts, false);
        assertTrue(registry.isAllowed(alice));
        assertTrue(registry.isAllowed(bob));
    }
}
