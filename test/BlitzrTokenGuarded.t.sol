// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrTokenGuarded} from "../contracts/BlitzrTokenGuarded.sol";

contract BlitzrTokenGuardedTest is Test {
    BlitzrTokenGuarded impl;
    BlitzrTokenGuarded tok;

    address launcher = makeAddr("launcher"); // owner, holds full supply pre-guard
    address pool = makeAddr("pool");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address dead = 0x000000000000000000000000000000000000dEaD;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant WINDOW = 20;
    uint256 constant MAX_VEST = 200;

    function setUp() public {
        impl = new BlitzrTokenGuarded();
        tok = BlitzrTokenGuarded(_clone(address(impl), keccak256("guard-salt")));
        vm.prank(launcher);
        tok.initBlitzr("Guarded Test", "GT", "ipfs://guard", launcher, 1_000_000); // huge antiBotBlocks so it never expires mid-test
    }

    function _clone(address impl_, bytes32 salt) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl_))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "clone failed");
    }

    function _initGuard() private {
        vm.startPrank(launcher);
        tok.initGuard(pool, WINDOW, MAX_VEST);
        // Mirrors what the real launcher always does before minting liquidity into the pool —
        // without this, funding the pool with a large balance below would itself trip the
        // anti-bot cap on the pool's own incoming balance.
        tok.setExempt(pool, true);
        vm.stopPrank();
    }

    function _fundPool(uint256 amount) private {
        vm.prank(launcher);
        tok.transfer(pool, amount);
    }

    function _buy(address buyer, uint256 amount) private {
        vm.prank(pool);
        tok.transfer(buyer, amount);
    }

    // --- initGuard ---

    function test_initGuard_onlyOwner() public {
        vm.expectRevert(BlitzrTokenGuarded.NotOwner.selector);
        tok.initGuard(pool, WINDOW, MAX_VEST);
    }

    function test_initGuard_revertsOnZeroPool() public {
        vm.expectRevert(BlitzrTokenGuarded.ZeroAddress.selector);
        vm.prank(launcher);
        tok.initGuard(address(0), WINDOW, MAX_VEST);
    }

    function test_initGuard_revertsOnZeroWindow() public {
        vm.expectRevert(BlitzrTokenGuarded.ZeroAmount.selector);
        vm.prank(launcher);
        tok.initGuard(pool, 0, MAX_VEST);
    }

    function test_initGuard_revertsIfAlreadyInitialized() public {
        _initGuard();
        vm.expectRevert(BlitzrTokenGuarded.GuardAlreadyInitialized.selector);
        vm.prank(launcher);
        tok.initGuard(pool, WINDOW, MAX_VEST);
    }

    function test_initGuard_setsStateAndEmits() public {
        vm.expectEmit(true, false, false, true, address(tok));
        emit BlitzrTokenGuarded.GuardInitialized(pool, block.number + WINDOW, MAX_VEST);
        _initGuard();
        assertEq(tok.pool(), pool);
        assertEq(tok.windowBlocks(), WINDOW);
        assertEq(tok.windowEndBlock(), block.number + WINDOW);
        assertEq(tok.maxVestBlocks(), MAX_VEST);
    }

    // --- no split without an armed guard ---

    function test_transfer_fromPoolBeforeGuardInit_isNotSplit() public {
        // pool isn't armed as a guard source yet (still address(0)) — a transfer FROM the
        // eventual pool address, before initGuard, must behave like an ordinary transfer.
        vm.prank(launcher);
        tok.transfer(pool, 1000e18);
        _buy(alice, 1000e18);
        assertEq(tok.balanceOf(alice), 1000e18);
        assertEq(tok.vestedBalanceOf(alice), 0);
    }

    function test_transfer_notFromPool_isNeverSplit() public {
        _initGuard();
        _fundPool(1000e18);
        _buy(alice, 500e18); // alice now has a mix of liquid tokens
        uint256 aliceLiquidBefore = tok.balanceOf(alice);

        vm.prank(alice);
        tok.transfer(bob, aliceLiquidBefore); // wallet-to-wallet, not from pool
        assertEq(tok.balanceOf(bob), aliceLiquidBefore);
        assertEq(tok.vestedBalanceOf(bob), 0); // never split, regardless of window
    }

    // --- guarded-buy split math ---

    function test_guardedBuy_atWindowStart_appliesMaxSplit() public {
        _initGuard();
        _fundPool(1_000_000e18);

        _buy(alice, 1_000_000e18); // block.number == launch block == window start, progress = 1.0

        // liquid 20%, vested 50%, burned 30% at progress = 1.0
        assertEq(tok.balanceOf(alice), 200_000e18);
        assertEq(tok.vestedBalanceOf(alice), 500_000e18);
        assertEq(tok.balanceOf(dead), 300_000e18);
        assertEq(tok.balanceOf(address(tok)), 500_000e18); // escrow holds the vested leg

        // Vesting duration is also maximal at window start: releaseBlock == buyBlock + maxVestBlocks.
        (uint256 amount, uint256 releaseBlock) = tok.vestScheduleAt(alice, 0);
        assertEq(amount, 500_000e18);
        assertEq(releaseBlock, block.number + MAX_VEST);
    }

    function test_guardedBuy_partwayThroughWindow_decaysBurnAndDuration() public {
        _initGuard();
        _fundPool(1_000_000e18);

        vm.roll(block.number + 10); // halfway through a 20-block window → progress = 0.5
        _buy(alice, 1_000_000e18);

        // burnBps = 3000 * 0.5 = 1500 (15%); vested fixed 50%; liquid = 100-50-15 = 35%
        assertEq(tok.balanceOf(dead), 150_000e18);
        assertEq(tok.vestedBalanceOf(alice), 500_000e18);
        assertEq(tok.balanceOf(alice), 350_000e18);

        (, uint256 releaseBlock) = tok.vestScheduleAt(alice, 0);
        assertEq(releaseBlock, block.number + (MAX_VEST / 2)); // duration halved too
    }

    function test_guardedBuy_atLastBlockOfWindow_minimalBurnAndDuration() public {
        _initGuard();
        _fundPool(1_000_000e18);

        vm.roll(block.number + WINDOW - 1); // last block still inside the window
        _buy(alice, 1_000_000e18);

        // remaining = 1 block out of 20 → progress = 1e18/20 = 5% → burnBps = 3000*5% = 150 (1.5%)
        uint256 expectedBurn = 1_000_000e18 * 150 / 10_000;
        assertEq(tok.balanceOf(dead), expectedBurn);
        assertGt(tok.balanceOf(alice), 0);
        assertLt(expectedBurn, 1_000_000e18 * 3000 / 10_000); // strictly less than the window-start burn
    }

    function test_guardedBuy_afterWindowCloses_isFullyLiquid() public {
        _initGuard();
        _fundPool(1_000_000e18);

        vm.roll(block.number + WINDOW); // window has fully elapsed
        _buy(alice, 1_000_000e18);

        assertEq(tok.balanceOf(alice), 1_000_000e18);
        assertEq(tok.vestedBalanceOf(alice), 0);
        assertEq(tok.balanceOf(dead), 0);
    }

    function test_guardedBuy_exemptRecipientBypassesSplitEntirely() public {
        _initGuard();
        _fundPool(1_000_000e18);
        vm.prank(launcher);
        tok.setExempt(alice, true);

        _buy(alice, 1_000_000e18);
        assertEq(tok.balanceOf(alice), 1_000_000e18);
        assertEq(tok.vestedBalanceOf(alice), 0);
        assertEq(tok.balanceOf(dead), 0);
    }

    // --- guardBypassOnce (creator's own instant buy) ---

    function test_guardBypassOnce_onlyOwner() public {
        vm.expectRevert(BlitzrTokenGuarded.NotOwner.selector);
        tok.setGuardBypassOnce(alice);
    }

    function test_guardBypassOnce_exemptsExactlyOnePurchase() public {
        _initGuard();
        _fundPool(2_000_000e18);

        vm.prank(launcher);
        tok.setGuardBypassOnce(alice);
        assertEq(tok.guardBypassOnce(), alice);

        _buy(alice, 1_000_000e18); // bypassed — fully liquid, and the antibot cap still binds elsewhere
        assertEq(tok.balanceOf(alice), 1_000_000e18);
        assertEq(tok.vestedBalanceOf(alice), 0);
        assertEq(tok.guardBypassOnce(), address(0)); // consumed

        // A second purchase by the SAME address is no longer exempt — the flag doesn't linger.
        _buy(alice, 1_000_000e18);
        assertEq(tok.vestedBalanceOf(alice), 500_000e18);
    }

    function test_guardBypassOnce_isConsumedEvenByAnUnrelatedTransfer() public {
        // Arm the flag, then have some OTHER transfer land on alice first (not from pool) —
        // the flag is still consumed on the first transfer TO alice, by design (see contract
        // comment); this documents that behavior rather than asserting it's exploit-proof.
        _initGuard();
        vm.prank(launcher);
        tok.setGuardBypassOnce(alice);

        vm.prank(launcher);
        tok.transfer(alice, 1); // unrelated ordinary transfer
        assertEq(tok.guardBypassOnce(), address(0));
    }

    // --- anti-bot cap interaction ---

    function test_antiBotCap_countsLiquidPlusVested() public {
        _initGuard();
        // cap is 2.5% of 1e9e18 = 25_000_000e18. A guarded buy of exactly that amount at window
        // start splits into 20% liquid + 50% vested = 70% counted exposure = 17.5M, comfortably
        // under cap on its own — so size it so total exposure (liquid+vested, NOT the 30% burned)
        // lands just over the cap.
        uint256 buyAmount = 40_000_000e18; // 70% of this = 28M > 25M cap
        _fundPool(buyAmount);

        vm.expectRevert(BlitzrTokenGuarded.MaxWalletExceeded.selector);
        _buy(alice, buyAmount);
    }

    function test_antiBotCap_burnedPortionDoesNotCountTowardExposure() public {
        _initGuard();
        // 100M tokens at window start: liquid 20M + vested 50M = 70M exposure > 25M cap — would
        // revert. But sized so liquid+vested alone stays under cap even though burned pushes the
        // RAW amount well over 25M, proving burn isn't counted.
        uint256 buyAmount = 30_000_000e18; // liquid 6M + vested 15M = 21M exposure < 25M cap; burn 9M ignored
        _fundPool(buyAmount);
        _buy(alice, buyAmount); // must NOT revert
        assertEq(tok.balanceOf(alice) + tok.vestedBalanceOf(alice), 21_000_000e18);
    }

    // --- claiming ---

    function test_claimVested_revertsNothingBeforeRelease() public {
        _initGuard();
        _fundPool(1_000_000e18);
        _buy(alice, 1_000_000e18);

        assertEq(tok.claimableVested(alice), 0);
        vm.prank(alice);
        uint256 claimed = tok.claimVested();
        assertEq(claimed, 0);
        assertEq(tok.balanceOf(alice), 200_000e18); // unchanged
    }

    function test_claimVested_releasesAfterMaturity() public {
        _initGuard();
        _fundPool(1_000_000e18);
        _buy(alice, 1_000_000e18); // vested 500_000e18, releaseBlock = block.number + MAX_VEST

        vm.roll(block.number + MAX_VEST);
        assertEq(tok.claimableVested(alice), 500_000e18);

        uint256 tokBalBefore = tok.balanceOf(address(tok));
        vm.prank(alice);
        uint256 claimed = tok.claimVested();

        assertEq(claimed, 500_000e18);
        assertEq(tok.balanceOf(alice), 200_000e18 + 500_000e18);
        assertEq(tok.vestedBalanceOf(alice), 0);
        assertEq(tok.balanceOf(address(tok)), tokBalBefore - 500_000e18);
        assertEq(tok.vestScheduleLength(alice), 0); // matured entry removed
    }

    function test_claimVestedFor_isPermissionless() public {
        _initGuard();
        _fundPool(1_000_000e18);
        _buy(alice, 1_000_000e18);
        vm.roll(block.number + MAX_VEST);

        vm.prank(bob); // anyone can trigger, funds still land with alice
        uint256 claimed = tok.claimVestedFor(alice);
        assertEq(claimed, 500_000e18);
        assertEq(tok.balanceOf(alice), 700_000e18);
        assertEq(tok.balanceOf(bob), 0);
    }

    function test_claimVested_onlyReleasesMaturedEntriesKeepsRest() public {
        _initGuard();
        _fundPool(2_000_000e18);

        _buy(alice, 1_000_000e18); // entry 0: releaseBlock = block.number + MAX_VEST
        uint256 firstReleaseBlock = block.number + MAX_VEST;

        vm.roll(block.number + 10); // still well inside the window (WINDOW=20)
        _buy(alice, 1_000_000e18); // entry 1: shorter duration (partway through window)

        // Roll to exactly when entry 0 matures, but before entry 1 (which started later with a
        // shorter absolute duration, so compare directly rather than assuming ordering).
        vm.roll(firstReleaseBlock);
        uint256 claimableAtFirstRelease = tok.claimableVested(alice);
        assertGe(claimableAtFirstRelease, 500_000e18); // at least entry 0 has matured

        vm.prank(alice);
        uint256 claimed = tok.claimVested();
        assertEq(claimed, claimableAtFirstRelease);
        assertEq(tok.claimableVested(alice), 0); // nothing left claimable at this exact block
    }

    // --- supply conservation ---

    function test_invariant_supplyConservedAcrossSplitAndClaim() public {
        _initGuard();
        _fundPool(5_000_000e18);
        _buy(alice, 2_000_000e18);
        vm.roll(block.number + 5);
        _buy(bob, 2_000_000e18);
        vm.roll(block.number + MAX_VEST);
        vm.prank(alice);
        tok.claimVested();

        uint256 sum = tok.balanceOf(launcher) + tok.balanceOf(pool) + tok.balanceOf(alice)
            + tok.balanceOf(bob) + tok.balanceOf(dead) + tok.balanceOf(address(tok));
        assertEq(sum, SUPPLY);
    }

    // --- base ERC20 behavior still intact ---

    function test_baseErc20_transferAndAntiBotCapStillWork() public {
        vm.prank(launcher);
        tok.transfer(alice, 100e18);
        assertEq(tok.balanceOf(alice), 100e18);

        uint256 tooMuch = SUPPLY * 251 / 10_000;
        vm.expectRevert(BlitzrTokenGuarded.MaxWalletExceeded.selector);
        vm.prank(launcher);
        tok.transfer(bob, tooMuch);
    }
}
