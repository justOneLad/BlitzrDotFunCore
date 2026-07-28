// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {XBlitzrLauncher} from "../xBlitzr/XBlitzrLauncher.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";
import {BlitzrTokenGuarded} from "../contracts/BlitzrTokenGuarded.sol";
import {MockPoolManagerV4Launcher} from "./mocks/MockPoolManagerV4Launcher.sol";
import {MockXBlitzrHookForLauncher} from "./mocks/MockXBlitzrHookForLauncher.sol";

// Integration tests for XBlitzrLauncher.launchGuarded() — wiring between the launcher and
// BlitzrTokenGuarded (deep unit coverage of the split/vest/burn math itself lives in
// BlitzrTokenGuarded.t.sol). Reuses the same mocks as XBlitzrLauncher.t.sol.
contract XBlitzrLauncherGuardedTest is Test {
    XBlitzrLauncher launcher;
    BlitzrToken tokenImpl;
    BlitzrTokenGuarded guardedImpl;
    MockPoolManagerV4Launcher poolManager;
    MockXBlitzrHookForLauncher hook;

    address feeWallet = makeAddr("feeWallet");
    address creator = makeAddr("creator");
    address platformWallet = makeAddr("platformWallet");

    uint256 constant LAUNCH_FEE = 0.01 ether;
    uint256 constant WINDOW = 20;

    function setUp() public {
        tokenImpl = new BlitzrToken();
        guardedImpl = new BlitzrTokenGuarded();
        poolManager = new MockPoolManagerV4Launcher();
        hook = new MockXBlitzrHookForLauncher(platformWallet);

        launcher = new XBlitzrLauncher(
            address(poolManager), address(tokenImpl), address(hook), feeWallet, LAUNCH_FEE
        );
        launcher.setGuardedTokenImpl(address(guardedImpl));

        vm.deal(creator, 100 ether);
        vm.deal(address(poolManager), 100 ether);
    }

    function _launchGuarded(string memory symbol, uint256 value, uint256 windowBlocks)
        private returns (address token, bytes32 poolId)
    {
        vm.prank(creator);
        (token, poolId) = launcher.launchGuarded{value: value}(
            string.concat("Guarded ", symbol), symbol, "ipfs://meta", address(0), address(0), 0, windowBlocks
        );
    }

    // --- configuration ---

    function test_launchGuarded_revertsIfNotConfigured() public {
        XBlitzrLauncher fresh = new XBlitzrLauncher(
            address(poolManager), address(tokenImpl), address(hook), feeWallet, LAUNCH_FEE
        );
        vm.expectRevert(XBlitzrLauncher.GuardedModeNotConfigured.selector);
        vm.prank(creator);
        fresh.launchGuarded{value: LAUNCH_FEE}("N", "N", "", address(0), address(0), 0, WINDOW);
    }

    function test_setGuardedTokenImpl_onlyOwner() public {
        vm.expectRevert(XBlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.setGuardedTokenImpl(address(guardedImpl));
    }

    function test_setGuardMaxVestBlocks_onlyOwner() public {
        vm.expectRevert(XBlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.setGuardMaxVestBlocks(1000);

        launcher.setGuardMaxVestBlocks(1000);
        assertEq(launcher.guardMaxVestBlocks(), 1000);
    }

    // --- happy path ---

    function test_launchGuarded_deploysGuardedTokenAndArmsGuard() public {
        (address token,) = _launchGuarded("AAA", LAUNCH_FEE, WINDOW);

        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);
        assertEq(gt.pool(), address(poolManager));
        assertEq(gt.windowBlocks(), WINDOW);
        assertEq(gt.windowEndBlock(), block.number + WINDOW);
        assertEq(gt.maxVestBlocks(), launcher.guardMaxVestBlocks());
        assertEq(gt.owner(), address(0)); // renounced
        assertTrue(gt.isExempt(address(poolManager)));
    }

    function test_launchGuarded_registersWithHookAndChargesFee() public {
        uint256 feeWalletBefore = feeWallet.balance;
        (address token,) = _launchGuarded("BBB", LAUNCH_FEE, WINDOW);

        assertEq(feeWallet.balance, feeWalletBefore + LAUNCH_FEE);
        (address fw,,) = hook.positionsMap(token);
        assertEq(fw, creator);
    }

    // --- creator's instant buy bypasses the guard ---

    function test_launchGuarded_creatorInstantBuyIsFullyLiquid() public {
        poolManager.setNextSwapAmountOut(500e18);
        (address token,) = _launchGuarded("CCC", LAUNCH_FEE + 0.02 ether, WINDOW);

        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);
        assertApproxEqAbs(gt.balanceOf(creator), 500e18, 2); // fully liquid (+ a few wei of mint-rounding dust)
        assertEq(gt.vestedBalanceOf(creator), 0);
        assertEq(gt.guardBypassOnce(), address(0)); // consumed
    }

    // --- third-party buys during the window get split ---

    function test_launchGuarded_thirdPartyBuyDuringWindowIsSplit() public {
        (address token,) = _launchGuarded("DDD", LAUNCH_FEE, WINDOW);
        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);

        address sniper = makeAddr("sniper");
        uint256 buyAmount = 1_000_000e18;
        // Same block as launch → progress = 1.0 → 20% liquid / 50% vested / 30% burned.
        poolManager.take(token, sniper, buyAmount);

        assertEq(gt.balanceOf(sniper), 200_000e18);
        assertEq(gt.vestedBalanceOf(sniper), 500_000e18);
        assertEq(gt.balanceOf(0x000000000000000000000000000000000000dEaD), 300_000e18);
    }

    function test_launchGuarded_thirdPartyBuyAfterWindowIsFullyLiquid() public {
        (address token,) = _launchGuarded("EEE", LAUNCH_FEE, WINDOW);
        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);

        vm.roll(block.number + WINDOW);
        address buyer = makeAddr("lateBuyer");
        poolManager.take(token, buyer, 1_000_000e18);

        assertEq(gt.balanceOf(buyer), 1_000_000e18);
        assertEq(gt.vestedBalanceOf(buyer), 0);
    }

    function test_launchGuarded_sniperCanClaimVestedAfterMaturity() public {
        (address token,) = _launchGuarded("FFF", LAUNCH_FEE, WINDOW);
        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);

        address sniper = makeAddr("sniper2");
        poolManager.take(token, sniper, 1_000_000e18);
        uint256 vested = gt.vestedBalanceOf(sniper);
        assertGt(vested, 0);

        vm.roll(block.number + launcher.guardMaxVestBlocks());
        vm.prank(sniper);
        uint256 claimed = gt.claimVested();
        assertEq(claimed, vested);
        assertEq(gt.vestedBalanceOf(sniper), 0);
    }

    function test_launchGuarded_and_launch_produceDistinctTokens() public {
        (address guardedToken,) = _launchGuarded("GGG", LAUNCH_FEE, WINDOW);
        vm.prank(creator);
        (address plainToken,) = launcher.launch{value: LAUNCH_FEE}(
            "Guarded GGG", "GGG", "ipfs://meta", address(0), address(0), 0
        );
        assertTrue(guardedToken != plainToken);
    }
}
