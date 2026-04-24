# Security review (interim, pre-audit)

**Status:** Interim self-review. **Not** a professional audit.
**Date:** 2026-04-24
**Commit:** see `git log -1` on the HEAD of `main`
**Reviewer:** Claude (Anthropic, automated assistant) + repository owner

---

## Disclaimer

This document is a structured self-review produced with AI assistance. It is
**not**, and **must not be represented as**, a professional third-party
security audit. A formal audit by a named specialist firm is planned and
required before any production deployment carrying non-trivial value that
has not already been deployed.

Reviewers and depositors should treat this document as:

- a **map of the design surface**, intended to orient auditors and
  sophisticated users;
- an **inventory of known assumptions and trust boundaries**;
- a **triage of automated static-analysis output** (see `SLITHER.md`);

and not as a substitute for:

- adversarial manual review by experienced auditors;
- symbolic execution / formal verification;
- economic-model analysis for a live mainnet book.

Any statement in this document framed as "safe" or "mitigated" is
conditional on the code actually matching the invariants stated, on the
upstream libraries (OpenZeppelin v5) being themselves correctly implemented,
and on off-chain operational security (key custody, oracle-poster keys,
upgrader keys) being maintained per the published policy.

---

## Scope

| Category | Contracts |
|----------|-----------|
| Deposit product | `DiscountBillCore`, `DiscountBillStorage`, `DiscountBillLifecycle`, `DiscountBillCampaigns`, `DiscountBillERC5095Upgradeable`, `BillTokenFactory`, `DiscountBillBatchHelper` |
| Treasury | `TreasuryUpgradeable`, `TreasuryYieldManager` |
| Collateral & lending | `CollateralVaultUpgradeable`, `BorrowingEngineUpgradeable`, `LiquidationManagerUpgradeable`, `HaircutRegistryUpgradeable`, `OperatorPriceOracleUpgradeable`, `ChainlinkFallbackOracleUpgradeable` |
| Compliance | `ComplianceRegistryUpgradeable`, `TravelRuleUpgradeable` |
| Stablecoins (internal testnet) | `StableTokenUpgradeable` |
| Strategy adapters | `AaveV3YieldManager`, `adapters/AaveV3StrategyAdapter`, `adapters/ChainalysisComplianceAdapter`, `adapters/CompositeComplianceAdapter`, `adapters/TreasuryFacilityAdapter` |

Out of scope:
- All OpenZeppelin contracts under `lib/`. Any Slither finding that
  originates in an OZ file is triaged as a library false positive (see
  `SLITHER.md`).
- Off-chain components — rate_server (C++), event indexer, admin dashboard,
  AWS KMS issuer key plumbing. Those are reviewed separately.

---

## Architecture overview (one-page)

CryptoDeposit is a **fixed-term, stablecoin-denominated deposit protocol**.
A depositor deposits an ERC-20 stablecoin and receives an **ERC-721 /
ERC-5095** "DepositBill" NFT recording principal, issuance time, maturity,
and a deterministic redemption value. At maturity, the holder calls
`redeem()` and the Treasury pays out.

Separately, a **borrowing engine** allows addresses to post collateral
(stablecoins or DepositBill NFTs) to the `CollateralVault` and borrow
stablecoins from the `BorrowingEngine`. Health factor, LTV, liquidation
threshold, and per-asset haircuts are maintained by the
`HaircutRegistry`; liquidations are executed by the `LiquidationManager`.

Prices come from an `OperatorPriceOracle` (operator-pushed) with a
`ChainlinkFallbackOracle` when available for the asset.

Same-chain only. No cross-chain bridges in the trust path. Each chain runs
its own full deployment; chains are **not** linked at the contract level.

---

## Trust model

