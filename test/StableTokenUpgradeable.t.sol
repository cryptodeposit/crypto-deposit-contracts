// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StableTokenUpgradeable} from "../src/StableTokenUpgradeable.sol";

contract StableTokenUpgradeableV2 is StableTokenUpgradeable {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract StableTokenUpgradeableTest is Test {
    StableTokenUpgradeable private token;

    address private owner = makeAddr("owner");
    address private user = makeAddr("user");
    address private recipient = makeAddr("recipient");

    uint256 private constant UNIT = 1e6; // 10**decimals

    function setUp() public {
        StableTokenUpgradeable impl = new StableTokenUpgradeable();
        token = StableTokenUpgradeable(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(StableTokenUpgradeable.initialize, ("Stable USD", "SUSD", 6, 1_000, owner))
                )
            )
        );
    }

    function testInitializeSetsStateAndRoles() public view {
        assertEq(token.name(), "Stable USD");
        assertEq(token.symbol(), "SUSD");
        assertEq(token.decimals(), 6);
        assertEq(token.owner(), owner);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(token.hasRole(token.MINTER_ROLE(), owner));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), owner));
        assertTrue(token.hasRole(token.BLACKLISTER_ROLE(), owner));
        assertTrue(token.hasRole(token.UPGRADER_ROLE(), owner));
        assertEq(token.totalSupply(), 1_000 * UNIT);
        assertEq(token.balanceOf(owner), 1_000 * UNIT);
    }

    function testMintAndRedeemRestrictedToMinter() public {
        uint256 startingSupply = token.totalSupply();

        vm.expectRevert();
        vm.prank(user);
        token.mint(2 * UNIT);

        vm.prank(owner);
        token.mint(2 * UNIT);
        assertEq(token.balanceOf(owner), startingSupply + 2 * UNIT);
        assertEq(token.totalSupply(), startingSupply + 2 * UNIT);

        vm.prank(owner);
        token.redeem(UNIT);
        assertEq(token.balanceOf(owner), startingSupply + UNIT);
        assertEq(token.totalSupply(), startingSupply + UNIT);
    }

    function testPauseAndUnpauseGatesTransfers() public {
        vm.prank(owner);
        token.pause();

        vm.expectRevert();
        vm.prank(owner);
        token.transfer(recipient, UNIT);

        vm.prank(owner);
        token.unpause();
        vm.prank(owner);
        token.transfer(recipient, UNIT);

        assertEq(token.balanceOf(recipient), UNIT);
    }

    function testBlacklistBlocksTransfersUntilRemoved() public {
        vm.prank(owner);
        token.addBlacklist(recipient);

        vm.expectRevert(bytes("Recipient blacklisted"));
        vm.prank(owner);
        token.transfer(recipient, UNIT);

        vm.prank(owner);
        token.removeBlacklist(recipient);
        vm.prank(owner);
        token.transfer(recipient, UNIT);

        assertEq(token.balanceOf(recipient), UNIT);
    }

    function testUpgradeRestrictedToUpgraderRole() public {
        StableTokenUpgradeableV2 newImpl = new StableTokenUpgradeableV2();

        vm.expectRevert();
        vm.prank(user);
        token.upgradeToAndCall(address(newImpl), bytes(""));

        vm.prank(owner);
        token.upgradeToAndCall(address(newImpl), bytes(""));
        assertEq(StableTokenUpgradeableV2(address(token)).version(), "v2");
    }
}
