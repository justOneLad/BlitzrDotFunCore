// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test, console} from "forge-std/Test.sol";
import {BlitzrLauncher} from "../contracts/BlitzrLauncher.sol";
import {BlitzrLocker} from "../contracts/BlitzrLocker.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";

interface IWETH9Fork {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IERC20Fork {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IERC721Fork {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface ISwapRouter02Fork {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// Mainnet-fork integration test — deploys the real V3 stack against the REAL Uniswap V3 Factory,
// NonfungiblePositionManager, SwapRouter02, and WETH9 (not mocks), then runs actual trades
// through the real AMM to validate BlitzrLocker's hand-rolled fee-growth math against Uniswap's
// genuine on-chain accounting. Run with `FOUNDRY_PROFILE=fork forge test`.
contract BlitzrLauncherForkTest is Test {
    // Verified to have live code at FORK_BLOCK (checked via eth_getCode against a public mainnet
    // RPC before writing this test) — canonical Uniswap V3 mainnet deployment.
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint24 constant FEE_TIER = 10_000;

    BlitzrToken tokenImpl;
    BlitzrLocker locker;
    BlitzrLauncher launcher;

    address platformWallet = makeAddr("forkPlatformWallet");
    address launchFeeWallet = makeAddr("forkLaunchFeeWallet");
    address creator = makeAddr("forkCreator");

    uint256 constant LAUNCH_FEE = 0.01 ether;

    function setUp() public {
        // Forks at latest rather than a pinned block — the free public RPC used as a fallback
        // here only serves recent/latest state without an archive-tier API key, and pinning an
        // older block gets a 403 "Archive requests require a personal token". Set MAINNET_RPC_URL
        // to your own archive-capable endpoint if you want a reproducible pinned block instead.
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpc);

        tokenImpl = new BlitzrToken();
        locker = new BlitzrLocker(platformWallet);
        launcher = new BlitzrLauncher(
            WETH, address(tokenImpl), address(locker), launchFeeWallet,
            V3_FACTORY, POSITION_MANAGER, SWAP_ROUTER, LAUNCH_FEE
        );
        locker.setLauncher(address(launcher), true);

        vm.deal(creator, 100 ether);
    }

    function test_fork_launchCreatesRealPoolAndPosition() public {
        uint256 feeWalletBefore = launchFeeWallet.balance;

        vm.prank(creator);
        (address token, address pool, uint256 tokenId) = launcher.launch{value: LAUNCH_FEE}(
            "Fork Test Token", "FORK", "ipfs://fork", address(0), V3_FACTORY, WETH
        );

        assertEq(launchFeeWallet.balance, feeWalletBefore + LAUNCH_FEE);
        assertGt(pool.code.length, 0); // real pool contract, deployed by the real factory
        assertEq(BlitzrToken(token).owner(), address(0)); // ownership renounced
        assertTrue(BlitzrToken(token).isExempt(pool));

        // The pool holds essentially the full one-sided supply; real V3 concentrated-liquidity
        // minting rounds down from the requested amount, with the shortfall swept back to the
        // creator (mirrors the unit-level dust-sweep tests) — utterly negligible relative to the
        // 1e27-wei total supply, so a generous absolute tolerance is the right check here, not a
        // tight one tuned to a specific observed value.
        assertApproxEqAbs(IERC20Fork(token).balanceOf(pool), BlitzrToken(token).totalSupply(), 1e18);
        assertGt(tokenId, 0);
        assertEq(IERC721Fork(POSITION_MANAGER).ownerOf(tokenId), address(locker));
    }

    function test_fork_thirdPartyCannotStealLockedPosition() public {
        vm.prank(creator);
        (,, uint256 tokenId) = launcher.launch{value: LAUNCH_FEE}(
            "Fork Steal Test", "STEAL", "ipfs://steal", address(0), V3_FACTORY, WETH
        );

        address attacker = makeAddr("forkAttacker");
        vm.prank(attacker);
        vm.expectRevert(); // real ERC721: attacker is neither owner nor approved
        IERC721Fork(POSITION_MANAGER).safeTransferFrom(address(locker), attacker, tokenId);

        assertEq(IERC721Fork(POSITION_MANAGER).ownerOf(tokenId), address(locker));
    }

