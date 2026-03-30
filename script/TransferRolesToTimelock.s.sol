// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title TransferRolesToTimelock
 * @notice Transfers UPGRADER_ROLE and DEFAULT_ADMIN_ROLE from the hardware wallet
 *         to the TimelockController on all deployed contracts.
 *
 * @dev For each contract:
 *      1. Grant UPGRADER_ROLE to timelock
 *      2. Grant DEFAULT_ADMIN_ROLE to timelock
 *      3. Revoke UPGRADER_ROLE from admin
 *      4. Revoke DEFAULT_ADMIN_ROLE from admin
 *
 *      The admin retains OPERATOR_ROLE for day-to-day operations.
 *      pause() stays instant via a separate PAUSER or DEFAULT_ADMIN role on the admin.
 *
 * Environment variables:
 *   PRIVATE_KEY0     — admin private key
 *   ADDRESS0         — admin address (current role holder)
 *   TIMELOCK         — TimelockController address
 *
 *   Contract addresses (set per-chain):
 *   DISCOUNT_BILL, TREASURY, COMPLIANCE_REGISTRY, TRAVEL_RULE_REGISTRY,
 *   PRICE_ORACLE, COLLATERAL_VAULT, BORROWING_ENGINE, LIQUIDATION_MANAGER,
 *   HAIRCUT_REGISTRY, STABLE_TOKEN
 *
 * Usage:
 *   PRIVATE_KEY0=... ADDRESS0=... TIMELOCK=0x... DISCOUNT_BILL=0x... TREASURY=0x... ... \
 *   forge script script/TransferRolesToTimelock.s.sol:TransferRolesToTimelock \
 *     --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY0
 */
contract TransferRolesToTimelock is Script {
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    function run() external {
        address admin = vm.envAddress("ADDRESS0");
        address timelock = vm.envAddress("TIMELOCK");

        // Collect all contract addresses (skip any not set)
        address[] memory contracts = _collectContracts();

        vm.startBroadcast();

        for (uint256 i = 0; i < contracts.length; i++) {
            if (contracts[i] == address(0)) continue;

            IAccessControl ac = IAccessControl(contracts[i]);

            // Grant roles to timelock
            if (!ac.hasRole(UPGRADER_ROLE, timelock)) {
                ac.grantRole(UPGRADER_ROLE, timelock);
                console.log("  Granted UPGRADER_ROLE to timelock on", contracts[i]);
            }
            if (!ac.hasRole(DEFAULT_ADMIN_ROLE, timelock)) {
                ac.grantRole(DEFAULT_ADMIN_ROLE, timelock);
                console.log("  Granted DEFAULT_ADMIN_ROLE to timelock on", contracts[i]);
            }

            // Revoke roles from admin
            if (ac.hasRole(UPGRADER_ROLE, admin)) {
                ac.revokeRole(UPGRADER_ROLE, admin);
                console.log("  Revoked UPGRADER_ROLE from admin on", contracts[i]);
            }
            if (ac.hasRole(DEFAULT_ADMIN_ROLE, admin)) {
                ac.revokeRole(DEFAULT_ADMIN_ROLE, admin);
                console.log("  Revoked DEFAULT_ADMIN_ROLE from admin on", contracts[i]);
            }
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Role Transfer Complete ===");
        console.log("Timelock:", timelock);
        console.log("Admin retains: OPERATOR_ROLE (day-to-day ops)");
        console.log("Timelock holds: UPGRADER_ROLE + DEFAULT_ADMIN_ROLE (critical ops)");
    }

    function _collectContracts() internal view returns (address[] memory) {
        address[] memory contracts = new address[](10);
        contracts[0] = vm.envOr("DISCOUNT_BILL", address(0));
        contracts[1] = vm.envOr("TREASURY", address(0));
        contracts[2] = vm.envOr("COMPLIANCE_REGISTRY", address(0));
        contracts[3] = vm.envOr("TRAVEL_RULE_REGISTRY", address(0));
        contracts[4] = vm.envOr("PRICE_ORACLE", address(0));
        contracts[5] = vm.envOr("COLLATERAL_VAULT", address(0));
        contracts[6] = vm.envOr("BORROWING_ENGINE", address(0));
        contracts[7] = vm.envOr("LIQUIDATION_MANAGER", address(0));
        contracts[8] = vm.envOr("HAIRCUT_REGISTRY", address(0));
        contracts[9] = vm.envOr("STABLE_TOKEN", address(0));
        return contracts;
    }
}
