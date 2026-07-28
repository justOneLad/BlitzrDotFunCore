// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlitzrSwapRouter} from "../BlitzrSwapRouter/BlitzrSwapRouter.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";
import {RewardsLib} from "../BlitzrSwapRouter/libraries/RewardsLib.sol";

interface IWETH9ForkMU {
    function deposit() external payable;
}

interface IERC20ForkMU {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IUniswapV2RouterForkMU {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        returns (uint256[] memory amounts);
}

interface ISwapRouter02ForkMU {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IUniswapV3FactoryForkMU {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3PoolMinimalForkMU {
    function liquidity() external view returns (uint128);
}

// Multi-user, multi-pool, multi-direction mainnet-fork scenario for BlitzrSwapRouter — where
// BlitzrSwapRouterFork.t.sol proves each venue works in isolation with a single trader always
// buying the same direction, this proves the shared router/vault instance behaves correctly under
// several INDEPENDENT wallets trading DIFFERENT pools in DIFFERENT directions (including two
// wallets hitting the exact same pool back-to-back), with per-user referral state never leaking
// across users. Run with `FOUNDRY_PROFILE=fork forge test`.
contract BlitzrSwapRouterMultiUserForkTest is Test {
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNISWAP_V3_SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    uint24[5] FEE_TIERS = [uint24(100), 500, 2500, 3000, 10_000];

    BlitzrSwapRouter router;
    BlitzrSwapRouterRewardVault vault;
    address owner = address(this);

    // Five independent wallets, each starting from a different token, each paired with its own
    // referrer — the whole point is proving these don't interfere with one another.
    address alice = makeAddr("muAlice"); // WETH -> USDC, Uniswap V3
    address bob = makeAddr("muBob"); // USDC -> WETH, Uniswap V3 (reverse direction, same pool as alice)
    address carol = makeAddr("muCarol"); // DAI -> WETH, Uniswap V2 (different DEX, reverse direction)
    address dave = makeAddr("muDave"); // WETH -> WBTC, Uniswap V3 (different pool)
    address eve = makeAddr("muEve"); // WETH -> USDC, Uniswap V3 (SAME pool/direction as alice, second user)

    address refAlice = makeAddr("muRefAlice");
    address refBob = makeAddr("muRefBob");
    address refCarol = makeAddr("muRefCarol");
    address refDave = makeAddr("muRefDave");
    address refEve = makeAddr("muRefEve");

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpc); // latest — see BlitzrLauncherFork.t.sol for why not pinned

        vault = new BlitzrSwapRouterRewardVault(owner, address(0));
        BlitzrSwapRouter impl = new BlitzrSwapRouter();
        bytes memory initData =
            abi.encodeWithSelector(BlitzrSwapRouter.initialize.selector, owner, address(vault), address(0xdead));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = BlitzrSwapRouter(payable(address(proxy)));
        vault.setRouter(address(router));

        router.setAllowedTarget(UNISWAP_V2_ROUTER, true);
        router.setAllowedTarget(UNISWAP_V3_SWAP_ROUTER, true);

        // Real reward funding + a modest, always-on aggregation fee — every user's swap below
        // settles a referral, so this exercises reward payout independently per-wallet too.
        RewardsLib.RewardToken[] memory rewardTokens = new RewardsLib.RewardToken[](2);
        rewardTokens[0] = RewardsLib.RewardToken({token: DAI, weightBps: 6_000});
        rewardTokens[1] = RewardsLib.RewardToken({token: UNI, weightBps: 4_000});
        router.setRewardTokens(rewardTokens);
        router.setFeeBps(1_000, 500);
        // _noValuation() is used for every swap below (this test's focus is multi-wallet/
        // multi-pool routing correctness, not oracle valuation — already covered separately in
        // BlitzrSwapRouterFork.t.sol's reward test), so a nonzero flat fallback is needed for
        // the reward payouts asserted below to be nonzero at all.
        router.setFlatFallbackValue(1000e18);
        deal(DAI, address(vault), 1_000e18);
        deal(UNI, address(vault), 1_000e18);

        // Fund each wallet from a DIFFERENT starting token — deal() for the ERC20 starters (no
        // need to route a real swap just to stock a test wallet), real WETH deposit for the
        // native starters.
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        IWETH9ForkMU(WETH).deposit{value: 5 ether}();

        vm.deal(dave, 10 ether);
        vm.prank(dave);
        IWETH9ForkMU(WETH).deposit{value: 5 ether}();

        vm.deal(eve, 10 ether);
        vm.prank(eve);
        IWETH9ForkMU(WETH).deposit{value: 5 ether}();

        deal(USDC, bob, 10_000e6);
        deal(DAI, carol, 10_000e18);

