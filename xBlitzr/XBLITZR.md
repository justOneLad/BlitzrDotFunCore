# xBlitzr — V4 Hook Variant

xBlitzr is the Uniswap V4 counterpart to the V3 Blitzr stack (`../contracts/`). Same job —
launch a token, seed permanent one-sided liquidity, lock it forever — rebuilt on V4's singleton
`PoolManager` + hooks architecture instead of per-pool V3 contracts. xBlitzr runs **two
independent revenue streams**: a 1 % pool LP fee split `creatorBps`/`platformBps` (default
85 % / 15 %, owner-adjustable, applied to both currency legs) and a separate `hookFeeBps` hook
fee (default 0.3 %, owner-adjustable) paid entirely to the platform. No charity wallet in this
variant.

---

## Contracts

| File | Contract | Role |
|------|----------|------|
| `XBlitzrHook.sol` | `XBlitzrHook` | V4 hook attached to every xBlitzr pool. Enforces the permanent one-sided lock and skims its fee cut live on every swap — replaces BlitzrLocker's claim-based model entirely. |
| `XBlitzrLauncher.sol` | `XBlitzrLauncher` | Orchestrates every launch against the singleton `PoolManager`. |

The token is **not** duplicated here — xBlitzr clones the same `contracts/BlitzrToken.sol`
implementation the V3 stack uses (`tokenImpl` in the constructor points at that deployed
contract). It's a plain EIP-1167 clone template with no V3/V4-specific logic, so there's nothing
to fork.

---

## Two fee streams, two different mechanisms

**Principal liquidity is permanently locked** — `XBlitzrHook.beforeRemoveLiquidity` reverts on
any nonzero `liquidityDelta`, from anyone, forever. V4 routes `modifyLiquidity` calls with
`liquidityDelta <= 0` — including the zero-delta "poke" used to realize LP fees without touching
principal — through this same remove-liquidity hook path, so principal-removal and fee-realization
share one gate. That gate distinguishes them by delta value, not by who's asking:

- `liquidityDelta == 0` (a poke, no principal change): allowed, but **only when called by the
  launcher** — the position's owner in `PoolManager`'s accounting, and the only address that
  could ever successfully make this call anyway (V4 positions are keyed by whoever called
  `modifyLiquidity` originally). `XBlitzrLauncher.collectPoolFees(token)` drives this: it replays
  the poke against the position's stored `PoolKey`/tick range, then splits whatever comes back
  `creatorBps`/`platformBps` between the creator's `feeWallet` and `platformWallet`. Permissionless
  to call — the split destination is fixed by the token/quote identity and the current bps, not
  by the caller, so calling it early or often can't misdirect anything, only affects *when* fees
  get realized.
- `liquidityDelta != 0` (any real removal): reverts unconditionally, including for the launcher.
  This is what makes the lock permanent — not any restraint in the launcher's own code, this hook
  check.

**The hook's own cut is separate and immediate** — `XBlitzrHook.afterSwap` skims `hookFeeBps`
(default 0.3 %) off every swap's unspecified-currency leg live, via the returned-delta mechanism,
and pays it entirely to `platformWallet` via a direct `poolManager.take()` call. No claim step, no
pending balance — this one lands the instant a swap happens, same swap that also generates the
pool-fee accrual the creator/platform later collect via `collectPoolFees`.

So a single swap generates revenue for *both* streams simultaneously: the pool's native 1 % LP
fee accrues silently until someone pokes it (creator/platform split, claimed), and the hook's
separate 0.3 % skim pays out immediately (platform-only, live) — two different mechanisms,
running side by side on every trade.

---

## Architecture

