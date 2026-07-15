# BlitzrDotFunCore

Smart contracts for [blitzr.fun](https://blitzr.fun) — deploy a token and seed permanent,
one-sided liquidity in a single transaction. Two parallel stacks:

| Stack | Directory | DEX | Docs |
|---|---|---|---|
| Blitzr | [`contracts/`](contracts/) | Uniswap V3 | [`contracts/BLITZR.md`](contracts/BLITZR.md) |
| xBlitzr | [`xBlitzr/`](xBlitzr/) | Uniswap V4 (hooks) | [`xBlitzr/XBLITZR.md`](xBlitzr/XBLITZR.md) |

Both clone the same shared `BlitzrToken.sol` implementation.

## Layout

```
contracts/    BlitzrToken, BlitzrLocker, BlitzrLauncher (V3 stack)
xBlitzr/      XBlitzrHook, XBlitzrLauncher (V4 stack)
script/       Deployment scripts (DeployV3, DeployHook, DeployLauncher)
script/fork-tests/  One-off scripts used for manual mainnet-fork exercising
```

## Development

Built with [Foundry](https://book.getfoundry.sh/).

```
forge build
forge test
```
