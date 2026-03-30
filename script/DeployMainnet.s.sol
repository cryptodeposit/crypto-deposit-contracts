// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {BillTokenFactory} from "../src/BillTokenFactory.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {TreasuryYieldManager} from "../src/TreasuryYieldManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployMainnet
 * @notice Full-stack production deployment — real tokens, Ledger-compatible
 * @dev No mock contracts. Reads token addresses from env vars (set by deploy_mainnet.sh
 *      from chain config TOML). Supports Ledger hardware wallet signing via --ledger flag.
 *
 *      Deploys: ComplianceRegistry, TravelRuleRegistry, Treasury,
 *               DiscountBillERC5095, BillTokenFactory, TreasuryYieldManager
 *
 * Usage (Ledger — production):
 *   DEPLOYER=0x... USDC=0x... USDT=0x... forge script script/DeployMainnet.s.sol:DeployMainnet \
 *     --rpc-url $RPC_URL --broadcast --verify --etherscan-api-key $API_KEY \
 *     --ledger --hd-paths "m/44'/60'/0'/0/0"
 *
 * Usage (private key — testnet dry run):
 *   DEPLOYER_KEY=0x... USDC=0x... USDT=0x... forge script script/DeployMainnet.s.sol:DeployMainnet \
 *     --rpc-url $RPC_URL --broadcast --verify --etherscan-api-key $API_KEY
 */
