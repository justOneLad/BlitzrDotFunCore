// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrLauncher} from "../contracts/BlitzrLauncher.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";
import {BlitzrTokenGuarded} from "../contracts/BlitzrTokenGuarded.sol";
import {MockV3Factory, MockPositionManager, MockSwapRouter, MockWETH} from "./mocks/MockUniswapV3.sol";
import {MockLocker} from "./mocks/MockLocker.sol";

// Integration tests for BlitzrLauncher.launchGuarded() — wiring between the launcher and
// BlitzrTokenGuarded (deep unit coverage of the split/vest/burn math itself lives in
// BlitzrTokenGuarded.t.sol). Reuses the same mocks as BlitzrLauncher.t.sol.
contract BlitzrLauncherGuardedTest is Test {
    BlitzrLauncher launcher;
    BlitzrToken tokenImpl;
    BlitzrTokenGuarded guardedImpl;
    MockWETH weth;
    MockV3Factory factory;
    MockPositionManager positionManager;
    MockSwapRouter router;
    MockLocker locker;

    address feeWallet = makeAddr("feeWallet");
    address creator = makeAddr("creator");

    uint256 constant LAUNCH_FEE = 0.01 ether;
    uint256 constant WINDOW = 20;

    function setUp() public {
        tokenImpl = new BlitzrToken();
        guardedImpl = new BlitzrTokenGuarded();
        weth = new MockWETH();
        factory = new MockV3Factory();
        positionManager = new MockPositionManager(address(factory));
        router = new MockSwapRouter(address(positionManager));
        locker = new MockLocker();

        launcher = new BlitzrLauncher(
            address(weth), address(tokenImpl), address(locker), feeWallet,
            address(factory), address(positionManager), address(router), LAUNCH_FEE
        );
        launcher.setGuardedTokenImpl(address(guardedImpl));

        vm.deal(creator, 100 ether);
    }

    function _launchGuarded(string memory symbol, uint256 value, uint256 windowBlocks)
        private returns (address token, address pool, uint256 tokenId)
    {
        vm.prank(creator);
        (token, pool, tokenId) = launcher.launchGuarded{value: value}(
            string.concat("Guarded ", symbol), symbol, "ipfs://meta", address(0), address(factory), address(weth), windowBlocks
        );
    }

    // --- configuration ---

    function test_launchGuarded_revertsIfNotConfigured() public {
        BlitzrLauncher fresh = new BlitzrLauncher(
            address(weth), address(tokenImpl), address(locker), feeWallet,
            address(factory), address(positionManager), address(router), LAUNCH_FEE
        );
        vm.expectRevert(BlitzrLauncher.GuardedModeNotConfigured.selector);
        vm.prank(creator);
        fresh.launchGuarded{value: LAUNCH_FEE}("N", "N", "", address(0), address(factory), address(weth), WINDOW);
    }

    function test_setGuardedTokenImpl_onlyOwner() public {
        vm.expectRevert(BlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.setGuardedTokenImpl(address(guardedImpl));
    }

    function test_setGuardMaxVestBlocks_onlyOwner() public {
        vm.expectRevert(BlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.setGuardMaxVestBlocks(1000);

        launcher.setGuardMaxVestBlocks(1000);
        assertEq(launcher.guardMaxVestBlocks(), 1000);
    }

    // --- happy path ---

    function test_launchGuarded_deploysGuardedTokenAndArmsGuard() public {
        (address token, address pool,) = _launchGuarded("AAA", LAUNCH_FEE, WINDOW);

        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);
        assertEq(gt.pool(), pool);
        assertEq(gt.windowBlocks(), WINDOW);
        assertEq(gt.windowEndBlock(), block.number + WINDOW);
        assertEq(gt.maxVestBlocks(), launcher.guardMaxVestBlocks());
        assertEq(gt.owner(), address(0)); // renounced, same as a plain launch
        assertTrue(gt.isExempt(pool));
    }

    function test_launchGuarded_registersWithLockerAndChargesFee() public {
        uint256 feeWalletBefore = feeWallet.balance;
        (address token, address pool, uint256 tokenId) = _launchGuarded("BBB", LAUNCH_FEE, WINDOW);

        assertEq(feeWallet.balance, feeWalletBefore + LAUNCH_FEE);
        assertEq(locker.callCount(), 1);
        (address recToken, uint256 recId, address recFeeWallet,,, address recPool,) = locker.calls(0);
        assertEq(recToken, token);
        assertEq(recId, tokenId);
        assertEq(recFeeWallet, creator);
        assertEq(recPool, pool);
    }

    // --- creator's instant buy bypasses the guard ---

    function test_launchGuarded_creatorInstantBuyIsFullyLiquid() public {
        router.setNextAmountOut(500e18);
        (address token,,) = _launchGuarded("CCC", LAUNCH_FEE + 1 ether, WINDOW);

        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);
        assertEq(gt.balanceOf(creator), 500e18); // fully liquid, no split
        assertEq(gt.vestedBalanceOf(creator), 0);
        assertEq(gt.guardBypassOnce(), address(0)); // consumed
    }

    // --- third-party buys during the window get split ---

    function test_launchGuarded_thirdPartyBuyDuringWindowIsSplit() public {
        (address token,,) = _launchGuarded("DDD", LAUNCH_FEE, WINDOW);
        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);

        address sniper = makeAddr("sniper");
        uint256 buyAmount = 1_000_000e18;
        // Same block as launch → progress = 1.0 → 20% liquid / 50% vested / 30% burned.
        positionManager.pullForSwap(token, sniper, buyAmount);

        assertEq(gt.balanceOf(sniper), 200_000e18);
        assertEq(gt.vestedBalanceOf(sniper), 500_000e18);
        assertEq(gt.balanceOf(0x000000000000000000000000000000000000dEaD), 300_000e18);
    }

    function test_launchGuarded_thirdPartyBuyAfterWindowIsFullyLiquid() public {
        (address token,,) = _launchGuarded("EEE", LAUNCH_FEE, WINDOW);
        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);

        vm.roll(block.number + WINDOW);
        address buyer = makeAddr("lateBuyer");
        positionManager.pullForSwap(token, buyer, 1_000_000e18);

        assertEq(gt.balanceOf(buyer), 1_000_000e18);
        assertEq(gt.vestedBalanceOf(buyer), 0);
    }

    function test_launchGuarded_sniperCanClaimVestedAfterMaturity() public {
        (address token,,) = _launchGuarded("FFF", LAUNCH_FEE, WINDOW);
        BlitzrTokenGuarded gt = BlitzrTokenGuarded(token);

        address sniper = makeAddr("sniper2");
        positionManager.pullForSwap(token, sniper, 1_000_000e18);
        uint256 vested = gt.vestedBalanceOf(sniper);
        assertGt(vested, 0);

        vm.roll(block.number + launcher.guardMaxVestBlocks());
        vm.prank(sniper);
        uint256 claimed = gt.claimVested();
        assertEq(claimed, vested);
        assertEq(gt.vestedBalanceOf(sniper), 0);
    }

    // --- distinct salts across launch/launchGuarded avoid collisions ---

    function test_launchGuarded_and_launch_produceDistinctTokens() public {
        (address guardedToken,,) = _launchGuarded("GGG", LAUNCH_FEE, WINDOW);
        vm.prank(creator);
        (address plainToken,,) = launcher.launch{value: LAUNCH_FEE}(
            "Guarded GGG", "GGG", "ipfs://meta", address(0), address(factory), address(weth)
        );
        assertTrue(guardedToken != plainToken);
    }
}
