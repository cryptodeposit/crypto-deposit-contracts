// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {BillTokenFactory} from "../src/BillTokenFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployProduction
 * @notice Minimal Phase 1 production deployment — 3 contracts, legacy issuer path
 * @dev Deploys ComplianceRegistry, TravelRuleRegistry, and DiscountBillERC5095.
 *      NO Treasury — uses legacy issuer path where deposited tokens flow to admin wallet.
 *      Admin can "pull down" funds by simply revoking the USDC approval.
 *
 *      Post-deploy actions:
 *        1. Admin must approve DiscountBill to spend USDC: USDC.approve(discountBill, max)
 *        2. Verify contracts on block explorer
 *
 * Usage (Arbitrum):
 *   forge script script/DeployProduction.s.sol:DeployProduction \
 *     --rpc-url $ARBITRUM_RPC_URL \
 *     --broadcast \
 *     --private-key $DEPLOYER_KEY \
 *     --verify \
 *     --etherscan-api-key $ARBISCAN_API_KEY
 *
 * Usage (Arbitrum Sepolia testnet):
 *   forge script script/DeployProduction.s.sol:DeployProduction \
 *     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --private-key $DEPLOYER_KEY \
 *     --verify \
 *     --etherscan-api-key $ARBISCAN_API_KEY
 */
contract DeployProduction is Script {
    // Arbitrum USDC (native Circle USDC, not bridged)
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    // Arbitrum Sepolia USDC (for testnet)
    address constant ARBITRUM_SEPOLIA_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    // Travel rule threshold: $1,000,000 USD (6 decimals)
    uint256 constant TRAVEL_RULE_THRESHOLD = 1_000_000 * 1e6;
    // Travel rule TTL: 24 hours
    uint64 constant TRAVEL_RULE_TTL = 24 hours;

    struct ProductionDeployment {
        address compliance;
        address complianceImpl;
        address travelRule;
        address travelRuleImpl;
        address discountBill;
        address discountBillImpl;
        address billTokenFactory;
    }

    function run() external returns (ProductionDeployment memory) {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address admin = vm.addr(deployerKey);

        // Determine USDC address based on chain
        uint256 chainId = block.chainid;
        address usdc;
        if (chainId == 42161) {
            usdc = ARBITRUM_USDC;
        } else if (chainId == 421614) {
            usdc = ARBITRUM_SEPOLIA_USDC;
        } else {
            // Allow override via env var for other chains
            usdc = vm.envAddress("USDC_ADDRESS");
        }

        vm.startBroadcast(deployerKey);

        // 1. Deploy ComplianceRegistry
        address complianceImpl = address(new ComplianceRegistryUpgradeable());
        address complianceProxy = address(
            new ERC1967Proxy(
                complianceImpl,
                abi.encodeCall(ComplianceRegistryUpgradeable.initialize, (admin))
            )
        );
        ComplianceRegistryUpgradeable compliance = ComplianceRegistryUpgradeable(complianceProxy);

        // 2. Deploy TravelRuleRegistry
        address travelImpl = address(new TravelRuleRegistryUpgradeable());
        address travelProxy = address(
            new ERC1967Proxy(
                travelImpl,
                abi.encodeCall(TravelRuleRegistryUpgradeable.initialize, (admin))
            )
        );
        TravelRuleRegistryUpgradeable travel = TravelRuleRegistryUpgradeable(travelProxy);

        // 3. Deploy DiscountBillERC5095 (admin is both admin and issuer for Phase 1)
        address billImpl = address(new DiscountBillERC5095Upgradeable());
        address billProxy = address(
            new ERC1967Proxy(
                billImpl,
                abi.encodeCall(DiscountBillERC5095Upgradeable.initialize, (admin, admin, compliance, travel))
            )
        );
        DiscountBillERC5095Upgradeable discountBill = DiscountBillERC5095Upgradeable(billProxy);

        // 3b. Deploy BillTokenFactory and connect to bill
        BillTokenFactory billTokenFactory = new BillTokenFactory();
        discountBill.setBillTokenFactory(address(billTokenFactory));

        // 4. Configure TravelRule policy for USDC
        travel.setPolicy(usdc, TRAVEL_RULE_THRESHOLD, false, TRAVEL_RULE_TTL);

        // 5. Grant ORDERING_ROLE to DiscountBill on TravelRule
        travel.grantRole(travel.ORDERING_ROLE(), billProxy);

        // 6. Grant OPERATOR_ROLE to admin on DiscountBill
        discountBill.grantRole(discountBill.OPERATOR_ROLE(), admin);

        // NOTE: No Treasury deployment — legacy issuer path.
        // treasury remains address(0), so tokens flow: depositor -> admin wallet
        // Admin must run: USDC.approve(discountBill, type(uint256).max) after deploy

        vm.stopBroadcast();

        // Output
        console.log("");
        console.log("=== PRODUCTION DEPLOYMENT (Phase 1 - Legacy Path) ===");
        console.log("");
        console.log("Chain ID:", chainId);
        console.log("USDC:", usdc);
        console.log("");
        console.log("--- Proxies ---");
        console.log("ComplianceRegistry:", complianceProxy);
        console.log("TravelRuleRegistry:", travelProxy);
        console.log("DiscountBillERC5095:", billProxy);
        console.log("BillTokenFactory:", address(billTokenFactory));
        console.log("");
        console.log("--- Implementations ---");
        console.log("ComplianceRegistry impl:", complianceImpl);
        console.log("TravelRuleRegistry impl:", travelImpl);
        console.log("DiscountBillERC5095 impl:", billImpl);
        console.log("");
        console.log("--- Configuration ---");
        console.log("Admin/Issuer:", admin);
        console.log("Treasury: address(0) [LEGACY PATH]");
        console.log("Travel Rule Threshold:", TRAVEL_RULE_THRESHOLD / 1e6, "USD");
        console.log("");
        console.log("--- POST-DEPLOY ACTION REQUIRED ---");
        console.log("Admin must approve DiscountBill to spend USDC:");
        console.log("  USDC.approve(%s, type(uint256).max)", billProxy);
        console.log("");

        // JSON output
        console.log("--- JSON ---");
        console.log("{");
        console.log('  "chainId": %s,', vm.toString(chainId));
        console.log('  "usdc": "%s",', usdc);
        console.log('  "compliance": "%s",', complianceProxy);
        console.log('  "travelRule": "%s",', travelProxy);
        console.log('  "discountBill": "%s",', billProxy);
        console.log('  "billTokenFactory": "%s",', address(billTokenFactory));
        console.log('  "admin": "%s",', admin);
        console.log('  "treasury": "0x0000000000000000000000000000000000000000"');
        console.log("}");

        return ProductionDeployment({
            compliance: complianceProxy,
            complianceImpl: complianceImpl,
            travelRule: travelProxy,
            travelRuleImpl: travelImpl,
            discountBill: billProxy,
            discountBillImpl: billImpl,
            billTokenFactory: address(billTokenFactory)
        });
    }
}
