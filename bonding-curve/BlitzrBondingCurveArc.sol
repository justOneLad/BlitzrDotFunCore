// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/IBlitzrLaunchToken.sol";

// Arc has no WETH, so unlike the BSC contract's shared IPancakeRouter02 (which declares
// addLiquidityETH), this router interface is ERC20-only: addLiquidity pulls both legs via
// transferFrom, with the native-USDC leg (ARC_USDC) passed explicitly like any other token.
interface IPancakeRouter02Arc {
    function factory() external pure returns (address);
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface IUniswapV3FactoryLP {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3PoolLP {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16  observationCardinality, uint16 observationCardinalityNext,
        uint32  feeProtocol, bool unlocked // PancakeSwap V3 packs this wider than vanilla Uniswap V3's uint8
    );
}

interface INonfungiblePositionManagerLP {
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

// Matches contracts/BlitzrLocker.sol's registerPosition — the shared V3 LP-lock and
// fee-distribution contract also used by the V3 Blitzr stack. BlitzrStandardToken migrations
// register their position there instead of a bonding-curve-specific vault.
interface IBlitzrLockerLP {
    function registerPosition(
        address token, uint256 tokenId, address feeWallet,
        address token0, address token1, address pool, address positionManager
    ) external;
}

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IStdInit {
    function initForBlitzr(
        string memory name_, string memory symbol_, uint256 totalSupply_,
        address launchManager_, address tokenOwner_, string memory metaURI_
    ) external;
}

interface ITaxInit {
    // Mirrors BlitzrTaxTokenArc.TaxConfig field-for-field — Solidity ABI-encodes structs by
    // member layout, not by declared name, so this local redeclaration is call-compatible.
    struct TaxConfig {
        uint256 buyLiquidityTax;
        uint256 buyReflectionTax;
        uint256 buyMarketingTax;
        uint256 sellLiquidityTax;
        uint256 sellReflectionTax;
        uint256 sellMarketingTax;
        address marketingWallet;
        address[] reflectionTokens;
    }
    function initForBlitzr(
        string memory name_, string memory symbol_, uint256 totalSupply_,
        address launchManager_, address creator_, string memory metaURI_,
        address router_, TaxConfig memory cfg
    ) external;
    function pancakePair() external view returns (address);
}

// Self-interface used by _finalizeBuy to wrap _doMigrate in a try/catch.
// try/catch only works on external calls; this exposes _doMigrate as one.
interface IBondingCurveSelf {
    function _tryMigrateExternal(address token_) external;
}

/// Blitzr — https://blitzr.fun
///
/// @notice Arc-network variant of BlitzrBondingCurve. Arc's native gas token IS USDC (6 decimals),
///         mirrored 1:1 as an ERC20 at the fixed address ARC_USDC below — there is no WETH on Arc,
///         and no wrap/unwrap step is ever needed: the moment this contract holds native value, that
///         same value is already spendable as ARC_USDC ERC20 balance. Because native == USDC, the
///         live price-oracle the BSC contract uses to convert USD market caps into native targets
///         is unnecessary here — market caps convert via a fixed decimal shift instead (see
///         _computeUSDCTargets). All DEX-facing calls use the plain ERC20 router functions
///         (addLiquidity / swap*Tokens*) rather than the ETH-suffixed sugar methods, since Arc's
///         router isn't assumed to implement those.
///
///         Single-contract launchpad: token creation (CREATE2 cloning), USD-denominated
///         bonding-curve sizing, all per-token AMM state and buy/sell/migrate execution, and DEX
///         migration (V2-and-burn for BlitzrTaxTokenArc, V3-and-lock-in-BlitzrLocker for
///         BlitzrStandardToken). There is no cross-contract trust boundary — a single owner governs
///         everything. Not upgradeable by design: a normal immutable contract.
contract BlitzrBondingCurveArc {

    struct TokenConfig {
        address   token;
        address   creator;

        uint256 totalSupply;
        uint256 liquidityTokens;
        uint256 bcTokensTotal;
        uint256 bcTokensSold;

        uint256 virtualUSDC;
        uint256 k;
        uint256 raisedUSDC;
        uint256 migrationTarget;

        // V2 pair (BlitzrTaxTokenArc) or V3 pool (BlitzrStandardToken) — both are created, and
        // for V3 price-initialized, at createToken()/createTT() time, not deferred to
        // migration. Liquidity is added at migration; this address never changes after that.
        address pair;
        address router;           // snapshotted at registration; immune to a later setRouter
        address v3PositionManager; // snapshotted at registration (useV3 only); immune to a later
                                    // setV3PositionManager between pool creation and migration

        bool    antibotEnabled;
        uint256 creationBlock;
        uint256 tradingBlock;

        bool migrated;
        bool migrationPending; // set when migration-cap buy commits but auto-migration reverts
        bool useV3; // BlitzrStandardToken migrates to a V3 1% pool, locked in the shared BlitzrLocker;
                    // BlitzrTaxTokenArc keeps the existing V2-and-burn path.
    }

    struct Alloc {
        uint256 supply;
        uint256 liqTokens;
        uint256 bcTokens;
    }

    struct BaseParams {
        string       name;
        string       symbol;
        uint256      totalSupply;           // 18-decimal token amount; bounded by minSupply/maxSupply
        uint256      curveBps;
        uint256      liquidityBps;
        uint256      startMarketCapUSD;     // 18-decimal USD, e.g. 5000e18 = $5,000
        uint256      migrationMarketCapUSD; // 18-decimal USD
        bool         enableAntibot;
        uint256      antibotBlocks;
        string       metaURI;
        bytes32      salt;
    }

    struct CreateTTParams {
        string       name;
        string       symbol;
        string       metaURI;
        uint256      totalSupply;
        uint256      curveBps;
        uint256      liquidityBps;
        uint256      startMarketCapUSD;
        uint256      migrationMarketCapUSD;
        bool         enableAntibot;
        uint256      antibotBlocks;
        bytes32      salt;
        // Tax config — fixed for the token's lifetime; see BlitzrTaxTokenArc.sol.
        uint256      buyLiquidityTax;
        uint256      buyReflectionTax;
        uint256      buyMarketingTax;
        uint256      sellLiquidityTax;
        uint256      sellReflectionTax;
        uint256      sellMarketingTax;
        address      marketingWallet;   // address(0) defaults to msg.sender
        address[]    reflectionTokens;  // required (1-4) iff either reflection tax > 0; must be allowlisted
    }

    struct BuyResult {
        uint256 refund;
        uint256 fee;
        uint256 tokensOut;
        uint256 netUSDCIn;
    }

    uint256 private constant BPS_DENOM          = 10_000;
    uint256 private constant MAX_TOTAL_FEE      =    250; // 2.5 %
    uint256 private constant ANTIBOT_MIN_BLOCKS =     10;
    uint256 private constant ANTIBOT_MAX_BLOCKS =    199;
    address private constant DEAD               = 0x000000000000000000000000000000000000dEaD;

    // Arc's native gas token IS USDC (6 decimals), mirrored as an ERC20 at this fixed,
    // network-wide address — balances are always in sync with native value, so no wrap/unwrap
    // step is ever needed before using it in DEX calls.
    address private constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    // 18-decimal USD market-cap input -> 6-decimal ARC_USDC native units. Since native == USDC
    // already, this is a fixed decimal shift, not a live price-oracle conversion.
    uint256 private constant USD_TO_NATIVE_SHIFT = 1e12;

    uint24 private constant V3_FEE_TIER = 10_000;  // 1 % tier; tick spacing 200 on this tier
    int24  private constant V3_MIN_TICK = -887_200; // full-range, aligned to the 1 % tier's spacing
    int24  private constant V3_MAX_TICK =  887_200;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    // ── Admin ─────────────────────────────────────────────────────────────────────
    address public owner;
    address public pendingOwner;

    address public standardImpl;
    address public taxImpl;
    address public locker;

    // ── BlitzrTaxTokenArc reflection-token allowlist ─────────────────────────────
    mapping(address => bool) public reflectionTokenAllowed;

    // ── DEX config ────────────────────────────────────────────────────────────────
    address public pancakeRouter;
    address public v3PositionManager;
    address public v3Factory;

    // ── Allocation guardrails (creator picks curve/liquidity bps per launch) ────────
    uint256 public minCurveBps     = 3000; // 30 % minimum on the bonding curve
    uint256 public minLiquidityBps = 1000; // 10 % minimum DEX liquidity at migration

    // ── Supply guardrails (creator picks an arbitrary totalSupply per launch) ───────
    uint256 public minSupply = 1e18;                   // 1 token minimum
    uint256 public maxSupply = 999_000_000_000_000e18; // 999 trillion tokens maximum

    // ── Fees ──────────────────────────────────────────────────────────────────────
    uint256 public platformFee;
    address public feeRecipient;
    uint256 public creationFee;

    // ── Token registry ────────────────────────────────────────────────────────────
    // The auto-generated public getter for this many fields exceeds the EVM's 16-slot
    // stack limit without viaIR. Use getToken() instead.
    mapping(address => TokenConfig) internal tokens;
    address[] public allTokens;
    mapping(address => address[]) private _tokensByCreator;

    uint256 private _totalRaisedUSDC; // sum of all active raisedUSDC pools; used by rescueUSDC
    uint256 private _status;

    error NotOwner();
    error NotPendingOwner();
    error Reentrancy();
    error ZeroAddress();
    error ZeroAmount();
    error FeeExceedsMax();
    error InsufficientCreationFee(uint256 required, uint256 provided);
    error CloneFailed();
    error VanityAddressRequired();
    error USDCTransferFailed();
    error RefundFailed();
    error DeadlineExpired();
    error TransferFailed();
    error UnknownToken();
    error AlreadyMigrated();
    error ExceedsSoldSupply();
    error LiquidityReserveViolation();
    error InsufficientPoolUSDC();
    error SlippageTooLittleUSDC();
    error SlippageTooFewTokens();
    error MigrationTargetNotReached();
    error ActivePool();
    error AntibotBlocksOutOfRange();
    error PoolAlreadyExists();
    error LockerNotSet();
    error InvalidAllocation();
    error InvalidMarketCaps();
    error InvalidSupply();
    error MigrationPending();
    error InsufficientContractBalance();
    error CannotRescueNativeUSDC();

    event TokenCreated(
        address indexed token,
        address indexed creator,
        uint256         totalSupply,
        uint256         virtualUSDC,
        uint256         migrationTarget,
        bool            antibotEnabled,
        uint256         tradingBlock
    );
    event TokenRegistered(
        address indexed token,
        address indexed creator,
        uint256         totalSupply,
        uint256         virtualUSDC,
        uint256         migrationTarget
    );
    event TokenBought(
        address indexed token, address indexed buyer,
        uint256 usdcIn, uint256 tokensOut, uint256 tokensToDead, uint256 raisedUSDC
    );
    event TokenSold(
        address indexed token, address indexed seller,
        uint256 tokensIn, uint256 usdcOut, uint256 raisedUSDC
    );
    event TokenMigrated(
        address indexed token, address indexed pair, uint256 liquidityUSDC, uint256 liquidityTokens
    );
    event EmergencyMigrated(
        address indexed token, address indexed to, uint256 usdcAmount, uint256 tokenAmount
    );
    event MigrationFailed(address indexed token);
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event V3PositionManagerUpdated(address indexed oldPM, address indexed newPM);
    event V3FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event AllocationBoundsUpdated(uint256 minCurveBps, uint256 minLiquidityBps);
    event SupplyBoundsUpdated(uint256 minSupply, uint256 maxSupply);
    event FeesUpdated(uint256 platformFee);
    event FeeRecipientUpdated(address recipient);
    event LockerUpdated(address indexed prev, address indexed next);
    event OwnershipTransferProposed(address indexed current, address indexed proposed);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event USDCRescued(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ImplUpdated(string implType, address indexed prev, address indexed next);
    event ReflectionTokenAllowlisted(address indexed token, bool allowed);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(
        address router_,
        address v3PositionManager_,
        address v3Factory_,
        address feeRecipient_,
        uint256 platformFee_,
        address standardImpl_,
        address taxImpl_,
        address locker_,
        uint256 creationFee_
    ) {
        if (router_             == address(0)) revert ZeroAddress();
        if (v3PositionManager_  == address(0)) revert ZeroAddress();
        if (v3Factory_          == address(0)) revert ZeroAddress();
        if (feeRecipient_       == address(0)) revert ZeroAddress();
        if (platformFee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();
        if (standardImpl_       == address(0)) revert ZeroAddress();
        if (taxImpl_            == address(0)) revert ZeroAddress();
        if (locker_             == address(0)) revert ZeroAddress();

        owner             = msg.sender;
        pancakeRouter     = router_;
        v3PositionManager = v3PositionManager_;
        v3Factory         = v3Factory_;
        feeRecipient      = feeRecipient_;
        platformFee       = platformFee_;
        standardImpl      = standardImpl_;
        taxImpl           = taxImpl_;
        locker            = locker_;
        creationFee       = creationFee_;
        _status           = _NOT_ENTERED;
    }

    // ── Token creation ────────────────────────────────────────────────────────────

    function createToken(BaseParams memory p) external payable nonReentrant returns (address token) {
        uint256 earlyBuy = _collectCreationFee();
        token = _cloneCreate2(standardImpl, p.salt);

        Alloc memory a = _computeAlloc(p.totalSupply, p.curveBps, p.liquidityBps);
        (uint256 vUSDC, uint256 migTarget) = _computeUSDCTargets(
            p.startMarketCapUSD, p.migrationMarketCapUSD, a.bcTokens, a.liqTokens, a.supply
        );

        // Created and price-initialized now rather than deferred to migration — see
        // "Security Properties" for why. Reverts the whole call if the pool is already
        // initialized (front-run), instead of stranding a bonding curve mid-raise later.
        address pool = _createV3Pool(token, migTarget, a.liqTokens);

        IStdInit(token).initForBlitzr(
            p.name, p.symbol, a.supply, address(this), msg.sender, p.metaURI
        );
        uint256 tradingBlock_ = _registerToken(
            token, msg.sender, a, vUSDC, migTarget, pool, true, p.enableAntibot, p.antibotBlocks
        );
        emit TokenCreated(token, msg.sender, a.supply, vUSDC, migTarget, p.enableAntibot, tradingBlock_);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);
    }

    function createTT(CreateTTParams memory p) external payable nonReentrant returns (address payable token) {
        uint256 earlyBuy = _collectCreationFee();
        token = payable(_cloneCreate2(taxImpl, p.salt));

        Alloc memory a = _computeAlloc(p.totalSupply, p.curveBps, p.liquidityBps);
        (uint256 vUSDC, uint256 migTarget) = _computeUSDCTargets(
            p.startMarketCapUSD, p.migrationMarketCapUSD, a.bcTokens, a.liqTokens, a.supply
        );

        ITaxInit(token).initForBlitzr(
            p.name, p.symbol, a.supply, address(this), msg.sender, p.metaURI, pancakeRouter,
            ITaxInit.TaxConfig({
                buyLiquidityTax:   p.buyLiquidityTax,
                buyReflectionTax:  p.buyReflectionTax,
                buyMarketingTax:   p.buyMarketingTax,
                sellLiquidityTax:  p.sellLiquidityTax,
                sellReflectionTax: p.sellReflectionTax,
                sellMarketingTax:  p.sellMarketingTax,
                marketingWallet:   p.marketingWallet,
                reflectionTokens:  p.reflectionTokens
            })
        );
        // BlitzrTaxTokenArc keeps the existing V2-and-burn migration path (useV3 = false).
        uint256 tradingBlock_ = _registerToken(
            token, msg.sender, a, vUSDC, migTarget, ITaxInit(token).pancakePair(), false, p.enableAntibot, p.antibotBlocks
        );
        emit TokenCreated(token, msg.sender, a.supply, vUSDC, migTarget, p.enableAntibot, tradingBlock_);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);
    }

    // ── Trading ───────────────────────────────────────────────────────────────────

    function buy(address token_, uint256 minOut, uint256 deadline) external payable nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (msg.value == 0) revert ZeroAmount();
        _executeBuy(token_, msg.sender, msg.value, minOut, false);
    }

