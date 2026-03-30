// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StableTokenUpgradeable} from "../src/StableTokenUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {TreasuryYieldManager} from "../src/TreasuryYieldManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployMEUR
 * @notice Deploys mEUR (Mock Euro Stablecoin) to local chains
 * @dev Requires existing deployment of DiscountBill, TravelRuleRegistry, TreasuryYieldManager
 *
 * Usage:
 *   forge script script/DeployMEUR.s.sol:DeployMEUR --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY0 \
 *     --sig "run(address,address,address)" $DISCOUNT_BILL $TRAVEL_RULE $TREASURY_YIELD_MANAGER
 */
contract DeployMEUR is Script {
    // Travel rule threshold: $1,000,000 USD equivalent (with 6 decimals)
    uint256 constant TRAVEL_RULE_THRESHOLD = 1_000_000 * 1e6;
    // Travel rule TTL: 24 hours
    uint64 constant TRAVEL_RULE_TTL = 24 hours;
    // Default APY for TreasuryYieldManager: 4.5%
    uint256 constant DEFAULT_APY_BPS = 450;
    // Facility commitment amount: $10M (equity)
    uint256 constant FACILITY_EQUITY = 10_000_000 * 1e6;
    // Initial supply: 10M mEUR
    uint256 constant INITIAL_SUPPLY = 10_000_000 * 1e6;

    function run(
        address discountBill,
        address travelRule,
        address treasuryYieldManager
    ) external returns (address meurProxy) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY0");
        address admin = vm.envAddress("ADDRESS0");

        vm.startBroadcast(deployerKey);

        // 1. Deploy mEUR StableToken
        address meurImpl = address(new StableTokenUpgradeable());
        meurProxy = address(
            new ERC1967Proxy(
                meurImpl,
                abi.encodeCall(
                    StableTokenUpgradeable.initialize,
                    ("Mock EUR", "mEUR", 6, INITIAL_SUPPLY, admin)
                )
            )
        );
        StableTokenUpgradeable meurToken = StableTokenUpgradeable(meurProxy);

        // 2. Configure TravelRule policy for mEUR
        TravelRuleRegistryUpgradeable(travelRule).setPolicy(
            meurProxy,
            TRAVEL_RULE_THRESHOLD,
            false,
            TRAVEL_RULE_TTL
        );

        // 3. Add mEUR to TreasuryYieldManager
        TreasuryYieldManager(treasuryYieldManager).addSupportedToken(
            meurProxy,
            DEFAULT_APY_BPS,
            FACILITY_EQUITY
        );

        // 4. Approve DiscountBill to spend mEUR from admin
        meurToken.approve(discountBill, type(uint256).max);

        vm.stopBroadcast();

        // Output
        console.log("");
        console.log("=== mEUR DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("mEUR proxy:", meurProxy);
        console.log("mEUR impl:", meurImpl);
        console.log("");
        console.log("Configuration:");
        console.log("  Symbol: mEUR");
        console.log("  Decimals: 6");
        console.log("  Initial Supply:", INITIAL_SUPPLY / 1e6, "mEUR");
        console.log("  Travel Rule Threshold:", TRAVEL_RULE_THRESHOLD / 1e6, "USD equivalent");
        console.log("  APY:", DEFAULT_APY_BPS, "bps");
        console.log("  Facility Equity:", FACILITY_EQUITY / 1e6, "USD equivalent");
        console.log("");

        return meurProxy;
    }
}
