// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Test double for XBlitzrHook's IXBlitzrHook surface as XBlitzrLauncher sees it — registration
// bookkeeping and platformWallet lookup only. Real hook access control (onlyLauncher, CTO flow,
// swap fee capture) is covered separately in XBlitzrHook.t.sol; XBlitzrLauncher never calls
// through PoolManager into the hook's callbacks itself, only these three functions directly.
contract MockXBlitzrHookForLauncher {
    struct PoolKeyLocal {
        address currency0;
        address currency1;
        uint24  fee;
        int24   tickSpacing;
        address hooks;
    }

    struct Position {
        address feeWallet;
        address currency0;
        address currency1;
    }

    mapping(address => Position) public positionsMap;
    address public platformWallet;

    // Real XBlitzrHook is the single source of truth for this split (see its contract-level
    // comment) — XBlitzrLauncher._executePoke reads it live via creatorBps()/platformBps().
    uint256 public creatorBps = 8_000;
    uint256 public platformBps = 2_000;

    constructor(address platformWallet_) {
        platformWallet = platformWallet_;
    }

    function registerPosition(address token, PoolKeyLocal calldata key, address feeWallet) external {
        positionsMap[token] = Position(feeWallet, key.currency0, key.currency1);
    }

    function positions(address token) external view returns (address feeWallet, address currency0, address currency1) {
        Position storage p = positionsMap[token];
        return (p.feeWallet, p.currency0, p.currency1);
    }

    function setFeeBps(uint256 creator_, uint256 platform_) external {
        creatorBps = creator_;
        platformBps = platform_;
    }
}
