# BlitzrDotFunCore

Smart contracts for [blitzr.fun](https://blitzr.fun). Two parallel launch stacks:

| Stack | Directory | Model | Docs |
|---|---|---|---|
| Blitzr | [`contracts/`](contracts/) | Uniswap V3, permanent one-sided liquidity | [`contracts/BLITZR.md`](contracts/BLITZR.md) |
| xBlitzr | [`xBlitzr/`](xBlitzr/) | Uniswap V4 (hooks), permanent one-sided liquidity | [`xBlitzr/XBLITZR.md`](xBlitzr/XBLITZR.md) |

Blitzr and xBlitzr clone the same shared `BlitzrToken.sol` implementation.

## Layout

```
contracts/       BlitzrToken, BlitzrLocker, BlitzrLauncher (V3 stack)
xBlitzr/          XBlitzrHook, XBlitzrLauncher (V4 stack)
script/           Deployment scripts (DeployV3, DeployHook, DeployLauncher)
script/fork-tests/  One-off scripts used for manual mainnet-fork exercising
```

## Development

Built with [Foundry](https://book.getfoundry.sh/).

```
forge build
forge test
```
