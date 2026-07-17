// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Blitzr — https://blitzr.fun
//
// Arc-network variant of BlitzrLauncher. Arc's native gas token IS USDC (6 decimals), mirrored
// 1:1 as an ERC20 at the fixed address USDC below — there is no WETH on Arc, and no wrap step is
// ever needed: the moment this contract holds native value, that same value is already spendable
// as USDC ERC20 balance. All DEX-facing calls approve USDC directly rather than wrapping it first.

interface IBlitzrToken {
    function initBlitzr(string calldata name_, string calldata symbol_, string calldata metaURI_, address launcher_, uint256 antiBotBlocks_) external;
    function renounceOwnership() external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function setExempt(address account, bool exempt_) external;
}

interface IBlitzrLocker {
    function registerPosition(
        address token,
        uint256 tokenId,
        address feeWallet,
        address token0,
        address token1,
        address pool,
        address positionManager
    ) external;
}

interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24   tick,
        uint16  observationIndex,
        uint16  observationCardinality,
        uint16  observationCardinalityNext,
        uint32  feeProtocol, // PancakeSwap V3 packs this wider than vanilla Uniswap V3's uint8
        bool    unlocked
    );
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24  fee;
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params)
        external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

// SwapRouter02 ABI (no `deadline` field — deadline enforcement lives in that router's
// separate `multicall` wrapper, unlike the original Uniswap V3 `SwapRouter`).
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);

    // Multi-hop variant — used when the quote token isn't USDC, routing
    // USDC -> quoteToken -> blitzrToken through whatever pools already exist.
    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params)
        external payable returns (uint256 amountOut);
}

