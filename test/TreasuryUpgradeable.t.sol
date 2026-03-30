// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {IStrategyAdapter} from "../src/interfaces/IStrategyAdapter.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";

// ============================================================================
// Mock Contracts
// ============================================================================

contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _decimals = dec_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/// @notice Liquid strategy mock (like Aave V3)
contract MockLiquidStrategy is IStrategyAdapter {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public _deployed;
    mapping(address => bool) public _supported;

    function addSupportedToken(address token) external {
        _supported[token] = true;
    }

    function deploy(address token, uint256 amount) external override {
        // Tokens already transferred to this contract
        _deployed[token] += amount;
    }

    function withdraw(address token, uint256 amount) external override returns (uint256) {
        if (_deployed[token] >= amount) {
            _deployed[token] -= amount;
        } else {
            _deployed[token] = 0;
        }
        IERC20(token).safeTransfer(msg.sender, amount);
        return amount;
    }

    function totalDeployed(address token) external view override returns (uint256) {
        return _deployed[token];
    }

    function currentValue(address token) external view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function supportsToken(address token) external view override returns (bool) {
        return _supported[token];
    }

    function isLiquid() external pure override returns (bool) {
        return true;
    }

    function name() external pure override returns (string memory) {
        return "Mock Liquid Strategy";
    }
}

/// @notice Non-liquid strategy mock
contract MockIlliquidStrategy is IStrategyAdapter {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public _deployed;
    mapping(address => bool) public _supported;
    address public custody;

    constructor(address custody_) {
        custody = custody_;
    }

    function addSupportedToken(address token) external {
        _supported[token] = true;
    }

    function deploy(address token, uint256 amount) external override {
        IERC20(token).safeTransfer(custody, amount);
        _deployed[token] += amount;
    }

    function withdraw(address token, uint256 amount) external override returns (uint256) {
        _deployed[token] -= amount;
        IERC20(token).safeTransferFrom(custody, msg.sender, amount);
        return amount;
    }

    function totalDeployed(address token) external view override returns (uint256) {
        return _deployed[token];
    }

    function currentValue(address token) external view override returns (uint256) {
        return _deployed[token];
    }

    function supportsToken(address token) external view override returns (bool) {
        return _supported[token];
    }

    function isLiquid() external pure override returns (bool) {
        return false;
    }

    function name() external pure override returns (string memory) {
        return "Mock Illiquid Strategy";
    }
}

// ============================================================================
// Treasury Tests
// ============================================================================