contract DeployMainnet is Script {
    struct DeploymentAddresses {
        address compliance;
        address complianceImpl;
        address travelRule;
        address travelRuleImpl;
        address treasury;
        address treasuryImpl;
        address discountBill;
        address discountBillImpl;
        address billTokenFactory;
        address yieldManager;
    }

    function run() external returns (DeploymentAddresses memory deployed) {
        // --- Read configuration from env ---
        address admin = _resolveDeployer();

        address usdc = vm.envAddress("USDC");
        address usdt = vm.envOr("USDT", address(0));

        uint256 travelRuleThreshold = vm.envOr("TRAVEL_RULE_THRESHOLD", uint256(1_000_000 * 1e6));
        uint64 travelRuleTtl = uint64(vm.envOr("TRAVEL_RULE_TTL", uint256(24 hours)));
        uint256 depositCap = vm.envOr("DEPOSIT_CAP", uint256(1_000_000 * 1e6));
        uint256 reserveRatioBps = vm.envOr("RESERVE_RATIO_BPS", uint256(800)); // 8% Basel III
        uint256 defaultApyBps = vm.envOr("DEFAULT_APY_BPS", uint256(450));
        uint256 facilityEquity = vm.envOr("FACILITY_EQUITY", uint256(10_000_000 * 1e6));

        // --- Start broadcast ---
        _startBroadcast();

        // ====================================================================
        // 1. ComplianceRegistry
        // ====================================================================
        address complianceImpl = address(new ComplianceRegistryUpgradeable());
        address complianceProxy = address(
            new ERC1967Proxy(
                complianceImpl,
                abi.encodeCall(ComplianceRegistryUpgradeable.initialize, (admin))
            )
        );

        // ====================================================================
        // 2. TravelRuleRegistry
        // ====================================================================
        address travelImpl = address(new TravelRuleRegistryUpgradeable());
        address travelProxy = address(
            new ERC1967Proxy(
                travelImpl,
                abi.encodeCall(TravelRuleRegistryUpgradeable.initialize, (admin))
            )
        );
        TravelRuleRegistryUpgradeable travel = TravelRuleRegistryUpgradeable(travelProxy);

        // ====================================================================
        // 3. Treasury
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
        // 4. DiscountBillERC5095
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
        // 5. BillTokenFactory
        // ====================================================================
        BillTokenFactory billTokenFactory = new BillTokenFactory();
        bill.setBillTokenFactory(address(billTokenFactory));

        // ====================================================================
        // 6. TreasuryYieldManager
        // ====================================================================
        TreasuryYieldManager yieldManager = new TreasuryYieldManager(admin);
        yieldManager.addSupportedToken(usdc, defaultApyBps, facilityEquity);
        if (usdt != address(0)) {
            yieldManager.addSupportedToken(usdt, defaultApyBps, facilityEquity);
        }

        // ====================================================================
        // Wiring — Role Grants
        // ====================================================================

        // Travel rule policies per token
        travel.setPolicy(usdc, travelRuleThreshold, false, travelRuleTtl);
        if (usdt != address(0)) {
            travel.setPolicy(usdt, travelRuleThreshold, false, travelRuleTtl);
        }

        // ORDERING_ROLE on TravelRule for bill + admin
        bytes32 orderingRole = travel.ORDERING_ROLE();
        travel.grantRole(orderingRole, billProxy);
        travel.grantRole(orderingRole, admin);

        // OPERATOR_ROLE on bill for admin
        bill.grantRole(bill.OPERATOR_ROLE(), admin);

        // DEPOSIT_MANAGER_ROLE on Treasury for bill
        treasury.grantRole(treasury.DEPOSIT_MANAGER_ROLE(), billProxy);

        // OPERATOR_ROLE on Treasury for admin
        treasury.grantRole(treasury.OPERATOR_ROLE(), admin);

        // Connect bill to Treasury
        bill.setTreasury(treasuryProxy);

        // YieldManager: OPERATOR_ROLE for bill
        yieldManager.grantRole(yieldManager.OPERATOR_ROLE(), billProxy);

        // Reserve ratios per token
        treasury.setReserveRatio(usdc, reserveRatioBps);
        if (usdt != address(0)) {
            treasury.setReserveRatio(usdt, reserveRatioBps);
        }

        // ====================================================================
        // Deposit Caps
        // ====================================================================
        bill.setMaxDepositAmount(usdc, depositCap);
        if (usdt != address(0)) {
            bill.setMaxDepositAmount(usdt, depositCap);
        }

        vm.stopBroadcast();

        // ====================================================================
        // Output
        // ====================================================================
        deployed = DeploymentAddresses({
            compliance: complianceProxy,
            complianceImpl: complianceImpl,
            travelRule: travelProxy,
            travelRuleImpl: travelImpl,
            treasury: treasuryProxy,
            treasuryImpl: treasuryImpl,
            discountBill: billProxy,
            discountBillImpl: billImpl,
            billTokenFactory: address(billTokenFactory),
            yieldManager: address(yieldManager)
        });

        _printDeployment(deployed, admin, usdc, usdt, depositCap, reserveRatioBps, travelRuleThreshold);
    }

    // --- Internal helpers ---

    function _resolveDeployer() internal view returns (address) {
        // Try DEPLOYER (address) first — used with --ledger
        // Fall back to DEPLOYER_KEY (private key) — used for testing
        try vm.envAddress("DEPLOYER") returns (address deployer) {
            return deployer;
        } catch {
            uint256 key = vm.envUint("DEPLOYER_KEY");
            return vm.addr(key);
        }
    }

    function _startBroadcast() internal {
        try vm.envAddress("DEPLOYER") returns (address deployer) {
            vm.startBroadcast(deployer);
        } catch {
            uint256 key = vm.envUint("DEPLOYER_KEY");
            vm.startBroadcast(key);
        }
    }

    function _printDeployment(
        DeploymentAddresses memory d,
        address admin,
        address usdc,
        address usdt,
        uint256 depositCap,
        uint256 reserveRatioBps,
        uint256 travelRuleThreshold
    ) internal view {
        console.log("");
        console.log("=== MAINNET DEPLOYMENT ===");
        console.log("");
        console.log("Chain ID:", block.chainid);
        console.log("");
        console.log("--- Tokens ---");
        console.log("USDC:", usdc);
        console.log("USDT:", usdt);
        console.log("");
        console.log("--- Proxies ---");
        console.log("ComplianceRegistry:", d.compliance);
        console.log("TravelRuleRegistry:", d.travelRule);
        console.log("Treasury:", d.treasury);
        console.log("DiscountBillERC5095:", d.discountBill);
        console.log("BillTokenFactory:", d.billTokenFactory);
        console.log("TreasuryYieldManager:", d.yieldManager);
        console.log("");
        console.log("--- Implementations ---");
        console.log("ComplianceRegistry impl:", d.complianceImpl);
        console.log("TravelRuleRegistry impl:", d.travelRuleImpl);
        console.log("Treasury impl:", d.treasuryImpl);
        console.log("DiscountBillERC5095 impl:", d.discountBillImpl);
        console.log("");
        console.log("--- Config ---");
        console.log("Admin:", admin);
        console.log("Deposit Cap (per token):", depositCap / 1e6, "USD");
        console.log("Reserve Ratio:", reserveRatioBps / 100, "%");
        console.log("Travel Rule Threshold:", travelRuleThreshold / 1e6, "USD");
        console.log("");
        console.log("--- POST-DEPLOY ACTIONS ---");
        console.log("1. Verify all contracts on block explorer");
        console.log("2. Fund Treasury with initial reserves");
        console.log("3. Admin approve bill to spend USDC/USDT (legacy path fallback)");
        console.log("4. Run TransferToSafe.s.sol to transfer admin to Gnosis Safe");
        console.log("");

        // JSON output for tooling
        console.log("--- JSON ---");
        console.log("{");
        console.log('  "chainId": %s,', vm.toString(block.chainid));
        console.log('  "usdc": "%s",', usdc);
        console.log('  "usdt": "%s",', usdt);
        console.log('  "compliance": "%s",', d.compliance);
        console.log('  "travelRule": "%s",', d.travelRule);
        console.log('  "treasury": "%s",', d.treasury);
        console.log('  "discountBillERC5095": "%s",', d.discountBill);
        console.log('  "billTokenFactory": "%s",', d.billTokenFactory);
        console.log('  "yieldManager": "%s",', d.yieldManager);
        console.log('  "admin": "%s"', admin);
        console.log("}");
    }
}
