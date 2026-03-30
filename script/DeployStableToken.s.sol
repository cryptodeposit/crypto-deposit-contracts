// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {StableTokenUpgradeable} from "../src/StableTokenUpgradeable.sol";
import {ComplianceRegistryUpgradeable} from "../src/ComplianceRegistryUpgradeable.sol";
import {TravelRuleRegistryUpgradeable} from "../src/TravelRuleUpgradeable.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {BillTokenFactory} from "../src/BillTokenFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";


contract DeployStableToken is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY0");
        address admin = vm.envAddress("ADDRESS0");
        address issuer = admin;

        vm.startBroadcast(deployerKey);

        address stableImpl = address(new StableTokenUpgradeable());
        address stableProxy = address(
            new ERC1967Proxy(
                stableImpl, abi.encodeCall(StableTokenUpgradeable.initialize, ("Mock USD", "mUSD", 6, 1_000_000, admin))
            )
        );

        address complianceImpl = address(new ComplianceRegistryUpgradeable());
        address complianceProxy =
            address(new ERC1967Proxy(complianceImpl, abi.encodeCall(ComplianceRegistryUpgradeable.initialize, (admin))));
        ComplianceRegistryUpgradeable compliance = ComplianceRegistryUpgradeable(complianceProxy);

        address travelImpl = address(new TravelRuleRegistryUpgradeable());
        address travelProxy =
            address(new ERC1967Proxy(travelImpl, abi.encodeCall(TravelRuleRegistryUpgradeable.initialize, (admin))));
        TravelRuleRegistryUpgradeable travel = TravelRuleRegistryUpgradeable(travelProxy);

        address depositImpl = address(new DiscountBillERC5095Upgradeable());
        address depositProxy = address(
            new ERC1967Proxy(
                depositImpl, abi.encodeCall(DiscountBillERC5095Upgradeable.initialize, (admin, issuer, compliance, travel))
            )
        );

        // Deploy BillTokenFactory and connect to bill
        BillTokenFactory billTokenFactory = new BillTokenFactory();
        DiscountBillERC5095Upgradeable(depositProxy).setBillTokenFactory(address(billTokenFactory));

        vm.stopBroadcast();

        console.log("StableToken proxy:", stableProxy);
        console.log("ComplianceRegistry proxy:", complianceProxy);
        console.log("TravelRuleRegistry proxy:", travelProxy);
        console.log("DiscountBillERC5095 (Deposit) proxy:", depositProxy);
        console.log("BillTokenFactory:", address(billTokenFactory));
        console.log("StableToken implementation:", stableImpl);
        console.log("ComplianceRegistry implementation:", complianceImpl);
        console.log("TravelRuleRegistry implementation:", travelImpl);
        console.log("DiscountBillERC5095 implementation:", depositImpl);
    }
}