```
Creator
  │  launch(name, symbol, metaURI, feeWallet, quoteToken, minTokensOut)  payable
  │  msg.value = launchFee + (optional) extra ETH for an instant buy
  ▼
XBlitzrLauncher
  ├─ call{value: launchFee}(launchFeeWallet)          ← same as V3: fee is always native, never touches the pool
  ├─ clone(BlitzrToken impl)  →  BlitzrToken (1 B supply minted to launcher)
  ├─ poolManager.unlock(...)  →  unlockCallback:
  │     ├─ poolManager.initialize(key, sqrtPriceX96)   → key.fee = 10_000 (1 %), returns currentTick directly
  │     ├─ compute one-sided [tickLower, tickUpper] exactly like V3
  │     ├─ TickMath + LiquidityAmounts → convert TOTAL_SUPPLY into a liquidity unit count
  │     ├─ poolManager.modifyLiquidity(key, {liquidityDelta: +liquidity})
  │     ├─ sync + transfer + settle the owed token leg
  │     ├─ store PoolFeePosition[token] = {key, tickLower, tickUpper}    ← needed to poke later
  │     ├─ XBlitzrHook.registerPosition(token, key, feeWallet)
  │     ├─ [if extra ETH sent] instant buy, checked against minTokensOut — see "Instant Buy" below
  │     └─ sweep mint-rounding dust to creator, renounce token ownership
  ├─ returns (token, poolId)
  └─ collectPoolFees(token)  [callable any time, by anyone, after launch]
        └─ poolManager.unlock(...)  →  unlockCallback:
              ├─ poolManager.modifyLiquidity(key, {liquidityDelta: 0, ...})   ← the poke
              └─ take() whatever comes back, split creatorBps/platformBps between feeWallet
                 and platformWallet (default 85/15)

XBlitzrHook  (attached to every xBlitzr pool)
  ├─ beforeAddLiquidity    → only the launcher may ever call this, and only once
  ├─ beforeRemoveLiquidity → liquidityDelta == 0 allowed, but launcher-only (the poke above);
  │                          liquidityDelta != 0 always reverts, from anyone, forever
  └─ afterSwap → skims hookFeeBps of every swap, live, entirely to platformWallet (default 0.3 %)
```

---

## What's simpler than V3

- **No DEX registry.** V3 tracked `dexes[factory] → {positionManager, router}` because V3 forks
  (PancakeSwap V3, etc.) each run their own factory. V4 is a single canonical `PoolManager` per
  chain, so `addDex`/`disableDex` and the whole registry disappear.
- **No WETH wrapping for the common case.** V4 treats native ETH/BNB as a first-class currency
  (`Currency` wrapping `address(0)`), so a native-quote launch never needs `IWETH.deposit()`.
- **No external swap router, even for multi-hop.** The launcher calls `poolManager.swap()`
  itself inside the same `unlock()` context used for `initialize`/`modifyLiquidity`, so the
  whole launch — including a multi-hop instant buy — is one atomic callback instead of
  coordinating a separate router contract with its own path-encoding scheme (V3's
  `ISwapRouter.exactInput`). V4's flash accounting lets the two hops chain directly: the
  intermediate currency's credit from hop 1 nets against its debit from hop 2 inside
  `PoolManager`'s own ledger, with no physical transfer of that currency at all — see
  "Instant Buy" below.
- **No LP-NFT.** V4 attributes liquidity positions to whichever address called
  `modifyLiquidity` (the launcher, here) rather than minting a transferable NFT — there's nothing
  for a separate locker contract to hold custody of. This is also *why* the hook-level
  `beforeRemoveLiquidity` revert matters: without it, the launcher contract itself would remain
  capable of calling `modifyLiquidity` with a negative delta on that exact position later.

## What's simplified relative to a "real" launch (deliberately, to control scope)

- **No dynamic fee.** The pool's `POOL_FEE` (1 %) is a fixed constant, not using V4's
  dynamic-fee flag. `creatorBps`/`platformBps` (pool fee split) and `hookFeeBps` (hook fee rate)
  are owner-adjustable, same pattern as V3's `BlitzrLocker.creatorBps`/`platformBps` — but there's
  no charity stream here.

---

## Deploying the Hook

Uniswap V4 hooks must be deployed at an address whose **low bits encode which callbacks are
active** — `PoolManager` only invokes a hook function if the corresponding flag bit is set in
`address(hook)`. `XBlitzrHook` needs:

```
BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG | AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG
```

