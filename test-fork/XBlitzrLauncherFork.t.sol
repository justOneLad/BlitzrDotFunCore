// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test, console} from "forge-std/Test.sol";
import {XBlitzrLauncher} from "../xBlitzr/XBlitzrLauncher.sol";
import {XBlitzrHook} from "../xBlitzr/XBlitzrHook.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {IPoolManager as IV4PoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "../lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "../lib/v4-core/src/libraries/StateLibrary.sol";

type ForkCurrency is address;
struct ForkPoolKey {
    ForkCurrency currency0;
    ForkCurrency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}
struct ForkModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}
struct ForkSwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerFork {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(ForkPoolKey memory key, ForkSwapParams memory params, bytes calldata hookData)
        external returns (int256 swapDelta);
    function modifyLiquidity(ForkPoolKey memory key, ForkModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
    function take(ForkCurrency currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256 paid);
    function sync(ForkCurrency currency) external;
}

interface IUnlockCallbackFork {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IERC20ForkV4 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

// Buys/sells the launched token against a real pool via a real unlock() callback — adapted from
// script/fork-tests/SwapTest.s.sol and SellSwapTest.s.sol, as a reusable in-test helper instead
// of a manually-run broadcast script.
contract ForkV4Trader is IUnlockCallbackFork {
    IPoolManagerFork public immutable poolManager;
    address public immutable recipient;
    address public immutable token;

    uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    constructor(address poolManager_, address recipient_, address token_) {
        poolManager = IPoolManagerFork(poolManager_);
        recipient = recipient_;
        token = token_;
    }

    function buy(ForkPoolKey calldata key, uint256 ethIn) external payable {
        poolManager.unlock(abi.encode(uint8(0), abi.encode(key, ethIn)));
    }

    function sell(ForkPoolKey calldata key, uint256 tokenAmountIn) external {
        poolManager.unlock(abi.encode(uint8(1), abi.encode(key, tokenAmountIn)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (action == 0) {
            (ForkPoolKey memory key, uint256 ethIn) = abi.decode(payload, (ForkPoolKey, uint256));
            int256 delta = poolManager.swap(
                key,
                ForkSwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: MIN_SQRT_RATIO_PLUS_ONE}),
                ""
            );
            poolManager.settle{value: ethIn}();
            int128 out = _amount1(delta);
            if (out > 0) poolManager.take(key.currency1, recipient, uint256(uint128(out)));
            return abi.encode(out);
        } else {
            (ForkPoolKey memory key, uint256 tokenIn) = abi.decode(payload, (ForkPoolKey, uint256));
            int256 delta = poolManager.swap(
                key,
                ForkSwapParams({zeroForOne: false, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: MAX_SQRT_RATIO_MINUS_ONE}),
                ""
            );
            poolManager.sync(key.currency1);
            IERC20ForkV4(token).transfer(address(poolManager), tokenIn);
            poolManager.settle();
            int128 out = _amount0(delta);
            if (out > 0) poolManager.take(key.currency0, recipient, uint256(uint128(out)));
            return abi.encode(out);
        }
    }

    function _amount0(int256 delta) private pure returns (int128) {
        return int128(delta >> 128);
    }

    function _amount1(int256 delta) private pure returns (int128) {
        return int128(delta);
    }

    receive() external payable {}
}

// Attempts an unauthorized zero-delta poke or an outright liquidity removal directly against the
// real PoolManager, bypassing XBlitzrLauncher entirely — adapted from
// script/fork-tests/{Add,Remove}LiquidityTest.s.sol. Both must revert: XBlitzrHook's
// beforeRemoveLiquidity only ever allows sender == launcher, for any liquidityDelta <= 0.
contract ForkV4Poker is IUnlockCallbackFork {
    IPoolManagerFork public immutable poolManager;

    constructor(address poolManager_) {
        poolManager = IPoolManagerFork(poolManager_);
    }

    function attempt(ForkPoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) external {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidityDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (ForkPoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (ForkPoolKey, int24, int24, int256));
        poolManager.modifyLiquidity(
            key,
            ForkModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)}),
            ""
        );
        return "";
    }
}

