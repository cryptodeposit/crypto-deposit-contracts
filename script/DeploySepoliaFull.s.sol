// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StableTokenUpgradeable} from "../src/StableTokenUpgradeable.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {BillTokenFactory} from "../src/BillTokenFactory.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {TreasuryYieldManager} from "../src/TreasuryYieldManager.sol";
import {AaveV3StrategyAdapter} from "../src/adapters/AaveV3StrategyAdapter.sol";
import {MockAaveV3Pool} from "../test/mocks/MockAaveV3Pool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeploySepoliaFull
 * @notice Full-stack deployment to Ethereum Sepolia — all contracts + wiring
 * @dev Deploys own test token (mUSD) to avoid Circle USDC faucet dependency.
 *      Includes ERC5095 bill, Treasury, Aave strategy adapter with mock pool.
 *
 * Usage:
 *   DEPLOYER_KEY=0x... forge script script/DeploySepoliaFull.s.sol:DeploySepoliaFull \
 *     --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeploySepoliaFull is Script {
    uint256 constant TRAVEL_RULE_THRESHOLD = 1_000_000 * 1e6; // $1M
    uint64  constant TRAVEL_RULE_TTL = 24 hours;
    uint256 constant DEFAULT_APY_BPS = 450;           // 4.5%
    uint256 constant FACILITY_EQUITY = 10_000_000 * 1e6; // $10M
    uint256 constant INITIAL_SUPPLY = 10_000_000 * 1e6;  // 10M mUSD
    uint256 constant TREASURY_FUNDING = 1_000_000 * 1e6;  // $1M to treasury
    uint256 constant POOL_FUNDING = 100_000 * 1e6;         // $100k to mock pool
    uint256 constant RESERVE_RATIO_BPS = 2000;             // 20%

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address admin = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ====================================================================
        // 1. StableToken (test mUSD — 6 decimals, 10M supply)
        // ====================================================================
        address stableImpl = address(new StableTokenUpgradeable());
        address stableProxy = address(
            new ERC1967Proxy(
                stableImpl,
                abi.encodeCall(
                    StableTokenUpgradeable.initialize,
                    ("Mock USD", "mUSD", 6, INITIAL_SUPPLY, admin)
                )
            )
        );

        // ====================================================================
        // 2. ComplianceRegistry
        // ====================================================================
        address complianceImpl = address(new ComplianceRegistryUpgradeable());
        address complianceProxy = address(
            new ERC1967Proxy(
                complianceImpl,
                abi.encodeCall(ComplianceRegistryUpgradeable.initialize, (admin))
            )
        );

        // ====================================================================
        // 3. TravelRuleRegistry
        // ====================================================================
        address travelImpl = address(new TravelRuleRegistryUpgradeable());
        address travelProxy = address(
            new ERC1967Proxy(
                travelImpl,
                abi.encodeCall(TravelRuleRegistryUpgradeable.initialize, (admin))
            )
        );

        // ====================================================================
        // 4. Treasury
        // ====================================================================
        address treasuryImpl = address(new TreasuryUpgradeable());
        address treasuryProxy = address(
            new ERC1967Proxy(
                treasuryImpl,
                abi.encodeCall(TreasuryUpgradeable.initialize, (admin))
            )
        );
        TreasuryUpgradeable treasury = TreasuryUpgradeable(treasuryProxy);

        // ====================================================================
        // 5. DiscountBillERC5095
        // ====================================================================
        address billImpl = address(new DiscountBillERC5095Upgradeable());
        address billProxy = address(
            new ERC1967Proxy(
                billImpl,
                abi.encodeCall(
                    DiscountBillERC5095Upgradeable.initialize,
                    (admin, admin, ComplianceRegistryUpgradeable(complianceProxy),
                     TravelRuleRegistryUpgradeable(travelProxy))
                )
            )
        );
        DiscountBillERC5095Upgradeable bill = DiscountBillERC5095Upgradeable(billProxy);

        // ====================================================================
        // 5b. BillTokenFactory
        // ====================================================================
        BillTokenFactory billTokenFactory = new BillTokenFactory();
        bill.setBillTokenFactory(address(billTokenFactory));

        // ====================================================================
        // 7. TreasuryYieldManager
        // ====================================================================
        TreasuryYieldManager yieldManager = new TreasuryYieldManager(admin);
        yieldManager.addSupportedToken(stableProxy, DEFAULT_APY_BPS, FACILITY_EQUITY);

        // ====================================================================
        // 8. MockAaveV3Pool + AaveV3StrategyAdapter
        // ====================================================================
        MockAaveV3Pool aavePool = new MockAaveV3Pool();
        aavePool.initReserve(stableProxy);

        AaveV3StrategyAdapter aaveAdapter = new AaveV3StrategyAdapter(admin, address(aavePool));
        aaveAdapter.addSupportedToken(stableProxy);

        // ====================================================================
        // Wiring — Role Grants
        // ====================================================================

        // Travel rule policy for mUSD
        TravelRuleRegistryUpgradeable(travelProxy).setPolicy(
            stableProxy, TRAVEL_RULE_THRESHOLD, false, TRAVEL_RULE_TTL
        );

        // ORDERING_ROLE on TravelRule for bill + admin (for manual preclears)
        bytes32 orderingRole = TravelRuleRegistryUpgradeable(travelProxy).ORDERING_ROLE();
        TravelRuleRegistryUpgradeable(travelProxy).grantRole(orderingRole, billProxy);
        TravelRuleRegistryUpgradeable(travelProxy).grantRole(orderingRole, admin);

        // OPERATOR_ROLE on bill for admin
        bill.grantRole(bill.OPERATOR_ROLE(), admin);

        // DEPOSIT_MANAGER_ROLE on Treasury for bill
        treasury.grantRole(treasury.DEPOSIT_MANAGER_ROLE(), billProxy);

        // OPERATOR_ROLE on Treasury for admin
        treasury.grantRole(treasury.OPERATOR_ROLE(), admin);

        // Connect bill to Treasury
        bill.setTreasury(treasuryProxy);

        // Aave strategy: TREASURY_ROLE for Treasury, register with Treasury
        aaveAdapter.grantRole(aaveAdapter.TREASURY_ROLE(), treasuryProxy);
        treasury.registerStrategy(address(aaveAdapter));

        // TreasuryYieldManager: OPERATOR_ROLE for bill
        yieldManager.grantRole(yieldManager.OPERATOR_ROLE(), billProxy);

        // Reserve ratio
        treasury.setReserveRatio(stableProxy, RESERVE_RATIO_BPS);

        // ====================================================================
        // Funding
        // ====================================================================
        StableTokenUpgradeable(stableProxy).transfer(treasuryProxy, TREASURY_FUNDING);
        StableTokenUpgradeable(stableProxy).transfer(address(aavePool), POOL_FUNDING);

        // Approve bill for legacy path fallback
        StableTokenUpgradeable(stableProxy).approve(billProxy, type(uint256).max);

        vm.stopBroadcast();

        // ====================================================================
        // Output
        // ====================================================================
        console.log("");
        console.log("=== SEPOLIA FULL-STACK DEPLOYMENT ===");
        console.log("");
        console.log("Chain ID:", block.chainid);
        console.log("");
        console.log("--- Proxies ---");
        console.log("StableToken (mUSD):", stableProxy);
        console.log("ComplianceRegistry:", complianceProxy);
        console.log("TravelRuleRegistry:", travelProxy);
        console.log("Treasury:", treasuryProxy);
        console.log("DiscountBillERC5095:", billProxy);
        console.log("TreasuryYieldManager:", address(yieldManager));
        console.log("MockAaveV3Pool:", address(aavePool));
        console.log("AaveV3StrategyAdapter:", address(aaveAdapter));
        console.log("BillTokenFactory:", address(billTokenFactory));
        console.log("BillMathLib: (linked at compile time)");
        console.log("");
        console.log("--- Implementations ---");
        console.log("StableToken impl:", stableImpl);
        console.log("ComplianceRegistry impl:", complianceImpl);
        console.log("TravelRuleRegistry impl:", travelImpl);
        console.log("Treasury impl:", treasuryImpl);
        console.log("DiscountBillERC5095 impl:", billImpl);
        console.log("");
        console.log("--- Config ---");
        console.log("Admin:", admin);
        console.log("Reserve Ratio: 20%");
        console.log("Travel Rule Threshold: $1M");
        console.log("APY: 4.5%");
        console.log("Treasury funded: $1M");
        console.log("Aave pool funded: $100k");
        console.log("");

        // JSON output
        console.log("--- JSON ---");
        console.log("{");
        console.log('  "chainId": %s,', vm.toString(block.chainid));
        console.log('  "stableToken": "%s",', stableProxy);
        console.log('  "compliance": "%s",', complianceProxy);
        console.log('  "travelRule": "%s",', travelProxy);
        console.log('  "treasury": "%s",', treasuryProxy);
        console.log('  "discountBillERC5095": "%s",', billProxy);
        console.log('  "billTokenFactory": "%s",', address(billTokenFactory));
        console.log('  "treasuryYieldManager": "%s",', address(yieldManager));
        console.log('  "mockAavePool": "%s",', address(aavePool));
        console.log('  "aaveAdapter": "%s",', address(aaveAdapter));
        console.log('  "admin": "%s"', admin);
        console.log("}");
    }
}
