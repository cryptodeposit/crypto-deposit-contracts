// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {IChainalysisSanctionsOracle} from "../interfaces/IChainalysisSanctionsOracle.sol";

/// @title ChainalysisComplianceAdapter
/// @notice Adapts the Chainalysis free sanctions oracle to the IComplianceRegistry interface.
///         isSanctioned(addr) == true  =>  isAllowed(addr) == false
contract ChainalysisComplianceAdapter is IComplianceRegistry, Ownable {
    IChainalysisSanctionsOracle public oracle;

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    constructor(address oracle_, address owner_) Ownable(owner_) {
        require(oracle_ != address(0), "oracle=0");
        oracle = IChainalysisSanctionsOracle(oracle_);
    }

    /// @notice Returns true if the account is NOT sanctioned by Chainalysis
    function isAllowed(address account) external view override returns (bool) {
        return !oracle.isSanctioned(account);
    }

    /// @notice Update the oracle address (e.g. if Chainalysis deploys a new version)
    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "oracle=0");
        address old = address(oracle);
        oracle = IChainalysisSanctionsOracle(newOracle);
        emit OracleUpdated(old, newOracle);
    }
}
