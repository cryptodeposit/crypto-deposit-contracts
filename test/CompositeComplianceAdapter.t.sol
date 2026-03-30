// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CompositeComplianceAdapter} from "../src/adapters/CompositeComplianceAdapter.sol";
import {IComplianceRegistry} from "../src/interfaces/IComplianceRegistry.sol";

/// @dev Mock compliance registry for testing
contract MockComplianceRegistry is IComplianceRegistry {
    mapping(address => bool) private _blocked;

    function setBlocked(address account, bool blocked) external {
        _blocked[account] = blocked;
    }

    function isAllowed(address account) external view override returns (bool) {
        return !_blocked[account];
    }
}

contract CompositeComplianceAdapterTest is Test {
    CompositeComplianceAdapter private composite;
    MockComplianceRegistry private registryA;
    MockComplianceRegistry private registryB;
    address private owner = makeAddr("owner");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    event RegistryAdded(address indexed registry);
    event RegistryRemoved(address indexed registry);

    function setUp() public {
        composite = new CompositeComplianceAdapter(owner);
        registryA = new MockComplianceRegistry();
        registryB = new MockComplianceRegistry();
    }

    function testEmptyRegistriesAllowsAll() public view {
        assertTrue(composite.isAllowed(alice));
        assertTrue(composite.isAllowed(bob));
        assertEq(composite.registryCount(), 0);
    }

    function testSingleRegistryPassthrough() public {
        vm.prank(owner);
        composite.addRegistry(address(registryA));

        assertTrue(composite.isAllowed(alice));

        registryA.setBlocked(alice, true);
        assertFalse(composite.isAllowed(alice));
    }

    function testMultiRegistryANDLogic() public {
        vm.startPrank(owner);
        composite.addRegistry(address(registryA));
        composite.addRegistry(address(registryB));
        vm.stopPrank();

        // Both allow alice
        assertTrue(composite.isAllowed(alice));

        // Only registryA blocks alice — should be blocked
        registryA.setBlocked(alice, true);
        assertFalse(composite.isAllowed(alice));

        // Unblock in A, block in B — still blocked
        registryA.setBlocked(alice, false);
        registryB.setBlocked(alice, true);
        assertFalse(composite.isAllowed(alice));

        // Block in both
        registryA.setBlocked(alice, true);
        assertFalse(composite.isAllowed(alice));
    }

    function testAddRegistryEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit RegistryAdded(address(registryA));
        vm.prank(owner);
        composite.addRegistry(address(registryA));
        assertEq(composite.registryCount(), 1);
    }

    function testAddRegistryRevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("registry=0"));
        composite.addRegistry(address(0));
    }

    function testAddRegistryRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        composite.addRegistry(address(registryA));
    }

    function testRemoveRegistry() public {
        vm.startPrank(owner);
        composite.addRegistry(address(registryA));
        composite.addRegistry(address(registryB));
        assertEq(composite.registryCount(), 2);

        vm.expectEmit(true, false, false, true);
        emit RegistryRemoved(address(registryA));
        composite.removeRegistry(0);
        vm.stopPrank();

        assertEq(composite.registryCount(), 1);
        // registryB should now be at index 0 (swap-and-pop)
        assertEq(address(composite.registries(0)), address(registryB));
    }

    function testRemoveRegistryRevertsOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert(bytes("index out of bounds"));
        composite.removeRegistry(0);
    }

    function testRemoveRegistryRevertsForNonOwner() public {
        vm.startPrank(owner);
        composite.addRegistry(address(registryA));
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        composite.removeRegistry(0);
    }

    function testRemovedRegistryNoLongerChecked() public {
        vm.startPrank(owner);
        composite.addRegistry(address(registryA));
        composite.addRegistry(address(registryB));
        vm.stopPrank();

        // Block alice in registryA only
        registryA.setBlocked(alice, true);
        assertFalse(composite.isAllowed(alice));

        // Remove registryA — alice should now be allowed (only registryB remains)
        vm.prank(owner);
        composite.removeRegistry(0);
        assertTrue(composite.isAllowed(alice));
    }
}