| Role | Powers | Held by |
|------|--------|---------|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke all other roles, set critical links (compliance, travel rule, treasury, oracle) | Hardware-wallet (Ledger) only in production |
| `UPGRADER_ROLE` | UUPS `upgradeToAndCall` on every upgradeable proxy | Same Ledger as DEFAULT_ADMIN |
| `ISSUER_ROLE` | `issue()` new DepositBills — mint + take custody of principal | AWS KMS-backed operator key (rate_server) |
| `OPERATOR_ROLE` | `issue()` loans, push prices, add borrow liquidity, update haircuts | KMS operator key |
| `DEPOSIT_MANAGER_ROLE` | Record deposits on Treasury, mark redemption paid | KMS operator key |
| `TREASURY_ROLE` | Register / configure strategies on Treasury | DEFAULT_ADMIN (separated grant) |
| `LENDING_MANAGER_ROLE` | Withdraw collateral on behalf of borrower during repay | BorrowingEngine contract itself (granted by admin) |
| `LIQUIDATOR_ROLE` | Trigger liquidation on under-collateralised loan | LiquidationManager contract (granted by admin) |
| `COLLATERAL_MANAGER_ROLE` | Seize collateral during liquidation | LiquidationManager contract |
| `PAUSER_ROLE` | Pause `issue()` and other user-facing entry points | DEFAULT_ADMIN |
| `BLACKLISTER_ROLE` | Mark addresses unable to transact | Compliance ops |
| `COMPLIANCE_ADMIN_ROLE` | Configure jurisdiction / KYC policy | Compliance ops |
| `ORDERING_ROLE`, `INTERMEDIARY_ROLE`, `BENEFICIARY_ROLE` | Travel Rule infrastructure (register & verify) | VASP integrators |
| `POLICY_ADMIN_ROLE` | Update risk / policy parameters | DEFAULT_ADMIN |
| `MINTER_ROLE` | Mint internal `StableTokenUpgradeable` supply | Testnet-only — never granted in mainnet deployment |

**Key invariants the trust model relies on:**

1. `DEFAULT_ADMIN_ROLE` on every proxy is held by a cold hardware wallet.
2. `UPGRADER_ROLE` matches `DEFAULT_ADMIN_ROLE` holder; **there is no
   automated upgrade path**.
3. `ISSUER_ROLE` / `OPERATOR_ROLE` keys used by the rate_server are
   AWS KMS-managed; the private key bytes never leave KMS. The rate_server
   only requests *signed messages* per request.
4. The operator-push oracle is trusted within bounded staleness (300s
   default); the ChainlinkFallbackOracle is consulted when configured and
   preferred on disagreement beyond a tolerance. Any borrower-facing
   action reverts if no price source is fresh.
5. Each chain is independent. Compromise of one chain's admin key **does
   not** grant powers on another chain. Same-chain backing means a
   compromised chain cannot drain a healthy chain's Treasury.

Departures from these invariants are operational incidents and must be
treated as such (rotate, revoke, pause, disclose).

---

## Access-control observations

- **16 named roles** across the suite. Every externally mutating function
  that was inspected is guarded by either `onlyRole(...)` or a
  caller-is-self / caller-is-owner check. No function that mutates
  depositor assets was found without a role guard.
- **UUPS authorisation**: every upgradeable contract implements
  `_authorizeUpgrade(...) internal override onlyRole(UPGRADER_ROLE)`.
  Confirmed across `DiscountBill*`, `Treasury`, `CollateralVault`,
  `BorrowingEngine`, `LiquidationManager`, `HaircutRegistry`,
  `OperatorPriceOracle`, `ChainlinkFallbackOracle`, `ComplianceRegistry`,
  `TravelRule`, `StableToken`.
- **Role granularity observation**: the rate_server wallet holds several
  operational roles simultaneously (`ISSUER_ROLE`, `OPERATOR_ROLE`,
  `DEPOSIT_MANAGER_ROLE`). Compromise of that single key compromises
  deposit issuance and oracle price pushing. Mitigation today: the key is
  AWS KMS-custodied and never exported; every signing request is
  authenticated and rate-limited at the KMS layer. A formal audit should
  consider whether the operator and oracle-poster roles should be split
  across two separate keys.
- **No default admin key is the same as any operator key** in the
  deployment config under `deployments/`. Separation of cold (admin/upgrader)
  and warm (operator) keys is a deliberate architectural choice.

---

## Upgrade safety

All user-facing contracts use the UUPS (ERC-1967) pattern via OpenZeppelin
`UUPSUpgradeable`. Implementation of `_authorizeUpgrade` is uniformly
`onlyRole(UPGRADER_ROLE)`.

Observations:

- **Storage layout discipline.** `DiscountBillStorage` and the `storage_`
  contracts for each upgradeable use the "storage contract" pattern: all
  state lives on one contract inherited first in the inheritance chain.
  This is the idiomatic OZ pattern for safe upgrades. Any change that
  reorders or inserts storage slots *before* existing ones will break
  the upgrade; no such change is permitted without an explicit
  `hardhat-storage-layout` / `forge inspect` diff review.
