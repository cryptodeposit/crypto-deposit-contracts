// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interfaces/IComplianceRegistry.sol";

contract ComplianceRegistryUpgradeable is Initializable, AccessControlUpgradeable, UUPSUpgradeable, IComplianceRegistry {
    bytes32 public constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    mapping(address => bool) private _blocked; // true => blocked

    event BlockStatusSet(address indexed account, bool blocked, address indexed by);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }
    function initialize(address admin) public initializer {
        require(admin != address(0), "admin=0");
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    function isAllowed(address account) external view override returns (bool) {
        return !_blocked[account];
    }

    function setBlocked(address account, bool blocked) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _blocked[account] = blocked;
        emit BlockStatusSet(account, blocked, msg.sender);
    }

    function setBlockedBatch(address[] calldata accounts, bool blocked) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            _blocked[accounts[i]] = blocked;
            emit BlockStatusSet(accounts[i], blocked, msg.sender);
        }
    }

    /// @dev Reserved storage space for future upgrades
    uint256[49] private __gap;
}