    function sell(address token_, uint256 amountIn, uint256 minUSDCOut, uint256 deadline)
        external nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();
        IBlitzrLaunchToken(token_).transferFrom(msg.sender, address(this), amountIn);
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0))   revert UnknownToken();
        if (tc.migrated)              revert AlreadyMigrated();
        if (tc.migrationPending)      revert MigrationPending();
        // Only tokens previously bought can be sold back; liquidityTokens are never
        // part of the BC pool and are always reserved for migration.
        if (amountIn > tc.bcTokensSold) revert ExceedsSoldSupply();
        (uint256 fee, uint256 netUSDC) = _computeSell(tc, amountIn, minUSDCOut);
        uint256 raisedAfter = tc.raisedUSDC;
        (bool ok,) = payable(msg.sender).call{value: netUSDC}("");
        if (!ok) revert USDCTransferFailed();
        _dispatchFee(fee);
        emit TokenSold(token_, msg.sender, amountIn, netUSDC, raisedAfter);
    }

    function migrate(address token_) external nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (!tc.migrationPending)   revert MigrationTargetNotReached();
        _doMigrate(tc, token_);
    }

    // Entry point for the try/catch in _finalizeBuy. Not guarded by nonReentrant so it
    // can be called while the outer buy() is holding _status = _ENTERED. Only callable
    // by address(this) — any reentrant call from a DEX callback into buy/sell/migrate
    // still hits the outer _ENTERED guard and reverts, keeping the guard effective.
    function _tryMigrateExternal(address token_) external {
        if (msg.sender != address(this)) revert NotOwner();
        TokenConfig storage tc = tokens[token_];
        _doMigrate(tc, token_);
    }

    // Used when a V3 pool has been pre-initialized by an attacker at the predicted token
    // address, causing _getOrCreateV3Pool to revert with PoolAlreadyExists(). The owner
    // receives the raised USDC and liquidity tokens to provision DEX liquidity manually,
    // while all other migration accounting (_totalRaisedUSDC, postMigrateSetup, unsold burn)
    // runs identically to the normal path so the token's state is fully closed out.
    function emergencyMigrate(address token_) external onlyOwner nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (!tc.migrationPending)   revert MigrationTargetNotReached();

        tc.migrated         = true;
        tc.migrationPending = false;

        uint256 migrationUSDC = tc.raisedUSDC;
        uint256 liqTokens    = tc.liquidityTokens;
        address to           = owner;

        // Mirror the _computeSell InsufficientPoolUSDC guard: never send more than the
        // contract actually holds, even if accounting somehow drifts.
        if (migrationUSDC > address(this).balance)
            revert InsufficientContractBalance();

        if (migrationUSDC >= _totalRaisedUSDC) _totalRaisedUSDC = 0;
        else                                 _totalRaisedUSDC -= migrationUSDC;
        tc.raisedUSDC = 0;

        IBlitzrLaunchToken(token_).postMigrateSetup();

        if (liqTokens > 0) {
            if (!IERC20Min(token_).transfer(to, liqTokens)) revert TransferFailed();
        }
        _safeSendUSDC(to, migrationUSDC);

        emit EmergencyMigrated(token_, to, migrationUSDC, liqTokens);
    }

    // ── Governance ────────────────────────────────────────────────────────────────

    function setCreationFee(uint256 fee_) external onlyOwner {
        emit CreationFeeUpdated(creationFee, fee_);
        creationFee = fee_;
    }

    function setAllocationBounds(uint256 minCurveBps_, uint256 minLiquidityBps_) external onlyOwner {
        if (minCurveBps_ + minLiquidityBps_ > BPS_DENOM) revert InvalidAllocation();
        minCurveBps     = minCurveBps_;
        minLiquidityBps = minLiquidityBps_;
        emit AllocationBoundsUpdated(minCurveBps_, minLiquidityBps_);
    }

    function setSupplyBounds(uint256 minSupply_, uint256 maxSupply_) external onlyOwner {
        if (minSupply_ == 0 || minSupply_ > maxSupply_) revert InvalidSupply();
        minSupply = minSupply_;
        maxSupply = maxSupply_;
        emit SupplyBoundsUpdated(minSupply_, maxSupply_);
    }

    function setStandardImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        emit ImplUpdated("standard", standardImpl, impl_);
        standardImpl = impl_;
    }

    function setTaxImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        emit ImplUpdated("tax", taxImpl, impl_);
        taxImpl = impl_;
    }

    // Reflection tokens are chosen per-launch from this owner-managed allowlist (checked by
    // BlitzrTaxTokenArc itself at init, callable back against launchManager) — creators can't
    // designate an arbitrary, potentially malicious token as a reflection target.
    function setReflectionTokenAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        reflectionTokenAllowed[token] = allowed;
        emit ReflectionTokenAllowlisted(token, allowed);
    }

    function setLocker(address locker_) external onlyOwner {
        if (locker_ == address(0)) revert ZeroAddress();
        emit LockerUpdated(locker, locker_);
        locker = locker_;
    }

    function setRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        address factory_ = IPancakeRouter02Arc(router_).factory();
        if (factory_ == address(0)) revert ZeroAddress();
        emit RouterUpdated(pancakeRouter, router_);
        pancakeRouter = router_;
    }

    function setV3PositionManager(address pm_) external onlyOwner {
        if (pm_ == address(0)) revert ZeroAddress();
        emit V3PositionManagerUpdated(v3PositionManager, pm_);
        v3PositionManager = pm_;
    }

    function setV3Factory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        emit V3FactoryUpdated(v3Factory, factory_);
        v3Factory = factory_;
    }

    function setPlatformFee(uint256 fee_) external onlyOwner {
        if (fee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();
        platformFee = fee_;
        emit FeesUpdated(fee_);
    }

    function setFeeRecipient(address rec_) external onlyOwner {
        if (rec_ == address(0)) revert ZeroAddress();
        feeRecipient = rec_;
        emit FeeRecipientUpdated(rec_);
    }

    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert ZeroAddress();
        pendingOwner = newOwner_;
        emit OwnershipTransferProposed(owner, newOwner_);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner        = msg.sender;
        pendingOwner = address(0);
    }

    // ── Rescue ────────────────────────────────────────────────────────────────────

    function rescueUSDC(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (address(this).balance <= _totalRaisedUSDC) revert ZeroAmount();
        uint256 amount = address(this).balance - _totalRaisedUSDC;
        _safeSendUSDC(to, amount);
        emit USDCRescued(to, amount);
    }

    function rescueToken(address token_, address to) external onlyOwner nonReentrant {
        if (token_ == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        // ARC_USDC's ERC20 balance is always in sync with this contract's native balance —
        // rescuing it here would bypass rescueUSDC()'s _totalRaisedUSDC reserve check and let the
        // owner drain funds still owed to every unmigrated bonding curve. Native/USDC rescue
        // must go through rescueUSDC() instead, which is reserve-aware.
        if (token_ == ARC_USDC) revert CannotRescueNativeUSDC();
        TokenConfig storage tc = tokens[token_];
        if (tc.token != address(0) && !tc.migrated) revert ActivePool();
        uint256 bal = IERC20Min(token_).balanceOf(address(this));
        if (bal == 0) revert ZeroAmount();
        if (!IERC20Min(token_).transfer(to, bal)) revert TransferFailed();
        emit TokenRescued(token_, to, bal);
    }

    // ── Internal: creation / allocation / USD conversion ─────────────────────────

    function _registerToken(
        address token_,
        address creator_,
        Alloc memory a,
        uint256 virtualUSDC_,
        uint256 migrationTarget_,
        address pair_,
        bool useV3_,
        bool enableAntibot_,
        uint256 antibotBlocks_
    ) private returns (uint256 tradingBlock_) {
        uint256 antibotBlocks = 0;
        if (enableAntibot_) {
            if (antibotBlocks_ < ANTIBOT_MIN_BLOCKS || antibotBlocks_ > ANTIBOT_MAX_BLOCKS)
                revert AntibotBlocksOutOfRange();
            antibotBlocks = antibotBlocks_;
        }

        TokenConfig storage tc = tokens[token_];
        tc.token           = token_;
        tc.creator         = creator_;
        tc.totalSupply     = a.supply;
        tc.liquidityTokens = a.liqTokens;
        tc.bcTokensTotal   = a.bcTokens;
        tc.bcTokensSold    = 0;
        tc.virtualUSDC      = virtualUSDC_;
        tc.k               = virtualUSDC_ * a.bcTokens;
        tc.raisedUSDC       = 0;
        tc.migrationTarget = migrationTarget_;
        tc.pair            = pair_;
        tc.router          = pancakeRouter; // snapshotted at registration; immune to future setRouter calls
        // Snapshotted here (not read live at migration) since the pool is created now but
        // liquidity is only minted at migration — a setV3PositionManager in between must not
        // change which position manager this token's eventual mint call uses.
        if (useV3_) tc.v3PositionManager = v3PositionManager;
        tc.antibotEnabled  = enableAntibot_;
        tc.creationBlock   = block.number;
        tc.tradingBlock    = block.number + antibotBlocks;
        tc.migrated        = false;
        tc.useV3           = useV3_;

        allTokens.push(token_);
        _tokensByCreator[creator_].push(token_);
        tradingBlock_ = tc.tradingBlock;

        emit TokenRegistered(token_, creator_, a.supply, virtualUSDC_, migrationTarget_);
    }

    function _computeAlloc(
        uint256 supply, uint256 curveBps, uint256 liquidityBps
    ) private view returns (Alloc memory a) {
        if (supply < minSupply || supply > maxSupply) revert InvalidSupply();
        if (curveBps + liquidityBps != BPS_DENOM) revert InvalidAllocation();
        if (curveBps     < minCurveBps)     revert InvalidAllocation();
        if (liquidityBps < minLiquidityBps) revert InvalidAllocation();

        a.supply    = supply;
        a.liqTokens = (supply * liquidityBps) / BPS_DENOM;
        a.bcTokens  = supply - a.liqTokens;
    }

    // Converts creator-chosen $ market-cap targets into native (ARC_USDC) units. Arc's native
    // token IS USDC, so this is a fixed decimal shift (18-decimal USD -> 6-decimal native) rather
    // than a live price-oracle read — unlike the BSC contract, there is no price-oracle pair to query.
    function _computeUSDCTargets(
        uint256 startMarketCapUSD,
        uint256 migrationMarketCapUSD,
        uint256 curveTokens,
        uint256 liqTokens,
        uint256 totalSupply
    ) private pure returns (uint256 virtualUSDC, uint256 migrationTarget) {
        if (startMarketCapUSD == 0 || migrationMarketCapUSD <= startMarketCapUSD) revert InvalidMarketCaps();
        virtualUSDC      = (startMarketCapUSD     * curveTokens) / totalSupply / USD_TO_NATIVE_SHIFT;
        migrationTarget = (migrationMarketCapUSD * liqTokens)   / totalSupply / USD_TO_NATIVE_SHIFT;
        if (virtualUSDC == 0 || migrationTarget == 0) revert InvalidMarketCaps();
    }

    function _collectCreationFee() private returns (uint256 earlyBuy) {
        uint256 cf = creationFee;
        if (msg.value < cf) revert InsufficientCreationFee(cf, msg.value);
        earlyBuy = msg.value - cf;
        if (cf > 0) _safeSendUSDC(feeRecipient, cf);
    }

    // Salt is bound to msg.sender to prevent cross-sender front-running.
    // The resulting address must end in 0x1111 (vanity requirement).
    function _cloneCreate2(address implementation, bytes32 userSalt) private returns (address instance) {
        bytes32 salt = keccak256(abi.encode(msg.sender, userSalt));
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,         0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0))              revert CloneFailed();
        if (uint16(uint160(instance)) != 0x1111) revert VanityAddressRequired();
    }

    // ── Internal: buy/sell/migrate (bonding-curve math, DEX-agnostic) ─────────────

    function _executeBuy(
        address token_, address buyer, uint256 usdcIn, uint256 minOut, bool skipAntibot
    ) private {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0))  revert UnknownToken();
        if (tc.migrated)             revert AlreadyMigrated();
        if (tc.migrationPending)     revert MigrationPending();
        BuyResult memory r = _calcBuy(tc, usdcIn, minOut);
        _dispatchFee(r.fee);
        _finalizeBuy(tc, token_, buyer, skipAntibot, r);
    }

    function _calcBuy(
        TokenConfig storage tc, uint256 usdcIn, uint256 minOut
    ) private returns (BuyResult memory r) {
        uint256 poolUSDC    = tc.virtualUSDC + tc.raisedUSDC;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 totalFee   = platformFee;
        // Ceiling division ensures net amount covers the migration target after fee deduction.
        uint256 grossNeeded = totalFee == 0
            ? tc.migrationTarget - tc.raisedUSDC
            : ((tc.migrationTarget - tc.raisedUSDC) * BPS_DENOM
                + (BPS_DENOM - totalFee) - 1)
              / (BPS_DENOM - totalFee);
        uint256 netUSDC;

        if (usdcIn >= grossNeeded) {
            // Migration-cap: sell all remaining BC tokens and refund excess USDC.
            r.refund    = usdcIn - grossNeeded;
            r.fee       = (grossNeeded * totalFee) / BPS_DENOM;
            netUSDC      = grossNeeded - r.fee;
            r.tokensOut = poolTokens;
            r.netUSDCIn  = grossNeeded;
        } else {
            r.fee       = totalFee == 0
                ? 0
                : (usdcIn * totalFee + BPS_DENOM - 1) / BPS_DENOM;
            netUSDC      = usdcIn - r.fee;
            r.tokensOut = poolTokens - ((tc.k + poolUSDC + netUSDC - 1) / (poolUSDC + netUSDC));
            r.netUSDCIn  = usdcIn;
        }

        if (r.tokensOut == 0)         revert ZeroAmount();
        if (r.tokensOut < minOut)     revert SlippageTooFewTokens();
        if (r.tokensOut > poolTokens) revert LiquidityReserveViolation();

        tc.raisedUSDC    += netUSDC;
        _totalRaisedUSDC += netUSDC;
        tc.bcTokensSold += r.tokensOut;
    }

    function _finalizeBuy(
        TokenConfig storage tc, address token_, address buyer, bool skipAntibot, BuyResult memory r
    ) private {
        uint256 tokensToDead;
        {
            if (!skipAntibot && tc.antibotEnabled && block.number < tc.tradingBlock) {
                uint256 remaining   = tc.tradingBlock - block.number;
                uint256 totalBlocks = tc.tradingBlock - tc.creationBlock;
                // Ceiling keeps the penalty from rounding down at the boundary block.
                uint256 penaltyBPS  = (remaining * BPS_DENOM + totalBlocks - 1) / totalBlocks;
                if (penaltyBPS > BPS_DENOM) penaltyBPS = BPS_DENOM;
                tokensToDead = (r.tokensOut * penaltyBPS) / BPS_DENOM;
            }
        }

        if (tokensToDead > 0)               IBlitzrLaunchToken(token_).transfer(DEAD, tokensToDead);
        if (r.tokensOut - tokensToDead > 0) IBlitzrLaunchToken(token_).transfer(buyer, r.tokensOut - tokensToDead);

        if (r.refund > 0) {
            (bool ok,) = payable(buyer).call{value: r.refund}("");
            if (!ok) revert RefundFailed();
        }

        emit TokenBought(token_, buyer, r.netUSDCIn, r.tokensOut, tokensToDead, tc.raisedUSDC);

        if (!tc.migrated && tc.raisedUSDC >= tc.migrationTarget) {
            // Try migration in the same tx. If _doMigrateV3 reverts (e.g. pool pre-initialized
            // by an attacker), the buy still commits and migrationPending is set so that
            // migrate() or emergencyMigrate() can be called in a separate tx.
            try IBondingCurveSelf(address(this))._tryMigrateExternal(token_) {
                // migrated successfully in same tx
            } catch {
                tc.migrationPending = true;
                emit MigrationFailed(token_);
            }
        }
    }

    function _doMigrate(TokenConfig storage tc, address token_) private {
        tc.migrated          = true;
        tc.migrationPending  = false;

        uint256 migrationUSDC = tc.raisedUSDC;
        uint256 liqTokens    = tc.liquidityTokens;

        // Safety nets: accounting invariants always hold, but verify before touching external funds.
        if (IBlitzrLaunchToken(token_).balanceOf(address(this)) < liqTokens)
            revert LiquidityReserveViolation();
        if (migrationUSDC > address(this).balance)
            revert InsufficientContractBalance();

        if (migrationUSDC >= _totalRaisedUSDC) _totalRaisedUSDC = 0;
        else                                 _totalRaisedUSDC -= migrationUSDC;

        address pair_ = tc.useV3
            ? _doMigrateV3(tc, token_, migrationUSDC, liqTokens)
            : _doMigrateV2(tc, token_, migrationUSDC, liqTokens);

        IBlitzrLaunchToken(token_).postMigrateSetup();
        tc.raisedUSDC = 0;
        emit TokenMigrated(token_, pair_, migrationUSDC, liqTokens);
    }

    // BlitzrTaxTokenArc path — LP tokens sent to the dead wallet, permanently locked.
    // 99 % minimums protect against pre-seeded pair sandwich attacks. Uses the plain ERC20
    // addLiquidity (not addLiquidityETH) since Arc's native USDC is used here purely as an ERC20
    // — both legs are pulled via transferFrom, so both must be approved first.
    function _doMigrateV2(
        TokenConfig storage tc, address token_, uint256 migrationUSDC, uint256 liqTokens
    ) private returns (address pair_) {
        pair_ = tc.pair;
        address router_ = tc.router;
        IBlitzrLaunchToken(token_).approve(router_, liqTokens);
        _safeApprove(ARC_USDC, router_, migrationUSDC);
        IPancakeRouter02Arc(router_).addLiquidity(
            token_, ARC_USDC,
            liqTokens,    migrationUSDC,
            liqTokens    * 9900 / 10000,
            migrationUSDC * 9900 / 10000,
            DEAD, block.timestamp + 300
        );
    }

    // BlitzrStandardToken path — the pool already exists and is price-initialized (see
    // _createV3Pool, run at createToken() time); this just mints a full-range position directly
    // to the shared contracts/BlitzrLocker.sol, and locks it there permanently, same as every V3
    // Blitzr launch. The creator earns an ongoing share of the pool's own 1 % trading fees instead
    // of the LP being burned outright. No wrap step is needed: the raised value already sits in
    // this contract as spendable ARC_USDC ERC20 balance (native and ERC20 balances are in sync).
    function _doMigrateV3(
        TokenConfig storage tc, address token_, uint256 migrationUSDC, uint256 liqTokens
    ) private returns (address pool) {
        address lockerAddr = locker;
        if (lockerAddr == address(0)) revert LockerNotSet();

        pool = tc.pair;

        // V3 requires token0 < token1 by address.
        (address token0, address token1, uint256 amount0, uint256 amount1) = token_ < ARC_USDC
            ? (token_, ARC_USDC, liqTokens,    migrationUSDC)
            : (ARC_USDC, token_, migrationUSDC, liqTokens);

        uint256 tokenId = _mintV3Position(token0, token1, amount0, amount1, lockerAddr, tc.v3PositionManager);
        IBlitzrLockerLP(lockerAddr).registerPosition(
            token_, tokenId, tc.creator, token0, token1, pool, tc.v3PositionManager
        );
    }

    // Called once, from createToken(), before the token is even registered — establishes the
    // pool and its opening price up front instead of at migration. migrationTarget_ and
    // liqTokens are both fixed at this point and never change afterward, and the bonding
    // curve's cap guarantees migration raises exactly migrationTarget_ native USDC by
    // construction, so this is the exact price the pool will actually receive liquidity at.
    function _createV3Pool(
        address token_, uint256 migrationTarget_, uint256 liqTokens
    ) private returns (address pool) {
        (address token0, address token1, uint256 amount0, uint256 amount1) = token_ < ARC_USDC
            ? (token_,   ARC_USDC,        liqTokens, migrationTarget_)
            : (ARC_USDC, token_,    migrationTarget_, liqTokens);
        pool = _getOrCreateV3Pool(token0, token1, amount0, amount1);
    }

    // A pool can already exist at this (token0, token1, V3_FEE_TIER) key if someone front-ran
    // createPool() with the token's predictable address — createPool() is permissionless on
    // the DEX factory. An uninitialized shell is harmless: we adopt and initialize it
    // ourselves. Only a pool someone has *already initialized* is a genuine collision — and
    // since this now runs inside createToken() itself, that collision reverts the whole launch
    // up front, before any trading or funds are ever at risk, rather than stranding a bonding
    // curve mid-raise the way deferring this to migration time would.
    function _getOrCreateV3Pool(
        address token0, address token1, uint256 amount0, uint256 amount1
    ) private returns (address pool) {
        address factory_ = v3Factory;
        pool = IUniswapV3FactoryLP(factory_).getPool(token0, token1, V3_FEE_TIER);
        if (pool == address(0)) {
            pool = IUniswapV3FactoryLP(factory_).createPool(token0, token1, V3_FEE_TIER);
        } else {
            (uint160 existingPrice,,,,,,) = IUniswapV3PoolLP(pool).slot0();
            if (existingPrice != 0) revert PoolAlreadyExists();
        }
        IUniswapV3PoolLP(pool).initialize(_sqrtPriceX96(amount0, amount1));
    }

    // Full-range mint — behaves like a V2 LP, absorbing nearly all of both amounts at the
    // ratio the pool was initialized to. 99 % minimums mirror the V2 path's tolerance. `pm` is
    // the position manager snapshotted at createToken() time (tc.v3PositionManager), not
    // necessarily today's v3PositionManager — the pool was created against that exact one.
    function _mintV3Position(
        address token0, address token1, uint256 amount0, uint256 amount1, address vault, address pm
    ) private returns (uint256 tokenId) {
        _safeApprove(token0, pm, amount0);
        _safeApprove(token1, pm, amount1);
        (tokenId,,,) = INonfungiblePositionManagerLP(pm).mint(
            INonfungiblePositionManagerLP.MintParams({
                token0:         token0,
                token1:         token1,
                fee:            V3_FEE_TIER,
                tickLower:      V3_MIN_TICK,
                tickUpper:      V3_MAX_TICK,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min:     amount0 * 9900 / 10000,
                amount1Min:     amount1 * 9900 / 10000,
                recipient:      vault,
                deadline:       block.timestamp + 300
            })
        );
    }

    // sqrtPriceX96 = sqrt(amount1 / amount0) × 2^96, i.e. price = token1/token0.
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
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _computeSell(
        TokenConfig storage tc, uint256 amountIn, uint256 minUSDCOut
    ) private returns (uint256 fee, uint256 netUSDC) {
        uint256 poolUSDC     = tc.virtualUSDC + tc.raisedUSDC;
        uint256 newPoolToks = tc.bcTokensTotal - tc.bcTokensSold + amountIn;
        uint256 newPoolUSDC  = (tc.k + newPoolToks - 1) / newPoolToks;
        uint256 grossUSDC    = poolUSDC > newPoolUSDC ? poolUSDC - newPoolUSDC : 0;
        if (grossUSDC > tc.raisedUSDC) revert InsufficientPoolUSDC();
        uint256 totalFee    = platformFee;
        fee    = totalFee == 0 ? 0 : (grossUSDC * totalFee + BPS_DENOM - 1) / BPS_DENOM;
        netUSDC = grossUSDC - fee;
        if (netUSDC < minUSDCOut) revert SlippageTooLittleUSDC();
        tc.raisedUSDC -= grossUSDC;
        if (grossUSDC >= _totalRaisedUSDC) _totalRaisedUSDC = 0;
        else                             _totalRaisedUSDC -= grossUSDC;
        tc.bcTokensSold -= amountIn;
    }

    function _dispatchFee(uint256 amount) private {
        if (amount == 0) return;
        _safeSendUSDC(feeRecipient, amount);
    }

    function _safeSendUSDC(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert USDCTransferFailed();
    }

    // ── Views ─────────────────────────────────────────────────────────────────────

    function getAmountOut(address token_, uint256 usdcIn)
        external view
        returns (uint256 tokensOut, uint256 feeUSDC)
    {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0) || tc.migrated) return (0, 0);

        uint256 poolUSDC     = tc.virtualUSDC + tc.raisedUSDC;
        uint256 poolTokens  = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 totalFee    = platformFee;
        uint256 grossNeeded = totalFee == 0
            ? tc.migrationTarget - tc.raisedUSDC
            : ((tc.migrationTarget - tc.raisedUSDC) * BPS_DENOM + (BPS_DENOM - totalFee) - 1)
              / (BPS_DENOM - totalFee);

        if (usdcIn >= grossNeeded) {
            feeUSDC    = (grossNeeded * totalFee) / BPS_DENOM;
            tokensOut = poolTokens;
        } else {
            feeUSDC         = totalFee == 0 ? 0 : (usdcIn * totalFee + BPS_DENOM - 1) / BPS_DENOM;
            uint256 netUSDC = usdcIn - feeUSDC;
            tokensOut = poolTokens - ((tc.k + poolUSDC + netUSDC - 1) / (poolUSDC + netUSDC));
        }
    }

    function getAmountOutSell(address token_, uint256 tokensIn)
        external view
        returns (uint256 usdcOut, uint256 feeUSDC)
    {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0) || tc.migrated || tc.bcTokensSold < tokensIn) return (0, 0);
        uint256 poolUSDC     = tc.virtualUSDC + tc.raisedUSDC;
        uint256 poolToks    = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 newPoolToks = poolToks + tokensIn;
        uint256 newPoolUSDC  = (tc.k + newPoolToks - 1) / newPoolToks;
        uint256 grossUSDC    = poolUSDC > newPoolUSDC ? poolUSDC - newPoolUSDC : 0;
        if (grossUSDC > tc.raisedUSDC) return (0, 0);
        uint256 totalFee    = platformFee;
        feeUSDC = totalFee == 0 ? 0 : (grossUSDC * totalFee + BPS_DENOM - 1) / BPS_DENOM;
        usdcOut = grossUSDC - feeUSDC;
    }

    function getSpotPrice(address token_) external view returns (uint256 price) {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        uint256 poolUSDC    = tc.virtualUSDC + tc.raisedUSDC;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        if (poolTokens == 0) return type(uint256).max;
        // poolUSDC is 6-decimal native USDC here (unlike the BSC contract's 18-decimal native token),
        // so an extra USD_TO_NATIVE_SHIFT factor is needed to keep this normalized to the same
        // 18-decimal-fixed-point "USD per token" convention callers already expect.
        price = (poolUSDC * 1e18 * USD_TO_NATIVE_SHIFT) / poolTokens;
    }

    // Off-chain quoting helper: what would virtualUSDC/migrationTarget resolve to right
    // now for given $ targets and allocation — pure decimal-shift conversion on Arc, no
    // live price read needed since native == USDC already.
    function previewUSDCTargets(
        uint256 startMarketCapUSD, uint256 migrationMarketCapUSD,
        uint256 supply, uint256 curveBps, uint256 liquidityBps
    ) external view returns (uint256 virtualUSDC, uint256 migrationTarget) {
        Alloc memory a = _computeAlloc(supply, curveBps, liquidityBps);
        (virtualUSDC, migrationTarget) = _computeUSDCTargets(
            startMarketCapUSD, migrationMarketCapUSD, a.bcTokens, a.liqTokens, a.supply
        );
    }

    function getToken(address token_) external view returns (TokenConfig memory) {
        return tokens[token_];
    }

    function totalTokensLaunched() external view returns (uint256) { return allTokens.length; }

    function getTokensByCreator(address creator_) external view returns (address[] memory) {
        return _tokensByCreator[creator_];
    }

    function tokenCountByCreator(address creator_) external view returns (uint256) {
        return _tokensByCreator[creator_].length;
    }

    function getAntibotBlocksRange() external pure returns (uint256 min, uint256 max) {
        return (ANTIBOT_MIN_BLOCKS, ANTIBOT_MAX_BLOCKS);
    }

    function predictTokenAddress(address creator_, bytes32 userSalt_, address impl_)
        external view
        returns (address predicted)
    {
        bytes32 salt = keccak256(abi.encode(creator_, userSalt_));
        bytes32 initcodeHash;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,         0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl_))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            initcodeHash := keccak256(ptr, 0x37)
        }
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            initcodeHash
        )))));
    }

    receive() external payable {}
}
