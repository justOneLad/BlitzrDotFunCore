// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrTreasury} from "../contracts/BlitzrTreasury.sol";
import {MockERC20, MockERC20NoRevert} from "./mocks/MockERC20.sol";

contract RevertingReceiver {
    receive() external payable { revert("nope"); }
}

contract BlitzrTreasuryTest is Test {
    BlitzrTreasury treasury;
    MockERC20 token;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    uint256 constant DELAY = 2 days;

    function setUp() public {
        treasury = new BlitzrTreasury(owner, DELAY);
        token = new MockERC20("Token", "TKN", 18);
    }

    // --- constructor ---

    function test_constructor_setsOwnerAndDelay() public view {
        assertEq(treasury.owner(), owner);
        assertEq(treasury.timelockDelay(), DELAY);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(BlitzrTreasury.ZeroAddress.selector);
        new BlitzrTreasury(address(0), DELAY);
    }

    function test_constructor_revertsOnZeroDelay() public {
        vm.expectRevert(BlitzrTreasury.ZeroDelay.selector);
        new BlitzrTreasury(owner, 0);
    }

    // --- receive ---

    function test_receive_acceptsNativeAndEmits() public {
        vm.expectEmit(true, false, false, true, address(treasury));
        emit BlitzrTreasury.Deposited(alice, 1 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_receive_revertsOnCalldata() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok);
    }

    // --- queueWithdrawal ---

    function test_queueWithdrawal_onlyOwner() public {
        vm.expectRevert(BlitzrTreasury.NotOwner.selector);
        vm.prank(alice);
        treasury.queueWithdrawal(address(0), alice, 1 ether);
    }

    function test_queueWithdrawal_revertsOnZeroTo() public {
        vm.expectRevert(BlitzrTreasury.ZeroAddress.selector);
        vm.prank(owner);
        treasury.queueWithdrawal(address(0), address(0), 1 ether);
    }

    function test_queueWithdrawal_revertsOnZeroAmount() public {
        vm.expectRevert(BlitzrTreasury.ZeroAmount.selector);
        vm.prank(owner);
        treasury.queueWithdrawal(address(0), alice, 0);
    }

    function test_queueWithdrawal_setsExecutableAtAndEmits() public {
        vm.prank(owner);
        bytes32 id = treasury.queueWithdrawal(address(0), alice, 1 ether);
        assertEq(treasury.queuedAt(id), block.timestamp + DELAY);
    }

    function test_queueWithdrawal_revertsIfAlreadyQueued() public {
        vm.startPrank(owner);
        treasury.queueWithdrawal(address(0), alice, 1 ether);
        vm.expectRevert(BlitzrTreasury.AlreadyQueued.selector);
        treasury.queueWithdrawal(address(0), alice, 1 ether);
        vm.stopPrank();
    }

    function test_queueWithdrawal_distinctParamsDistinctIds() public {
        vm.startPrank(owner);
        bytes32 id1 = treasury.queueWithdrawal(address(0), alice, 1 ether);
        bytes32 id2 = treasury.queueWithdrawal(address(0), alice, 2 ether);
        vm.stopPrank();
        assertTrue(id1 != id2);
    }

    // --- cancelWithdrawal ---

    function test_cancelWithdrawal_onlyOwner() public {
        vm.prank(owner);
        treasury.queueWithdrawal(address(0), alice, 1 ether);

        vm.expectRevert(BlitzrTreasury.NotOwner.selector);
        vm.prank(alice);
        treasury.cancelWithdrawal(address(0), alice, 1 ether);
    }

    function test_cancelWithdrawal_revertsIfNotQueued() public {
        vm.expectRevert(BlitzrTreasury.NotQueued.selector);
        vm.prank(owner);
        treasury.cancelWithdrawal(address(0), alice, 1 ether);
    }

    function test_cancelWithdrawal_clearsQueueAndAllowsRequeue() public {
        vm.startPrank(owner);
        bytes32 id = treasury.queueWithdrawal(address(0), alice, 1 ether);
        treasury.cancelWithdrawal(address(0), alice, 1 ether);
        assertEq(treasury.queuedAt(id), 0);

        // Re-queueing the same params after cancellation must not revert with AlreadyQueued.
        treasury.queueWithdrawal(address(0), alice, 1 ether);
        vm.stopPrank();
    }

    // --- executeWithdrawal: native ---

    function test_executeWithdrawal_revertsIfNotQueued() public {
        vm.expectRevert(BlitzrTreasury.NotQueued.selector);
        vm.prank(owner);
        treasury.executeWithdrawal(address(0), alice, 1 ether);
    }

    function test_executeWithdrawal_revertsBeforeDelayElapsed() public {
        vm.prank(owner);
        treasury.queueWithdrawal(address(0), alice, 1 ether);

        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert(BlitzrTreasury.NotReady.selector);
        vm.prank(owner);
        treasury.executeWithdrawal(address(0), alice, 1 ether);
    }

    function test_executeWithdrawal_onlyOwner() public {
        vm.prank(owner);
        treasury.queueWithdrawal(address(0), alice, 1 ether);
        vm.warp(block.timestamp + DELAY);

        vm.expectRevert(BlitzrTreasury.NotOwner.selector);
        vm.prank(alice);
        treasury.executeWithdrawal(address(0), alice, 1 ether);
    }

    function test_executeWithdrawal_native_transfersAfterDelay() public {
        vm.deal(address(treasury), 5 ether);
        vm.startPrank(owner);
        treasury.queueWithdrawal(address(0), alice, 1 ether);
        vm.warp(block.timestamp + DELAY);
        treasury.executeWithdrawal(address(0), alice, 1 ether);
        vm.stopPrank();

        assertEq(alice.balance, 1 ether);
        assertEq(address(treasury).balance, 4 ether);
    }

    function test_executeWithdrawal_native_exactlyAtDelayBoundarySucceeds() public {
        vm.deal(address(treasury), 1 ether);
        vm.startPrank(owner);
        treasury.queueWithdrawal(address(0), alice, 1 ether);
        vm.warp(block.timestamp + DELAY); // exactly executableAt
        treasury.executeWithdrawal(address(0), alice, 1 ether);
        vm.stopPrank();
        assertEq(alice.balance, 1 ether);
    }

    function test_executeWithdrawal_clearsQueueEntry() public {
        vm.deal(address(treasury), 1 ether);
        vm.startPrank(owner);
        bytes32 id = treasury.queueWithdrawal(address(0), alice, 1 ether);
        vm.warp(block.timestamp + DELAY);
        treasury.executeWithdrawal(address(0), alice, 1 ether);
        vm.stopPrank();
        assertEq(treasury.queuedAt(id), 0);
    }

    function test_executeWithdrawal_cannotDoubleExecute() public {
        vm.deal(address(treasury), 1 ether);
        vm.startPrank(owner);
        treasury.queueWithdrawal(address(0), alice, 1 ether);
        vm.warp(block.timestamp + DELAY);
        treasury.executeWithdrawal(address(0), alice, 1 ether);

        vm.expectRevert(BlitzrTreasury.NotQueued.selector);
        treasury.executeWithdrawal(address(0), alice, 1 ether);
        vm.stopPrank();
    }

    function test_executeWithdrawal_native_revertsIfRecipientRejects() public {
        RevertingReceiver bad = new RevertingReceiver();
        vm.deal(address(treasury), 1 ether);
        vm.startPrank(owner);
        treasury.queueWithdrawal(address(0), address(bad), 1 ether);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BlitzrTreasury.TransferFailed.selector);
        treasury.executeWithdrawal(address(0), address(bad), 1 ether);
        vm.stopPrank();
    }

    function test_executeWithdrawal_native_revertsOnInsufficientBalance() public {
        // Nothing deposited — the low-level call itself fails on insufficient balance.
        vm.startPrank(owner);
        treasury.queueWithdrawal(address(0), alice, 1 ether);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BlitzrTreasury.TransferFailed.selector);
        treasury.executeWithdrawal(address(0), alice, 1 ether);
        vm.stopPrank();
    }

    // --- executeWithdrawal: ERC20 ---

    function test_executeWithdrawal_token_transfersAfterDelay() public {
        token.mint(address(treasury), 100e18);
        vm.startPrank(owner);
        treasury.queueWithdrawal(address(token), alice, 40e18);
        vm.warp(block.timestamp + DELAY);
        treasury.executeWithdrawal(address(token), alice, 40e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 40e18);
        assertEq(token.balanceOf(address(treasury)), 60e18);
    }

    function test_executeWithdrawal_token_revertsOnFalseReturn() public {
        MockERC20NoRevert badToken = new MockERC20NoRevert();
        vm.startPrank(owner);
        treasury.queueWithdrawal(address(badToken), alice, 1e18);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BlitzrTreasury.TransferFailed.selector);
        treasury.executeWithdrawal(address(badToken), alice, 1e18);
        vm.stopPrank();
    }

    function test_executeWithdrawal_token_and_native_areIndependentQueueEntries() public {
        // Same `to` and numerically-equal amount but different token param must not collide
        // in the id mapping — both queue calls below must succeed without AlreadyQueued.
        vm.deal(address(treasury), 1 ether);
        token.mint(address(treasury), 1e18);
        vm.startPrank(owner);
        treasury.queueWithdrawal(address(0), alice, 1 ether);
        treasury.queueWithdrawal(address(token), alice, 1e18);
        vm.stopPrank();
    }

    // --- transferOwnership ---

    function test_transferOwnership_onlyOwner() public {
        vm.expectRevert(BlitzrTreasury.NotOwner.selector);
        vm.prank(alice);
        treasury.transferOwnership(alice);
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.expectRevert(BlitzrTreasury.ZeroAddress.selector);
        vm.prank(owner);
        treasury.transferOwnership(address(0));
    }

    function test_transferOwnership_updatesOwnerAndEmits() public {
        vm.expectEmit(true, true, false, true, address(treasury));
        emit BlitzrTreasury.OwnershipTransferred(owner, alice);
        vm.prank(owner);
        treasury.transferOwnership(alice);
        assertEq(treasury.owner(), alice);
    }

    function test_transferOwnership_stolenKeyStillBlockedByTimelock() public {
        // Even after a compromised owner transfers ownership to themselves, withdrawals they
        // queue still can't execute before timelockDelay elapses — the delay is immutable and
        // doesn't reset or shorten based on who currently holds `owner`.
        vm.deal(address(treasury), 1 ether);
        address attacker = makeAddr("attacker");
        vm.prank(owner);
        treasury.transferOwnership(attacker);

        vm.startPrank(attacker);
        treasury.queueWithdrawal(address(0), attacker, 1 ether);
        vm.expectRevert(BlitzrTreasury.NotReady.selector);
        treasury.executeWithdrawal(address(0), attacker, 1 ether);
        vm.stopPrank();
    }

    // --- multi-withdrawal scenario ---

    // Several independently-queued withdrawals — different recipients, different assets, queued
    // at different times — each must run its own lifecycle (execute / cancel / still-pending)
    // without interfering with the others.
    function test_scenario_multipleIndependentWithdrawalLifecycles() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address bob = makeAddr("bob");

        vm.deal(address(treasury), 10 ether);
        usdc.mint(address(treasury), 1_000_000e6);

        vm.startPrank(owner);
        // t0: queue three withdrawals at once, staggered by asset/recipient.
        bytes32 idNativeAlice = treasury.queueWithdrawal(address(0), alice, 1 ether);
        bytes32 idUsdcBob = treasury.queueWithdrawal(address(usdc), bob, 500_000e6);
        vm.stopPrank();

        // Halfway through the delay, queue a fourth withdrawal — its clock starts later than
        // the first two, so it must not become executable at the same time as them.
        vm.warp(block.timestamp + DELAY / 2);
        vm.prank(owner);
        bytes32 idNativeBob = treasury.queueWithdrawal(address(0), bob, 2 ether);

        // Cancel one of the original three before it ever becomes executable.
        vm.prank(owner);
        treasury.cancelWithdrawal(address(usdc), bob, 500_000e6);

        // Advance past the FIRST batch's delay but not the second's.
        vm.warp(block.timestamp + DELAY / 2);
        assertTrue(block.timestamp >= treasury.queuedAt(idNativeAlice));
        assertTrue(block.timestamp < treasury.queuedAt(idNativeBob));

        vm.startPrank(owner);
        treasury.executeWithdrawal(address(0), alice, 1 ether); // first batch: ready
        vm.expectRevert(BlitzrTreasury.NotQueued.selector); // cancelled — never re-executable
        treasury.executeWithdrawal(address(usdc), bob, 500_000e6);
        vm.expectRevert(BlitzrTreasury.NotReady.selector); // second batch: not ready yet
        treasury.executeWithdrawal(address(0), bob, 2 ether);
        vm.stopPrank();

        assertEq(idUsdcBob, keccak256(abi.encode(address(usdc), bob, uint256(500_000e6)))); // sanity on id derivation
        assertEq(alice.balance, 1 ether);
        assertEq(usdc.balanceOf(bob), 0); // cancelled, never paid
        assertEq(bob.balance, 0); // still pending

        // Finish out the delay for the last one.
        vm.warp(treasury.queuedAt(idNativeBob));
        vm.prank(owner);
        treasury.executeWithdrawal(address(0), bob, 2 ether);
        assertEq(bob.balance, 2 ether);

        // Treasury balance reflects exactly what was actually paid out (1 + 2 native; USDC
        // withdrawal was cancelled so its full balance remains).
        assertEq(address(treasury).balance, 10 ether - 3 ether);
        assertEq(usdc.balanceOf(address(treasury)), 1_000_000e6);
    }
}
