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
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

// Deployed on-chain so PoolManager's unlock() callback has a real contract to call back into —
// simulates a regular swapper buying the launched token with native ETH, exercising
// XBlitzrHook.afterSwap's live fee capture on a real swap (not the launcher's own instant buy).
contract Trader is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable recipient;

    constructor(address poolManager_, address recipient_) {
        poolManager = IPoolManager(poolManager_);
        recipient = recipient_;
    }

    function doSwap(PoolKey calldata key, uint256 swapAmount) external payable {
        poolManager.unlock(abi.encode(key, swapAmount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (PoolKey memory key, uint256 swapAmount) = abi.decode(data, (PoolKey, uint256));

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, // native (currency0) -> token (currency1)
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: 4295128740 // MIN_SQRT_RATIO + 1
            }),
            ""
        );

        poolManager.settle{value: swapAmount}();

        int128 amount1;
        assembly {
            amount1 := signextend(15, delta)
        }
        if (amount1 > 0) {
            poolManager.take(key.currency1, recipient, uint256(uint128(amount1)));
        }

        return abi.encode(amount1);
    }

    receive() external payable {}
}

contract SwapTest is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address token = vm.envAddress("TOKEN");
        address hook = vm.envAddress("HOOK");
        uint256 swapAmount = vm.envUint("SWAP_AMOUNT");
        address recipient = vm.envAddress("TRADER");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 10_000,
            tickSpacing: 200,
            hooks: hook
        });

        vm.startBroadcast();
        Trader trader = new Trader(poolManager, recipient);
        trader.doSwap{value: swapAmount}(key, swapAmount);
        vm.stopBroadcast();

        console.log("Trader deployed at:");
        console.logAddress(address(trader));
    }
}
