// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {DiscountBillCore} from "../src/DiscountBillCore.sol";
import {DiscountBillLifecycle} from "../src/DiscountBillLifecycle.sol";
import {DiscountBillCampaigns} from "../src/DiscountBillCampaigns.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeDiscountBill
 * @notice Upgrades the DiscountBill proxy to the 3-contract split architecture.
 * @dev Deploys 3 contracts:
 *        1. DiscountBillLifecycle  (plain, ~15KB) — early redemption, merge
 *        2. DiscountBillCampaigns  (plain, ~13KB) — escheatment, series
 *        3. DiscountBillCore       (UUPS, ~21KB)  — proxy impl, issue/redeem, dispatch
 *      Then upgrades the proxy and wires the extensions.
 *
 *      The caller must hold UPGRADER_ROLE on the proxy.
 *
 * Usage (Sepolia):
 *   DISCOUNT_BILL_PROXY=0x... \
 *   forge script script/UpgradeDiscountBill.s.sol:UpgradeDiscountBill \
 *     --rpc-url $SEPOLIA_RPC --broadcast --private-key $KEY \
 *     --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
 *
 * Mainnet (Ledger):
 *   DISCOUNT_BILL_PROXY=0x4049F922977347fD217B266618a9F17bc97c181B \
 *   forge script script/UpgradeDiscountBill.s.sol:UpgradeDiscountBill \
 *     --rpc-url $MAINNET_RPC --broadcast \
 *     --ledger --sender 0xb109cb03A35827a1ef3570893d8972C523b6F2ce \
 *     --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
 *
 * Optional env vars:
 *   BASE_URI      — NFT metadata base (e.g. "https://api.cryptodeposit.org/nft/1/")
 *   CONTRACT_URI  — Collection metadata (e.g. "https://api.cryptodeposit.org/nft/collection.json")
 */
contract UpgradeDiscountBill is Script {
    function run() external {
        address payable proxy = payable(vm.envAddress("DISCOUNT_BILL_PROXY"));

        // Sanity: read existing state
        (bool ok, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("commissionRateBps()"));
        require(ok, "proxy not responding");
        uint256 commRate = abi.decode(data, (uint256));
        console.log("Current commission rate (bps):", commRate);
        console.log("Upgrading proxy at:", proxy);

        vm.startBroadcast();

        // 1. Deploy extensions (plain contracts, no proxy)
        DiscountBillLifecycle lifecycle = new DiscountBillLifecycle();
        console.log("DiscountBillLifecycle deployed:", address(lifecycle));

        DiscountBillCampaigns campaigns = new DiscountBillCampaigns();
        console.log("DiscountBillCampaigns deployed:", address(campaigns));

        // 2. Deploy new Core implementation
        DiscountBillCore core = new DiscountBillCore();
        console.log("DiscountBillCore deployed:", address(core));

        // 3. Upgrade proxy to new Core
        UUPSUpgradeable(proxy).upgradeToAndCall(address(core), "");
        console.log("Proxy upgraded to Core");

        // 4. Wire extensions
        DiscountBillCore(proxy).setLifecycleImpl(address(lifecycle));
        console.log("Lifecycle wired:", address(lifecycle));

        DiscountBillCore(proxy).setCampaignsImpl(address(campaigns));
        console.log("Campaigns wired:", address(campaigns));

        // 5. Optional: set NFT metadata
        string memory baseURI = vm.envOr("BASE_URI", string(""));
        if (bytes(baseURI).length > 0) {
            DiscountBillCore(proxy).setBaseURI(baseURI);
            console.log("Set baseURI:", baseURI);
        }

        string memory contractURI_ = vm.envOr("CONTRACT_URI", string(""));
        if (bytes(contractURI_).length > 0) {
            DiscountBillCore(proxy).setContractURI(contractURI_);
            console.log("Set contractURI:", contractURI_);
        }

        vm.stopBroadcast();

        // 6. Post-upgrade verification
        (ok, data) = proxy.staticcall(abi.encodeWithSignature("commissionRateBps()"));
        require(ok, "post-upgrade: proxy not responding");
        uint256 commRateAfter = abi.decode(data, (uint256));
        require(commRateAfter == commRate, "Commission rate changed after upgrade!");

        (ok, data) = proxy.staticcall(abi.encodeWithSignature("lifecycleImpl()"));
        require(ok && abi.decode(data, (address)) == address(lifecycle), "lifecycleImpl not wired");

        (ok, data) = proxy.staticcall(abi.encodeWithSignature("campaignsImpl()"));
        require(ok && abi.decode(data, (address)) == address(campaigns), "campaignsImpl not wired");

        console.log("");
        console.log("=== UPGRADE COMPLETE ===");
        console.log("  Core:      ", address(core));
        console.log("  Lifecycle: ", address(lifecycle));
        console.log("  Campaigns: ", address(campaigns));
        console.log("  Commission:", commRateAfter, "bps (unchanged)");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Run: ./scripts/validate_mainnet_upgrade.sh --post-bill");
        console.log("  2. Rebuild + redeploy rate_server");
        console.log("  3. Set claim window (separate step, after reviewing legacy bills)");
    }
}
