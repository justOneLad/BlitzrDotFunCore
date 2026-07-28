# BlitzrDotFunCore

Smart contracts for [blitzr.fun](https://blitzr.fun). Two parallel launch stacks:

| Stack | Directory | Model | Docs |
|---|---|---|---|
| Blitzr | [`contracts/`](contracts/) | Uniswap V3, permanent one-sided liquidity | [`contracts/BLITZR.md`](contracts/BLITZR.md) |
| xBlitzr | [`xBlitzr/`](xBlitzr/) | Uniswap V4 (hooks), permanent one-sided liquidity | [`xBlitzr/XBLITZR.md`](xBlitzr/XBLITZR.md) |

Blitzr and xBlitzr clone the same shared `BlitzrToken.sol` implementation (or, for guarded
launches, `contracts/BlitzrTokenGuarded.sol`).

Alongside the two launch stacks, [`BlitzrSwapRouter/`](BlitzrSwapRouter/) is a standalone,
UUPS-upgradeable DEX-aggregator router (Uniswap V2/V3/V4 + any allowlisted DEX) with Permit2,
split routing, and multi-token referral/cashback rewards — see
[`BlitzrSwapRouter/BlitzrSwapRouter.md`](BlitzrSwapRouter/BlitzrSwapRouter.md).

## Layout

```
contracts/        BlitzrToken, BlitzrTokenGuarded, BlitzrLocker, BlitzrLauncher (V3 stack),
                   BlitzrTreasury (timelocked platform-revenue vault, shared by both stacks)
xBlitzr/           XBlitzrHook, XBlitzrLauncher (V4 stack)
BlitzrSwapRouter/  DEX-aggregator swap router (Uniswap V2/V3/V4 + any allowlisted DEX),
                   UUPS-upgradeable, with Permit2, split routing, and referral/cashback rewards
script/            Deployment scripts (DeployV3, DeployHook, DeployLauncher, DeployBlitzrSwapRouter)
script/fork-tests/ One-off scripts used for manual mainnet-fork exercising
```

## Development

Built with [Foundry](https://book.getfoundry.sh/).

```
forge build
forge test
```
