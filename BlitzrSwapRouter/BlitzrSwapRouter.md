# BlitzrSwapRouter — DEX Aggregator Router

BlitzrSwapRouter is a UUPS-upgradeable swap router that executes an **off-chain-computed route**
across Uniswap V2, V3, V4, or any other allowlisted DEX in a single transaction — matching how
real aggregators (1inch, 0x, Paraswap) actually work: the contract never does on-chain
pathfinding or price comparison. It also carries referral/cashback rewards and an optional
Permit2-based gasless approval path.

---

## Contracts

| File | Contract | Role |
|------|----------|------|
| `BlitzrSwapRouter.sol` | `BlitzrSwapRouter` | The router itself — UUPS-upgradeable, executes routes, settles rewards |
| `BlitzrSwapRouterRewardVault.sol` | `BlitzrSwapRouterRewardVault` | Standalone, non-upgradeable, pre-funded vault that referral/cashback payouts are pulled from |
| `libraries/OracleLib.sol` | `OracleLib` | V2 checkpoint-based and V3 on-demand TWAP, used to value a swap for reward sizing |
| `libraries/ReferralLib.sol` | `ReferralLib` | First-touch referral binding (pure bookkeeping, no token movement) |
| `libraries/RewardsLib.sol` | `RewardsLib` | Computes and pays the referrer's share of a reward event |
| `libraries/CashbackLib.sol` | `CashbackLib` | Computes and pays the swapper's own cashback share |
| `interfaces/IPermit2.sol` | `IPermit2` | Minimal slice of Uniswap Permit2's `ISignatureTransfer` |
| `interfaces/IRewardVault.sol` | `IRewardVault` | The vault's `payout` surface, as the router calls it |

---

## Architecture

```
Caller (off-chain route builder)
  │  swap(hops, minFinalAmountOut, referrer, valuation)  payable
  ▼
BlitzrSwapRouter
  ├─ pull hops[0]'s input (native via msg.value, or ERC20 via transferFrom)
  ├─ for each hop, in order:
  │     STANDARD → allowlist-check target, plain `call(hop.data)` (never delegatecall),
  │                balance-delta before/after enforces hop.minAmountOut
  │     V4       → poolManager.unlock(hop) → this contract's own unlockCallback →
  │                poolManager.swap/settle/take (same pattern proven in xBlitzr/XBlitzrLauncher.sol)
  ├─ enforce minFinalAmountOut against the route's final output
  ├─ settle rewards EXACTLY ONCE (see "Rewards" below)
  └─ send final output to msg.sender
```

Each hop's `tokenOut`/`amountOut` must exactly match the next hop's `tokenIn`/`amountIn` — this
is checked explicitly, not assumed, so a malformed off-chain route fails loudly instead of
silently misrouting funds.

---

## Hops and routing modes

```solidity
enum HopType { STANDARD, V4 }

struct Hop {
    HopType dexType;
    address target;       // STANDARD only — owner-allowlisted contract to call
    bytes   data;          // STANDARD: pre-built calldata. V4: abi.encode(PoolKey, zeroForOne, amountSpecified, sqrtPriceLimitX96)
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
}

struct Route {
    Hop[] hops;
}
```

Two routing modes:

- **`swap(hops, ...)`** — a single ordered chain of hops (one logical path).
- **`swapSplit(routes, ...)`** — several parallel `Route`s executed in the same call, all sharing
  the same overall input/output token, whose outputs are **summed**. Splitting one trade across
  multiple venues (e.g. 60% Uniswap V3 + 40% PancakeSwap V3) reduces price impact versus routing
  the whole amount through one path.

Both have a Permit2 counterpart — `swapWithPermit` / `swapSplitWithPermit` — see below.

STANDARD hops cover V2, V3, and any other DEX with a "call it, tokens move" shape uniformly; the
router doesn't need per-DEX ABI knowledge since the off-chain route builder already encoded the
exact call. V4 is handled specially because its flash-accounting model requires the caller of
`PoolManager.unlock()` to receive the callback directly — that can't be pushed off-chain the way
STANDARD calldata can, so the router implements `unlockCallback` itself. V4 hops ignore
`hop.target` entirely and never consult the STANDARD-hop allowlist.

