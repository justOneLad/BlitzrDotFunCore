// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlitzrSwapRouter} from "../BlitzrSwapRouter/BlitzrSwapRouter.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";

// Deploys the reward vault, the router implementation, and the ERC1967 proxy in front of it —
// with `initialize()` encoded directly into the proxy's own constructor call rather than as a
// separate follow-up transaction. Deploying the proxy first and calling initialize() after would
// leave a window where the implementation is live but uninitialized, and anyone could call
// initialize() themselves in that gap (initializer front-running) — encoding it atomically here
// closes that window entirely.
contract DeployBlitzrSwapRouter is Script {
    function run() external returns (address vault, address implementation, address proxy) {
        address owner = vm.envAddress("ROUTER_OWNER");
        address poolManager = vm.envAddress("POOL_MANAGER");

        vm.startBroadcast();

        // router set to address(0) for now — this contract doesn't know the proxy's address
        // until after it's deployed below; wired up with setRouter() immediately after.
        BlitzrSwapRouterRewardVault vaultC = new BlitzrSwapRouterRewardVault(owner, address(0));

        BlitzrSwapRouter impl = new BlitzrSwapRouter();
        bytes memory initData =
            abi.encodeWithSelector(BlitzrSwapRouter.initialize.selector, owner, address(vaultC), poolManager);
        ERC1967Proxy proxyC = new ERC1967Proxy(address(impl), initData);

        vaultC.setRouter(address(proxyC));

        // Reward tokens (and their weights) are configured post-deploy via setRewardTokens(),
        // same as allowedTargets — not baked into initialize().

        vm.stopBroadcast();

        vault = address(vaultC);
        implementation = address(impl);
        proxy = address(proxyC);

        console.log("BlitzrSwapRouterRewardVault:");
        console.logAddress(vault);
        console.log("BlitzrSwapRouter implementation:");
        console.logAddress(implementation);
        console.log("BlitzrSwapRouter proxy (the address to actually interact with):");
        console.logAddress(proxy);
    }
}
