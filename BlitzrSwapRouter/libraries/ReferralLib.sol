// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// First-touch: a swapper's referrer is set once and is immutable thereafter.
library ReferralLib {
    event ReferralBound(address indexed swapper, address indexed referrer);

    // No-ops rather than reverting on self-referral or an already-bound swapper — never a reason
    // to fail an otherwise-valid trade.
    function recordReferral(mapping(address => address) storage referrerOf, address swapper, address referrer)
        internal
    {
        if (referrer == address(0) || referrer == swapper) return;
        if (referrerOf[swapper] != address(0)) return;
        referrerOf[swapper] = referrer;
        emit ReferralBound(swapper, referrer);
    }
}
