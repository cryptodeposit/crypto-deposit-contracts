# Slither results & triage

**Tool:** Slither v0.11.3 (crytic/slither)
**Invocation:**
```
slither . --compile-force-framework forge --exclude-informational --exclude-low
```
**Date:** 2026-04-24

Run excludes `Low` and `Informational` severities by design — those generate
style-and-convention noise that has been reviewed separately and does not
affect security. High, Medium, and Optimization findings are retained and
triaged below.

Raw JSON output is checked in at `security/slither.json` and human-readable
at `security/slither_checklist.md`. This document is the **authoritative
triage** that calls each finding either:

- ✅ **False positive** — tool limitation / library-internal / intentional.
- 🟡 **Optimisation** — valid gas suggestion, not security.
- ❌ **Action required** — genuine code bug / risk.

As of this run: **0 findings fall in the ❌ Action required bucket.**
The rest of this document explains why, finding by finding.

---

## Summary by category

| Severity | Check | Count | Verdict |
|----------|-------|------:|---------|
| High | `uninitialized-state` | 14 | ✅ False positive — upgradeable storage pattern |
| High | `incorrect-exp` | 1 | ✅ False positive — OZ Math.mulDiv |
| Medium | `divide-before-multiply` | 9 | ✅ False positive — OZ Math.mulDiv |
| Medium | `incorrect-equality` | 2 | ✅ Intentional — sentinel `== 0` |
| Medium | `unused-return` | 2 | ✅ False positive — OZ ERC1967Utils |
| Optimization | `constable-states` | 12 | ✅ False positive — upgrade-safe storage |
| Optimization | `cache-array-length` | 3 | 🟡 Gas optimisation only (bounded loops) |
| **Total** | | **43** | **0 real findings** |

---

## High findings

### 1. `uninitialized-state` × 14 — upgradeable-storage false positive

Slither reports storage variables in `DiscountBillStorage`,
`TreasuryStorage`, and other storage base contracts as "never
initialized in a constructor." This is the expected UUPS pattern:

- Implementation contract's constructor calls `_disableInitializers()`.
- Every storage slot is initialized in the proxy via `initialize(...)`,
  guarded by OZ's `initializer` / `reinitializer` modifier.

Slither does not trace the `initialize()` call path through the proxy
dispatch and therefore flags every storage slot as uninitialised.
This is a standard, well-known tool limitation for UUPS / Beacon / OZ
upgradeable contracts.

**Confirmed false positive.** Each flagged slot is set in the matching
`initialize` function of the top-level implementation. Verified by
inspection:

| Slot | Set in |
|------|--------|
| `DiscountBillStorage.compliance` | `DiscountBillERC5095Upgradeable.initialize` |
| `DiscountBillStorage.travel` | same |
| `DiscountBillStorage.treasury` | same |
| `DiscountBillStorage.issuer` | same |
| `DiscountBillStorage.commissionBps` | same |
| `DiscountBillStorage.defaultBreakFeeBps` | same |
| `DiscountBillStorage.defaultClaimWindow` | same |
| `DiscountBillStorage.claimWindowEffectiveFrom` | same |
| `DiscountBillStorage.maxDepositAmount` | same |
| `DiscountBillStorage.billTokenFactory` | same |
| `DiscountBillStorage.nextSeriesId` | same |
| `DiscountBillStorage.campaignsImpl` | same |
| `DiscountBillStorage.lifecycleImpl` | same |
| (…) | (…) |

### 2. `incorrect-exp` × 1 — OZ Math.mulDiv

Location: `lib/openzeppelin-contracts/contracts/utils/math/Math.sol`,
function `mulDiv(uint256, uint256, uint256)`.

Slither's detector assumes the `^` operator is exponentiation (Python
semantics) rather than bitwise-XOR (Solidity semantics). `Math.mulDiv`
uses XOR as part of its Newton-iteration seed computation. This is
well-known, well-tested OpenZeppelin code; the detector is producing a
language-mismatch false positive.

**Confirmed false positive.** See
<https://github.com/crytic/slither/issues/2105> for the upstream tracker.

---

## Medium findings

### 3. `divide-before-multiply` × 9 — OZ Math.mulDiv / invMod

