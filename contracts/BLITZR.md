# Blitzr — Token Launcher

Blitzr lets anyone deploy a meme token and seed permanent one-sided V3 liquidity in a single transaction on any registered DEX. Liquidity is locked forever in BlitzrLocker; only accrued swap fees can be claimed.

---

## Contracts

| File | Contract | Role |
|------|----------|------|
| `BlitzrToken.sol` | `BlitzrToken` | ERC-20 + EIP-2612 implementation used as the EIP-1167 clone template |
| `BlitzrLauncher.sol` | `BlitzrLauncher` | Orchestrates every launch — clones token, creates pool, seeds one-sided liquidity |
| `BlitzrLocker.sol` | `BlitzrLocker` | Permanent LP-NFT vault; distributes swap fees to creator and platform, with an optional per-token burn |

---

## Architecture

```
Creator
  │
  │  launch(name, symbol, metaURI, feeWallet, factory, quoteToken)  payable
  │  msg.value = launchFee + (optional) extra ETH for an instant buy
  ▼
BlitzrLauncher
  ├─ validates factory  →  looks up DexConfig (positionManager, router)
  ├─ clone(BlitzrToken impl)  →  BlitzrToken (1 B supply minted to launcher)
  ├─ call{value: launchFee}(launchFeeWallet)  ← fee is always native ETH/BNB,
  │                                              regardless of quoteToken; never touches the pool
  ├─ V3Factory.createPool(quoteToken, blitzrToken, 1%)
  ├─ pool.initialize(computeSqrtPriceX96)  →  marketCapRef market cap price
  ├─ pool.slot0()  →  currentTick  →  compute one-sided tick range
  ├─ positionManager.mint(one-sided: BlitzrToken only)  →  LP NFT  →  BlitzrLocker
  ├─ BlitzrLocker.registerPosition(token, tokenId, feeWallet, token0, token1, pool, positionManager)
  ├─ [if extra ETH sent] WETH.deposit(extra)  then either:
  │     quoteToken == WETH  →  swapRouter.exactInputSingle(WETH → blitzrToken → creator)
  │     quoteToken != WETH  →  swapRouter.exactInput(WETH → quoteToken → blitzrToken → creator)  (multihop)
  └─ transfer(remaining mint-rounding dust → creator)

BlitzrLocker  (holds LP NFTs forever)
  └─ claimFees(token)  →  the launched-token leg: split 85% feeWallet + 15% platformWallet by
                          default, or if burn is enabled for that token, sent entirely to
                          BURN_ADDRESS instead
                        →  the quote-token leg: always split 85% feeWallet + 15% platformWallet
```

The quote token is purely the pool's pairing partner — the creator never sends or approves
any ERC-20 to launch. All payment (fee + optional instant buy) is native ETH/BNB only.

---

## Launch Flow

1. **Validate** — launcher checks the factory is in the DEX registry and the quote token is registered.

2. **Fee collection & routing** — `launch()` is always payable; `msg.value` must be `>= launchFee` (a single global value, in native ETH/BNB, regardless of which quote token is used). The fee is sent directly to `launchFeeWallet` as raw ETH. Any ETH above the fee becomes `extraEth`, reserved for the instant buy in step 7. No ERC-20 is ever pulled from the creator at launch time — the quote token is only used to pick the pool's pairing partner and the price target.

3. **Token deployment** — an EIP-1167 minimal-proxy clone of `BlitzrToken` is deployed and `initBlitzr` is called. `metaURI` is written, **1 000 000 000** tokens are minted to the launcher, and the anti-bot window is armed (`antiBotEndBlock = block.number + antiBotBlocks`, see *Anti-Bot Max-Wallet Cap*).

4. **Pool creation** — a V3 pool (`quoteToken / BlitzrToken`, **1 % fee tier**) is created on the chosen DEX and initialised at a price targeting the quote token's configured `marketCapRef` (`marketCapRef / TOTAL_SUPPLY`). Reverts with `PoolAlreadyExists` if that pair already has an *initialized* 1 % pool on the same factory — an uninitialized shell (e.g. created but not initialized by someone else) is adopted and initialized by this launch instead. Immediately after, the pool address is exempted from the anti-bot cap (`BlitzrToken.setExempt(pool, true)`) — it's about to receive ~100% of supply as locked liquidity via the mint in the next step, which would otherwise trip the cap itself.

