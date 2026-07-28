// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IRewardVault {
    function payout(address token, address to, uint256 amount, address swapper) external;
}
