# Blitzr Bonding Curve

A pump.fun-style launchpad: creators mint a token that trades on an internal constant-product
bonding curve until a USD-denominated market-cap target is hit, then it migrates automatically
to a real DEX. Single-contract design — `BlitzrBondingCurve` is simultaneously the token
factory, the bonding-curve AMM, and the migration engine. No proxy, no upgradeability, one
`owner` (2-step transfer).

---

## Contracts

| File | Contract | Role |
|------|----------|------|
| `BlitzrBondingCurve.sol` | `BlitzrBondingCurve` | Token creation (CREATE2 clone), bonding-curve buy/sell, USD-denominated pricing, DEX migration |
| `tokens/BlitzrStandardToken.sol` | `BlitzrStandardToken` | Plain ERC-20 + permit, no tax. Migrates to a PancakeSwap V3 1% pool, LP locked in the shared `contracts/BlitzrLocker.sol` |
| `tokens/BlitzrTaxToken.sol` | `BlitzrTaxToken` | Buy/sell tax (liquidity/reflection/marketing, ≤3% per direction). Reflection portion is swapped into 1-4 creator-chosen, platform-allowlisted tokens and pushed to holders. Migrates to V2, LP burned |

There is no bonding-curve-specific vault contract — `BlitzrStandardToken` migrations register
their V3 LP position with the same `contracts/BlitzrLocker.sol` the V3 Blitzr stack uses (see
`../contracts/BLITZR.md`), rather than a separate copy of that logic. The `locker` address is
just configured on `BlitzrBondingCurve` like any other DEX-infra address.

`BlitzrTaxToken` has no owner — every tax rate, wallet, and reflection token is fixed at
`initForBlitzr` (launch time) and can never change afterward. There is no post-launch admin
surface on the token at all.

During the bonding phase, both token types restrict transfers to `launchManager` only (the
`BlitzrBondingCurve` contract) — no secondary market can form before migration. This lifts when
`postMigrateSetup()` is called at migration.

---

## Architecture

```
Creator
  │  createToken(BaseParams)    payable   → BlitzrStandardToken
  │  createTT(CreateTTParams)   payable   → BlitzrTaxToken
  ▼
BlitzrBondingCurve
  ├─ collect creationFee → feeRecipient; excess msg.value = an early buy, executed after registration
  ├─ CREATE2-clone the token impl (salt bound to msg.sender; resulting address must end 0x1111)
  ├─ compute Alloc{ liqTokens, bcTokens } from curveBps/liquidityBps (must sum to 10 000)
  ├─ convert startMarketCapUSD / migrationMarketCapUSD → virtualBNB / migrationTarget,
  │  via a live spot read of the configured USDC/WBNB pair
  ├─ [BlitzrStandardToken only] create + price-initialize its V3 pool now, at the exact
  │  migrationTarget:liqTokens ratio — see "Pool Creation" below. token.pair is non-zero
  │  from this point on, before the token even exists yet.
  ├─ [BlitzrTaxToken only] validate tax bps ≤ 3% per direction, reflection tokens against
  │  the reflectionTokenAllowed whitelist — see "BlitzrTaxToken" below
  ├─ token.initForBlitzr(...) → full supply minted to BlitzrBondingCurve itself
  │  (BlitzrTaxToken also creates its V2 pair here, same as always)
  └─ register TokenConfig { virtualBNB, k = virtualBNB × bcTokens, raisedBNB = 0, pair, ... }

Trading
  ├─ buy(token, minOut, deadline)     payable  → constant-product curve, antibot decay, auto-migrate at cap
  └─ sell(token, amountIn, minOut, deadline)   → capped at raisedBNB; cannot pay out BNB never received

Migration (triggered automatically at the buy that reaches migrationTarget)
  ├─ BlitzrStandardToken → wrap BNB, mint a full-range position into the pool already created
  │                        at launch, directly to the shared BlitzrLocker, register it —
  │                        creator earns an ongoing fee share
  └─ BlitzrTaxToken      → addLiquidityETH on V2, LP sent to the dead address
```

---

## Bonding Curve

