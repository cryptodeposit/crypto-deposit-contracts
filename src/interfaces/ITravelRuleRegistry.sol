// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITravelRuleRegistry {
    function isCompliant(address token, address from, address to, uint256 amount) external view returns (bool);
    function consume(address token, address from, address to, uint256 amount) external;
}

