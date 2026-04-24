// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StableTokenUpgradeable} from "../src/StableTokenUpgradeable.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillCore} from "../src/DiscountBillCore.sol";
import {DiscountBillLifecycle} from "../src/DiscountBillLifecycle.sol";
import {DiscountBillCampaigns} from "../src/DiscountBillCampaigns.sol";
import {BillTokenFactory} from "../src/BillTokenFactory.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {TreasuryYieldManager} from "../src/TreasuryYieldManager.sol";
import {ChainalysisComplianceAdapter} from "../src/adapters/ChainalysisComplianceAdapter.sol";
import {CompositeComplianceAdapter} from "../src/adapters/CompositeComplianceAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployAll
 * @notice Deploys all crypto-deposit contracts (3-contract DiscountBill split)
 * @dev PRODUCTION: always use --ledger. Never use --private-key for mainnet/L2.
 *
 * Usage (production — Ledger):
 *   ADDRESS0=0xb109... forge script script/DeployAll.s.sol:DeployAll \
 *     --rpc-url $RPC --broadcast --ledger --sender 0xb109... --verify --etherscan-api-key $KEY
 *
 * Usage (testnet only):
 *   ADDRESS0=0x940b... forge script script/DeployAll.s.sol:DeployAll \
 *     --rpc-url $RPC --broadcast --private-key $KEY
 */