// Mainnet-fork integration test — deploys XBlitzrHook (via a real mined CREATE2 salt, exactly as
// production requires) and XBlitzrLauncher against the REAL Uniswap V4 PoolManager singleton,
// then runs real swaps and a real fee-collection poke through it. This is the only way to verify
// the hook's beforeAddLiquidity/beforeRemoveLiquidity/afterSwap callbacks actually get invoked
// correctly by a genuine PoolManager — the mocked unit tests never call the hook at all,
// they exercise its functions directly. Run with `FOUNDRY_PROFILE=fork forge test`.
contract XBlitzrLauncherForkTest is Test {
    // Verified to have live code (checked via eth_getCode against a public mainnet RPC before
    // writing this test) — canonical Uniswap V4 mainnet PoolManager singleton.
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 constant REQUIRED_FLAGS = (1 << 11) | (1 << 9) | (1 << 6) | (1 << 2);
    int24 constant MIN_TICK = -887_200;
    int24 constant TICK_SPACING = 200;

    BlitzrToken tokenImpl;
    XBlitzrHook hook;
    XBlitzrLauncher launcher;

    address platformWallet = makeAddr("forkV4PlatformWallet");
    address launchFeeWallet = makeAddr("forkV4LaunchFeeWallet");
    address creator = makeAddr("forkV4Creator");

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

        vm.deal(creator, 100 ether);
    }

    function _key(address token) private view returns (ForkPoolKey memory) {
        return ForkPoolKey({
            currency0: ForkCurrency.wrap(address(0)),
            currency1: ForkCurrency.wrap(token),
            fee: 10_000,
            tickSpacing: 200,
            hooks: address(hook)
        });
    }

    // Matches XBlitzrLauncher._floorToTickSpacing exactly.
    function _floorToTickSpacing(int24 tick) private pure returns (int24) {
        int24 compressed = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) compressed--;
        return compressed * TICK_SPACING;
    }

    function test_fork_launchCreatesRealV4Pool() public {
        uint256 feeWalletBefore = launchFeeWallet.balance;

        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: LAUNCH_FEE}(
            "Fork V4 Token", "FV4", "ipfs://fv4", address(0), address(0), 0
        );

        assertEq(launchFeeWallet.balance, feeWalletBefore + LAUNCH_FEE);
        assertTrue(poolId != bytes32(0));
        assertEq(BlitzrToken(token).owner(), address(0)); // renounced
        assertTrue(BlitzrToken(token).isExempt(POOL_MANAGER));
        // The real PoolManager now holds the one-sided supply (a few wei of real liquidity-math
        // rounding aside — see the V3 fork test for the same, non-launcher-specific, phenomenon).
        assertApproxEqAbs(IERC20ForkV4(token).balanceOf(POOL_MANAGER), BlitzrToken(token).totalSupply(), 1e18);

        (address feeWallet,,) = hook.positions(token);
        assertEq(feeWallet, creator);
    }

    function test_fork_thirdPartyCannotPokeOrRemoveLockedLiquidity() public {
        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: LAUNCH_FEE}(
            "Fork V4 Lock Test", "FLOCK", "ipfs://flock", address(0), address(0), 0
        );
        ForkPoolKey memory key = _key(token);

        // Recover the real registered position's tick range by reading the real PoolManager's
        // actual on-chain slot0 (via extsload, same mechanism Uniswap's own StateLibrary uses) —
        // native quote means token is always currency1, so the range is
        // [MIN_TICK, floor(currentTick to nearest tickSpacing)], matching
        // XBlitzrLauncher._executeLaunch's token-is-currency1 branch exactly.
        (, int24 currentTick,,) = StateLibrary.getSlot0(IV4PoolManager(POOL_MANAGER), PoolId.wrap(poolId));
        int24 realTickLower = MIN_TICK;
        int24 realTickUpper = _floorToTickSpacing(currentTick);

        ForkV4Poker poker = new ForkV4Poker(POOL_MANAGER);

        vm.expectRevert(); // zero-delta poke from a non-launcher sender
        poker.attempt(key, realTickLower, realTickUpper, 0);

        vm.expectRevert(); // outright removal attempt
        poker.attempt(key, realTickLower, realTickUpper, -1000);
    }

    function test_fork_realTradingAndFeeCollectionAgainstRealPoolManager() public {
        // Small instant buy for the same reason as the V3 fork test — default marketCapRef is
        // only 5 ETH for the full 1B supply.
        vm.prank(creator);
        (address token,) = launcher.launch{value: LAUNCH_FEE + 0.02 ether}(
            "Fork V4 Trade Token", "FV4T", "ipfs://fv4t", address(0), address(0), 0
        );
        assertGt(BlitzrToken(token).balanceOf(creator), 0);

        vm.roll(block.number + launcher.antiBotBlocks() + 1);

        ForkPoolKey memory key = _key(token);
        address trader = makeAddr("forkV4Trader");
        vm.deal(trader, 10 ether);

        ForkV4Trader traderContract = new ForkV4Trader(POOL_MANAGER, trader, token);
        vm.deal(address(traderContract), 5 ether);
        traderContract.buy{value: 5 ether}(key, 5 ether);
        uint256 bought = IERC20ForkV4(token).balanceOf(trader);
        assertGt(bought, 0);

        // Sell some back so LP fees accrue on the token leg too.
        uint256 sellAmount = bought / 4;
        vm.prank(trader);
        IERC20ForkV4(token).transfer(address(traderContract), sellAmount);
        traderContract.sell(key, sellAmount);
        assertGt(trader.balance, 0); // received real ETH back from the sell

        // Realize the real accrued LP fees via a genuine zero-delta poke against the real
        // PoolManager + hook — this is the one thing the mocked unit tests structurally cannot
        // exercise, since the mock never actually invokes XBlitzrHook's callbacks at all.
        uint256 creatorEthBefore = creator.balance;
        uint256 creatorTokenBefore = BlitzrToken(token).balanceOf(creator);
        uint256 platformEthBefore = platformWallet.balance;

        (uint256 quotePaid, uint256 tokenAmount) = launcher.collectPoolFees(token);
        assertTrue(quotePaid > 0 || tokenAmount > 0);

        assertEq(creator.balance - creatorEthBefore, quotePaid * 8000 / 10_000);
        assertEq(BlitzrToken(token).balanceOf(creator) - creatorTokenBefore, tokenAmount * 8000 / 10_000);
        if (quotePaid > 0) assertGt(platformWallet.balance - platformEthBefore, 0);

        // A second collection right after must pay out ~nothing new.
        (uint256 quotePaid2, uint256 tokenAmount2) = launcher.collectPoolFees(token);
        assertEq(quotePaid2, 0);
        assertEq(tokenAmount2, 0);
    }
}
