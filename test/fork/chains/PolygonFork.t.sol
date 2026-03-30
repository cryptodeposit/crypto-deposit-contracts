// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseMultiChainForkTest} from "../BaseMultiChainForkTest.sol";
import {ChainRegistry} from "../ChainRegistry.sol";

contract PolygonForkTest is BaseMultiChainForkTest {
    function _getChainConfig() internal pure override returns (ChainRegistry.ChainConfig memory) {
        return ChainRegistry.polygon();
    }
}