contract DeployAll is Script {
    // Chainalysis free sanctions oracle (mainnet)
    address constant CHAINALYSIS_ORACLE = 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;

    // Travel rule threshold: $1,000,000 USD (with 6 decimals)
    // Transfers >= this amount require pre-clearance from compliance
    uint256 constant TRAVEL_RULE_THRESHOLD = 1_000_000 * 1e6;
    // Travel rule TTL: 24 hours
    uint64 constant TRAVEL_RULE_TTL = 24 hours;
    // Default APY for TreasuryYieldManager: 4.5%
    uint256 constant DEFAULT_APY_BPS = 450;
    // Facility commitment amount: $10M (equity - backed by off-chain credit facility)
    // This represents the capital buffer that backs depositor liabilities
    uint256 constant FACILITY_EQUITY = 10_000_000 * 1e6;

    struct Deployment {
        address stableToken;
        address stableTokenImpl;
        address compliance;
        address complianceImpl;
        address travelRule;
        address travelRuleImpl;
        address discountBill;
        address discountBillImpl;
        address billTokenFactory;
        address treasury;
        address treasuryImpl;
        address treasuryYieldManager;
    }

    function run() external returns (Deployment memory) {
        // PRODUCTION: always use --ledger. Never pass a private key for mainnet.
        // The signer comes from CLI (--ledger --sender or --private-key for testnets only).
        address admin = vm.envAddress("ADDRESS0");
        address issuer = admin;

        vm.startBroadcast();

        // 1. Deploy StableToken (Mock USD)
        address stableImpl = address(new StableTokenUpgradeable());
        address stableProxy = address(
            new ERC1967Proxy(
                stableImpl,
                abi.encodeCall(
                    StableTokenUpgradeable.initialize,
                    ("Mock USD", "mUSD", 6, 10_000_000 * 1e6, admin) // 10M initial supply
                )
            )
        );
        StableTokenUpgradeable stableToken = StableTokenUpgradeable(stableProxy);

        // 2. Deploy ComplianceRegistry
        address complianceImpl = address(new ComplianceRegistryUpgradeable());
        address complianceProxy = address(
            new ERC1967Proxy(
                complianceImpl,
                abi.encodeCall(ComplianceRegistryUpgradeable.initialize, (admin))
            )
        );
        ComplianceRegistryUpgradeable compliance = ComplianceRegistryUpgradeable(complianceProxy);

        // --- Alternative: Chainalysis compliance adapter ---
        // To use the Chainalysis free oracle instead of (or alongside) the internal blocklist:
        //
        // Option A: Chainalysis only
        //   ChainalysisComplianceAdapter chainalysisAdapter =
        //       new ChainalysisComplianceAdapter(CHAINALYSIS_ORACLE, admin);
        //   // Then pass address(chainalysisAdapter) wherever compliance is used.
        //
        // Option B: Composite (Chainalysis + internal blocklist)
        //   CompositeComplianceAdapter compositeCompliance = new CompositeComplianceAdapter(admin);
        //   compositeCompliance.addRegistry(complianceProxy);           // internal blocklist
        //   compositeCompliance.addRegistry(address(chainalysisAdapter)); // Chainalysis oracle
        //   // Then pass address(compositeCompliance) wherever compliance is used.
        //
        // To swap later: call setComplianceRegistry() on each consumer contract.

        // 3. Deploy TravelRuleRegistry
        address travelImpl = address(new TravelRuleRegistryUpgradeable());
        address travelProxy = address(
            new ERC1967Proxy(
                travelImpl,
                abi.encodeCall(TravelRuleRegistryUpgradeable.initialize, (admin))
            )
        );
        TravelRuleRegistryUpgradeable travel = TravelRuleRegistryUpgradeable(travelProxy);

        // 4. Deploy DiscountBillERC5095 (main deposit contract)
        DiscountBillLifecycle lifecycle = new DiscountBillLifecycle();
        DiscountBillCampaigns campaigns = new DiscountBillCampaigns();
        address billImpl = address(new DiscountBillCore());
        address billProxy = address(
            new ERC1967Proxy(
                billImpl,
                abi.encodeCall(DiscountBillCore.initialize, (admin, issuer, compliance, travel))
            )
        );
        DiscountBillCore discountBill = DiscountBillCore(payable(billProxy));
        discountBill.setLifecycleImpl(address(lifecycle));
        discountBill.setCampaignsImpl(address(campaigns));

        // 4b. Deploy BillTokenFactory and connect to bill
        BillTokenFactory billTokenFactory = new BillTokenFactory();
        discountBill.setBillTokenFactory(address(billTokenFactory));

        // 5. Deploy TreasuryUpgradeable (central custody)
        address treasuryImpl = address(new TreasuryUpgradeable());
        address treasuryProxy = address(
            new ERC1967Proxy(
                treasuryImpl,
                abi.encodeCall(TreasuryUpgradeable.initialize, (admin))
            )
        );
        TreasuryUpgradeable treasuryContract = TreasuryUpgradeable(treasuryProxy);

        // 6. Configure TravelRule policy for stable token
        travel.setPolicy(stableProxy, TRAVEL_RULE_THRESHOLD, false, TRAVEL_RULE_TTL);

        // 7. Grant ORDERING_ROLE to DiscountBill on TravelRule
        travel.grantRole(travel.ORDERING_ROLE(), billProxy);

        // 8. Grant OPERATOR_ROLE to admin on DiscountBill
        discountBill.grantRole(discountBill.OPERATOR_ROLE(), admin);

        // 9. Grant DEPOSIT_MANAGER_ROLE to DiscountBill on Treasury
        // This is CRITICAL — DiscountBill needs this to call recordDeposit() and withdrawForRedemption()
        treasuryContract.grantRole(treasuryContract.DEPOSIT_MANAGER_ROLE(), billProxy);

        // 10. Connect DiscountBill to Treasury (enables treasury path for token flow)
        discountBill.setTreasury(treasuryProxy);

        // 11. Set reserve ratio for mUSD on Treasury (20%)
        treasuryContract.setReserveRatio(stableProxy, 2000);

        // 12. Fund Treasury with initial mUSD for liquidity
        uint256 treasuryFunding = 1_000_000 * 1e6; // $1M
        stableToken.transfer(treasuryProxy, treasuryFunding);

        // 13. Approve DiscountBill to spend stable tokens from issuer (legacy path fallback)
        stableToken.approve(billProxy, type(uint256).max);

        // 14. Deploy TreasuryYieldManager (facility-backed yield)
        TreasuryYieldManager treasuryYieldManager = new TreasuryYieldManager(admin);

        // 15. Configure TreasuryYieldManager with mUSD
        treasuryYieldManager.addSupportedToken(stableProxy, DEFAULT_APY_BPS, FACILITY_EQUITY);

        // 16. Grant OPERATOR_ROLE on TreasuryYieldManager to DiscountBill
        treasuryYieldManager.grantRole(treasuryYieldManager.OPERATOR_ROLE(), billProxy);

        vm.stopBroadcast();

        // Output addresses
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("--- Proxies (use these) ---");
        console.log("StableToken proxy:", stableProxy);
        console.log("ComplianceRegistry proxy:", complianceProxy);
        console.log("TravelRuleRegistry proxy:", travelProxy);
        console.log("DiscountBillERC5095 proxy:", billProxy);
        console.log("Treasury proxy:", treasuryProxy);
        console.log("BillTokenFactory:", address(billTokenFactory));
        console.log("TreasuryYieldManager:", address(treasuryYieldManager));
        console.log("");
        console.log("--- Implementations ---");
        console.log("StableToken impl:", stableImpl);
        console.log("ComplianceRegistry impl:", complianceImpl);
        console.log("TravelRuleRegistry impl:", travelImpl);
        console.log("DiscountBillERC5095 impl:", billImpl);
        console.log("Treasury impl:", treasuryImpl);
        console.log("");
        console.log("--- Configuration ---");
        console.log("Admin/Issuer:", admin);
        console.log("Travel Rule Threshold:", TRAVEL_RULE_THRESHOLD / 1e6, "USD");
        console.log("Travel Rule TTL:", TRAVEL_RULE_TTL / 3600, "hours");
        console.log("Initial mUSD Supply:", stableToken.totalSupply() / 1e6);
        console.log("Treasury Funding:", treasuryFunding / 1e6, "USD");
        console.log("Treasury APY:", DEFAULT_APY_BPS, "bps");
        console.log("Facility Equity:", FACILITY_EQUITY / 1e6, "USD");
        console.log("");
        console.log("--- Role Matrix ---");
        console.log("DiscountBillERC5095 -> Treasury: DEPOSIT_MANAGER_ROLE");
        console.log("DiscountBillERC5095 -> TravelRule: ORDERING_ROLE");
        console.log("DiscountBillERC5095 -> TreasuryYieldManager: OPERATOR_ROLE");
        console.log("");

        // Output JSON for scripts
        console.log("--- JSON (for scripts) ---");
        console.log("{");
        console.log('  "stableToken": "%s",', stableProxy);
        console.log('  "compliance": "%s",', complianceProxy);
        console.log('  "travelRule": "%s",', travelProxy);
        console.log('  "discountBill": "%s",', billProxy);
        console.log('  "billTokenFactory": "%s",', address(billTokenFactory));
        console.log('  "treasury": "%s",', treasuryProxy);
        console.log('  "treasuryYieldManager": "%s",', address(treasuryYieldManager));
        console.log('  "admin": "%s"', admin);
        console.log("}");

        return Deployment({
            stableToken: stableProxy,
            stableTokenImpl: stableImpl,
            compliance: complianceProxy,
            complianceImpl: complianceImpl,
            travelRule: travelProxy,
            travelRuleImpl: travelImpl,
            discountBill: billProxy,
            discountBillImpl: billImpl,
            billTokenFactory: address(billTokenFactory),
            treasury: treasuryProxy,
            treasuryImpl: treasuryImpl,
            treasuryYieldManager: address(treasuryYieldManager)
        });
    }
}