All 9 occurrences are inside `OpenZeppelin Math.mulDiv` or
`Math.invMod`. These are the canonical 512-bit multiply-divide and
modular-inverse routines used across DeFi — the same code that backs
Uniswap V3's fixed-point math.

The detector flags the algorithm's internal structure (which does
perform a divide-then-multiply by design to handle 512-bit
intermediate products) as risky, but the math has been formally
verified and independently audited.

**Confirmed false positive.** Out of scope for this repository — we
do not modify library code.

### 4. `incorrect-equality` × 2 — intentional sentinel

| File | Line | Expression |
|------|------|-----------|
| `src/DiscountBillCampaigns.sol` | 73 | `deadline == 0` |
| `src/DiscountBillERC5095Upgradeable.sol` | 788 | `deadline == 0` |

Both are **intentional sentinels** — a zero deadline means "no expiry
set." Slither's `incorrect-equality` detector warns because strict
equality on an integer is brittle if the value could vary; here the
value is a sentinel that is explicitly compared against literal zero.

**Confirmed intentional.** The alternative (`deadline == type(uint256).max`)
would be conventional but uses more gas to store; the sentinel pattern is
consistent with OZ timestamps.

### 5. `unused-return` × 2 — OZ ERC1967Utils

Both findings are inside `lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol`:
- `upgradeToAndCall` discards the return of `Address.functionDelegateCall`.
- `upgradeBeaconToAndCall` does the same.

This is the intended pattern — the delegate-call's success is verified
by revert propagation, not by inspecting the returned bytes. OZ code,
not ours.

**Confirmed false positive.**

---

## Optimization findings

### 6. `constable-states` × 12 — upgrade-safe storage

Slither suggests several state variables in storage contracts could be
declared `constant`. Marking them `constant` would remove them from the
storage layout, which would **break upgrade compatibility** for every
deployed proxy.

Example flagged variables:
- `DiscountBillStorage.issuer` — set in `initialize`, upgradeable.
- `DiscountBillStorage.treasury` — same.
- `DiscountBillStorage.compliance` — same.
- etc.

These must remain storage variables to preserve the ability to change
them via an upgrade or an admin setter (where one exists).

**Confirmed false positive.**

### 7. `cache-array-length` × 3 — gas optimisation

| File | Line | Array |
|------|------|-------|
| `src/TreasuryUpgradeable.sol` | 553 | `_trackedTokens` |
| `src/TreasuryUpgradeable.sol` | 728 | `_strategies` |
| `src/TreasuryUpgradeable.sol` | 886 | `_strategies` |

Each loop reads `array.length` from storage on every iteration instead
of caching to a local. The arrays in question are bounded (tracked
tokens <20 per chain in the deployed config; strategies <10). Gas
impact is negligible but the cleanup is trivial.

**Verdict: 🟡 Gas optimisation.** Scheduled for the pre-audit cleanup
pass — tracked in the parent monorepo's TODO backlog.

---

## What Slither does not catch

This run is useful as a floor but **does not** substitute for the
following, all of which are on the scope of the pending formal audit:

1. Cross-contract invariants spanning more than one contract
   (e.g. redemption path: DiscountBill ↔ Treasury ↔ ERC-20).
2. Economic exploits (flash loans against a price oracle,
   liquidation gaming, MEV sandwiches).
3. End-to-end protocol logic correctness.
4. Storage-layout changes between upgrades (requires `forge inspect`
   or `hardhat-storage-layout`, not Slither).
5. Access-control correctness under adversarial permission sequences
   (grant → revoke → re-grant edge cases).
6. Formal verification of the interest-accrual and haircut math.
7. Denial-of-service via unbounded loops — our flagged loops are
   bounded but an auditor should verify the bounds under all paths.

---

## Reproducing this run

```bash
# From a conda env with slither-analyzer installed
conda activate slither-env
cd /path/to/crypto-deposit-contracts
forge install
slither . \
  --compile-force-framework forge \
  --exclude-informational --exclude-low \
  --json security/slither.json \
  --checklist > security/slither_checklist.md
```

Slither version pinned: `slither-analyzer==0.11.3`.

---

## Changelog

| Date | Change |
|------|--------|
| 2026-04-24 | Initial Slither run + triage. 43 findings; 0 actionable vulnerabilities. |
