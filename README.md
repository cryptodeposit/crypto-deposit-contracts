# CryptoDeposit Contracts

Solidity smart contracts for the CryptoDeposit protocol — institutional-grade crypto deposit infrastructure built on ERC-5095 discount bills.

## Overview

CryptoDeposit enables compliant, multi-chain crypto deposits with fixed-income characteristics. Depositors receive ERC-5095 discount bills representing their deposit, redeemable at maturity for the face value.

### Core Contracts

| Contract | Description |
|----------|-------------|
| `DiscountBillERC5095Upgradeable` | ERC-5095 discount bill token (UUPS upgradeable) |
| `TreasuryUpgradeable` | Treasury management, deposit/redemption flows |
| `ComplianceRegistryUpgradeable` | Pluggable compliance adapter registry |
| `TravelRuleUpgradeable` | Travel rule data for regulatory compliance |
| `HaircutRegistryUpgradeable` | Configurable fee/haircut schedules |
| `CollateralVaultUpgradeable` | Collateral management for borrowing |
| `BorrowingEngineUpgradeable` | Over-collateralized borrowing against deposits |
| `OperatorPriceOracleUpgradeable` | Operator-set price oracle with Chainlink fallback |
| `TreasuryYieldManager` | Yield strategy management for treasury assets |

### Adapters

| Contract | Description |
|----------|-------------|
| `TreasuryFacilityAdapter` | Connects Treasury to external facility providers |
| `AaveV3StrategyAdapter` | Aave V3 yield strategy integration |
| `ChainalysisComplianceAdapter` | Chainalysis sanctions oracle adapter |
| `CompositeComplianceAdapter` | Multi-adapter compliance aggregation |

## Build

```bash
# Install dependencies
forge install

# Build
forge build

# Test
forge test

# Test with verbosity
forge test -vvv
```

## Deployments

See [`deployments/`](deployments/) for contract addresses on each chain.

## Security

This code has been deployed to production. If you discover a vulnerability, please report it responsibly to security@cryptodeposit.org.

## License

MIT — see [LICENSE](LICENSE).

Copyright (c) 2026 Basseterre Holdings Limited
