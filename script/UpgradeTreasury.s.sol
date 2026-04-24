// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeTreasury
 * @notice UUPS proxy upgrade for TreasuryUpgradeable
 * @dev Deploys new implementation, upgrades proxy. No reinitialization needed.
 *
 *      Changes in this upgrade (from v1.0.0-mainnet-first-deposit):
 *        - withdrawForRedemption: new params (principalPortion, maturityTimestamp)
 *          → fixes depositClaims tracking + clears maturity buckets
 *        - writeOffExpiredDeposit: new function for escheatment
 *        - settleEarlyRedemptionForfeit: new function for early redemption accounting
 *        - disburseExpiredFunds: new function for external expiry transfers
 *        - ownedCapital mapping: tracks principal from expired deposits
 *        - sweepUntracked: now includes ownedCapital in tracked balance
 *        - emergencyWithdraw: now clears ownedCapital
 *        - getTokenState/getFullSnapshot: now expose ownedCapital
 *
 *      Storage layout:
 *        +1 new mapping (ownedCapital) → __gap reduced from 40 to 39
 *
 *      IMPORTANT: This upgrade MUST be deployed alongside UpgradeDiscountBill
 *      because the withdrawForRedemption signature changed. DiscountBill calls
 *      withdrawForRedemption with 5 params; the old Treasury expects 3.
 *      Deploy Treasury upgrade FIRST, then DiscountBill.
 *
 * Usage (Sepolia):
 *   TREASURY_PROXY=0xd58b4a6e25a6d370FEEA573ec06aEb5ba2b11798 \
 *   forge script script/UpgradeTreasury.s.sol:UpgradeTreasury \
 *     --rpc-url $SEPOLIA_RPC \
 *     --broadcast \
 *     --private-key $UPGRADER_PRIVATE_KEY \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * Mainnet (Ledger):
 *   TREASURY_PROXY=0xda930739d391Da7064FF95651b42db264d5B5413 \
 *   forge script script/UpgradeTreasury.s.sol:UpgradeTreasury \
 *     --rpc-url $MAINNET_RPC \
 *     --broadcast \
 *     --ledger --sender 0xb109cb03A35827a1ef3570893d8972C523b6F2ce \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * After upgrade:
 *   1. Verify: cast call $PROXY "ownedCapital(address)" $USDC_ADDRESS → should return 0
 *   2. Upgrade DiscountBill (the new DiscountBill calls the new Treasury interface)
 *   3. Update deployments/{network}.json with new impl address
 *   4. Rebuild and redeploy rate_server (C++ decoder expects 8-field TokenState)
 */
contract UpgradeTreasury is Script {
    function run() external {
        address proxy = vm.envAddress("TREASURY_PROXY");

        // Sanity: read existing state
        TreasuryUpgradeable treasury = TreasuryUpgradeable(proxy);
        console.log("Upgrading Treasury proxy at:", proxy);

        // Read a known token's state to verify post-upgrade
        address checkToken = vm.envOr("CHECK_TOKEN", address(0));
        uint256 liabBefore;
        uint256 claimsBefore;
        if (checkToken != address(0)) {
            liabBefore = treasury.depositLiabilities(checkToken);
            claimsBefore = treasury.depositClaims(checkToken);
            console.log("Pre-upgrade depositLiabilities:", liabBefore);
            console.log("Pre-upgrade depositClaims:", claimsBefore);
        }

        vm.startBroadcast();

        // 1. Deploy new implementation
        TreasuryUpgradeable newImpl = new TreasuryUpgradeable();
        console.log("New implementation deployed at:", address(newImpl));

        // 2. Upgrade proxy — no reinitializer needed
        //    New storage (ownedCapital) defaults to 0 for all tokens.
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        // 3. Post-upgrade verification
        if (checkToken != address(0)) {
            uint256 liabAfter = treasury.depositLiabilities(checkToken);
            uint256 claimsAfter = treasury.depositClaims(checkToken);
            require(liabAfter == liabBefore, "depositLiabilities changed!");
            require(claimsAfter == claimsBefore, "depositClaims changed!");
            console.log("Post-upgrade depositLiabilities:", liabAfter, "(unchanged)");
            console.log("Post-upgrade depositClaims:", claimsAfter, "(unchanged)");

            // Verify new function exists
            uint256 owned = treasury.ownedCapital(checkToken);
            console.log("ownedCapital:", owned, "(should be 0)");
        }

        console.log("");
        console.log("Treasury upgrade successful.");
        console.log("");
        console.log("CRITICAL: Now upgrade DiscountBill (it calls the new Treasury interface).");
        console.log("  Run: UpgradeDiscountBill.s.sol with DISCOUNT_BILL_PROXY=...");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Update deployments/{network}.json: treasuryImpl =", address(newImpl));
        console.log("  2. Upgrade DiscountBill (MUST be done before any new deposits/redemptions)");
        console.log("  3. Rebuild rate_server (C++ expects 8-field TokenState)");
        console.log("  4. Run: source scripts/lib/contracts_env.sh && contracts_env_sync_from_deployments");
    }
}