5. **One-sided liquidity seeding** — the current tick is read from `pool.slot0()` immediately after initialisation and used to compute a one-sided tick range:

   - **BlitzrToken = token0** (lower address): `tickLower = floor(currentTick / 200) × 200 + 200`, `tickUpper = +887 200` → position is entirely in token0 (BlitzrToken) since `currentTick < tickLower`.
   - **BlitzrToken = token1** (higher address): `tickLower = −887 200`, `tickUpper = floor(currentTick / 200) × 200` → position is entirely in token1 (BlitzrToken) since `currentTick ≥ tickUpper`.

   **100 %** of supply (1 000 000 000 tokens) is deposited. No quote token enters the pool. The LP NFT goes directly to `BlitzrLocker`.

6. **Locker registration** — `BlitzrLocker.registerPosition` records the NFT id, fee wallet, pool address, and position manager for this launch.

7. **Instant buy** — if any `extraEth` remains, it's wrapped to WETH and swapped into blitzr tokens for the creator, atomically with the launch:
   - **quoteToken == WETH**: direct single-hop swap, `exactInputSingle(WETH → blitzrToken)`.
   - **quoteToken != WETH**: multihop swap, `exactInput(WETH → quoteToken → blitzrToken)`, via `ISwapRouter.exactInput` with an encoded path. This requires a real, liquid WETH/quoteToken pool to already exist on the same DEX at the fee tier configured for that quote token (`QuoteToken.wethPairFee`) — set by the owner when registering the quote token.

8. **Creator allocation** — none, by design. The full supply is seeded; any tiny mint-rounding dust left in the launcher is swept to the creator, but there is no deliberate reserve. The creator only holds tokens if they bought some via the instant buy in step 7.

---

## Price Initialisation

The pool is initialised at a price corresponding to a **`marketCapRef`** market cap for the full 1 B token supply. `marketCapRef` is stored per quote token (`QuoteToken.marketCapRef`), not a single global constant. The computation adjusts for which address becomes `token0`:

```
BlitzrToken < quoteToken  →  price = marketCapRef / TOTAL_SUPPLY  (small)
quoteToken < BlitzrToken  →  price = TOTAL_SUPPLY / marketCapRef  (large)
```

WETH defaults to `marketCapRef = 5e18` (5 WETH in raw units) in the constructor. Every other quote token's `marketCapRef` is set explicitly when it's registered via `addQuoteToken`, and can be updated later via `setMarketCapRef` — it must already be expressed in that token's raw smallest-unit terms.

The `sqrtPriceX96` is derived using the two-step overflow-safe formula (see *sqrtPriceX96 Derivation* below).

---

## DEX Registry

BlitzrLauncher maintains a whitelist of V3-compatible DEXes. Each entry maps a factory address to its position manager and swap router.

The caller passes the factory address of their chosen DEX to `launch()`. The launcher validates it against the registry and uses the stored position manager and router for all DEX interactions.

```
dexes[factory] = DexConfig { positionManager, router, enabled }
```

Owner functions:

| Function | Description |
|----------|-------------|
| `addDex(factory, positionMgr, router)` | Register or update a DEX |
| `disableDex(factory)` | Block new launches on this factory; existing positions unaffected |

---

## Quote Tokens

Quote tokens are DEX-agnostic — the same token (e.g. USDC) can be used on any registered DEX.
A quote token is purely the pool's pairing partner and the price-target reference — it carries
no fee of its own; all fees are native ETH/BNB (see *Launch Fee Wallet*).

| Function | Description |
|----------|-------------|
| `addQuoteToken(token, marketCapRef, wethPairFee)` | Register or update a quote token. `wethPairFee` is the fee tier of an existing, liquid WETH/`token` pool on the DEX, used to build the multihop instant-buy path; ignored (pass `0`) when `token == WETH` |
| `disableQuoteToken(token)` | Block new launches using this token |
| `setMarketCapRef(token, ref)` | Update the price-init reference for an already-registered quote token |

