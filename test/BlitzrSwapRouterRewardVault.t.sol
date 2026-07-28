// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrSwapRouterRewardVault} from "../BlitzrSwapRouter/BlitzrSwapRouterRewardVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BlitzrSwapRouterRewardVaultTest is Test {
    BlitzrSwapRouterRewardVault vault;
    MockERC20 token;

    address owner = makeAddr("owner");
    address router = makeAddr("router");
    address alice = makeAddr("alice");
    address swapper = makeAddr("swapper");

    function setUp() public {
        vault = new BlitzrSwapRouterRewardVault(owner, router);
        token = new MockERC20("Reward", "RWD", 18);
    }

    function test_constructor_setsOwnerAndRouter() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.router(), router);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(BlitzrSwapRouterRewardVault.ZeroAddress.selector);
        new BlitzrSwapRouterRewardVault(address(0), router);
    }

    function test_constructor_allowsZeroRouter() public {
        BlitzrSwapRouterRewardVault v = new BlitzrSwapRouterRewardVault(owner, address(0));
        assertEq(v.router(), address(0));
    }

    function test_setRouter_onlyOwner() public {
        vm.expectRevert(BlitzrSwapRouterRewardVault.NotOwner.selector);
        vm.prank(alice);
        vault.setRouter(alice);

        vm.prank(owner);
        vault.setRouter(alice);
        assertEq(vault.router(), alice);
    }

    function test_transferOwnership_onlyOwnerNonZero() public {
        vm.expectRevert(BlitzrSwapRouterRewardVault.NotOwner.selector);
        vm.prank(alice);
        vault.transferOwnership(alice);

        vm.prank(owner);
        vm.expectRevert(BlitzrSwapRouterRewardVault.ZeroAddress.selector);
        vault.transferOwnership(address(0));

        vm.prank(owner);
        vault.transferOwnership(alice);
        assertEq(vault.owner(), alice);
    }

    function test_fund_pullsViaTransferFromAndIsPermissionless() public {
        token.mint(alice, 1000e18);
        vm.prank(alice);
        token.approve(address(vault), 1000e18);

        vm.prank(alice);
        vault.fund(address(token), 1000e18);

        assertEq(token.balanceOf(address(vault)), 1000e18);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_fund_revertsOnZeroAmount() public {
        vm.expectRevert(BlitzrSwapRouterRewardVault.ZeroAmount.selector);
        vault.fund(address(token), 0);
    }

    function test_payout_onlyRouter() public {
        token.mint(address(vault), 1000e18);
        vm.expectRevert(BlitzrSwapRouterRewardVault.NotOwner.selector);
        vm.prank(alice);
        vault.payout(address(token), alice, 100e18, swapper);
    }

    function test_payout_transfersAndEmits() public {
        token.mint(address(vault), 1000e18);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BlitzrSwapRouterRewardVault.Paid(address(token), alice, 100e18, swapper);
        vm.prank(router);
        vault.payout(address(token), alice, 100e18, swapper);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(address(vault)), 900e18);
    }

    function test_payout_revertsOnZeroToOrAmount() public {
        token.mint(address(vault), 1000e18);
        vm.startPrank(router);
        vm.expectRevert(BlitzrSwapRouterRewardVault.ZeroAddress.selector);
        vault.payout(address(token), address(0), 100e18, swapper);

        vm.expectRevert(BlitzrSwapRouterRewardVault.ZeroAmount.selector);
        vault.payout(address(token), alice, 0, swapper);
        vm.stopPrank();
    }

    function test_payout_revertsOnInsufficientBalance() public {
        token.mint(address(vault), 50e18);
        vm.prank(router);
        vm.expectRevert(BlitzrSwapRouterRewardVault.TransferFailed.selector);
        vault.payout(address(token), alice, 100e18, swapper);
    }

    function test_rescueERC20_onlyOwner() public {
        token.mint(address(vault), 1000e18);
        vm.expectRevert(BlitzrSwapRouterRewardVault.NotOwner.selector);
        vm.prank(alice);
        vault.rescueERC20(address(token), alice, 100e18);

        vm.prank(owner);
        vault.rescueERC20(address(token), alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_setRouter_afterUpgradeStyleRotation_oldRouterLosesAccess() public {
        token.mint(address(vault), 1000e18);
        vm.prank(router);
        vault.payout(address(token), alice, 10e18, swapper); // old router still works

        address newRouter = makeAddr("newRouter");
        vm.prank(owner);
        vault.setRouter(newRouter);

        vm.expectRevert(BlitzrSwapRouterRewardVault.NotOwner.selector);
        vm.prank(router); // old router address no longer authorized
        vault.payout(address(token), alice, 10e18, swapper);

        vm.prank(newRouter);
        vault.payout(address(token), alice, 10e18, swapper); // new router works
        assertEq(token.balanceOf(alice), 20e18);
    }
}
