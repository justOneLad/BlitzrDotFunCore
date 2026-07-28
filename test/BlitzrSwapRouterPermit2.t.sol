// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlitzrSwapRouter} from "../BlitzrSwapRouter/BlitzrSwapRouter.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapTarget} from "./mocks/MockSwapTarget.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

// swapWithPermit()/swapSplitWithPermit() — the Permit2-based ERC20 pull path, an alternative to
// the pre-existing-approval path covered in BlitzrSwapRouter.t.sol. Uses a MockPermit2 rather
// than the real canonical Permit2 (which would need to be etched/forked in) — signature
// verification is Permit2's own already-audited logic, out of scope for this router's own tests.
contract BlitzrSwapRouterPermit2Test is Test {
    BlitzrSwapRouter router;
    BlitzrSwapRouterRewardVault vault;
    MockPermit2 permit2;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockSwapTarget target;

    address owner = address(this);
    address alice = makeAddr("alice");

    // Must match BlitzrSwapRouter's CANONICAL_PERMIT2 constant.
    address constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {
        vault = new BlitzrSwapRouterRewardVault(owner, address(0));
        permit2 = new MockPermit2();

        BlitzrSwapRouter impl = new BlitzrSwapRouter();
        bytes memory initData =
            abi.encodeWithSelector(BlitzrSwapRouter.initialize.selector, owner, address(vault), address(0xdead));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = BlitzrSwapRouter(payable(address(proxy)));
        vault.setRouter(address(router));

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        target = new MockSwapTarget();
        router.setAllowedTarget(address(target), true);

        tokenA.mint(alice, 1_000e18);
        vm.prank(alice);
        tokenA.approve(address(permit2), type(uint256).max);
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

    function _noValuation() private pure returns (BlitzrSwapRouter.Valuation memory) {
        return BlitzrSwapRouter.Valuation({kind: BlitzrSwapRouter.ValuationType.NONE, pool: address(0), window: 0});
    }

    // --- permit2 config ---

    function test_permit2_defaultsToCanonicalAddress() public view {
        assertEq(router.permit2(), CANONICAL_PERMIT2);
    }

    function test_setPermit2_onlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        router.setPermit2(address(permit2));
    }

    // --- swapWithPermit ---

    function test_swapWithPermit_pullsViaPermit2AndSwaps() public {
        router.setPermit2(address(permit2));
        tokenB.mint(address(target), 1000e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.prank(alice);
        uint256 out = router.swapWithPermit(hops, 90e18, address(0), _noValuation(), 1, block.timestamp + 1 hours, "");

        assertEq(out, 90e18);
        assertEq(tokenB.balanceOf(alice), 90e18);
        assertEq(tokenA.balanceOf(alice), 900e18);
        assertEq(tokenA.balanceOf(address(target)), 100e18);
    }

    function test_swapWithPermit_revertsIfPermit2NotSet() public {
        router.setPermit2(address(0));
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.Permit2NotSet.selector);
        router.swapWithPermit(hops, 90e18, address(0), _noValuation(), 1, block.timestamp + 1 hours, "");
    }

    function test_swapWithPermit_revertsOnNativeInput() public {
        router.setPermit2(address(permit2));
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(0), address(tokenB), 1 ether, 90e18);

        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.InvalidNativeAmount.selector);
        router.swapWithPermit(hops, 90e18, address(0), _noValuation(), 1, block.timestamp + 1 hours, "");
    }

    function test_swapWithPermit_revertsOnNonceReuse() public {
        router.setPermit2(address(permit2));
        tokenB.mint(address(target), 1000e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.prank(alice);
        router.swapWithPermit(hops, 90e18, address(0), _noValuation(), 1, block.timestamp + 1 hours, "");

        vm.prank(alice);
        vm.expectRevert(MockPermit2.NonceUsed.selector);
        router.swapWithPermit(hops, 90e18, address(0), _noValuation(), 1, block.timestamp + 1 hours, "");
    }

    function test_swapWithPermit_revertsOnExpiredDeadline() public {
        router.setPermit2(address(permit2));
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.warp(1_000_000);
        vm.prank(alice);
        vm.expectRevert(MockPermit2.Expired.selector);
        router.swapWithPermit(hops, 90e18, address(0), _noValuation(), 1, block.timestamp - 1, "");
    }
}