Constant-product `k = virtualBNB × bcTokensTotal`, where `virtualBNB` seeds the curve's opening
price without any BNB actually being in the pool yet:

```
poolBNB    = virtualBNB + raisedBNB
poolTokens = bcTokensTotal - bcTokensSold

tokensOut = poolTokens - k / (poolBNB + netBNBIn)     [buy]
grossBNB  = poolBNB    - k / (poolTokens + tokensIn)  [sell]
```

A buy that would push `raisedBNB` past `migrationTarget` is capped: it fills the remainder of
the curve exactly (`tokensOut = poolTokens`) and refunds any excess BNB, rather than reverting.
The sell path can never pay out more BNB than `raisedBNB` actually holds
(`InsufficientPoolBNB`).

**Antibot** — during the first `antibotBlocks` blocks after creation (owner range: 10–199), a
linearly-decaying fraction of every buy's output is sent to `0x...dEaD` instead of the buyer.
The penalty is 100% at the creation block and 0% by the last block of the window. The creator's
own early buy at launch skips this.

---

## USD-Denominated Pricing

`startMarketCapUSD` and `migrationMarketCapUSD` are both 18-decimal USD figures, converted to
BNB at creation time via a live spot read of a configured USDC/WBNB PancakeSwap V2 pair:

```
virtualBNB      = (startMarketCapUSD     × wbnbReserve / totalSupply) × curveTokens / usdcReserve
migrationTarget = (migrationMarketCapUSD × wbnbReserve / totalSupply) × liqTokens   / usdcReserve
```

