// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {XBlitzrLauncher} from "../xBlitzr/XBlitzrLauncher.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManagerV4Launcher} from "./mocks/MockPoolManagerV4Launcher.sol";
import {MockXBlitzrHookForLauncher} from "./mocks/MockXBlitzrHookForLauncher.sol";

contract XBlitzrLauncherTest is Test {
    XBlitzrLauncher launcher;
    BlitzrToken tokenImpl;
    MockPoolManagerV4Launcher poolManager;
    MockXBlitzrHookForLauncher hook;

    address owner = address(this);
    address feeWallet = makeAddr("feeWallet");
    address creator = makeAddr("creator");
    address platformWallet = makeAddr("platformWallet");

    uint256 constant LAUNCH_FEE = 0.01 ether;
    int24 constant TICK_SPACING = 200;
    int24 constant MIN_TICK = -887_200;
    int24 constant MAX_TICK = 887_200;
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        tokenImpl = new BlitzrToken();
        poolManager = new MockPoolManagerV4Launcher();
        hook = new MockXBlitzrHookForLauncher(platformWallet);

        launcher = new XBlitzrLauncher(
            address(poolManager), address(tokenImpl), address(hook), feeWallet, LAUNCH_FEE
        );

        vm.deal(creator, 100 ether);
        vm.deal(address(poolManager), 100 ether);
    }

    function _launch(string memory symbol, uint256 value) private returns (address token, bytes32 poolId) {
        vm.prank(creator);
        (token, poolId) = launcher.launch{value: value}(
            string.concat("Token ", symbol), symbol, "ipfs://meta", address(0), address(0), 0
        );
    }

    // --- constructor ---

    function test_constructor_setsInitialState() public view {
        assertEq(launcher.owner(), owner);
        assertEq(address(launcher.poolManager()), address(poolManager));
        assertEq(launcher.tokenImpl(), address(tokenImpl));
        assertEq(launcher.hook(), address(hook));
        assertEq(launcher.launchFeeWallet(), feeWallet);
        assertEq(launcher.launchFee(), LAUNCH_FEE);
        (uint256 ref, bool enabled,,,) = launcher.quoteTokens(address(0));
        assertEq(ref, 5e18);
        assertTrue(enabled);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(XBlitzrLauncher.ZeroAddress.selector);
        new XBlitzrLauncher(address(0), address(tokenImpl), address(hook), feeWallet, LAUNCH_FEE);
    }

    function test_constructor_revertsOnZeroFee() public {
        vm.expectRevert(XBlitzrLauncher.ZeroAmount.selector);
        new XBlitzrLauncher(address(poolManager), address(tokenImpl), address(hook), feeWallet, 0);
    }

    // --- admin ---

    function test_transferOwnership_onlyOwner() public {
        vm.expectRevert(XBlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.transferOwnership(creator);
        launcher.transferOwnership(creator);
        assertEq(launcher.owner(), creator);
    }

    function test_collectPoolFees_readsFeeBpsLiveFromHook() public {
        // XBlitzrLauncher has no creatorBps/platformBps of its own anymore — it's the hook's
        // (see XBlitzrHook.setFeeBps access-control tests in XBlitzrHook.t.sol). This just
        // confirms the launcher actually reads through to the hook's current value.
        hook.setFeeBps(9000, 1000);
        (address token, bytes32 poolId) = _launch("FEE", LAUNCH_FEE);
        poolManager.setPendingFees(poolId, 1 ether, 0);

        uint256 creatorBefore = creator.balance;
        launcher.collectPoolFees(token);
        assertEq(creator.balance - creatorBefore, 0.9 ether);
    }

    function test_addQuoteToken_revertsOnZeroRefTickSpacingForNonNative() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 18);
        vm.expectRevert(XBlitzrLauncher.ZeroAmount.selector);
        launcher.addQuoteToken(address(usdc), 1000e18, 3000, 0, address(0));
    }

    function test_addQuoteToken_addsAndDisables() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 18);
        launcher.addQuoteToken(address(usdc), 1000e18, 3000, 60, address(hook));
        (uint256 ref, bool enabled,,,) = launcher.quoteTokens(address(usdc));
        assertEq(ref, 1000e18);
        assertTrue(enabled);

        launcher.disableQuoteToken(address(usdc));
        (, bool enabledAfter,,,) = launcher.quoteTokens(address(usdc));
        assertFalse(enabledAfter);
    }

    function test_rescueETH_onlyOwnerAndTransfers() public {
        address recipient = makeAddr("rescueRecipient");
        vm.deal(address(launcher), 5 ether);
        vm.expectRevert(XBlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.rescueETH(recipient, 1 ether);

        launcher.rescueETH(recipient, 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function test_rescueERC20_onlyOwnerAndTransfers() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(launcher), 100e18);

        vm.expectRevert(XBlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.rescueERC20(address(stray), creator, 50e18);

        launcher.rescueERC20(address(stray), creator, 50e18);
        assertEq(stray.balanceOf(creator), 50e18);
    }

    // --- launch: validation ---

    function test_launch_revertsOnUnsupportedQuoteToken() public {
        vm.expectRevert(XBlitzrLauncher.UnsupportedQuoteToken.selector);
        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE}("N", "N", "", address(0), address(0xdead), 0);
    }

    function test_launch_revertsOnWrongFee() public {
        vm.expectRevert(XBlitzrLauncher.WrongFee.selector);
        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE - 1}("N", "N", "", address(0), address(0), 0);
    }

    // --- launch: happy path (native quote) ---

    function test_launch_chargesFeeAndSeedsFullSupplyIntoPoolManager() public {
        uint256 feeWalletBefore = feeWallet.balance;
        (address token,) = _launch("AAA", LAUNCH_FEE);

        assertEq(feeWallet.balance, feeWalletBefore + LAUNCH_FEE);
        // The ported liquidity<->amount round-trip math has the same few-wei floor rounding real
        // Uniswap has, so the pool manager's balance can be a few wei under TOTAL_SUPPLY — the
        // shortfall lands back with the creator via the post-mint dust sweep (see below).
        assertApproxEqAbs(BlitzrToken(token).balanceOf(address(poolManager)), TOTAL_SUPPLY, 2);
        assertEq(BlitzrToken(token).balanceOf(address(launcher)), 0); // dust always gets swept out
    }

    function test_launch_rendersOwnershipRenouncedAndExemptsPoolManager() public {
        (address token,) = _launch("BBB", LAUNCH_FEE);
        assertEq(BlitzrToken(token).owner(), address(0));
        assertTrue(BlitzrToken(token).isExempt(address(poolManager)));
    }

    function test_launch_registersPositionWithHook() public {
        (address token,) = _launch("CCC", LAUNCH_FEE);
        (address fw, address c0, address c1) = hook.positionsMap(token);
        assertEq(fw, creator); // feeWallet_ == address(0) resolves to msg.sender
        // native quote is always currency0 (address(0) sorts below any nonzero token address).
        assertEq(c0, address(0));
        assertEq(c1, token);
    }

    function test_launch_revertsOnInvalidTickRange() public {
        // Native quote → token is always currency1 → tickUpper = floor(currentTick),
        // tickLower = MIN_TICK. MIN_TICK is already a multiple of TICK_SPACING, so setting the
        // mock's tick to MIN_TICK collapses the range to [MIN_TICK, MIN_TICK].
        poolManager.setNextTick(MIN_TICK);
        vm.expectRevert(XBlitzrLauncher.InvalidTickRange.selector);
        _launch("DDD", LAUNCH_FEE);
    }

    // --- launch: instant buy ---

    function test_launch_instantBuy_singleHop_paysCreator() public {
        poolManager.setNextSwapAmountOut(500e18);
        uint256 extra = 1 ether;
        (address token,) = _launch("EEE", LAUNCH_FEE + extra);
        // Creator receives the swap output plus a few wei of rounding dust from the mint (see
        // test_launch_chargesFeeAndSeedsFullSupplyIntoPoolManager).
        assertApproxEqAbs(BlitzrToken(token).balanceOf(creator), 500e18, 2);
    }

    function test_launch_instantBuy_revertsOnInsufficientOutput() public {
        poolManager.setNextSwapAmountOut(10e18);
        vm.expectRevert(XBlitzrLauncher.InsufficientOutput.selector);
        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE + 1 ether}(
            "Token FFF", "FFF", "ipfs://meta", address(0), address(0), 20e18 // minTokensOut > actual
        );
    }

    function test_launch_instantBuy_multiHop_wiresThroughQuoteToken() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 18);
        launcher.addQuoteToken(address(usdc), 1000e18, 3000, 60, address(hook));
        poolManager.setNextSwapAmountOut(700e18);

        uint256 extra = 2 ether;
        vm.prank(creator);
        (address token,) = launcher.launch{value: LAUNCH_FEE + extra}(
            "Token GGG", "GGG", "ipfs://meta", address(0), address(usdc), 0
        );

        assertApproxEqAbs(BlitzrToken(token).balanceOf(creator), 700e18, 2);
    }

    // --- collectPoolFees ---

    function test_collectPoolFees_revertsOnUnknownToken() public {
        vm.expectRevert(XBlitzrLauncher.UnknownToken.selector);
        launcher.collectPoolFees(address(0xdead));
    }

    function test_collectPoolFees_splitsCreatorAndPlatformShares() public {
        (address token, bytes32 poolId) = _launch("HHH", LAUNCH_FEE);
        // Snapshot after _launch (which already spent LAUNCH_FEE and swept a little rounding
        // dust to the creator) so the assertions below isolate collectPoolFees' own effect.
        uint256 creatorNativeBefore = creator.balance;
        uint256 creatorTokenBefore = BlitzrToken(token).balanceOf(creator);

        // currency0 = native (quote), currency1 = token — fee0 is the native/quote leg,
        // fee1 is the launched-token leg, matching _executePoke's currency-order resolution.
        poolManager.setPendingFees(poolId, 1 ether, 1000e18);

        (uint256 quotePaid, uint256 tokenAmount) = launcher.collectPoolFees(token);
        assertEq(quotePaid, 1 ether);
        assertEq(tokenAmount, 1000e18);

        // default creatorBps 8000 / platformBps 2000
        assertEq(creator.balance - creatorNativeBefore, 0.8 ether); // feeWallet_ == 0 resolved to creator
        assertEq(platformWallet.balance, 0.2 ether);
        assertEq(BlitzrToken(token).balanceOf(creator) - creatorTokenBefore, 800e18);
        assertEq(BlitzrToken(token).balanceOf(platformWallet), 200e18);
    }

    function test_collectPoolFees_secondCallWithNoNewFeesPaysNothing() public {
        (address token, bytes32 poolId) = _launch("III", LAUNCH_FEE);
        poolManager.setPendingFees(poolId, 1 ether, 1000e18);
        launcher.collectPoolFees(token);

        (uint256 quotePaid, uint256 tokenAmount) = launcher.collectPoolFees(token);
        assertEq(quotePaid, 0);
        assertEq(tokenAmount, 0);
    }

    // --- multi-creator scenario ---

    // Two different creators launch two different tokens; a global bps change happens between
    // their two fee collections. Asserts: each launch/collection is scoped by its own poolId (no
    // fee leakage across tokens), and the bps change only governs collections that happen after
    // it — a collection already in flight isn't retroactively affected, matching how creatorBps
    // is read fresh at collection time, not captured at launch time.
    function test_scenario_twoCreatorsLaunchAndCollectAcrossBpsChange() public {
        address creatorA = makeAddr("xLaunchCreatorA");
        address creatorB = makeAddr("xLaunchCreatorB");
        vm.deal(creatorA, 10 ether);
        vm.deal(creatorB, 10 ether);

        vm.prank(creatorA);
        (address tokenA, bytes32 poolIdA) = launcher.launch{value: LAUNCH_FEE}(
            "Token XA", "XA", "ipfs://xa", address(0), address(0), 0
        );
        vm.prank(creatorB);
        (address tokenB, bytes32 poolIdB) = launcher.launch{value: LAUNCH_FEE}(
            "Token XB", "XB", "ipfs://xb", address(0), address(0), 0
        );
        assertTrue(poolIdA != poolIdB);

        // Fees accrue differently on each pool.
        poolManager.setPendingFees(poolIdA, 1 ether, 1000e18);
        poolManager.setPendingFees(poolIdB, 2 ether, 2000e18);

        // Collect A's fees under the original 8000/2000 split.
        uint256 creatorANativeBefore = creatorA.balance;
        launcher.collectPoolFees(tokenA);
        assertEq(creatorA.balance - creatorANativeBefore, 0.8 ether);

        // Owner changes the global split (on the hook — the single source of truth) before B's
        // collection.
        hook.setFeeBps(9000, 1000);

        // Collect B's fees under the NEW split — and confirm A's already-settled payout is
        // untouched by the bps change (no retroactive re-distribution).
        uint256 creatorBNativeBefore = creatorB.balance;
        launcher.collectPoolFees(tokenB);
        assertEq(creatorB.balance - creatorBNativeBefore, 1.8 ether); // 2 ether * 9000/10000
        assertEq(creatorA.balance, creatorANativeBefore + 0.8 ether); // unchanged by B's collection or the bps change

        assertGe(BlitzrToken(tokenA).balanceOf(creatorA), 800e18);
        assertGe(BlitzrToken(tokenB).balanceOf(creatorB), 1800e18);
    }
}
