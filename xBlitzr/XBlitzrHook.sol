// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// ============================================================================
// UNVERIFIED SCAFFOLD — hand-rolled Uniswap V4 primitives.
//
// This sandbox has no network access to vendor the real `@uniswap/v4-core`
// package, so the types/interfaces below are reproduced from the published
// V4 spec rather than imported. They MUST be diffed against the actual
// v4-core deployed on your target chain before this is trusted with real
// funds — a single mismatched selector, struct field order, or hook-flag
// bit silently breaks dispatch or, worse, misencodes a call.
// See XBLITZR.md → "Verification Checklist" before deploying.
// ============================================================================

type Currency is address;
type PoolId   is bytes32;
type BalanceDelta is int256;

library CurrencyLibrary {
    function isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == address(0);
    }
}

library BalanceDeltaLibrary {
    function amount0(BalanceDelta delta) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(delta) >> 128));
    }
    function amount1(BalanceDelta delta) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(delta)));
    }
}

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24   fee;
    int24    tickSpacing;
    address  hooks; // ABI-compatible with v4-core's `IHooks hooks` (both encode as address)
}

library PoolIdLibrary {
    function toId(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }
}

struct ModifyLiquidityParams {
    int24   tickLower;
    int24   tickUpper;
    int256  liquidityDelta;
    bytes32 salt;
}

struct SwapParams {
    bool    zeroForOne;
    int256  amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function take(Currency currency, address to, uint256 amount) external;
}