Division precedes the final multiply in both terms to stay within `uint256` without a 512-bit
`mulDiv`. The quote pair is owner-configurable (`setUsdQuotePair`, validated against the
router's `WETH()` on set). USDC decimals vary by chain — pass `startMarketCapUSD`/
`migrationMarketCapUSD` already scaled to match (`5000e18` on BSC where USDC is 18-decimal,
`5000e6` on Ethereum where it's 6-decimal); the math itself is decimal-agnostic since it only
ever works in each token's own raw units.

---

## Pool Creation

Both token types track their own trading pair from the moment they're created, not from
migration:

- **BlitzrStandardToken**: `createToken()` calls `_createV3Pool` right after cloning the token,
  before its `TokenConfig` is even registered — it creates the V3 pool (or adopts an existing
  uninitialized shell) and price-initializes it at exactly `migrationTarget : liqTokens`, the
  ratio migration will actually deposit at. `TokenConfig.pair` is non-zero from registration
  onward. The pool holds no liquidity yet — that's only added at migration (see below) — but
  its address and opening price are fixed from block one.
- **BlitzrTaxToken**: unchanged — `initForBlitzr` creates its PancakeSwap V2 pair immediately,
  same as it always has.

**Why this matters**: `createPool` on the V3 factory is permissionless, so an attacker can
front-run a predictable `BlitzrStandardToken` CREATE2 address with their own pre-initialized
pool. Creating the pool inside `createToken()` itself means that collision (`PoolAlreadyExists`)
reverts the whole launch immediately — the creator loses only gas and can retry with a fresh
salt — instead of surfacing much later, mid-raise, after real trader funds are already
committed to the bonding curve (the old failure mode, back when pool creation was deferred to
migration).

Both token types also already enforce the launch-phase transfer restriction (see "Security
Properties") from creation, which blocks anyone — including via a direct `transfer()` call
bypassing `buy()`/`sell()` — from feeding real token liquidity into either pair before
`postMigrateSetup()` runs at migration. The pair existing early doesn't mean it's usable early.

---

## Migration

Triggered automatically inside the buy that pushes `raisedBNB` to `migrationTarget`
(`_finalizeBuy` → `try IBondingCurveSelf(address(this))._tryMigrateExternal(...)`). If it
reverts, `migrationPending = true` is set, blocking further trading until:

```solidity
bondingCurve.migrate(token)             // anyone; requires migrationPending == true
bondingCurve.emergencyMigrate(token)    // owner only; bypasses the DEX, sends funds to owner
```

**BlitzrStandardToken → V3**: BNB wrapped to WBNB, a full-range position minted into the pool
already created at launch (see "Pool Creation" above) directly to the shared
`contracts/BlitzrLocker.sol` and registered — the creator earns an ongoing share of the pool's
own trading fees indefinitely. Uses `TokenConfig.v3PositionManager`, snapshotted at creation
time alongside the pool itself, not whatever `v3PositionManager` happens to be set to right now
— a `setV3PositionManager` call between creation and migration can't mismatch the two.

**BlitzrTaxToken → V2**: `addLiquidityETH` with the raised BNB and the liquidity token
allocation; LP tokens sent straight to the dead address, permanently burned.

Both paths enforce 99% minimums on token and BNB amounts against migration-time sandwich
attacks. `postMigrateSetup()` is then called on the token to lift the bonding-phase transfer
restriction.

**Invariants maintained throughout:**
- `tc.raisedBNB ≤ _totalRaisedBNB ≤ address(this).balance`
- `bcTokensSold == bcTokensTotal` when migration triggers — no unsold curve tokens exist at the cap
- `rescueBNB` can only withdraw `balance - _totalRaisedBNB`, never active pool BNB

---

## LP Lock (BlitzrLocker)

`BlitzrStandardToken` migrations reuse `contracts/BlitzrLocker.sol` — the same permanent V3
LP-lock and fee-distribution contract the V3 Blitzr stack uses — instead of a bonding-curve-specific
vault. `BlitzrBondingCurve` calls `registerPosition` on it exactly like `BlitzrLauncher` does; see
`../contracts/BLITZR.md` → "Fee Wallet & Claiming" for the full `claimFees`/`pendingCreatorFees`/
`setFeeBps` surface, the 85/15 creator/platform default split, and the CTO and per-token burn
features that come along with reusing it.

`BlitzrTaxToken` never touches the locker — its LP is burned outright at migration instead.

---

## BlitzrTaxToken

Buy/sell tax across exactly three categories — **liquidity**, **reflection**, **marketing** —
each direction independently capped at `MAX_TOTAL_TAX = 300` (3%). There is no burn category and
no team/treasury split; those were dropped along with the plain (non-reflecting) tax token this
type replaced.

**No owner, ever.** Every tax rate, the marketing wallet, and the reflection token list are
fixed at `initForBlitzr` — there is no `_owner`, no post-launch setter, and `setMetaURI` is a
permanent revert stub kept only to satisfy the shared `IBlitzrLaunchToken` interface. What a
creator configures at launch is what the token runs with forever.

### Reflection tokens

If either `buyReflectionTax` or `sellReflectionTax` is nonzero, the creator must supply 1-4
reflection token addresses at launch, each of which must already be allowlisted by the platform
owner:

```solidity
bondingCurve.setReflectionTokenAllowed(token, true)   // owner only
bondingCurve.reflectionTokenAllowed(token)             // view
```

`BlitzrTaxToken.initForBlitzr` re-validates every entry itself (calling back into
`launchManager.reflectionTokenAllowed`), rejects duplicates, and enforces the 1-4 bound — so the
invariant holds regardless of which `launchManager` deploys it, not just because
`BlitzrBondingCurve` happened to check first. If no reflection tax is configured, the list may be
empty; there is no native, swap-free reflection mode.

**Swapping and distributing are two separate steps, not one.** Neither happens automatically
end-to-end:

1. **Swap** — the reflection-tax portion of every buy/sell accumulates in the token's own
   balance until `swapThreshold` is crossed, at which point it's split evenly across the
   configured reflection tokens (remainder folded into the last one) and each share is swapped
   independently via the router. This part *is* automatic (triggered inside `_transfer`), same
   as the liquidity/marketing swap. The received reflection tokens are **not** pushed anywhere
   at this point — they simply sit in the contract's own balance, per reflection token.
2. **Distribute** — `distributeReflection()` is a separate, permissionless, explicitly-called
   function. It reads whatever balance of each configured reflection token the contract
   currently holds (which may reflect several accumulated swaps since the last call) and pushes
   it out proportionally to every holder whose balance is at or above `reflectionMinBalance`.
   Eligibility and eligible-supply are computed once per call and reused across all configured
   tokens, since nothing in the loop changes this token's own holder balances.

`MAX_REFLECTION_HOLDERS = 500` bounds the holder list `distributeReflection()` iterates over.
Since distribution is its own transaction rather than something bundled into an ordinary
buy/sell, this cost is only ever paid by whoever chooses to call it — never forced onto a
trader. Holders beyond the cap keep trading normally but stop receiving new reflection pushes.

`manualSwap()` is permissionless and only triggers step 1 early (swap, not distribute) at the
fixed destinations already configured at launch; it cannot misdirect anything.

### Views

```solidity
token.getTaxConfig()                    // all six tax bps + marketingWallet in one call
token.getTotalBuyTax() / getTotalSellTax()

token.getReflectionTokens()             // the full configured list (1-4 addresses)
token.reflectionTokenCount()
token.isReflectionToken(token)
token.pendingReflectionBalance(token)   // balance of one token awaiting distributeReflection()
token.pendingReflectionBalances()       // the above for every configured token, in one call
token.eligibleReflectionSupply()        // total holder balance that currently qualifies
token.pendingReflectionFor(holder)      // per-token preview of what a holder would receive right now

token.getHolders()                      // full current holder list (bounded to 500)
token.holderCount()
token.isHolder(account)
token.isExcludedFromFee(account) / isExcludedFromReflection(account)
```

---

## Governance

All instant, `onlyOwner` — no timelock in this variant:

| Function | What it changes |
|---|---|
| `setCreationFee` | BNB fee required to create a token |
| `setAllocationBounds` | `minCurveBps`, `minLiquidityBps` |
| `setSupplyBounds` | `minSupply`, `maxSupply` |
| `setStandardImpl` / `setTaxImpl` | Clone implementation addresses |
| `setReflectionTokenAllowed` | Allow/disallow a token as a BlitzrTaxToken reflection target |
| `setLocker` | `contracts/BlitzrLocker.sol` address |
| `setRouter` | PancakeSwap V2 router (validated: `factory()`/`WETH()` non-zero) |
| `setV3PositionManager` / `setV3Factory` | V3 infrastructure addresses |
| `setUsdQuotePair` | USDC/WBNB quote pair (validated to contain USDC + the router's WETH) |
| `setPlatformFee` | Bps charged on every buy/sell, hard-capped at 2.5% (`MAX_TOTAL_FEE`) |
| `setFeeRecipient` | Platform fee destination |
| `transferOwnership` / `acceptOwnership` | 2-step ownership transfer |

### Rescue

```solidity
bondingCurve.rescueBNB(to)            // only withdraws balance surplus above _totalRaisedBNB
bondingCurve.rescueToken(token, to)   // only callable after migration, or for unrelated ERC-20s
```

---

## Security Properties

**Reentrancy** — `nonReentrant` on every state-mutating public function. `_tryMigrateExternal`
is deliberately unguarded so the outer buy can `try/catch` it while still holding the
reentrancy lock; it's gated to `msg.sender == address(this)` instead, so no external caller can
reach it directly.

**DoS via pre-initialized V3 pool** — `createPool` on the V3 factory is permissionless, so an
attacker can pre-initialize a pool at a `BlitzrStandardToken`'s CREATE2-predicted address. Since
pool creation now happens inside `createToken()` itself (see "Pool Creation"), that collision
(`PoolAlreadyExists`) reverts the whole launch immediately — no funds or trading were ever at
risk, the creator just retries with a fresh salt. `migrationPending` still exists as a fallback
for other reasons `_tryMigrateExternal` might revert at the actual migration step, but the V3
pool-collision case specifically can no longer strand a bonding curve mid-raise.

**Launch-phase transfer restriction** — every token type blocks transfers to/from any address
other than `launchManager` until `postMigrateSetup()` runs, so no pool can receive real token
liquidity pre-migration — closing off the balance side of the same pre-initialization attack.

**Front-running salt** — `_cloneCreate2` binds the salt to `keccak256(abi.encode(msg.sender,
userSalt))`, so a mined vanity salt can't be stolen by a front-runner deploying from a different
address.

**Router / position-manager snapshots** — `tc.router` and (for `BlitzrStandardToken`)
`tc.v3PositionManager` are captured at registration; a later `setRouter` or
`setV3PositionManager` call doesn't affect tokens already on the curve. `v3Factory` needs no
equivalent snapshot — it's only ever read live, at `createToken()` time, since pool creation
now happens there instead of at migration.

---

## Constructor Arguments

### BlitzrBondingCurve

```solidity
constructor(
    address router_,             // PancakeSwap V2 router
    address v3PositionManager_,  // PancakeSwap V3 NonfungiblePositionManager
    address v3Factory_,          // PancakeSwap V3 Factory
    address feeRecipient_,       // Platform fee destination
    uint256 platformFee_,        // Bps on every buy/sell, ≤ 250 (2.5%)
    address standardImpl_,       // Deployed BlitzrStandardToken implementation
    address taxImpl_,            // Deployed BlitzrTaxToken implementation
    address locker_,             // Deployed contracts/BlitzrLocker.sol
    address usdcToken_,          // USDC address for this chain
    address usdQuotePair_,       // USDC/WBNB V2 pair — validated to contain both
    uint256 creationFee_         // BNB required to launch a token (may be 0)
)
```

---

## Deployment Order

`BlitzrLocker` needs a `launcher` address and `BlitzrBondingCurve` needs a `locker` address —
resolve the circular dependency by deploying the locker first with a temporary launcher, then
wiring the real address after.

`BlitzrLocker.launcher` is a single address (`onlyLauncher` gates `registerPosition` to exactly
one caller) — it **cannot** be shared between the V3 `BlitzrLauncher` and `BlitzrBondingCurve`
at the same time; whichever one is set last via `setLauncher` is the only one that can register
new positions. Deploy a **separate** `BlitzrLocker` instance for this stack rather than pointing
it at the V3 stack's existing one.

1. Deploy `BlitzrStandardToken` / `BlitzrTaxToken` implementations (clone targets; constructors set `_initialized = true`).
2. Deploy `contracts/BlitzrLocker.sol(platformWallet_)` — a dedicated instance for this stack.
3. Deploy `BlitzrBondingCurve(...)` with the locker address from step 2.
4. Call `locker.setLauncher(bondingCurve)` — until this runs, `registerPosition` reverts for every real migration.
5. Call `bondingCurve.setReflectionTokenAllowed(token, true)` for every token creators should be able to select as a BlitzrTaxToken reflection target.

---

## Key View Functions

```solidity
bondingCurve.getToken(token)                           // full TokenConfig struct
bondingCurve.getAmountOut(token, bnbIn)                 // (tokensOut, feeBNB) — buy quote
bondingCurve.getAmountOutSell(token, tokensIn)          // (bnbOut, feeBNB)    — sell quote
bondingCurve.getSpotPrice(token)                        // price in BNB per token (18-decimal)
bondingCurve.previewBNBTargets(startUSD, migUSD, ...)   // (virtualBNB, migrationTarget) for given params
bondingCurve.predictTokenAddress(creator, salt, impl)   // CREATE2 address before deployment
bondingCurve.totalTokensLaunched()                      // allTokens.length
bondingCurve.getTokensByCreator(creator)                // all tokens by one address
```

---

## Key Constants

| Constant | Value | Notes |
|---|---|---|
| `MAX_TOTAL_FEE` | 250 bps (2.5%) | Hard cap on `platformFee` |
| `ANTIBOT_MIN_BLOCKS` / `ANTIBOT_MAX_BLOCKS` | 10 / 199 | Valid range for `antibotBlocks` |
| `V3_FEE_TIER` | 10 000 (1%) | Tick spacing 200 |
| `V3_MIN_TICK` / `V3_MAX_TICK` | ±887 200 | Full-range V3 position |
| `minCurveBps` (default) | 3 000 (30%) | Minimum bonding-curve allocation |
| `minLiquidityBps` (default) | 1 000 (10%) | Minimum DEX liquidity at migration |
| `minSupply` / `maxSupply` (default) | 1e18 / 999 trillion × 1e18 | Per-launch `totalSupply` bounds |
