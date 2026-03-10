# TrancheFi Vault — Production Contracts

Full implementation of Whitepaper v6. Fixed 1.75x leverage with four-level HF cascade. Compiles with solc 0.8.24.

## Features

| Feature | Section | Status |
|---------|---------|--------|
| Fixed 1.75x leverage with HF cascade | 7 | ✅ Built |
| Lending adapter interface (Morpho/Aave) | 6.1 | ✅ Built |
| Morpho adapter (primary venue, 86% LLTV) | 6.1 | ✅ Built |
| Aave V3 adapter (backup venue) | 6.1 | ✅ Built |
| Leverage loop execution (deposit/borrow/loop) | 6.1 | ✅ Built |
| Leverage rebalancing (up and down) | 7.6 | ✅ Built |
| USDC → sUSDat conversion via Curve | 4.2 | ✅ Built |
| Withdrawal request queue (FIFO) | 9.3 | ✅ Built |
| Withdrawal claim system | 9.3 | ✅ Built |
| Senior-first withdrawal priority | 9.3 | ✅ Built |
| Per-epoch withdrawal caps (15%) | 10.2 | ✅ Built |
| Bunker mode (25% trigger, 10% cap) | 10.2 | ✅ Built |
| USDC liquidity reserve (7.5% target) | 10.1 | ✅ Built |
| Reserve replenishment logic | 10.1 | ✅ Built |
| Health factor monitoring (keeper-callable) | 9.5 | ✅ Built |
| Four-tier HF deleveraging cascade | 9.5 | ✅ Built |
| Emergency deleverage + shutdown | 9.5 | ✅ Built |
| Borrow cost circuit breaker (10/12/15%) | 9.8 | ✅ Built |
| Dual oracle safety (Saturn + Curve TWAP) | 9.7 | ✅ Built |
| Oracle deviation circuit breaker (2%) | 9.7 | ✅ Built |
| TVL cap (governance-adjustable) | 14.1 | ✅ Built |
| Admin functions (set adapter, set pool, set cap) | 9.10 | ✅ Built |

## File Structure

```
src/
  TrancheFiVault.sol          — Main vault (1,466 lines)
  adapters/
    MorphoAdapter.sol          — Morpho Blue adapter (245 lines)
    AaveV3Adapter.sol          — Aave V3 adapter (207 lines)
  interfaces/
    ILendingAdapter.sol        — Lending abstraction (62 lines)
    IMorpho.sol                — Morpho Blue interface (122 lines)
    IAaveV3.sol                — Aave V3 interface (129 lines)
    ISaturn.sol                — sUSDat, StrcPriceOracle (78 lines)
    ICurvePool.sol             — Curve swap + oracle (32 lines)
  tokens/
    TrancheToken.sol           — sdcSENIOR / sdcJUNIOR ERC20 (35 lines)

test/
  TrancheFiVault.t.sol         — 48 test cases (845 lines)
  mocks/
    MockLendingAdapter.sol     — Lending mock (tracks collateral/debt)
    MockCurvePool.sol          — Curve mock (1:1 swaps, configurable TWAP)
    MockSUSDat.sol             — sUSDat mock (with convertToAssets)
    MockStrcOracle.sol         — STRC price oracle mock
    MockUSDC.sol               — USDC mock (6 decimals)
    MockUSDat.sol              — USDat mock (6 decimals)

script/
  Deploy.s.sol                 — Deployment script (131 lines)

keeper/
  keeper.py                    — Keeper bot (322 lines)
```

Total auditable Solidity: 2,376 lines.

## Key Architecture Decisions

**Lending Adapter Pattern:** The vault doesn't talk to Morpho directly. It calls `ILendingAdapter` which can be swapped between implementations via 7-day timelocked governance. This means:
- Can migrate from Morpho to Aave without touching vault logic
- Testable with MockLendingAdapter (no mainnet fork)
- Future: could split across multiple venues

**Withdrawal Queue:** Linear scan through requests with cursor advancement (O(1) amortized per epoch). Current design is gas-efficient up to ~100 pending requests per epoch.

**Leverage Loops:** Not iterated in a loop (gas-expensive). Instead, calculates target collateral/debt from leverage ratio and equity, then does a single deposit+borrow or withdraw+repay to reach target.

**USDC Reserve:** 7.5% of deposits go to reserve on deposit. Reserve is replenished from lending position during epoch settlement (max 2% of TVL per epoch to avoid disruption). Withdrawals draw from reserve first.

## Pre-Audit Notes

Items for auditor attention or finalization before mainnet deployment:

1. **Curve pool index mapping** — `exchange(0, 1, ...)` assumes USDC=0, sUSDat=1; needs to match actual deployed pool indices
2. **Slippage parameters** — currently hardcoded 1%; auditor should assess whether this is sufficient or should be configurable
3. **Timelock on governance** — 7-day timelock for adapter changes is implemented; auditor should verify timelock cannot be bypassed
4. **Events** — may need additional events for full indexability by off-chain infrastructure
5. **Saturn ABI finalization** — 4 TODOs in vault awaiting Saturn's finalized contract addresses and interface

## Constructor Parameters

```solidity
constructor(
    address _usdc,            // USDC token
    address _usdat,           // USDat token (Saturn)
    address _sUsdat,          // sUSDat vault (Saturn)
    address _strcOracle,      // STRC price oracle
    address _lendingAdapter,  // Morpho or Aave adapter
    address _curvePool,       // Curve sUSDat/USDC pool
    address _admin,           // Admin multisig
    address _keeper           // Keeper bot address
)
```

## settleEpoch Pipeline (Full Integration)

```
1. Dual oracle check (Saturn vs Curve TWAP, 2% max deviation)
2. Fixed leverage target (1.75x)
3. Borrow cost circuit breaker (freeze 10%, deleverage 12%, emergency 15%)
4. Health factor cascade (freeze 1.8, deleverage 1.6, accelerate 1.3, emergency 1.1)
5. Rebalance actual lending position (deposit/borrow or withdraw/repay)
6. Execute waterfall (NAV updates)
7. Process withdrawal queue (senior-first, FIFO, epoch caps)
8. Replenish USDC reserve toward 7.5% target
```
