// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {IRewardVault} from "../interfaces/IRewardVault.sol";
import {RewardsLib} from "./RewardsLib.sol";

// Pays the SWAPPER's own cashback share — see RewardsLib for the referrer's leg. Both draw from
// the same vault and the same weighted RewardsLib.RewardToken[] list.
library CashbackLib {
    event CashbackPaid(address indexed swapper, address rewardToken, uint256 amount);

    // `feeBase` is the router's own aggregation fee, not the swap's raw value.
    function payCashback(
        address vault,
        RewardsLib.RewardToken[] storage rewardTokens,
        address swapper,
        uint256 feeBase,
        uint256 cashbackBps
    ) internal {
        if (cashbackBps == 0 || feeBase == 0) return;
        uint256 totalAmount = feeBase * cashbackBps / RewardsLib.BPS;
        if (totalAmount == 0) return;

        uint256 len = rewardTokens.length;
        for (uint256 i; i < len; ++i) {
            RewardsLib.RewardToken storage rt = rewardTokens[i];
            uint256 amount = totalAmount * rt.weightBps / RewardsLib.BPS;
            if (amount == 0) continue;
            IRewardVault(vault).payout(rt.token, swapper, amount, swapper);
            emit CashbackPaid(swapper, rt.token, amount);
        }
    }
}