- **Initializer guards.** Every upgradeable contract declares an
  `initialize(...)` function gated by OZ `initializer` / `reinitializer`
  modifier, and the constructor calls `_disableInitializers()`. Verified
  on spot inspection.
- **Reinitialization risk.** When a contract is upgraded in a way that
  introduces new state, `reinitializer(N)` with a monotonically
  increasing N is used. No upgrades currently rely on `reinitializer`;
  the first upgrade that does so needs special attention.
- **Proxy admin.** Since UUPS embeds the upgrade logic in the
  implementation, there is no separate ProxyAdmin. The only way to
  "lock" a proxy is to renounce `UPGRADER_ROLE` — this is **not done
  currently** because the contracts are pre-audit.

---

## Reentrancy

- All state-mutating external functions that move tokens are marked
  `nonReentrant` (OZ `ReentrancyGuardUpgradeable`). Spot checks:
  - `BorrowingEngine.borrow / repay / addLiquidity / removeLiquidity / liquidateRepay / accrueInterest`
  - `CollateralVault.depositCollateral / depositBill / withdrawCollateral / withdrawBill`
  - `DiscountBill.issue / redeem / transferFrom / merge`
  - `Treasury.registerDeposit / markRedemptionPaid / deployToStrategy / withdrawFromStrategy / captureYield`
- **External calls ordering.** CEI (checks-effects-interactions) is
  followed in the critical paths. A formal audit should verify the bill
  redemption path end-to-end — it crosses Treasury ↔ DiscountBill ↔
  ERC-20 transfer — because reentrancy guards are local per contract but
  the redemption chain spans three of them.
- **ERC-777 / transfer-hook callbacks.** None of the supported assets
  (USDC, USDT, USDbC, DAI, FRAX, mUSD) implement ERC-777 hooks. If an
  asset with transfer hooks is ever added, the collateral deposit and
  loan disbursement paths would need re-review.

---

## Integer math

- Solidity 0.8.x default overflow/underflow checks are in effect
  throughout. No `unchecked {}` blocks were found outside OpenZeppelin
  Math internals.
- Fixed-point arithmetic (haircut BPS, LTV BPS, interest rate BPS) uses
  the standard `amount * bps / 10_000` pattern. The order —
  multiplication before division — is consistent and avoids truncation
  in all inspected call sites.
- **Slither `divide-before-multiply`** findings: all 9 occurrences are
  inside `OpenZeppelin Math.mulDiv`, the canonical 512-bit multiply-divide
  routine. False positives (see `SLITHER.md`).
- **Slither `incorrect-exp`** finding: single occurrence inside OZ
  `Math.mulDiv`; slither misinterprets the Newton-iteration seed
  computation. False positive.
- **Decimals discipline.** The system expects 6-decimal stablecoins on
  every chain except BSC, where mainnet USDC and USDT are 18-decimal.
  All on-chain decimal handling consults each token contract's
  `decimals()` at runtime (or uses the `decimals` field stored at
  registration time) rather than hardcoding 6. The off-chain
  reconciliation engine has a matching per-token-decimals resolver.

---

## Oracle risk

- **OperatorPriceOracle.** Operator-pushed prices with a configurable
  staleness window (default 300s). Every consumer checks
  `price.timestamp + staleness > block.timestamp` and reverts on staleness.
- **ChainlinkFallbackOracle.** When configured for an asset, the vault
  prefers the Chainlink feed and cross-checks against the operator price;
  on disagreement beyond a tolerance, the borrow-time action reverts.
- **Price manipulation surface**: the operator key can post a malicious
  price. Mitigations:
  - Per-asset bounded price deltas per block (upper bound on
    percentage change between successive operator pushes — needs to
    be explicitly parameterised; an audit should verify the bound is
    tight enough to prevent oracle-grief liquidation cascades).
  - Chainlink fallback when available.
  - Staleness window.
- **Lending denominated in stablecoins**: the dominant oracle risk in
  the lending path is volatile-collateral valuation (ETH as collateral).
  A compromised operator price could open a liquidation attack on
  volatile collateral. Haircut and liquidation-threshold discipline
  (currently 25–35% haircut on ETH-class assets) reduces but does not
  eliminate this.
- **DiscountBill-as-collateral.** The bill valuation used by the vault
  is the bill's programmatic redemption value less a haircut; no oracle
  is consulted. A bill's value is deterministic from the contract's
  own state, so the oracle attack surface does not apply.

---

## Economic risks

These are model risks, not code bugs. They need economic-model review,
not just code audit:

