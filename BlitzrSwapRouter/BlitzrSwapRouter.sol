// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// Transient-storage (EIP-1153) reentrancy guard — `@custom:stateless`, no persistent storage, so
// no separate "Upgradeable" variant exists (or is needed) for it: nothing to initialize, nothing
// that could ever collide with this contract's own ERC-7201 storage on an upgrade.
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {OracleLib} from "./libraries/OracleLib.sol";
import {ReferralLib} from "./libraries/ReferralLib.sol";
import {RewardsLib} from "./libraries/RewardsLib.sol";
import {CashbackLib} from "./libraries/CashbackLib.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";

// Local copies of Uniswap V4's shapes rather than importing v4-core — ABI-compatibility with the
// real PoolManager is structural, not nominal (see xBlitzr/XBlitzrLauncher.sol).
type Currency is address;
type BalanceDelta is int256;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24   fee;
    int24    tickSpacing;
    address  hooks;
}

struct SwapParams {
    bool    zeroForOne;
    int256  amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerMinimal {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (BalanceDelta swapDelta);
    function take(Currency currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256 paid);
    function sync(Currency currency) external;
}

// Blitzr — https://blitzr.fun
//
// Executes an OFF-CHAIN-COMPUTED swap route: no on-chain pathfinding or price comparison. A route
// is an ordered list of hops — STANDARD (an owner-allowlisted target + pre-built calldata, plain
// `call`, never `delegatecall`; slippage enforced via balance-delta, not trusting the target's
// return value) or V4 (this contract implements `unlockCallback` itself, since V4's
// flash-accounting model requires the caller of `PoolManager.unlock()` to receive the callback
// directly). Referral/cashback settle exactly ONCE per call, sized off a two-stage value: an
// oracle- or flat-fallback-derived `value`, scaled by aggregationFeeBps into an `aggregationFee`
// that referralBps/cashbackBps then cut a share of. Payouts are pulled from a separate,
// non-upgradeable BlitzrSwapRouterRewardVault.
contract BlitzrSwapRouter is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardTransient {

    error EmptyRoute();
    error InvalidNativeAmount();
    error UnexpectedNativeValue();
    error TokenMismatch();
    error AmountMismatch();
    error InsufficientOutput();
    error TargetNotAllowed();
    error HopCallFailed();
    error NotPoolManager();
    error ZeroAddress();
    error InvalidBps();
    error Permit2NotSet();

    enum HopType { STANDARD, V4 }
    enum ValuationType { NONE, V2, V3 }

    struct Hop {
        HopType dexType;
        address target;       // STANDARD only — owner-allowlisted contract to call; ignored for V4 (always $.poolManager)
        bytes   data;          // STANDARD: pre-built calldata. V4: abi.encode(PoolKey, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    // Decoupled from the execution hops — always measured against the overall route's own
    // input token/amount, never a separately-claimed amount.
    struct Valuation {
        ValuationType kind;
        address pool; // V2 pair or V3 pool address; ignored if kind == NONE
        uint32  window; // V3 TWAP window in seconds; ignored for V2/NONE
    }

    // One parallel path within a split route — swapSplit() takes several, all sharing the same
    // overall input/output token, whose outputs are summed.
    struct Route {
        Hop[] hops;
    }

    /// @custom:storage-location erc7201:blitzr.storage.BlitzrSwapRouter
    struct RouterStorage {
        address rewardVault;
        address poolManager;
        uint256 referralBps;
        uint256 cashbackBps;
        uint256 flatFallbackValue;
        uint256 v2MinElapsed;
        uint256 aggregationFeeBps;
        address permit2;
        RewardsLib.RewardToken[] rewardTokens;
        mapping(address => bool) allowedTargets;
        mapping(address => address) referrerOf;
        mapping(address => OracleLib.V2Observation) v2Observations;
    }

    // keccak256(abi.encode(uint256(keccak256("blitzr.storage.BlitzrSwapRouter")) - 1)) & ~bytes32(uint256(0xff))
    // ERC-7201 namespaced storage (OZ v5) rather than a trailing __gap array.
    bytes32 private constant ROUTER_STORAGE_LOCATION =
        0x46fa41d4049a7719bca04b00fbf56e0b7bbfa947aa9983ebeb732139a8ae9300;

    function _getRouterStorage() private pure returns (RouterStorage storage $) {
        assembly {
            $.slot := ROUTER_STORAGE_LOCATION
        }
    }

    // Uniswap Permit2's canonical singleton — same address on essentially every EVM chain.
    // Seeded as the default in initialize(), owner-overridable via setPermit2.
    address private constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    event RewardVaultSet(address indexed vault);
    event RewardTokensSet(uint256 count);
    event PoolManagerSet(address indexed poolManager);
    event FeeBpsSet(uint256 referralBps, uint256 cashbackBps);
    event AggregationFeeBpsSet(uint256 aggregationFeeBps);
    event FlatFallbackValueSet(uint256 value);
    event V2MinElapsedSet(uint256 minElapsed);
    event Permit2Set(address indexed permit2);
    event AllowedTargetSet(address indexed target, bool allowed);
    event SwapExecuted(
        address indexed swapper,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address referrer
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address rewardVault_, address poolManager_)
        external
        initializer
    {
        __Ownable_init(owner_);
        // UUPSUpgradeable and ReentrancyGuardTransient both need no init call — neither holds
        // persistent storage of its own.

        RouterStorage storage $ = _getRouterStorage();
        $.rewardVault = rewardVault_;
        $.poolManager = poolManager_;
        $.referralBps = 0;
        $.cashbackBps = 0;
        $.v2MinElapsed = 1800; // 30 min default, owner-adjustable
        $.aggregationFeeBps = 30; // 0.3%, owner-adjustable
        $.permit2 = CANONICAL_PERMIT2;
        // reward tokens start empty — owner configures via setRewardTokens post-deploy.
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // --- admin ---

    function setRewardVault(address vault_) external onlyOwner {
        _getRouterStorage().rewardVault = vault_;
        emit RewardVaultSet(vault_);
    }

    // Each entry's weightBps is a share of the total payout, so weights sum to <= BPS — not
    // independently bounded like referralBps/cashbackBps (one pie split N ways, not N cuts).
    function setRewardTokens(RewardsLib.RewardToken[] calldata tokens_) external onlyOwner {
        uint256 totalWeight;
        uint256 len = tokens_.length;
        for (uint256 i; i < len; ++i) {
            if (tokens_[i].token == address(0)) revert ZeroAddress();
            totalWeight += tokens_[i].weightBps;
        }
        if (totalWeight > 10_000) revert InvalidBps();

        _getRouterStorage().rewardTokens = tokens_;
        emit RewardTokensSet(len);
    }

    function setPoolManager(address poolManager_) external onlyOwner {
        _getRouterStorage().poolManager = poolManager_;
        emit PoolManagerSet(poolManager_);
    }

    // Independent bps cuts of the swap's AGGREGATION FEE, not its raw value — see
    // aggregationFeeBps below. Not a 100%-split pair; both bounded at <= BPS individually.
    function setFeeBps(uint256 referralBps_, uint256 cashbackBps_) external onlyOwner {
        if (referralBps_ > 10_000 || cashbackBps_ > 10_000) revert InvalidBps();
        RouterStorage storage $ = _getRouterStorage();
        $.referralBps = referralBps_;
        $.cashbackBps = cashbackBps_;
        emit FeeBpsSet(referralBps_, cashbackBps_);
    }

    // This router's own protocol fee, as a fraction of a swap's resolved value — enforced on
    // every swap. referralBps/cashbackBps then cut a share OF this fee, not the raw value:
    // giving away 10% of a trade's entire value would be unsustainable, but 10% of a 0.3% take
    // is the standard model real aggregators use.
    function setAggregationFeeBps(uint256 aggregationFeeBps_) external onlyOwner {
        if (aggregationFeeBps_ > 10_000) revert InvalidBps();
        _getRouterStorage().aggregationFeeBps = aggregationFeeBps_;
        emit AggregationFeeBpsSet(aggregationFeeBps_);
    }

    function setFlatFallbackValue(uint256 value_) external onlyOwner {
        _getRouterStorage().flatFallbackValue = value_;
        emit FlatFallbackValueSet(value_);
    }

    function setV2MinElapsed(uint256 minElapsed_) external onlyOwner {
        _getRouterStorage().v2MinElapsed = minElapsed_;
        emit V2MinElapsedSet(minElapsed_);
    }

    function setPermit2(address permit2_) external onlyOwner {
        _getRouterStorage().permit2 = permit2_;
        emit Permit2Set(permit2_);
    }

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        _getRouterStorage().allowedTargets[target] = allowed;
        emit AllowedTargetSet(target, allowed);
    }

    // Permissionless — refreshing more often only makes v2MinElapsed easier to satisfy, never a
    // way to manipulate the result (you don't control when your update lands).
    function updateV2Observation(address pair) external {
        OracleLib.updateV2Observation(_getRouterStorage().v2Observations, pair);
    }

    // --- views ---

    function rewardVault() external view returns (address) { return _getRouterStorage().rewardVault; }
    function rewardTokens() external view returns (RewardsLib.RewardToken[] memory) { return _getRouterStorage().rewardTokens; }
    function poolManager() external view returns (address) { return _getRouterStorage().poolManager; }
    function referralBps() external view returns (uint256) { return _getRouterStorage().referralBps; }
    function cashbackBps() external view returns (uint256) { return _getRouterStorage().cashbackBps; }
    function aggregationFeeBps() external view returns (uint256) { return _getRouterStorage().aggregationFeeBps; }
    function flatFallbackValue() external view returns (uint256) { return _getRouterStorage().flatFallbackValue; }
    function v2MinElapsed() external view returns (uint256) { return _getRouterStorage().v2MinElapsed; }
    function permit2() external view returns (address) { return _getRouterStorage().permit2; }
    function isAllowedTarget(address target) external view returns (bool) { return _getRouterStorage().allowedTargets[target]; }
    function referrerOf(address swapper) external view returns (address) { return _getRouterStorage().referrerOf[swapper]; }

    // --- swap (single path) ---

    function swap(Hop[] calldata hops, uint256 minFinalAmountOut, address referrer, Valuation calldata valuation)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (hops.length == 0) revert EmptyRoute();
        Hop calldata firstHop = hops[0];
        if (firstHop.tokenIn == address(0)) {
            if (msg.value != firstHop.amountIn) revert InvalidNativeAmount();
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            _pullToken(firstHop.tokenIn, msg.sender, firstHop.amountIn);
        }

        amountOut = _runSinglePath(hops, minFinalAmountOut, referrer, valuation);
    }

    // ERC20-only counterpart to swap() — pulls the input via a Permit2 signature instead of a
    // pre-existing router approval. Native-input routes have no approval step, so they stay on
    // swap().
    function swapWithPermit(
        Hop[] calldata hops,
        uint256 minFinalAmountOut,
        address referrer,
        Valuation calldata valuation,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256 amountOut) {
        if (hops.length == 0) revert EmptyRoute();
        Hop calldata firstHop = hops[0];
        if (firstHop.tokenIn == address(0)) revert InvalidNativeAmount();

        _pullViaPermit2Checked(firstHop.tokenIn, firstHop.amountIn, nonce, deadline, signature);

        amountOut = _runSinglePath(hops, minFinalAmountOut, referrer, valuation);
    }

    function _runSinglePath(
        Hop[] calldata hops,
        uint256 minFinalAmountOut,
        address referrer,
        Valuation calldata valuation
    ) private returns (uint256 amountOut) {
        RouterStorage storage $ = _getRouterStorage();
        Hop calldata firstHop = hops[0];

        (uint256 currentAmount, address currentToken) = _executeHops($, hops);
        if (currentAmount < minFinalAmountOut) revert InsufficientOutput();
        amountOut = currentAmount;

        address boundReferrer = _settleRewards($, referrer, firstHop.tokenIn, firstHop.amountIn, valuation);
        _sendToken(currentToken, msg.sender, amountOut);

        emit SwapExecuted(msg.sender, firstHop.tokenIn, currentToken, firstHop.amountIn, amountOut, boundReferrer);
    }

    // --- swap (split across multiple parallel routes) ---

    function swapSplit(Route[] calldata routes, uint256 minFinalAmountOut, address referrer, Valuation calldata valuation)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        (address tokenIn, address tokenOut, uint256 totalAmountIn) = _validateRoutes(routes);

        if (tokenIn == address(0)) {
            if (msg.value != totalAmountIn) revert InvalidNativeAmount();
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            _pullToken(tokenIn, msg.sender, totalAmountIn);
        }

        amountOut = _runSplitPaths(routes, tokenIn, tokenOut, totalAmountIn, minFinalAmountOut, referrer, valuation);
    }

