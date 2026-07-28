// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlitzrSwapRouter} from "../BlitzrSwapRouter/BlitzrSwapRouter.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";
import {RewardsLib} from "../BlitzrSwapRouter/libraries/RewardsLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapTarget} from "./mocks/MockSwapTarget.sol";

// Deployed as a second implementation in the upgrade test — just needs a distinguishable marker
// while otherwise behaving identically, to prove storage survives an upgrade.
contract BlitzrSwapRouterV2Stub is BlitzrSwapRouter {
    function version() external pure returns (string memory) {
        return "v2-stub";
    }
}

contract BlitzrSwapRouterTest is Test {
    BlitzrSwapRouter router; // proxy, typed as the implementation ABI
    BlitzrSwapRouterRewardVault vault;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 rewardToken;
    MockSwapTarget target;

    address owner = address(this);
    address alice = makeAddr("alice");
    address referrer = makeAddr("referrer");

    function setUp() public {
        rewardToken = new MockERC20("Reward", "RWD", 18);
        vault = new BlitzrSwapRouterRewardVault(owner, address(0));

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

        RewardsLib.RewardToken[] memory tokens = new RewardsLib.RewardToken[](1);
        tokens[0] = RewardsLib.RewardToken({token: address(rewardToken), weightBps: 10_000});
        router.setRewardTokens(tokens);

        // 100% — isolates referralBps/cashbackBps math in this file's tests from the
        // aggregation-fee scaling step (covered separately in BlitzrSwapRouterRewards.t.sol).
        router.setAggregationFeeBps(10_000);

        tokenA.mint(alice, 1_000e18);
        vm.prank(alice);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _hop(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        private
        view
        returns (BlitzrSwapRouter.Hop memory)
    {
        return BlitzrSwapRouter.Hop({
            dexType: BlitzrSwapRouter.HopType.STANDARD,
            target: address(target),
            data: abi.encodeWithSelector(MockSwapTarget.executeSwap.selector, tokenIn, amountIn, tokenOut, amountOut, address(router)),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: amountOut
        });
    }

    function _noValuation() private pure returns (BlitzrSwapRouter.Valuation memory) {
        return BlitzrSwapRouter.Valuation({kind: BlitzrSwapRouter.ValuationType.NONE, pool: address(0), window: 0});
    }

    // --- initialize / proxy wiring ---

    function test_initialize_setsStateAndOwner() public view {
        assertEq(router.owner(), owner);
        assertEq(router.rewardVault(), address(vault));
        assertEq(router.poolManager(), address(0xdead));
        assertEq(router.v2MinElapsed(), 1800);
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        router.initialize(alice, address(vault), address(0xdead));
    }

    function test_implementation_initializeIsDisabled() public {
        BlitzrSwapRouter impl = new BlitzrSwapRouter();
        vm.expectRevert();
        impl.initialize(owner, address(vault), address(0xdead));
    }

    // --- UUPS upgrade ---

    function test_upgrade_onlyOwner() public {
        BlitzrSwapRouterV2Stub newImpl = new BlitzrSwapRouterV2Stub();
        vm.expectRevert();
        vm.prank(alice);
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_preservesStorageAndSwitchesLogic() public {
        // Establish some state pre-upgrade.
        router.setFeeBps(500, 200);
        router.setFlatFallbackValue(1000e18);

        BlitzrSwapRouterV2Stub newImpl = new BlitzrSwapRouterV2Stub();
        router.upgradeToAndCall(address(newImpl), "");

        // Storage survived the upgrade.
        assertEq(router.referralBps(), 500);
        assertEq(router.cashbackBps(), 200);
        assertEq(router.flatFallbackValue(), 1000e18);
        // New logic is live.
        assertEq(BlitzrSwapRouterV2Stub(payable(address(router))).version(), "v2-stub");
    }

    // --- admin ---

    function test_setAllowedTarget_onlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        router.setAllowedTarget(address(target), false);
    }

    function test_setFeeBps_onlyOwnerAndBounded() public {
        vm.expectRevert();
        vm.prank(alice);
        router.setFeeBps(100, 100);

        vm.expectRevert(BlitzrSwapRouter.InvalidBps.selector);
        router.setFeeBps(10_001, 0);

        router.setFeeBps(500, 300);
        assertEq(router.referralBps(), 500);
        assertEq(router.cashbackBps(), 300);
    }

    // --- swap: STANDARD hops ---

    function test_swap_singleHop_happyPath() public {
        tokenB.mint(address(target), 1000e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.prank(alice);
        uint256 out = router.swap(hops, 90e18, address(0), _noValuation());

        assertEq(out, 90e18);
        assertEq(tokenB.balanceOf(alice), 90e18);
        assertEq(tokenA.balanceOf(address(target)), 100e18);
    }

    function test_swap_multiHop_chainsThroughCorrectly() public {
        MockERC20 tokenC = new MockERC20("C", "C", 18);
        tokenB.mint(address(target), 1000e18);
        tokenC.mint(address(target), 1000e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](2);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);
        hops[1] = _hop(address(tokenB), address(tokenC), 90e18, 80e18);

        vm.prank(alice);
        uint256 out = router.swap(hops, 80e18, address(0), _noValuation());

        assertEq(out, 80e18);
        assertEq(tokenC.balanceOf(alice), 80e18);
        assertEq(tokenB.balanceOf(address(router)), 0); // fully passed through, nothing stuck
    }

    function test_swap_revertsOnTargetNotAllowed() public {
        MockSwapTarget rogue = new MockSwapTarget();
        tokenB.mint(address(rogue), 1000e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = BlitzrSwapRouter.Hop({
            dexType: BlitzrSwapRouter.HopType.STANDARD,
            target: address(rogue),
            data: abi.encodeWithSelector(MockSwapTarget.executeSwap.selector, address(tokenA), 100e18, address(tokenB), 90e18, address(router)),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: 100e18,
            minAmountOut: 90e18
        });

        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.TargetNotAllowed.selector);
        router.swap(hops, 90e18, address(0), _noValuation());
    }

    function test_swap_revertsOnSlippage() public {
        tokenB.mint(address(target), 1000e18);
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 50e18);
        hops[0].minAmountOut = 90e18; // target only pays out 50e18, but we demand 90e18

        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.InsufficientOutput.selector);
        router.swap(hops, 50e18, address(0), _noValuation());
    }

    function test_swap_revertsOnEmptyRoute() public {
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](0);
        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.EmptyRoute.selector);
        router.swap(hops, 0, address(0), _noValuation());
    }

    function test_swap_revertsOnHopChainTokenMismatch() public {
        MockERC20 tokenC = new MockERC20("C", "C", 18);
        tokenB.mint(address(target), 1000e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](2);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);
        hops[1] = _hop(address(tokenC), address(tokenB), 90e18, 80e18); // wrong tokenIn — doesn't match hop0's output

        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.TokenMismatch.selector);
        router.swap(hops, 80e18, address(0), _noValuation());
    }

    function test_swap_nativeInput() public {
        vm.deal(alice, 10 ether);
        tokenB.mint(address(target), 1000e18);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(0), address(tokenB), 1 ether, 90e18);

        vm.prank(alice);
        uint256 out = router.swap{value: 1 ether}(hops, 90e18, address(0), _noValuation());

        assertEq(out, 90e18);
        assertEq(tokenB.balanceOf(alice), 90e18);
        assertEq(address(target).balance, 1 ether);
    }

    function test_swap_revertsOnWrongNativeAmount() public {
        vm.deal(alice, 10 ether);
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(0), address(tokenB), 1 ether, 90e18);

        vm.prank(alice);
        vm.expectRevert(BlitzrSwapRouter.InvalidNativeAmount.selector);
        router.swap{value: 0.5 ether}(hops, 90e18, address(0), _noValuation());
    }

    // --- referral / cashback (flat fallback valuation) ---

    function test_swap_bindsReferralAndPaysOutViaFlatFallback() public {
        router.setFeeBps(1000, 500); // 10% referral, 5% cashback
        router.setFlatFallbackValue(1000e18);
        rewardToken.mint(address(vault), 1000e18);

        tokenB.mint(address(target), 1000e18);
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.prank(alice);
        router.swap(hops, 90e18, referrer, _noValuation());

        assertEq(router.referrerOf(alice), referrer);
        assertEq(rewardToken.balanceOf(referrer), 100e18); // 1000e18 * 10%
        assertEq(rewardToken.balanceOf(alice), 50e18); // 1000e18 * 5%
    }

    function test_swap_referralBindingIsFirstTouchOnly() public {
        router.setFlatFallbackValue(1000e18);
        tokenB.mint(address(target), 1000e18);
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.prank(alice);
        router.swap(hops, 90e18, referrer, _noValuation());
        assertEq(router.referrerOf(alice), referrer);

        address otherReferrer = makeAddr("otherReferrer");
        tokenA.mint(alice, 100e18);
        vm.prank(alice);
        router.swap(hops, 90e18, otherReferrer, _noValuation());
        assertEq(router.referrerOf(alice), referrer); // unchanged — first touch wins
    }

    function test_swap_noRewardPayoutWhenBpsUnset() public {
        router.setFlatFallbackValue(1000e18);
        // referralBps/cashbackBps default to 0
        tokenB.mint(address(target), 1000e18);
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(address(tokenA), address(tokenB), 100e18, 90e18);

        vm.prank(alice);
        router.swap(hops, 90e18, referrer, _noValuation());

        assertEq(rewardToken.balanceOf(referrer), 0);
        assertEq(rewardToken.balanceOf(alice), 0);
    }
}