| Quote token | marketCapRef | wethPairFee |
|-------------|--------------|-------------|
| WETH | 5e18 (set in constructor) | unused |
| USDC | Set by owner | Set by owner, e.g. the deepest existing WETH/USDC pool's fee tier |
| Any ERC-20 | Set by owner | Set by owner |

---

## Launch Fee Wallet

`launchFeeWallet` is a platform-level address that receives the launch fee for every token deployed, paid as raw native ETH/BNB (`launchFeeWallet.call{value: launchFee}("")`). It is set in the constructor and updatable by the owner via `setLaunchFeeWallet`.

`launchFee` is a single global value (not per quote token), set in the constructor and updatable by the owner via `setLaunchFee(fee)`. It applies identically regardless of which quote token a launch uses.

This is separate from the per-launch `feeWallet` stored in BlitzrLocker, which receives the creator's share of ongoing LP swap fees.

---

## Fee Wallet & Claiming (BlitzrLocker)

- The per-launch `feeWallet` is set by the creator at launch; defaults to `msg.sender` if `address(0)` is passed.
- **Only the fee wallet OR the platform owner** may call `claimFees(token)`.
- The platform owner may also call `claimAllFees()` or `claimFeesRange(from, to)` to sweep positions in bulk.

### Fee split

Default values — updatable by the locker owner via `setFeeBps(creator, platform)`. The two values must sum to exactly 10 000.

| Recipient | Default share | Interaction |
|-----------|--------------|-------------|
| Creator fee wallet | 85 % (8 500 bps) | Initiates `claimFees` |
| Platform wallet | 15 % (1 500 bps) | Passive recipient |

Fees are distributed atomically. Platform receives the remainder after creator to absorb rounding dust.

This split applies to whichever leg *isn't* being burned — see below.

### Per-token burn (default off)

Each launch's V3 pool pairs two tokens: the launched token itself, and the quote token. On
every `claimFees(token)`, `BlitzrLocker` determines which of `token0`/`token1` is actually the
launched token (comparing against the `token` argument itself, not a fixed position, since V3
address-sort ordering varies per launch) and treats its leg differently from the quote leg:

- **The launched-token leg**: if burn is enabled for that token, the *entire* amount is sent to
  `BURN_ADDRESS` (the conventional `0x...dEaD` address — `BlitzrToken._transfer` reverts on
  transfers to the zero address, so the dead address is used instead) — not split with
  creator/platform first. Off by default, in which case this leg follows the normal
  creator/platform split like any other.
- **The quote-token leg**: never burned — always follows the normal creator/platform split,
  regardless of the token's burn setting.

```solidity
function burnEnabled(address token) public view returns (bool)
function setBurnEnabled(address token, bool enabled) external
```

`setBurnEnabled` is callable by either the token's own `feeWallet` (their project, their
tokenomics) or the locker owner (the same override authority `ctoFeeWallet` already has over
feeWallet-scoped settings). Toggling takes effect on the *next* claim — it doesn't retroactively
affect fees already distributed.

### Pending fee view

```solidity
pendingCreatorFees(address token)
    returns (address token0, address token1, uint256 amount0, uint256 amount1)
```

Returns the creator's share of currently uncollected fees, computed using the full Uniswap V3 fee-growth formula without modifying state. If burn is enabled for the token, the leg matching the launched token itself is reported as `0` here — that leg goes to `BURN_ADDRESS` on claim, not to the creator.

---

## BlitzrToken

Each launched token is an EIP-1167 clone of the `BlitzrToken` implementation contract.

- Standard ERC-20, 18 decimals, 1 B fixed supply — no mint, no dedicated burn function, no tax.
  (`BlitzrLocker` can still reduce effective circulating supply by sending its collected fee leg
  to the dead address as a plain `transfer` — see *Per-token burn* — but the token contract
  itself has no `burn()` and never destroys balances directly.)
- EIP-2612 `permit` for gasless approvals and DEX aggregator support
- `metaURI()` — set once at `initBlitzr`, updatable by owner thereafter
- Implementation constructor sets `_initialized = true` to block direct use
- **Anti-bot max-wallet cap** — see *Anti-Bot Max-Wallet Cap* below

