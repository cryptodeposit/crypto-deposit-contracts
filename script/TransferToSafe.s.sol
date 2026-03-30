// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title TransferToSafe
 * @notice Transfers DEFAULT_ADMIN_ROLE and UPGRADER_ROLE from deployer EOA to Gnosis Safe
 * @dev Run AFTER deployment. Grants roles to Safe first, then revokes from deployer.
 *      OPERATOR_ROLE stays with the operational EOA (daily ops via Ledger).
 *
 * Required env vars:
 *   DEPLOYER          - Current admin address (Ledger)
 *   SAFE              - Gnosis Safe multisig address
 *   COMPLIANCE        - ComplianceRegistry proxy
 *   TRAVEL_RULE       - TravelRuleRegistry proxy
 *   TREASURY          - Treasury proxy
 *   DISCOUNT_BILL     - DiscountBill proxy
 *   DISCOUNT_BILL_5095 - DiscountBillERC5095 proxy
 *
 * Usage (Ledger):
 *   DEPLOYER=0x... SAFE=0x... COMPLIANCE=0x... TRAVEL_RULE=0x... TREASURY=0x... \
 *   DISCOUNT_BILL=0x... DISCOUNT_BILL_5095=0x... \
 *   forge script script/TransferToSafe.s.sol:TransferToSafe \
 *     --rpc-url $RPC_URL --broadcast --ledger --hd-paths "m/44'/60'/0'/0/0"
 */
contract TransferToSafe is Script {
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address safe = vm.envAddress("SAFE");

        require(safe != address(0), "SAFE address required");
        require(safe != deployer, "SAFE must differ from DEPLOYER");

        address[5] memory contracts = [
            vm.envAddress("COMPLIANCE"),
            vm.envAddress("TRAVEL_RULE"),
            vm.envAddress("TREASURY"),
            vm.envAddress("DISCOUNT_BILL"),
            vm.envAddress("DISCOUNT_BILL_5095")
        ];

        string[5] memory names = [
            "ComplianceRegistry",
            "TravelRuleRegistry",
            "Treasury",
            "DiscountBill",
            "DiscountBillERC5095"
        ];

        vm.startBroadcast(deployer);

        // Phase 1: Grant roles to Safe
        for (uint256 i = 0; i < contracts.length; i++) {
            IAccessControl ac = IAccessControl(contracts[i]);

            // Verify deployer currently has admin
            require(ac.hasRole(DEFAULT_ADMIN_ROLE, deployer), string.concat(names[i], ": deployer not admin"));

            ac.grantRole(DEFAULT_ADMIN_ROLE, safe);
            ac.grantRole(UPGRADER_ROLE, safe);

            console.log("[GRANT] %s: admin + upgrader -> Safe", names[i]);
        }

        // Phase 2: Verify Safe has roles, then revoke from deployer
        for (uint256 i = 0; i < contracts.length; i++) {
            IAccessControl ac = IAccessControl(contracts[i]);

            require(ac.hasRole(DEFAULT_ADMIN_ROLE, safe), string.concat(names[i], ": Safe missing admin"));
            require(ac.hasRole(UPGRADER_ROLE, safe), string.concat(names[i], ": Safe missing upgrader"));

            ac.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
            ac.revokeRole(UPGRADER_ROLE, deployer);

            console.log("[REVOKE] %s: admin + upgrader revoked from deployer", names[i]);
        }

        vm.stopBroadcast();

        // Verification summary
        console.log("");
        console.log("=== ADMIN TRANSFER COMPLETE ===");
        console.log("Safe:", safe);
        console.log("Deployer:", deployer);
        console.log("");
        console.log("Roles transferred: DEFAULT_ADMIN_ROLE, UPGRADER_ROLE");
        console.log("Roles retained by deployer: OPERATOR_ROLE (daily ops)");
        console.log("");
        console.log("VERIFY: deployer should NO LONGER be able to:");
        console.log("  - Upgrade contracts");
        console.log("  - Grant/revoke roles");
        console.log("  - Change admin settings");
        console.log("");
        console.log("VERIFY: Safe CAN now:");
        console.log("  - Upgrade contracts (via multisig proposal)");
        console.log("  - Grant/revoke roles");
        console.log("  - Change admin settings");
    }
}