// Blitzr — https://blitzr.fun
//
// V4 counterpart to BlitzrLocker, adapted for the singleton PoolManager + hooks model.
// One shared hook instance is attached to every xBlitzr pool (same pattern as one shared
// BlitzrLocker serving every V3 launch). It enforces two permanent invariants on any pool
// that uses it:
//
//   1. Liquidity can only ever be added once, by the launcher, at launch time
//      (beforeAddLiquidity reverts for any other caller).
//   2. Principal liquidity can never be removed by anyone, ever, including the owner
//      (beforeRemoveLiquidity reverts on any nonzero delta, forever).
//
// Two separate revenue streams exist side by side, each going entirely to one party — no split:
//   - The pool's own LP fee (1 %, set in PoolKey.fee by the launcher) accrues to the locked
//     position as ordinary Uniswap fee growth and goes entirely to the creator. Since principal
//     can never be removed, this fee is realized via a zero-delta "poke" — beforeRemoveLiquidity
//     allows liquidityDelta == 0, but only when called by the launcher (the position's owner in
//     PoolManager's accounting). XBlitzrLauncher.collectPoolFees() drives this and pays the
//     creator directly.
//   - The hook's own cut (HOOK_FEE_BPS, taken independently of the pool fee) is skimmed live on
//     every swap via afterSwap's returned delta and goes entirely to the platform wallet — no
//     claim step, revenue lands immediately.
contract XBlitzrHook {
    using CurrencyLibrary   for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary     for PoolKey;

    // Hook permission bits this contract's deployed address must encode in its low bits —
    // verified against Uniswap/v4-core's Hooks.sol (github.com/Uniswap/v4-core, src/libraries/Hooks.sol).
    // Achieving this requires deploying via CREATE2 with a mined salt; see XBLITZR.md →
    // "Deploying the Hook". A normal `new XBlitzrHook(...)` will NOT produce a valid hook address.
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG     = 1 << 11;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG  = 1 << 9;
    uint160 internal constant AFTER_SWAP_FLAG                = 1 << 6;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG   = 1 << 2;
    uint160 internal constant REQUIRED_FLAGS =
        BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG |
        AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG;

    // Cut taken out of every swap's unspecified-currency leg, paid entirely to platformWallet.
    // Separate from and in addition to the pool's own 1 % LP fee (set in PoolKey.fee by the
    // launcher, paid entirely to the creator) — see the contract-level comment above.
    uint256 public constant HOOK_FEE_BPS = 50; // 0.5 %
    uint256 private constant BPS = 10_000;

    error NotOwner();
    error NotLauncher();
    error NotPoolManager();
    error ZeroAddress();
    error AlreadyRegistered();
    error UnknownToken();
    error WrongFee();
    error TransferFailed();
    error LiquidityLocked();
    error BadHookAddress();

    uint256 public ctoFee = 0.05 ether; // anti-spam charge for applyForCTO, owner-adjustable

    struct Position {
        address  feeWallet;
        Currency currency0;
        Currency currency1;
    }

    struct CTOApplication {
        address applicant;
        address proposedFeeWallet;
        uint256 feePaid;
    }

    IPoolManager public immutable poolManager;
    address public owner;
    address public launcher;
    address public platformWallet;

    mapping(address => Position) public positions;         // launched token → locked position
    mapping(PoolId  => address)  public tokenByPoolId;      // reverse lookup for afterSwap
    mapping(address => CTOApplication) public ctoApplications;
    address[] public allTokens;

    event PositionRegistered(address indexed token, bytes32 indexed poolId, address feeWallet);
    event SwapFeeCaptured(address indexed token, address indexed currency, uint256 platformCut);
    event LauncherSet(address indexed launcher);
    event PlatformWalletSet(address indexed wallet);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenCTO(address indexed token, address indexed oldFeeWallet, address indexed newFeeWallet);
    event CTOApplied(address indexed token, address indexed applicant, address proposedFeeWallet, uint256 feePaid);
    event CTOFeeSet(uint256 fee);

    modifier onlyOwner()       { if (msg.sender != owner)                 revert NotOwner();       _; }
    modifier onlyLauncher()    { if (msg.sender != launcher)              revert NotLauncher();    _; }
    modifier onlyPoolManager() { if (msg.sender != address(poolManager))  revert NotPoolManager(); _; }

    // owner_ is an explicit constructor argument rather than `msg.sender` — this contract must
    // be deployed via CREATE2 through a shared deterministic deployment proxy (see "Deploying
    // the Hook" in XBLITZR.md) to land on a valid hook-flag address, and inside that deployment
    // `msg.sender` is the proxy itself, not the deploying EOA. Using `msg.sender` here would
    // permanently lock `owner` to an address nobody controls — confirmed by fork-testing this
    // exact deployment path against the real CREATE2 deployment proxy on mainnet.
    constructor(address poolManager_, address platformWallet_, address owner_) {
        if (poolManager_    == address(0)) revert ZeroAddress();
        if (platformWallet_ == address(0)) revert ZeroAddress();
        if (owner_          == address(0)) revert ZeroAddress();
        // Deployer must CREATE2-mine a salt producing this exact flag pattern beforehand —
        // see XBLITZR.md. Checked against ALL_HOOK_MASK, not just REQUIRED_FLAGS, so a mined
        // salt that accidentally sets an unrelated flag (e.g. BEFORE_SWAP) is rejected too —
        // matches the exact-match semantics of v4-core's Hooks.validateHookPermissions.
        if (uint160(address(this)) & ALL_HOOK_MASK != REQUIRED_FLAGS) revert BadHookAddress();

        poolManager    = IPoolManager(poolManager_);
        owner          = owner_;
        platformWallet = platformWallet_;
    }

    function setLauncher(address launcher_) external onlyOwner {
        if (launcher_ == address(0)) revert ZeroAddress();
        launcher = launcher_;
        emit LauncherSet(launcher_);
    }

    function setPlatformWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        platformWallet = wallet;
        emit PlatformWalletSet(wallet);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // Reassigns a token's creator fee wallet — a community takeover (CTO) lever for when the
    // original creator is unreachable or has abandoned the project.
    function ctoFeeWallet(address token, address newFeeWallet) external onlyOwner {
        Position storage pos = positions[token];
        if (pos.feeWallet == address(0)) revert UnknownToken();
        if (newFeeWallet == address(0)) revert ZeroAddress();
        emit TokenCTO(token, pos.feeWallet, newFeeWallet);
        pos.feeWallet = newFeeWallet;
        delete ctoApplications[token];
    }

    function setCTOFee(uint256 fee_) external onlyOwner {
        ctoFee = fee_;
        emit CTOFeeSet(fee_);
    }

    // Public entry point for proposing a community takeover. Gated by ctoFee (paid to
    // platformWallet) so bots can't spam applications for free; the owner still reviews and
    // executes via ctoFeeWallet — this only records the proposal. The fee is non-refundable.
    function applyForCTO(address token, address proposedFeeWallet) external payable {
        Position storage pos = positions[token];
        if (pos.feeWallet == address(0)) revert UnknownToken();
        if (proposedFeeWallet == address(0)) revert ZeroAddress();
        if (msg.value < ctoFee) revert WrongFee();

        ctoApplications[token] = CTOApplication({
            applicant:         msg.sender,
            proposedFeeWallet: proposedFeeWallet,
            feePaid:           msg.value
        });

        if (msg.value > 0) {
            (bool ok,) = platformWallet.call{value: msg.value}("");
            if (!ok) revert TransferFailed();
        }

        emit CTOApplied(token, msg.sender, proposedFeeWallet, msg.value);
    }

    function registerPosition(address token, PoolKey calldata key, address feeWallet) external onlyLauncher {
        if (positions[token].feeWallet != address(0)) revert AlreadyRegistered();
        PoolId id = key.toId();
        positions[token] = Position({
            feeWallet: feeWallet,
            currency0: key.currency0,
            currency1: key.currency1
        });
        tokenByPoolId[id] = token;
        allTokens.push(token);
        emit PositionRegistered(token, PoolId.unwrap(id), feeWallet);
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    // --- hook callbacks — PoolManager only calls these because REQUIRED_FLAGS marks them
    //     active in this contract's address; any other flag stays off and is never invoked. ---

    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view onlyPoolManager returns (bytes4)
    {
        if (sender != launcher) revert LiquidityLocked();
        return this.beforeAddLiquidity.selector;
    }

    // Reverts on any actual removal (liquidityDelta < 0) from anyone, forever — principal is
    // permanently locked. But allows a zero-delta "poke" (fee-only, no principal change) from
    // the launcher specifically, since it's the position's owner in PoolManager's accounting and
    // is the only address that could ever successfully call modifyLiquidity on this position.
    // liquidityDelta is never positive here — PoolManager routes delta > 0 through
    // beforeAddLiquidity instead (see Hooks.beforeModifyLiquidity), so != 0 here means < 0.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        if (params.liquidityDelta != 0) revert LiquidityLocked();
        if (sender != launcher) revert LiquidityLocked();
        return this.beforeRemoveLiquidity.selector;
    }

    // Skims HOOK_FEE_BPS off the unspecified-currency leg of every swap and routes it straight
    // to platformWallet via take() — no intermediate custody in this contract. Separate from,
    // and paid to a different party than, the pool-fee poke XBlitzrLauncher.collectPoolFees()
    // drives (that one pays the creator).
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        address token = tokenByPoolId[key.toId()];
        Position storage pos = positions[token];
        if (pos.feeWallet == address(0)) return (this.afterSwap.selector, 0);

        // Unspecified currency = whichever leg wasn't fixed by the swapper's amountSpecified.
        // See XBLITZR.md → "Hook Fee Mechanics" for the derivation of this condition.
        bool unspecifiedIsCurrency0 = !(params.zeroForOne == (params.amountSpecified < 0));
        int128 unspecifiedAmount = unspecifiedIsCurrency0 ? delta.amount0() : delta.amount1();
        if (unspecifiedAmount == 0) return (this.afterSwap.selector, 0);

        uint256 gross = unspecifiedAmount > 0
            ? uint256(uint128(unspecifiedAmount))
            : uint256(uint128(-unspecifiedAmount));
        uint256 cut = gross * HOOK_FEE_BPS / BPS;
        if (cut == 0) return (this.afterSwap.selector, 0);

        Currency feeCurrency = unspecifiedIsCurrency0 ? key.currency0 : key.currency1;

        poolManager.take(feeCurrency, platformWallet, cut);

        emit SwapFeeCaptured(token, Currency.unwrap(feeCurrency), cut);

        return (this.afterSwap.selector, int128(int256(cut)));
    }
}