---

## Anti-Bot Max-Wallet Cap

For `antiBotBlocks` blocks after launch (set per-launch by the launcher, owner-adjustable via
`BlitzrLauncher.setAntiBotBlocks`, default 10), no non-exempt address may hold more than
**2.5 %** (`MAX_WALLET_BPS = 250`) of a launched token's total supply. Enforced directly in
`BlitzrToken._transfer` — checked against the *recipient's* resulting balance on every transfer,
so it catches accumulation across multiple smaller buys, not just one large one, and applies
uniformly regardless of whether the transfer came from a DEX swap or a direct wallet-to-wallet
send.

```solidity
uint256 public constant MAX_WALLET_BPS = 250; // 2.5 %
uint256 public antiBotEndBlock;
mapping(address => bool) public isExempt;

function setExempt(address account, bool exempt_) external; // owner-only
```

Because the cap applies to *every* non-exempt recipient, including the creator's own instant-buy
at launch, a creator requesting an instant buy larger than 2.5 % of supply will revert the whole
`launch()` call during the anti-bot window — there's no creator carve-out by default.

Two addresses are exempted automatically by the launcher before it renounces ownership, since
both structurally hold far more than 2.5 % of supply by design:
- **The pool address** — holds ~100 % of supply as locked liquidity.
- **`BURN_ADDRESS`** — accumulates burned tokens indefinitely across every `claimFees` call
  where burn is enabled; without exemption it would eventually exceed the cap and brick further
  burns for the rest of the anti-bot window.

`setExempt` is owner-only, so no further exemptions can be granted once the launcher renounces
ownership at the end of `launch()` — the exemption list is effectively frozen at launch time.

---

## Constructor Arguments

### BlitzrLocker

```solidity
constructor(
    address platformWallet_  // Receives 15 % of claimed swap fees (default)
)
```

### BlitzrLauncher

```solidity
constructor(
    address weth_,               // WETH contract
    address tokenImpl_,          // BlitzrToken implementation (deployed separately)
    address locker_,             // BlitzrLocker (set its launcher to this address after deploy)
    address launchFeeWallet_,    // Platform wallet that receives per-launch fees (native ETH/BNB)
    address initialFactory_,     // Factory of the first supported V3 DEX
    address initialPositionMgr_, // Position manager of the first supported V3 DEX
    address initialRouter_,      // Swap router of the first supported V3 DEX
    uint256 launchFee_           // Global launch fee, in native ETH/BNB raw units
)
```

---

## Deployment Order

1. Deploy `BlitzrToken` implementation (no constructor args)
2. Deploy `BlitzrLocker(platformWallet)`
3. Deploy `BlitzrLauncher(weth, tokenImpl, locker, launchFeeWallet, factory, positionMgr, router, launchFee)`
4. Call `BlitzrLocker.setLauncher(blitzrLauncher)`
5. Call `BlitzrLauncher.addDex(...)` for each additional DEX
6. Call `BlitzrLauncher.addQuoteToken(...)` for USDC, WBTC, or other supported assets

---

## Function Reference

### BlitzrLauncher (owner)

| Function | Description |
|----------|-------------|
| `addDex(factory, positionMgr, router)` | Register or update a V3-compatible DEX |
| `disableDex(factory)` | Prevent new launches on this factory |
| `addQuoteToken(token, marketCapRef, wethPairFee)` | Register or update an accepted quote token |
| `disableQuoteToken(token)` | Prevent new launches using this quote token |
| `setLaunchFee(fee)` | Update the global native launch fee (applies to all quote tokens) |
| `setMarketCapRef(token, ref)` | Update the price-init reference for an existing quote token |
| `setLaunchFeeWallet(wallet)` | Update the platform launch-fee recipient |
| `setAntiBotBlocks(blocks)` | Update how many blocks after launch the anti-bot max-wallet cap applies for |
| `rescueETH(to, amount)` | Recover ETH stuck in this contract (e.g. from a failed launch mid-flight) |
| `rescueERC20(token, to, amount)` | Recover ERC-20 tokens stuck in this contract |
| `transferOwnership(newOwner)` | Transfer launcher admin |

