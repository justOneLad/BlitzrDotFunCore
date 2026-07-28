// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlitzrSwapRouter, PoolKey, Currency, SwapParams} from "../BlitzrSwapRouter/BlitzrSwapRouter.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManagerV4Router} from "./mocks/MockPoolManagerV4Router.sol";

// V4-hop-specific integration tests — BlitzrSwapRouter.unlockCallback wiring against a real V4
// PoolManager shape. STANDARD-hop coverage (the bulk of the router's surface) lives in
// BlitzrSwapRouter.t.sol.
contract BlitzrSwapRouterV4Test is Test {
    BlitzrSwapRouter router;
    BlitzrSwapRouterRewardVault vault;
    MockPoolManagerV4Router poolManager;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address owner = address(this);
    address alice = makeAddr("alice");

    uint24 constant FEE = 10_000;
    int24 constant TICK_SPACING = 200;

    function setUp() public {
        vault = new BlitzrSwapRouterRewardVault(owner, address(0));
        poolManager = new MockPoolManagerV4Router();

        BlitzrSwapRouter impl = new BlitzrSwapRouter();
        bytes memory initData = abi.encodeWithSelector(
            BlitzrSwapRouter.initialize.selector, owner, address(vault), address(poolManager)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = BlitzrSwapRouter(payable(address(proxy)));
        vault.setRouter(address(router));

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(alice, 1_000e18);
        vm.prank(alice);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _v4Hop(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        private
        pure
        returns (BlitzrSwapRouter.Hop memory)
    {
        bool zeroForOne = tokenIn < tokenOut;
        (address c0, address c1) = zeroForOne ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(0)
        });
        bytes memory data = abi.encode(key, zeroForOne, -int256(amountIn), uint160(0));
        return BlitzrSwapRouter.Hop({
            dexType: BlitzrSwapRouter.HopType.V4,
            target: address(0), // ignored for V4 — router always uses its own stored poolManager
            data: data,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut
        });
    }

    function _noValuation() private pure returns (BlitzrSwapRouter.Valuation memory) {
        return BlitzrSwapRouter.Valuation({kind: BlitzrSwapRouter.ValuationType.NONE, pool: address(0), window: 0});
    }

    function test_swap_v4Hop_erc20ToErc20() public {
        tokenB.mint(address(poolManager), 1000e18);
        poolManager.setNextSwapAmountOut(90e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _v4Hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.prank(alice);
        uint256 out = router.swap(hops, 90e18, address(0), _noValuation());

        assertEq(out, 90e18);
        assertEq(tokenB.balanceOf(alice), 90e18);
        assertEq(tokenA.balanceOf(address(poolManager)), 100e18); // settled to the pool manager
    }

    function test_swap_v4Hop_nativeInput() public {
        vm.deal(alice, 10 ether);
        tokenB.mint(address(poolManager), 1000e18);
        poolManager.setNextSwapAmountOut(90e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _v4Hop(address(0), address(tokenB), 1 ether, 90e18);

        vm.prank(alice);
        uint256 out = router.swap{value: 1 ether}(hops, 90e18, address(0), _noValuation());

        assertEq(out, 90e18);
        assertEq(tokenB.balanceOf(alice), 90e18);
        assertEq(address(poolManager).balance, 1 ether);
    }

    function test_swap_v4Hop_revertsOnSlippage() public {
        tokenB.mint(address(poolManager), 1000e18);
        poolManager.setNextSwapAmountOut(50e18); // less than what we'll demand

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _v4Hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.InsufficientOutput.selector);
        router.swap(hops, 50e18, address(0), _noValuation());
    }

    function test_swap_v4Hop_notGatedByAllowedTargets() public {
        // V4 hops never consult the STANDARD-hop allowedTargets registry — the router always
        // talks to its own configured poolManager regardless of hop.target.
        tokenB.mint(address(poolManager), 1000e18);
        poolManager.setNextSwapAmountOut(90e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _v4Hop(address(tokenA), address(tokenB), 100e18, 90e18);
        assertEq(hops[0].target, address(0)); // deliberately unset/unrelated

        vm.prank(alice);
        uint256 out = router.swap(hops, 90e18, address(0), _noValuation());
        assertEq(out, 90e18);
    }

    function test_unlockCallback_onlyPoolManager() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(0)
        });
        BlitzrSwapRouter.Hop memory hop = BlitzrSwapRouter.Hop({
            dexType: BlitzrSwapRouter.HopType.V4,
            target: address(0),
            data: abi.encode(key, true, -int256(100e18), uint160(0)),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: 100e18,
            minAmountOut: 0
        });

        vm.expectRevert(BlitzrSwapRouter.NotPoolManager.selector);
        router.unlockCallback(abi.encode(hop));
    }
}
