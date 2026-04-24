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

**Audit status.** A formal third-party security audit is planned and has
**not yet been completed**. Deployments exist on testnet and mainnet but
should be treated as pre-audit code. Production value should not be
committed without an independent audit.

In the interim we publish:

- [`security/SECURITY_REVIEW.md`](security/SECURITY_REVIEW.md) — a detailed
  AI-assisted self-review covering architecture, trust model, access
  control, upgrade safety, reentrancy, integer math, oracle risk, and
  economic risks. Explicitly **not** a substitute for a professional audit.
- [`security/SLITHER.md`](security/SLITHER.md) — triaged Slither v0.11.3
  output. 43 findings reviewed; 0 represent real vulnerabilities in our
  code (all High/Medium findings are OpenZeppelin library false
  positives or upgradeable-storage pattern mismatches, enumerated in the
  document).
- [`security/slither.json`](security/slither.json) — raw Slither output
  for reproducibility.

### Reproducing the Slither run locally

```bash
conda activate slither-env
cd /path/to/crypto-deposit-contracts
forge install
slither . --compile-force-framework forge --exclude-informational --exclude-low
```

Pinned tool version: `slither-analyzer==0.11.3`. Any Slither release can be
installed via `pip install slither-analyzer==0.11.3` inside the conda env.
Re-running with a different Slither version may surface additional
findings; please re-triage against `security/SLITHER.md` before reporting.

**Disclosure.** If you discover a vulnerability, please report it
responsibly to security@cryptodeposit.org.

## License

MIT — see [LICENSE](LICENSE).

Copyright (c) 2026 Basseterre Holdings Limited