---

## Permit2

`swapWithPermit`/`swapSplitWithPermit` pull the input token via a Permit2 signature instead of a
pre-existing ERC20 approval on the router itself — a swapper only ever needs to approve the
canonical Permit2 contract once (or nothing at all, if they've already approved it for another
Permit2-integrated app), rather than every router/contract they use. Native-input routes have no
approval step to begin with, so they stay on the plain `swap`/`swapSplit` entrypoints.

`permit2` defaults to Permit2's canonical singleton address
(`0x000000000022D473030F116dDEE9F6B43aC78BA3`, the same on essentially every EVM chain) and is
owner-overridable via `setPermit2` — e.g. for a chain where it isn't deployed yet, or a test
double.

---

## Rewards

Referral and cashback settle **exactly once** per `swap()`/`swapSplit()` call — never per-hop or
per-leg, so splitting a trade into more hops or more parallel routes can't multiply payouts.
Sizing is two-stage:

```
value          = swap's resolved value (see "Valuation" below)
aggregationFee = value × aggregationFeeBps / 10_000     (this router's own enforced take, default 0.3%)
referralAmount = aggregationFee × referralBps / 10_000  (only if a referrer is bound)
cashbackAmount = aggregationFee × cashbackBps / 10_000
```

`referralBps`/`cashbackBps` cut a share of the **aggregation fee**, not the swap's raw value —
giving away 10% of an entire trade's value to a referrer would be unsustainable; giving away 10%
of the router's own 0.3% take is the standard model real aggregators use for referral programs.
`aggregationFeeBps` is enforced on every swap; `referralBps`/`cashbackBps` only fire when a
referrer is actually bound / are independently configured (not a 100%-split pair — both can be
nonzero at once).

Referral binding is **first-touch**: a swapper's referrer is set on their first swap that names
one and is immutable thereafter (self-referral and an already-bound swapper both silently no-op,
never revert the swap).

### Multi-token reward

Reward payouts aren't restricted to one fixed token — the owner curates a weighted list:

```solidity
struct RewardToken { address token; uint256 weightBps; }
function setRewardTokens(RewardsLib.RewardToken[] calldata tokens_) external onlyOwner;
```

Each entry's `weightBps` is a share of the total payout (sum of weights `<= 10_000` — one pie
split N ways, e.g. 70% USDC + 30% a platform token). Both the referral leg and the cashback leg
are split across the same list.

### Reward vault

Payouts are pulled from a separate, **non-upgradeable** `BlitzrSwapRouterRewardVault` — the
router never custodies reward funds itself, only whatever's mid-swap in a single transaction. A
bug or exploit in the router's swap-execution logic can therefore only ever drain what's sitting
in the vault, never anything beyond it. `router` on the vault must be set to the router's **proxy**
address (stable across upgrades), and `payout` is gated `onlyRouter`.

---

## Valuation

```solidity
enum ValuationType { NONE, V2, V3 }
struct Valuation { ValuationType kind; address pool; uint32 window; }
```

Passed alongside every `swap()`/`swapSplit()` call, always measured against the route's own
first-hop input token/amount (never a separately-claimed amount, so it can't be inflated
independent of the real trade size):

- **V3** — `OracleLib.getV3Value`, an on-demand TWAP read from a V3 pool's `observe()` — no
  external bookkeeping needed.
- **V2** — `OracleLib.getV2Value`, comparing the pair's current cumulative price against a stored
  checkpoint (`updateV2Observation`, permissionless, call periodically — a checkpoint from the
  current or an adjacent block is trivially manipulable, so `v2MinElapsed`, default 1800s, guards
  against that).
- **NONE** — falls back to `flatFallbackValue`, a flat owner-configured number. Also the only
  option for V4-only routes — V4 core has no built-in oracle (unlike V3, it moved that into
  opt-in hooks), so a route valued this way always uses the flat fallback rather than an
  oracle-derived number, by deliberate design choice, not as a stopgap.

Both TWAP mechanisms remain spot-manipulable within their measurement window on a thin reference
pool/pair — pool/pair selection is an owner-curated trust decision, not something this contract
can guarantee on its own.

---

## Upgradeability

