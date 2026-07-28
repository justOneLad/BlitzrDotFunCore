// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrLocker} from "../contracts/BlitzrLocker.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Factory, MockV3Pool, MockPositionManager} from "./mocks/MockUniswapV3.sol";

contract BlitzrLockerTest is Test {
    BlitzrLocker locker;
    MockV3Factory factory;
    MockPositionManager positionManager;

    address owner = address(this);
    address launcher = address(this); // test contract acts as the sole allowlisted launcher
    address platformWallet = makeAddr("platformWallet");
    address feeWallet = makeAddr("feeWallet");
    address dead = 0x000000000000000000000000000000000000dEaD;

    uint24 constant FEE = 10_000;

    function setUp() public {
        locker = new BlitzrLocker(platformWallet);
        locker.setLauncher(launcher, true);

        factory = new MockV3Factory();
        positionManager = new MockPositionManager(address(factory));
    }

    // Deploys a fresh token pair, creates a pool, mints a one-sided position (token is token0
    // side gets `amount`, the other side gets 0) and registers it with the locker. Returns the
    // launched token, its tokenId, and the pool address.
    function _launchAndRegister(uint256 amount, address wallet)
        private returns (MockERC20 launched, address token0, address token1, uint256 tokenId, address pool)
    {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        launched = MockERC20(token0); // pretend token0 is "the launched token" for these tests
        pool = factory.createPool(token0, token1, FEE);

        MockERC20(token0).mint(address(this), amount);
        MockERC20(token0).approve(address(positionManager), amount);

        MockPositionManager.MintParams memory params = MockPositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE,
            tickLower: -200,
            tickUpper: 200,
            amount0Desired: amount,
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(locker),
            deadline: block.timestamp
        });
        (tokenId,,,) = positionManager.mint(params);

        locker.registerPosition(token0, tokenId, wallet, token0, token1, pool, address(positionManager));
    }

    // --- constructor ---

    function test_constructor_revertsOnZeroPlatformWallet() public {
        vm.expectRevert(BlitzrLocker.ZeroAddress.selector);
        new BlitzrLocker(address(0));
    }

    function test_constructor_setsOwnerAndPlatformWallet() public view {
        assertEq(locker.owner(), owner);
        assertEq(locker.platformWallet(), platformWallet);
    }

    // --- admin ---

    function test_setLauncher_onlyOwner() public {
        vm.expectRevert(BlitzrLocker.NotOwner.selector);
        vm.prank(feeWallet);
        locker.setLauncher(feeWallet, true);
    }

    function test_setLauncher_revertsOnZeroAddress() public {
        vm.expectRevert(BlitzrLocker.ZeroAddress.selector);
        locker.setLauncher(address(0), true);
    }

    function test_setPlatformWallet_onlyOwnerNonZero() public {
        vm.expectRevert(BlitzrLocker.NotOwner.selector);
        vm.prank(feeWallet);
        locker.setPlatformWallet(feeWallet);

        vm.expectRevert(BlitzrLocker.ZeroAddress.selector);
        locker.setPlatformWallet(address(0));

        locker.setPlatformWallet(feeWallet);
        assertEq(locker.platformWallet(), feeWallet);
    }

    function test_setFeeBps_onlyOwnerAndMustSumToBps() public {
        vm.expectRevert(BlitzrLocker.NotOwner.selector);
        vm.prank(feeWallet);
        locker.setFeeBps(9000, 1000);

        vm.expectRevert(BlitzrLocker.InvalidBps.selector);
        locker.setFeeBps(9000, 500);

        locker.setFeeBps(9000, 1000);
        assertEq(locker.creatorBps(), 9000);
        assertEq(locker.platformBps(), 1000);
    }

    function test_transferOwnership_onlyOwnerNonZero() public {
        vm.expectRevert(BlitzrLocker.NotOwner.selector);
        vm.prank(feeWallet);
        locker.transferOwnership(feeWallet);

        vm.expectRevert(BlitzrLocker.ZeroAddress.selector);
        locker.transferOwnership(address(0));

        locker.transferOwnership(feeWallet);
        assertEq(locker.owner(), feeWallet);
    }

    // --- registerPosition ---

    function test_registerPosition_onlyLauncher() public {
        vm.expectRevert(BlitzrLocker.NotLauncher.selector);
        vm.prank(feeWallet);
        locker.registerPosition(address(0x1), 1, feeWallet, address(0x1), address(0x2), address(0x3), address(0x4));
    }

    function test_registerPosition_revertsIfAlreadyRegistered() public {
        (MockERC20 token,,, uint256 tokenId, address pool) = _launchAndRegister(1000e18, feeWallet);
        vm.expectRevert(BlitzrLocker.AlreadyRegistered.selector);
        locker.registerPosition(address(token), tokenId, feeWallet, address(token), address(0x2), pool, address(positionManager));
    }

    function test_registerPosition_incrementsTokenCount() public {
        _launchAndRegister(1000e18, feeWallet);
        assertEq(locker.tokenCount(), 1);
        _launchAndRegister(1000e18, feeWallet);
        assertEq(locker.tokenCount(), 2);
    }

    // --- burn toggle ---

    function test_setBurnEnabled_revertsOnUnknownToken() public {
        vm.expectRevert(BlitzrLocker.UnknownToken.selector);
        locker.setBurnEnabled(address(0xdead), true);
    }

    function test_setBurnEnabled_feeWalletOrOwnerOnly() public {
        (MockERC20 token,,,,) = _launchAndRegister(1000e18, feeWallet);

        vm.expectRevert(BlitzrLocker.NotAuthorized.selector);
        vm.prank(makeAddr("rando"));
        locker.setBurnEnabled(address(token), true);

        vm.prank(feeWallet);
        locker.setBurnEnabled(address(token), true);
        assertTrue(locker.burnEnabled(address(token)));

        locker.setBurnEnabled(address(token), false); // owner can too
        assertFalse(locker.burnEnabled(address(token)));
    }

    // --- claimFees: access control ---

    function test_claimFees_revertsOnUnknownToken() public {
        vm.expectRevert(BlitzrLocker.UnknownToken.selector);
        locker.claimFees(address(0xdead));
    }

    function test_claimFees_authorizedCallersOnly() public {
        (MockERC20 token,,,,) = _launchAndRegister(1000e18, feeWallet);

        vm.expectRevert(BlitzrLocker.NotAuthorized.selector);
        vm.prank(makeAddr("rando"));
        locker.claimFees(address(token));

        vm.prank(feeWallet); // feeWallet allowed
        locker.claimFees(address(token));

        locker.claimFees(address(token)); // owner allowed
    }

    function test_claimFees_noopWhenNothingCollectable() public {
        (MockERC20 token,,,,) = _launchAndRegister(1000e18, feeWallet);
        // No collectable set — should return quietly, no revert.
        locker.claimFees(address(token));
    }

    // --- claimFees: distribution math ---

    function test_claimFees_splitsCreatorAndPlatformShares() public {
        (MockERC20 token, address token0, address token1, uint256 tokenId, address pool) = _launchAndRegister(1000e18, feeWallet);
        MockERC20(token0).mint(pool, 1000e18); // fee leg 0
        MockERC20(token1).mint(pool, 500e18);  // fee leg 1
        positionManager.setCollectable(tokenId, 1000e18, 500e18);

        locker.claimFees(address(token));

        // default creatorBps 8000 / platformBps 2000
        assertEq(MockERC20(token0).balanceOf(feeWallet), 800e18);
        assertEq(MockERC20(token0).balanceOf(platformWallet), 200e18);
        assertEq(MockERC20(token1).balanceOf(feeWallet), 400e18);
        assertEq(MockERC20(token1).balanceOf(platformWallet), 100e18);
    }

    function test_claimFees_burnEnabled_routesLaunchedTokenLegToDeadAddress() public {
        (MockERC20 token, address token0, address token1, uint256 tokenId, address pool) = _launchAndRegister(1000e18, feeWallet);
        vm.prank(feeWallet);
        locker.setBurnEnabled(address(token), true); // token == token0 in this setup

        MockERC20(token0).mint(pool, 1000e18);
        MockERC20(token1).mint(pool, 500e18);
        positionManager.setCollectable(tokenId, 1000e18, 500e18);

        locker.claimFees(address(token));

        // token0 leg (the launched token itself) burns entirely; token1 (quote) still splits normally.
        assertEq(MockERC20(token0).balanceOf(dead), 1000e18);
        assertEq(MockERC20(token0).balanceOf(feeWallet), 0);
        assertEq(MockERC20(token0).balanceOf(platformWallet), 0);
        assertEq(MockERC20(token1).balanceOf(feeWallet), 400e18);
        assertEq(MockERC20(token1).balanceOf(platformWallet), 100e18);
    }

    function test_claimFees_customFeeBpsApplied() public {
        locker.setFeeBps(9000, 1000);
        (MockERC20 token, address token0,, uint256 tokenId, address pool) = _launchAndRegister(1000e18, feeWallet);
        MockERC20(token0).mint(pool, 1000e18);
        positionManager.setCollectable(tokenId, 1000e18, 0);

        locker.claimFees(address(token));
        assertEq(MockERC20(token0).balanceOf(feeWallet), 900e18);
        assertEq(MockERC20(token0).balanceOf(platformWallet), 100e18);
    }

    // --- claimAllFees / claimFeesRange ---

    function test_claimAllFees_processesEveryRegisteredToken() public {
        (MockERC20 t1, address t1t0,, uint256 id1, address pool1) = _launchAndRegister(1000e18, feeWallet);
        (MockERC20 t2, address t2t0,, uint256 id2, address pool2) = _launchAndRegister(1000e18, feeWallet);

        MockERC20(t1t0).mint(pool1, 100e18);
        positionManager.setCollectable(id1, 100e18, 0);
        MockERC20(t2t0).mint(pool2, 200e18);
        positionManager.setCollectable(id2, 200e18, 0);

        locker.claimAllFees();

        assertEq(MockERC20(t1t0).balanceOf(feeWallet), 80e18);
        assertEq(MockERC20(t2t0).balanceOf(feeWallet), 160e18);
    }

    function test_claimAllFees_skipsFailingEntriesWithoutReverting() public {
        (MockERC20 good, address goodT0,, uint256 goodId, address goodPool) = _launchAndRegister(1000e18, feeWallet);
        // Register a second "position" whose positionManager is an address with no code —
        // IPositionManager.collect() on it will revert during ABI-decoding of empty returndata,
        // exercising claimAllFees' try/catch skip path.
        MockERC20 broken = new MockERC20("Broken", "BRK", 18);
        locker.registerPosition(address(broken), 1, feeWallet, address(broken), address(0x2), address(0x3), address(0xBAD));

        MockERC20(goodT0).mint(goodPool, 100e18);
        positionManager.setCollectable(goodId, 100e18, 0);

        locker.claimAllFees(); // must not revert despite the broken entry

        assertEq(MockERC20(goodT0).balanceOf(feeWallet), 80e18);
    }

    function test_claimFeesRange_paginatesAndClampsToLength() public {
        _launchAndRegister(1000e18, feeWallet);
        _launchAndRegister(1000e18, feeWallet);
        assertEq(locker.tokenCount(), 2);

        // `to` beyond length must clamp instead of reverting out-of-bounds.
        locker.claimFeesRange(0, 100);
    }

    // --- pendingCreatorFees ---

    function test_pendingCreatorFees_revertsOnUnknownToken() public {
        vm.expectRevert(BlitzrLocker.UnknownToken.selector);
        locker.pendingCreatorFees(address(0xdead));
    }

    function test_pendingCreatorFees_returnsZeroWhenLiquidityIsZero() public {
        (MockERC20 token,,, uint256 tokenId,) = _launchAndRegister(1000e18, feeWallet);
        positionManager.setLiquidity(tokenId, 0);
        (,, uint256 amount0, uint256 amount1) = locker.pendingCreatorFees(address(token));
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_pendingCreatorFees_computesCreatorShareFromFeeGrowth() public {
        (MockERC20 token,,, uint256 tokenId, address pool) = _launchAndRegister(1000e18, feeWallet);

        // liquidity = 2^64, feeGrowthGlobal0X128 = 2^64 * 1000 → raw0 = liq*fgi0/2^128 = 1000
        // exactly, no truncation. currentTick (0, the mock's default) sits inside [-200, 200],
        // and both tick infos are left at 0, so feeGrowthInside == feeGrowthGlobal here.
        uint128 liquidity = uint128(2 ** 64);
        uint256 fgGlobal0 = (2 ** 64) * 1000;
        positionManager.setLiquidity(tokenId, liquidity);
        positionManager.setFeeGrowthInsideLast(tokenId, 0, 0);
        MockV3Pool(pool).setFeeGrowthGlobal(fgGlobal0, 0);

        (,, uint256 amount0, uint256 amount1) = locker.pendingCreatorFees(address(token));
        assertEq(amount0, 800); // 1000 * 8000 / 10000
        assertEq(amount1, 0);
    }

    function test_pendingCreatorFees_zeroedForBurningLeg() public {
        (MockERC20 token,,, uint256 tokenId, address pool) = _launchAndRegister(1000e18, feeWallet);
        vm.prank(feeWallet);
        locker.setBurnEnabled(address(token), true);

        uint128 liquidity = uint128(2 ** 64);
        uint256 fgGlobal0 = (2 ** 64) * 1000;
        positionManager.setLiquidity(tokenId, liquidity);
        MockV3Pool(pool).setFeeGrowthGlobal(fgGlobal0, 0);

        (,, uint256 amount0,) = locker.pendingCreatorFees(address(token));
        assertEq(amount0, 0); // token0 == the launched (burning) token → reported as 0
    }

    // --- CTO ---

    function test_applyForCTO_revertsOnUnknownToken() public {
        vm.expectRevert(BlitzrLocker.UnknownToken.selector);
        locker.applyForCTO(address(0xdead), feeWallet);
    }

    function test_applyForCTO_revertsOnWrongFee() public {
        (MockERC20 token,,,,) = _launchAndRegister(1000e18, feeWallet);
        vm.expectRevert(BlitzrLocker.WrongFee.selector);
        locker.applyForCTO{value: 0.01 ether}(address(token), makeAddr("applicant2"));
    }

    function test_applyForCTO_recordsApplicationAndForwardsFee() public {
        (MockERC20 token,,,,) = _launchAndRegister(1000e18, feeWallet);
        address applicant = makeAddr("applicant");
        vm.deal(applicant, 1 ether);

        vm.prank(applicant);
        locker.applyForCTO{value: 0.05 ether}(address(token), applicant);

        (address a, address proposed, uint256 paid) = locker.ctoApplications(address(token));
        assertEq(a, applicant);
        assertEq(proposed, applicant);
        assertEq(paid, 0.05 ether);
        assertEq(platformWallet.balance, 0.05 ether);
    }

    function test_ctoFeeWallet_onlyOwner() public {
        (MockERC20 token,,,,) = _launchAndRegister(1000e18, feeWallet);
        vm.expectRevert(BlitzrLocker.NotOwner.selector);
        vm.prank(feeWallet);
        locker.ctoFeeWallet(address(token), makeAddr("newWallet"));
    }

    function test_ctoFeeWallet_revertsOnUnknownToken() public {
        vm.expectRevert(BlitzrLocker.UnknownToken.selector);
        locker.ctoFeeWallet(address(0xdead), feeWallet);
    }

    function test_ctoFeeWallet_reassignsAndClearsApplication() public {
        (MockERC20 token,,,,) = _launchAndRegister(1000e18, feeWallet);
        address applicant = makeAddr("applicant");
        vm.deal(applicant, 1 ether);
        vm.prank(applicant);
        locker.applyForCTO{value: 0.05 ether}(address(token), applicant);

        address newWallet = makeAddr("newWallet");
        locker.ctoFeeWallet(address(token), newWallet);

        (,address newFeeWallet,,,,) = locker.positions(address(token));
        assertEq(newFeeWallet, newWallet);
        (address a,,) = locker.ctoApplications(address(token));
        assertEq(a, address(0)); // cleared
    }

    function test_setCTOFee_onlyOwner() public {
        vm.expectRevert(BlitzrLocker.NotOwner.selector);
        vm.prank(feeWallet);
        locker.setCTOFee(1 ether);
        locker.setCTOFee(1 ether);
        assertEq(locker.ctoFee(), 1 ether);
    }

    // --- ERC721 receiver ---

    function test_onERC721Received_returnsSelector() public view {
        bytes4 selector = locker.onERC721Received(address(0), address(0), 0, "");
        assertEq(selector, bytes4(0x150b7a02));
    }

    // --- multi-user / multi-token scenario ---

    // Two independently-launched tokens with distinct creators, interleaving claims, burn
    // toggles, and CTO actions across both — asserts every action stays scoped to the token it
    // targets and never leaks into the other token's state or balances.
    function test_scenario_twoTokensInterleavedByDifferentUsers() public {
        address creatorA = makeAddr("creatorA");
        address creatorB = makeAddr("creatorB");
        address randoC = makeAddr("randoC");

        (MockERC20 tokenA, address a0, address a1, uint256 idA, address poolA) = _launchAndRegister(1000e18, creatorA);
        (MockERC20 tokenB, address b0, address b1, uint256 idB, address poolB) = _launchAndRegister(1000e18, creatorB);
        assertEq(locker.tokenCount(), 2);

        // 1. creatorA enables burn on token A only.
        vm.prank(creatorA);
        locker.setBurnEnabled(address(tokenA), true);
        assertTrue(locker.burnEnabled(address(tokenA)));
        assertFalse(locker.burnEnabled(address(tokenB))); // untouched

        // 2. randoC applies for CTO on token B only; token A has no pending application.
        vm.deal(randoC, 1 ether);
        vm.prank(randoC);
        locker.applyForCTO{value: 0.05 ether}(address(tokenB), randoC);
        (address applicantA,,) = locker.ctoApplications(address(tokenA));
        (address applicantB,,) = locker.ctoApplications(address(tokenB));
        assertEq(applicantA, address(0));
        assertEq(applicantB, randoC);

        // 3. Fees accrue on both pools simultaneously; claimAllFees must distribute each
        //    correctly — A burns its launched-token leg (creatorA gets none of that leg),
        //    B splits normally to creatorB.
        MockERC20(a0).mint(poolA, 200e18);
        MockERC20(a1).mint(poolA, 50e18);
        positionManager.setCollectable(idA, 200e18, 50e18);

        MockERC20(b0).mint(poolB, 300e18);
        MockERC20(b1).mint(poolB, 75e18);
        positionManager.setCollectable(idB, 300e18, 75e18);

        locker.claimAllFees();

        assertEq(MockERC20(a0).balanceOf(dead), 200e18); // A's launched-token leg burned
        assertEq(MockERC20(a0).balanceOf(creatorA), 0);
        assertEq(MockERC20(a1).balanceOf(creatorA), 40e18); // 50 * 8000/10000, quote leg unaffected by burn
        assertEq(MockERC20(b0).balanceOf(creatorB), 240e18); // 300 * 8000/10000, no burn on B
        assertEq(MockERC20(b1).balanceOf(creatorB), 60e18); // 75 * 8000/10000

        // 4. Owner approves B's CTO, reassigning its feeWallet — must not touch A's feeWallet
        //    or clear A's (nonexistent) application.
        locker.ctoFeeWallet(address(tokenB), randoC);
        (, address feeWalletA,,,,) = locker.positions(address(tokenA));
        (, address feeWalletB,,,,) = locker.positions(address(tokenB));
        assertEq(feeWalletA, creatorA); // unchanged
        assertEq(feeWalletB, randoC);   // reassigned
        (address clearedApplicantB,,) = locker.ctoApplications(address(tokenB));
        assertEq(clearedApplicantB, address(0)); // cleared on approval

        // 5. Further claims on B now pay out to the new feeWallet (randoC), while A still pays
        //    its original creator.
        MockERC20(a1).mint(poolA, 10e18);
        positionManager.setCollectable(idA, 0, 10e18);
        MockERC20(b0).mint(poolB, 40e18);
        positionManager.setCollectable(idB, 40e18, 0);

        locker.claimFeesRange(0, locker.tokenCount());

        assertEq(MockERC20(a1).balanceOf(creatorA), 40e18 + 8e18); // += 10 * 8000/10000
        assertEq(MockERC20(b0).balanceOf(randoC), 32e18); // 40 * 8000/10000, new feeWallet
        assertEq(MockERC20(b0).balanceOf(creatorB), 240e18); // creatorB's earlier balance untouched
    }
}
