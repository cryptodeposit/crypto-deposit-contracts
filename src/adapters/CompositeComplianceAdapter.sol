// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";

/// @title CompositeComplianceAdapter
/// @notice Chains multiple IComplianceRegistry sources. An address must pass ALL
///         checks to be allowed. Use this to combine Chainalysis + internal blocklist.
contract CompositeComplianceAdapter is IComplianceRegistry, Ownable {
    IComplianceRegistry[] public registries;

    event RegistryAdded(address indexed registry);
    event RegistryRemoved(address indexed registry);

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Returns true only if ALL registries allow the account
    function isAllowed(address account) external view override returns (bool) {
        uint256 len = registries.length;
        for (uint256 i = 0; i < len; i++) {
            if (!registries[i].isAllowed(account)) {
                return false;
            }
        }
        return true;
    }

    function addRegistry(address registry) external onlyOwner {
        require(registry != address(0), "registry=0");
        registries.push(IComplianceRegistry(registry));
        emit RegistryAdded(registry);
    }

    function removeRegistry(uint256 index) external onlyOwner {
        uint256 len = registries.length;
        require(index < len, "index out of bounds");
        address removed = address(registries[index]);
        registries[index] = registries[len - 1];
        registries.pop();
        emit RegistryRemoved(removed);
    }

    function registryCount() external view returns (uint256) {
        return registries.length;
    }
}