### BlitzrLauncher (public)

| Function | Description |
|----------|-------------|
| `launch(name, symbol, metaURI, feeWallet, factory, quoteToken) payable` | Deploy token, seed one-sided pool, lock LP — returns `(token, pool, tokenId)`. `msg.value` must be `>= launchFee`; any excess funds an instant buy |

### BlitzrLocker (owner)

| Function | Description |
|----------|-------------|
| `setLauncher(launcher)` | Set the address authorised to call `registerPosition` |
| `setPlatformWallet(wallet)` | Update platform fee recipient |
| `setFeeBps(creator, platform)` | Update fee split; must sum to 10 000 |
| `claimAllFees()` | Sweep all positions; skips failures |
| `claimFeesRange(from, to)` | Paginated sweep of `allTokens[from..to)` |
| `transferOwnership(newOwner)` | Transfer locker admin |

### BlitzrLocker (fee wallet or owner)

| Function | Description |
|----------|-------------|
| `claimFees(token)` | Collect and distribute fees for one token |
| `setBurnEnabled(token, enabled)` | Toggle whether this token's launched-token fee leg is burned instead of paid out (default: off) |

### BlitzrLocker (view)

| Function | Returns | Description |
|----------|---------|-------------|
| `pendingCreatorFees(token)` | `(token0, token1, amount0, amount1)` | Creator's share of uncollected fees |
| `tokenCount()` | `uint256` | Number of registered positions |
| `positions(token)` | `Position` | Full position record for a launched token |
| `allTokens(i)` | `address` | Launched token at index `i` |
| `burnEnabled(token)` | `bool` | Whether this token's launched-token fee leg is currently burned on claim |

### BlitzrToken (public)

Standard ERC-20 (`transfer`, `transferFrom`, `approve`, `allowance`, `balanceOf`, `totalSupply`, `name`, `symbol`, `decimals`) plus:

| Function | Description |
|----------|-------------|
| `metaURI()` | Returns the token's metadata URI |
| `permit(owner, spender, value, deadline, v, r, s)` | EIP-2612 gasless approval |
| `DOMAIN_SEPARATOR()` | EIP-712 domain separator (chain-fork safe) |
| `antiBotEndBlock()` | Block number after which the anti-bot max-wallet cap no longer applies |
| `isExempt(account)` | Whether `account` is exempt from the anti-bot cap |
| `setExempt(account, exempt)` | Owner-only (window before the launcher renounces); grant/revoke an exemption |

---

## Key Constants (BlitzrLauncher)

| Constant | Value | Notes |
|----------|-------|-------|
| `TOTAL_SUPPLY` | 1 000 000 000 × 10¹⁸ | Fixed supply per token; 100 % seeded one-sided into V3 |
| `marketCapRef` (per quote token) | 5 × 10¹⁸ for WETH by default | Reference for price init — set per quote token via `addQuoteToken`/`setMarketCapRef`, not a single global constant |
| `wethPairFee` (per quote token) | Set by owner | Fee tier of the WETH/quoteToken pool used for multihop instant-buy routing; unused for WETH itself |
| `launchFee` | Set in constructor, owner-updatable | Single global value, native ETH/BNB, applies to every quote token |
| `FEE_TIER` | 10 000 (1 % V3 tier) | Tick spacing 200 |
| `MIN_TICK` | −887 200 | Floor tick for 1 % tier |
| `MAX_TICK` | +887 200 | Ceiling tick for 1 % tier |
| `TICK_SPACING` | 200 | Required by 1 % fee tier |
| `antiBotBlocks` | 10 by default, owner-updatable | Blocks after launch during which `BlitzrToken`'s 2.5 % max-wallet cap applies |
| `MAX_WALLET_BPS` (on `BlitzrToken`) | 250 (2.5 %) | Fixed constant, not adjustable |

---

## sqrtPriceX96 Derivation

Pool initialisation price is computed on-chain without overflowing `uint256`:

```
scaled           = (amount1 << 96) / amount0    →  price × 2^96
sqrt(scaled)     = sqrt(price) × 2^48
sqrt(scaled) << 48 = sqrt(price) × 2^96         ✓  (= sqrtPriceX96)
```

