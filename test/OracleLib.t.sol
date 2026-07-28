// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {OracleLib} from "../BlitzrSwapRouter/libraries/OracleLib.sol";
import {OracleLibHarness} from "./mocks/OracleLibHarness.sol";
import {MockUniswapV2Pair} from "./mocks/MockUniswapV2Pair.sol";
import {MockV3PoolObserve} from "./mocks/MockV3PoolObserve.sol";

contract OracleLibTest is Test {
    OracleLibHarness harness;
    address tokenA = makeAddr("tokenA");
    address tokenB = makeAddr("tokenB");

    uint256 constant Q112 = 2 ** 112;

    function setUp() public {
        harness = new OracleLibHarness();
    }

    // --- V2 ---

    function test_getV2Value_revertsWithoutPriorObservation() public {
        MockUniswapV2Pair pair = new MockUniswapV2Pair(tokenA, tokenB);
        vm.expectRevert(OracleLib.NoV2Observation.selector);
        harness.getV2Value(address(pair), tokenA, 100e18, 0);
    }

    function test_getV2Value_revertsIfElapsedBelowMinimum() public {
        MockUniswapV2Pair pair = new MockUniswapV2Pair(tokenA, tokenB);
        pair.setCumulative(0, 0, 1000);
        harness.updateV2Observation(address(pair));

        pair.setCumulative(2 * Q112 * 1000, 0, 1400); // only 400s elapsed
        vm.expectRevert(OracleLib.InsufficientV2Elapsed.selector);
        harness.getV2Value(address(pair), tokenA, 100e18, 500);
    }

    function test_getV2Value_computesAveragePriceOverWindow_token0() public {
        MockUniswapV2Pair pair = new MockUniswapV2Pair(tokenA, tokenB);
        pair.setCumulative(0, 0, 1000);
        harness.updateV2Observation(address(pair));

        // Average price over the next 1000s is exactly 2.0 (token1 per token0).
        uint256 delta = 2 * Q112 * 1000;
        pair.setCumulative(delta, 0, 2000);

        uint256 value = harness.getV2Value(address(pair), tokenA, 100e18, 500);
        assertEq(value, 200e18);
    }

    function test_getV2Value_usesOtherCumulative_forToken1() public {
        MockUniswapV2Pair pair = new MockUniswapV2Pair(tokenA, tokenB);
        pair.setCumulative(0, 0, 1000);
        harness.updateV2Observation(address(pair));

        // token1 (tokenB) average price is 0.5 (token0 per token1) over 1000s.
        uint256 delta1 = Q112 * 1000 / 2;
        pair.setCumulative(999_999e18, delta1, 2000); // price0Cumulative irrelevant for this query

        uint256 value = harness.getV2Value(address(pair), tokenB, 100e18, 500);
        assertEq(value, 50e18);
    }

    function test_updateV2Observation_isPermissionlessAndOverwritesPreviousCheckpoint() public {
        MockUniswapV2Pair pair = new MockUniswapV2Pair(tokenA, tokenB);
        pair.setCumulative(0, 0, 1000);
        vm.prank(makeAddr("randomKeeper"));
        harness.updateV2Observation(address(pair));

        pair.setCumulative(2 * Q112 * 1000, 0, 2000);
        vm.prank(makeAddr("anotherKeeper"));
        harness.updateV2Observation(address(pair)); // re-checkpoints at t=2000

        // A further 500s later at the same 2.0 average price:
        pair.setCumulative(2 * Q112 * 1000 + 2 * Q112 * 500, 0, 2500);
        uint256 value = harness.getV2Value(address(pair), tokenA, 100e18, 400);
        assertEq(value, 200e18); // still 2.0 average, now measured from the newer checkpoint
    }

    // --- V3 ---

    function test_getV3TwapTick_atTickZero() public {
        MockV3PoolObserve pool = new MockV3PoolObserve(tokenA);
        pool.setTickCumulatives(0, 0);
        assertEq(harness.getV3TwapTick(address(pool), 1800), 0);
    }

    function test_getV3TwapTick_flooredTowardsNegativeInfinity() public {
        MockV3PoolObserve pool = new MockV3PoolObserve(tokenA);
        pool.setTickCumulatives(0, -1000);
        // delta = -1000, window = 300 -> -1000/300 truncates to -3, remainder nonzero -> floor to -4.
        assertEq(harness.getV3TwapTick(address(pool), 300), -4);
    }

    function test_getV3Value_atTickZero_isOneToOne() public {
        MockV3PoolObserve pool = new MockV3PoolObserve(tokenA);
        pool.setTickCumulatives(0, 0);
        uint256 value = harness.getV3Value(address(pool), tokenA, 100e18, 1800);
        assertEq(value, 100e18); // tick 0 => sqrtPriceX96 == 2^96 => price 1.0
    }

    function test_getV3Value_token1Direction_atTickZero_isOneToOne() public {
        MockV3PoolObserve pool = new MockV3PoolObserve(tokenA); // tokenA is token0
        pool.setTickCumulatives(0, 0);
        uint256 value = harness.getV3Value(address(pool), tokenB, 100e18, 1800); // tokenB is "token1"
        assertEq(value, 100e18);
    }
}
