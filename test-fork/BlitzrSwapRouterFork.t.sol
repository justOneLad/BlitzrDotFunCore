// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlitzrSwapRouter} from "../BlitzrSwapRouter/BlitzrSwapRouter.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";
import {RewardsLib} from "../BlitzrSwapRouter/libraries/RewardsLib.sol";

interface IWETH9ForkR {
    function deposit() external payable;
}

interface IERC20ForkR {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IUniswapV2RouterForkR {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface ISwapRouter02ForkR {
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

interface IUniswapV3FactoryForkR {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3PoolMinimalForkR {
    function liquidity() external view returns (uint128);
}

// STANDARD-hop mainnet-fork integration tests for BlitzrSwapRouter — real Uniswap V2, real
// Uniswap V3, and real PancakeSwap V2/V3 deployments on Ethereum mainnet, across several tokens
// pulled from Uniswap's own default token list (https://tokens.uniswap.org): WETH, USDC, USDT,
// DAI, WBTC. Addresses below were cross-checked against Etherscan/the token list directly rather
// than taken from memory (a prior Permit2-address typo in this repo cost a checksum digit — same
// discipline applies here). V4-hop coverage against the real PoolManager lives in the separate
// BlitzrSwapRouterV4Fork.t.sol (it needs its own launched pool, unlike these pre-existing pairs).
// Run with `FOUNDRY_PROFILE=fork forge test`.
contract BlitzrSwapRouterForkTest is Test {
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNISWAP_V3_SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant PANCAKE_V2_ROUTER = 0xEfF92A263d31888d860bD50809A8D171709b7b1c;
    address constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PANCAKE_V3_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    // Covers both Uniswap V3's standard tiers (100/500/3000/10000) and PancakeSwap V3's
    // (100/500/2500/10000) in one probe list, since which tier actually has a live/liquid pool
    // for a given pair is live external state, not something to hardcode and hope stays true.
    uint24[5] FEE_TIERS = [uint24(100), 500, 2500, 3000, 10_000];

    BlitzrSwapRouter router;
    BlitzrSwapRouterRewardVault vault;

    address owner = address(this);
    address trader = makeAddr("forkSwapTrader");

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
        router.setAllowedTarget(PANCAKE_V2_ROUTER, true);
        router.setAllowedTarget(PANCAKE_V3_SMART_ROUTER, true);

        vm.deal(trader, 100 ether);
        vm.startPrank(trader);
        IWETH9ForkR(WETH).deposit{value: 50 ether}();
        IERC20ForkR(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();
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
                IUniswapV2RouterForkR.swapExactTokensForTokens.selector,
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
                ISwapRouter02ForkR.exactInputSingle.selector,
                ISwapRouter02ForkR.ExactInputSingleParams({
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

    // Live-state discovery, not a hardcoded guess — probes every known fee tier on the given
    // factory and returns the first pool that actually exists and actually has liquidity right
    // now. Returns (address(0), 0) if none found, which callers treat as "skip this pair".
    function _findV3Pool(address factory, address tokenA, address tokenB) private view returns (address pool, uint24 fee) {
        for (uint256 i; i < FEE_TIERS.length; ++i) {
            address p = IUniswapV3FactoryForkR(factory).getPool(tokenA, tokenB, FEE_TIERS[i]);
            if (p != address(0) && p.code.length > 0 && IUniswapV3PoolMinimalForkR(p).liquidity() > 0) {
                return (p, FEE_TIERS[i]);
            }
        }
        return (address(0), 0);
    }

    function _v2PoolExists(address v2Router, address tokenIn, address tokenOut, uint256 amountIn) private view returns (bool) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        try IUniswapV2RouterForkR(v2Router).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            return amounts[1] > 0;
        } catch {
            return false;
        }
    }

    // --- Uniswap V2, across several real tokens from the Uniswap default token list ---

    function test_fork_uniswapV2_wethToTokenList() public {
        address[4] memory tokens = [USDC, USDT, DAI, WBTC];
        uint256 amountIn = 1 ether;

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
            hops[0] = _v2Hop(UNISWAP_V2_ROUTER, WETH, token, amountIn);

            vm.prank(trader);
            uint256 out = router.swap(hops, 0, address(0), _noValuation());

            assertGt(out, 0);
            assertEq(IERC20ForkR(token).balanceOf(trader), out);
        }
    }

    // --- Uniswap V3, across the same token list, fee tier discovered live per pair ---

    function test_fork_uniswapV3_wethToTokenList() public {
        address[4] memory tokens = [USDC, USDT, DAI, WBTC];
        uint256 amountIn = 1 ether;

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            (address pool, uint24 fee) = _findV3Pool(UNISWAP_V3_FACTORY, WETH, token);
            if (pool == address(0)) {
                console.log("skipping Uniswap V3 pair - no liquid pool found for token:", token);
                continue;
            }

            BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
            hops[0] = _v3Hop(UNISWAP_V3_SWAP_ROUTER, WETH, token, fee, amountIn);

            vm.prank(trader);
            uint256 out = router.swap(hops, 0, address(0), _noValuation());

            assertGt(out, 0);
            assertEq(IERC20ForkR(token).balanceOf(trader), out);
        }
    }