UUPS proxy (`Initializable`, `UUPSUpgradeable`, `OwnableUpgradeable`), constructor calls only
`_disableInitializers()`. State lives in an ERC-7201 namespaced storage struct rather than a
trailing `__gap` array, since the router's own state is expected to grow across upgrades.
`_authorizeUpgrade` is `onlyOwner`. Reentrancy protection (`ReentrancyGuardTransient`) uses
EIP-1153 transient storage — stateless, needs no init call, and can never collide with the
namespaced storage on an upgrade.

---

## Deployment Order

1. Deploy `BlitzrSwapRouterRewardVault(owner, address(0))` — `router` set to `address(0)`
   temporarily, since the proxy doesn't exist yet.
2. Deploy the `BlitzrSwapRouter` implementation.
3. Deploy `ERC1967Proxy(implementation, initData)` — `initialize(owner, rewardVault, poolManager)`
   must be encoded directly into the proxy's own constructor call, not as a separate follow-up
   transaction, so there's never a window where the implementation is live but uninitialized
   (initializer front-running).
4. Call `vault.setRouter(proxy)`.
5. Owner configures `setAllowedTarget(...)` for each STANDARD-hop DEX target,
   `setRewardTokens(...)`, `setFeeBps(referralBps, cashbackBps)`, and `setAggregationFeeBps(...)`
   if the 0.3% default isn't right.

See `script/DeployBlitzrSwapRouter.s.sol`.

---

## Function Reference

### Admin (owner)

| Function | Description |
|----------|-------------|
| `setRewardVault(vault)` | Update the reward vault address |
| `setRewardTokens(tokens[])` | Replace the whole weighted reward-token list; weights must sum to `<= 10_000` |
| `setPoolManager(poolManager)` | Update the V4 `PoolManager` address |
| `setFeeBps(referralBps, cashbackBps)` | Update the cuts of the aggregation fee paid to referrer/swapper; each `<= 10_000` independently |
| `setAggregationFeeBps(bps)` | Update this router's own enforced take of a swap's resolved value; default 30 (0.3%) |
| `setFlatFallbackValue(value)` | Update the flat value used when `ValuationType.NONE` |
| `setV2MinElapsed(seconds)` | Update the minimum checkpoint age required for a V2 TWAP read; default 1800 |
| `setPermit2(permit2)` | Override the Permit2 address (defaults to the canonical singleton) |
| `setAllowedTarget(target, allowed)` | Allowlist (or revoke) a STANDARD-hop call target |
| `updateV2Observation(pair)` | Permissionless — refresh a V2 pair's TWAP checkpoint |

### Swap

| Function | Description |
|----------|-------------|
| `swap(hops, minFinalAmountOut, referrer, valuation) payable` | Execute a single-path route |
| `swapWithPermit(hops, minFinalAmountOut, referrer, valuation, nonce, deadline, signature)` | Same, pulling ERC20 input via Permit2 instead of a standing approval |
| `swapSplit(routes, minFinalAmountOut, referrer, valuation) payable` | Execute several parallel routes, summing their outputs |
| `swapSplitWithPermit(routes, minFinalAmountOut, referrer, valuation, nonce, deadline, signature)` | Same, via Permit2 |

### Views

| Function | Description |
|----------|-------------|
| `rewardVault()` / `rewardTokens()` / `poolManager()` / `permit2()` | Current configuration |
| `referralBps()` / `cashbackBps()` / `aggregationFeeBps()` / `flatFallbackValue()` / `v2MinElapsed()` | Current reward/valuation parameters |
| `isAllowedTarget(target)` | Whether a STANDARD-hop target is allowlisted |
| `referrerOf(swapper)` | The bound referrer for a given swapper, if any |

---

## Key Constants

| Constant | Value | Notes |
|----------|-------|-------|
| `aggregationFeeBps` (default) | 30 (0.3%) | Owner-adjustable via `setAggregationFeeBps` |
| `v2MinElapsed` (default) | 1800 seconds | Owner-adjustable via `setV2MinElapsed` |
| `permit2` (default) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Permit2's canonical cross-chain singleton |
| `referralBps` / `cashbackBps` (default) | 0 / 0 | Rewards are off until the owner configures them |
