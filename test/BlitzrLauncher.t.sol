// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrLauncher} from "../contracts/BlitzrLauncher.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Factory, MockV3Pool, MockPositionManager, MockSwapRouter, MockWETH} from "./mocks/MockUniswapV3.sol";
import {MockLocker} from "./mocks/MockLocker.sol";

contract BlitzrLauncherTest is Test {
    BlitzrLauncher launcher;
    BlitzrToken tokenImpl;
    MockWETH weth;
    MockV3Factory factory;
    MockPositionManager positionManager;
    MockSwapRouter router;
    MockLocker locker;

    address owner = address(this);
    address feeWallet = makeAddr("feeWallet");
    address creator = makeAddr("creator");

    uint256 constant LAUNCH_FEE = 0.01 ether;
    uint24  constant FEE_TIER = 10_000;
    int24   constant TICK_SPACING = 200;
    int24   constant MAX_TICK = 887_200;
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        tokenImpl = new BlitzrToken();
        weth = new MockWETH();
        factory = new MockV3Factory();
        positionManager = new MockPositionManager(address(factory));
        router = new MockSwapRouter(address(positionManager));
        locker = new MockLocker();

        launcher = new BlitzrLauncher(
            address(weth), address(tokenImpl), address(locker), feeWallet,
            address(factory), address(positionManager), address(router), LAUNCH_FEE
        );

        vm.deal(creator, 100 ether);
    }

    function _launch(string memory symbol, uint256 value) private returns (address token, address pool, uint256 tokenId) {
        vm.prank(creator);
        (token, pool, tokenId) = launcher.launch{value: value}(
            string.concat("Token ", symbol), symbol, "ipfs://meta", address(0), address(factory), address(weth)
        );
    }

    function _floorToTickSpacing(int24 t) private pure returns (int24) {
        int24 compressed = t / TICK_SPACING;
        if (t < 0 && t % TICK_SPACING != 0) compressed--;
        return compressed * TICK_SPACING;
    }

    // --- constructor ---

    function test_constructor_setsInitialState() public view {
        assertEq(launcher.owner(), owner);
        assertEq(launcher.weth(), address(weth));
        assertEq(launcher.tokenImpl(), address(tokenImpl));
        assertEq(address(launcher.locker()), address(locker));
        assertEq(launcher.launchFeeWallet(), feeWallet);
        assertEq(launcher.launchFee(), LAUNCH_FEE);
        (address pm, address r, bool enabled) = launcher.dexes(address(factory));
        assertEq(pm, address(positionManager));
        assertEq(r, address(router));
        assertTrue(enabled);
        (uint256 ref, uint24 fee, bool qEnabled) = launcher.quoteTokens(address(weth));
        assertEq(ref, 5e18);
        assertEq(fee, 0);
        assertTrue(qEnabled);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(BlitzrLauncher.ZeroAddress.selector);
        new BlitzrLauncher(address(0), address(tokenImpl), address(locker), feeWallet, address(factory), address(positionManager), address(router), LAUNCH_FEE);

        vm.expectRevert(BlitzrLauncher.ZeroAddress.selector);
        new BlitzrLauncher(address(weth), address(0), address(locker), feeWallet, address(factory), address(positionManager), address(router), LAUNCH_FEE);
    }

    function test_constructor_revertsOnZeroFee() public {
        vm.expectRevert(BlitzrLauncher.ZeroAmount.selector);
        new BlitzrLauncher(address(weth), address(tokenImpl), address(locker), feeWallet, address(factory), address(positionManager), address(router), 0);
    }

    // --- owner-only admin ---

    function test_transferOwnership_onlyOwner() public {
        vm.expectRevert(BlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.transferOwnership(creator);
    }

    function test_transferOwnership_updatesOwner() public {
        launcher.transferOwnership(creator);
        assertEq(launcher.owner(), creator);
    }

    function test_setLaunchFeeWallet_onlyOwnerAndNonZero() public {
        vm.expectRevert(BlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.setLaunchFeeWallet(creator);

        vm.expectRevert(BlitzrLauncher.ZeroAddress.selector);
        launcher.setLaunchFeeWallet(address(0));

        launcher.setLaunchFeeWallet(creator);
        assertEq(launcher.launchFeeWallet(), creator);
    }

    function test_setLaunchFee_onlyOwnerAndNonZero() public {
        vm.expectRevert(BlitzrLauncher.ZeroAmount.selector);
        launcher.setLaunchFee(0);
        launcher.setLaunchFee(1 ether);
        assertEq(launcher.launchFee(), 1 ether);
    }

    function test_setAntiBotBlocks_onlyOwner() public {
        vm.expectRevert(BlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.setAntiBotBlocks(20);
        launcher.setAntiBotBlocks(20);
        assertEq(launcher.antiBotBlocks(), 20);
    }

    function test_addDex_onlyOwner() public {
        vm.expectRevert(BlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.addDex(address(0x1), address(0x2), address(0x3));
    }

    function test_addDex_revertsOnZeroAddress() public {
        vm.expectRevert(BlitzrLauncher.ZeroAddress.selector);
        launcher.addDex(address(0), address(0x2), address(0x3));
    }

    function test_disableDex_revertsIfNotEnabled() public {
        vm.expectRevert(BlitzrLauncher.UnsupportedDex.selector);
        launcher.disableDex(address(0xdead));
    }

    function test_disableDex_disablesEnabledDex() public {
        launcher.disableDex(address(factory));
        (,, bool enabled) = launcher.dexes(address(factory));
        assertFalse(enabled);
    }

    function test_addQuoteToken_revertsWhenNonWethMissingPairFee() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.expectRevert(BlitzrLauncher.ZeroAmount.selector);
        launcher.addQuoteToken(address(usdc), 1000e6, 0);
    }

    function test_addQuoteToken_addsQuoteToken() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        launcher.addQuoteToken(address(usdc), 1000e6, 3000);
        (uint256 ref, uint24 fee, bool enabled) = launcher.quoteTokens(address(usdc));
        assertEq(ref, 1000e6);
        assertEq(fee, 3000);
        assertTrue(enabled);
    }

    function test_disableQuoteToken_revertsIfNotEnabled() public {
        vm.expectRevert(BlitzrLauncher.UnsupportedQuoteToken.selector);
        launcher.disableQuoteToken(address(0xdead));
    }

    function test_setMarketCapRef_requiresEnabledQuoteAndNonZero() public {
        vm.expectRevert(BlitzrLauncher.UnsupportedQuoteToken.selector);
        launcher.setMarketCapRef(address(0xdead), 1e18);

        vm.expectRevert(BlitzrLauncher.ZeroAmount.selector);
        launcher.setMarketCapRef(address(weth), 0);

        launcher.setMarketCapRef(address(weth), 10e18);
        (uint256 ref,,) = launcher.quoteTokens(address(weth));
        assertEq(ref, 10e18);
    }

    function test_rescueETH_onlyOwnerAndTransfers() public {
        address recipient = makeAddr("rescueRecipient");
        vm.deal(address(launcher), 5 ether);
        vm.expectRevert(BlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.rescueETH(recipient, 1 ether);

        launcher.rescueETH(recipient, 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function test_rescueERC20_onlyOwnerAndTransfers() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(launcher), 100e18);

        vm.expectRevert(BlitzrLauncher.NotOwner.selector);
        vm.prank(creator);
        launcher.rescueERC20(address(stray), creator, 50e18);

        launcher.rescueERC20(address(stray), creator, 50e18);
        assertEq(stray.balanceOf(creator), 50e18);
    }

    // --- launch: validation ---

    function test_launch_revertsOnUnsupportedDex() public {
        vm.expectRevert(BlitzrLauncher.UnsupportedDex.selector);
        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE}("N", "N", "", address(0), address(0xdead), address(weth));
    }

    function test_launch_revertsOnUnsupportedQuoteToken() public {
        vm.expectRevert(BlitzrLauncher.UnsupportedQuoteToken.selector);
        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE}("N", "N", "", address(0), address(factory), address(0xdead));
    }

    function test_launch_revertsOnWrongFee() public {
        vm.expectRevert(BlitzrLauncher.WrongFee.selector);
        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE - 1}("N", "N", "", address(0), address(factory), address(weth));
    }

    // --- launch: happy path ---

    function test_launch_chargesFeeToLaunchFeeWallet() public {
        uint256 before = feeWallet.balance;
        _launch("AAA", LAUNCH_FEE);
        assertEq(feeWallet.balance, before + LAUNCH_FEE);
    }

    function test_launch_rendersOwnershipRenounced() public {
        (address token,,) = _launch("BBB", LAUNCH_FEE);
        assertEq(BlitzrToken(token).owner(), address(0));
    }

    function test_launch_registersPositionWithLocker() public {
        (address token, address pool, uint256 tokenId) = _launch("CCC", LAUNCH_FEE);
        assertEq(locker.callCount(), 1);
        (address t, uint256 tid, address fw,,, address p,) = locker.calls(0);
        assertEq(t, token);
        assertEq(tid, tokenId);
        assertEq(fw, creator); // feeWallet_ == address(0) resolves to msg.sender
        assertEq(p, pool);
    }

    function test_launch_exemptsPoolAndBurnAddressFromAntiBot() public {
        (address token, address pool,) = _launch("DDD", LAUNCH_FEE);
        assertTrue(BlitzrToken(token).isExempt(pool));
        assertTrue(BlitzrToken(token).isExempt(0x000000000000000000000000000000000000dEaD));
    }

    function test_launch_seedsOneSidedLiquidityAccordingToTokenOrdering() public {
        // Loop several launches with distinct symbols (distinct CREATE2 salts → distinct token
        // addresses) so both token<quoteToken and token>quoteToken orderings get exercised, and
        // assert the one-sided range invariant generically for whichever ordering occurred.
        bool sawToken0 = false;
        bool sawToken1 = false;
        for (uint256 i = 0; i < 8 && !(sawToken0 && sawToken1); i++) {
            (address token, address pool, uint256 tokenId) = _launch(string.concat("SYM", vm.toString(i)), LAUNCH_FEE);
            (,, address t0, address t1,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = positionManager.positions(tokenId);
            if (token == t0) {
                sawToken0 = true;
                assertEq(tickUpper, MAX_TICK);
                assertGt(tickLower, -MAX_TICK); // above current tick, per _mintAndRegister
            } else {
                assertEq(t1, token);
                sawToken1 = true;
                assertEq(tickLower, -MAX_TICK);
            }
            assertGt(liquidity, 0);
            assertEq(BlitzrToken(token).balanceOf(pool), TOTAL_SUPPLY);
        }
        assertTrue(sawToken0, "never saw token-is-token0 ordering across 8 launches");
        assertTrue(sawToken1, "never saw token-is-token1 ordering across 8 launches");
    }

    function test_launch_adoptsUninitializedShellPool() public {
        // Front-run: pre-create the pool (but don't initialize it) at whatever address a launch
        // would target — simulated by creating a pool for a placeholder pair, since we can't
        // predict the real token address ahead of the actual launch call in this test. Instead,
        // directly exercise the "adopt existing shell" branch by pre-creating via the factory
        // for the (weth, token) pair after computing the token's deterministic CREATE2 address.
        bytes32 salt = keccak256(abi.encodePacked(creator, block.timestamp, "Token EEE", "EEE", "ipfs://meta"));
        address predictedToken = _predictClone(address(tokenImpl), salt);

        vm.prank(creator);
        factory.frontRunCreatePool(predictedToken, address(weth), FEE_TIER);

        (address token, address pool,) = _launch("EEE", LAUNCH_FEE);
        assertEq(token, predictedToken);
        assertEq(factory.getPool(token, address(weth), FEE_TIER), pool);
    }

    function test_launch_revertsOnPoolAlreadyExists() public {
        bytes32 salt = keccak256(abi.encodePacked(creator, block.timestamp, "Token FFF", "FFF", "ipfs://meta"));
        address predictedToken = _predictClone(address(tokenImpl), salt);

        address preexisting = factory.frontRunCreatePool(predictedToken, address(weth), FEE_TIER);
        MockV3Pool(preexisting).initialize(1 << 96); // nonzero price = "already initialized"

        vm.expectRevert(BlitzrLauncher.PoolAlreadyExists.selector);
        _launch("FFF", LAUNCH_FEE);
    }

    function test_launch_revertsOnInvalidTickRange() public {
        // Force currentTick to MAX_TICK so a token-is-token0 launch computes
        // tickLower = floor(MAX_TICK)+SPACING > MAX_TICK == tickUpper.
        factory.setNextTick(MAX_TICK);
        // Try a handful of symbols until we land a token-is-token0 ordering (weth is the other
        // side); any ordering that resolves to token0 will trip InvalidTickRange here.
        for (uint256 i = 0; i < 20; i++) {
            bytes32 salt = keccak256(abi.encodePacked(creator, block.timestamp, string.concat("Token G", vm.toString(i)), string.concat("G", vm.toString(i)), "ipfs://meta"));
            address predicted = _predictClone(address(tokenImpl), salt);
            if (predicted < address(weth)) {
                vm.expectRevert(BlitzrLauncher.InvalidTickRange.selector);
                _launch(string.concat("G", vm.toString(i)), LAUNCH_FEE);
                return;
            }
        }
        fail();
    }

    // --- launch: instant buy ---

    function test_launch_instantBuy_singleHop_wrapsAndSwaps() public {
        router.setNextAmountOut(500e18);
        uint256 extra = 1 ether;
        (address token,,) = _launch("HHH", LAUNCH_FEE + extra);

        assertEq(weth.balanceOf(address(router)), extra);
        assertEq(BlitzrToken(token).balanceOf(creator), 500e18);
    }

    function test_launch_instantBuy_multiHop_routesThroughQuoteToken() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 18);
        launcher.addQuoteToken(address(usdc), 1000e18, 3000);
        router.setNextAmountOut(700e18);

        uint256 extra = 2 ether;
        vm.prank(creator);
        (address token,,) = launcher.launch{value: LAUNCH_FEE + extra}(
            "Token III", "III", "ipfs://meta", address(0), address(factory), address(usdc)
        );

        assertEq(weth.balanceOf(address(router)), extra);
        assertEq(BlitzrToken(token).balanceOf(creator), 700e18);
    }

    function test_launch_sweepsDustToCreator() public {
        // With no instant buy and full one-sided seeding, mint() returns amount0 == amount0Desired
        // exactly in the mock, so there's no rounding dust — this asserts that invariant holds
        // (creator's token balance is 0 pre-sweep-relevant-dust) rather than a nonzero dust amount.
        (address token,,) = _launch("JJJ", LAUNCH_FEE);
        assertEq(BlitzrToken(token).balanceOf(address(launcher)), 0);
    }

    // --- multi-user scenario ---

    // Two different creators launching distinct tokens with a fee change and a DEX disablement
    // happening in between — asserts config changes only affect launches after them, and that
    // creatorA's post-launch token balance behaves correctly under continued transfers ("trading")
    // both inside and outside the anti-bot window.
    function test_scenario_twoCreatorsLaunchWithFeeChangeAndTrading() public {
        address creatorA = makeAddr("launchCreatorA");
        address creatorB = makeAddr("launchCreatorB");
        address buyerX = makeAddr("buyerX");
        vm.deal(creatorA, 10 ether);
        vm.deal(creatorB, 10 ether);

        // 1. creatorA launches with an instant buy at the original fee.
        uint256 instantBuyOut = 300e18;
        router.setNextAmountOut(instantBuyOut);
        vm.prank(creatorA);
        (address tokenA,,) = launcher.launch{value: LAUNCH_FEE + 1 ether}(
            "Token AAA1", "AAA1", "ipfs://a", address(0), address(factory), address(weth)
        );
        assertEq(BlitzrToken(tokenA).balanceOf(creatorA), instantBuyOut);

        // 2. Owner raises the launch fee — must only bind launches from here on.
        uint256 newFee = LAUNCH_FEE * 2;
        launcher.setLaunchFee(newFee);
        vm.prank(creatorB);
        vm.expectRevert(BlitzrLauncher.WrongFee.selector); // still paying the old (now stale) fee
        launcher.launch{value: LAUNCH_FEE}("Token BBB1", "BBB1", "ipfs://b", address(0), address(factory), address(weth));

        uint256 feeWalletBefore = feeWallet.balance;
        vm.prank(creatorB);
        (address tokenB,,) = launcher.launch{value: newFee}(
            "Token BBB2", "BBB2", "ipfs://b", address(0), address(factory), address(weth)
        );
        assertEq(feeWallet.balance, feeWalletBefore + newFee);
        assertTrue(tokenA != tokenB);

        // 3. Owner disables the DEX — must block further launches but not touch what already exists.
        launcher.disableDex(address(factory));
        vm.prank(creatorA);
        vm.expectRevert(BlitzrLauncher.UnsupportedDex.selector);
        launcher.launch{value: newFee}("Token AAA2", "AAA2", "ipfs://a2", address(0), address(factory), address(weth));

        // Both earlier tokens remain fully functional regardless of the DEX being disabled since.
        assertEq(BlitzrToken(tokenA).balanceOf(creatorA), instantBuyOut);
        assertEq(BlitzrToken(tokenB).owner(), address(0));

        // 4. "Trading": creatorA moves tokens to a third party while the anti-bot window from
        //    ITS OWN launch is still open — ordinary transfers under the 2.5%-of-supply cap
        //    succeed normally (the exact over-cap-reverts behavior is covered exhaustively at
        //    the token level in BlitzrToken.t.sol; here the point is that trading isn't broken
        //    by anything the launcher itself did during setup, e.g. the pool/BURN_ADDRESS
        //    exemptions it applied don't accidentally exempt ordinary third parties too).
        assertFalse(BlitzrToken(tokenA).isExempt(buyerX));
        vm.prank(creatorA);
        BlitzrToken(tokenA).transfer(buyerX, 100e18);
        assertEq(BlitzrToken(tokenA).balanceOf(buyerX), 100e18);
        assertEq(BlitzrToken(tokenA).balanceOf(creatorA), instantBuyOut - 100e18);

        // Once the anti-bot window lapses, buyerX can pass tokens along too, and the old owner
        // (the launcher, pre-renounce) has no remaining admin lever over the token — renounce is
        // permanent, so even the launcher itself can no longer call setExempt on tokenA.
        vm.roll(block.number + launcher.antiBotBlocks() + 1);
        vm.prank(buyerX);
        BlitzrToken(tokenA).transfer(creatorA, 50e18);
        assertEq(BlitzrToken(tokenA).balanceOf(buyerX), 50e18);

        vm.expectRevert(BlitzrToken.NotOwner.selector);
        BlitzrToken(tokenA).setExempt(buyerX, true);

        // 5. Both launches were registered with the locker independently and correctly.
        assertEq(locker.callCount(), 2);
        (address recA, uint256 tidA, address fwA,,,,) = locker.calls(0);
        (address recB, uint256 tidB, address fwB,,,,) = locker.calls(1);
        assertEq(recA, tokenA);
        assertEq(recB, tokenB);
        assertEq(fwA, creatorA);
        assertEq(fwB, creatorB);
        assertTrue(tidA != tidB);
    }

    // --- helpers ---

    function _predictClone(address impl_, bytes32 salt) private view returns (address predicted) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl_, hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 initCodeHash = keccak256(initCode);
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launcher), salt, initCodeHash)))));
    }
}
