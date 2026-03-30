// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

/**
 * @title RegisterFacilityAdapter
 * @notice Phase 2: Register a deployed TreasuryFacilityAdapter with Treasury
 *         and grant OPERATOR_ROLE to the rate_server signer.
 *
 * @dev Requires DEFAULT_ADMIN_ROLE on Treasury. The Treasury admin is typically
 *      a Ledger wallet, separate from the deployer key used in Phase 1.
 *
 *      This script is called automatically by deploy_facility_adapter.sh Phase 2,
 *      or can be run standalone.
 *
 * Required env vars:
 *   TREASURY       — deployed Treasury proxy address
 *   ADAPTER        — deployed TreasuryFacilityAdapter address (from Phase 1)
 *   SIGNER         — rate_server signer address for OPERATOR_ROLE (optional, 0x0 to skip)
 *
 * Usage (Ledger — typical):
 *   TREASURY=0xd58b... ADAPTER=0x0971... SIGNER=0xb109... \
 *     forge script script/RegisterFacilityAdapter.s.sol:RegisterFacilityAdapter \
 *     --rpc-url $RPC --broadcast --ledger --hd-paths "m/44'/60'/0'/0/0"
 *
 * Usage (private key — if admin wallet has a key):
 *   TREASURY=0xd58b... ADAPTER=0x0971... SIGNER=0xb109... \
 *     forge script script/RegisterFacilityAdapter.s.sol:RegisterFacilityAdapter \
 *     --rpc-url $RPC --broadcast --private-key $ADMIN_KEY
 */
contract RegisterFacilityAdapter is Script {

    function run() external {
        address treasury = vm.envAddress("TREASURY");
        address adapter  = vm.envAddress("ADAPTER");
        address signer   = vm.envOr("SIGNER", address(0));

        console.log("=== Register Facility Adapter (Phase 2) ===");
        console.log("Treasury:", treasury);
        console.log("Adapter: ", adapter);
        console.log("Signer:  ", signer);
        console.log("");

        // Resolve broadcast identity
        uint256 key = vm.envOr("ADMIN_KEY", uint256(0));
        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }

        // 1. Check if adapter is already registered as a strategy
        (bool readOk, bytes memory readData) = treasury.staticcall(
            abi.encodeWithSignature("getStrategies()")
        );
        bool alreadyRegistered = false;
        if (readOk && readData.length > 0) {
            address[] memory strategies = abi.decode(readData, (address[]));
            for (uint256 i = 0; i < strategies.length; i++) {
                if (strategies[i] == adapter) {
                    alreadyRegistered = true;
                    break;
                }
            }
        }

        if (alreadyRegistered) {
            console.log("  Adapter already registered as strategy - skipping");
        } else {
            (bool ok1,) = treasury.call(
                abi.encodeWithSignature("registerStrategy(address)", adapter)
            );
            require(ok1, "Failed to register strategy on Treasury");
            console.log("  Registered adapter as strategy on Treasury");
        }

        // 2. Grant OPERATOR_ROLE on Treasury to the rate_server signer (idempotent)
        if (signer != address(0)) {
            bytes32 OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
            // hasRole is idempotent — grantRole on an already-granted role is a no-op
            (bool ok2,) = treasury.call(
                abi.encodeWithSignature("grantRole(bytes32,address)", OPERATOR_ROLE, signer)
            );
            require(ok2, "Failed to grant OPERATOR_ROLE to signer on Treasury");
            console.log("  Granted OPERATOR_ROLE to signer:", signer);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== PHASE 2 COMPLETE ===");
        console.log("");
    }
}