1. **Term mismatch.** Deposits are fixed-term up to five years. If we
   grant loans against DepositBill collateral, the collateral maturity
   may pre-date the loan maturity, forcing an in-protocol rollover
   event. This needs a loan-vs-collateral maturity invariant (not yet
   enforced on-chain).
2. **Stablecoin depeg.** Every deposit is denominated in a specific
   stablecoin. If a stablecoin depegs, the protocol's liability to its
   depositors remains denominated in the same token — so the depeg risk
   is pass-through to depositors, not to the protocol itself. However,
   depositors hold stronger information-asymmetry than the protocol,
   and a rapid depeg could trigger mass early-redemption. Early
   redemption is rate-limited and fee-bearing; this is a deliberate
   mechanism to absorb the shock.
3. **LRT / LST exclusion.** Liquid-staking and liquid-restaking tokens
   are explicitly excluded from collateral by policy (see the April 2026
   Aave/Kelp statement in the parent-org public record). An LRT-backed
   loan class would need to be added through the explicit risk-review
   process and the collateral whitelist gate.
4. **Haircut staleness.** HaircutRegistry values are not time-stamped
   as enforceable freshness (they reflect policy, not market prices).
   Market-regime changes require operator action.

---

## Known deliberate design choices (not findings)

- **`deadline == 0` is a sentinel for "no deadline"** in
  `DiscountBillCampaigns.isExpired()` and `DiscountBillERC5095Upgradeable.isExpired()`.
  Slither flags these as `incorrect-equality`. They are intentional.
- **State variables marked by Slither as "could be constant"** in the
  storage contracts (`DiscountBillStorage`, `TreasuryStorage`, etc.)
  cannot actually be constant — they are upgrade-safe storage slots
  initialised via `initialize()`. Making them `constant` would either
  move them out of the storage layout (breaking upgrades) or require a
  fresh deployment per parameter change.
- **`array.length` in loop conditions** (Slither `cache-array-length`).
  Gas optimisation, not a security issue. The specific loops flagged
  operate on bounded strategy / token arrays (`<10` elements in
  practice).
- **ERC1967Utils `unused-return`** Slither finding is inside OZ's own
  library, where `Address.functionDelegateCall` return-value discarding
  is the canonical pattern (the delegate-called contract's success is
  verified via the low-level call's revert behaviour, not the return
  value).

---

## Slither output

See `SLITHER.md` for a per-finding triage of the Slither v0.11.3 run
against this tree. Headline:

- 43 total findings.
- 0 findings in our code that represent actual vulnerabilities.
- All 15 "High" and 13 "Medium" findings map to either
  OpenZeppelin library false positives or upgradeable-storage patterns
  that Slither does not model.

This **does not** mean the protocol is audit-clean. Slither catches a
specific class of bug (known dangerous patterns). An audit will cover
categories Slither cannot — economic exploits, composability risk,
end-to-end protocol logic, MEV exposure, and human-level design review.

---

## Recommended scope for the formal audit

A formal audit firm asked to review this repository should, at minimum:

1. Verify the storage layout discipline across every upgradeable pair
   (`<Name>Core.sol` implementation vs `<Name>Storage.sol` slots).
2. Verify that every `DEFAULT_ADMIN_ROLE` holder in the deployment
   artifacts matches the documented hardware-wallet policy, and that
   no operational key also holds `DEFAULT_ADMIN_ROLE` or `UPGRADER_ROLE`.
3. Manually trace the bill redemption path end-to-end across the three
   contracts involved, with adversarial input at each boundary.
4. Review the price-push path for bounded-delta enforcement and
   parameterise a maximum price change per block.
5. Review the liquidation path for MEV-resistant behaviour and for
   priority-conflict between multiple liquidators in the same block.
6. Review the `merge()` operation on DiscountBill for conservation of
   principal + liability and for maturity-bucket reclassification
   correctness.
7. Model-check the ERC-5095 compliance — particularly the relationship
   between `underlying` and `redemption` asset when the bill is a bill
   (not a zero-coupon).
8. Review the cross-contract invariants the rate_server's triple
   reconciliation tests for (on-chain ↔ journal ↔ events) and identify
   any on-chain invariant that should be enforced at the contract level
   rather than monitored off-chain.
9. Audit economic parameters — haircuts, LTVs, liquidation thresholds,
   operator price staleness — against adverse scenarios.

---

## Changelog

| Date | Change |
|------|--------|
| 2026-04-24 | Initial publication with Slither v0.11.3 output. |
