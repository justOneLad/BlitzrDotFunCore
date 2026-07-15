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

struct ModifyLiquidityParams {
    int24   tickLower;
    int24   tickUpper;
    int256  liquidityDelta;
    bytes32 salt;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

// Attempts a zero-delta "poke" (fee collection without changing principal) on the launcher's
// own locked position. Should revert — XBlitzrHook.beforeRemoveLiquidity reverts unconditionally,
// including for the launcher itself, including for delta == 0.
contract Poker is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(address poolManager_) {
        poolManager = IPoolManager(poolManager_);
    }

    function attemptPoke(PoolKey calldata key, int24 tickLower, int24 tickUpper) external {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper) = abi.decode(data, (PoolKey, int24, int24));

        // liquidityDelta = 0 -- the "poke" pattern. Hooks.sol routes delta <= 0 through the
        // beforeRemoveLiquidity path, which XBlitzrHook always reverts.
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)}),
            ""
        );

        return "";
    }
}

contract RemoveLiquidityTest is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address token = vm.envAddress("TOKEN");
        address hook = vm.envAddress("HOOK");
        int24 tickLower = int24(vm.envInt("TICK_LOWER"));
        int24 tickUpper = int24(vm.envInt("TICK_UPPER"));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 10_000,
            tickSpacing: 200,
            hooks: hook
        });

        vm.startBroadcast();
        Poker poker = new Poker(poolManager);
        console.log("Poker deployed at:");
        console.logAddress(address(poker));

        // Expect this to revert.
        poker.attemptPoke(key, tickLower, tickUpper);
        vm.stopBroadcast();

        console.log("UNEXPECTED: poke succeeded, permanent lock is broken!");
    }
}
