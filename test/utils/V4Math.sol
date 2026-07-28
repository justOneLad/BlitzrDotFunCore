// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {FullMath} from "../../xBlitzr/XBlitzrLauncher.sol";

// Inverse of XBlitzrLauncher's LiquidityAmounts.getLiquidityForAmountX (liquidity -> amount
// instead of amount -> liquidity) — ported from Uniswap's LiquidityAmounts.sol. XBlitzrLauncher
// itself never needs this direction (real PoolManager returns amounts owed directly), but the
// test double does, to reconstruct realistic owed amounts from the liquidity XBlitzrLauncher
// computes and passes into modifyLiquidity.
library V4Math {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal pure returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return FullMath.mulDiv(uint256(liquidity) << 96, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal pure returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }
}