Max intermediate: `TOTAL_SUPPLY × 2^96 ≈ 7.92 × 10⁵⁵ ≪ 2^256`. Safe for all valid quote token amounts.

---

## One-Sided Tick Range

After `pool.initialize(sqrtPriceX96)`, `pool.slot0()` returns `currentTick`. The floor function handles negative ticks (Solidity truncates towards zero):

```
floorToTickSpacing(tick):
    compressed = tick / TICK_SPACING
    if tick < 0 && tick % TICK_SPACING != 0: compressed -= 1
    return compressed * TICK_SPACING
```

| BlitzrToken ordering | tickLower | tickUpper | V3 condition met |
|---------------------|-----------|-----------|-----------------|
| token0 (lower addr) | `floor(currentTick) + 200` | +887 200 | `currentTick < tickLower` → all token0 |
| token1 (higher addr) | −887 200 | `floor(currentTick)` | `currentTick ≥ tickUpper` → all token1 |

---

## Pending Fee Formula

`pendingCreatorFees` uses the standard Uniswap V3 fee-growth derivation:

```
feeGrowthBelow  = tick.feeGrowthOutside  (if currentTick ≥ tickLower)
                  global − tick.feeGrowthOutside  (otherwise)

feeGrowthAbove  = tick.feeGrowthOutside  (if currentTick < tickUpper)
                  global − tick.feeGrowthOutside  (otherwise)

feeGrowthInside = feeGrowthGlobal − feeGrowthBelow − feeGrowthAbove

pending         = liquidity × (feeGrowthInside − feeGrowthInsideLast) / 2¹²⁸
                  + tokensOwed
```

All arithmetic is `unchecked` (wrapping) per the Uniswap V3 spec.

---

## Arc Variant

`BlitzrLauncherArc.sol` (`BlitzrLauncherArc`) is the same launcher rebuilt for Arc, whose native
gas token **is** USDC (6 decimals) rather than ETH/BNB, mirrored as an ERC20 at the fixed,
network-wide address `0x3600000000000000000000000000000000000000` — native balance and that
ERC20's `balanceOf` are always in sync, so there is no WETH on Arc and no wrap/unwrap step is
ever needed. Everything else — DEX registry, quote-token registration, one-sided tick math,
anti-bot cap, locker registration — is unchanged.

Differences from `BlitzrLauncher`:

- **No `weth_` constructor param.** `USDC` is a hardcoded `constant`
  (`0x3600000000000000000000000000000000000000`), not per-deployment config — it's fixed by the
  network itself, so there's nothing to misconfigure at deploy time.
- **No wrap step.** `_doInstantBuy` skips the `IWETH.deposit{value: extraUsdc}()` call entirely —
  the native value this contract just received is already spendable as `USDC` ERC20 balance.
- **`QuoteToken.wethPairFee` → `nativePairFee`** (and the matching `addQuoteToken` param), purely
  a rename — same role, still the fee tier of an existing `USDC`/quoteToken pool used for the
  multihop instant-buy path when `quoteToken != USDC`.
- **`USDC` defaults to `marketCapRef = 5e6`** (~$5 at 6 decimals) in the constructor, versus
  `5e18` (5 WETH) for the BSC contract's WETH default.
- Launch fee, DEX registry, and quote-token mechanics are otherwise byte-for-byte identical —
  `launchFee` is still a single global native-value figure, just denominated in 6-decimal USDC on
  Arc instead of 18-decimal ETH/BNB (pass amounts accordingly when configuring it).

### Constructor Arguments (BlitzrLauncherArc)

```solidity
constructor(
    address tokenImpl_,          // BlitzrToken implementation (deployed separately)
    address locker_,             // BlitzrLocker (set its launcher to this address after deploy)
    address launchFeeWallet_,    // Platform wallet that receives per-launch fees (native USDC)
    address initialFactory_,     // Factory of the first supported V3 DEX
    address initialPositionMgr_, // Position manager of the first supported V3 DEX
    address initialRouter_,      // Swap router of the first supported V3 DEX
    uint256 launchFee_           // Global launch fee, in native USDC raw units (6 decimals)
)
```