        address[5] memory wallets = [alice, bob, carol, dave, eve];
        for (uint256 i; i < wallets.length; ++i) {
            vm.startPrank(wallets[i]);
            IERC20ForkMU(WETH).approve(address(router), type(uint256).max);
            IERC20ForkMU(USDC).approve(address(router), type(uint256).max);
            IERC20ForkMU(DAI).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _noValuation() private pure returns (BlitzrSwapRouter.Valuation memory) {
        return BlitzrSwapRouter.Valuation({kind: BlitzrSwapRouter.ValuationType.NONE, pool: address(0), window: 0});
    }

    function _v2Hop(address v2Router, address tokenIn, address tokenOut, uint256 amountIn)
        private
        view
        returns (BlitzrSwapRouter.Hop memory)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return BlitzrSwapRouter.Hop({
            dexType: BlitzrSwapRouter.HopType.STANDARD,
            target: v2Router,
            data: abi.encodeWithSelector(
                IUniswapV2RouterForkMU.swapExactTokensForTokens.selector,
                amountIn,
                uint256(0),
                path,
                address(router),
                block.timestamp + 1 hours
            ),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: 0
        });
    }

    function _v3Hop(address swapRouter, address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        private
        view
        returns (BlitzrSwapRouter.Hop memory)
    {
        return BlitzrSwapRouter.Hop({
            dexType: BlitzrSwapRouter.HopType.STANDARD,
            target: swapRouter,
            data: abi.encodeWithSelector(
                ISwapRouter02ForkMU.exactInputSingle.selector,
                ISwapRouter02ForkMU.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(router),
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: 0
        });
    }

    function _findV3Pool(address factory, address tokenA, address tokenB) private view returns (address pool, uint24 fee) {
        for (uint256 i; i < FEE_TIERS.length; ++i) {
            address p = IUniswapV3FactoryForkMU(factory).getPool(tokenA, tokenB, FEE_TIERS[i]);
            if (p != address(0) && p.code.length > 0 && IUniswapV3PoolMinimalForkMU(p).liquidity() > 0) {
                return (p, FEE_TIERS[i]);
            }
        }
        return (address(0), 0);
    }

    function _swap(address wallet, BlitzrSwapRouter.Hop memory hop, address referrer) private returns (uint256 out) {
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = hop;
        vm.prank(wallet);
        out = router.swap(hops, 0, referrer, _noValuation());
    }

    function test_fork_fiveWallets_fivePoolsAndDirections_noCrossContamination() public {
        (, uint24 wethUsdcFee) = _findV3Pool(UNISWAP_V3_FACTORY, WETH, USDC);
        (, uint24 wethWbtcFee) = _findV3Pool(UNISWAP_V3_FACTORY, WETH, WBTC);
        assertTrue(wethUsdcFee != 0, "Uniswap V3 WETH/USDC must exist");
        assertTrue(wethWbtcFee != 0, "Uniswap V3 WETH/WBTC must exist");

        uint256 aliceWethBefore = IERC20ForkMU(WETH).balanceOf(alice);
        uint256 bobUsdcBefore = IERC20ForkMU(USDC).balanceOf(bob);
        uint256 carolDaiBefore = IERC20ForkMU(DAI).balanceOf(carol);
        uint256 daveWethBefore = IERC20ForkMU(WETH).balanceOf(dave);
        uint256 eveWethBefore = IERC20ForkMU(WETH).balanceOf(eve);

        // --- alice: WETH -> USDC, Uniswap V3 ---
        uint256 aliceOut = _swap(alice, _v3Hop(UNISWAP_V3_SWAP_ROUTER, WETH, USDC, wethUsdcFee, 1 ether), refAlice);

        // --- bob: USDC -> WETH, Uniswap V3, SAME pool as alice but REVERSE direction ---
        uint256 bobOut = _swap(bob, _v3Hop(UNISWAP_V3_SWAP_ROUTER, USDC, WETH, wethUsdcFee, 1_000e6), refBob);

        // --- carol: DAI -> WETH, Uniswap V2 — different DEX AND reverse direction ---
        uint256 carolOut = _swap(carol, _v2Hop(UNISWAP_V2_ROUTER, DAI, WETH, 1_000e18), refCarol);

        // --- dave: WETH -> WBTC, Uniswap V3, a THIRD distinct pool ---
        uint256 daveOut = _swap(dave, _v3Hop(UNISWAP_V3_SWAP_ROUTER, WETH, WBTC, wethWbtcFee, 1 ether), refDave);

        // --- eve: WETH -> USDC, Uniswap V3 — SAME pool AND SAME direction as alice, second user ---
        uint256 eveOut = _swap(eve, _v3Hop(UNISWAP_V3_SWAP_ROUTER, WETH, USDC, wethUsdcFee, 1 ether), refEve);

        // Every trade actually executed and landed with the RIGHT wallet, not some other one.
        assertGt(aliceOut, 0);
        assertGt(bobOut, 0);
        assertGt(carolOut, 0);
        assertGt(daveOut, 0);
        assertGt(eveOut, 0);

        assertEq(IERC20ForkMU(USDC).balanceOf(alice), aliceOut);
        assertEq(IERC20ForkMU(WETH).balanceOf(bob), bobOut);
        assertEq(IERC20ForkMU(WETH).balanceOf(carol), carolOut);
        assertEq(IERC20ForkMU(WBTC).balanceOf(dave), daveOut);
        assertEq(IERC20ForkMU(USDC).balanceOf(eve), eveOut);

        // Each wallet's OWN input balance dropped by exactly what IT spent — no wallet accidentally
        // paid for, or received, another wallet's leg. Carol is the one exception: her own trade
        // is denominated in DAI, which is ALSO one of the two configured reward tokens, so her
        // own cashback (paid in DAI, to the swapper) lands right back in the same balance —
        // that's expected reward behavior, not cross-contamination, so it's accounted for
        // explicitly rather than silently changing what this assertion checks.
        uint256 aggregationFee = router.flatFallbackValue() * router.aggregationFeeBps() / 10_000;
        uint256 carolDaiCashback = aggregationFee * router.cashbackBps() / 10_000 * 6_000 / 10_000;
        assertEq(IERC20ForkMU(WETH).balanceOf(alice), aliceWethBefore - 1 ether);
        assertEq(IERC20ForkMU(USDC).balanceOf(bob), bobUsdcBefore - 1_000e6);
        assertEq(IERC20ForkMU(DAI).balanceOf(carol), carolDaiBefore - 1_000e18 + carolDaiCashback);
        assertEq(IERC20ForkMU(WETH).balanceOf(dave), daveWethBefore - 1 ether);
        assertEq(IERC20ForkMU(WETH).balanceOf(eve), eveWethBefore - 1 ether);

        // Router itself never accumulates a stray balance between independent users' swaps.
        assertEq(IERC20ForkMU(WETH).balanceOf(address(router)), 0);
        assertEq(IERC20ForkMU(USDC).balanceOf(address(router)), 0);
        assertEq(IERC20ForkMU(DAI).balanceOf(address(router)), 0);
        assertEq(IERC20ForkMU(WBTC).balanceOf(address(router)), 0);

        // Per-user referral binding — each wallet's own referrer, never mixed up with another's.
        assertEq(router.referrerOf(alice), refAlice);
        assertEq(router.referrerOf(bob), refBob);
        assertEq(router.referrerOf(carol), refCarol);
        assertEq(router.referrerOf(dave), refDave);
        assertEq(router.referrerOf(eve), refEve);

        // Reward payout happened independently per user too — five distinct referrers, all paid.
        assertGt(IERC20ForkMU(DAI).balanceOf(refAlice), 0);
        assertGt(IERC20ForkMU(DAI).balanceOf(refBob), 0);
        assertGt(IERC20ForkMU(DAI).balanceOf(refCarol), 0);
        assertGt(IERC20ForkMU(DAI).balanceOf(refDave), 0);
        assertGt(IERC20ForkMU(DAI).balanceOf(refEve), 0);
    }

    // A second swap from an ALREADY-bound wallet, through a totally different pool/direction,
    // with a DIFFERENT referrer offered — first-touch binding must hold regardless of how many
    // other wallets/pools/directions have been used in between.
    function test_fork_referralBinding_staysFirstTouchAcrossDifferentPoolsAndOtherUsersActivity() public {
        (, uint24 wethUsdcFee) = _findV3Pool(UNISWAP_V3_FACTORY, WETH, USDC);
        (, uint24 wethWbtcFee) = _findV3Pool(UNISWAP_V3_FACTORY, WETH, WBTC);

        _swap(alice, _v3Hop(UNISWAP_V3_SWAP_ROUTER, WETH, USDC, wethUsdcFee, 0.5 ether), refAlice);
        assertEq(router.referrerOf(alice), refAlice);

        // Unrelated activity from three other wallets in between.
        _swap(bob, _v3Hop(UNISWAP_V3_SWAP_ROUTER, USDC, WETH, wethUsdcFee, 500e6), refBob);
        _swap(carol, _v2Hop(UNISWAP_V2_ROUTER, DAI, WETH, 500e18), refCarol);
        _swap(dave, _v3Hop(UNISWAP_V3_SWAP_ROUTER, WETH, WBTC, wethWbtcFee, 0.5 ether), refDave);

        // Alice trades again, through a DIFFERENT pool (WETH->WBTC instead of WETH->USDC), naming
        // a different referrer — binding must not move.
        address attemptedNewReferrer = makeAddr("muAttemptedNewReferrer");
        _swap(alice, _v3Hop(UNISWAP_V3_SWAP_ROUTER, WETH, WBTC, wethWbtcFee, 0.2 ether), attemptedNewReferrer);

        assertEq(router.referrerOf(alice), refAlice); // unchanged — first touch still wins
    }
}
