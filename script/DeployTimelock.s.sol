// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployTimelock
 * @notice Deploys an OpenZeppelin TimelockController for admin operation protection
 * @dev The timelock enforces a mandatory delay on critical operations:
 *      - Contract upgrades (UPGRADER_ROLE)
 *      - Address changes (setTreasury, setComplianceRegistry, setPriceOracle)
 *      - Strategy management (registerStrategy, removeStrategy)
 *      - Fund extraction (withdrawRevenue, sweepUntracked)
 *      - Liquidation parameter changes
 *      - Oracle signer rotation
 *
 *      The hardware wallet is both proposer and executor.
 *      Day-to-day operations (OPERATOR_ROLE) remain instant.
 *
 * Environment variables:
 *   PRIVATE_KEY0       — deployer private key
 *   ADDRESS0           — admin/hardware wallet address
 *   TIMELOCK_DELAY     — (optional) delay in seconds, default 86400 (24 hours)
 *
 * Post-deployment:
 *   Run TransferRolesToTimelock.s.sol to migrate roles on existing contracts.
 *
 * Usage:
 *   PRIVATE_KEY0=... ADDRESS0=... \
 *   forge script script/DeployTimelock.s.sol:DeployTimelock \
 *     --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY0
 */
contract DeployTimelock is Script {
    function run() external {
        address admin = vm.envAddress("ADDRESS0");
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(86400)); // 24 hours default

        vm.startBroadcast();

        // Proposers: hardware wallet can propose operations
        address[] memory proposers = new address[](1);
        proposers[0] = admin;

        // Executors: hardware wallet can execute after delay
        address[] memory executors = new address[](1);
        executors[0] = admin;

        // Deploy TimelockController
        // admin parameter is the initial TIMELOCK_ADMIN_ROLE holder
        TimelockController timelock = new TimelockController(
            delay,
            proposers,
            executors,
            admin // admin retains TIMELOCK_ADMIN_ROLE for configuration
        );

        vm.stopBroadcast();

        console.log("=== TimelockController Deployed ===");
        console.log("Address:       ", address(timelock));
        console.log("Min Delay:     ", delay, "seconds");
        console.log("Admin:         ", admin);
        console.log("Proposer:      ", admin);
        console.log("Executor:      ", admin);
        console.log("");
        console.log("Next step: Run TransferRolesToTimelock.s.sol");
    }
}
