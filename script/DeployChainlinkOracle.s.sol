// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ChainlinkFallbackOracleUpgradeable} from "../src/ChainlinkFallbackOracleUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployChainlinkOracle
 * @notice Deploys ChainlinkFallbackOracleUpgradeable and optionally swaps it into consumers
 * @dev Requires the existing OperatorPriceOracle to be deployed.
 *
 * Environment variables:
 *   PRIVATE_KEY0     — deployer private key
 *   ADDRESS0         — deployer/admin address
 *   OPERATOR_ORACLE  — existing OperatorPriceOracleUpgradeable proxy address
 *   DEVIATION_BPS    — (optional) deviation threshold, default 500 (5%)
 *
 * Post-deployment:
 *   1. Call setFeed(token, chainlinkFeedAddress, stalenessSeconds) for each token
 *   2. Call setPriceOracle(newOracleAddress) on CollateralVault, BorrowingEngine, LiquidationManager
 *
 * Usage:
 *   PRIVATE_KEY0=... ADDRESS0=... OPERATOR_ORACLE=0x... \
 *   forge script script/DeployChainlinkOracle.s.sol:DeployChainlinkOracle \
 *     --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY0
 */
contract DeployChainlinkOracle is Script {
    function run() external {
        address admin = vm.envAddress("ADDRESS0");
        address operatorOracle = vm.envAddress("OPERATOR_ORACLE");
        uint256 deviationBps = vm.envOr("DEVIATION_BPS", uint256(500));

        vm.startBroadcast();

        // Deploy implementation
        ChainlinkFallbackOracleUpgradeable impl = new ChainlinkFallbackOracleUpgradeable();

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ChainlinkFallbackOracleUpgradeable.initialize,
                (admin, operatorOracle, deviationBps)
            )
        );

        ChainlinkFallbackOracleUpgradeable oracle = ChainlinkFallbackOracleUpgradeable(address(proxy));

        vm.stopBroadcast();

        console.log("=== ChainlinkFallbackOracle Deployed ===");
        console.log("Implementation:", address(impl));
        console.log("Proxy:         ", address(proxy));
        console.log("Admin:         ", admin);
        console.log("Operator Oracle:", operatorOracle);
        console.log("Deviation BPS: ", oracle.deviationThresholdBps());
        console.log("");
        console.log("Next steps:");
        console.log("  1. setFeed(token, chainlinkFeed, staleness) for each token");
        console.log("  2. setPriceOracle(proxy) on CollateralVault, BorrowingEngine, LiquidationManager");
    }
}