contract BlitzrLauncherArc {

    error NotOwner();
    error UnsupportedQuoteToken();
    error UnsupportedDex();
    error WrongFee();
    error ZeroAddress();
    error ZeroAmount();
    error CloneFailed();
    error PoolAlreadyExists();
    error TransferFailed();
    error ApprovalFailed();
    error InvalidTickRange();

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18; // 100 % seeded one-sided into the pool

    uint24 private constant FEE_TIER     = 10_000; // 1 % V3 tier
    int24  private constant MIN_TICK     = -887_200;
    int24  private constant MAX_TICK     =  887_200;
    int24  private constant TICK_SPACING =  200;   // spacing for 1 % tier

    // Matches BlitzrLocker.BURN_ADDRESS — exempted from the anti-bot cap here so BlitzrLocker's
    // burn transfers (if enabled for a given token) don't eventually trip the cap once enough
    // has accumulated there during the anti-bot window.
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    struct DexConfig {
        address positionManager;
        address router;
        bool    enabled;
    }

    struct QuoteToken {
        uint256 marketCapRef;   // reference amount (raw units) targeting the desired launch market cap
        uint24  nativePairFee;  // fee tier of the existing USDC/quoteToken pool, for multihop instant-buy
                                 // routing when quoteToken != USDC; unused when quoteToken == USDC
        bool    enabled;
    }

    mapping(address => DexConfig)  public dexes;
    mapping(address => QuoteToken) public quoteTokens;

    // Arc's native gas token IS USDC (6 decimals), mirrored as an ERC20 at this fixed,
    // network-wide address — balances are always in sync with native value, so no wrap step is
    // ever needed before using it in DEX calls. Fixed by the network, not per-deployment config.
    address      public constant USDC = 0x3600000000000000000000000000000000000000;
    address      public immutable tokenImpl;
    IBlitzrLocker public immutable locker;
    address      public owner;
    address      public launchFeeWallet; // receives platform launch fees
    uint256      public launchFee;       // charged in native USDC on every launch, regardless of quote token
    uint256      public antiBotBlocks = 10; // blocks after launch during which BlitzrToken caps any wallet at 2.5% of supply

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address indexed factory,
        address         quoteToken,
        address         feeWallet,
        address         pool,
        uint256         tokenId
    );
    event DexAdded(address indexed factory, address positionManager, address router);
    event DexDisabled(address indexed factory);
    event QuoteTokenAdded(address indexed token, uint256 marketCapRef, uint24 nativePairFee);
    event QuoteTokenDisabled(address indexed token);
    event LaunchFeeWalletSet(address indexed wallet);
    event LaunchFeeSet(uint256 fee);
    event AntiBotBlocksSet(uint256 blocks);
    event MarketCapRefSet(address indexed token, uint256 marketCapRef);
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(
        address tokenImpl_,
        address locker_,
        address launchFeeWallet_,
        address initialFactory_,
        address initialPositionMgr_,
        address initialRouter_,
        uint256 launchFee_
    ) {
        if (tokenImpl_          == address(0)) revert ZeroAddress();
        if (locker_             == address(0)) revert ZeroAddress();
        if (launchFeeWallet_    == address(0)) revert ZeroAddress();
        if (initialFactory_     == address(0)) revert ZeroAddress();
        if (initialPositionMgr_ == address(0)) revert ZeroAddress();
        if (initialRouter_      == address(0)) revert ZeroAddress();
        if (launchFee_          == 0)          revert ZeroAmount();

        owner           = msg.sender;
        tokenImpl       = tokenImpl_;
        locker          = IBlitzrLocker(locker_);
        launchFeeWallet = launchFeeWallet_;
        launchFee       = launchFee_;

        dexes[initialFactory_] = DexConfig({
            positionManager: initialPositionMgr_,
            router:          initialRouter_,
            enabled:         true
        });
        emit DexAdded(initialFactory_, initialPositionMgr_, initialRouter_);

        quoteTokens[USDC] = QuoteToken({
            marketCapRef:  5e6,          // ~$5 market cap at launch (6-decimal USDC)
            nativePairFee: 0,            // unused — quote token is USDC itself, no hop needed
            enabled:       true
        });
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
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

    function setMarketCapRef(address token_, uint256 ref_) external onlyOwner {
        if (!quoteTokens[token_].enabled) revert UnsupportedQuoteToken();
        if (ref_ == 0) revert ZeroAmount();
        quoteTokens[token_].marketCapRef = ref_;
        emit MarketCapRefSet(token_, ref_);
    }

    function addDex(address factory_, address positionMgr_, address router_) external onlyOwner {
        if (factory_     == address(0)) revert ZeroAddress();
        if (positionMgr_ == address(0)) revert ZeroAddress();
        if (router_      == address(0)) revert ZeroAddress();
        dexes[factory_] = DexConfig({
            positionManager: positionMgr_,
            router:          router_,
            enabled:         true
        });
        emit DexAdded(factory_, positionMgr_, router_);
    }

    function disableDex(address factory_) external onlyOwner {
        if (!dexes[factory_].enabled) revert UnsupportedDex();
        dexes[factory_].enabled = false;
        emit DexDisabled(factory_);
    }

    function addQuoteToken(
        address token_,
        uint256 marketCapRef_,
        uint24  nativePairFee_
    ) external onlyOwner {
        if (token_        == address(0)) revert ZeroAddress();
        if (marketCapRef_ == 0)          revert ZeroAmount();
        if (token_ != USDC && nativePairFee_ == 0) revert ZeroAmount(); // needed for multihop routing
        quoteTokens[token_] = QuoteToken({
            marketCapRef:  marketCapRef_,
            nativePairFee: nativePairFee_,
            enabled:       true
        });
        emit QuoteTokenAdded(token_, marketCapRef_, nativePairFee_);
    }

    function disableQuoteToken(address token_) external onlyOwner {
        if (!quoteTokens[token_].enabled) revert UnsupportedQuoteToken();
        quoteTokens[token_].enabled = false;
        emit QuoteTokenDisabled(token_);
    }

    function rescueETH(address to_, uint256 amount_) external onlyOwner {
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();
        (bool ok,) = to_.call{value: amount_}("");
        if (!ok) revert TransferFailed();
        emit ETHRescued(to_, amount_);
    }

    function rescueERC20(address token_, address to_, uint256 amount_) external onlyOwner {
        if (token_  == address(0)) revert ZeroAddress();
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();
        _safeTransfer(token_, to_, amount_);
        emit ERC20Rescued(token_, to_, amount_);
    }

    function launch(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_,
        address         feeWallet_,
        address         factory_,
        address         quoteToken_
    ) external payable returns (address token, address pool, uint256 tokenId) {
        token = _deployAndInit(name_, symbol_, metaURI_);
        (pool, tokenId) = _setupAndRegister(token, feeWallet_, factory_, quoteToken_);
    }

    function _setupAndRegister(
        address token,
        address feeWallet_,
        address factory_,
        address quoteToken_
    ) private returns (address pool, uint256 tokenId) {
        // Access dex/quote config directly from storage — avoids two memory-pointer stack slots
        // that legacy codegen would keep live for the entire function body.
        if (!dexes[factory_].enabled)          revert UnsupportedDex();
        if (!quoteTokens[quoteToken_].enabled)  revert UnsupportedQuoteToken();
        if (msg.value < launchFee)              revert WrongFee();

        // Fee is always charged in native USDC, regardless of quote token — sent straight
        // to the platform wallet, never touching the pool. Anything above the fee is spent on
        // an instant buy after the pool is seeded.
        (bool feeOk,) = launchFeeWallet.call{value: launchFee}("");
        if (!feeOk) revert TransferFailed();
        uint256 extraUsdc = msg.value - launchFee;

        // Determine token ordering (V3 requires token0 < token1 by address).
        (address token0, address token1) = token < quoteToken_
            ? (token,       quoteToken_)
            : (quoteToken_, token      );

        // A pool can already exist at this (token0, token1, FEE_TIER) key if someone front-ran
        // createPool() with our predicted clone address — createPool() is permissionless on the
        // DEX factory. An uninitialized shell is harmless: we just adopt and initialize it
        // ourselves. Only a pool someone has *already initialized* is a genuine collision.
        address existingPool = IUniswapV3Factory(factory_).getPool(token0, token1, FEE_TIER);
        if (existingPool == address(0)) {
            pool = IUniswapV3Factory(factory_).createPool(token0, token1, FEE_TIER);
        } else {
            (uint160 existingPrice,,,,,,) = IUniswapV3Pool(existingPool).slot0();
            if (existingPrice != 0) revert PoolAlreadyExists();
            pool = existingPool;
        }

        // Initialise at a price targeting marketCapRef for the full TOTAL_SUPPLY.
        IUniswapV3Pool(pool).initialize(
            _computeSqrtPriceX96(token, quoteToken_, quoteTokens[quoteToken_].marketCapRef)
        );

        // Must happen before the mint below: the pool is about to receive ~100% of supply as
        // locked liquidity, which would itself trip the anti-bot cap if not exempted first.
        // BURN_ADDRESS is exempted too since its balance only ever grows.
        IBlitzrToken(token).setExempt(pool, true);
        IBlitzrToken(token).setExempt(BURN_ADDRESS, true);

        // Tick setup, mint, and register extracted to avoid stack-too-deep in legacy codegen.
        tokenId = _mintAndRegister(
            dexes[factory_].positionManager,
            token,
            feeWallet_ == address(0) ? msg.sender : feeWallet_,
            token0, token1, pool
        );

        // Instant buy extracted to avoid stack-too-deep during ExactInputSingleParams construction.
        if (extraUsdc > 0) {
            _doInstantBuy(dexes[factory_].router, quoteToken_, token, extraUsdc, quoteTokens[quoteToken_].nativePairFee);
        }

        // Sweep any mint-rounding dust left in this contract back to the creator — the
        // full supply is seeded one-sided, so no deliberate allocation is held back.
        uint256 creatorTokens = IBlitzrToken(token).balanceOf(address(this));
        if (creatorTokens > 0) IBlitzrToken(token).transfer(msg.sender, creatorTokens);

        IBlitzrToken(token).renounceOwnership();

        emit TokenLaunched(
            token, msg.sender, factory_, quoteToken_,
            feeWallet_ == address(0) ? msg.sender : feeWallet_,
            pool, tokenId
        );
    }

    receive() external payable {}

    // Buys blitzr tokens for the creator with the excess native USDC. Direct single-hop swap
    // when the quote token is USDC itself; otherwise multihops USDC -> quoteToken ->
    // blitzrToken through whichever pools already exist (quoteToken/blitzrToken is the one we
    // just seeded; USDC/quoteToken must already have real liquidity on this DEX). No wrap step
    // is needed — the native value this contract just received is already spendable as USDC
    // ERC20 balance (native and ERC20 balances are in sync on Arc).
    function _doInstantBuy(
        address router_,
        address quoteToken_,
        address token,
        uint256 extraUsdc,
        uint24  nativePairFee
    ) private {
        _safeApprove(USDC, router_, extraUsdc);

        if (quoteToken_ == USDC) {
            ISwapRouter(router_).exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn:           USDC,
                tokenOut:          token,
                fee:               FEE_TIER,
                recipient:         msg.sender,
                amountIn:          extraUsdc,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            }));
        } else {
            ISwapRouter(router_).exactInput(ISwapRouter.ExactInputParams({
                path:             abi.encodePacked(USDC, nativePairFee, quoteToken_, FEE_TIER, token),
                recipient:        msg.sender,
                amountIn:         extraUsdc,
                amountOutMinimum: 0
            }));
        }
    }

    // Tick setup, mint, and locker registration in one frame.
    // tick/amount vars are scoped to the inner block so they are popped before the
    // 7-argument registerPosition call — keeping that call's stack depth in range.
    function _mintAndRegister(
        address positionManager_,
        address token,
        address feeWallet,
        address token0,
        address token1,
        address pool
    ) private returns (uint256 tokenId) {
        {
            int24   currentTick;
            int24   tickLower;
            int24   tickUpper;
            uint256 amount0Desired;
            uint256 amount1Desired;

            (, currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

            if (token == token0) {
                // BlitzrToken is token0 → deposit only token0 by placing the active range above current tick.
                tickLower      = _floorToTickSpacing(currentTick) + TICK_SPACING; // > currentTick ✓
                tickUpper      = MAX_TICK;
                amount0Desired = TOTAL_SUPPLY;
                amount1Desired = 0;
            } else {
                // BlitzrToken is token1 → deposit only token1 by placing the active range below current tick.
                tickLower      = MIN_TICK;
                tickUpper      = _floorToTickSpacing(currentTick); // <= currentTick ✓
                amount0Desired = 0;
                amount1Desired = TOTAL_SUPPLY;
            }
            if (tickLower >= tickUpper) revert InvalidTickRange();

            _safeApprove(token, positionManager_, TOTAL_SUPPLY);

            (tokenId,,,) = INonfungiblePositionManager(positionManager_).mint(
                INonfungiblePositionManager.MintParams({
                    token0:         token0,
                    token1:         token1,
                    fee:            FEE_TIER,
                    tickLower:      tickLower,
                    tickUpper:      tickUpper,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min:     0,
                    amount1Min:     0,
                    recipient:      address(locker),
                    deadline:       block.timestamp
                })
            );
        } // tickLower, tickUpper, amount0Desired, amount1Desired freed here

        locker.registerPosition(token, tokenId, feeWallet, token0, token1, pool, positionManager_);
    }

    function _deployAndInit(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_
    ) private returns (address token) {
        // Salted by caller + block + the launch params themselves, so the resulting clone
        // address can't be precomputed and squatted ahead of time by an unrelated third party
        // scanning a predictable counter — only by racing this exact pending transaction.
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp, name_, symbol_, metaURI_));
        token = _clone(tokenImpl, salt);
        IBlitzrToken(token).initBlitzr(name_, symbol_, metaURI_, address(this), antiBotBlocks);
    }

    // sqrtPriceX96 targeting marketCapRef_ for TOTAL_SUPPLY, adjusted for token ordering.
    function _computeSqrtPriceX96(address blitzrToken, address quoteToken_, uint256 marketCapRef_)
        private pure returns (uint160)
    {
        // price = token1 / token0
        if (blitzrToken < quoteToken_) {
            // blitzrToken = token0, quote = token1 → price = marketCapRef_ / TOTAL_SUPPLY (very small)
            return _sqrtPriceX96(TOTAL_SUPPLY, marketCapRef_);
        } else {
            // quote = token0, blitzrToken = token1 → price = TOTAL_SUPPLY / marketCapRef_ (very large)
            return _sqrtPriceX96(marketCapRef_, TOTAL_SUPPLY);
        }
    }

    // Floor tick down to the nearest TICK_SPACING multiple (handles negative ticks correctly).
    function _floorToTickSpacing(int24 tick) private pure returns (int24) {
        int24 compressed = tick / TICK_SPACING;
        // Solidity truncates towards zero; subtract 1 for negative non-multiples.
        if (tick < 0 && tick % TICK_SPACING != 0) compressed--;
        return compressed * TICK_SPACING;
    }

    // EIP-1167 minimal proxy — 55-byte deployment (10 creation + 45 runtime).
    // CREATE2 (not CREATE) so the resulting address depends on `salt`, not just this
    // contract's nonce — see _deployAndInit for why that matters.
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

    // sqrtPriceX96 = sqrt(amount1 / amount0) × 2^96
    // Two-step to avoid 2^192 overflow:
    //   scaled = (amount1 << 96) / amount0   →  price × 2^96
    //   sqrt(scaled) << 48                   →  sqrt(price) × 2^96  ✓
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) private pure returns (uint160) {
        uint256 scaled = (amount1 << 96) / amount0;
        return uint160(_sqrt(scaled) << 48);
    }

    // Babylonian integer sqrt — returns floor(sqrt(x)).
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) >> 1;
        while (z < y) { y = z; z = (x / z + z) >> 1; }
    }

    // Reset allowance to 0 before setting — handles USDT's non-zero→non-zero restriction.
    function _safeApprove(address token_, address spender, uint256 amount) private {
        (bool reset,) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, 0));
        reset;
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert ApprovalFailed();
    }

    // transfer(address,uint256) — USDT-safe (handles missing return value).
    function _safeTransfer(address token_, address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token_.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
