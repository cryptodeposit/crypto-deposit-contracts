// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HaircutRegistryUpgradeable} from "../src/HaircutRegistryUpgradeable.sol";
import {IHaircutRegistry} from "../src/interfaces/IHaircutRegistry.sol";

contract HaircutRegistryUpgradeableTest is Test {
    HaircutRegistryUpgradeable private registry;
    address private admin = makeAddr("admin");
    address private operator_ = makeAddr("operator");
    address private attacker = makeAddr("attacker");

    address private wbtc = makeAddr("WBTC");
    address private usdc = makeAddr("USDC");

    event HaircutUpdated(address indexed token, IHaircutRegistry.HaircutConfig config, address indexed updatedBy);
    event AssetEnabled(address indexed token, address indexed enabledBy);
    event AssetDisabled(address indexed token, address indexed disabledBy);

    function setUp() public {
        HaircutRegistryUpgradeable impl = new HaircutRegistryUpgradeable();
        registry = HaircutRegistryUpgradeable(
            address(
                new ERC1967Proxy(address(impl), abi.encodeCall(HaircutRegistryUpgradeable.initialize, (admin)))
            )
        );

        // Grant operator role
        bytes32 operatorRole = registry.OPERATOR_ROLE();
        vm.prank(admin);
        registry.grantRole(operatorRole, operator_);
    }

    function testInitializeGrantsRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.OPERATOR_ROLE(), admin));
        assertTrue(registry.hasRole(registry.POLICY_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.UPGRADER_ROLE(), admin));
    }

    function testSetHaircutRequiresOperator() public {
        IHaircutRegistry.HaircutConfig memory config = IHaircutRegistry.HaircutConfig({
            collateralHaircutBps: 3000,
            borrowHaircutBps: 1000,
            maxLtvBps: 6500,
            liquidationThresholdBps: 7500,
            enabled: true
        });

        bytes32 operatorRole = registry.OPERATOR_ROLE();
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, operatorRole)
        );
        registry.setHaircut(wbtc, config);
    }

    function testSetAndGetHaircut() public {
        IHaircutRegistry.HaircutConfig memory config = IHaircutRegistry.HaircutConfig({
            collateralHaircutBps: 3000,  // 30%
            borrowHaircutBps: 1000,      // 10%
            maxLtvBps: 6500,             // 65%
            liquidationThresholdBps: 7500, // 75%
            enabled: true
        });

        vm.prank(operator_);
        registry.setHaircut(wbtc, config);

        IHaircutRegistry.HaircutConfig memory stored = registry.getHaircut(wbtc);
        assertEq(stored.collateralHaircutBps, 3000);
        assertEq(stored.borrowHaircutBps, 1000);
        assertEq(stored.maxLtvBps, 6500);
        assertEq(stored.liquidationThresholdBps, 7500);
        assertTrue(stored.enabled);
    }

    function testEffectiveCollateralValue() public {
        IHaircutRegistry.HaircutConfig memory config = IHaircutRegistry.HaircutConfig({
            collateralHaircutBps: 3000,
            borrowHaircutBps: 1000,
            maxLtvBps: 6500,
            liquidationThresholdBps: 7500,
            enabled: true
        });

        vm.prank(operator_);
        registry.setHaircut(wbtc, config);

        // 1 BTC (1e8 sats) at $65,000 (65000e8 in oracle format)
        // Effective = 1e8 * 65000e8 * (10000 - 3000) / (10000 * 1e8)
        // = 1e8 * 65000e8 * 7000 / (10000 * 1e8)
        // = 45500e8 (= $45,500)
        uint256 effective = registry.getEffectiveCollateralValue(wbtc, 1e8, 65000e8);
        assertEq(effective, 45500e8);
    }

    function testStablecoinLowHaircut() public {
        IHaircutRegistry.HaircutConfig memory config = IHaircutRegistry.HaircutConfig({
            collateralHaircutBps: 500,   // 5%
            borrowHaircutBps: 200,
            maxLtvBps: 9000,
            liquidationThresholdBps: 9500,
            enabled: true
        });

        vm.prank(operator_);
        registry.setHaircut(usdc, config);

        // 100,000 USDC (100000e6) at $1.00 (1e8)
        // Effective = 100000e6 * 1e8 * 9500 / (10000 * 1e8) = 95000e6
        uint256 effective = registry.getEffectiveCollateralValue(usdc, 100000e6, 1e8);
        assertEq(effective, 95000e6);
    }

    function testValidationLiquidationMustExceedMaxLtv() public {
        IHaircutRegistry.HaircutConfig memory bad = IHaircutRegistry.HaircutConfig({
            collateralHaircutBps: 3000,
            borrowHaircutBps: 1000,
            maxLtvBps: 8000,                // 80%
            liquidationThresholdBps: 7000,  // 70% < maxLTV - invalid!
            enabled: true
        });

        vm.prank(operator_);
        vm.expectRevert(bytes("liquidation threshold must exceed maxLTV"));
        registry.setHaircut(wbtc, bad);
    }

    function testBatchHaircuts() public {
        address[] memory tokens = new address[](2);
        tokens[0] = wbtc;
        tokens[1] = usdc;

        IHaircutRegistry.HaircutConfig[] memory configs = new IHaircutRegistry.HaircutConfig[](2);
        configs[0] = IHaircutRegistry.HaircutConfig(3000, 1000, 6500, 7500, true);
        configs[1] = IHaircutRegistry.HaircutConfig(500, 200, 9000, 9500, true);

        vm.prank(operator_);
        registry.setBatchHaircuts(tokens, configs);

        assertTrue(registry.isAcceptedCollateral(wbtc));
        assertTrue(registry.isAcceptedCollateral(usdc));

        address[] memory registered = registry.getRegisteredTokens();
        assertEq(registered.length, 2);
    }

    function testDisableAsset() public {
        IHaircutRegistry.HaircutConfig memory config = IHaircutRegistry.HaircutConfig(3000, 1000, 6500, 7500, true);
        vm.prank(operator_);
        registry.setHaircut(wbtc, config);
        assertTrue(registry.isAcceptedCollateral(wbtc));

        vm.prank(admin);
        registry.disableAsset(wbtc);
        assertFalse(registry.isAcceptedCollateral(wbtc));
    }

    function testDisabledAssetRevertsOnEffectiveValue() public {
        IHaircutRegistry.HaircutConfig memory config = IHaircutRegistry.HaircutConfig(3000, 1000, 6500, 7500, false);
        vm.prank(operator_);
        registry.setHaircut(wbtc, config);

        vm.expectRevert(bytes("asset not accepted"));
        registry.getEffectiveCollateralValue(wbtc, 1e8, 65000e8);
    }

    // ========== DIGITAL TWIN GETTER TESTS ==========

    function testIsTokenRegistered() public {
        assertFalse(registry.isTokenRegistered(wbtc));

        IHaircutRegistry.HaircutConfig memory config = IHaircutRegistry.HaircutConfig(3000, 500, 7000, 7500, true);
        vm.prank(operator_);
        registry.setHaircut(wbtc, config);

        assertTrue(registry.isTokenRegistered(wbtc));
        assertFalse(registry.isTokenRegistered(usdc));
    }

    function testIsTokenRegisteredConsistentWithGetRegisteredTokens() public {
        IHaircutRegistry.HaircutConfig memory config = IHaircutRegistry.HaircutConfig(3000, 500, 7000, 7500, true);
        vm.startPrank(operator_);
        registry.setHaircut(wbtc, config);
        registry.setHaircut(usdc, IHaircutRegistry.HaircutConfig(500, 0, 9000, 9250, true));
        vm.stopPrank();

        address[] memory tokens = registry.getRegisteredTokens();
        assertEq(tokens.length, 2);
        for (uint256 i = 0; i < tokens.length; i++) {
            assertTrue(registry.isTokenRegistered(tokens[i]));
        }
    }
}
