// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {
    XBlitzrHook, Currency, PoolKey, PoolIdLibrary, ModifyLiquidityParams, SwapParams, BalanceDelta
} from "../xBlitzr/XBlitzrHook.sol";
import {MockPoolManagerV4} from "./mocks/MockPoolManagerV4.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract XBlitzrHookTest is Test {
    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 constant AFTER_SWAP_FLAG = 1 << 6;
    uint160 constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 constant REQUIRED_FLAGS =
        BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG | AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG;

    XBlitzrHook hook;
    MockPoolManagerV4 poolManager;

    address owner = address(this);
    address platformWallet = makeAddr("platformWallet");
    address launcher = makeAddr("launcher");
    address feeWallet = makeAddr("feeWallet");

    function setUp() public {
        poolManager = new MockPoolManagerV4();
        hook = _deployHook(address(poolManager), platformWallet, owner);

        vm.prank(owner);
        hook.setLauncher(launcher);
    }

    function _deployHook(address poolManager_, address platformWallet_, address owner_) private returns (XBlitzrHook) {
        bytes memory creationCode = abi.encodePacked(
            type(XBlitzrHook).creationCode, abi.encode(poolManager_, platformWallet_, owner_)
        );
        (address predicted, bytes32 salt) = HookMiner.find(address(this), ALL_HOOK_MASK, REQUIRED_FLAGS, creationCode);
        XBlitzrHook deployed = new XBlitzrHook{salt: salt}(poolManager_, platformWallet_, owner_);
        require(address(deployed) == predicted, "salt mismatch");
        return deployed;
    }

    function _key(address c0, address c1) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000,
            tickSpacing: 200,
            hooks: address(hook)
        });
    }

    function _packDelta(int128 a0, int128 a1) private pure returns (BalanceDelta) {
        int256 packed = (int256(a0) << 128) | int256(uint256(uint128(a1)));
        return BalanceDelta.wrap(packed);
    }

    // --- constructor ---

    function test_constructor_revertsOnBadHookAddress() public {
        // A plain `new` deployment (no mined salt) will essentially never land on an address
        // whose low 14 bits happen to equal REQUIRED_FLAGS.
        vm.expectRevert(XBlitzrHook.BadHookAddress.selector);
        new XBlitzrHook(address(poolManager), platformWallet, owner);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        bytes memory creationCode1 = abi.encodePacked(type(XBlitzrHook).creationCode, abi.encode(address(0), platformWallet, owner));
        (, bytes32 salt1) = HookMiner.find(address(this), ALL_HOOK_MASK, REQUIRED_FLAGS, creationCode1);
        vm.expectRevert(XBlitzrHook.ZeroAddress.selector);
        new XBlitzrHook{salt: salt1}(address(0), platformWallet, owner);
    }

    function test_constructor_setsImmutablesAndOwner() public view {
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.owner(), owner);
        assertEq(hook.platformWallet(), platformWallet);
        assertEq(hook.launcher(), launcher);
    }

    // --- admin ---

    function test_setLauncher_onlyOwner() public {
        vm.expectRevert(XBlitzrHook.NotOwner.selector);
        vm.prank(feeWallet);
        hook.setLauncher(feeWallet);
    }

    function test_setPlatformWallet_onlyOwnerNonZero() public {
        vm.expectRevert(XBlitzrHook.NotOwner.selector);
        vm.prank(feeWallet);
        hook.setPlatformWallet(feeWallet);

        vm.expectRevert(XBlitzrHook.ZeroAddress.selector);
        hook.setPlatformWallet(address(0));

        hook.setPlatformWallet(feeWallet);
        assertEq(hook.platformWallet(), feeWallet);
    }

    function test_setHookFeeBps_onlyOwnerAndBounded() public {
        vm.expectRevert(XBlitzrHook.NotOwner.selector);
        vm.prank(feeWallet);
        hook.setHookFeeBps(100);

        vm.expectRevert(XBlitzrHook.InvalidBps.selector);
        hook.setHookFeeBps(10_001);

        hook.setHookFeeBps(500);
        assertEq(hook.hookFeeBps(), 500);
    }

    function test_setFeeBps_defaultsAndOnlyOwnerMustSumToBps() public {
        assertEq(hook.creatorBps(), 8_000);
        assertEq(hook.platformBps(), 2_000);

        vm.expectRevert(XBlitzrHook.NotOwner.selector);
        vm.prank(feeWallet);
        hook.setFeeBps(9000, 1000);

        vm.expectRevert(XBlitzrHook.InvalidBps.selector);
        hook.setFeeBps(9000, 500);

        hook.setFeeBps(9000, 1000);
        assertEq(hook.creatorBps(), 9000);
        assertEq(hook.platformBps(), 1000);
    }

    function test_transferOwnership_onlyOwnerNonZero() public {
        vm.expectRevert(XBlitzrHook.NotOwner.selector);
        vm.prank(feeWallet);
        hook.transferOwnership(feeWallet);

        hook.transferOwnership(feeWallet);
        assertEq(hook.owner(), feeWallet);
    }

    // --- registerPosition ---

    function test_registerPosition_onlyLauncher() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.expectRevert(XBlitzrHook.NotLauncher.selector);
        hook.registerPosition(address(0x3), key, feeWallet);
    }

    function test_registerPosition_revertsIfAlreadyRegistered() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.startPrank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);
        vm.expectRevert(XBlitzrHook.AlreadyRegistered.selector);
        hook.registerPosition(address(0x3), key, feeWallet);
        vm.stopPrank();
    }

    function test_registerPosition_storesPositionAndPoolIdMapping() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.prank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);

        (address fw, Currency c0, Currency c1) = hook.positions(address(0x3));
        assertEq(fw, feeWallet);
        assertEq(Currency.unwrap(c0), address(0x1));
        assertEq(Currency.unwrap(c1), address(0x2));
        assertEq(hook.tokenCount(), 1);
    }

    // --- beforeAddLiquidity / beforeRemoveLiquidity ---

    function test_beforeAddLiquidity_onlyPoolManager() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        ModifyLiquidityParams memory params = ModifyLiquidityParams(0, 0, 0, bytes32(0));
        vm.expectRevert(XBlitzrHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(launcher, key, params, "");
    }

    function test_beforeAddLiquidity_revertsForNonLauncherSender() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        ModifyLiquidityParams memory params = ModifyLiquidityParams(0, 0, 0, bytes32(0));
        vm.prank(address(poolManager));
        vm.expectRevert(XBlitzrHook.LiquidityLocked.selector);
        hook.beforeAddLiquidity(feeWallet, key, params, "");
    }

    function test_beforeAddLiquidity_allowsLauncher() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        ModifyLiquidityParams memory params = ModifyLiquidityParams(0, 0, 0, bytes32(0));
        vm.prank(address(poolManager));
        bytes4 selector = hook.beforeAddLiquidity(launcher, key, params, "");
        assertEq(selector, hook.beforeAddLiquidity.selector);
    }

    function test_beforeRemoveLiquidity_onlyPoolManager() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        ModifyLiquidityParams memory params = ModifyLiquidityParams(0, 0, 0, bytes32(0));
        vm.expectRevert(XBlitzrHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(launcher, key, params, "");
    }

    function test_beforeRemoveLiquidity_revertsOnNonzeroDeltaEvenFromLauncher() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        ModifyLiquidityParams memory params = ModifyLiquidityParams(0, 0, -100, bytes32(0));
        vm.prank(address(poolManager));
        vm.expectRevert(XBlitzrHook.LiquidityLocked.selector);
        hook.beforeRemoveLiquidity(launcher, key, params, "");
    }

    function test_beforeRemoveLiquidity_revertsOnZeroDeltaFromNonLauncher() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        ModifyLiquidityParams memory params = ModifyLiquidityParams(0, 0, 0, bytes32(0));
        vm.prank(address(poolManager));
        vm.expectRevert(XBlitzrHook.LiquidityLocked.selector);
        hook.beforeRemoveLiquidity(feeWallet, key, params, "");
    }

    function test_beforeRemoveLiquidity_allowsZeroDeltaPokeFromLauncher() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        ModifyLiquidityParams memory params = ModifyLiquidityParams(0, 0, 0, bytes32(0));
        vm.prank(address(poolManager));
        bytes4 selector = hook.beforeRemoveLiquidity(launcher, key, params, "");
        assertEq(selector, hook.beforeRemoveLiquidity.selector);
    }

    // --- afterSwap ---

    function test_afterSwap_onlyPoolManager() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        SwapParams memory params = SwapParams(true, -1000, 0);
        vm.expectRevert(XBlitzrHook.NotPoolManager.selector);
        hook.afterSwap(launcher, key, params, _packDelta(-990, 1000), "");
    }

    function test_afterSwap_unregisteredTokenReturnsZeroWithoutTake() public {
        PoolKey memory key = _key(address(0x1), address(0x2)); // never registered
        SwapParams memory params = SwapParams(true, -1000, 0);
        vm.prank(address(poolManager));
        (bytes4 selector, int128 delta) = hook.afterSwap(launcher, key, params, _packDelta(-990, 1000), "");
        assertEq(selector, hook.afterSwap.selector);
        assertEq(delta, 0);
        assertEq(poolManager.takeCallCount(), 0);
    }

    function test_afterSwap_zeroUnspecifiedAmountSkipsTake() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.prank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);

        // zeroForOne=true, amountSpecified<0 → unspecified leg is currency1; set it to 0.
        SwapParams memory params = SwapParams(true, -1000, 0);
        vm.prank(address(poolManager));
        (, int128 delta) = hook.afterSwap(launcher, key, params, _packDelta(-1000, 0), "");
        assertEq(delta, 0);
        assertEq(poolManager.takeCallCount(), 0);
    }

    function test_afterSwap_roundsDownToZeroCutSkipsTake() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.prank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);

        // hookFeeBps default 35 (0.35%); gross=1 → 1*35/10000 == 0 after truncation.
        SwapParams memory params = SwapParams(true, -1000, 0);
        vm.prank(address(poolManager));
        (, int128 delta) = hook.afterSwap(launcher, key, params, _packDelta(-1000, 1), "");
        assertEq(delta, 0);
        assertEq(poolManager.takeCallCount(), 0);
    }

    function test_afterSwap_capturesFeeAndCallsTake() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.prank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);

        // unspecified leg = currency1, gross = 10_000 → cut = 10_000*35/10_000 = 35, split
        // 80/20 (default creatorBps/platformBps) → creator 28, platform 7.
        SwapParams memory params = SwapParams(true, -9999, 0);
        vm.prank(address(poolManager));
        (bytes4 selector, int128 delta) = hook.afterSwap(launcher, key, params, _packDelta(-9999, 10_000), "");

        assertEq(selector, hook.afterSwap.selector);
        assertEq(delta, 35); // total cut, regardless of how many recipients it's split across
        assertEq(poolManager.takeCallCount(), 2);
        assertEq(poolManager.totalTaken(address(0x2), feeWallet), 28);
        assertEq(poolManager.totalTaken(address(0x2), platformWallet), 7);
    }

    function test_afterSwap_negativeUnspecifiedAmountUsesAbsoluteValue() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.prank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);

        // zeroForOne=false, amountSpecified<0 → unspecified is currency0; make it negative.
        SwapParams memory params = SwapParams(false, -9999, 0);
        vm.prank(address(poolManager));
        (, int128 delta) = hook.afterSwap(launcher, key, params, _packDelta(-10_000, 9999), "");

        assertEq(delta, 35);
        assertEq(poolManager.totalTaken(address(0x1), feeWallet), 28);
        assertEq(poolManager.totalTaken(address(0x1), platformWallet), 7);
    }

    function test_afterSwap_zeroCreatorBpsSendsEntireCutToPlatform() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.prank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);
        hook.setFeeBps(0, 10_000);

        SwapParams memory params = SwapParams(true, -9999, 0);
        vm.prank(address(poolManager));
        hook.afterSwap(launcher, key, params, _packDelta(-9999, 10_000), "");

        assertEq(poolManager.totalTaken(address(0x2), feeWallet), 0);
        assertEq(poolManager.totalTaken(address(0x2), platformWallet), 35);
    }

    // --- CTO flow ---

    function test_applyForCTO_revertsOnUnknownToken() public {
        vm.expectRevert(XBlitzrHook.UnknownToken.selector);
        hook.applyForCTO(address(0x3), feeWallet);
    }

    function test_applyForCTO_revertsOnWrongFee() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.prank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);

        vm.expectRevert(XBlitzrHook.WrongFee.selector);
        hook.applyForCTO{value: 0.01 ether}(address(0x3), feeWallet);
    }

    function test_applyForCTO_recordsAndForwardsFee() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.prank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);

        address applicant = makeAddr("applicant");
        vm.deal(applicant, 1 ether);
        vm.prank(applicant);
        hook.applyForCTO{value: 0.05 ether}(address(0x3), applicant);

        (address a, address proposed, uint256 paid) = hook.ctoApplications(address(0x3));
        assertEq(a, applicant);
        assertEq(proposed, applicant);
        assertEq(paid, 0.05 ether);
        assertEq(platformWallet.balance, 0.05 ether);
    }

    function test_ctoFeeWallet_onlyOwnerAndReassigns() public {
        PoolKey memory key = _key(address(0x1), address(0x2));
        vm.prank(launcher);
        hook.registerPosition(address(0x3), key, feeWallet);

        vm.expectRevert(XBlitzrHook.NotOwner.selector);
        vm.prank(feeWallet);
        hook.ctoFeeWallet(address(0x3), makeAddr("newWallet"));

        address newWallet = makeAddr("newWallet");
        hook.ctoFeeWallet(address(0x3), newWallet);
        (address fw,,) = hook.positions(address(0x3));
        assertEq(fw, newWallet);
    }

    function test_setCTOFee_onlyOwner() public {
        vm.expectRevert(XBlitzrHook.NotOwner.selector);
        vm.prank(feeWallet);
        hook.setCTOFee(1 ether);
        hook.setCTOFee(1 ether);
        assertEq(hook.ctoFee(), 1 ether);
    }

    // --- multi-token trading scenario ---

    // Two independently-registered pools with multiple swaps interleaved across both, plus a
    // CTO application landing on one mid-sequence — asserts fee capture accumulates correctly
    // per pool (not globally) and that CTO/trading activity on one pool never touches the other.
    function test_scenario_twoPoolsInterleavedSwapsAndCTO() public {
        address tokenX = makeAddr("tokenX");
        address tokenY = makeAddr("tokenY");
        address feeWalletX = makeAddr("feeWalletX");
        address feeWalletY = makeAddr("feeWalletY");
        PoolKey memory keyX = _key(address(0x10), address(0x20));
        PoolKey memory keyY = _key(address(0x30), address(0x40));

        vm.startPrank(launcher);
        hook.registerPosition(tokenX, keyX, feeWalletX);
        hook.registerPosition(tokenY, keyY, feeWalletY);
        vm.stopPrank();

        SwapParams memory params = SwapParams(true, -9999, 0); // unspecified leg = currency1, gross 10_000

        // Swap #1 on pool X.
        vm.prank(address(poolManager));
        hook.afterSwap(launcher, keyX, params, _packDelta(-9999, 10_000), "");
        // Swap #1 on pool Y, independently.
        vm.prank(address(poolManager));
        hook.afterSwap(launcher, keyY, params, _packDelta(-9999, 10_000), "");

        // A CTO application lands on pool X's token mid-sequence — must not disturb Y at all.
        address applicant = makeAddr("xApplicant");
        vm.deal(applicant, 1 ether);
        vm.prank(applicant);
        hook.applyForCTO{value: 0.05 ether}(tokenX, applicant);
        (address yApplicant,,) = hook.ctoApplications(tokenY);
        assertEq(yApplicant, address(0)); // untouched

        // Swap #2 on pool X only — Y's accumulated total must stay exactly where swap #1 left it.
        vm.prank(address(poolManager));
        hook.afterSwap(launcher, keyX, params, _packDelta(-9999, 10_000), "");

        // currency1 for both keys is address(0x20) and address(0x40) respectively — distinct, so
        // totals must never mix even though both split into the same platformWallet. Each swap's
        // cut of 35 splits 80/20 (default creatorBps/platformBps) → creator 28, platform 7.
        assertEq(poolManager.totalTaken(address(0x20), feeWalletX), 56); // two X swaps * 28
        assertEq(poolManager.totalTaken(address(0x20), platformWallet), 14); // two X swaps * 7
        assertEq(poolManager.totalTaken(address(0x40), feeWalletY), 28); // one Y swap * 28
        assertEq(poolManager.totalTaken(address(0x40), platformWallet), 7); // one Y swap * 7

        // Owner approves X's CTO — Y's feeWallet must be completely unaffected.
        hook.ctoFeeWallet(tokenX, applicant);
        (address fwX,,) = hook.positions(tokenX);
        (address fwY,,) = hook.positions(tokenY);
        assertEq(fwX, applicant);
        assertEq(fwY, feeWalletY);

        // Trading continues on Y after X's CTO resolved — still accrues independently. Note
        // Y's feeWallet is unaffected by X's CTO, so the creator share still lands on feeWalletY.
        vm.prank(address(poolManager));
        hook.afterSwap(launcher, keyY, params, _packDelta(-9999, 10_000), "");
        assertEq(poolManager.totalTaken(address(0x40), feeWalletY), 56); // two Y swaps * 28
        assertEq(poolManager.totalTaken(address(0x40), platformWallet), 14); // two Y swaps * 7
        assertEq(poolManager.totalTaken(address(0x20), feeWalletX), 56); // X unchanged by Y's swap
        assertEq(poolManager.totalTaken(address(0x20), platformWallet), 14); // X unchanged by Y's swap
    }
}
