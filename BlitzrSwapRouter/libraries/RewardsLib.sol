// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {IRewardVault} from "../interfaces/IRewardVault.sol";

// Pays the REFERRER's share — see CashbackLib for the swapper's own share. Reward tokens are an
// owner-curated weighted list (sum of weightBps <= BPS); a single reward event splits across
// every entry by weight, e.g. 70% USDC + 30% a platform token.
library RewardsLib {
    uint256 internal constant BPS = 10_000;

    struct RewardToken {
        address token;
        uint256 weightBps;
    }

    event ReferralRewardPaid(address indexed referrer, address indexed swapper, address rewardToken, uint256 amount);

    // `feeBase` is the router's own aggregation fee, not the swap's raw value.
    function payReferralReward(
        address vault,
        RewardToken[] storage rewardTokens,
        address referrer,
        address swapper,
        uint256 feeBase,
        uint256 referralBps
    ) internal {
        if (referrer == address(0) || referralBps == 0 || feeBase == 0) return;
        uint256 totalAmount = feeBase * referralBps / BPS;
        if (totalAmount == 0) return;

        uint256 len = rewardTokens.length;
        for (uint256 i; i < len; ++i) {
            RewardToken storage rt = rewardTokens[i];
            uint256 amount = totalAmount * rt.weightBps / BPS;
            if (amount == 0) continue;
            IRewardVault(vault).payout(rt.token, referrer, amount, swapper);
            emit ReferralRewardPaid(referrer, swapper, rt.token, amount);
        }
    }
}