    function swapSplitWithPermit(
        Route[] calldata routes,
        uint256 minFinalAmountOut,
        address referrer,
        Valuation calldata valuation,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256 amountOut) {
        (address tokenIn, address tokenOut, uint256 totalAmountIn) = _validateRoutes(routes);
        if (tokenIn == address(0)) revert InvalidNativeAmount();

        _pullViaPermit2Checked(tokenIn, totalAmountIn, nonce, deadline, signature);

        amountOut = _runSplitPaths(routes, tokenIn, tokenOut, totalAmountIn, minFinalAmountOut, referrer, valuation);
    }

    // Every route must share the same input/output token — that's what makes summing their
    // outputs into one amountOut meaningful.
    function _validateRoutes(Route[] calldata routes)
        private
        pure
        returns (address tokenIn, address tokenOut, uint256 totalAmountIn)
    {
        if (routes.length == 0) revert EmptyRoute();
        Hop[] calldata firstHops = routes[0].hops;
        if (firstHops.length == 0) revert EmptyRoute();
        tokenIn = firstHops[0].tokenIn;
        tokenOut = firstHops[firstHops.length - 1].tokenOut;

        uint256 len = routes.length;
        for (uint256 i; i < len; ++i) {
            Hop[] calldata hops = routes[i].hops;
            if (hops.length == 0) revert EmptyRoute();
            if (hops[0].tokenIn != tokenIn) revert TokenMismatch();
            if (hops[hops.length - 1].tokenOut != tokenOut) revert TokenMismatch();
            totalAmountIn += hops[0].amountIn;
        }
    }

