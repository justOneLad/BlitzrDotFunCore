// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Script, console} from "forge-std/Script.sol";
import {XBlitzrHook} from "../xBlitzr/XBlitzrHook.sol";

// Mines a CREATE2 salt producing a valid XBlitzrHook address (flags: before-add-liquidity,
// before-remove-liquidity, after-swap, after-swap-returns-delta) and deploys it via the
// standard deterministic deployment proxy at 0x4e59b44847b379578588920cA78FbF26c0B4956C.
contract DeployHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 constant REQUIRED_FLAGS =
        (1 << 11) | // BEFORE_ADD_LIQUIDITY_FLAG
        (1 << 9)  | // BEFORE_REMOVE_LIQUIDITY_FLAG
        (1 << 6)  | // AFTER_SWAP_FLAG
        (1 << 2);   // AFTER_SWAP_RETURNS_DELTA_FLAG

    function run() external returns (address hook) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address platformWallet = vm.envAddress("PLATFORM_WALLET");
        address hookOwner = vm.envAddress("HOOK_OWNER");

        bytes memory initCode = abi.encodePacked(
            type(XBlitzrHook).creationCode,
            abi.encode(poolManager, platformWallet, hookOwner)
        );
        bytes32 initCodeHash = keccak256(initCode);

        bytes32 salt;
        address predicted;
        bool found;
        for (uint256 i = 0; i < 500_000; i++) {
            salt = bytes32(i);
            predicted = vm.computeCreate2Address(salt, initCodeHash, CREATE2_DEPLOYER);
            if (uint160(predicted) & ALL_HOOK_MASK == REQUIRED_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "no salt found in range");

        console.log("Mined salt (uint):");
        console.logUint(uint256(salt));
        console.log("Predicted hook address:");
        console.logAddress(predicted);

        vm.startBroadcast();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok, "CREATE2 deploy failed");
        vm.stopBroadcast();

        // the deterministic deployer returns the deployed address
        hook = address(uint160(bytes20(ret)));
        require(hook == predicted, "deployed address mismatch");
        console.log("Deployed XBlitzrHook at:");
        console.logAddress(hook);
    }
}
