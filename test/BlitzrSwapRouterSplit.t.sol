// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlitzrSwapRouter} from "../BlitzrSwapRouter/BlitzrSwapRouter.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapTarget} from "./mocks/MockSwapTarget.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

// swapSplit()/swapSplitWithPermit() — splitting one logical trade across multiple parallel
// Route legs that share the same overall input/output token, summing their outputs. Single-path
// swap() coverage lives in BlitzrSwapRouter.t.sol.
contract BlitzrSwapRouterSplitTest is Test {
    BlitzrSwapRouter router;
    BlitzrSwapRouterRewardVault vault;
    MockPermit2 permit2;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockSwapTarget target;

    address owner = address(this);
    address alice = makeAddr("alice");

    function setUp() public {
        vault = new BlitzrSwapRouterRewardVault(owner, address(0));
        permit2 = new MockPermit2();

        BlitzrSwapRouter impl = new BlitzrSwapRouter();
        bytes memory initData =
            abi.encodeWithSelector(BlitzrSwapRouter.initialize.selector, owner, address(vault), address(0xdead));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = BlitzrSwapRouter(payable(address(proxy)));
        vault.setRouter(address(router));
        router.setPermit2(address(permit2));

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        target = new MockSwapTarget();
        router.setAllowedTarget(address(target), true);

        tokenA.mint(alice, 1_000e18);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenA.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function _hop(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        private
        view
        returns (BlitzrSwapRouter.Hop memory)
    {
        return BlitzrSwapRouter.Hop({
            dexType: BlitzrSwapRouter.HopType.STANDARD,
            target: address(target),
            data: abi.encodeWithSelector(
                MockSwapTarget.executeSwap.selector, tokenIn, amountIn, tokenOut, amountOut, address(router)
            ),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: amountOut
        });
    }

    function _route(BlitzrSwapRouter.Hop memory hop) private pure returns (BlitzrSwapRouter.Route memory) {
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = hop;
        return BlitzrSwapRouter.Route({hops: hops});
    }

    function _noValuation() private pure returns (BlitzrSwapRouter.Valuation memory) {
        return BlitzrSwapRouter.Valuation({kind: BlitzrSwapRouter.ValuationType.NONE, pool: address(0), window: 0});
    }

    function _twoLegRoutes() private view returns (BlitzrSwapRouter.Route[] memory routes) {
        routes = new BlitzrSwapRouter.Route[](2);
        routes[0] = _route(_hop(address(tokenA), address(tokenB), 60e18, 54e18)); // 90% rate leg
        routes[1] = _route(_hop(address(tokenA), address(tokenB), 40e18, 38e18)); // 95% rate leg
    }

    // --- swapSplit ---

    function test_swapSplit_sumsOutputAcrossRoutes() public {
        tokenB.mint(address(target), 1000e18);

        vm.prank(alice);
        uint256 out = router.swapSplit(_twoLegRoutes(), 92e18, address(0), _noValuation());

        assertEq(out, 92e18); // 54 + 38
        assertEq(tokenB.balanceOf(alice), 92e18);
        assertEq(tokenA.balanceOf(alice), 900e18); // 1000 - 60 - 40
    }

    function test_swapSplit_revertsOnEmptyRoutes() public {
        BlitzrSwapRouter.Route[] memory routes = new BlitzrSwapRouter.Route[](0);
        vm.expectRevert(BlitzrSwapRouter.EmptyRoute.selector);
        router.swapSplit(routes, 0, address(0), _noValuation());
    }

    function test_swapSplit_revertsOnEmptyRouteHops() public {
        BlitzrSwapRouter.Route[] memory routes = new BlitzrSwapRouter.Route[](1);
        routes[0] = BlitzrSwapRouter.Route({hops: new BlitzrSwapRouter.Hop[](0)});
        vm.expectRevert(BlitzrSwapRouter.EmptyRoute.selector);
        router.swapSplit(routes, 0, address(0), _noValuation());
    }

    function test_swapSplit_revertsOnMismatchedTokenInAcrossRoutes() public {
        MockERC20 tokenC = new MockERC20("C", "C", 18);
        tokenC.mint(alice, 100e18);
        vm.prank(alice);
        tokenC.approve(address(router), type(uint256).max);

        BlitzrSwapRouter.Route[] memory routes = new BlitzrSwapRouter.Route[](2);
        routes[0] = _route(_hop(address(tokenA), address(tokenB), 60e18, 54e18));
        routes[1] = _route(_hop(address(tokenC), address(tokenB), 40e18, 38e18)); // different tokenIn

        vm.expectRevert(BlitzrSwapRouter.TokenMismatch.selector);
        router.swapSplit(routes, 0, address(0), _noValuation());
    }

    function test_swapSplit_revertsOnMismatchedTokenOutAcrossRoutes() public {
        MockERC20 tokenC = new MockERC20("C", "C", 18);

        BlitzrSwapRouter.Route[] memory routes = new BlitzrSwapRouter.Route[](2);
        routes[0] = _route(_hop(address(tokenA), address(tokenB), 60e18, 54e18));
        routes[1] = _route(_hop(address(tokenA), address(tokenC), 40e18, 38e18)); // different tokenOut

        vm.expectRevert(BlitzrSwapRouter.TokenMismatch.selector);
        router.swapSplit(routes, 0, address(0), _noValuation());
    }

    function test_swapSplit_revertsOnSlippage() public {
        tokenB.mint(address(target), 1000e18);
        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.InsufficientOutput.selector);
        router.swapSplit(_twoLegRoutes(), 93e18, address(0), _noValuation()); // actual output is 92e18
    }

    function test_swapSplit_nativeInputSummedAcrossRoutes() public {
        vm.deal(alice, 10 ether);
        tokenB.mint(address(target), 1000e18);

        BlitzrSwapRouter.Route[] memory routes = new BlitzrSwapRouter.Route[](2);
        routes[0] = _route(_hop(address(0), address(tokenB), 0.6 ether, 54e18));
        routes[1] = _route(_hop(address(0), address(tokenB), 0.4 ether, 38e18));

        vm.prank(alice);
        uint256 out = router.swapSplit{value: 1 ether}(routes, 92e18, address(0), _noValuation());

        assertEq(out, 92e18);
        assertEq(tokenB.balanceOf(alice), 92e18);
    }

    function test_swapSplit_revertsOnWrongNativeAmount() public {
        vm.deal(alice, 10 ether);
        BlitzrSwapRouter.Route[] memory routes = new BlitzrSwapRouter.Route[](1);
        routes[0] = _route(_hop(address(0), address(tokenB), 1 ether, 90e18));

        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.InvalidNativeAmount.selector);
        router.swapSplit{value: 0.5 ether}(routes, 90e18, address(0), _noValuation());
    }

    // --- swapSplitWithPermit ---

    function test_swapSplitWithPermit_pullsTotalViaPermit2() public {
        tokenB.mint(address(target), 1000e18);

        vm.prank(alice);
        uint256 out = router.swapSplitWithPermit(
            _twoLegRoutes(), 92e18, address(0), _noValuation(), 1, block.timestamp + 1 hours, ""
        );

        assertEq(out, 92e18);
        assertEq(tokenB.balanceOf(alice), 92e18);
        assertEq(tokenA.balanceOf(alice), 900e18);
    }

    function test_swapSplitWithPermit_revertsOnNativeInput() public {
        BlitzrSwapRouter.Route[] memory routes = new BlitzrSwapRouter.Route[](1);
        routes[0] = _route(_hop(address(0), address(tokenB), 1 ether, 90e18));

        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.InvalidNativeAmount.selector);
        router.swapSplitWithPermit(routes, 90e18, address(0), _noValuation(), 1, block.timestamp + 1 hours, "");
    }
}