    function test_fork_realTradingAccruesFeesLockerCorrectlyDistributes() public {
        // Small instant buy — the default marketCapRef targets only 5 ETH for the whole 1B
        // supply, so anything much larger than this would legitimately trip the anti-bot cap on
        // the still-non-exempt creator (a multi-ETH buy against a 5 ETH-cap pool is well over 2.5%
        // of supply). Real-world launches would size this deliberately; here it just needs to be
        // small enough to prove the instant buy worked without hitting that cap.
        vm.prank(creator);
        (address token,,) = launcher.launch{value: LAUNCH_FEE + 0.02 ether}(
            "Fork Trade Token", "FTRD", "ipfs://ftrd", address(0), V3_FACTORY, WETH
        );
        uint256 creatorTokensFromLaunch = BlitzrToken(token).balanceOf(creator);
        assertGt(creatorTokensFromLaunch, 0); // instant buy worked against the real pool

        // Advance past the anti-bot window before the larger trading below — real traders buying
        // a meaningful size would either wait this out or split across multiple smaller trades;
        // rolling forward here isolates "does trading/fee-accrual work" from anti-bot sizing.
        vm.roll(block.number + launcher.antiBotBlocks() + 1);

        // A real trader buys more of the token with real WETH.
        address trader = makeAddr("forkTrader");
        vm.deal(trader, 10 ether);
        vm.startPrank(trader);
        IWETH9Fork(WETH).deposit{value: 5 ether}();
        IWETH9Fork(WETH).approve(SWAP_ROUTER, 5 ether);
        uint256 bought = ISwapRouter02Fork(SWAP_ROUTER).exactInputSingle(
            ISwapRouter02Fork.ExactInputSingleParams({
                tokenIn: WETH, tokenOut: token, fee: FEE_TIER, recipient: trader,
                amountIn: 5 ether, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertGt(bought, 0);

        // The trader sells some back, generating LP fee accrual on the token leg too (the buy
        // above only accrued fee on the WETH leg).
        uint256 sellAmount = bought / 4;
        vm.startPrank(trader);
        IERC20Fork(token).approve(SWAP_ROUTER, sellAmount);
        uint256 wethOut = ISwapRouter02Fork(SWAP_ROUTER).exactInputSingle(
            ISwapRouter02Fork.ExactInputSingleParams({
                tokenIn: token, tokenOut: WETH, fee: FEE_TIER, recipient: trader,
                amountIn: sellAmount, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertGt(wethOut, 0);

        // Validate BlitzrLocker's hand-rolled fee-growth formula (pendingCreatorFees) against
        // what the real Uniswap V3 NonfungiblePositionManager actually pays out on collect().
        (address t0, address t1, uint256 predicted0, uint256 predicted1) = locker.pendingCreatorFees(token);
        assertTrue(predicted0 > 0 || predicted1 > 0); // real trading really did accrue fees

        uint256 creatorT0Before = IERC20Fork(t0).balanceOf(creator);
        uint256 creatorT1Before = IERC20Fork(t1).balanceOf(creator);
        uint256 platformT0Before = IERC20Fork(t0).balanceOf(platformWallet);
        uint256 platformT1Before = IERC20Fork(t1).balanceOf(platformWallet);

        locker.claimFees(token);

        uint256 creatorT0Gain = IERC20Fork(t0).balanceOf(creator) - creatorT0Before;
        uint256 creatorT1Gain = IERC20Fork(t1).balanceOf(creator) - creatorT1Before;
        uint256 platformT0Gain = IERC20Fork(t0).balanceOf(platformWallet) - platformT0Before;
        uint256 platformT1Gain = IERC20Fork(t1).balanceOf(platformWallet) - platformT1Before;

        // No new trades happened between the prediction and the claim, so the actual payout
        // should match the pre-claim prediction almost exactly (a couple of wei of slack for
        // rounding in Uniswap's own fee-growth accounting).
        assertApproxEqAbs(creatorT0Gain, predicted0, 4);
        assertApproxEqAbs(creatorT1Gain, predicted1, 4);

        // 85/15 creator/platform split (defaults) — when a leg accrued anything, creator's share
        // must exceed platform's.
        if (creatorT0Gain + platformT0Gain > 0) assertGt(creatorT0Gain, platformT0Gain);
        if (creatorT1Gain + platformT1Gain > 0) assertGt(creatorT1Gain, platformT1Gain);

        // Claiming again immediately must pay out ~nothing — fees don't get double-counted.
        (,, uint256 predicted0Again, uint256 predicted1Again) = locker.pendingCreatorFees(token);
        assertEq(predicted0Again, 0);
        assertEq(predicted1Again, 0);
    }
}
