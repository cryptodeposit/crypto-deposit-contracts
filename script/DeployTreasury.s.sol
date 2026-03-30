// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {TreasuryYieldManager} from "../src/TreasuryYieldManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployTreasury
 * @notice Deploys Treasury + TreasuryYieldManager and links to existing DiscountBill
 * @dev For adding Treasury to an existing Phase 1 deployment (DiscountBill already live).
 *      Also deploys the in-house TreasuryYieldManager backed by the real estate facility.
 *
 * Required env vars:
 *   DEPLOYER_KEY          — private key (must be DEFAULT_ADMIN_ROLE on DiscountBill)
 *   DISCOUNT_BILL         — address of the existing DiscountBill proxy
 *   STABLE_TOKEN          — address of the stable token (e.g. USDC)
 *
 * Optional env vars:
 *   RESERVE_RATIO_BPS     — treasury reserve ratio in bps (default 2000 = 20%)
 *   YIELD_APY_BPS         — TreasuryYieldManager APY in bps (default 450 = 4.5%)
 *   FACILITY_EQUITY       — facility commitment in token units (default 10M * 1e6)
 *   COLLATERAL_VAULT      — if set, grants COLLATERAL_MANAGER_ROLE
 *   BORROWING_ENGINE      — if set, grants LENDING_MANAGER_ROLE
 *
 * Usage:
 *   DEPLOYER_KEY=0x... DISCOUNT_BILL=0x... STABLE_TOKEN=0x... \
 *   forge script script/DeployTreasury.s.sol:DeployTreasury \
 *     --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_KEY
 */
contract DeployTreasury is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address admin = vm.addr(deployerKey);

        address discountBillAddr = vm.envAddress("DISCOUNT_BILL");
        address stableToken = vm.envAddress("STABLE_TOKEN");
        uint256 reserveRatioBps = vm.envOr("RESERVE_RATIO_BPS", uint256(2000));
        uint256 yieldApyBps = vm.envOr("YIELD_APY_BPS", uint256(450));
        uint256 facilityEquity = vm.envOr("FACILITY_EQUITY", uint256(10_000_000 * 1e6));
        address collateralVault = vm.envOr("COLLATERAL_VAULT", address(0));
        address borrowingEngine = vm.envOr("BORROWING_ENGINE", address(0));

        console.log("");
        console.log("=== Deploy Treasury + In-House Yield Manager ===");
        console.log("");
        console.log("Admin:", admin);
        console.log("DiscountBill:", discountBillAddr);
        console.log("StableToken:", stableToken);
        console.log("Reserve ratio:", reserveRatioBps, "bps");
        console.log("Yield APY:", yieldApyBps, "bps");
        console.log("Facility equity:", facilityEquity / 1e6, "USD");
        console.log("");

        vm.startBroadcast(deployerKey);

        // ── 1. Deploy TreasuryUpgradeable (implementation + UUPS proxy) ─────────
        address treasuryImpl = address(new TreasuryUpgradeable());
        address treasuryProxy = address(new ERC1967Proxy(
            treasuryImpl,
            abi.encodeCall(TreasuryUpgradeable.initialize, (admin))
        ));
        TreasuryUpgradeable treasury = TreasuryUpgradeable(treasuryProxy);

        // ── 2. Deploy TreasuryYieldManager (in-house facility-backed yield) ─────
        TreasuryYieldManager yieldManager = new TreasuryYieldManager(admin);

        // ── 3. Configure yield manager ──────────────────────────────────────────
        yieldManager.addSupportedToken(stableToken, yieldApyBps, facilityEquity);

        // ── 4. Grant roles on Treasury ──────────────────────────────────────────
        treasury.grantRole(treasury.DEPOSIT_MANAGER_ROLE(), discountBillAddr);
        if (collateralVault != address(0)) {
            treasury.grantRole(treasury.COLLATERAL_MANAGER_ROLE(), collateralVault);
        }
        if (borrowingEngine != address(0)) {
            treasury.grantRole(treasury.LENDING_MANAGER_ROLE(), borrowingEngine);
        }

        // ── 5. Set reserve ratio for stable token ───────────────────────────────
        treasury.setReserveRatio(stableToken, reserveRatioBps);

        // ── 6. Connect DiscountBill → Treasury ──────────────────────────────────
        (bool ok,) = discountBillAddr.call(
            abi.encodeWithSignature("setTreasury(address)", treasuryProxy)
        );
        require(ok, "setTreasury on DiscountBill failed");

        // ── 7. Grant OPERATOR_ROLE on yield manager to DiscountBill ─────────────
        yieldManager.grantRole(yieldManager.OPERATOR_ROLE(), discountBillAddr);

        vm.stopBroadcast();

        // ── Output ──────────────────────────────────────────────────────────────
        console.log("");
        console.log("=== TREASURY DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Treasury proxy:", treasuryProxy);
        console.log("Treasury impl:", treasuryImpl);
        console.log("TreasuryYieldManager:", address(yieldManager));
        console.log("");
        console.log("--- Role Matrix ---");
        console.log("  DiscountBill -> Treasury: DEPOSIT_MANAGER_ROLE");
        console.log("  DiscountBill -> YieldManager: OPERATOR_ROLE");
        console.log("  DiscountBill.treasury =", treasuryProxy);
        if (collateralVault != address(0)) {
            console.log("  CollateralVault -> Treasury: COLLATERAL_MANAGER_ROLE");
        }
        if (borrowingEngine != address(0)) {
            console.log("  BorrowingEngine -> Treasury: LENDING_MANAGER_ROLE");
        }
        console.log("");

        // JSON for scripts
        console.log("--- JSON ---");
        console.log("{");
        console.log('  "treasury": "%s",', treasuryProxy);
        console.log('  "treasuryImpl": "%s",', treasuryImpl);
        console.log('  "treasuryYieldManager": "%s"', address(yieldManager));
        console.log("}");
    }
}
