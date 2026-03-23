# TrancheFi Vault — Production Contracts

Full implementation of Whitepaper v7.5. Fixed 1.75x leverage with multi-tier HF cascade and coverage-based structural integrity gates. Compiles with solc 0.8.24.

---

## Features

| Feature | Status |
|---|---|
| Fixed 1.75x leverage with multi-tier HF cascade | ✅ Built |
| Lending adapter interface (Morpho) | ✅ Built |
| Morpho adapter (primary venue, 86% LLTV) | ✅ Built |
| Leverage loop execution (deposit/borrow/loop) | ✅ Built |
| Leverage rebalancing (up and down) | ✅ Built |
| Underlying token conversion via Curve | ✅ Built |
| Async ERC-7540 deposit queue (request/claim) | ✅ Built |
| Bootstrap synchronous deposits (junior first) | ✅ Built |
| Withdrawal request queue (FIFO) | ✅ Built |
| Senior-first withdrawal priority | ✅ Built |
| Coverage-based junior withdrawal gates | ✅ Built |
| Per-epoch withdrawal caps (15% normal, 10% stressed) | ✅ Built |
| Bunker mode (25% trigger, 10% cap, 1.0x leverage) | ✅ Built |
| USDC liquidity reserve (7.5% target) | ✅ Built |
| Reserve replenishment logic | ✅ Built |
| Health factor monitoring (keeper-callable every 30s) | ✅ Built |
| Multi-tier HF deleveraging cascade | ✅ Built |
| Emergency deleverage + shutdown | ✅ Built |
| Borrow cost circuit breaker (10/12/15%) | ✅ Built |
| Dual oracle safety (internal exchange rate + Curve TWAP) | ✅ Built |
| Oracle deviation circuit breaker (2%) | ✅ Built |
| Derived underlying yield from exchange rate delta | ✅ Built |
| Underlying price validation (keeper vs on-chain oracle) | ✅ Built |
| Coverage floor gate (12% hard, 15% soft, 18% recovery) | ✅ Built |
| getLeverageAdjustedCoverage() view function | ✅ Built |
| Junior wipeout handling (senior earns full pool yield) | ✅ Built |
| Governance-adjustable fees with hardcoded ceilings | ✅ Built |
| Fee timelock (7-day delay on all fee changes) | ✅ Built |
| TVL cap (governance-adjustable) | ✅ Built |
| Admin functions (set adapter, set pool, set cap, set fees) | ✅ Built |

---

## File Structure

```
src/
  TrancheFiVault.sol          — Main vault (~1,518 lines)
  adapters/
    MorphoAdapter.sol          — Morpho Blue adapter
    AaveV3Adapter.sol          — Aave V3 adapter (backup)
  interfaces/
    ILendingAdapter.sol        — Lending abstraction
    IMorpho.sol                — Morpho Blue interface
    IAaveV3.sol                — Aave V3 interface
    IVaultUnderlying.sol       — Underlying token + price oracle interface
                                 (covers sUSDat/Saturn and apyUSD/Apyx)
    ICurvePool.sol             — Curve swap + oracle interface
  tokens/
    TrancheToken.sol           — sdcSENIOR / sdcJUNIOR ERC20

test/
  TrancheFiVault.t.sol         — 64 test cases (unit + invariant fuzz)
  mocks/
    MockLendingAdapter.sol     — Lending mock (tracks collateral/debt)
    MockCurvePool.sol          — Curve mock (1:1 swaps, configurable TWAP)
    MockStakedUnderlying.sol   — Underlying token mock (with convertToAssets)
    MockUnderlyingOracle.sol   — Price oracle mock
    MockUSDC.sol               — USDC mock (6 decimals)

script/
  Deploy.s.sol                 — Deployment script

keeper/
  keeper.py                    — Keeper bot
```

---

## Key Architecture Decisions

**Vault-Agnostic Underlying:** The vault does not hardcode sUSDat or any specific token. All underlying asset interactions go through `IVaultUnderlying` (for `convertToAssets()` yield derivation) and `IUnderlyingPriceOracle` (for keeper MTM validation). This means the same contract deploys for both:
- Saturn vault: sUSDat collateral, USDC borrow
- Apyx vault: apyUSD collateral, apxUSD borrow (pending Apyx ABI confirmation)

**Derived Yield — No Hardcoded APY:** Underlying yield is not a constant. Each epoch, `settleEpoch()` computes:
```
epochYield = (currentRate - lastExchangeRate) / lastExchangeRate
```
where `currentRate = stakedUnderlying.convertToAssets(WAD)`. The waterfall receives the annualized derived yield. Epoch 0 uses `SUSDAT_YIELD_FALLBACK` (10.35%) as a one-time estimate only.

**Coverage Floor Gate:** The vault maintains `getLeverageAdjustedCoverage() = juniorNAV / (totalNAV × currentLeverage)`. This is the true structural metric — not the raw senior/junior ratio. At 70/30 and 1.75x this equals 17.1%, meaning sUSDat must drop 17.1% before senior is touched. Hard gates:
- Coverage < 15% (soft floor): junior withdrawals capped at `WITHDRAWAL_STRESSED` (10%) per epoch
- Coverage < 12% (hard floor): junior withdrawals fully paused; senior deposits blocked
- Coverage > 18% (recovery): all restrictions lift automatically

**Governance-Adjustable Fees:** `srMgmtFee`, `jrMgmtFee`, and `jrPerfFee` are mutable state variables (not constants). Launch values: 0% / 0% / 10%. All changes require a 7-day timelock. Hard ceilings enforced in contract: management fee max 2%, performance fee max 20%.

**Lending Adapter Pattern:** The vault calls `ILendingAdapter` not Morpho directly. Adapter can be swapped via 7-day timelocked governance. Testable with `MockLendingAdapter` without a mainnet fork.

