// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TreasuryFacilityAdapter} from "../src/adapters/TreasuryFacilityAdapter.sol";

/**
 * @title DeployFacilityAdapter
 * @notice Deploys TreasuryFacilityAdapter for exchange yield deployment,
 *         registers it with an existing Treasury, and grants required roles.
 *
 * @dev Phase 1 only: deploys adapter, adds tokens, grants TREASURY_ROLE.
 *      Does NOT call treasury.registerStrategy() — that requires DEFAULT_ADMIN_ROLE
 *      on Treasury, which may belong to a different wallet (e.g. Ledger).
 *      Use RegisterFacilityAdapter.s.sol (Phase 2) for Treasury registration.
 *
 * Required env vars:
 *   DEPLOYER_KEY   — private key (testnet) OR use --ledger for mainnet
 *   TREASURY       — deployed Treasury proxy address (for TREASURY_ROLE grant)
 *   CUSTODY        — exchange deposit address (e.g. Binance/Coinbase)
 *   USDC           — USDC token address on target chain
 *   USDT           — USDT token address on target chain (optional, set 0x0 to skip)
 *
 * Usage (Sepolia — private key):
 *   DEPLOYER_KEY=0x... TREASURY=0xd58b... CUSTODY=0x... USDC=0x... USDT=0x... SIGNER=0x... \
 *     forge script script/DeployFacilityAdapter.s.sol:DeployFacilityAdapter \
 *     --rpc-url $SEPOLIA_RPC --broadcast
 *
 * Usage (Mainnet — Ledger):
 *   TREASURY=0xda93... CUSTODY=0x... USDC=0xA0b8... USDT=0xdAC1... SIGNER=0x... \
 *     forge script script/DeployFacilityAdapter.s.sol:DeployFacilityAdapter \
 *     --rpc-url $MAINNET_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY \
 *     --ledger --hd-paths "m/44'/60'/0'/0/0"
 */
contract DeployFacilityAdapter is Script {

    function run() external returns (address facilityAdapter) {
        // --- Read configuration from env ---
        address treasury = vm.envAddress("TREASURY");
        address custody  = vm.envAddress("CUSTODY");
        address usdc     = vm.envAddress("USDC");
        address usdt     = vm.envOr("USDT", address(0));
        address signer   = vm.envOr("SIGNER", address(0));

        // Resolve deployer: DEPLOYER_KEY for testnet, --ledger for mainnet
        address admin = _resolveDeployer();

        // --- Start broadcast ---
        _startBroadcast();

        // 1. Deploy TreasuryFacilityAdapter
        facilityAdapter = address(new TreasuryFacilityAdapter(admin, custody));
        console.log("TreasuryFacilityAdapter deployed:", facilityAdapter);

        // 2. Add supported tokens
        TreasuryFacilityAdapter(facilityAdapter).addSupportedToken(usdc);
        console.log("  Added USDC:", usdc);

        if (usdt != address(0)) {
            TreasuryFacilityAdapter(facilityAdapter).addSupportedToken(usdt);
            console.log("  Added USDT:", usdt);
        }

        // 3. Grant TREASURY_ROLE to Treasury contract on the adapter
        //    (so Treasury.allocateToStrategy can call adapter.deploy)
        bytes32 TREASURY_ROLE = keccak256("TREASURY_ROLE");
        TreasuryFacilityAdapter(facilityAdapter).grantRole(TREASURY_ROLE, treasury);
        console.log("  Granted TREASURY_ROLE to Treasury:", treasury);

        // NOTE: Steps 4-5 (registerStrategy + grantRole on Treasury) require
        //       DEFAULT_ADMIN_ROLE on the Treasury contract. If the deployer
        //       does NOT hold that role, run RegisterFacilityAdapter.s.sol
        //       separately with the admin wallet (e.g. --ledger).
        //
        //       The bash script deploy_facility_adapter.sh handles this
        //       automatically as Phase 2.

        vm.stopBroadcast();

        // --- Summary ---
        console.log("");
        console.log("=== FACILITY ADAPTER DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("TreasuryFacilityAdapter:", facilityAdapter);
        console.log("  name:     Treasury Facility");
        console.log("  isLiquid: false");
        console.log("  custody:  ", custody);
        console.log("Treasury:   ", treasury);
        console.log("Signer:     ", signer);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Update contracts.env: CONTRACTS_<chainId>_FACILITY_ADAPTER=", facilityAdapter);
        console.log("  2. Verify custody address matches exchange deposit address");
        console.log("  3. Fund Treasury with tokens before calling allocateToStrategy");
        console.log("");

        return facilityAdapter;
    }

    // --- Deployer resolution (matches DeployMainnet.s.sol pattern) ---

    function _resolveDeployer() internal view returns (address) {
        // Try DEPLOYER env var first (for Ledger — address only)
        address deployer = vm.envOr("DEPLOYER", address(0));
        if (deployer != address(0)) return deployer;

        // Fall back to deriving from DEPLOYER_KEY
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (key != 0) return vm.addr(key);

        // Anvil default
        return vm.addr(vm.envOr("PRIVATE_KEY0", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)));
    }

    function _startBroadcast() internal {
        // Prefer DEPLOYER_KEY (testnet), otherwise broadcast without key (--ledger)
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }
    }
}
