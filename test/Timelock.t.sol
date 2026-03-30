// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OperatorPriceOracleUpgradeable} from "../src/OperatorPriceOracleUpgradeable.sol";

/**
 * @title TimelockTest
 * @notice Verifies that OpenZeppelin TimelockController correctly gates
 *         UPGRADER_ROLE and DEFAULT_ADMIN_ROLE operations with a delay.
 *
 *         Uses OperatorPriceOracleUpgradeable as a representative contract
 *         since the timelock pattern is identical across all contracts.
 */
contract TimelockTest is Test {
    TimelockController public timelock;
    OperatorPriceOracleUpgradeable public oracle;

    address admin = makeAddr("admin");
    address token1 = makeAddr("token1");

    uint256 constant DELAY = 86400; // 24 hours
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    function setUp() public {
        vm.startPrank(admin);

        // Deploy timelock
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        timelock = new TimelockController(DELAY, proposers, executors, admin);

        // Deploy oracle behind UUPS proxy
        OperatorPriceOracleUpgradeable impl = new OperatorPriceOracleUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(OperatorPriceOracleUpgradeable.initialize, (admin, admin, 300))
        );
        oracle = OperatorPriceOracleUpgradeable(address(proxy));

        // Transfer UPGRADER_ROLE and DEFAULT_ADMIN_ROLE to timelock
        oracle.grantRole(UPGRADER_ROLE, address(timelock));
        oracle.grantRole(DEFAULT_ADMIN_ROLE, address(timelock));

        // Revoke admin's critical roles (keep OPERATOR_ROLE)
        oracle.revokeRole(UPGRADER_ROLE, admin);
        oracle.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        vm.stopPrank();
    }

    // ========================================================================
    // Role verification
    // ========================================================================

    function test_roles_afterTransfer() public view {
        // Timelock has critical roles
        assertTrue(oracle.hasRole(UPGRADER_ROLE, address(timelock)));
        assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)));

        // Admin lost critical roles
        assertFalse(oracle.hasRole(UPGRADER_ROLE, admin));
        assertFalse(oracle.hasRole(DEFAULT_ADMIN_ROLE, admin));

        // Admin still has OPERATOR_ROLE
        assertTrue(oracle.hasRole(OPERATOR_ROLE, admin));
    }

    // ========================================================================
    // OPERATOR_ROLE operations remain instant
    // ========================================================================

    function test_operator_setPrice_instant() public {
        vm.prank(admin);
        oracle.setPrice(token1, 100_000_000); // $1.00

        (uint256 price, ) = oracle.getPrice(token1);
        assertEq(price, 100_000_000);
    }

    // ========================================================================
    // DEFAULT_ADMIN_ROLE operations require timelock
    // ========================================================================

    function test_admin_setTrustedSigner_blocked_directCall() public {
        address newSigner = makeAddr("newSigner");
        vm.prank(admin);
        vm.expectRevert(); // AccessControl: account is missing role
        oracle.setTrustedSigner(newSigner);
    }

    function test_admin_setTrustedSigner_viaTimelock() public {
        address newSigner = makeAddr("newSigner");

        // Encode the call
        bytes memory data = abi.encodeCall(oracle.setTrustedSigner, (newSigner));

        // Schedule
        vm.prank(admin);
        timelock.schedule(
            address(oracle),
            0,
            data,
            bytes32(0),
            bytes32(0),
            DELAY
        );

        // Cannot execute before delay
        vm.prank(admin);
        vm.expectRevert();
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(0));

        // Warp past delay
        vm.warp(block.timestamp + DELAY + 1);

        // Now execute succeeds
        vm.prank(admin);
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(0));

        // Verify the signer was changed
        assertEq(oracle.trustedSigner(), newSigner);
    }

    function test_admin_setMaxStaleness_viaTimelock() public {
        bytes memory data = abi.encodeCall(oracle.setMaxStaleness, (600));

        vm.prank(admin);
        timelock.schedule(address(oracle), 0, data, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(admin);
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(0));

        assertEq(oracle.maxStaleness(), 600);
    }

    // ========================================================================
    // Timelock cancellation
    // ========================================================================

    function test_cancel_scheduled_operation() public {
        address newSigner = makeAddr("newSigner");
        bytes memory data = abi.encodeCall(oracle.setTrustedSigner, (newSigner));
        bytes32 id = timelock.hashOperation(address(oracle), 0, data, bytes32(0), bytes32(0));

        // Schedule
        vm.prank(admin);
        timelock.schedule(address(oracle), 0, data, bytes32(0), bytes32(0), DELAY);

        assertTrue(timelock.isOperationPending(id));

        // Cancel
        vm.prank(admin);
        timelock.cancel(id);

        assertFalse(timelock.isOperationPending(id));

        // Cannot execute cancelled operation
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(admin);
        vm.expectRevert();
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(0));
    }

    // ========================================================================
    // Non-proposer cannot schedule
    // ========================================================================

    function test_schedule_revert_unauthorized() public {
        address attacker = makeAddr("attacker");
        bytes memory data = abi.encodeCall(oracle.setTrustedSigner, (attacker));

        vm.prank(attacker);
        vm.expectRevert();
        timelock.schedule(address(oracle), 0, data, bytes32(0), bytes32(0), DELAY);
    }

    // ========================================================================
    // Timelock delay enforcement
    // ========================================================================

    function test_execute_revert_beforeDelay() public {
        bytes memory data = abi.encodeCall(oracle.setMaxStaleness, (600));

        vm.prank(admin);
        timelock.schedule(address(oracle), 0, data, bytes32(0), bytes32(0), DELAY);

        // Try executing 1 second before delay expires
        vm.warp(block.timestamp + DELAY - 1);

        vm.prank(admin);
        vm.expectRevert();
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(0));
    }

    function test_execute_succeeds_atExactDelay() public {
        bytes memory data = abi.encodeCall(oracle.setMaxStaleness, (600));

        uint256 scheduleTime = block.timestamp;
        vm.prank(admin);
        timelock.schedule(address(oracle), 0, data, bytes32(0), bytes32(0), DELAY);

        // Execute at exact delay
        vm.warp(scheduleTime + DELAY);

        vm.prank(admin);
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(0));

        assertEq(oracle.maxStaleness(), 600);
    }
}
