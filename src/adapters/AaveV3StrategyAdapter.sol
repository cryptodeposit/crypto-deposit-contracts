// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";

/**
 * @title IAaveV3Pool
 * @notice Minimal interface for Aave V3 Pool
 */
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256 configuration,
        uint128 liquidityIndex,
        uint128 currentLiquidityRate,
        uint128 variableBorrowIndex,
        uint128 currentVariableBorrowRate,
        uint128 currentStableBorrowRate,
        uint40 lastUpdateTimestamp,
        uint16 id,
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress,
        address interestRateStrategyAddress,
        uint128 accruedToTreasury,
        uint128 unbacked,
        uint128 isolationModeTotalDebt
    );
}

/**
 * @title AaveV3StrategyAdapter
 * @notice Strategy adapter wrapping Aave V3 for the Treasury
 * @dev Supplies tokens to Aave V3 lending pool. Same-block withdrawals (liquid).
 *      Only callable by the Treasury contract via TREASURY_ROLE.
 */
contract AaveV3StrategyAdapter is IStrategyAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    uint16 public constant REFERRAL_CODE = 0;

    IAaveV3Pool public immutable aavePool;

    /// @notice Token → aToken mapping
    mapping(address => address) public aTokens;
    mapping(address => bool) public supportedTokens;
    /// @notice Total principal deployed per token (not including yield)
    mapping(address => uint256) public deployed;

    event TokenAdded(address indexed token, address indexed aToken);

    constructor(address admin_, address aavePool_) {
        require(admin_ != address(0), "admin=0");
        require(aavePool_ != address(0), "pool=0");

        aavePool = IAaveV3Pool(aavePool_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(TREASURY_ROLE, admin_);
    }

    /// @notice Register a token supported by Aave V3
    function addSupportedToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "token=0");
        require(!supportedTokens[token], "already supported");

        // Security: only aTokenAddress needed from Aave reserve data
        // slither-disable-next-line unused-return
        (,,,,,,,, address aTokenAddress,,,,,,) = aavePool.getReserveData(token);
        require(aTokenAddress != address(0), "no aave reserve");

        supportedTokens[token] = true;
        aTokens[token] = aTokenAddress;

        emit TokenAdded(token, aTokenAddress);
    }

    // ============================================================================
    // IStrategyAdapter Implementation
    // ============================================================================

    function deploy(address token, uint256 amount) external override onlyRole(TREASURY_ROLE) nonReentrant {
        require(supportedTokens[token], "token not supported");
        require(amount > 0, "amount=0");

        // Tokens already transferred to this contract by Treasury
        IERC20(token).safeIncreaseAllowance(address(aavePool), amount);
        aavePool.supply(token, amount, address(this), REFERRAL_CODE);

        deployed[token] += amount;
    }

    function withdraw(address token, uint256 amount) external override onlyRole(TREASURY_ROLE) nonReentrant returns (uint256 withdrawn) {
        require(supportedTokens[token], "token not supported");
        require(amount > 0, "amount=0");

        withdrawn = aavePool.withdraw(token, amount, msg.sender);

        if (deployed[token] >= amount) {
            deployed[token] -= amount;
        } else {
            deployed[token] = 0;
        }
    }

    function totalDeployed(address token) external view override returns (uint256) {
        return deployed[token];
    }

    function currentValue(address token) external view override returns (uint256) {
        address aToken = aTokens[token];
        if (aToken == address(0)) return 0;
        return IERC20(aToken).balanceOf(address(this));
    }

    function supportsToken(address token) external view override returns (bool) {
        return supportedTokens[token];
    }

    function isLiquid() external pure override returns (bool) {
        return true; // Aave V3 supports same-block withdrawals
    }

    function name() external pure override returns (string memory) {
        return "Aave V3";
    }
}
