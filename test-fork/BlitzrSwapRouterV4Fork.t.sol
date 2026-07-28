// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlitzrSwapRouter, PoolKey, Currency} from "../BlitzrSwapRouter/BlitzrSwapRouter.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";
import {XBlitzrLauncher} from "../xBlitzr/XBlitzrLauncher.sol";
import {XBlitzrHook} from "../xBlitzr/XBlitzrHook.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

interface IERC20ForkV4R {
    function balanceOf(address) external view returns (uint256);
}

// V4-hop mainnet-fork integration test for BlitzrSwapRouter — unlike the pre-existing WETH/USDC
// pairs used in BlitzrSwapRouterFork.t.sol, there's no long-lived, guaranteed-liquid V4 pool to
// discover on mainnet (V4 launched recently and pools are permissionless/ephemeral), so this
// launches a REAL pool via XBlitzrLauncher against the REAL Uniswap V4 PoolManager singleton
// (same pattern as XBlitzrLauncherFork.t.sol) and then swaps against it through
// BlitzrSwapRouter's own unlockCallback — proving the router's independent V4 integration works
// against genuine flash-accounting, not just XBlitzrLauncher's own trading path.
// Run with `FOUNDRY_PROFILE=fork forge test`.
contract BlitzrSwapRouterV4ForkTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 constant REQUIRED_FLAGS = (1 << 11) | (1 << 9) | (1 << 6) | (1 << 2);
    int24 constant TICK_SPACING = 200;
    uint24 constant FEE = 10_000;
    uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;

    BlitzrToken tokenImpl;
    XBlitzrHook hook;
    XBlitzrLauncher launcher;
    BlitzrSwapRouter router;
    BlitzrSwapRouterRewardVault vault;

    address platformWallet = makeAddr("forkRouterV4Platform");
    address launchFeeWallet = makeAddr("forkRouterV4LaunchFee");
    address creator = makeAddr("forkRouterV4Creator");
    address trader = makeAddr("forkRouterV4Trader");

    uint256 constant LAUNCH_FEE = 0.01 ether;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpc); // latest — see BlitzrLauncherFork.t.sol for why not pinned

        tokenImpl = new BlitzrToken();

        bytes memory creationCode = abi.encodePacked(
            type(XBlitzrHook).creationCode, abi.encode(POOL_MANAGER, platformWallet, address(this))
        );
        (address predictedHook, bytes32 salt) = HookMiner.find(address(this), ALL_HOOK_MASK, REQUIRED_FLAGS, creationCode);
        hook = new XBlitzrHook{salt: salt}(POOL_MANAGER, platformWallet, address(this));
        require(address(hook) == predictedHook, "hook salt mismatch");

        launcher = new XBlitzrLauncher(POOL_MANAGER, address(tokenImpl), address(hook), launchFeeWallet, LAUNCH_FEE);
        hook.setLauncher(address(launcher));

        vault = new BlitzrSwapRouterRewardVault(address(this), address(0));
        BlitzrSwapRouter impl = new BlitzrSwapRouter();
        bytes memory initData = abi.encodeWithSelector(
            BlitzrSwapRouter.initialize.selector, address(this), address(vault), POOL_MANAGER
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = BlitzrSwapRouter(payable(address(proxy)));
        vault.setRouter(address(router));

        vm.deal(creator, 100 ether);
        vm.deal(trader, 100 ether);
    }

    function test_fork_v4Hop_swapsAgainstRealFreshlyLaunchedPool() public {
        vm.prank(creator);
        (address token,) = launcher.launch{value: LAUNCH_FEE}(
            "Fork Router V4 Token", "FRV4", "ipfs://frv4", address(0), address(0), 0
        );

        // Real V4 pools require the caller past this launcher's own anti-bot window to trade
        // freely against the swap router (a fresh non-exempt buyer is otherwise capped) — mirrors
        // the same wait already used in XBlitzrLauncherFork.t.sol before its own real-trading test.
        vm.roll(block.number + launcher.antiBotBlocks() + 1);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });

        uint256 amountIn = 0.05 ether;
        bytes memory hopData = abi.encode(key, true, -int256(amountIn), MIN_SQRT_RATIO_PLUS_ONE);

        BlitzrSwapRouter.Hop[] memory hops = new BlitzrSwapRouter.Hop[](1);
        hops[0] = BlitzrSwapRouter.Hop({
            dexType: BlitzrSwapRouter.HopType.V4,
            target: address(0), // ignored for V4 — router always uses its own stored poolManager
            data: hopData,
            tokenIn: address(0),
            tokenOut: token,
            amountIn: amountIn,
            minAmountOut: 0
        });

        BlitzrSwapRouter.Valuation memory noValuation =
            BlitzrSwapRouter.Valuation({kind: BlitzrSwapRouter.ValuationType.NONE, pool: address(0), window: 0});

        vm.prank(trader);
        uint256 out = router.swap{value: amountIn}(hops, 0, address(0), noValuation);

        assertGt(out, 0);
        assertEq(IERC20ForkV4R(token).balanceOf(trader), out);
    }
}
