// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Script, console} from "forge-std/Script.sol";

type Currency is address;
type BalanceDelta is int256;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24   fee;
    int24    tickSpacing;
    address  hooks;
}

struct SwapParams {
    bool    zeroForOne;
    int256  amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (BalanceDelta swapDelta);
    function take(Currency currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256 paid);
    function sync(Currency currency) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

// Sells the token back into the pool for native ETH — exercises the opposite trade direction
// from SwapTest.s.sol's buy, so the pool's LP fee accrues in the TOKEN currency instead of
// native, letting collectPoolFees()'s burn path actually fire.
contract SellTrader is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable recipient;
    address public immutable token;

    constructor(address poolManager_, address recipient_, address token_) {
        poolManager = IPoolManager(poolManager_);
        recipient = recipient_;
        token = token_;
    }

    function doSell(PoolKey calldata key, uint256 tokenAmountIn) external {
        poolManager.unlock(abi.encode(key, tokenAmountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (PoolKey memory key, uint256 tokenAmountIn) = abi.decode(data, (PoolKey, uint256));

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: false, // token (currency1) -> native (currency0)
                amountSpecified: -int256(tokenAmountIn),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341 // MAX_SQRT_RATIO - 1
            }),
            ""
        );

        poolManager.sync(key.currency1);
        IERC20(token).transfer(address(poolManager), tokenAmountIn);
        poolManager.settle();

        int128 amount0;
        assembly {
            amount0 := sar(128, delta)
        }
        if (amount0 > 0) {
            poolManager.take(key.currency0, recipient, uint256(uint128(amount0)));
        }

        return abi.encode(amount0);
    }
}

contract SellSwapTest is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address token = vm.envAddress("TOKEN");
        address hook = vm.envAddress("HOOK");
        uint256 tokenAmountIn = vm.envUint("TOKEN_AMOUNT_IN");
        address recipient = vm.envAddress("TRADER");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 10_000,
            tickSpacing: 200,
            hooks: hook
        });

        vm.startBroadcast();
        SellTrader trader = new SellTrader(poolManager, recipient, token);
        IERC20(token).transfer(address(trader), tokenAmountIn);
        trader.doSell(key, tokenAmountIn);
        vm.stopBroadcast();

        console.log("SellTrader deployed at:");
        console.logAddress(address(trader));
    }
}
