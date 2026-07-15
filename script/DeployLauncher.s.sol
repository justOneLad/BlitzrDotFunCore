// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Script, console} from "forge-std/Script.sol";
import {XBlitzrLauncher} from "../xBlitzr/XBlitzrLauncher.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";

contract DeployLauncher is Script {
    function run() external returns (address tokenImpl, address launcher) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("HOOK");
        address launchFeeWallet = vm.envAddress("LAUNCH_FEE_WALLET");
        uint256 launchFee = vm.envUint("LAUNCH_FEE");

        vm.startBroadcast();
        tokenImpl = address(new BlitzrToken());
        launcher = address(new XBlitzrLauncher(poolManager, tokenImpl, hook, launchFeeWallet, launchFee));
        vm.stopBroadcast();

        console.log("BlitzrToken impl:");
        console.logAddress(tokenImpl);
        console.log("XBlitzrLauncher:");
        console.logAddress(launcher);
    }
}
