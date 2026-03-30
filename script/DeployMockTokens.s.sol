// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StableTokenUpgradeable} from "../src/StableTokenUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {TreasuryYieldManager} from "../src/TreasuryYieldManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployMockTokens
 * @notice Deploys mETH and mMATIC mock tokens for local testing
 * @dev Requires existing deployment of DiscountBill, TravelRuleRegistry, TreasuryYieldManager
 *
 * These are ERC20 representations of ETH and MATIC (like wrapped tokens) with 18 decimals,
 * allowing them to be used in the DiscountBill deposit/yield system alongside mUSD/mEUR.
 *
 * Usage:
 *   forge script script/DeployMockTokens.s.sol:DeployMockTokens --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY0 \
 *     --sig "run(address,address,address)" $DISCOUNT_BILL $TRAVEL_RULE $TREASURY_YIELD_MANAGER
 */
contract DeployMockTokens is Script {
    // Travel rule threshold: $1,000,000 USD equivalent (with 18 decimals for ETH/MATIC)
    uint256 constant TRAVEL_RULE_THRESHOLD_18 = 1_000_000 * 1e18;
    // Travel rule TTL: 24 hours
    uint64 constant TRAVEL_RULE_TTL = 24 hours;

    // mETH config
    uint256 constant METH_APY_BPS = 350;              // 3.5% APY
    uint256 constant METH_FACILITY_EQUITY = 5_000 * 1e18;  // 5,000 ETH equiv
    uint256 constant METH_INITIAL_SUPPLY = 100_000;    // 100,000 mETH (pre-decimals)

    // mMATIC config
    uint256 constant MMATIC_APY_BPS = 500;             // 5.0% APY
    uint256 constant MMATIC_FACILITY_EQUITY = 10_000_000 * 1e18;  // 10M MATIC equiv
    uint256 constant MMATIC_INITIAL_SUPPLY = 50_000_000; // 50M mMATIC (pre-decimals)

    function run(
        address discountBill,
        address travelRule,
        address treasuryYieldManager
    ) external returns (address methProxy, address mmaticProxy) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY0");
        address admin = vm.envAddress("ADDRESS0");

        vm.startBroadcast(deployerKey);

        // ========================================
        // 1. Deploy mETH (Mock Wrapped Ether)
        // ========================================
        address methImpl = address(new StableTokenUpgradeable());
        methProxy = address(
            new ERC1967Proxy(
                methImpl,
                abi.encodeCall(
                    StableTokenUpgradeable.initialize,
                    ("Mock Wrapped Ether", "mETH", 18, METH_INITIAL_SUPPLY, admin)
                )
            )
        );

        // Configure TravelRule for mETH
        TravelRuleRegistryUpgradeable(travelRule).setPolicy(
            methProxy,
            TRAVEL_RULE_THRESHOLD_18,
            false,
            TRAVEL_RULE_TTL
        );

        // Add mETH to TreasuryYieldManager
        TreasuryYieldManager(treasuryYieldManager).addSupportedToken(
            methProxy,
            METH_APY_BPS,
            METH_FACILITY_EQUITY
        );

        // Approve DiscountBill to spend mETH
        StableTokenUpgradeable(methProxy).approve(discountBill, type(uint256).max);

        // ========================================
        // 2. Deploy mMATIC (Mock Polygon Token)
        // ========================================
        address mmaticImpl = address(new StableTokenUpgradeable());
        mmaticProxy = address(
            new ERC1967Proxy(
                mmaticImpl,
                abi.encodeCall(
                    StableTokenUpgradeable.initialize,
                    ("Mock Polygon", "mMATIC", 18, MMATIC_INITIAL_SUPPLY, admin)
                )
            )
        );

        // Configure TravelRule for mMATIC
        TravelRuleRegistryUpgradeable(travelRule).setPolicy(
            mmaticProxy,
            TRAVEL_RULE_THRESHOLD_18,
            false,
            TRAVEL_RULE_TTL
        );

        // Add mMATIC to TreasuryYieldManager
        TreasuryYieldManager(treasuryYieldManager).addSupportedToken(
            mmaticProxy,
            MMATIC_APY_BPS,
            MMATIC_FACILITY_EQUITY
        );

        // Approve DiscountBill to spend mMATIC
        StableTokenUpgradeable(mmaticProxy).approve(discountBill, type(uint256).max);

        vm.stopBroadcast();

        // Output
        console.log("");
        console.log("=== MOCK TOKEN DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("mETH proxy:", methProxy);
        console.log("mETH impl:", methImpl);
        console.log("  Symbol: mETH");
        console.log("  Decimals: 18");
        console.log("  Initial Supply:", METH_INITIAL_SUPPLY, "mETH");
        console.log("  APY:", METH_APY_BPS, "bps");
        console.log("");
        console.log("mMATIC proxy:", mmaticProxy);
        console.log("mMATIC impl:", mmaticImpl);
        console.log("  Symbol: mMATIC");
        console.log("  Decimals: 18");
        console.log("  Initial Supply:", MMATIC_INITIAL_SUPPLY, "mMATIC");
        console.log("  APY:", MMATIC_APY_BPS, "bps");
        console.log("");

        return (methProxy, mmaticProxy);
    }
}
