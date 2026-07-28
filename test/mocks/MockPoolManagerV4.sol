// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Records take() calls for XBlitzrHook tests. Currency is a user-defined value type wrapping
// address, which ABI-encodes identically to `address` — so this plain-address signature matches
// the same selector XBlitzrHook's IPoolManager.take(Currency,address,uint256) call targets.
contract MockPoolManagerV4 {
    address public lastCurrency;
    address public lastTo;
    uint256 public lastAmount;
    uint256 public takeCallCount;

    // Cumulative total taken per (currency, recipient) — lets multi-swap scenario tests verify
    // accumulated fee capture across several afterSwap calls, not just the most recent one.
    mapping(address => mapping(address => uint256)) public totalTaken;

    function take(address currency, address to, uint256 amount) external {
        lastCurrency = currency;
        lastTo = to;
        lastAmount = amount;
        takeCallCount++;
        totalTaken[currency][to] += amount;
    }
}
