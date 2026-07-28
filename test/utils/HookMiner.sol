// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Brute-force CREATE2 salt search for deploying a Uniswap V4 hook to an address whose low bits
// encode the desired permission flags — same technique real v4 test suites use (the production
// deployment path in XBLITZR.md uses a similar miner against the canonical deterministic deployer).
library HookMiner {
    function find(address deployer, uint160 mask, uint160 flags, bytes memory creationCodeWithArgs)
        internal pure returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCodeWithArgs);
        for (uint256 i; i < 400_000; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & mask == flags) return (hookAddress, salt);
        }
        revert("HookMiner: no salt found in range");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
