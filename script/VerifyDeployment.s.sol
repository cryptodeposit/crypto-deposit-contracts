// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StableTokenUpgradeable} from "../src/StableTokenUpgradeable.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {TreasuryYieldManager} from "../src/TreasuryYieldManager.sol";
import {AaveV3StrategyAdapter} from "../src/adapters/AaveV3StrategyAdapter.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VerifyDeployment
 * @notice Post-deploy verification — checks all roles, wiring, and config
 * @dev Read-only script, no broadcast. Reads addresses from env vars.
 *
 * Usage:
 *   STABLE_TOKEN=0x... COMPLIANCE=0x... TRAVEL_RULE=0x... TREASURY=0x... \
 *   DISCOUNT_BILL=0x... YIELD_MANAGER=0x... \
 *   AAVE_ADAPTER=0x... ADMIN=0x... \
 *   forge script script/VerifyDeployment.s.sol:VerifyDeployment \
 *     --rpc-url https://ethereum-sepolia-rpc.publicnode.com
 */
contract VerifyDeployment is Script {
    uint256 checks;
    uint256 passed;

    function run() external view {
        address stableToken = vm.envAddress("STABLE_TOKEN");
        vm.envAddress("COMPLIANCE"); // validated but not used directly
        address travelRule = vm.envAddress("TRAVEL_RULE");
        address treasury = vm.envAddress("TREASURY");
        address discountBill = vm.envAddress("DISCOUNT_BILL");
        address yieldManager = vm.envAddress("YIELD_MANAGER");
        address aaveAdapter = vm.envAddress("AAVE_ADAPTER");
        address admin = vm.envAddress("ADMIN");

        console.log("=== DEPLOYMENT VERIFICATION ===");
        console.log("");

        // ================================================================
        // 1. Role Checks
        // ================================================================
        console.log("--- Role Checks ---");

        TreasuryUpgradeable t = TreasuryUpgradeable(treasury);
        DiscountBillERC5095Upgradeable bill = DiscountBillERC5095Upgradeable(discountBill);
        TravelRuleRegistryUpgradeable travel = TravelRuleRegistryUpgradeable(travelRule);
        TreasuryYieldManager ym = TreasuryYieldManager(yieldManager);
        AaveV3StrategyAdapter adapter = AaveV3StrategyAdapter(aaveAdapter);

        // Treasury roles
        _check("Treasury: bill has DEPOSIT_MANAGER_ROLE",
            t.hasRole(t.DEPOSIT_MANAGER_ROLE(), discountBill));
        _check("Treasury: admin has OPERATOR_ROLE",
            t.hasRole(t.OPERATOR_ROLE(), admin));
        _check("Treasury: admin has DEFAULT_ADMIN_ROLE",
            t.hasRole(t.DEFAULT_ADMIN_ROLE(), admin));

        // Bill roles
        _check("DiscountBillERC5095: admin has OPERATOR_ROLE",
            bill.hasRole(bill.OPERATOR_ROLE(), admin));

        // TravelRule roles
        _check("TravelRule: bill has ORDERING_ROLE",
            travel.hasRole(travel.ORDERING_ROLE(), discountBill));
        _check("TravelRule: admin has ORDERING_ROLE",
            travel.hasRole(travel.ORDERING_ROLE(), admin));

        // Strategy adapter
        _check("AaveAdapter: treasury has TREASURY_ROLE",
            adapter.hasRole(adapter.TREASURY_ROLE(), treasury));

        // YieldManager
        _check("YieldManager: bill has OPERATOR_ROLE",
            ym.hasRole(ym.OPERATOR_ROLE(), discountBill));

        // ================================================================
        // 2. Cross-Contract References
        // ================================================================
        console.log("");
        console.log("--- Cross-Contract References ---");

        _check("DiscountBillERC5095.treasury == Treasury",
            address(bill.treasury()) == treasury);

        // Strategy registered
        address[] memory strategies = t.getStrategies();
        bool adapterRegistered = false;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i] == aaveAdapter) adapterRegistered = true;
        }
        _check("AaveAdapter registered in Treasury", adapterRegistered);

        // ================================================================
        // 3. Configuration
        // ================================================================
        console.log("");
        console.log("--- Configuration ---");

        ITreasury.TokenState memory state = t.getTokenState(stableToken);
        _check("Reserve ratio = 2000 bps (20%)", state.reserveRatioBps == 2000);

        // Travel rule policy (accessed via policyOf mapping)
        (uint256 threshold, bool alwaysOn, uint64 ttl) = travel.policyOf(stableToken);
        _check("Travel rule threshold = $1M", threshold == 1_000_000 * 1e6);
        _check("Travel rule TTL = 24h", ttl == 24 hours);
        _check("Travel rule not alwaysOn", !alwaysOn);

        // Token support
        _check("AaveAdapter supports mUSD", adapter.supportsToken(stableToken));

        // ================================================================
        // 4. Balances
        // ================================================================
        console.log("");
        console.log("--- Balances ---");

        uint256 treasuryBal = IERC20(stableToken).balanceOf(treasury);
        console.log("Treasury mUSD balance:", treasuryBal / 1e6, "USD");
        _check("Treasury funded (>= $1M)", treasuryBal >= 1_000_000 * 1e6);

        uint256 adminBal = IERC20(stableToken).balanceOf(admin);
        console.log("Admin mUSD balance:", adminBal / 1e6, "USD");

        // ================================================================
        // 5. Health
        // ================================================================
        console.log("");
        console.log("--- Health ---");

        bool almHealthy = t.isALMHealthy(stableToken);
        _check("ALM healthy for mUSD", almHealthy);

        // ================================================================
        // Summary
        // ================================================================
        console.log("");
        console.log("=================================");
        console.log("VERIFICATION COMPLETE");
        console.log("=================================");
    }

    function _check(string memory label, bool condition) internal pure {
        if (condition) {
            console.log("[PASS]", label);
        } else {
            console.log("[FAIL]", label);
        }
    }
}
