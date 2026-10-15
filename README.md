# DrawdownBurnStrategy — audit scope

A fee strategy for a token traded on a Uniswap v4 pool against ARB on Arbitrum One.

## In scope

| File | Status |
|---|---|
| `src/DrawdownBurnStrategy.sol` | **New, not deployed: the audit target** |
| `src/FeeVault.sol` | Deployed, immutable; included as context |
| `src/FeeHook.sol` | Deployed, immutable (the pool's hook); context |
| `src/Token.sol`, `src/ERC20Checkpoints.sol` | Deployed token; context |
| `src/interfaces/IFeeStrategy.sol` | Interface the vault calls |

Build: `forge build` (solc 0.8.26, cancun, optimizer 200 runs). Dependencies are pinned git submodules.

## How fees flow

1. Every swap on the pool pays the hook a fee (3.3%) on the side the trader receives.
   - Buys: the fee is in the token and is **burned** by the hook.
   - Sells: the fee is in ARB and is sent to `FeeVault`.
2. The hook calls `FeeVault.onFeeReceived`, which calls the strategy with a **400k gas cap** inside a
   try/catch, so a strategy can never revert a swap.
3. The strategy **owns the vault** (as the previous strategy did) and spends only fees that arrive after
   it is installed. ARB already banked in the vault must never be spent.

## What the strategy does

- **Metric**: circulating market cap in ARB = (total supply − excluded balances − tokens held for
  burning) × pool price. No oracle.
- **ATH**: the highest *hourly close* (the last reading of a clock hour). Given at deploy; afterwards it
  rises only when an hour closes above it.
- **Anchor**: read once per block. The block's anchor tick moves at most 200 ticks (~2%) from the last
  one; the market cap and tier are read there.
- **Tiers**: share of each new ARB fee bought back and burned:

  | Under the ATH | Burned | Kept for the wall |
  |---|---|---|
  | at or over | 0% | 100% |
  | 0–20% | 25% | 75% |
  | 20–40% | 50% | 50% |
  | 40–60% | 75% | 25% |
  | ≥ 60% | 100% | 0% |

- **Buyback**: whole pot, ≤ `maxPerBuy`, once per block, ≤ ~2% over the anchor. Runs inside the
  trader's swap (measured peak 327k gas) or via permissionless `buyback()`. Bought tokens are burned on
  the next call (`burnHeld()` is permissionless).
- **Wall**: kept ARB is laid as a single-sided (ARB-only) v4 position whose top is where the
  circulating market cap equals 40% of the ATH. Permissionless `buildWall()` adds pending ARB, or, once
  the price has crossed the wall entirely, removes it and burns the tokens it bought. The wall does not
  follow a later ATH.
- **Owner only**: `withdrawWall(to)`, `burnWall()` (wall ARB to the buyback pot, wall tokens burned),
  `moveWall()` (re-lay under the current ATH), `withdrawFromVault`, `releaseVault`, `setExcluded`,
  `setMaxPerBuy`, `setWallWidth`. `Ownable2Step`; renounce disabled. Single-key owner by design.

## Please look hardest at

1. **Accounting**: `pot`, `pendingWall`, `accounted` vs the vault's real ARB balance, across
   buybacks, `buildWall`, `burnWall`, `moveWall`, `withdrawFromVault` and `_toVault` (ARB returned to
   the vault must not be counted as a new fee). The pre-existing vault balance must never be spent.
2. **Pool manager flash accounting**: every `unlockCallback` path settling to zero deltas;
   `onFeeReceived` running *inside another user's swap* (the `getSyncedCurrency` guard, `sync`/`settle`
   ordering, re-entry through the vault while the guard is held).
3. **Manipulation**: anchor stepping, the hourly-close ATH, the tier read, buyback price limits, and
   whether a flash pump/dump, sandwich or multi-block push can make it buy high, flip tiers, lift the
   ATH or misplace the wall profitably.
4. **The wall**: tick math in `wallTarget()` (sqrt of `ath*0.4/circ` in X96), rounding to spacing,
   single-sided add/remove, fee collection, the crossed-wall burn, and DoS (can anyone make
   `buildWall` revert or burn something it should not).
5. **Gas inside swaps**: anything that can push `onFeeReceived` past the 400k cap repeatedly
   (it fails silently; buybacks then rely on `buyback()`).
6. `circulatingSupply()` assumptions (excluded list ≤ 8, held balance, burns lowering the market cap).

Fork tests (23 + deploy) exist against the live pool and are not included here.
