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
    address  hooks;
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
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (BalanceDelta swapDelta);
    function unlock(bytes calldata data) external returns (bytes memory);
    function take(Currency currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256 paid);
    function sync(Currency currency) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IXBlitzrHook {
    function registerPosition(address token, PoolKey calldata key, address feeWallet) external;
    function positions(address token) external view returns (address feeWallet, Currency currency0, Currency currency1);
}

interface IBlitzrToken {
    function initBlitzr(string calldata name_, string calldata symbol_, string calldata metaURI_, address launcher_, uint256 antiBotBlocks_) external;
    function renounceOwnership() external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function setExempt(address account, bool exempt_) external;
}

// Full-precision mulDiv — ported from Uniswap's FullMath.sol (Remco Bloemen's 512-bit
// algorithm). Required because sqrtRatioAX96 * sqrtRatioBX96 in LiquidityAmounts can exceed
// 2^256 for wide tick ranges; a naive `a * b / c` would revert or misbehave.
library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                require(denominator > 0);
                assembly { result := div(prod0, denominator) }
                return result;
            }

            require(denominator > prod1);

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = (0 - denominator) & denominator;
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;

            result = prod0 * inv;
        }
    }
}

// Ported from Uniswap's TickMath.sol — unchanged between v3-core and v4-core.
library TickMath {
    int24  internal constant MAX_TICK_ABS   = 887272;
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK_ABS)), "T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2    != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4    != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8    != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10   != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20   != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40   != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80   != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100  != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200  != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400  != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800  != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}