    // --- PancakeSwap V2 — guarded: Pancake's V2 deployment on Ethereum mainnet (as opposed to
    // BSC, where it's dominant) may or may not have live liquidity for a given pair at any given
    // fork block; this discovers that live, and skips rather than asserting on state this test
    // doesn't control. ---

    function test_fork_pancakeV2_wethToUsdc() public {
        uint256 amountIn = 1 ether;
        if (!_v2PoolExists(PANCAKE_V2_ROUTER, WETH, USDC, amountIn)) {
            console.log("skipping PancakeSwap V2 WETH/USDC - no live route found at this fork block");
            return;
        }

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _v2Hop(PANCAKE_V2_ROUTER, WETH, USDC, amountIn);

        vm.prank(trader);
        uint256 out = router.swap(hops, 0, address(0), _noValuation());

        assertGt(out, 0);
        assertEq(IERC20ForkR(USDC).balanceOf(trader), out);
    }

    // --- PancakeSwap V3 — same live-discovery guard as above. ---

    function test_fork_pancakeV3_wethToUsdc() public {
        uint256 amountIn = 1 ether;
        (address pool, uint24 fee) = _findV3Pool(PANCAKE_V3_FACTORY, WETH, USDC);
        if (pool == address(0)) {
            console.log("skipping PancakeSwap V3 WETH/USDC - no liquid pool found at this fork block");
            return;
        }

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _v3Hop(PANCAKE_V3_SMART_ROUTER, WETH, USDC, fee, amountIn);

        vm.prank(trader);
        uint256 out = router.swap(hops, 0, address(0), _noValuation());

        assertGt(out, 0);
        assertEq(IERC20ForkR(USDC).balanceOf(trader), out);
    }

    // --- Flagship: true cross-DEX aggregation — one swapSplit() call routing part of the trade
    // through real Uniswap V3 and part through real PancakeSwap V3 simultaneously, summing their
    // outputs. Skips if PancakeSwap has no live WETH/USDC liquidity right now (see above). ---

    function test_fork_swapSplit_uniswapV3AndPancakeV3_wethToUsdc() public {
        (address uniPool, uint24 uniFee) = _findV3Pool(UNISWAP_V3_FACTORY, WETH, USDC);
        (address cakePool, uint24 cakeFee) = _findV3Pool(PANCAKE_V3_FACTORY, WETH, USDC);
        assertTrue(uniPool != address(0), "Uniswap V3 WETH/USDC must exist - this pair is one of the deepest in DeFi");
        if (cakePool == address(0)) {
            console.log("skipping split test - no live PancakeSwap V3 WETH/USDC liquidity at this fork block");
            return;
        }

        BlitzrSwapRouter.Hop[] memory uniHops = new BlitzrSwapRouter.Hop[](1);
        uniHops[0] = _v3Hop(UNISWAP_V3_SWAP_ROUTER, WETH, USDC, uniFee, 0.6 ether);
        BlitzrSwapRouter.Hop[] memory cakeHops = new BlitzrSwapRouter.Hop[](1);
        cakeHops[0] = _v3Hop(PANCAKE_V3_SMART_ROUTER, WETH, USDC, cakeFee, 0.4 ether);

        BlitzrSwapRouter.Route[] memory routes = new BlitzrSwapRouter.Route[](2);
        routes[0] = BlitzrSwapRouter.Route({hops: uniHops});
        routes[1] = BlitzrSwapRouter.Route({hops: cakeHops});

        vm.prank(trader);
        uint256 out = router.swapSplit(routes, 0, address(0), _noValuation());

        assertGt(out, 0);
        assertEq(IERC20ForkR(USDC).balanceOf(trader), out);
    }

