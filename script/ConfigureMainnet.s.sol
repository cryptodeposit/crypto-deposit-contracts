// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {TreasuryYieldManager} from "../src/TreasuryYieldManager.sol";

/**
 * @title ConfigureMainnet
 * @notice Completes wiring for a partially-deployed mainnet stack.
 * @dev Sends only the 10 missing config calls from the interrupted deployment.
 *      All contract addresses are read from env vars (set by the calling script).
 *
 * Usage (Ledger):
 *   DEPLOYER=0x... forge script script/ConfigureMainnet.s.sol:ConfigureMainnet \
 *     --rpc-url $RPC_URL --broadcast --ledger --hd-paths "m/44'/60'/0'/0/0"
 */
contract ConfigureMainnet is Script {
    function run() external {
        // --- Deployed addresses (from env) ---
        address admin        = vm.envAddress("DEPLOYER");
        address travelProxy  = vm.envAddress("TRAVEL_RULE_PROXY");
        address treasuryProxy = vm.envAddress("TREASURY_PROXY");
        address billProxy    = vm.envAddress("BILL_PROXY");
        address yieldManager = vm.envAddress("YIELD_MANAGER");

        address usdc = vm.envAddress("USDC");
        address usdt = vm.envOr("USDT", address(0));

        uint256 depositCap       = vm.envOr("DEPOSIT_CAP", uint256(1_000_000 * 1e6));
        uint256 reserveRatioBps  = vm.envOr("RESERVE_RATIO_BPS", uint256(800));

        // --- Cast to typed interfaces ---
        TravelRuleRegistryUpgradeable travel = TravelRuleRegistryUpgradeable(travelProxy);
        TreasuryUpgradeable treasury = TreasuryUpgradeable(treasuryProxy);
        DiscountBillERC5095Upgradeable bill = DiscountBillERC5095Upgradeable(billProxy);
        TreasuryYieldManager yield_ = TreasuryYieldManager(yieldManager);

        // --- Start broadcast ---
        vm.startBroadcast(admin);

        // [17] grantRole: ORDERING_ROLE on TravelRule → admin
        travel.grantRole(travel.ORDERING_ROLE(), admin);

        // [18] grantRole: OPERATOR_ROLE on DiscountBill → admin
        bill.grantRole(bill.OPERATOR_ROLE(), admin);

        // [19] grantRole: DEPOSIT_MANAGER_ROLE on Treasury → bill
        treasury.grantRole(treasury.DEPOSIT_MANAGER_ROLE(), billProxy);

        // [20] grantRole: OPERATOR_ROLE on Treasury → admin
        treasury.grantRole(treasury.OPERATOR_ROLE(), admin);

        // [21] setTreasury on DiscountBill → treasury
        bill.setTreasury(treasuryProxy);

        // [22] grantRole: OPERATOR_ROLE on YieldManager → bill
        yield_.grantRole(yield_.OPERATOR_ROLE(), billProxy);

        // [23] setReserveRatio on Treasury: USDC
        treasury.setReserveRatio(usdc, reserveRatioBps);

        // [24] setReserveRatio on Treasury: USDT
        if (usdt != address(0)) {
            treasury.setReserveRatio(usdt, reserveRatioBps);
        }

        // [25] setMaxDepositAmount on DiscountBill: USDC
        bill.setMaxDepositAmount(usdc, depositCap);

        // [26] setMaxDepositAmount on DiscountBill: USDT
        if (usdt != address(0)) {
            bill.setMaxDepositAmount(usdt, depositCap);
        }

        vm.stopBroadcast();

        // --- Output ---
        console.log("");
        console.log("=== CONFIGURATION COMPLETE ===");
        console.log("");
        console.log("TravelRule ORDERING_ROLE -> admin:", admin);
        console.log("Bill OPERATOR_ROLE -> admin:", admin);
        console.log("Treasury DEPOSIT_MANAGER_ROLE -> bill:", billProxy);
        console.log("Treasury OPERATOR_ROLE -> admin:", admin);
        console.log("Bill treasury set to:", treasuryProxy);
        console.log("YieldManager OPERATOR_ROLE -> bill:", billProxy);
        console.log("Treasury reserve ratio (USDC):", reserveRatioBps, "bps");
        console.log("Bill deposit cap (USDC):", depositCap / 1e6, "USD");
        if (usdt != address(0)) {
            console.log("Treasury reserve ratio (USDT):", reserveRatioBps, "bps");
            console.log("Bill deposit cap (USDT):", depositCap / 1e6, "USD");
        }
    }
}
