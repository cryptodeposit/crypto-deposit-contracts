// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IComplianceRegistry {
    function isAllowed(address account) external view returns (bool);
}

