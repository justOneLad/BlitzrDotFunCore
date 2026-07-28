// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrLocker} from "../../contracts/BlitzrLocker.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Factory, MockPositionManager} from "../mocks/MockUniswapV3.sol";
import {BlitzrLockerHandler} from "./handlers/BlitzrLockerHandler.sol";

// Stateful fuzz: random fee accrual/claim/burn-toggle sequences across several registered
// tokens. claimFees/claimAllFees always fully collect-then-distribute in one call (see
// BlitzrLocker._collectAndDistribute) — there is no code path that leaves collected fees sitting
// in the locker itself, so its balance of any registered token's legs should always be zero,
// no matter what sequence of claims/toggles ran beforehand.
contract BlitzrLockerInvariantsTest is Test {
    BlitzrLocker locker;
    MockV3Factory factory;
    MockPositionManager positionManager;
    BlitzrLockerHandler handler;

    address platformWallet = makeAddr("invPlatformWallet");
    address feeWallet = makeAddr("invFeeWallet");

    function setUp() public {
        locker = new BlitzrLocker(platformWallet);
        factory = new MockV3Factory();
        positionManager = new MockPositionManager(address(factory));

        handler = new BlitzrLockerHandler(locker, factory, positionManager, feeWallet);
        locker.setLauncher(address(handler), true);

        // Seed a fixed set of tokens up front — registerToken itself is not a fuzz target
        // (see targetSelector below), so this set never grows mid-run.
        for (uint256 i; i < 3; i++) {
            handler.registerToken();
        }

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.accrueAndClaim.selector;
        selectors[1] = handler.toggleBurn.selector;
        selectors[2] = handler.claimAll.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_lockerNeverRetainsCollectedFees() public view {
        uint256 n = handler.launchedTokenCount();
        for (uint256 i; i < n; i++) {
            address t0 = handler.launchedTokens(i);
            address t1 = handler.quoteTokens(i);
            assertEq(MockERC20(t0).balanceOf(address(locker)), 0);
            assertEq(MockERC20(t1).balanceOf(address(locker)), 0);
        }
    }
}
