// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlitzrSwapRouter} from "../BlitzrSwapRouter/BlitzrSwapRouter.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";
import {RewardsLib} from "../BlitzrSwapRouter/libraries/RewardsLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapTarget} from "./mocks/MockSwapTarget.sol";

// Multi-token reward: setRewardTokens() configures a weighted list of RewardsLib.RewardToken
// entries; a single referral/cashback payout is split across all of them by weight rather than
// being restricted to one fixed reward token. Single-reward-token payout mechanics (bps math,
// no-op conditions, first-touch referral binding) are already covered in BlitzrSwapRouter.t.sol
// using a one-entry, 100%-weight list; this file focuses on the multi-token split itself.
contract BlitzrSwapRouterRewardsTest is Test {
    BlitzrSwapRouter router;
    BlitzrSwapRouterRewardVault vault;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 rewardX;
    MockERC20 rewardY;
    MockSwapTarget target;

    address owner = address(this);
    address alice = makeAddr("alice");
    address referrer = makeAddr("referrer");

    function setUp() public {
        vault = new BlitzrSwapRouterRewardVault(owner, address(0));

        BlitzrSwapRouter impl = new BlitzrSwapRouter();
        bytes memory initData =
            abi.encodeWithSelector(BlitzrSwapRouter.initialize.selector, owner, address(vault), address(0xdead));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = BlitzrSwapRouter(payable(address(proxy)));
        vault.setRouter(address(router));

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        rewardX = new MockERC20("RewardX", "RX", 18);
        rewardY = new MockERC20("RewardY", "RY", 18);
        target = new MockSwapTarget();
        router.setAllowedTarget(address(target), true);

        tokenA.mint(alice, 1_000e18);
        vm.prank(alice);
        tokenA.approve(address(router), type(uint256).max);

        rewardX.mint(address(vault), 1_000e18);
        rewardY.mint(address(vault), 1_000e18);

        // 100% by default in this file — isolates the multi-token weighting math (this file's
        // focus) from the aggregation-fee scaling step, which gets its own dedicated tests below.
        router.setAggregationFeeBps(10_000);
    }

    function _weightedTokens(uint256 weightX, uint256 weightY) private view returns (RewardsLib.RewardToken[] memory) {
        RewardsLib.RewardToken[] memory tokens = new RewardsLib.RewardToken[](2);
        tokens[0] = RewardsLib.RewardToken({token: address(rewardX), weightBps: weightX});
        tokens[1] = RewardsLib.RewardToken({token: address(rewardY), weightBps: weightY});
        return tokens;
    }

    function _hop(uint256 amountIn, uint256 amountOut) private view returns (BlitzrSwapRouter.Hop memory) {
        return BlitzrSwapRouter.Hop({
            dexType: BlitzrSwapRouter.HopType.STANDARD,
            target: address(target),
            data: abi.encodeWithSelector(
                MockSwapTarget.executeSwap.selector, address(tokenA), amountIn, address(tokenB), amountOut, address(router)
            ),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: amountIn,
            minAmountOut: amountOut
        });
    }

    function _noValuation() private pure returns (BlitzrSwapRouter.Valuation memory) {
        return BlitzrSwapRouter.Valuation({kind: BlitzrSwapRouter.ValuationType.NONE, pool: address(0), window: 0});
    }

    function _swap(address referrer_) private {
        tokenB.mint(address(target), 1000e18);
        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = _hop(100e18, 90e18);
        vm.prank(alice);
        router.swap(hops, 90e18, referrer_, _noValuation());
    }

    // --- setRewardTokens admin ---

    function test_setRewardTokens_onlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        router.setRewardTokens(_weightedTokens(7000, 3000));
    }

    function test_setRewardTokens_revertsWhenWeightsExceedBps() public {
        vm.expectRevert(BlitzrSwapRouter.InvalidBps.selector);
        router.setRewardTokens(_weightedTokens(7000, 4000)); // sums to 11000 > 10000
    }

    function test_setRewardTokens_revertsOnZeroAddressToken() public {
        RewardsLib.RewardToken[] memory tokens = new RewardsLib.RewardToken[](1);
        tokens[0] = RewardsLib.RewardToken({token: address(0), weightBps: 10_000});
        vm.expectRevert(BlitzrSwapRouter.ZeroAddress.selector);
        router.setRewardTokens(tokens);
    }

    function test_setRewardTokens_storesConfiguredList() public {
        router.setRewardTokens(_weightedTokens(7000, 3000));
        RewardsLib.RewardToken[] memory got = router.rewardTokens();
        assertEq(got.length, 2);
        assertEq(got[0].token, address(rewardX));
        assertEq(got[0].weightBps, 7000);
        assertEq(got[1].token, address(rewardY));
        assertEq(got[1].weightBps, 3000);
    }

    // --- multi-token payout ---

    function test_referralReward_splitsAcrossWeightedTokens() public {
        router.setRewardTokens(_weightedTokens(7000, 3000));
        router.setFeeBps(1000, 0); // 10% referral, no cashback
        router.setFlatFallbackValue(1000e18);

        _swap(referrer);

        // total referral amount = 1000e18 * 10% = 100e18, split 70/30
        assertEq(rewardX.balanceOf(referrer), 70e18);
        assertEq(rewardY.balanceOf(referrer), 30e18);
    }

    function test_cashback_splitsAcrossWeightedTokens() public {
        router.setRewardTokens(_weightedTokens(7000, 3000));
        router.setFeeBps(0, 500); // no referral, 5% cashback
        router.setFlatFallbackValue(1000e18);

        _swap(address(0));

        // total cashback = 1000e18 * 5% = 50e18, split 70/30
        assertEq(rewardX.balanceOf(alice), 35e18);
        assertEq(rewardY.balanceOf(alice), 15e18);
    }

    function test_referralReward_bothLegsFireOnSameSwap() public {
        router.setRewardTokens(_weightedTokens(5000, 5000));
        router.setFeeBps(1000, 500);
        router.setFlatFallbackValue(1000e18);

        _swap(referrer);

        assertEq(rewardX.balanceOf(referrer), 50e18); // 100e18 * 50%
        assertEq(rewardY.balanceOf(referrer), 50e18);
        assertEq(rewardX.balanceOf(alice), 25e18); // 50e18 * 50%
        assertEq(rewardY.balanceOf(alice), 25e18);
    }

    function test_noRewardTokensConfigured_paysNothingWithoutReverting() public {
        // rewardTokens left empty — bps configured but nothing to pay out into.
        router.setFeeBps(1000, 500);
        router.setFlatFallbackValue(1000e18);

        _swap(referrer); // must not revert

        assertEq(rewardX.balanceOf(referrer), 0);
        assertEq(rewardY.balanceOf(referrer), 0);
    }

    function test_zeroWeightEntry_isSkippedWithoutAffectingOthers() public {
        router.setRewardTokens(_weightedTokens(10_000, 0));
        router.setFeeBps(1000, 0);
        router.setFlatFallbackValue(1000e18);

        _swap(referrer);

        assertEq(rewardX.balanceOf(referrer), 100e18);
        assertEq(rewardY.balanceOf(referrer), 0);
    }

    // --- aggregationFeeBps: referral/cashback cut a share of the AGGREGATION FEE, not of the
    // swap's raw value directly — see BlitzrSwapRouter.sol's header and setAggregationFeeBps. ---

    function test_initialize_defaultsAggregationFeeBpsTo30() public {
        // A fresh instance, deliberately not the shared `router` from setUp() — that one has
        // aggregationFeeBps overridden to 100% so the rest of this file's weighting-math tests
        // stay isolated from the scaling step. This checks the real post-initialize default.
        BlitzrSwapRouter impl = new BlitzrSwapRouter();
        bytes memory initData =
            abi.encodeWithSelector(BlitzrSwapRouter.initialize.selector, owner, address(vault), address(0xdead));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        BlitzrSwapRouter freshRouter = BlitzrSwapRouter(payable(address(proxy)));

        assertEq(freshRouter.aggregationFeeBps(), 30); // 0.3%
    }

    function test_setAggregationFeeBps_onlyOwnerAndBounded() public {
        vm.expectRevert();
        vm.prank(alice);
        router.setAggregationFeeBps(100);

        vm.expectRevert(BlitzrSwapRouter.InvalidBps.selector);
        router.setAggregationFeeBps(10_001);

        router.setAggregationFeeBps(50);
        assertEq(router.aggregationFeeBps(), 50);
    }

    function test_referralReward_scaledByAggregationFeeBeforeBpsSplit() public {
        router.setRewardTokens(_weightedTokens(10_000, 0));
        router.setAggregationFeeBps(30); // 0.3% — the real default, overriding this file's setUp override
        router.setFeeBps(1000, 0); // 10% of the aggregation fee
        router.setFlatFallbackValue(1000e18);

        _swap(referrer);

        // aggregationFee = 1000e18 * 0.3% = 3e18; referral = 3e18 * 10% = 3e17 — NOT 1000e18 * 10%
        // (100e18), proving referralBps cuts the fee, not the raw value.
        assertEq(rewardX.balanceOf(referrer), 3e17);
    }

    function test_aggregationFeeBpsZero_paysNoRewardsEvenWithFeeBpsSet() public {
        router.setRewardTokens(_weightedTokens(10_000, 0));
        router.setAggregationFeeBps(0);
        router.setFeeBps(1000, 500);
        router.setFlatFallbackValue(1000e18);

        _swap(referrer); // must not revert

        assertEq(rewardX.balanceOf(referrer), 0);
        assertEq(rewardX.balanceOf(alice), 0);
    }
}