**Withdrawal Queue:** Linear scan with per-tranche cursor advancement (O(1) amortized). Senior queue processed before junior in every epoch — structurally enforced, not governance-dependent.

**Bootstrap Sequence:** Junior must be seeded first via `depositJunior()`. `requestDeposit()` blocks senior deposits when `juniorNAV == 0` — there must be subordination before senior capital enters. Both bootstrap functions revert once both tranches have capital, forcing use of the async `requestDeposit` path.

---

## Constructor Parameters

```solidity
constructor(
    address _usdc,                // USDC token
    address _underlying,          // Underlying yield token (sUSDat or apyUSD)
    address _stakedUnderlying,    // For convertToAssets() yield derivation
    address _underlyingOracle,    // Price oracle for MTM validation
    address _lendingAdapter,      // Morpho or Aave adapter
    address _curvePool,           // Curve underlying/USDC pool
    address _admin,               // Admin multisig
    address _keeper               // Keeper bot address
)
```

---

## settleEpoch Pipeline

```
Step 1:  _checkOracleDeviation()     — Internal rate vs Curve TWAP, 2% max deviation
Step 2:  Borrow circuit breaker      — Read from adapter; freeze >10%, deleverage >12%, emergency 1.0x >15%
Step 3:  HF cascade                  — HF<1.1: shutdown | HF<1.3: emergency deleverage | HF<1.6: accelerate | HF<1.8: freeze
Step 4:  _rebalanceLeverage()        — Execute on-chain position to reach newLeverage (skipped if oracle broken)
Step 5:  Derive underlying yield     — epochYield from convertToAssets() delta; annualize; epoch 0 uses fallback
Step 6:  Oracle price validation     — Keeper underlyingPrice validated against on-chain oracle (±1%)
Step 7:  _executeWaterfall()         — Pure function: senior coupon, junior delta, MTM, fees using actualLeverage
Step 8:  NAV update                  — Apply waterfall to seniorNAV/juniorNAV; increment epoch
Step 9:  _processDeposits()          — Price and mint shares at post-waterfall NAV
Step 10: _processWithdrawals()       — Senior first; coverage gates applied to junior
Step 11: _replenishReserve()         — Pull up to 2% TVL per epoch toward 7.5% reserve target
Step 12: Final leverage sync         — Recompute currentLeverage from actual adapter state
```

---

## Health Factor Cascade

| HF Range | Keeper (checkHealthFactor) | Epoch (settleEpoch) |
|---|---|---|
| ≥ 2.0 | No action | Full 1.75x maintained |
| 1.8 – 2.0 | No action | Freeze leverage increases |
| 1.6 – 1.8 | No action | Deleverage toward 1.25x |
| 1.3 – 1.6 | Deleverage to 1.0x | Accelerated deleverage |
| < 1.3 | Emergency deleverage to 1.0x | Emergency deleverage |
| < 1.1 | Shutdown + full unwind | Shutdown + full unwind |

The keeper fires between epochs every 30 seconds for the three most severe tiers. The freeze tier (1.8–2.0) only applies at epoch settlement since it merely prevents re-leveraging.

---

## Fee Schedule

| Phase | TVL | Sr Mgmt | Jr Mgmt | Jr Perf |
|---|---|---|---|---|
| 1 — Launch | < $5M | 0% | 0% | 10% |
| 2 — Growth | $5M – $25M | 0.25% | 0.25% | 10% |
| 3 — Scale | $25M – $100M | 0.50% | 0.50% | 15% above 8% hurdle |
| 4 — Maturity | > $100M | 0.50% | 0.50% | 20% above 8% hurdle |

Hard ceilings (constants, immutable): `MAX_MGMT_FEE = 2%`, `MAX_PERF_FEE = 20%`.
All fee changes require `queueSetFees()` + 7-day timelock + `executeSetFees()`.

---

## Pre-Audit Notes

Items requiring auditor attention or finalization before mainnet deployment:

1. **Curve pool index mapping** — `exchange(0, 1, ...)` assumes underlying=1, USDC=0. Must match actual deployed pool indices for both Saturn and Apyx pools.

2. **Slippage parameters** — 1% hardcoded in `_usdcToUnderlying` and `_underlyingToUsdc`. Auditor should assess whether configurable slippage is needed.

3. **Timelock bypass** — Verify 7-day timelock on adapter, pool, and fee changes cannot be bypassed via role escalation.

4. **Saturn ABI TODOs** — `IVaultUnderlying` interface needs finalization: exact function signatures for `convertToAssets()` on Saturn mainnet deployment.

5. **Apyx ABI TODOs** — apyUSD exchange rate function name, apxUSD borrow token address, and Morpho market parameters pending confirmation from Apyx team.

6. **Curve pool addresses** — Mainnet addresses for sUSDat/USDC and apyUSD/apxUSD Curve pools not yet confirmed.

7. **Coverage floor behavior at bootstrap** — `getLeverageAdjustedCoverage()` returns `WAD` (100%) when either NAV is zero, bypassing coverage gates during bootstrap. Auditor should verify this is safe.

8. **Junior wipeout branch** — When `jrNAV == 0`, `_executeWaterfall()` assigns full pool yield to senior uncapped. Verify this cannot be triggered artificially to extract senior yield.

---

## Deployment Sequence

1. Deploy `MorphoAdapter` (or `AaveV3Adapter`)
2. Deploy `TrancheFiVault` with constructor params
3. Set TVL cap via `setTVLCap()` (Phase 1: $1M)
4. Call `depositJunior()` to seed junior tranche first
5. Call `depositSenior()` to seed senior tranche
6. Verify both tranches funded, coverage > 18%
7. Open public access via `requestDeposit()`
