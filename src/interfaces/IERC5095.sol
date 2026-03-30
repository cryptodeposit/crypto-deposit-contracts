// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC5095 is IERC20 {
    function underlying() external view returns (address);

    function maturity() external view returns (uint256);

    function maxRedeem(address owner) external view returns (uint256);

    function previewRedeem(uint256 amount) external view returns (uint256);

    function redeem(uint256 amount, address receiver, address owner) external returns (uint256);
}
