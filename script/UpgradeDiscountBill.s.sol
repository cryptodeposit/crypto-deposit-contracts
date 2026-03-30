// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeDiscountBill
 * @notice UUPS proxy upgrade script for DiscountBillERC5095Upgradeable
 * @dev Deploys a new implementation and upgrades the existing proxy.
 *      The caller must hold UPGRADER_ROLE on the proxy.
 *
 * Usage (Sepolia):
 *   DISCOUNT_BILL_PROXY=0x7396d169DE124C5827A22f3750cfE39855Efd708 \
 *   forge script script/UpgradeDiscountBill.s.sol:UpgradeDiscountBill \
 *     --rpc-url $SEPOLIA_RPC \
 *     --broadcast \
 *     --private-key $UPGRADER_PRIVATE_KEY \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * Verify only:
 *   forge verify-contract <NEW_IMPL_ADDRESS> DiscountBillERC5095Upgradeable \
 *     --chain sepolia \
 *     --etherscan-api-key $ETHERSCAN_API_KEY
 *
 * After upgrade:
 *   - Update deployments/sepolia.json with new impl address
 *   - Run: source scripts/lib/contracts_env.sh && contracts_env_sync_from_deployments
 *   - Rebuild and redeploy rate_server to pick up new BillMerged event topic
 */
contract UpgradeDiscountBill is Script {
    function run() external {
        address proxy = vm.envAddress("DISCOUNT_BILL_PROXY");

        // Sanity check: verify the proxy is a DiscountBill by calling a view function
        DiscountBillERC5095Upgradeable bill = DiscountBillERC5095Upgradeable(proxy);
        uint256 commRate = bill.commissionRateBps();
        console.log("Current commission rate (bps):", commRate);
        console.log("Upgrading proxy at:", proxy);

        vm.startBroadcast();

        // 1. Deploy new implementation
        DiscountBillERC5095Upgradeable newImpl = new DiscountBillERC5095Upgradeable();
        console.log("New implementation deployed at:", address(newImpl));

        // 2. Upgrade proxy to new implementation
        //    No reinitialization needed — storage layout is unchanged,
        //    only the BillMerged event emit was added to merge().
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        // 3. Post-upgrade verification
        uint256 commRateAfter = bill.commissionRateBps();
        require(commRateAfter == commRate, "Commission rate changed after upgrade");
        console.log("Upgrade successful. Commission rate unchanged:", commRateAfter);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Update deployments/sepolia.json: discountBillImpl =", address(newImpl));
        console.log("  2. Run: source scripts/lib/contracts_env.sh && contracts_env_sync_from_deployments");
        console.log("  3. Rebuild and redeploy rate_server");
    }
}
