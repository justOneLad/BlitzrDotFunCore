// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {FullMath, TickMath} from "../../xBlitzr/XBlitzrLauncher.sol";

interface IUniswapV2PairMinimal {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

interface IUniswapV3PoolObserveMinimal {
    function token0() external view returns (address);
    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

// Prices a swap's input against a reference asset. V3 pools expose historical ticks directly via
// `observe()`; V2 pairs only expose the current cumulative price, so a TWAP needs a stored
// checkpoint (updateV2Observation, called periodically) to compare against. Both remain
// spot-manipulable on a thin pool/pair — window length (V3) and minElapsed (V2) are the only
// levers against that; pool/pair selection is an owner-curated trust decision, not enforced here.
library OracleLib {
    error InsufficientV2Elapsed();
    error NoV2Observation();

    uint256 internal constant Q112 = 2 ** 112;

    struct V2Observation {
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
        uint32  blockTimestampLast;
    }

    // --- Uniswap V2 ---

    // The first call for a given pair only seeds the checkpoint — getV2Value() reverts
    // (InsufficientV2Elapsed) until a second, later call records a later one to compare against.
    function updateV2Observation(mapping(address => V2Observation) storage observations, address pair) internal {
        (,, uint32 blockTimestampLast) = IUniswapV2PairMinimal(pair).getReserves();
        observations[pair] = V2Observation({
            price0CumulativeLast: IUniswapV2PairMinimal(pair).price0CumulativeLast(),
            price1CumulativeLast: IUniswapV2PairMinimal(pair).price1CumulativeLast(),
            blockTimestampLast: blockTimestampLast
        });
    }

    // Value of `amountIn` of `token` in terms of the pair's other token, averaged since the
    // stored checkpoint. minElapsed guards against a same-block/adjacent-block checkpoint, which
    // would be trivially manipulable.
    function getV2Value(
        mapping(address => V2Observation) storage observations,
        address pair,
        address token,
        uint256 amountIn,
        uint256 minElapsed
    ) internal view returns (uint256 valueOut) {
        V2Observation storage obs = observations[pair];
        if (obs.blockTimestampLast == 0) revert NoV2Observation();

        (,, uint32 blockTimestampNow) = IUniswapV2PairMinimal(pair).getReserves();
        // Matches V2's own accumulator: blockTimestampLast is uint32, differences wrap correctly
        // modulo 2^32 exactly like the pair contract's own arithmetic.
        uint256 elapsed = uint256(blockTimestampNow - obs.blockTimestampLast);
        if (elapsed < minElapsed) revert InsufficientV2Elapsed();

        bool tokenIsToken0 = token == IUniswapV2PairMinimal(pair).token0();
        uint256 priceCumulativeNow = tokenIsToken0
            ? IUniswapV2PairMinimal(pair).price0CumulativeLast()
            : IUniswapV2PairMinimal(pair).price1CumulativeLast();
        uint256 priceCumulativeLast = tokenIsToken0 ? obs.price0CumulativeLast : obs.price1CumulativeLast;

        // V2 price accumulators are UQ112x112 fixed point; unchecked to match V2's own
        // accumulator overflow semantics (differences are always correct mod 2^256 regardless).
        unchecked {
            uint256 priceAverageX112 = (priceCumulativeNow - priceCumulativeLast) / elapsed;
            valueOut = FullMath.mulDiv(priceAverageX112, amountIn, Q112);
        }
    }

    // --- Uniswap V3 ---

    // Time-weighted average tick over the trailing `window` seconds, ending now.
    function getV3TwapTick(address pool, uint32 window) internal view returns (int24 arithmeticMeanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = IUniswapV3PoolObserveMinimal(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 windowInt = int56(uint56(window));
        arithmeticMeanTick = int24(delta / windowInt);
        // Floor towards negative infinity (Solidity truncates towards zero) to match the real
        // Uniswap v3-periphery OracleLibrary's rounding convention exactly.
        if (delta < 0 && delta % windowInt != 0) arithmeticMeanTick--;
    }

    // Ported from Uniswap v3-periphery's OracleLibrary.getQuoteAtTick — branches on sqrtPriceX96
    // magnitude to avoid squaring overflowing uint256 (up to 320 bits for a naive square).
    function getV3Value(address pool, address token, uint256 amountIn, uint32 window)
        internal view returns (uint256 valueOut)
    {
        int24 meanTick = getV3TwapTick(pool, window);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(meanTick);
        bool tokenIsToken0 = token == IUniswapV3PoolObserveMinimal(pool).token0();

        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            valueOut = tokenIsToken0
                ? FullMath.mulDiv(ratioX192, amountIn, 1 << 192)
                : FullMath.mulDiv(1 << 192, amountIn, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            valueOut = tokenIsToken0
                ? FullMath.mulDiv(ratioX128, amountIn, 1 << 128)
                : FullMath.mulDiv(1 << 128, amountIn, ratioX128);
        }
    }
}