    // --- Reward confirmation: real ERC20 reward tokens, real bps, real oracle-derived valuation
    // (V3 TWAP against the real WETH/USDC pool) — every other fork test above deliberately used
    // referrer=address(0) and ValuationType.NONE to isolate "does routing work" from reward
    // mechanics. This is the counterpart: proves referral + cashback actually pay out, split
    // across two real reward tokens (DAI, UNI) by weight, against a real trade's real value. ---

    function test_fork_referralAndCashback_payOutRealErc20sWeightedByRealValue() public {
        address referrer = makeAddr("forkRewardReferrer");

        // Two independent reward tokens split 60/40 — proves multi-token reward weighting isn't
        // just a mocked unit-test artifact, it works with genuine ERC20s on a live fork.
        RewardsLib.RewardToken[] memory rewardTokens = new RewardsLib.RewardToken[](2);
        rewardTokens[0] = RewardsLib.RewardToken({token: DAI, weightBps: 6_000});
        rewardTokens[1] = RewardsLib.RewardToken({token: UNI, weightBps: 4_000});
        router.setRewardTokens(rewardTokens);
        router.setFeeBps(1_000, 500); // 10% referral, 5% cashback

        // deal() writes the balance directly via storage — real DAI/UNI, no need to route a real
        // swap just to stock the vault.
        deal(DAI, address(vault), 1_000e18);
        deal(UNI, address(vault), 1_000e18);

        (address uniPool, uint24 fee) = _findV3Pool(UNISWAP_V3_FACTORY, WETH, USDC);
        assertTrue(uniPool != address(0), "Uniswap V3 WETH/USDC must exist - this pair is one of the deepest in DeFi");
        BlitzrSwapRouter.Valuation memory realValuation =
            BlitzrSwapRouter.Valuation({kind: BlitzrSwapRouter.ValuationType.V3, pool: uniPool, window: 1800});

        uint256 amountIn = 1 ether;
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _v3Hop(UNISWAP_V3_SWAP_ROUTER, WETH, USDC, fee, amountIn);

        vm.prank(trader);
        uint256 out = router.swap(hops, 0, referrer, realValuation);
        assertGt(out, 0);

        // First-touch referral binding actually happened.
        assertEq(router.referrerOf(trader), referrer);

        // Both reward legs fired, both reward tokens paid out, weighted 60/40 as configured.
        uint256 referrerDai = IERC20ForkR(DAI).balanceOf(referrer);
        uint256 referrerUni = IERC20ForkR(UNI).balanceOf(referrer);
        uint256 traderDai = IERC20ForkR(DAI).balanceOf(trader);
        uint256 traderUni = IERC20ForkR(UNI).balanceOf(trader);

        assertGt(referrerDai, 0);
        assertGt(referrerUni, 0);
        assertGt(traderDai, 0);
        assertGt(traderUni, 0);

        // 60/40 weighting held for both the referral leg and the cashback leg independently.
        assertApproxEqRel(referrerDai, referrerUni * 6_000 / 4_000, 0.01e18);
        assertApproxEqRel(traderDai, traderUni * 6_000 / 4_000, 0.01e18);

        // Referral (10%) outweighs cashback (5%) on both reward tokens, matching the configured bps.
        assertGt(referrerDai, traderDai);
        assertGt(referrerUni, traderUni);
    }
}
