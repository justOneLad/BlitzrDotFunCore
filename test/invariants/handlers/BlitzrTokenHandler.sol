// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrToken} from "../../../contracts/BlitzrToken.sol";

// Bounded random actor for BlitzrToken invariant fuzzing — every action is confined to a fixed
// actor set (never a fresh/unbounded address) so the invariant can sum exactly those balances
// without needing to auto-discover every historical holder.
contract BlitzrTokenHandler is Test {
    BlitzrToken public immutable token;
    address[] public actors;

    constructor(BlitzrToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        amount = amount % (bal + 1);
        vm.prank(from);
        try token.transfer(to, amount) {} catch {} // anti-bot cap etc. — expected, not a bug
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner_ = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner_);
        try token.approve(spender, amount) {} catch {}
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 bal = token.balanceOf(from);
        uint256 cap = allowed < bal ? allowed : bal;
        if (cap == 0) return;
        amount = amount % (cap + 1);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {} catch {}
    }
}
