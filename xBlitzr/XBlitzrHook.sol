// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

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
// V4 counterpart to BlitzrLocker, one shared hook instance attached to every xBlitzr pool.
// Enforces two permanent invariants: liquidity can only be added once, by the launcher, at
// launch time (beforeAddLiquidity); and principal can never be removed by anyone, ever
// (beforeRemoveLiquidity). Two revenue streams both split creatorBps/platformBps — the pool's own
// LP fee, realized via a zero-delta poke since principal can't be removed, and the hook's own
// swap-fee cut, skimmed live in afterSwap. Both read the SAME ratio from this contract so there's
// one number to keep in sync, not two.
contract XBlitzrHook {
    using CurrencyLibrary   for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary     for PoolKey;

    // Hook permission bits this contract's deployed address must encode — requires CREATE2 with
    // a mined salt (see XBLITZR.md → "Deploying the Hook"); a plain `new XBlitzrHook(...)` will
    // NOT produce a valid hook address.
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG     = 1 << 11;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG  = 1 << 9;
    uint160 internal constant AFTER_SWAP_FLAG                = 1 << 6;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG   = 1 << 2;
    uint160 internal constant REQUIRED_FLAGS =
        BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG |
        AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG;

    // Cut taken out of every swap's unspecified-currency leg — separate from and in addition to
    // the pool's own 1% LP fee (set in PoolKey.fee by the launcher).
    uint256 public hookFeeBps = 100; // 1 %, owner-adjustable via setHookFeeBps
    uint256 private constant BPS = 10_000;

    // Single source of truth for the creator/platform split, also read by
    // XBlitzrLauncher.collectPoolFees for the pool LP fee — one ratio, not two that could drift.
    uint256 public creatorBps  = 8_000; // 80 %, owner-adjustable via setFeeBps
    uint256 public platformBps = 2_000; // 20 %, owner-adjustable via setFeeBps

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
    error InvalidBps();

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
    event SwapFeeCaptured(address indexed token, address indexed currency, uint256 creatorCut, uint256 platformCut);
    event LauncherSet(address indexed launcher);
    event PlatformWalletSet(address indexed wallet);
    event HookFeeBpsSet(uint256 bps);
    event FeeBpsSet(uint256 creatorBps, uint256 platformBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenCTO(address indexed token, address indexed oldFeeWallet, address indexed newFeeWallet);
    event CTOApplied(address indexed token, address indexed applicant, address proposedFeeWallet, uint256 feePaid);
    event CTOFeeSet(uint256 fee);

    modifier onlyOwner()       { if (msg.sender != owner)                 revert NotOwner();       _; }
    modifier onlyLauncher()    { if (msg.sender != launcher)              revert NotLauncher();    _; }
    modifier onlyPoolManager() { if (msg.sender != address(poolManager))  revert NotPoolManager(); _; }

    // owner_ is an explicit arg, not `msg.sender` — deployment goes through a CREATE2 proxy (see
    // XBLITZR.md), so `msg.sender` here would be that proxy, not the real owner.
    constructor(address poolManager_, address platformWallet_, address owner_) {
        if (poolManager_    == address(0)) revert ZeroAddress();
        if (platformWallet_ == address(0)) revert ZeroAddress();
        if (owner_          == address(0)) revert ZeroAddress();
        // Checked against ALL_HOOK_MASK, not just REQUIRED_FLAGS, so a mined salt that
        // accidentally sets an unrelated flag is rejected too.
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

    function setHookFeeBps(uint256 bps_) external onlyOwner {
        if (bps_ > BPS) revert InvalidBps();
        hookFeeBps = bps_;
        emit HookFeeBpsSet(bps_);
    }

    function setFeeBps(uint256 creator_, uint256 platform_) external onlyOwner {
        if (creator_ + platform_ != BPS) revert InvalidBps();
        creatorBps  = creator_;
        platformBps = platform_;
        emit FeeBpsSet(creator_, platform_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

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

    // Gated by ctoFee (non-refundable, paid to platformWallet) so bots can't spam applications;
    // owner still reviews and executes via ctoFeeWallet — this only records the proposal.
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

    // --- hook callbacks ---

    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view onlyPoolManager returns (bytes4)
    {
        if (sender != launcher) revert LiquidityLocked();
        return this.beforeAddLiquidity.selector;
    }

    // Allows a zero-delta "poke" (fee-only) from the launcher; any nonzero delta reverts.
    // liquidityDelta is never positive here — PoolManager routes delta > 0 through
    // beforeAddLiquidity instead.
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

        // See XBLITZR.md → "Hook Fee Mechanics" for the derivation of this condition.
        bool unspecifiedIsCurrency0 = !(params.zeroForOne == (params.amountSpecified < 0));
        int128 unspecifiedAmount = unspecifiedIsCurrency0 ? delta.amount0() : delta.amount1();
        if (unspecifiedAmount == 0) return (this.afterSwap.selector, 0);

        uint256 gross = unspecifiedAmount > 0
            ? uint256(uint128(unspecifiedAmount))
            : uint256(uint128(-unspecifiedAmount));
        uint256 cut = gross * hookFeeBps / BPS;
        if (cut == 0) return (this.afterSwap.selector, 0);

        Currency feeCurrency = unspecifiedIsCurrency0 ? key.currency0 : key.currency1;

        // Platform's share absorbs the rounding remainder — matches _executePoke's convention.
        uint256 creatorCut = cut * creatorBps / BPS;
        uint256 platformCut = cut - creatorCut;
        if (creatorCut  > 0) poolManager.take(feeCurrency, pos.feeWallet,  creatorCut);
        if (platformCut > 0) poolManager.take(feeCurrency, platformWallet, platformCut);

        emit SwapFeeCaptured(token, Currency.unwrap(feeCurrency), creatorCut, platformCut);

        return (this.afterSwap.selector, int128(int256(cut)));
    }
}
