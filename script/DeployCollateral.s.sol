// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {HaircutRegistryUpgradeable} from "../src/HaircutRegistryUpgradeable.sol";
import {OperatorPriceOracleUpgradeable} from "../src/OperatorPriceOracleUpgradeable.sol";
import {CollateralVaultUpgradeable} from "../src/CollateralVaultUpgradeable.sol";
import {BorrowingEngineUpgradeable} from "../src/BorrowingEngineUpgradeable.sol";
import {LiquidationManagerUpgradeable} from "../src/LiquidationManagerUpgradeable.sol";
import {IHaircutRegistry} from "../src/interfaces/IHaircutRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployCollateral
 * @notice Deploys the collateral/borrowing system contracts to local chains
 * @dev Requires the core deposit contracts to already be deployed.
 *      Reads existing contract addresses from environment variables.
 *
 * Usage:
 *   PRIVATE_KEY0=... ADDRESS0=... \
 *   STABLE_TOKEN=0x... COMPLIANCE_REGISTRY=0x... TRAVEL_RULE_REGISTRY=0x... DISCOUNT_BILL=0x... \
 *   forge script script/DeployCollateral.s.sol:DeployCollateral --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY0
 */
contract DeployCollateral is Script {
    uint256 constant PRICE_STALENESS = 300;
    uint256 constant INITIAL_BORROW_LIQUIDITY = 1_000_000 * 1e6;
    uint256 constant DEFAULT_BORROW_RATE_BPS = 500;

    /// @dev Groups env-sourced addresses to avoid stack-too-deep
    struct ExistingAddrs {
        address admin;
        address stableToken;
        address complianceRegistry;
        address travelRuleRegistry;
        address discountBill;
        address meurToken;
        address methToken;
        address mmaticToken;
    }

    /// @dev Groups proxy addresses for the newly deployed contracts
    struct Proxies {
        address haircutRegistry;
        address priceOracle;
        address collateralVault;
        address borrowingEngine;
        address liquidationManager;
    }

    /// @dev Groups implementation addresses
    struct Impls {
        address haircutRegistry;
        address priceOracle;
        address collateralVault;
        address borrowingEngine;
        address liquidationManager;
    }

    function run() external {
        ExistingAddrs memory existing = ExistingAddrs({
            admin: vm.envAddress("ADDRESS0"),
            stableToken: vm.envAddress("STABLE_TOKEN"),
            complianceRegistry: vm.envAddress("COMPLIANCE_REGISTRY"),
            travelRuleRegistry: vm.envAddress("TRAVEL_RULE_REGISTRY"),
            discountBill: vm.envAddress("DISCOUNT_BILL"),
            meurToken: vm.envOr("MEUR_TOKEN", address(0)),
            methToken: vm.envOr("METH_TOKEN", address(0)),
            mmaticToken: vm.envOr("MMATIC_TOKEN", address(0))
        });

        // startBroadcast() without args — signer comes from CLI (--private-key or --ledger)
        vm.startBroadcast();

        (Proxies memory proxies, Impls memory impls) = _deployAll(existing);
        _configure(existing, proxies);

        vm.stopBroadcast();

        _logOutput(existing, proxies, impls);
    }

    function _deployAll(ExistingAddrs memory e) internal returns (Proxies memory p, Impls memory i) {
        // 1. HaircutRegistry
        i.haircutRegistry = address(new HaircutRegistryUpgradeable());
        p.haircutRegistry = address(new ERC1967Proxy(
            i.haircutRegistry,
            abi.encodeCall(HaircutRegistryUpgradeable.initialize, (e.admin))
        ));

        // 2. PriceOracle (admin is also trusted signer for local dev)
        i.priceOracle = address(new OperatorPriceOracleUpgradeable());
        p.priceOracle = address(new ERC1967Proxy(
            i.priceOracle,
            abi.encodeCall(OperatorPriceOracleUpgradeable.initialize, (e.admin, e.admin, PRICE_STALENESS))
        ));

        // 3. CollateralVault
        i.collateralVault = address(new CollateralVaultUpgradeable());
        p.collateralVault = address(new ERC1967Proxy(
            i.collateralVault,
            abi.encodeCall(CollateralVaultUpgradeable.initialize,
                (e.admin, e.complianceRegistry, p.haircutRegistry, p.priceOracle, e.discountBill))
        ));

        // 4. BorrowingEngine
        i.borrowingEngine = address(new BorrowingEngineUpgradeable());
        p.borrowingEngine = address(new ERC1967Proxy(
            i.borrowingEngine,
            abi.encodeCall(BorrowingEngineUpgradeable.initialize,
                (e.admin, p.collateralVault, e.complianceRegistry, e.travelRuleRegistry, p.priceOracle))
        ));

        // 5. LiquidationManager
        i.liquidationManager = address(new LiquidationManagerUpgradeable());
        p.liquidationManager = address(new ERC1967Proxy(
            i.liquidationManager,
            abi.encodeCall(LiquidationManagerUpgradeable.initialize,
                (e.admin, p.borrowingEngine, p.collateralVault, p.priceOracle))
        ));
    }

    function _configure(ExistingAddrs memory e, Proxies memory p) internal {
        CollateralVaultUpgradeable vault = CollateralVaultUpgradeable(p.collateralVault);
        BorrowingEngineUpgradeable engine = BorrowingEngineUpgradeable(p.borrowingEngine);
        HaircutRegistryUpgradeable haircuts = HaircutRegistryUpgradeable(p.haircutRegistry);
        OperatorPriceOracleUpgradeable oracle = OperatorPriceOracleUpgradeable(p.priceOracle);

        // Link CollateralVault ↔ BorrowingEngine
        vault.setBorrowingEngine(p.borrowingEngine);

        // Grant LIQUIDATOR_ROLE to LiquidationManager
        vault.grantRole(vault.LIQUIDATOR_ROLE(), p.liquidationManager);
        engine.grantRole(engine.LIQUIDATOR_ROLE(), p.liquidationManager);

        // Set haircuts + prices for mUSD (stablecoin)
        _setStablecoinHaircut(haircuts, e.stableToken);
        oracle.setPrice(e.stableToken, 100_000_000); // $1.00
        engine.addSupportedToken(e.stableToken, DEFAULT_BORROW_RATE_BPS);

        // Optional tokens
        if (e.meurToken != address(0)) {
            _setStablecoinHaircut(haircuts, e.meurToken);
            oracle.setPrice(e.meurToken, 108_000_000); // $1.08
            engine.addSupportedToken(e.meurToken, DEFAULT_BORROW_RATE_BPS);
        }
        if (e.methToken != address(0)) {
            _setVolatileHaircut(haircuts, e.methToken, 2500, 7500, 8250);
            oracle.setPrice(e.methToken, 250_000_000_000); // $2,500
            engine.addSupportedToken(e.methToken, 800);
        }
        if (e.mmaticToken != address(0)) {
            _setVolatileHaircut(haircuts, e.mmaticToken, 3000, 7000, 7500);
            oracle.setPrice(e.mmaticToken, 80_000_000); // $0.80
            engine.addSupportedToken(e.mmaticToken, 1000);
        }

        // Fund BorrowingEngine with borrow liquidity
        IERC20(e.stableToken).approve(p.borrowingEngine, INITIAL_BORROW_LIQUIDITY);
        engine.addLiquidity(e.stableToken, INITIAL_BORROW_LIQUIDITY);
    }

    function _setStablecoinHaircut(HaircutRegistryUpgradeable registry, address token) internal {
        registry.setHaircut(token, IHaircutRegistry.HaircutConfig({
            collateralHaircutBps: 500,
            borrowHaircutBps: 0,
            maxLtvBps: 9000,
            liquidationThresholdBps: 9250,
            enabled: true
        }));
    }

    function _setVolatileHaircut(
        HaircutRegistryUpgradeable registry,
        address token,
        uint256 haircutBps,
        uint256 maxLtvBps,
        uint256 liqThresholdBps
    ) internal {
        registry.setHaircut(token, IHaircutRegistry.HaircutConfig({
            collateralHaircutBps: haircutBps,
            borrowHaircutBps: 500,
            maxLtvBps: maxLtvBps,
            liquidationThresholdBps: liqThresholdBps,
            enabled: true
        }));
    }

    function _logOutput(ExistingAddrs memory e, Proxies memory p, Impls memory i) internal pure {
        console.log("");
        console.log("=== COLLATERAL SYSTEM DEPLOYED ===");
        console.log("");
        console.log("--- Proxies (use these) ---");
        console.log("HaircutRegistry proxy:", p.haircutRegistry);
        console.log("PriceOracle proxy:", p.priceOracle);
        console.log("CollateralVault proxy:", p.collateralVault);
        console.log("BorrowingEngine proxy:", p.borrowingEngine);
        console.log("LiquidationManager proxy:", p.liquidationManager);
        console.log("");
        console.log("--- Implementations ---");
        console.log("HaircutRegistry impl:", i.haircutRegistry);
        console.log("PriceOracle impl:", i.priceOracle);
        console.log("CollateralVault impl:", i.collateralVault);
        console.log("BorrowingEngine impl:", i.borrowingEngine);
        console.log("LiquidationManager impl:", i.liquidationManager);
        console.log("");
        console.log("--- Configuration ---");
        console.log("Admin:", e.admin);
        console.log("Price Staleness:", PRICE_STALENESS, "seconds");
        console.log("mUSD Borrow Rate:", DEFAULT_BORROW_RATE_BPS, "bps");
        console.log("Borrow Liquidity:", INITIAL_BORROW_LIQUIDITY / 1e6, "mUSD");
        console.log("");
        console.log("--- Existing Contracts Used ---");
        console.log("StableToken:", e.stableToken);
        console.log("ComplianceRegistry:", e.complianceRegistry);
        console.log("TravelRuleRegistry:", e.travelRuleRegistry);
        console.log("DiscountBill:", e.discountBill);
        console.log("");
    }
}
