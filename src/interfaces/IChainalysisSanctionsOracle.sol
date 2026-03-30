// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChainalysisSanctionsOracle
/// @notice Minimal interface for the Chainalysis free sanctions oracle
/// @dev Mainnet: 0x40C57923924B5c5c5455c48D93317139ADDaC8fb
interface IChainalysisSanctionsOracle {
    function isSanctioned(address addr) external view returns (bool);
}
