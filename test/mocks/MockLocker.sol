// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Records registerPosition() calls for BlitzrLauncher tests without pulling in BlitzrLocker's
// own logic (that's covered separately in BlitzrLocker.t.sol).
contract MockLocker {
    struct Call {
        address token;
        uint256 tokenId;
        address feeWallet;
        address token0;
        address token1;
        address pool;
        address positionManager;
    }

    Call[] public calls;

    function registerPosition(
        address token,
        uint256 tokenId,
        address feeWallet,
        address token0,
        address token1,
        address pool,
        address positionManager
    ) external {
        calls.push(Call(token, tokenId, feeWallet, token0, token1, pool, positionManager));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }
}
