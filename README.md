# BlitzrDotFunCore

Smart contracts for [blitzr.fun](https://blitzr.fun). Three parallel launch stacks:

| Stack | Directory | Model | Docs |
|---|---|---|---|
| Blitzr | [`contracts/`](contracts/) | Uniswap V3, permanent one-sided liquidity | [`contracts/BLITZR.md`](contracts/BLITZR.md) |
| xBlitzr | [`xBlitzr/`](xBlitzr/) | Uniswap V4 (hooks), permanent one-sided liquidity | [`xBlitzr/XBLITZR.md`](xBlitzr/XBLITZR.md) |
| Blitzr Bonding Curve | [`bonding-curve/`](bonding-curve/) | Internal bonding curve, migrates to a DEX at a market-cap target | [`bonding-curve/BONDING_CURVE.md`](bonding-curve/BONDING_CURVE.md) |

Blitzr and xBlitzr clone the same shared `BlitzrToken.sol` implementation; the bonding curve
stack has its own token types (see its doc). The bonding curve stack also reuses
`contracts/BlitzrLocker.sol` to lock the V3 LP position at a BlitzrStandardToken's migration,
rather than a stack-specific vault.

## Layout

```
contracts/       BlitzrToken, BlitzrLocker, BlitzrLauncher (V3 stack)
xBlitzr/          XBlitzrHook, XBlitzrLauncher (V4 stack)
bonding-curve/    BlitzrBondingCurve, tokens/ (bonding-curve stack; reuses contracts/BlitzrLocker.sol)
script/           Deployment scripts (DeployV3, DeployHook, DeployLauncher)
script/fork-tests/  One-off scripts used for manual mainnet-fork exercising
```

## Development

Built with [Foundry](https://book.getfoundry.sh/).

```
forge build
forge test
```