contract TreasuryUpgradeableTest is Test {
    TreasuryUpgradeable public treasury;
    MockToken public mUSD;
    MockToken public mETH;
    MockLiquidStrategy public liquidStrategy;
    MockIlliquidStrategy public illiquidStrategy;

    address public admin = makeAddr("admin");
    address public depositManager = makeAddr("depositManager");
    address public collateralManager = makeAddr("collateralManager");
    address public lendingManager = makeAddr("lendingManager");
    address public operator = makeAddr("operator");
    address public depositor = makeAddr("depositor");
    address public borrower = makeAddr("borrower");
    address public liquidator = makeAddr("liquidator");
    address public custody = makeAddr("custody");

    uint256 constant MILLION = 1_000_000 * 1e6; // 1M mUSD (6 decimals)
    uint256 constant TEN_ETH = 10 * 1e18;

    function setUp() public {
        // Deploy tokens
        mUSD = new MockToken("Mock USD", "mUSD", 6);
        mETH = new MockToken("Mock ETH", "mETH", 18);

        // Deploy Treasury proxy
        address impl = address(new TreasuryUpgradeable());
        address proxy = address(new ERC1967Proxy(
            impl,
            abi.encodeCall(TreasuryUpgradeable.initialize, (admin))
        ));
        treasury = TreasuryUpgradeable(proxy);

        // Deploy strategies
        liquidStrategy = new MockLiquidStrategy();
        liquidStrategy.addSupportedToken(address(mUSD));
        liquidStrategy.addSupportedToken(address(mETH));

        illiquidStrategy = new MockIlliquidStrategy(custody);
        illiquidStrategy.addSupportedToken(address(mUSD));

        // Grant roles
        vm.startPrank(admin);
        treasury.grantRole(treasury.DEPOSIT_MANAGER_ROLE(), depositManager);
        treasury.grantRole(treasury.COLLATERAL_MANAGER_ROLE(), collateralManager);
        treasury.grantRole(treasury.LENDING_MANAGER_ROLE(), lendingManager);
        treasury.grantRole(treasury.OPERATOR_ROLE(), operator);

        // Register strategies
        treasury.registerStrategy(address(liquidStrategy));
        treasury.registerStrategy(address(illiquidStrategy));

        // Set reserve ratios
        treasury.setReserveRatio(address(mUSD), 2000); // 20%
        treasury.setReserveRatio(address(mETH), 3500); // 35%
        vm.stopPrank();

        // Fund accounts
        mUSD.mint(depositor, MILLION * 10);
        mUSD.mint(borrower, MILLION);
        mUSD.mint(operator, MILLION * 5);
        mETH.mint(depositor, TEN_ETH * 100);
    }

    // ============================================================================
    // Initialization
    // ============================================================================

    function test_initialize() public view {
        assertTrue(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(treasury.hasRole(treasury.OPERATOR_ROLE(), admin));
        assertTrue(treasury.hasRole(treasury.UPGRADER_ROLE(), admin));
        assertTrue(treasury.hasRole(treasury.DEPOSIT_MANAGER_ROLE(), depositManager));
        assertTrue(treasury.hasRole(treasury.COLLATERAL_MANAGER_ROLE(), collateralManager));
        assertTrue(treasury.hasRole(treasury.LENDING_MANAGER_ROLE(), lendingManager));
    }

    function test_reserveRatios() public view {
        assertEq(treasury.reserveRatioBps(address(mUSD)), 2000);
        assertEq(treasury.reserveRatioBps(address(mETH)), 3500);
    }

    // ============================================================================
    // Deposit Flow
    // ============================================================================

    function test_recordDeposit() public {
        // Simulate deposit — tokens transferred to treasury
        uint256 principal = 100_000 * 1e6;
        uint256 liability = 105_000 * 1e6; // 5% yield
        uint256 maturity = block.timestamp + 90 days;

        mUSD.mint(address(treasury), principal);

        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), principal, liability, maturity);

        assertEq(treasury.depositClaims(address(mUSD)), principal);
        assertEq(treasury.depositLiabilities(address(mUSD)), liability);
    }

    function test_withdrawForRedemption() public {
        // Setup deposit
        uint256 principal = 100_000 * 1e6;
        uint256 liability = 105_000 * 1e6;
        uint256 maturity = block.timestamp + 90 days;

        mUSD.mint(address(treasury), liability); // Fund enough for full redemption

        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), principal, liability, maturity);

        // Fast forward past maturity
        vm.warp(maturity + 1);

        // Redeem
        uint256 balBefore = mUSD.balanceOf(depositor);
        vm.prank(depositManager);
        treasury.withdrawForRedemption(address(mUSD), liability, depositor);

        assertEq(mUSD.balanceOf(depositor) - balBefore, liability);
        assertEq(treasury.depositLiabilities(address(mUSD)), 0);
    }

    function test_recordDeposit_revertsUnauthorized() public {
        vm.expectRevert();
        vm.prank(depositor);
        treasury.recordDeposit(address(mUSD), 100, 110, block.timestamp + 1 days);
    }

    // ============================================================================
    // Collateral Flow
    // ============================================================================

    function test_collateralFlow() public {
        uint256 amount = 50_000 * 1e6;

        // Deposit collateral — tokens to treasury
        mUSD.mint(address(treasury), amount);
        vm.prank(collateralManager);
        treasury.recordCollateral(address(mUSD), amount);

        assertEq(treasury.collateralClaims(address(mUSD)), amount);

        // Release collateral
        vm.prank(collateralManager);
        treasury.releaseCollateral(address(mUSD), amount, depositor);

        assertEq(treasury.collateralClaims(address(mUSD)), 0);
        assertEq(mUSD.balanceOf(depositor), MILLION * 10 + amount);
    }

    function test_liquidation() public {
        uint256 amount = 50_000 * 1e6;

        mUSD.mint(address(treasury), amount);
        vm.prank(collateralManager);
        treasury.recordCollateral(address(mUSD), amount);

        // Liquidate
        uint256 balBefore = mUSD.balanceOf(liquidator);
        vm.prank(collateralManager);
        treasury.withdrawForLiquidation(address(mUSD), amount, liquidator);

        assertEq(mUSD.balanceOf(liquidator) - balBefore, amount);
        assertEq(treasury.collateralClaims(address(mUSD)), 0);
    }

    // ============================================================================
    // Lending Flow
    // ============================================================================

    function test_lendingFlow() public {
        // Fund lending pool
        vm.startPrank(operator);
        mUSD.approve(address(treasury), MILLION);
        treasury.fundLendingPool(address(mUSD), MILLION);
        vm.stopPrank();

        assertEq(treasury.lendingPoolReserves(address(mUSD)), MILLION);

        // Disburse loan
        uint256 loanAmount = 100_000 * 1e6;
        uint256 balBefore = mUSD.balanceOf(borrower);
        vm.prank(lendingManager);
        treasury.withdrawForLoan(address(mUSD), loanAmount, borrower);

        assertEq(mUSD.balanceOf(borrower) - balBefore, loanAmount);
        assertEq(treasury.lendingPoolReserves(address(mUSD)), MILLION - loanAmount);

        // Record repayment with interest
        uint256 principalRepaid = loanAmount;
        uint256 interestPaid = 5_000 * 1e6; // 5% interest
        mUSD.mint(address(treasury), principalRepaid + interestPaid);

        vm.prank(lendingManager);
        treasury.recordRepayment(address(mUSD), principalRepaid, interestPaid);

        assertEq(treasury.lendingPoolReserves(address(mUSD)), MILLION);
        assertEq(treasury.protocolRevenue(address(mUSD)), interestPaid);
    }

    function test_withdrawForLoan_insufficientPool() public {
        vm.prank(lendingManager);
        vm.expectRevert("insufficient lending pool");
        treasury.withdrawForLoan(address(mUSD), 100, borrower);
    }

    // ============================================================================
    // Strategy Deployment
    // ============================================================================

    function test_allocateToLiquidStrategy() public {
        // Fund treasury
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        // Deploy 50% to liquid strategy
        uint256 deployAmount = 500_000 * 1e6;
        vm.prank(operator);
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), deployAmount, 0);

        assertEq(treasury.strategyDeployed(address(liquidStrategy), address(mUSD)), deployAmount);
        assertEq(mUSD.balanceOf(address(liquidStrategy)), deployAmount);
    }

    function test_allocateToStrategy_revertsOnReserveFloorBreach() public {
        // Fund treasury with 1M and set 20% reserve
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        // Try to deploy more than 80% (would breach 20% reserve floor)
        uint256 tooMuch = 900_000 * 1e6;
        vm.prank(operator);
        vm.expectRevert("would breach reserve floor");
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), tooMuch, 0);
    }

    function test_withdrawFromStrategy() public {
        // Setup: fund and deploy
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        uint256 deployAmount = 500_000 * 1e6;
        vm.prank(operator);
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), deployAmount, 0);

        // Withdraw half
        uint256 withdrawAmount = 250_000 * 1e6;
        vm.prank(operator);
        treasury.withdrawFromStrategy(address(liquidStrategy), address(mUSD), withdrawAmount);

        assertEq(treasury.strategyDeployed(address(liquidStrategy), address(mUSD)), deployAmount - withdrawAmount);
    }

    // ============================================================================
    // Auto-Unwind (Liquidation Guarantee)
    // ============================================================================

    function test_liquidation_autoUnwindsStrategy() public {
        // Fund treasury with collateral
        uint256 collateral = 500_000 * 1e6;
        mUSD.mint(address(treasury), collateral);
        vm.prank(collateralManager);
        treasury.recordCollateral(address(mUSD), collateral);

        // Deploy 80% to liquid strategy (leaving 20% on-chain)
        uint256 deployAmount = 400_000 * 1e6;
        vm.prank(operator);
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), deployAmount, 0);

        uint256 onChainBefore = mUSD.balanceOf(address(treasury));
        assertEq(onChainBefore, 100_000 * 1e6); // Only 100K on-chain

        // Liquidate full collateral — must auto-unwind strategy
        vm.prank(collateralManager);
        treasury.withdrawForLiquidation(address(mUSD), collateral, liquidator);

        assertEq(mUSD.balanceOf(liquidator), collateral);
        assertEq(treasury.collateralClaims(address(mUSD)), 0);
    }

    // ============================================================================
    // Revenue
    // ============================================================================

    function test_withdrawRevenue() public {
        // Create revenue via repayment
        uint256 interest = 10_000 * 1e6;
        mUSD.mint(address(treasury), interest);
        vm.prank(lendingManager);
        treasury.recordRepayment(address(mUSD), 0, interest);

        assertEq(treasury.protocolRevenue(address(mUSD)), interest);

        // Withdraw revenue
        address recipient = makeAddr("revenueRecipient");
        vm.prank(admin);
        treasury.withdrawRevenue(address(mUSD), interest, recipient);

        assertEq(mUSD.balanceOf(recipient), interest);
        assertEq(treasury.protocolRevenue(address(mUSD)), 0);
    }

    function test_withdrawRevenue_insufficientRevenue() public {
        vm.prank(admin);
        vm.expectRevert("exceeds protocol revenue");
        treasury.withdrawRevenue(address(mUSD), 100, admin);
    }

    // ============================================================================
    // Strategy Management
    // ============================================================================

    function test_registerAndRemoveStrategy() public {
        MockLiquidStrategy newStrategy = new MockLiquidStrategy();

        vm.prank(admin);
        treasury.registerStrategy(address(newStrategy));
        assertTrue(treasury.isRegisteredStrategy(address(newStrategy)));

        address[] memory strategies = treasury.getStrategies();
        assertEq(strategies.length, 3); // liquid + illiquid + new

        vm.prank(admin);
        treasury.removeStrategy(address(newStrategy));
        assertFalse(treasury.isRegisteredStrategy(address(newStrategy)));

        strategies = treasury.getStrategies();
        assertEq(strategies.length, 2);
    }

    function test_removeStrategy_revertsWithDeployedBalance() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        vm.prank(operator);
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), 100_000 * 1e6, 0);

        vm.prank(admin);
        vm.expectRevert("strategy has deployed balance");
        treasury.removeStrategy(address(liquidStrategy));
    }

    // ============================================================================
    // View Functions
    // ============================================================================

    function test_totalAssets() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        // Deploy some to strategy
        vm.prank(operator);
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), 500_000 * 1e6, 0);

        uint256 total = treasury.totalAssets(address(mUSD));
        assertEq(total, MILLION); // 500K on-chain + 500K deployed
    }

    function test_totalLiabilities() public {
        // Deposits
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION + 50_000 * 1e6, block.timestamp + 90 days);

        // Collateral
        mUSD.mint(address(treasury), 200_000 * 1e6);
        vm.prank(collateralManager);
        treasury.recordCollateral(address(mUSD), 200_000 * 1e6);

        uint256 total = treasury.totalLiabilities(address(mUSD));
        // deposit liabilities (1.05M) + collateral claims (200K) + lending pool (0)
        assertEq(total, (MILLION + 50_000 * 1e6) + 200_000 * 1e6);
    }

    function test_getTokenState() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION + 50_000 * 1e6, block.timestamp + 90 days);

        ITreasury.TokenState memory state = treasury.getTokenState(address(mUSD));
        assertEq(state.depositClaims, MILLION);
        assertEq(state.depositLiabilities, MILLION + 50_000 * 1e6);
        assertEq(state.collateralClaims, 0);
        assertEq(state.lendingPool, 0);
        assertEq(state.deployed, 0);
        assertEq(state.protocolRevenue, 0);
        assertEq(state.reserveRatioBps, 2000);
    }

    // ============================================================================
    // ALM Health
    // ============================================================================

    function test_isALMHealthy_liquid() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 30 days);

        assertTrue(treasury.isALMHealthy(address(mUSD)));
    }

    function test_getMaturityProfile() public {
        uint256 maturity1 = block.timestamp + 30 days;
        uint256 maturity2 = block.timestamp + 90 days;

        mUSD.mint(address(treasury), MILLION * 2);

        vm.startPrank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, maturity1);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, maturity2);
        vm.stopPrank();

        ITreasury.MaturityBucket[] memory buckets = treasury.getMaturityProfile(address(mUSD));
        assertTrue(buckets.length >= 1);
    }

    // ============================================================================
    // Token Tracking
    // ============================================================================

    function test_trackedTokens() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 30 days);

        mETH.mint(address(treasury), TEN_ETH);
        vm.prank(collateralManager);
        treasury.recordCollateral(address(mETH), TEN_ETH);

        address[] memory tracked = treasury.getTrackedTokens();
        assertEq(tracked.length, 2);
    }

    // ============================================================================
    // Reserve Ratio
    // ============================================================================

    function test_availableReserves() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        // Reserve floor = 1M * 20% = 200K
        // Available = 1M - 200K = 800K
        uint256 available = treasury.availableReserves(address(mUSD));
        assertEq(available, 800_000 * 1e6);
    }

    function test_setReserveRatio_revertsExceedMax() public {
        vm.prank(operator);
        vm.expectRevert("ratio too high");
        treasury.setReserveRatio(address(mUSD), 10001);
    }

    // ============================================================================
    // Emergency Withdraw
    // ============================================================================

    function test_emergencyWithdraw_fullBalance() public {
        // Setup: deposit + collateral + revenue
        uint256 depositAmount = 500_000 * 1e6;
        uint256 collateralAmount = 200_000 * 1e6;
        uint256 interest = 10_000 * 1e6;

        mUSD.mint(address(treasury), depositAmount + collateralAmount + interest);

        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), depositAmount, depositAmount + 25_000 * 1e6, block.timestamp + 90 days);

        vm.prank(collateralManager);
        treasury.recordCollateral(address(mUSD), collateralAmount);

        vm.prank(lendingManager);
        treasury.recordRepayment(address(mUSD), 0, interest);

        // Emergency withdraw everything
        address recipient = makeAddr("emergencyRecipient");
        vm.prank(admin);
        treasury.emergencyWithdraw(address(mUSD), type(uint256).max, recipient);

        // All tokens transferred to recipient
        assertEq(mUSD.balanceOf(recipient), depositAmount + collateralAmount + interest);
        assertEq(mUSD.balanceOf(address(treasury)), 0);

        // All accounting zeroed
        assertEq(treasury.depositClaims(address(mUSD)), 0);
        assertEq(treasury.depositLiabilities(address(mUSD)), 0);
        assertEq(treasury.collateralClaims(address(mUSD)), 0);
        assertEq(treasury.lendingPoolReserves(address(mUSD)), 0);
        assertEq(treasury.protocolRevenue(address(mUSD)), 0);
    }

    function test_emergencyWithdraw_partialAmount() public {
        uint256 amount = 1_000_000 * 1e6;
        mUSD.mint(address(treasury), amount);

        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), amount, amount, block.timestamp + 90 days);

        // Withdraw only half — but accounting still gets zeroed
        address recipient = makeAddr("emergencyRecipient");
        uint256 half = 500_000 * 1e6;
        vm.prank(admin);
        treasury.emergencyWithdraw(address(mUSD), half, recipient);

        assertEq(mUSD.balanceOf(recipient), half);
        assertEq(mUSD.balanceOf(address(treasury)), half);

        // Accounting still zeroed (emergency = full reset)
        assertEq(treasury.depositClaims(address(mUSD)), 0);
        assertEq(treasury.depositLiabilities(address(mUSD)), 0);
    }

    function test_emergencyWithdraw_revertsFromNonAdmin() public {
        mUSD.mint(address(treasury), MILLION);

        vm.prank(operator);
        vm.expectRevert();
        treasury.emergencyWithdraw(address(mUSD), MILLION, operator);

        vm.prank(depositManager);
        vm.expectRevert();
        treasury.emergencyWithdraw(address(mUSD), MILLION, depositManager);
    }

    function test_emergencyWithdraw_unwindsStrategies() public {
        // Fund treasury and deploy to liquid strategy
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        uint256 deployAmount = 600_000 * 1e6;
        vm.prank(operator);
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), deployAmount, 0);

        assertEq(mUSD.balanceOf(address(liquidStrategy)), deployAmount);
        assertEq(mUSD.balanceOf(address(treasury)), MILLION - deployAmount);

        // Emergency withdraw — should unwind strategy first, then transfer all
        address recipient = makeAddr("emergencyRecipient");
        vm.prank(admin);
        treasury.emergencyWithdraw(address(mUSD), type(uint256).max, recipient);

        // All funds recovered
        assertEq(mUSD.balanceOf(recipient), MILLION);
        assertEq(mUSD.balanceOf(address(treasury)), 0);
        assertEq(mUSD.balanceOf(address(liquidStrategy)), 0);

        // Strategy tracking zeroed
        assertEq(treasury.strategyDeployed(address(liquidStrategy), address(mUSD)), 0);
    }

    function test_emergencyWithdraw_zeroBalanceReverts() public {
        address recipient = makeAddr("emergencyRecipient");
        vm.prank(admin);
        vm.expectRevert("nothing to withdraw");
        treasury.emergencyWithdraw(address(mUSD), MILLION, recipient);
    }

    // ============================================================================
    // adjustDepositOnMerge
    // ============================================================================

    function test_adjustDepositOnMerge_updatesLiabilities() public {
        // Record two deposits
        uint256 liability1 = 500_000 * 1e6;
        uint256 liability2 = 300_000 * 1e6;
        uint256 maturity1 = block.timestamp + 30 days;
        uint256 maturity2 = block.timestamp + 90 days;

        mUSD.mint(address(treasury), 800_000 * 1e6);
        vm.startPrank(depositManager);
        treasury.recordDeposit(address(mUSD), 450_000 * 1e6, liability1, maturity1);
        treasury.recordDeposit(address(mUSD), 280_000 * 1e6, liability2, maturity2);
        vm.stopPrank();

        uint256 totalLiabilitiesBefore = treasury.depositLiabilities(address(mUSD));
        assertEq(totalLiabilitiesBefore, liability1 + liability2);

        // Merge: old liabilities removed, new merged liability added
        uint256 newLiability = 850_000 * 1e6; // Slightly higher (rollover growth)
        uint256 newMaturity = maturity2; // Uses longest maturity

        uint256[] memory oldLiabilities = new uint256[](2);
        oldLiabilities[0] = liability1;
        oldLiabilities[1] = liability2;
        uint256[] memory oldMaturities = new uint256[](2);
        oldMaturities[0] = maturity1;
        oldMaturities[1] = maturity2;

        vm.prank(depositManager);
        treasury.adjustDepositOnMerge(
            address(mUSD),
            liability1 + liability2,
            newLiability,
            newMaturity,
            oldLiabilities,
            oldMaturities
        );

        assertEq(treasury.depositLiabilities(address(mUSD)), newLiability);
    }

    function test_adjustDepositOnMerge_updatesMaturityBuckets() public {
        uint256 maturity1 = block.timestamp + 30 days;
        uint256 maturity2 = block.timestamp + 90 days;

        mUSD.mint(address(treasury), MILLION);
        vm.startPrank(depositManager);
        treasury.recordDeposit(address(mUSD), 500_000 * 1e6, 500_000 * 1e6, maturity1);
        treasury.recordDeposit(address(mUSD), 500_000 * 1e6, 500_000 * 1e6, maturity2);
        vm.stopPrank();

        // Check maturity buckets before merge
        ITreasury.MaturityBucket[] memory bucketsBefore = treasury.getMaturityProfile(address(mUSD));
        assertTrue(bucketsBefore.length >= 1);

        // Merge into single maturity at maturity2
        uint256[] memory oldLiabilities = new uint256[](2);
        oldLiabilities[0] = 500_000 * 1e6;
        oldLiabilities[1] = 500_000 * 1e6;
        uint256[] memory oldMaturities = new uint256[](2);
        oldMaturities[0] = maturity1;
        oldMaturities[1] = maturity2;

        vm.prank(depositManager);
        treasury.adjustDepositOnMerge(
            address(mUSD),
            MILLION,
            MILLION + 50_000 * 1e6, // new liability slightly higher
            maturity2,
            oldLiabilities,
            oldMaturities
        );

        // Verify the old bucket for maturity1 is cleared
        uint256 bucket1 = (maturity1 / 7 days) * 7 days;
        assertEq(treasury.maturityLiabilities(address(mUSD), bucket1), 0);
    }

    function test_adjustDepositOnMerge_revertsUnauthorized() public {
        uint256[] memory empty = new uint256[](0);

        vm.prank(operator);
        vm.expectRevert();
        treasury.adjustDepositOnMerge(address(mUSD), 0, 0, block.timestamp + 30 days, empty, empty);
    }

    function test_adjustDepositOnMerge_revertsArrayMismatch() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        uint256[] memory liabilities = new uint256[](2);
        uint256[] memory maturities = new uint256[](1);

        vm.prank(depositManager);
        vm.expectRevert("array length mismatch");
        treasury.adjustDepositOnMerge(
            address(mUSD), MILLION, MILLION, block.timestamp + 90 days, liabilities, maturities
        );
    }

    function test_adjustDepositOnMerge_revertsExceedsLiabilities() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        uint256[] memory oldLiabilities = new uint256[](1);
        oldLiabilities[0] = MILLION * 2; // More than recorded
        uint256[] memory oldMaturities = new uint256[](1);
        oldMaturities[0] = block.timestamp + 90 days;

        vm.prank(depositManager);
        vm.expectRevert("exceeds deposit liabilities");
        treasury.adjustDepositOnMerge(
            address(mUSD), MILLION * 2, MILLION, block.timestamp + 90 days, oldLiabilities, oldMaturities
        );
    }

    function test_adjustDepositOnMerge_depositClaimsUnchanged() public {
        mUSD.mint(address(treasury), MILLION);
        vm.startPrank(depositManager);
        treasury.recordDeposit(address(mUSD), 400_000 * 1e6, 500_000 * 1e6, block.timestamp + 30 days);
        treasury.recordDeposit(address(mUSD), 400_000 * 1e6, 500_000 * 1e6, block.timestamp + 90 days);
        vm.stopPrank();

        uint256 claimsBefore = treasury.depositClaims(address(mUSD));
        assertEq(claimsBefore, 800_000 * 1e6);

        uint256[] memory oldLiabilities = new uint256[](2);
        oldLiabilities[0] = 500_000 * 1e6;
        oldLiabilities[1] = 500_000 * 1e6;
        uint256[] memory oldMaturities = new uint256[](2);
        oldMaturities[0] = block.timestamp + 30 days;
        oldMaturities[1] = block.timestamp + 90 days;

        vm.prank(depositManager);
        treasury.adjustDepositOnMerge(
            address(mUSD), MILLION, MILLION + 50_000 * 1e6, block.timestamp + 90 days,
            oldLiabilities, oldMaturities
        );

        // depositClaims should be unchanged (principals don't change on merge)
        assertEq(treasury.depositClaims(address(mUSD)), claimsBefore);
    }

    // ============================================================================
    // Pause / Unpause
    // ============================================================================

    function test_pause_blocksAllocateToStrategy() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        vm.prank(admin);
        treasury.pause();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), 100_000 * 1e6, 0);
    }

    function test_pause_doesNotBlockWithdrawForRedemption() public {
        uint256 principal = 100_000 * 1e6;
        uint256 liability = 105_000 * 1e6;
        mUSD.mint(address(treasury), liability);

        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), principal, liability, block.timestamp + 90 days);

        vm.prank(admin);
        treasury.pause();

        // Depositors must always be able to exit — even when paused
        vm.warp(block.timestamp + 91 days);
        vm.prank(depositManager);
        treasury.withdrawForRedemption(address(mUSD), liability, depositor);

        assertEq(mUSD.balanceOf(depositor), MILLION * 10 + liability);
    }

    function test_unpause_resumesOperations() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        // Pause then unpause
        vm.startPrank(admin);
        treasury.pause();
        treasury.unpause();
        vm.stopPrank();

        // Should work again after unpause
        vm.prank(operator);
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), 100_000 * 1e6, 0);

        assertEq(treasury.strategyDeployed(address(liquidStrategy), address(mUSD)), 100_000 * 1e6);
    }

    // ============================================================================
    // Yield Harvesting
    // ============================================================================

    function test_harvestYield_capturesExcess() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        // Deploy 500K to liquid strategy
        uint256 deployAmount = 500_000 * 1e6;
        vm.prank(operator);
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), deployAmount, 0);

        // Simulate yield: mint extra tokens to strategy (like Aave interest accrual)
        uint256 yieldAmount = 10_000 * 1e6;
        mUSD.mint(address(liquidStrategy), yieldAmount);

        // Harvest
        vm.prank(operator);
        treasury.harvestYield(address(liquidStrategy), address(mUSD));

        // Yield captured as protocol revenue
        assertEq(treasury.protocolRevenue(address(mUSD)), yieldAmount);
        // Principal still tracked as deployed
        assertEq(treasury.strategyDeployed(address(liquidStrategy), address(mUSD)), deployAmount);
    }

    function test_harvestYield_revertsWhenNoYield() public {
        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 90 days);

        uint256 deployAmount = 500_000 * 1e6;
        vm.prank(operator);
        treasury.allocateToStrategy(address(liquidStrategy), address(mUSD), deployAmount, 0);

        // No yield to harvest
        vm.prank(operator);
        vm.expectRevert("no yield to harvest");
        treasury.harvestYield(address(liquidStrategy), address(mUSD));
    }

    function test_harvestYield_onlyOperator() public {
        vm.prank(depositor);
        vm.expectRevert();
        treasury.harvestYield(address(liquidStrategy), address(mUSD));
    }

    // ============================================================================
    // Token Sweep
    // ============================================================================

    function test_sweepUntracked_recoversExcess() public {
        // Record a deposit so we have tracked funds
        uint256 principal = 100_000 * 1e6;
        mUSD.mint(address(treasury), principal);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), principal, principal, block.timestamp + 90 days);

        // Send extra tokens directly to treasury (accidental transfer)
        uint256 extra = 5_000 * 1e6;
        mUSD.mint(address(treasury), extra);

        // Sweep the untracked excess
        address recipient = makeAddr("sweepRecipient");
        vm.prank(admin);
        treasury.sweepUntracked(address(mUSD), extra, recipient);

        assertEq(mUSD.balanceOf(recipient), extra);
    }

    function test_sweepUntracked_revertsOnTrackedFunds() public {
        uint256 principal = 100_000 * 1e6;
        mUSD.mint(address(treasury), principal);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), principal, principal, block.timestamp + 90 days);

        // Try to sweep tracked funds — should revert
        vm.prank(admin);
        vm.expectRevert("would sweep tracked funds");
        treasury.sweepUntracked(address(mUSD), principal, admin);
    }

    function test_sweepUntracked_onlyAdmin() public {
        mUSD.mint(address(treasury), 1000);

        vm.prank(operator);
        vm.expectRevert();
        treasury.sweepUntracked(address(mUSD), 1000, operator);
    }

    // ========== DIGITAL TWIN GETTER TESTS ==========

    function test_isTrackedToken() public {
        assertFalse(treasury.isTrackedToken(address(mUSD)));

        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, block.timestamp + 30 days);

        assertTrue(treasury.isTrackedToken(address(mUSD)));
        assertFalse(treasury.isTrackedToken(address(0xdead)));
    }

    function test_getActiveBuckets() public {
        uint256 maturity1 = block.timestamp + 30 days;
        uint256 maturity2 = block.timestamp + 90 days;

        mUSD.mint(address(treasury), MILLION * 2);
        vm.startPrank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, maturity1);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, maturity2);
        vm.stopPrank();

        uint256[] memory buckets = treasury.getActiveBuckets(address(mUSD));
        assertTrue(buckets.length >= 1);
        // Buckets should be sorted
        for (uint256 i = 1; i < buckets.length; i++) {
            assertTrue(buckets[i] > buckets[i - 1]);
        }
    }

    function test_isBucketActive() public {
        uint256 maturity = block.timestamp + 30 days;
        uint256 bucketDuration = treasury.BUCKET_DURATION();
        uint256 expectedBucket = (maturity / bucketDuration) * bucketDuration;

        assertFalse(treasury.isBucketActive(address(mUSD), expectedBucket));

        mUSD.mint(address(treasury), MILLION);
        vm.prank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, maturity);

        assertTrue(treasury.isBucketActive(address(mUSD), expectedBucket));
        assertFalse(treasury.isBucketActive(address(mUSD), expectedBucket + bucketDuration * 100));
    }

    function test_getActiveBuckets_empty() public view {
        uint256[] memory buckets = treasury.getActiveBuckets(address(mUSD));
        assertEq(buckets.length, 0);
    }

    function test_getFullSnapshot() public {
        // Deposit to create tracked tokens
        uint256 maturity = block.timestamp + 30 days;
        mUSD.mint(address(treasury), MILLION);
        mETH.mint(address(treasury), TEN_ETH);

        vm.startPrank(depositManager);
        treasury.recordDeposit(address(mUSD), MILLION, MILLION, maturity);
        treasury.recordDeposit(address(mETH), TEN_ETH, TEN_ETH, maturity);
        vm.stopPrank();

        (address[] memory tokens, TreasuryUpgradeable.TokenState[] memory states) = treasury.getFullSnapshot();
        assertEq(tokens.length, states.length);
        assertTrue(tokens.length >= 2);

        // Find mUSD in the snapshot
        bool foundUSD = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(mUSD)) {
                assertEq(states[i].depositClaims, MILLION);
                foundUSD = true;
            }
        }
        assertTrue(foundUSD, "mUSD not found in snapshot");
    }
}
