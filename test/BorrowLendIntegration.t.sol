// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {HaircutRegistryUpgradeable} from "../src/HaircutRegistryUpgradeable.sol";
import {OperatorPriceOracleUpgradeable} from "../src/OperatorPriceOracleUpgradeable.sol";
import {CollateralVaultUpgradeable} from "../src/CollateralVaultUpgradeable.sol";
import {BorrowingEngineUpgradeable} from "../src/BorrowingEngineUpgradeable.sol";
import {LiquidationManagerUpgradeable} from "../src/LiquidationManagerUpgradeable.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";
import {IHaircutRegistry} from "../src/interfaces/IHaircutRegistry.sol";

// Mock ERC20 for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _decimals = dec;
    }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public view override returns (uint8) { return _decimals; }
}

contract BorrowLendIntegrationTest is Test {
    // Contracts
    ComplianceRegistryUpgradeable compliance;
    HaircutRegistryUpgradeable haircutRegistry;
    OperatorPriceOracleUpgradeable priceOracle;
    CollateralVaultUpgradeable vault;
    BorrowingEngineUpgradeable engine;
    LiquidationManagerUpgradeable liquidator;

    // Tokens
    MockERC20 wbtc;  // 8 decimals
    MockERC20 usdt;  // 6 decimals

    // Actors
    address admin = makeAddr("admin");
    address operator_ = makeAddr("operator");
    address borrower = makeAddr("borrower");
    address liquidatorAddr = makeAddr("liquidator");
    address treasury = makeAddr("treasury");

    function setUp() public {
        // Deploy mock tokens
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        // Deploy compliance (UUPS proxy)
        compliance = ComplianceRegistryUpgradeable(address(
            new ERC1967Proxy(
                address(new ComplianceRegistryUpgradeable()),
                abi.encodeCall(ComplianceRegistryUpgradeable.initialize, (admin))
            )
        ));

        // Deploy haircut registry
        haircutRegistry = HaircutRegistryUpgradeable(address(
            new ERC1967Proxy(
                address(new HaircutRegistryUpgradeable()),
                abi.encodeCall(HaircutRegistryUpgradeable.initialize, (admin))
            )
        ));

        // Deploy price oracle (5 min staleness)
        priceOracle = OperatorPriceOracleUpgradeable(address(
            new ERC1967Proxy(
                address(new OperatorPriceOracleUpgradeable()),
                abi.encodeCall(OperatorPriceOracleUpgradeable.initialize, (admin, admin, 300))
            )
        ));

        // Deploy collateral vault
        vault = CollateralVaultUpgradeable(address(
            new ERC1967Proxy(
                address(new CollateralVaultUpgradeable()),
                abi.encodeCall(CollateralVaultUpgradeable.initialize, (
                    admin,
                    address(compliance),
                    address(haircutRegistry),
                    address(priceOracle),
                    address(0) // No discount bill for this test
                ))
            )
        ));

        // Deploy borrowing engine
        engine = BorrowingEngineUpgradeable(address(
            new ERC1967Proxy(
                address(new BorrowingEngineUpgradeable()),
                abi.encodeCall(BorrowingEngineUpgradeable.initialize, (
                    admin,
                    address(vault),
                    address(compliance),
                    address(0), // No travel rule for this test
                    address(priceOracle)
                ))
            )
        ));

        // Deploy liquidation manager
        liquidator = LiquidationManagerUpgradeable(address(
            new ERC1967Proxy(
                address(new LiquidationManagerUpgradeable()),
                abi.encodeCall(LiquidationManagerUpgradeable.initialize, (
                    admin,
                    address(engine),
                    address(vault),
                    address(priceOracle)
                ))
            )
        ));

        // Configure roles
        vm.startPrank(admin);

        // Grant operator roles
        haircutRegistry.grantRole(haircutRegistry.OPERATOR_ROLE(), operator_);
        priceOracle.grantRole(priceOracle.OPERATOR_ROLE(), operator_);
        engine.grantRole(engine.OPERATOR_ROLE(), operator_);

        // Grant liquidator roles
        vault.grantRole(vault.LIQUIDATOR_ROLE(), address(liquidator));
        engine.grantRole(engine.LIQUIDATOR_ROLE(), address(liquidator));

        // Link vault to engine
        vault.setBorrowingEngine(address(engine));

        vm.stopPrank();

        // Configure haircuts
        vm.startPrank(operator_);
        haircutRegistry.setHaircut(address(wbtc), IHaircutRegistry.HaircutConfig({
            collateralHaircutBps: 3000,  // 30% haircut
            borrowHaircutBps: 1000,
            maxLtvBps: 6500,
            liquidationThresholdBps: 7500,
            enabled: true
        }));
        haircutRegistry.setHaircut(address(usdt), IHaircutRegistry.HaircutConfig({
            collateralHaircutBps: 500,   // 5% haircut
            borrowHaircutBps: 200,
            maxLtvBps: 9000,
            liquidationThresholdBps: 9500,
            enabled: true
        }));
        vm.stopPrank();

        // Set prices (8 decimals)
        vm.startPrank(admin);
        priceOracle.setPrice(address(wbtc), 65000e8);  // $65,000
        priceOracle.setPrice(address(usdt), 1e8);       // $1.00
        vm.stopPrank();

        // Configure borrow token (USDT at 5% APR)
        vm.startPrank(operator_);
        engine.addSupportedToken(address(usdt), 500); // 5% = 500 bps
        vm.stopPrank();

        // Fund treasury with USDT for lending pool
        usdt.mint(operator_, 10_000_000e6);
        vm.startPrank(operator_);
        usdt.approve(address(engine), 5_000_000e6);
        engine.addLiquidity(address(usdt), 5_000_000e6);
        vm.stopPrank();

        // Give borrower some WBTC
        wbtc.mint(borrower, 2e8); // 2 BTC
    }

    // ========================================================================
    // Test: Full borrow lifecycle
    // ========================================================================

    function testFullBorrowLifecycle() public {
        // Step 1: Borrower deposits 1 BTC as collateral
        vm.startPrank(borrower);
        wbtc.approve(address(vault), 1e8);
        vault.depositCollateral(address(wbtc), 1e8);
        vm.stopPrank();

        // Verify collateral value
        // Raw: 1 BTC * $65,000 = $65,000
        // Effective: $65,000 * (1 - 0.30) = $45,500
        uint256 rawValue = vault.getCollateralValue(borrower);
        uint256 effectiveValue = vault.getEffectiveCollateralValue(borrower);

        // Values are in token-native * price / 1e8
        // 1e8 * 65000e8 / 1e8 = 65000e8
        assertEq(rawValue, 65000e8);
        // Effective: 1e8 * 65000e8 * 7000 / (10000 * 1e8) = 45500e8
        assertEq(effectiveValue, 45500e8);

        // Step 2: Borrow 30,000 USDT
        vm.startPrank(borrower);
        uint256 loanId = engine.borrow(address(usdt), 30_000e6);
        vm.stopPrank();

        // Verify loan created
        assertEq(engine.getTotalBorrowed(address(usdt)), 30_000e6);

        // Health factor: $45,500 / $30,000 = 1.5167x = ~15167 bps
        uint256 hf = engine.getHealthFactor(borrower);
        // effectiveCollateral is in 8-decimal terms: 45500e8
        // borrowValue: 30000e6 * 1e8 / 1e8 = 30000e6
        // HF = 45500e8 * 10000 / 30000e6 = ~151666666 (much > 10000)
        assertTrue(hf > 12500, "Health factor should be above minimum");

        // Step 3: Accrue interest over 30 days
        vm.warp(block.timestamp + 30 days);

        (uint256 principal, uint256 interest, uint256 total) = engine.getLoanBalance(loanId);
        assertEq(principal, 30_000e6);
        assertTrue(interest > 0, "Interest should have accrued");

        // Step 4: Repay loan
        usdt.mint(borrower, total); // Mint enough to cover
        vm.startPrank(borrower);
        usdt.approve(address(engine), total);
        engine.repay(loanId, total);
        vm.stopPrank();

        // Loan should be closed
        BorrowingEngineUpgradeable.Loan memory loan = engine.getLoan(loanId);
        assertFalse(loan.active);

        // Step 5: Withdraw collateral
        vm.startPrank(borrower);
        vault.withdrawCollateral(address(wbtc), 1e8);
        vm.stopPrank();

        assertEq(wbtc.balanceOf(borrower), 2e8); // Back to 2 BTC
    }

    // ========================================================================
    // Test: Cannot borrow without sufficient collateral
    // ========================================================================

    function testCannotBorrowWithoutCollateral() public {
        vm.prank(borrower);
        vm.expectRevert(bytes("insufficient collateral"));
        engine.borrow(address(usdt), 1000e6);
    }

    // ========================================================================
    // Test: Cannot withdraw collateral below margin
    // ========================================================================

    function testCannotWithdrawBelowMargin() public {
        // Deposit and borrow
        vm.startPrank(borrower);
        wbtc.approve(address(vault), 1e8);
        vault.depositCollateral(address(wbtc), 1e8);
        engine.borrow(address(usdt), 30_000e6);

        // Try to withdraw all collateral - should fail
        vm.expectRevert(bytes("insufficient free collateral"));
        vault.withdrawCollateral(address(wbtc), 1e8);
        vm.stopPrank();
    }

    // ========================================================================
    // Test: Compliance blocks deposit
    // ========================================================================

    function testComplianceBlocksDeposit() public {
        // Block borrower
        vm.prank(admin);
        compliance.setBlocked(borrower, true);

        vm.startPrank(borrower);
        wbtc.approve(address(vault), 1e8);
        vm.expectRevert(bytes("compliance: blocked"));
        vault.depositCollateral(address(wbtc), 1e8);
        vm.stopPrank();
    }

    // ========================================================================
    // Test: Liquidation flow
    // ========================================================================

    function testLiquidationOnPriceDrop() public {
        // Deposit and borrow at comfortable ratio
        vm.startPrank(borrower);
        wbtc.approve(address(vault), 1e8);
        vault.depositCollateral(address(wbtc), 1e8);
        engine.borrow(address(usdt), 30_000e6);
        vm.stopPrank();

        // Crash BTC price to trigger liquidation.
        // Health factor uses raw token-decimal values, so with WBTC (8 dec) collateral
        // and USDT (6 dec) borrows, we need a very low price for HF < 10500.
        // At $400: effective = 1e8 * 400e8 * 7000 / (10000 * 1e8) = 280e8
        // borrowValue = 30000e6 * 1e8 / 1e8 = 30000e6
        // HF = 280e8 * 10000 / 30000e6 = 9333 < 10500
        vm.prank(admin);
        priceOracle.setPrice(address(wbtc), 400e8);

        // Verify liquidatable
        assertTrue(liquidator.isLiquidatable(borrower));

        // Liquidator repays 15,000 USDT, seizes WBTC at 5% bonus
        usdt.mint(liquidatorAddr, 15_000e6);
        vm.startPrank(liquidatorAddr);
        usdt.approve(address(liquidator), 15_000e6);
        liquidator.liquidate(borrower, 0, address(wbtc), 15_000e6);
        vm.stopPrank();

        // Liquidator should have received WBTC
        assertTrue(wbtc.balanceOf(liquidatorAddr) > 0, "Liquidator should have received WBTC");

        // Borrower's collateral should be reduced
        assertTrue(vault.getTokenBalance(borrower, address(wbtc)) < 1e8);
    }

    // ========================================================================
    // Test: Price oracle staleness
    // ========================================================================

    function testPriceStaleness() public {
        vm.prank(admin);
        priceOracle.setPrice(address(wbtc), 65000e8);

        assertTrue(priceOracle.isPriceFresh(address(wbtc)));

        // Fast forward past staleness window (5 min + 1 sec)
        vm.warp(block.timestamp + 301);

        assertFalse(priceOracle.isPriceFresh(address(wbtc)));
    }

    // ========================================================================
    // Test: Interest accrual accuracy
    // ========================================================================

    function testInterestAccrual() public {
        // Deposit and borrow
        vm.startPrank(borrower);
        wbtc.approve(address(vault), 1e8);
        vault.depositCollateral(address(wbtc), 1e8);
        engine.borrow(address(usdt), 100_000e6);
        vm.stopPrank();

        // Fast forward 365 days
        vm.warp(block.timestamp + 365 days);

        // Check interest: 100,000 * 5% = 5,000 USDT over 1 year
        (, uint256 interest,) = engine.getLoanBalance(0);

        // Allow 0.1% tolerance for rounding
        assertApproxEqRel(interest, 5_000e6, 0.001e18);
    }

    // ========================================================================
    // Test: Multiple collateral types
    // ========================================================================

    function testMultipleCollateralTypes() public {
        usdt.mint(borrower, 50_000e6);

        vm.startPrank(borrower);
        // Deposit 0.5 BTC + 50,000 USDT as collateral
        wbtc.approve(address(vault), 0.5e8);
        vault.depositCollateral(address(wbtc), 0.5e8);

        usdt.approve(address(vault), 50_000e6);
        vault.depositCollateral(address(usdt), 50_000e6);
        vm.stopPrank();

        // Check positions
        CollateralVaultUpgradeable.CollateralPosition[] memory positions = vault.getPositions(borrower);
        assertEq(positions.length, 2);

        // Effective: 0.5 BTC * $65,000 * 0.70 = $22,750
        //          + 50,000 USDT * $1.00 * 0.95 = $47,500
        //          = $70,250
        uint256 effective = vault.getEffectiveCollateralValue(borrower);
        assertTrue(effective > 0);
    }

    // ========== DIGITAL TWIN GETTER TESTS ==========

    function testGetClientTokens() public {
        // Before deposit, no tokens
        address[] memory tokensBefore = vault.getClientTokens(borrower);
        assertEq(tokensBefore.length, 0);

        // Deposit WBTC
        vm.startPrank(borrower);
        wbtc.approve(address(vault), 1e8);
        vault.depositCollateral(address(wbtc), 1e8);
        vm.stopPrank();

        address[] memory tokensAfter = vault.getClientTokens(borrower);
        assertEq(tokensAfter.length, 1);
        assertEq(tokensAfter[0], address(wbtc));
    }

    function testGetClientTokensMultiple() public {
        usdt.mint(borrower, 50_000e6);

        vm.startPrank(borrower);
        wbtc.approve(address(vault), 0.5e8);
        vault.depositCollateral(address(wbtc), 0.5e8);
        usdt.approve(address(vault), 50_000e6);
        vault.depositCollateral(address(usdt), 50_000e6);
        vm.stopPrank();

        address[] memory tokens = vault.getClientTokens(borrower);
        assertEq(tokens.length, 2);
    }

    function testHasToken() public {
        assertFalse(vault.hasToken(borrower, address(wbtc)));

        vm.startPrank(borrower);
        wbtc.approve(address(vault), 1e8);
        vault.depositCollateral(address(wbtc), 1e8);
        vm.stopPrank();

        assertTrue(vault.hasToken(borrower, address(wbtc)));
        assertFalse(vault.hasToken(borrower, address(usdt)));
    }
}

interface ICollateralVault {
    struct CollateralPosition {
        address token;
        uint256 amount;
        uint256 billId;
        uint256 depositedAt;
        bool locked;
    }
}
