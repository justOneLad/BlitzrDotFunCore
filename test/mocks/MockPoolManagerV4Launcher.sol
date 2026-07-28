// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {TickMath} from "../../xBlitzr/XBlitzrLauncher.sol";
import {V4Math} from "../utils/V4Math.sol";

interface IERC20Like2 {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUnlockCallbackLike {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

// Test double for Uniswap V4's PoolManager singleton, scoped to what XBlitzrLauncher actually
// calls. Deliberately untyped (plain address/int256 instead of the Currency/BalanceDelta custom
// value types XBlitzrLauncher.sol declares) — user-defined value types ABI-encode identically to
// their underlying primitive, so this still matches every call XBlitzrLauncher makes without
// needing to share Solidity-level type identity across files.
//
// No real flash-accounting/solvency tracking: `take()` pays out of this contract's own real
// token/native balance (funded either by XBlitzrLauncher's own settle-time transfers, mirroring
// production, or directly by a test for fee-poke scenarios), and `settle()`/`sync()` are no-ops.
// That's enough to exercise XBlitzrLauncher's own math and orchestration without reimplementing
// Uniswap's engine.
contract MockPoolManagerV4Launcher {
    struct PoolKeyLocal {
        address currency0;
        address currency1;
        uint24  fee;
        int24   tickSpacing;
        address hooks;
    }
    struct ModifyLiquidityParamsLocal {
        int24   tickLower;
        int24   tickUpper;
        int256  liquidityDelta;
        bytes32 salt;
    }
    struct SwapParamsLocal {
        bool    zeroForOne;
        int256  amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    int24 public nextTick;
    uint256 public nextSwapAmountOut;
    mapping(bytes32 => uint256) public pendingFees0;
    mapping(bytes32 => uint256) public pendingFees1;

    function setNextTick(int24 tick_) external {
        nextTick = tick_;
    }

    function setNextSwapAmountOut(uint256 amountOut) external {
        nextSwapAmountOut = amountOut;
    }

    // poolId must be the bytes32 returned by XBlitzrLauncher.launch() (== PoolIdLibrary.toId(key),
    // an identical hash regardless of which file's Currency/PoolKey type produced it, since
    // abi.encode of structurally-identical tuples is byte-for-byte identical).
    function setPendingFees(bytes32 poolId, uint256 amount0, uint256 amount1) external {
        pendingFees0[poolId] = amount0;
        pendingFees1[poolId] = amount1;
    }

    function initialize(PoolKeyLocal memory, uint160) external view returns (int24 tick) {
        return nextTick;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallbackLike(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(PoolKeyLocal memory key, ModifyLiquidityParamsLocal memory params, bytes calldata)
        external returns (int256 callerDelta, int256 feesAccrued)
    {
        if (params.liquidityDelta > 0) {
            uint160 sqrtA = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtB = TickMath.getSqrtRatioAtTick(params.tickUpper);
            uint160 sqrtCurrent = TickMath.getSqrtRatioAtTick(nextTick);
            uint128 liq = uint128(uint256(params.liquidityDelta));

            uint256 amt0;
            uint256 amt1;
            if (sqrtCurrent <= sqrtA) {
                amt0 = V4Math.getAmount0ForLiquidity(sqrtA, sqrtB, liq);
            } else if (sqrtCurrent >= sqrtB) {
                amt1 = V4Math.getAmount1ForLiquidity(sqrtA, sqrtB, liq);
            } else {
                amt0 = V4Math.getAmount0ForLiquidity(sqrtCurrent, sqrtB, liq);
                amt1 = V4Math.getAmount1ForLiquidity(sqrtA, sqrtCurrent, liq);
            }
            callerDelta = _pack(-int128(int256(amt0)), -int128(int256(amt1)));
            feesAccrued = 0;
        } else {
            // Zero-delta poke: pay out whatever the test configured as accrued fees for this
            // pool, then clear it (mirrors real fees only being realized once per poke).
            bytes32 poolId = keccak256(abi.encode(key));
            uint256 fee0 = pendingFees0[poolId];
            uint256 fee1 = pendingFees1[poolId];
            pendingFees0[poolId] = 0;
            pendingFees1[poolId] = 0;
            callerDelta = _pack(int128(int256(fee0)), int128(int256(fee1)));
            feesAccrued = callerDelta;
        }
    }

    function swap(PoolKeyLocal memory, SwapParamsLocal memory params, bytes calldata)
        external view returns (int256 swapDelta)
    {
        // amountSpecified is always negative (exact input) on every path XBlitzrLauncher uses.
        int128 specifiedLeg = int128(params.amountSpecified);
        int128 unspecifiedLeg = int128(int256(nextSwapAmountOut));
        return params.zeroForOne ? _pack(specifiedLeg, unspecifiedLeg) : _pack(unspecifiedLeg, specifiedLeg);
    }

    function take(address currency, address to, uint256 amount) external {
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native take failed");
        } else {
            require(IERC20Like2(currency).transfer(to, amount), "take failed");
        }
    }

    function settle() external payable returns (uint256 paid) {
        return msg.value;
    }

    function sync(address) external {}

    receive() external payable {}

    function _pack(int128 amount0, int128 amount1) private pure returns (int256) {
        return (int256(amount0) << 128) | int256(uint256(uint128(amount1)));
    }
}
