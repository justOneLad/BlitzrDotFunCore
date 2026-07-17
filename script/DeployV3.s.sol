// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Script, console} from "forge-std/Script.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";
import {BlitzrLocker} from "../contracts/BlitzrLocker.sol";
import {BlitzrLauncher} from "../contracts/BlitzrLauncher.sol";

contract DeployV3 is Script {
    function run() external returns (address tokenImpl, address locker, address launcher) {
        address weth = vm.envAddress("WETH");
        address factory = vm.envAddress("FACTORY");
        address posMgr = vm.envAddress("POS_MGR");
        address router = vm.envAddress("ROUTER");
        address platformWallet = vm.envAddress("PLATFORM_WALLET");
        address launchFeeWallet = vm.envAddress("LAUNCH_FEE_WALLET");
        uint256 launchFee = vm.envUint("LAUNCH_FEE");

        vm.startBroadcast();
        tokenImpl = address(new BlitzrToken());
        BlitzrLocker lockerC = new BlitzrLocker(platformWallet);
        BlitzrLauncher launcherC = new BlitzrLauncher(
            weth, tokenImpl, address(lockerC), launchFeeWallet, factory, posMgr, router, launchFee
        );
        lockerC.setLauncher(address(launcherC), true);
        vm.stopBroadcast();

        locker = address(lockerC);
        launcher = address(launcherC);

        console.log("BlitzrToken impl:");
        console.logAddress(tokenImpl);
        console.log("BlitzrLocker:");
        console.logAddress(locker);
        console.log("BlitzrLauncher:");
        console.logAddress(launcher);
    }
}
