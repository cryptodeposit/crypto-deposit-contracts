// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ChainalysisComplianceAdapter} from "../src/adapters/ChainalysisComplianceAdapter.sol";
import {IChainalysisSanctionsOracle} from "../src/interfaces/IChainalysisSanctionsOracle.sol";

/// @dev Mock Chainalysis oracle for testing
contract MockSanctionsOracle is IChainalysisSanctionsOracle {
    mapping(address => bool) private _sanctioned;

    function setSanctioned(address addr, bool sanctioned) external {
        _sanctioned[addr] = sanctioned;
    }

    function isSanctioned(address addr) external view override returns (bool) {
        return _sanctioned[addr];
    }
}

contract ChainalysisComplianceAdapterTest is Test {
    ChainalysisComplianceAdapter private adapter;
    MockSanctionsOracle private oracle;
    address private owner = makeAddr("owner");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    function setUp() public {
        oracle = new MockSanctionsOracle();
        adapter = new ChainalysisComplianceAdapter(address(oracle), owner);
    }

    function testConstructorSetsOracle() public view {
        assertEq(address(adapter.oracle()), address(oracle));
    }

    function testConstructorSetsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    function testConstructorRevertsOnZeroOracle() public {
        vm.expectRevert(bytes("oracle=0"));
        new ChainalysisComplianceAdapter(address(0), owner);
    }

    function testIsAllowedReturnsTrueForNonSanctioned() public view {
        assertTrue(adapter.isAllowed(alice));
    }

    function testIsAllowedReturnsFalseForSanctioned() public {
        oracle.setSanctioned(alice, true);
        assertFalse(adapter.isAllowed(alice));
    }

    function testIsAllowedReflectsOracleChanges() public {
        oracle.setSanctioned(alice, true);
        assertFalse(adapter.isAllowed(alice));

        oracle.setSanctioned(alice, false);
        assertTrue(adapter.isAllowed(alice));
    }

    function testSetOracleByOwner() public {
        MockSanctionsOracle newOracle = new MockSanctionsOracle();
        vm.expectEmit(true, true, false, true);
        emit OracleUpdated(address(oracle), address(newOracle));
        vm.prank(owner);
        adapter.setOracle(address(newOracle));
        assertEq(address(adapter.oracle()), address(newOracle));
    }

    function testSetOracleRevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("oracle=0"));
        adapter.setOracle(address(0));
    }

    function testSetOracleRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        adapter.setOracle(makeAddr("newOracle"));
    }

    function testNewOracleIsUsedAfterUpdate() public {
        MockSanctionsOracle newOracle = new MockSanctionsOracle();
        newOracle.setSanctioned(bob, true);

        // bob is allowed on old oracle
        assertTrue(adapter.isAllowed(bob));

        // swap oracle
        vm.prank(owner);
        adapter.setOracle(address(newOracle));

        // bob is now blocked via new oracle
        assertFalse(adapter.isAllowed(bob));
    }
}
