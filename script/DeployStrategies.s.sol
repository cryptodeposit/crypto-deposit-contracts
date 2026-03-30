// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3StrategyAdapter} from "../src/adapters/AaveV3StrategyAdapter.sol";
import {TreasuryFacilityAdapter} from "../src/adapters/TreasuryFacilityAdapter.sol";

/**
 * @title MockAaveV3Pool
 * @notice Minimal mock for Aave V3 Pool — supports supply/withdraw for local testing.
 *         Does NOT generate real yield; currentValue == totalDeployed.
 */
contract MockAaveV3Pool {
    // token => user => balance (simulating aToken balances)
    mapping(address => mapping(address => uint256)) public balances;
    // token => MockAToken address
    mapping(address => address) public aTokens;

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 /* referralCode */) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        balances[asset][onBehalfOf] += amount;

        // Ensure aToken exists
        if (aTokens[asset] == address(0)) {
            aTokens[asset] = address(new MockAToken(asset, address(this)));
        }
        MockAToken(aTokens[asset]).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        // Burn aTokens from caller
        MockAToken(aTokens[asset]).burn(msg.sender, amount);
        balances[asset][msg.sender] -= amount;
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function getReserveData(address asset) external view returns (
        uint256, uint128, uint128, uint128, uint128, uint128,
        uint40, uint16, address, address, address, address, uint128, uint128, uint128
    ) {
        return (0, 0, 0, 0, 0, 0, 0, 0, aTokens[asset], address(0), address(0), address(0), 0, 0, 0);
    }

    /// @notice Pre-create an aToken for a given asset so getReserveData works
    function initReserve(address asset) external {
        if (aTokens[asset] == address(0)) {
            aTokens[asset] = address(new MockAToken(asset, address(this)));
        }
    }
}

/**
 * @title MockAToken
 * @notice Minimal aToken mock — tracks balances for currentValue() reads
 */
contract MockAToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    address public pool;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address /* asset */, address pool_) {
        pool = pool_;
        decimals = 18; // Simplified
        name = "Mock aToken";
        symbol = "aMOCK";
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

/**
 * @title DeployStrategies
 * @notice Deploys MockAaveV3Pool + AaveV3StrategyAdapter + TreasuryFacilityAdapter
 *         and registers both strategies with the Treasury.
 *
 * Usage:
 *   forge script script/DeployStrategies.s.sol:DeployStrategies --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY0 \
 *     --sig "run(address,address)" $TREASURY $MUSD_TOKEN
 */
contract DeployStrategies is Script {

    function run(
        address treasury,
        address musdToken
    ) external returns (address mockPool, address aaveAdapter, address facilityAdapter) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY0");
        address admin = vm.envAddress("ADDRESS0");

        vm.startBroadcast(deployerKey);

        // 1. Deploy MockAaveV3Pool
        mockPool = address(new MockAaveV3Pool());
        // Initialize mUSD reserve so getReserveData returns a valid aToken
        MockAaveV3Pool(mockPool).initReserve(musdToken);

        // 2. Deploy AaveV3StrategyAdapter
        aaveAdapter = address(new AaveV3StrategyAdapter(admin, mockPool));
        // Register mUSD as supported
        AaveV3StrategyAdapter(aaveAdapter).addSupportedToken(musdToken);

        // 3. Deploy TreasuryFacilityAdapter (custody = admin for local testing)
        facilityAdapter = address(new TreasuryFacilityAdapter(admin, admin));
        // Register mUSD as supported
        TreasuryFacilityAdapter(facilityAdapter).addSupportedToken(musdToken);

        // 4. Register both strategies with Treasury
        // Treasury.registerStrategy() needs DEFAULT_ADMIN_ROLE (admin has it)
        (bool ok1,) = treasury.call(
            abi.encodeWithSignature("registerStrategy(address)", aaveAdapter)
        );
        require(ok1, "Failed to register Aave strategy");

        (bool ok2,) = treasury.call(
            abi.encodeWithSignature("registerStrategy(address)", facilityAdapter)
        );
        require(ok2, "Failed to register Facility strategy");

        // 5. Grant TREASURY_ROLE to the Treasury contract on both adapters
        bytes32 TREASURY_ROLE = keccak256("TREASURY_ROLE");
        AaveV3StrategyAdapter(aaveAdapter).grantRole(TREASURY_ROLE, treasury);
        TreasuryFacilityAdapter(facilityAdapter).grantRole(TREASURY_ROLE, treasury);

        vm.stopBroadcast();

        // Output
        console.log("");
        console.log("=== STRATEGY DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("MockAaveV3Pool:", mockPool);
        console.log("AaveV3StrategyAdapter:", aaveAdapter);
        console.log("  name: Aave V3");
        console.log("  isLiquid: true");
        console.log("TreasuryFacilityAdapter:", facilityAdapter);
        console.log("  name: Treasury Facility");
        console.log("  isLiquid: false");
        console.log("  custody:", admin);
        console.log("");
        console.log("Both registered with Treasury:", treasury);
        console.log("");

        return (mockPool, aaveAdapter, facilityAdapter);
    }
}