A plain `new XBlitzrHook(...)` will essentially never land on an address with that exact bit
pattern (roughly 1-in-16384 odds by chance). The constructor defends against this — it reverts
with `BadHookAddress` if the deployed address doesn't encode `REQUIRED_FLAGS` — but you still
need to **mine a CREATE2 salt** that produces a valid address before deployment even reaches the
constructor. This is normally done off-chain in a deploy script (Foundry's `forge script`, using
a `HookMiner`-style brute-force loop over salts, then deploying via a CREATE2 factory with the
found salt) — not something to attempt manually. No such script exists yet in this repo.

---

## Deployment Order

1. Deploy `BlitzrToken` implementation, if not already deployed for the V3 stack (it's shared —
   skip this if `contracts/BlitzrToken.sol` is already live and reuse that address).
2. Mine a CREATE2 salt for `XBlitzrHook` against the target chain's `PoolManager` address, then
   deploy `XBlitzrHook(poolManager, platformWallet, owner)` via that salt. `owner` must be passed
   explicitly (see the constructor's doc comment) — deploying through a CREATE2 proxy means
   `msg.sender` inside the constructor is the proxy, not your EOA.
3. Deploy `XBlitzrLauncher(poolManager, tokenImpl, hook, launchFeeWallet, launchFee)`.
4. Call `XBlitzrHook.setLauncher(xBlitzrLauncher)`.
5. Call `XBlitzrLauncher.addQuoteToken(...)` for any non-native quote tokens (native ETH/BNB is
   registered automatically in the constructor).

---

## Hook Fee Mechanics

`afterSwap` needs to know which of `key.currency0`/`currency1` is the **unspecified** currency —
the leg the swapper didn't fix an exact amount for, and therefore the only leg it's safe to skim
from without violating the swapper's requested exact amount:

| `zeroForOne` | `amountSpecified` | specified currency | unspecified currency |
|---|---|---|---|
| true  | negative (exact input)  | currency0 | currency1 |
| true  | positive (exact output) | currency1 | currency0 |
| false | negative (exact input)  | currency1 | currency0 |
| false | positive (exact output) | currency0 | currency1 |

`unspecifiedIsCurrency0 = !(zeroForOne == (amountSpecified < 0))`.

The cut is computed as `hookFeeBps` (default 30 bps = 0.3 %, owner-adjustable via
`setHookFeeBps`) of the unspecified leg's realized delta magnitude, taken via a single direct
`poolManager.take(feeCurrency, platformWallet, cut)` call, and the cut is returned from
`afterSwap` as the hook's delta so `PoolManager`'s internal accounting for the swap stays
balanced. This sign convention and the settlement ordering (the `take()` call creates a debt on
the hook's own currency ledger; `PoolManager` credits that ledger with the returned delta
immediately after `afterSwap` returns, netting it to zero before `unlock()` finishes — see
`_accountPoolBalanceDelta` in `PoolManager.swap()`) have been traced against
`Uniswap/v4-core@main` and confirmed correct. No separate `settle()` call is needed for the
hook's own `take()`.

Note the creator's own instant-buy swap also pays this cut — every swap through the pool pays it
uniformly, launch-time or not, and it always goes entirely to `platformWallet`, never the creator.
This stream has no creator share at all, unlike the pool fee below.

---

## Pool Fee Mechanics

`XBlitzrLauncher` persists a `PoolFeePosition` (the `PoolKey`, `tickLower`, `tickUpper` used at
launch) per token so `collectPoolFees(token)` can replay the exact `modifyLiquidity` call later
with `liquidityDelta: 0`. This only works because `PoolManager` keys liquidity positions by
`(owner, tickLower, tickUpper, salt)` where `owner` is whoever originally called
`modifyLiquidity` — the launcher, in this design — so the launcher is the only address that could
ever successfully touch this position again, poke or not.

The returned `callerDelta` from a zero-delta poke reflects only the accrued LP fees (no principal
change), and can be nonzero in either or both currencies — a one-sided *position* doesn't mean
one-sided *fee accrual*, since fees are taken on whichever currency was the input for each
individual swap, regardless of the position's range: buys accrue fees in the quote currency,
sells accrue fees in the token currency.

`_executePoke` resolves which of `currency0`/`currency1` is actually the launched token
(comparing against the `token` address directly — address sort order varies per launch, so this
can't be assumed from position), then splits **both** legs the same way:
- The creator's share (`creatorBps`, default 8 500 = 85 %) is paid to the creator's registered
  `feeWallet` (looked up live via `IXBlitzrHook.positions(token)`, so a CTO reassignment via
  `ctoFeeWallet` immediately redirects future collections too).
- The platform's share (`platformBps`, default 1 500 = 15 %) is paid to `platformWallet` (looked
  up live via `IXBlitzrHook.platformWallet()`), computed as the remainder after the creator's
  share rather than its own bps multiply, so rounding dust always lands with the platform instead
  of being lost twice.

`creatorBps`/`platformBps` are owner-adjustable via `XBlitzrLauncher.setFeeBps(creator, platform)`
and must sum to exactly 10 000. Each `collectPoolFees` call emits the exact per-leg,
per-recipient amounts actually paid (`PoolFeesCollected`), so historical splits stay correct even
across a later bps change.

---

## Instant Buy

`launch(..., minTokensOut)` accepts an ETH amount above `launchFee` to instant-buy the creator
some of their own freshly launched token, atomically. Two paths:

- **Native quote currency**: single-hop, direct `poolManager.swap()` against the just-created
  pool.
- **Non-native quote currency**: multi-hop, `native → quoteToken → token`. The first leg routes
  through an existing, liquid `native/quoteToken` pool the owner registers via
  `addQuoteToken(token, marketCapRef, refFee, refTickSpacing, refHooks)` — the full `PoolKey` of
  that reference pool (not just a fee tier, since V4 pools are keyed by `(currency0, currency1,
  fee, tickSpacing, hooks)`, unlike V3's `(token0, token1, fee)`). The second leg is the
  just-created `quoteToken/token` pool, same as the single-hop case.

Both hops happen inside the same `unlock()` call as the rest of `launch()` — no external router,
even for the multi-hop case. The intermediate `quoteToken` never physically moves: hop 1's output
credit and hop 2's input debit, in the same currency, within the same `unlock()` context, net to
exactly zero in `PoolManager`'s own ledger. This is a direct consequence of V4's flash accounting
and has no equivalent in V3, where the same route requires the periphery `SwapRouter`'s
`exactInput` with an ABI-encoded multi-hop path.

`minTokensOut` is checked once, against the final output only, after either path completes —
reverting the whole `launch()` call (pool creation included) if not met. A bad rate on either hop
shows up as a smaller final amount, so a single check at the end covers the full route. Pass `0`
for no protection. Unlike the anti-bot cap, there's no default floor here — an unprotected instant
buy is a choice the creator opts into by passing `0`, not a fixed platform policy.

---

## Anti-Bot Max-Wallet Cap

Enforced entirely in the shared `contracts/BlitzrToken.sol` — see `BLITZR.md` → "Anti-Bot
Max-Wallet Cap" for the full mechanism (it's identical for both stacks, since both launchers
call the same `initBlitzr`/`_transfer`). No xBlitzr-specific hook logic was added for this: a
predictive check in `beforeSwap` was considered and rejected, because at the point `afterSwap`
runs, the actual `take()` to the real recipient hasn't happened yet — it happens later in the
launcher's own `unlockCallback`/`_instantBuy`, so the hook can't reliably know who'll end up
holding the tokens. The token-level check is the one point that's guaranteed correct.

`XBlitzrLauncher` exempts `address(poolManager)` from the cap before renouncing token ownership,
in `_executeLaunch`, before `_settleOwed` (which is what actually credits `PoolManager` with
~100% of supply as locked liquidity across every pool — exemption must happen *before* that
transfer, not after, or the transfer itself would trip the cap).

`antiBotBlocks` (default 10) is owner-adjustable via `XBlitzrLauncher.setAntiBotBlocks`, passed
to `initBlitzr` on every launch. As with V3, there's no creator carve-out — an instant buy larger
than 2.5% of supply reverts the whole `launch()` call during the window.
