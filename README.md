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

### Arc variant

`BlitzrLauncher` and the bonding curve stack each have an `*Arc.sol` sibling
(`BlitzrLauncherArc.sol`, `BlitzrBondingCurveArc.sol`, `BlitzrTaxTokenArc.sol`) for deployment on
Arc, whose native gas token IS USDC (6 decimals) rather than ETH/BNB, mirrored as an ERC20 at the
fixed address `0x3600000000000000000000000000000000000000`. No WETH exists on Arc, so these
variants never wrap/unwrap native value and use plain ERC20 DEX calls throughout instead of the
ETH-suffixed ones (`addLiquidity`/`swapExactTokensForTokens...` instead of
`addLiquidityETH`/`swapExact...ETH...`). The bonding curve variant also drops the live
USDC/WBNB price oracle entirely — since native already **is** USDC, USD market-cap targets
convert via a fixed decimal shift instead of a pair read. See each doc's "Arc Variant" section
for the full list of differences. xBlitzr (V4) has no Arc variant.

## Layout

```
contracts/       BlitzrToken, BlitzrLocker, BlitzrLauncher (V3 stack), BlitzrLauncherArc (Arc variant)
xBlitzr/          XBlitzrHook, XBlitzrLauncher (V4 stack)
bonding-curve/    BlitzrBondingCurve, BlitzrBondingCurveArc, tokens/ (bonding-curve stack;
                  reuses contracts/BlitzrLocker.sol)
script/           Deployment scripts (DeployV3, DeployHook, DeployLauncher)
script/fork-tests/  One-off scripts used for manual mainnet-fork exercising
```

## Development

Built with [Foundry](https://book.getfoundry.sh/).

```
forge build
forge test
```
