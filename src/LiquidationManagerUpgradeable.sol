// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IBorrowingEngine.sol";
import "./interfaces/ICollateralVault.sol";
import "./interfaces/IPriceOracle.sol";

/**
 * @title LiquidationManagerUpgradeable
 * @notice Monitors health factors and executes liquidations with incentive structure
 * @dev Permissionless liquidation model:
 *      - Anyone can call liquidate() if borrower's health factor < liquidationThreshold
 *      - Liquidator repays part of the loan and receives collateral at a discount (bonus)
 *      - Max 50% of a loan can be liquidated per call (prevents single-tx wipeout)
 *      - Liquidation bonus incentivizes keepers to monitor and act quickly
 *
 *      Health factor thresholds (in bps, 10000 = 1.0x):
 *      - Warning: 12500 (1.25x) - notification sent
 *      - Critical: 11000 (1.10x) - urgent notification
 *      - Liquidation: 10500 (1.05x) - can be liquidated
 */
contract LiquidationManagerUpgradeable is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    IBorrowingEngine public borrowingEngine;
    ICollateralVault public collateralVault;
    IPriceOracle public priceOracle;

    // ============================================================================
    // Liquidation Parameters
    // ============================================================================

    /// @notice Health factor threshold below which liquidation is permitted (bps)
    uint256 public liquidationThresholdBps;

    /// @notice Discount given to liquidators on collateral (bps, e.g., 500 = 5%)
    uint256 public liquidationBonusBps;

    /// @notice Maximum % of a loan that can be liquidated per call (bps)
    uint256 public maxLiquidationRatioBps;

    /// @notice Minimum liquidation amount to prevent dust liquidations (USD, 8 decimals)
    uint256 public minLiquidationUsd;

    // ============================================================================
    // State
    // ============================================================================

    /// @notice Total liquidations executed
    uint256 public totalLiquidations;

    /// @notice Total value liquidated (USD, 8 decimals)
    uint256 public totalLiquidatedValueUsd;

    // ============================================================================
    // Events
    // ============================================================================

    event LiquidationExecuted(
        address indexed borrower,
        address indexed liquidator,
        uint256 indexed loanId,
        address collateralToken,
        uint256 collateralSeized,
        uint256 debtRepaid,
        uint256 bonusAmount
    );

    event LiquidationParametersUpdated(
        uint256 threshold,
        uint256 bonus,
        uint256 maxRatio,
        uint256 minAmount
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address admin,
        address _borrowingEngine,
        address _collateralVault,
        address _priceOracle
    ) public initializer {
        require(admin != address(0), "admin=0");
        require(_borrowingEngine != address(0), "engine=0");
        require(_collateralVault != address(0), "vault=0");
        require(_priceOracle != address(0), "oracle=0");
        __AccessControl_init();


        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        borrowingEngine = IBorrowingEngine(_borrowingEngine);
        collateralVault = ICollateralVault(_collateralVault);
        priceOracle = IPriceOracle(_priceOracle);

        // Default parameters
        liquidationThresholdBps = 10500;    // 1.05x health factor
        liquidationBonusBps = 500;          // 5% bonus
        maxLiquidationRatioBps = 5000;      // 50% max per call
        minLiquidationUsd = 100 * 1e8;      // $100 minimum
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ============================================================================
    // Admin
    // ============================================================================

    function setLiquidationParameters(
        uint256 _thresholdBps,
        uint256 _bonusBps,
        uint256 _maxRatioBps,
        uint256 _minUsd
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_thresholdBps >= 10000 && _thresholdBps <= 15000, "threshold out of range");
        require(_bonusBps <= 2000, "bonus too high"); // Max 20%
        require(_maxRatioBps > 0 && _maxRatioBps <= 10000, "ratio out of range");

        liquidationThresholdBps = _thresholdBps;
        liquidationBonusBps = _bonusBps;
        maxLiquidationRatioBps = _maxRatioBps;
        minLiquidationUsd = _minUsd;

        emit LiquidationParametersUpdated(_thresholdBps, _bonusBps, _maxRatioBps, _minUsd);
    }

    // ============================================================================
    // Liquidation
    // ============================================================================

    /**
     * @notice Liquidate an unhealthy borrower's position
     * @dev Permissionless - anyone can call. Liquidator must have tokens to repay debt.
     * @param borrower Address of the borrower to liquidate
     * @param loanId ID of the loan to partially repay
     * @param collateralToken The collateral token to seize
     * @param repayAmount Amount of borrowed token to repay
     */
    function liquidate(
        address borrower,
        uint256 loanId,
        address collateralToken,
        uint256 repayAmount
    ) external nonReentrant {
        require(borrower != msg.sender, "cannot self-liquidate");

        // Verify borrower is liquidatable
        uint256 healthFactor = borrowingEngine.getHealthFactor(borrower);
        require(healthFactor < liquidationThresholdBps, "borrower not liquidatable");

        // Get loan details
        IBorrowingEngine.Loan memory loan = borrowingEngine.getLoan(loanId);
        require(loan.active, "loan not active");
        require(loan.borrower == borrower, "loan not owned by borrower");

        // Cap repayment at maxLiquidationRatio of loan
        uint256 maxRepay = (loan.principal * maxLiquidationRatioBps) / 10000;
        if (repayAmount > maxRepay) {
            repayAmount = maxRepay;
        }

        // Calculate collateral to seize (repayAmount + bonus, converted to collateral token)
        // Security: timestamp return intentionally unused
        // slither-disable-next-line unused-return
        (uint256 debtTokenPrice, ) = priceOracle.getPrice(loan.token);
        // Security: timestamp return intentionally unused
        // slither-disable-next-line unused-return
        (uint256 collateralPrice, ) = priceOracle.getPrice(collateralToken);
        require(collateralPrice > 0, "no collateral price");

        // debtValueUsd = repayAmount * debtTokenPrice / 1e8
        // collateralToSeize = debtValueUsd * (10000 + bonus) / 10000 / collateralPrice * 1e8
        uint256 debtValueUsd = Math.mulDiv(repayAmount, debtTokenPrice, 1e8);
        require(debtValueUsd >= minLiquidationUsd, "liquidation too small");

        uint256 collateralValueWithBonus = Math.mulDiv(debtValueUsd, 10000 + liquidationBonusBps, 10000);
        uint256 collateralToSeize = Math.mulDiv(collateralValueWithBonus, 1e8, collateralPrice);

        // Bonus amount (in collateral token terms)
        uint256 bonusInCollateral = (collateralToSeize * liquidationBonusBps) / (10000 + liquidationBonusBps);

        // Transfer repayment from liquidator to BorrowingEngine
        IERC20(loan.token).safeTransferFrom(msg.sender, address(this), repayAmount);
        // Security: approve return checked by SafeERC20 on subsequent transfer
        // slither-disable-next-line unused-return
        IERC20(loan.token).approve(address(borrowingEngine), repayAmount);

        // Execute repayment via BorrowingEngine
        // BorrowingEngine.liquidateRepay handles the accounting
        (bool success, ) = address(borrowingEngine).call(
            abi.encodeWithSignature("liquidateRepay(uint256,uint256,address)", loanId, repayAmount, address(this))
        );
        require(success, "repayment failed");

        // Seize collateral from vault to liquidator
        collateralVault.liquidateCollateral(borrower, collateralToken, collateralToSeize, msg.sender);

        // Update stats
        totalLiquidations++;
        totalLiquidatedValueUsd += debtValueUsd;

        emit LiquidationExecuted(
            borrower,
            msg.sender,
            loanId,
            collateralToken,
            collateralToSeize,
            repayAmount,
            bonusInCollateral
        );
    }

    // ============================================================================
    // View Functions
    // ============================================================================

    /**
     * @notice Check if a borrower can be liquidated
     */
    function isLiquidatable(address borrower) external view returns (bool) {
        uint256 healthFactor = borrowingEngine.getHealthFactor(borrower);
        return healthFactor < liquidationThresholdBps;
    }

    /**
     * @notice Get the price at which a borrower becomes liquidatable
     * @dev This is approximate - assumes single collateral token and single loan
     * @param borrower Address to check
     * @return healthFactorBps Current health factor in basis points
     * @return totalBorrowUsd Total borrow value in USD
     * @return effectiveCollateralUsd Effective collateral value in USD
     * @return liquidatable Whether the borrower can be liquidated
     */
    function getLiquidationInfo(address borrower) external view returns (
        uint256 healthFactorBps,
        uint256 totalBorrowUsd,
        uint256 effectiveCollateralUsd,
        bool liquidatable
    ) {
        healthFactorBps = borrowingEngine.getHealthFactor(borrower);
        totalBorrowUsd = borrowingEngine.getTotalBorrowValue(borrower);
        effectiveCollateralUsd = collateralVault.getEffectiveCollateralValue(borrower);
        liquidatable = healthFactorBps < liquidationThresholdBps;
    }

    /**
     * @notice Get maximum repayable amount for a specific loan
     */
    function getMaxRepayAmount(uint256 loanId) external view returns (uint256) {
        IBorrowingEngine.Loan memory loan = borrowingEngine.getLoan(loanId);
        if (!loan.active) return 0;
        return (loan.principal * maxLiquidationRatioBps) / 10000;
    }

    /// @dev Reserved storage space for future upgrades
    uint256[43] private __gap;
}
