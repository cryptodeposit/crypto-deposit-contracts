// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ChainRegistry
 * @notice Registry of native USDC addresses per chain for multi-chain fork testing
 * @dev USDC addresses sourced from Circle's developer documentation.
 *      BSC uses 18 decimals (not 6) — all other chains use 6.
 */
library ChainRegistry {
    struct ChainConfig {
        string name;
        uint256 chainId;
        address usdc;
        string stablecoinSymbol;
        uint8 stablecoinDecimals;
        bool isTestnet;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Mainnets
    // ═══════════════════════════════════════════════════════════════════

    function ethereum() internal pure returns (ChainConfig memory) {
        return ChainConfig("Ethereum", 1, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "USDC", 6, false);
    }

    function polygon() internal pure returns (ChainConfig memory) {
        return ChainConfig("Polygon", 137, 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359, "USDC", 6, false);
    }

    function arbitrum() internal pure returns (ChainConfig memory) {
        return ChainConfig("Arbitrum", 42161, 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, "USDC", 6, false);
    }

    function base() internal pure returns (ChainConfig memory) {
        return ChainConfig("Base", 8453, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, "USDC", 6, false);
    }

    function optimism() internal pure returns (ChainConfig memory) {
        return ChainConfig("Optimism", 10, 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85, "USDC", 6, false);
    }

    function bsc() internal pure returns (ChainConfig memory) {
        // BSC USDC uses 18 decimals, not 6
        return ChainConfig("BSC", 56, 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d, "USDC", 18, false);
    }

    function avalanche() internal pure returns (ChainConfig memory) {
        return ChainConfig("Avalanche", 43114, 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, "USDC", 6, false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Testnets
    // ═══════════════════════════════════════════════════════════════════

    function sepolia() internal pure returns (ChainConfig memory) {
        return ChainConfig("Sepolia", 11155111, 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, "USDC", 6, true);
    }

    function arbitrumSepolia() internal pure returns (ChainConfig memory) {
        return ChainConfig("Arbitrum Sepolia", 421614, 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d, "USDC", 6, true);
    }

    function baseSepolia() internal pure returns (ChainConfig memory) {
        return ChainConfig("Base Sepolia", 84532, 0x036CbD53842c5426634e7929541eC2318f3dCF7e, "USDC", 6, true);
    }

    function optimismSepolia() internal pure returns (ChainConfig memory) {
        return ChainConfig("Optimism Sepolia", 11155420, 0x5fd84259d66Cd46123540766Be93DFE6D43130D7, "USDC", 6, true);
    }

    function polygonAmoy() internal pure returns (ChainConfig memory) {
        return ChainConfig("Polygon Amoy", 80002, 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582, "USDC", 6, true);
    }

    function bscTestnet() internal pure returns (ChainConfig memory) {
        return ChainConfig("BSC Testnet", 97, 0x64544969ed7EBf5f083679233325356EbE738930, "USDC", 18, true);
    }
}