    function _runSplitPaths(
        Route[] calldata routes,
        address tokenIn,
        address tokenOut,
        uint256 totalAmountIn,
        uint256 minFinalAmountOut,
        address referrer,
        Valuation calldata valuation
    ) private returns (uint256 amountOut) {
        RouterStorage storage $ = _getRouterStorage();

        uint256 totalOut;
        uint256 len = routes.length;
        for (uint256 i; i < len; ++i) {
            (uint256 routeOut,) = _executeHops($, routes[i].hops);
            totalOut += routeOut;
        }

        if (totalOut < minFinalAmountOut) revert InsufficientOutput();
        amountOut = totalOut;

        address boundReferrer = _settleRewards($, referrer, tokenIn, totalAmountIn, valuation);
        _sendToken(tokenOut, msg.sender, amountOut);

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, totalAmountIn, amountOut, boundReferrer);
    }

    // --- shared helpers ---

    function _executeHops(RouterStorage storage $, Hop[] calldata hops)
        private
        returns (uint256 currentAmount, address currentToken)
    {
        currentAmount = hops[0].amountIn;
        currentToken = hops[0].tokenIn;

        uint256 len = hops.length;
        for (uint256 i; i < len; ++i) {
            Hop calldata hop = hops[i];
            if (hop.tokenIn != currentToken) revert TokenMismatch();
            if (hop.amountIn != currentAmount) revert AmountMismatch();

            currentAmount = hop.dexType == HopType.V4 ? _executeV4Hop($, hop) : _executeStandardHop($, hop);
            currentToken = hop.tokenOut;
        }
    }

    // Settles exactly once per call, never per-hop/per-leg, so splitting a trade can't multiply
    // payouts.
    function _settleRewards(
        RouterStorage storage $,
        address referrer,
        address tokenIn,
        uint256 amountIn,
        Valuation calldata valuation
    ) private returns (address boundReferrer) {
        ReferralLib.recordReferral($.referrerOf, msg.sender, referrer);
        boundReferrer = $.referrerOf[msg.sender];
        uint256 value = _resolveValue($, valuation, tokenIn, amountIn);
        uint256 aggregationFee = value * $.aggregationFeeBps / 10_000;
        RewardsLib.payReferralReward($.rewardVault, $.rewardTokens, boundReferrer, msg.sender, aggregationFee, $.referralBps);
        CashbackLib.payCashback($.rewardVault, $.rewardTokens, msg.sender, aggregationFee, $.cashbackBps);
    }

    function _pullViaPermit2Checked(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) private {
        address permit2_ = _getRouterStorage().permit2;
        if (permit2_ == address(0)) revert Permit2NotSet();
        _pullViaPermit2(permit2_, token, amount, nonce, deadline, signature);
    }

    function _pullViaPermit2(
        address permit2_,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) private {
        IPermit2(permit2_).permitTransferFrom(
            IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: token, amount: amount}),
                nonce: nonce,
                deadline: deadline
            }),
            IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
            msg.sender,
            signature
        );
    }

    function _resolveValue(RouterStorage storage $, Valuation calldata valuation, address token, uint256 amountIn)
        private
        view
        returns (uint256)
    {
        if (valuation.kind == ValuationType.V3) {
            return OracleLib.getV3Value(valuation.pool, token, amountIn, valuation.window);
        } else if (valuation.kind == ValuationType.V2) {
            return OracleLib.getV2Value($.v2Observations, valuation.pool, token, amountIn, $.v2MinElapsed);
        }
        return $.flatFallbackValue;
    }

    // --- STANDARD hop execution (V2 / V3 / any other allowlisted DEX) ---

    function _executeStandardHop(RouterStorage storage $, Hop calldata hop) private returns (uint256 received) {
        if (!$.allowedTargets[hop.target]) revert TargetNotAllowed();

        uint256 balanceBefore = _balanceOf(hop.tokenOut);

        if (hop.tokenIn == address(0)) {
            (bool ok,) = hop.target.call{value: hop.amountIn}(hop.data);
            if (!ok) revert HopCallFailed();
        } else {
            _safeApprove(hop.tokenIn, hop.target, hop.amountIn);
            (bool ok,) = hop.target.call(hop.data);
            if (!ok) revert HopCallFailed();
        }

        received = _balanceOf(hop.tokenOut) - balanceBefore;
        if (received < hop.minAmountOut) revert InsufficientOutput();
    }

    // --- V4 hop execution ---

    function _executeV4Hop(RouterStorage storage $, Hop calldata hop) private returns (uint256 amountOut) {
        bytes memory result = IPoolManagerMinimal($.poolManager).unlock(abi.encode(hop));
        amountOut = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        RouterStorage storage $ = _getRouterStorage();
        if (msg.sender != $.poolManager) revert NotPoolManager();

        Hop memory hop = abi.decode(data, (Hop));
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(hop.data, (PoolKey, bool, int256, uint160));

        BalanceDelta delta = IPoolManagerMinimal(msg.sender).swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96}), ""
        );

        int128 amount0 = _amount0(delta);
        int128 amount1 = _amount1(delta);
        bool zeroIsInput = amount0 < 0;
        Currency inputCurrency = zeroIsInput ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroIsInput ? key.currency1 : key.currency0;
        uint256 inputAmount = uint256(uint128(zeroIsInput ? -amount0 : -amount1));
        uint256 outputAmount = uint256(uint128(zeroIsInput ? amount1 : amount0));

        if (Currency.unwrap(inputCurrency) != hop.tokenIn || Currency.unwrap(outputCurrency) != hop.tokenOut) {
            revert TokenMismatch();
        }

        if (Currency.unwrap(inputCurrency) == address(0)) {
            IPoolManagerMinimal(msg.sender).settle{value: inputAmount}();
        } else {
            IPoolManagerMinimal(msg.sender).sync(inputCurrency);
            _sendRaw(Currency.unwrap(inputCurrency), msg.sender, inputAmount);
            IPoolManagerMinimal(msg.sender).settle();
        }
        IPoolManagerMinimal(msg.sender).take(outputCurrency, address(this), outputAmount);

        if (outputAmount < hop.minAmountOut) revert InsufficientOutput();

        return abi.encode(outputAmount);
    }

    function _amount0(BalanceDelta delta) private pure returns (int128) {
        return int128(BalanceDelta.unwrap(delta) >> 128);
    }

    function _amount1(BalanceDelta delta) private pure returns (int128) {
        return int128(BalanceDelta.unwrap(delta));
    }

    // --- token movement helpers (raw-selector, USDT-safe) ---

    function _balanceOf(address token) private view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!ok || data.length < 32) revert HopCallFailed();
        return abi.decode(data, (uint256));
    }

    function _pullToken(address token, address from, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, address(this), amount) // transferFrom(address,address,uint256)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert HopCallFailed();
    }

    function _sendToken(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert HopCallFailed();
        } else {
            _sendRaw(token, to, amount);
        }
    }

    function _sendRaw(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert HopCallFailed();
    }

    // Reset-to-zero-then-set — handles USDT's non-zero→non-zero approval restriction.
    function _safeApprove(address token, address spender, uint256 amount) private {
        (bool reset,) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, 0));
        reset;
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert HopCallFailed();
    }

    receive() external payable {}
}
