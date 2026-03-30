// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockAToken
 * @notice Rebasing aToken mock — balanceOf scales with an exchange rate
 * @dev exchangeRate starts at 1e18. When the pool calls `simulateYield`, the
 *      rate increases, causing all holders' balanceOf to grow proportionally.
 */
contract MockAToken is ERC20 {
    address public pool;
    uint8 private _decimals;

    /// @dev Tracks "shares" per user. balanceOf = shares * exchangeRate / 1e18
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public exchangeRate; // 1e18 = 1:1

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address pool_)
        ERC20(name_, symbol_)
    {
        pool = pool_;
        _decimals = decimals_;
        exchangeRate = 1e18;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint shares equivalent to `amount` underlying at current rate
    function mint(address to, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        uint256 sharesToMint = (amount * 1e18) / exchangeRate;
        shares[to] += sharesToMint;
        totalShares += sharesToMint;
    }

    /// @notice Burn shares equivalent to `amount` underlying at current rate
    function burn(address from, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        uint256 sharesToBurn = (amount * 1e18 + exchangeRate - 1) / exchangeRate; // round up
        require(shares[from] >= sharesToBurn, "aToken: insufficient balance");
        shares[from] -= sharesToBurn;
        totalShares -= sharesToBurn;
    }

    /// @notice Returns the underlying-denominated balance (rebased)
    function balanceOf(address account) public view override returns (uint256) {
        return (shares[account] * exchangeRate) / 1e18;
    }

    /// @notice Total supply in underlying terms
    function totalSupply() public view override returns (uint256) {
        return (totalShares * exchangeRate) / 1e18;
    }

    /// @dev Called by the pool to simulate yield accrual
    function setExchangeRate(uint256 newRate) external {
        require(msg.sender == pool, "only pool");
        exchangeRate = newRate;
    }
}

/**
 * @title MockAaveV3Pool
 * @notice Realistic Aave V3 Pool mock with yield simulation
 * @dev Key features beyond the basic mock:
 *      - aToken rebasing via exchange rate (balanceOf grows over time)
 *      - Configurable currentLiquidityRate per token (ray format, 1e27)
 *      - simulateYield(token, bps) helper for test-controlled yield accrual
 *      - Proper reserve data with non-zero liquidity rates
 */
contract MockAaveV3Pool {
    /// @notice token => MockAToken address
    mapping(address => address) public aTokens;

    /// @notice token => underlying balance held by pool (backing aTokens)
    mapping(address => uint256) public poolBalance;

    /// @notice token => current liquidity rate in ray (1e27)
    mapping(address => uint128) public liquidityRates;

    /// @notice token => liquidity index in ray (starts at 1e27)
    mapping(address => uint128) public liquidityIndexes;

    // ========================================================================
    // Reserve Initialization
    // ========================================================================

    /// @notice Create an aToken for a given asset so getReserveData works
    function initReserve(address asset) external {
        _ensureReserve(asset);
    }

    /// @notice Create an aToken with specific decimals
    function initReserveWithDecimals(address asset, uint8 tokenDecimals) external {
        if (aTokens[asset] == address(0)) {
            string memory sym = string(abi.encodePacked("a", ERC20(asset).symbol()));
            aTokens[asset] = address(new MockAToken(
                string(abi.encodePacked("Aave ", ERC20(asset).name())),
                sym,
                tokenDecimals,
                address(this)
            ));
            liquidityIndexes[asset] = 1e27;  // RAY
            liquidityRates[asset] = 0;
        }
    }

    function _ensureReserve(address asset) internal {
        if (aTokens[asset] == address(0)) {
            uint8 dec;
            try ERC20(asset).decimals() returns (uint8 d) {
                dec = d;
            } catch {
                dec = 18;
            }
            string memory sym;
            try ERC20(asset).symbol() returns (string memory s) {
                sym = string(abi.encodePacked("a", s));
            } catch {
                sym = "aMOCK";
            }
            string memory nm;
            try ERC20(asset).name() returns (string memory n) {
                nm = string(abi.encodePacked("Aave ", n));
            } catch {
                nm = "Aave Mock";
            }
            aTokens[asset] = address(new MockAToken(nm, sym, dec, address(this)));
            liquidityIndexes[asset] = 1e27;
            liquidityRates[asset] = 0;
        }
    }

    // ========================================================================
    // Aave V3 Pool Interface
    // ========================================================================

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 /* referralCode */) external {
        _ensureReserve(asset);
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        poolBalance[asset] += amount;
        MockAToken(aTokens[asset]).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        MockAToken aToken = MockAToken(aTokens[asset]);

        // Cap at caller's aToken balance
        uint256 available = aToken.balanceOf(msg.sender);
        uint256 toWithdraw = amount > available ? available : amount;

        aToken.burn(msg.sender, toWithdraw);

        // Transfer underlying — pool might need extra tokens if yield was simulated
        // (simulateYield mints extra underlying to the pool to back the rate increase)
        IERC20(asset).transfer(to, toWithdraw);

        if (poolBalance[asset] >= toWithdraw) {
            poolBalance[asset] -= toWithdraw;
        } else {
            poolBalance[asset] = 0;
        }

        return toWithdraw;
    }

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
    ) {
        return (
            0,
            liquidityIndexes[asset],
            liquidityRates[asset],
            0,
            0,
            0,
            uint40(block.timestamp),
            0,
            aTokens[asset],
            address(0),
            address(0),
            address(0),
            0,
            0,
            0
        );
    }

    // ========================================================================
    // Test Helpers — Yield Simulation
    // ========================================================================

    /**
     * @notice Simulate yield accrual on an aToken by increasing the exchange rate
     * @dev This causes all aToken holders' balanceOf to increase proportionally.
     *      Also mints extra underlying to the pool to back the increased value.
     * @param asset The underlying token
     * @param yieldBps Yield in basis points (e.g., 100 = 1%)
     */
    function simulateYield(address asset, uint256 yieldBps) external {
        MockAToken aToken = MockAToken(aTokens[asset]);
        uint256 oldRate = aToken.exchangeRate();
        uint256 newRate = (oldRate * (10_000 + yieldBps)) / 10_000;
        aToken.setExchangeRate(newRate);

        // Mint extra underlying to pool to back the yield
        uint256 oldTotal = (aToken.totalShares() * oldRate) / 1e18;
        uint256 newTotal = (aToken.totalShares() * newRate) / 1e18;
        if (newTotal > oldTotal) {
            uint256 yieldAmount = newTotal - oldTotal;
            // We need the underlying to actually exist — use deal-like approach
            // In tests, caller should deal() extra tokens to this pool address
            poolBalance[asset] += yieldAmount;
        }
    }

    /**
     * @notice Set the current liquidity rate for a token (used by currentApyBps)
     * @param asset The underlying token
     * @param rateRay Rate in ray format (1e27). E.g., 5% APY = 0.05e27
     */
    function setLiquidityRate(address asset, uint128 rateRay) external {
        liquidityRates[asset] = rateRay;
    }

    /**
     * @notice Convenience: set liquidity rate from basis points
     * @param asset The underlying token
     * @param rateBps Rate in bps (e.g., 500 = 5%)
     */
    function setLiquidityRateBps(address asset, uint256 rateBps) external {
        // Convert bps to ray: bps * 1e23
        liquidityRates[asset] = uint128(rateBps * 1e23);
    }

    /**
     * @notice Get the MockAToken for a given asset (for direct manipulation in tests)
     */
    function getMockAToken(address asset) external view returns (MockAToken) {
        return MockAToken(aTokens[asset]);
    }
}