// Ported from Uniswap's LiquidityAmounts.sol.
library LiquidityAmounts {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal pure returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        return uint128(FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal pure returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return uint128(FullMath.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }
}

// Blitzr — https://blitzr.fun
//
// V4 counterpart to BlitzrLauncher. Clones the same BlitzrToken implementation used by the V3
// stack (contracts/BlitzrToken.sol) and seeds 100 % one-sided liquidity into a V4 pool via the
// PoolManager singleton, attached to XBlitzrHook. There is no per-DEX registry like V3's
// dexes[] — V4 is one canonical PoolManager per chain, so that whole surface disappears.
// Native ETH/BNB is a first-class quote currency in V4 (Currency address(0)), so unlike V3
// there's no WETH-wrapping step for the common case.
contract XBlitzrLauncher is IUnlockCallback {
    using CurrencyLibrary   for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary     for PoolKey;

    error NotOwner();
    error NotPoolManager();
    error UnsupportedQuoteToken();
    error WrongFee();
    error ZeroAddress();
    error ZeroAmount();
    error CloneFailed();
    error TransferFailed();
    error InvalidTickRange();
    error UnknownToken();
    error InsufficientOutput();

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    int24 private constant TICK_SPACING = 200;
    int24 private constant MIN_TICK     = -887_200;
    int24 private constant MAX_TICK     =  887_200;

    // Uniswap fee units are hundredths of a bip (1e-6) — 10_000 = 1 %. This is the pool's own
    // LP fee, separate from XBlitzrHook's HOOK_FEE_BPS. It accrues to the locked position and
    // is realized via collectPoolFees() below: the quote-currency leg pays the creator, the
    // token-currency leg is burned — every launched token is deflationary via its own fees.
    uint24 private constant POOL_FEE = 10_000;

    // Not address(0): BlitzrToken._transfer reverts on transfers to the zero address, so the
    // conventional dead address is used instead — a normal, code-less address nobody holds the
    // key to, which BlitzrToken has no special-case rejection for.
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    struct QuoteToken {
        uint256 marketCapRef;
        bool    enabled;
        // Identifies an existing, liquid native/quoteToken pool used to route the first hop of
        // a multi-hop instant buy when this quote token isn't native. Unused (left zero) for
        // the native entry itself, which never needs a first hop.
        uint24  refFee;
        int24   refTickSpacing;
        address refHooks;
    }

    struct LaunchCallbackData {
        address  token;
        address  creator;
        address  feeWallet;
        Currency quoteCurrency;
        uint256  marketCapRef;
        uint256  extraEth;
        uint256  minTokensOut;
        uint24   refFee;
        int24    refTickSpacing;
        address  refHooks;
    }

    // Persisted per launch so collectPoolFees() can replay the exact poke later — PoolManager
    // only lets the original modifyLiquidity caller (this contract) touch this position again.
    struct PoolFeePosition {
        PoolKey key;
        int24   tickLower;
        int24   tickUpper;
    }

    mapping(address => QuoteToken) public quoteTokens; // address(0) == native ETH/BNB
    mapping(address => PoolFeePosition) public poolFeePositions; // launched token → its pool position

    IPoolManager public immutable poolManager;
    address      public immutable tokenImpl; // shared with the V3 stack — contracts/BlitzrToken.sol
    address      public immutable hook;
    address      public owner;
    address      public launchFeeWallet;
    uint256      public launchFee;
    uint256      public antiBotBlocks = 10; // blocks after launch during which BlitzrToken caps any wallet at 2.5% of supply

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address         quoteToken,
        address         feeWallet,
        bytes32         poolId
    );
    event QuoteTokenAdded(address indexed token, uint256 marketCapRef, uint24 refFee, int24 refTickSpacing, address refHooks);
    event QuoteTokenDisabled(address indexed token);
    event LaunchFeeWalletSet(address indexed wallet);
    event LaunchFeeSet(uint256 fee);
    event AntiBotBlocksSet(uint256 blocks);
    event MarketCapRefSet(address indexed token, uint256 marketCapRef);
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PoolFeesCollected(address indexed token, address indexed creator, uint256 quotePaid, uint256 tokenBurned);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(
        address poolManager_,
        address tokenImpl_,
        address hook_,
        address launchFeeWallet_,
        uint256 launchFee_
    ) {
        if (poolManager_     == address(0)) revert ZeroAddress();
        if (tokenImpl_       == address(0)) revert ZeroAddress();
        if (hook_            == address(0)) revert ZeroAddress();
        if (launchFeeWallet_ == address(0)) revert ZeroAddress();
        if (launchFee_       == 0)          revert ZeroAmount();

        owner           = msg.sender;
        poolManager     = IPoolManager(poolManager_);
        tokenImpl       = tokenImpl_;
        hook            = hook_;
        launchFeeWallet = launchFeeWallet_;
        launchFee       = launchFee_;

        // native ETH/BNB — refFee/refTickSpacing/refHooks unused, it never needs a first hop
        quoteTokens[address(0)] = QuoteToken({
            marketCapRef:   5e18,
            enabled:        true,
            refFee:         0,
            refTickSpacing: 0,
            refHooks:       address(0)
        });
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setLaunchFeeWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        launchFeeWallet = wallet;
        emit LaunchFeeWalletSet(wallet);
    }

    function setLaunchFee(uint256 fee_) external onlyOwner {
        if (fee_ == 0) revert ZeroAmount();
        launchFee = fee_;
        emit LaunchFeeSet(fee_);
    }

    function setAntiBotBlocks(uint256 blocks_) external onlyOwner {
        antiBotBlocks = blocks_;
        emit AntiBotBlocksSet(blocks_);
    }

    // token_ == address(0) re-registers native ETH/BNB's marketCapRef — unlike V3, address(0)
    // is a valid quote token here (it's V4's native-currency marker), not a banned sentinel.
    // refFee_/refTickSpacing_/refHooks_ identify an existing, liquid native/token_ pool used to
    // route the first hop of a multi-hop instant buy — required for any non-native token_, since
    // there's no way to route native ETH into an instant buy otherwise. Ignored for token_ ==
    // address(0), which never needs a first hop.
    function addQuoteToken(
        address token_,
        uint256 marketCapRef_,
        uint24  refFee_,
        int24   refTickSpacing_,
        address refHooks_
    ) external onlyOwner {
        if (marketCapRef_ == 0) revert ZeroAmount();
        if (token_ != address(0) && refTickSpacing_ == 0) revert ZeroAmount();
        quoteTokens[token_] = QuoteToken({
            marketCapRef:   marketCapRef_,
            enabled:        true,
            refFee:         refFee_,
            refTickSpacing: refTickSpacing_,
            refHooks:       refHooks_
        });
        emit QuoteTokenAdded(token_, marketCapRef_, refFee_, refTickSpacing_, refHooks_);
    }

    function disableQuoteToken(address token_) external onlyOwner {
        if (!quoteTokens[token_].enabled) revert UnsupportedQuoteToken();
        quoteTokens[token_].enabled = false;
        emit QuoteTokenDisabled(token_);
    }

    function setMarketCapRef(address token_, uint256 ref_) external onlyOwner {
        if (!quoteTokens[token_].enabled) revert UnsupportedQuoteToken();
        if (ref_ == 0) revert ZeroAmount();
        quoteTokens[token_].marketCapRef = ref_;
        emit MarketCapRefSet(token_, ref_);
    }

    function rescueETH(address to_, uint256 amount_) external onlyOwner {
        if (to_ == address(0)) revert ZeroAddress();
        if (amount_ == 0) revert ZeroAmount();
        (bool ok,) = to_.call{value: amount_}("");
        if (!ok) revert TransferFailed();
        emit ETHRescued(to_, amount_);
    }

    function rescueERC20(address token_, address to_, uint256 amount_) external onlyOwner {
        if (token_ == address(0)) revert ZeroAddress();
        if (to_ == address(0)) revert ZeroAddress();
        if (amount_ == 0) revert ZeroAmount();
        _safeTransfer(token_, to_, amount_);
        emit ERC20Rescued(token_, to_, amount_);
    }

    receive() external payable {}

    // minTokensOut_ protects the instant buy (if extraEth > 0) against slippage/sandwiching —
    // pass 0 for no minimum. Applies to the final token output regardless of whether the buy
    // is single-hop (native quote) or multi-hop (non-native quote, routed through the quote
    // token's registered reference pool first).
    function launch(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_,
        address         feeWallet_,
        address         quoteToken_,
        uint256         minTokensOut_
    ) external payable returns (address token, bytes32 poolId) {
        QuoteToken memory qt = quoteTokens[quoteToken_];
        if (!qt.enabled) revert UnsupportedQuoteToken();
        if (msg.value < launchFee) revert WrongFee();

        (bool feeOk,) = launchFeeWallet.call{value: launchFee}("");
        if (!feeOk) revert TransferFailed();
        uint256 extraEth = msg.value - launchFee;

        token = _deployAndInit(name_, symbol_, metaURI_);
        address resolvedFeeWallet = feeWallet_ == address(0) ? msg.sender : feeWallet_;

        bytes memory result = poolManager.unlock(abi.encode(uint8(0), abi.encode(LaunchCallbackData({
            token:          token,
            creator:        msg.sender,
            feeWallet:      resolvedFeeWallet,
            quoteCurrency:  Currency.wrap(quoteToken_),
            marketCapRef:   qt.marketCapRef,
            extraEth:       extraEth,
            minTokensOut:   minTokensOut_,
            refFee:         qt.refFee,
            refTickSpacing: qt.refTickSpacing,
            refHooks:       qt.refHooks
        }))));
        poolId = abi.decode(result, (bytes32));

        emit TokenLaunched(token, msg.sender, quoteToken_, resolvedFeeWallet, poolId);
    }

    // Realizes the pool's accrued 1 % LP fee via a zero-delta poke (see PoolFeePosition /
    // XBlitzrHook.beforeRemoveLiquidity for why only this contract can ever successfully call
    // modifyLiquidity again on that position). The quote-currency leg pays the creator; the
    // token-currency leg is burned, not paid out — every launched token is deflationary via its
    // own trading fees. Permissionless — the split destination is fixed by the token/quote
    // identity, not by the caller, so there's no way to misdirect funds by calling this early or
    // often; it only ever determines *when* fees get realized.
    function collectPoolFees(address token) external returns (uint256 quotePaid, uint256 tokenBurned) {
        if (poolFeePositions[token].key.hooks == address(0)) revert UnknownToken();
        bytes memory result = poolManager.unlock(abi.encode(uint8(1), abi.encode(token)));
        (quotePaid, tokenBurned) = abi.decode(result, (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == 0) {
            LaunchCallbackData memory d = abi.decode(payload, (LaunchCallbackData));
            return abi.encode(_executeLaunch(d));
        } else {
            address token = abi.decode(payload, (address));
            (uint256 quotePaid, uint256 tokenBurned) = _executePoke(token);
            return abi.encode(quotePaid, tokenBurned);
        }
    }

    function _executeLaunch(LaunchCallbackData memory d) private returns (bytes32) {
        Currency tokenCurrency = Currency.wrap(d.token);
        bool tokenIsCurrency0  = Currency.unwrap(tokenCurrency) < Currency.unwrap(d.quoteCurrency);
        (Currency currency0, Currency currency1) = tokenIsCurrency0
            ? (tokenCurrency, d.quoteCurrency)
            : (d.quoteCurrency, tokenCurrency);

        PoolKey memory key = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks:       hook
        });

        int24 currentTick = poolManager.initialize(
            key, _computeSqrtPriceX96(tokenIsCurrency0, d.marketCapRef)
        );

        (int24 tickLower, int24 tickUpper) = tokenIsCurrency0
            ? (_floorToTickSpacing(currentTick) + TICK_SPACING, MAX_TICK)
            : (MIN_TICK, _floorToTickSpacing(currentTick));
        if (tickLower >= tickUpper) revert InvalidTickRange();

        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = tokenIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, TOTAL_SUPPLY)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, TOTAL_SUPPLY);

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt:           bytes32(0)
            }),
            ""
        );

        // Must happen before _settleOwed below: PoolManager is about to receive ~100% of supply
        // as locked liquidity, which would itself trip the anti-bot cap if not exempted first.
        // BURN_ADDRESS is exempted too since its balance only ever grows.
        IBlitzrToken(d.token).setExempt(address(poolManager), true);
        IBlitzrToken(d.token).setExempt(BURN_ADDRESS, true);

        _settleOwed(tokenCurrency, callerDelta, tokenIsCurrency0);

        poolFeePositions[d.token] = PoolFeePosition({key: key, tickLower: tickLower, tickUpper: tickUpper});

        IXBlitzrHook(hook).registerPosition(d.token, key, d.feeWallet);

        if (d.extraEth > 0) {
            _instantBuy(key, tokenIsCurrency0, d.quoteCurrency, d);
        }

        uint256 dust = IBlitzrToken(d.token).balanceOf(address(this));
        if (dust > 0) IBlitzrToken(d.token).transfer(d.creator, dust);
        IBlitzrToken(d.token).renounceOwnership();

        return PoolId.unwrap(key.toId());
    }

    // Zero-delta poke: realizes accrued LP fees without touching principal. XBlitzrHook only
    // allows this specific call shape (liquidityDelta == 0, sender == this contract) through
    // beforeRemoveLiquidity — any other caller or any nonzero delta reverts there.
    //
    // The two accrued legs are NOT both creator revenue: currency0/currency1 just reflects
    // address sort order, which varies per launch, so which leg is "the token" vs "the quote"
    // has to be resolved against the actual token address, not assumed from position. The quote
    // leg pays the creator; the token leg is sent to BURN_ADDRESS — every launched token is
    // deflationary via its own accrued trading fees.
    function _executePoke(address token) private returns (uint256 quotePaid, uint256 tokenBurned) {
        PoolFeePosition storage pos = poolFeePositions[token];

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            pos.key,
            ModifyLiquidityParams({
                tickLower:      pos.tickLower,
                tickUpper:      pos.tickUpper,
                liquidityDelta: 0,
                salt:           bytes32(0)
            }),
            ""
        );

        (address feeWallet,,) = IXBlitzrHook(hook).positions(token);

        bool tokenIsCurrency0 = Currency.unwrap(pos.key.currency0) == token;
        (Currency tokenCurrency, Currency quoteCurrency) = tokenIsCurrency0
            ? (pos.key.currency0, pos.key.currency1)
            : (pos.key.currency1, pos.key.currency0);
        (int128 tokenAmt, int128 quoteAmt) = tokenIsCurrency0
            ? (callerDelta.amount0(), callerDelta.amount1())
            : (callerDelta.amount1(), callerDelta.amount0());

        if (quoteAmt > 0) {
            quotePaid = uint256(uint128(quoteAmt));
            poolManager.take(quoteCurrency, feeWallet, quotePaid);
        }
        if (tokenAmt > 0) {
            tokenBurned = uint256(uint128(tokenAmt));
            poolManager.take(tokenCurrency, BURN_ADDRESS, tokenBurned);
        }

        emit PoolFeesCollected(token, feeWallet, quotePaid, tokenBurned);
    }

    function _settleOwed(Currency tokenCurrency, BalanceDelta callerDelta, bool tokenIsCurrency0) private {
        int128 owed = tokenIsCurrency0 ? callerDelta.amount0() : callerDelta.amount1();
        if (owed >= 0) return; // one-sided range: the non-token leg should net to ~0, nothing to settle there
        uint256 amount = uint256(uint128(-owed));
        poolManager.sync(tokenCurrency);
        IBlitzrToken(Currency.unwrap(tokenCurrency)).transfer(address(poolManager), amount);
        poolManager.settle();
    }

    // Single-hop when the quote currency is native; multi-hop (native → quoteToken → token)
    // when it isn't, routing the first leg through the quote token's registered reference pool.
    // No external router needed in V4 — the launcher calls PoolManager itself within the same
    // unlock() context, and for the multi-hop case the intermediate quoteToken leg nets to zero
    // in PoolManager's internal per-currency ledger without ever being physically transferred
    // (hop 1 credits exactly what hop 2 debits, in the same currency, same unlock() call).
    // minTokensOut is checked once, against the final output only — a bad rate on either hop
    // shows up as a smaller final amount, so one check at the end covers the whole route.
    function _instantBuy(
        PoolKey memory key,
        bool tokenIsCurrency0,
        Currency quoteCurrency,
        LaunchCallbackData memory d
    ) private {
        uint256 quoteAmountIn = d.extraEth;
        if (!quoteCurrency.isNative()) {
            quoteAmountIn = _swapNativeToQuote(quoteCurrency, d.refFee, d.refTickSpacing, d.refHooks, d.extraEth);
        }

        bool zeroForOne = !tokenIsCurrency0;
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(quoteAmountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );

        if (quoteCurrency.isNative()) {
            poolManager.settle{value: d.extraEth}();
        }

        int128 tokenOut = tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 tokenOutAmount = tokenOut > 0 ? uint256(uint128(tokenOut)) : 0;
        if (tokenOutAmount < d.minTokensOut) revert InsufficientOutput();
        if (tokenOutAmount > 0) {
            poolManager.take(tokenIsCurrency0 ? key.currency0 : key.currency1, d.creator, tokenOutAmount);
        }
    }

    // First hop of a multi-hop instant buy: native ETH → quoteToken, via the quote token's
    // registered reference pool. Native is always currency0 there (address(0) sorts below any
    // nonzero address), so the direction is fixed, unlike the token/quote ordering elsewhere.
    function _swapNativeToQuote(
        Currency quoteCurrency,
        uint24  refFee,
        int24   refTickSpacing,
        address refHooks,
        uint256 extraEth
    ) private returns (uint256 quoteAmountOut) {
        PoolKey memory refKey = PoolKey({
            currency0:   Currency.wrap(address(0)),
            currency1:   quoteCurrency,
            fee:         refFee,
            tickSpacing: refTickSpacing,
            hooks:       refHooks
        });

        BalanceDelta delta = poolManager.swap(
            refKey,
            SwapParams({
                zeroForOne:        true,
                amountSpecified:   -int256(extraEth),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );

        poolManager.settle{value: extraEth}();

        int128 out = delta.amount1();
        quoteAmountOut = out > 0 ? uint256(uint128(out)) : 0;
    }

    function _deployAndInit(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_
    ) private returns (address token) {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp, name_, symbol_, metaURI_));
        token = _clone(tokenImpl, salt);
        IBlitzrToken(token).initBlitzr(name_, symbol_, metaURI_, address(this), antiBotBlocks);
    }

    // sqrtPriceX96 targeting marketCapRef for TOTAL_SUPPLY, adjusted for token ordering —
    // identical math to V3's BlitzrLauncher, the price formula is DEX-version-agnostic.
    function _computeSqrtPriceX96(bool tokenIsCurrency0, uint256 marketCapRef_) private pure returns (uint160) {
        return tokenIsCurrency0
            ? _sqrtPriceX96(TOTAL_SUPPLY, marketCapRef_)
            : _sqrtPriceX96(marketCapRef_, TOTAL_SUPPLY);
    }

    function _floorToTickSpacing(int24 tick) private pure returns (int24) {
        int24 compressed = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) compressed--;
        return compressed * TICK_SPACING;
    }

    function _clone(address impl, bytes32 salt) private returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0)) revert CloneFailed();
    }

    function _sqrtPriceX96(uint256 amount0, uint256 amount1) private pure returns (uint160) {
        uint256 scaled = (amount1 << 96) / amount0;
        return uint160(_sqrt(scaled) << 48);
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) >> 1;
        while (z < y) { y = z; z = (x / z + z) >> 1; }
    }

    function _safeTransfer(address token_, address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token_.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
