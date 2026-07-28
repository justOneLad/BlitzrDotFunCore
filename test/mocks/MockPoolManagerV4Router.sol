// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC20Like4 {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUnlockCallbackRouter {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

// Test double for Uniswap V4's PoolManager, scoped to BlitzrSwapRouter's own unlockCallback
// shape (a plain abi.encode(Hop), not XBlitzrLauncher's action-byte-tagged variant — a separate,
// simpler mock rather than reusing MockPoolManagerV4Launcher.sol, since the callback payload
// shape differs). Same no-real-flash-accounting simplification as that mock: `take()` pays out
// of this contract's own real balance (pre-funded by the test), `settle()`/`sync()` are no-ops.
contract MockPoolManagerV4Router {
    struct PoolKeyLocal {
        address currency0;
        address currency1;
        uint24  fee;
        int24   tickSpacing;
        address hooks;
    }
    struct SwapParamsLocal {
        bool    zeroForOne;
        int256  amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    uint256 public nextSwapAmountOut;

    function setNextSwapAmountOut(uint256 amountOut) external {
        nextSwapAmountOut = amountOut;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallbackRouter(msg.sender).unlockCallback(data);
    }

    function swap(PoolKeyLocal memory, SwapParamsLocal memory params, bytes calldata)
        external
        view
        returns (int256 swapDelta)
    {
        // amountSpecified is always negative (exact input) on the router's only call site.
        int128 specifiedLeg = int128(params.amountSpecified);
        int128 unspecifiedLeg = int128(int256(nextSwapAmountOut));
        return params.zeroForOne ? _pack(specifiedLeg, unspecifiedLeg) : _pack(unspecifiedLeg, specifiedLeg);
    }

    function take(address currency, address to, uint256 amount) external {
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native take failed");
        } else {
            require(IERC20Like4(currency).transfer(to, amount), "take failed");
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
