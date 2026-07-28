// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrToken} from "../contracts/BlitzrToken.sol";

contract BlitzrTokenTest is Test {
    BlitzrToken impl;
    BlitzrToken tok;

    address launcher = makeAddr("launcher");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant SUPPLY = 1_000_000_000e18;

    function setUp() public {
        impl = new BlitzrToken();
        tok = BlitzrToken(_clone(address(impl), keccak256("salt")));
        vm.prank(launcher);
        tok.initBlitzr("Blitzr Test", "BTEST", "ipfs://meta", launcher, 10);
    }

    // EIP-1167 minimal proxy, identical to BlitzrLauncher._clone — a real `new BlitzrToken()`
    // can never be initialized (its constructor sets _initialized = true directly), only a
    // delegatecall clone whose own storage starts empty regardless of what the implementation's
    // constructor did.
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

    // --- init ---

    function test_implementation_blockedFromDirectInit() public {
        vm.expectRevert(BlitzrToken.AlreadyInitialized.selector);
        impl.initBlitzr("X", "X", "", launcher, 10);
    }

    function test_initBlitzr_revertsIfAlreadyInitialized() public {
        vm.expectRevert(BlitzrToken.AlreadyInitialized.selector);
        tok.initBlitzr("Y", "Y", "", launcher, 10);
    }

    function test_initBlitzr_revertsOnZeroLauncher() public {
        BlitzrToken fresh = BlitzrToken(_clone(address(impl), keccak256("salt2")));
        vm.expectRevert(BlitzrToken.ZeroAddress.selector);
        fresh.initBlitzr("Y", "Y", "", address(0), 10);
    }

    function test_initBlitzr_setsMetadataAndMintsSupplyToLauncher() public view {
        assertEq(tok.name(), "Blitzr Test");
        assertEq(tok.symbol(), "BTEST");
        assertEq(tok.metaURI(), "ipfs://meta");
        assertEq(tok.decimals(), 18);
        assertEq(tok.totalSupply(), SUPPLY);
        assertEq(tok.balanceOf(launcher), SUPPLY);
        assertEq(tok.owner(), launcher);
    }

    function test_initBlitzr_setsAntiBotEndBlock() public view {
        assertEq(tok.antiBotEndBlock(), block.number + 10);
    }

    // --- ownership / admin ---

    function test_setExempt_onlyOwner() public {
        vm.expectRevert(BlitzrToken.NotOwner.selector);
        vm.prank(alice);
        tok.setExempt(alice, true);
    }

    function test_setExempt_ownerCanSet() public {
        vm.prank(launcher);
        tok.setExempt(alice, true);
        assertTrue(tok.isExempt(alice));
    }

    function test_setMetaURI_onlyOwner() public {
        vm.expectRevert(BlitzrToken.NotOwner.selector);
        vm.prank(alice);
        tok.setMetaURI("ipfs://new");
    }

    function test_setMetaURI_updatesUri() public {
        vm.prank(launcher);
        tok.setMetaURI("ipfs://new");
        assertEq(tok.metaURI(), "ipfs://new");
    }

    function test_transferOwnership_onlyOwner() public {
        vm.expectRevert(BlitzrToken.NotOwner.selector);
        vm.prank(alice);
        tok.transferOwnership(alice);
    }

    function test_transferOwnership_updatesOwner() public {
        vm.prank(launcher);
        tok.transferOwnership(alice);
        assertEq(tok.owner(), alice);
    }

    function test_renounceOwnership_onlyOwner() public {
        vm.expectRevert(BlitzrToken.NotOwner.selector);
        vm.prank(alice);
        tok.renounceOwnership();
    }

    function test_renounceOwnership_zeroesOwnerAndBlocksFurtherAdmin() public {
        vm.startPrank(launcher);
        tok.renounceOwnership();
        assertEq(tok.owner(), address(0));

        vm.expectRevert(BlitzrToken.NotOwner.selector);
        tok.setExempt(alice, true);
        vm.stopPrank();
    }

    // --- ERC20 core ---

    function test_transfer_movesBalance() public {
        vm.prank(launcher);
        tok.transfer(alice, 100e18);
        assertEq(tok.balanceOf(alice), 100e18);
        assertEq(tok.balanceOf(launcher), SUPPLY - 100e18);
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.expectRevert(BlitzrToken.InsufficientBalance.selector);
        vm.prank(alice); // alice has 0
        tok.transfer(bob, 1);
    }

    function test_transfer_revertsToZeroAddress() public {
        vm.expectRevert(BlitzrToken.ZeroAddress.selector);
        vm.prank(launcher);
        tok.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(launcher);
        tok.approve(alice, 50e18);
        assertEq(tok.allowance(launcher, alice), 50e18);

        vm.prank(alice);
        tok.transferFrom(launcher, bob, 30e18);
        assertEq(tok.balanceOf(bob), 30e18);
        assertEq(tok.allowance(launcher, alice), 20e18);
    }

    function test_transferFrom_infiniteAllowanceNeverDecrements() public {
        vm.prank(launcher);
        tok.approve(alice, type(uint256).max);

        vm.prank(alice);
        tok.transferFrom(launcher, bob, 10e18);
        assertEq(tok.allowance(launcher, alice), type(uint256).max);
    }

    function test_transferFrom_revertsOnExceedsAllowance() public {
        vm.prank(launcher);
        tok.approve(alice, 5e18);

        vm.expectRevert(BlitzrToken.ExceedsAllowance.selector);
        vm.prank(alice);
        tok.transferFrom(launcher, bob, 6e18);
    }

    function test_approve_revertsToZeroAddress() public {
        vm.expectRevert(BlitzrToken.ZeroAddress.selector);
        vm.prank(launcher);
        tok.approve(address(0), 1);
    }

    // --- anti-bot cap ---

    function test_antiBot_blocksNonExemptOverCap() public {
        // launcher moves just over 2.5% of supply to alice — should revert while window is open.
        uint256 tooMuch = (SUPPLY * 250 / 10_000) + 1;
        vm.expectRevert(BlitzrToken.MaxWalletExceeded.selector);
        vm.prank(launcher);
        tok.transfer(alice, tooMuch);
    }

    function test_antiBot_allowsExactlyAtCap() public {
        uint256 atCap = SUPPLY * 250 / 10_000;
        vm.prank(launcher);
        tok.transfer(alice, atCap);
        assertEq(tok.balanceOf(alice), atCap);
    }

    function test_antiBot_exemptAddressBypassesCap() public {
        vm.startPrank(launcher);
        tok.setExempt(alice, true);
        uint256 tooMuch = (SUPPLY * 250 / 10_000) + 1;
        tok.transfer(alice, tooMuch);
        vm.stopPrank();
        assertEq(tok.balanceOf(alice), tooMuch);
    }

    function test_antiBot_capLiftsAfterEndBlock() public {
        vm.roll(block.number + 11); // antiBotBlocks_ was 10
        uint256 tooMuch = (SUPPLY * 250 / 10_000) + 1;
        vm.prank(launcher);
        tok.transfer(alice, tooMuch);
        assertEq(tok.balanceOf(alice), tooMuch);
    }

    function test_antiBot_cumulativeBalanceCountsTowardCap() public {
        // Two transfers that individually stay under cap but sum over it must still revert
        // on the second — the check is against the recipient's resulting balance, not the
        // transfer amount alone.
        uint256 half = SUPPLY * 250 / 10_000 / 2 + 1;
        vm.startPrank(launcher);
        tok.transfer(alice, half);
        vm.expectRevert(BlitzrToken.MaxWalletExceeded.selector);
        tok.transfer(alice, half + 10); // pushes cumulative just over the cap
        vm.stopPrank();
    }

    // --- permit (EIP-2612) ---

    function test_permit_setsAllowanceViaSignature() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        vm.prank(launcher);
        tok.transfer(signer, 1e18); // just so signer is a "real" holder, not required for permit itself

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            signer, alice, 100e18, tok.nonces(signer), deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tok.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        tok.permit(signer, alice, 100e18, deadline, v, r, s);
        assertEq(tok.allowance(signer, alice), 100e18);
        assertEq(tok.nonces(signer), 1);
    }

    function test_permit_revertsOnExpiredDeadline() public {
        // deadline is a literal, not derived from block.timestamp — this environment's via_ir
        // optimizer has been observed to re-materialize a block.timestamp-derived local as a
        // fresh TIMESTAMP() read when it's used again after an intervening vm.warp within the
        // same function, which would silently corrupt the value passed to permit() below.
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        uint256 deadline = 5;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            signer, alice, 100e18, tok.nonces(signer), deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tok.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.warp(10);
        vm.expectRevert(BlitzrToken.PermitExpired.selector);
        tok.permit(signer, alice, 100e18, deadline, v, r, s);
    }

    function test_permit_revertsOnWrongSigner() public {
        (address signer, ) = makeAddrAndKey("signer");
        (, uint256 wrongPk) = makeAddrAndKey("wrongSigner");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            signer, alice, 100e18, tok.nonces(signer), deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tok.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);

        vm.expectRevert(BlitzrToken.InvalidSignature.selector);
        tok.permit(signer, alice, 100e18, deadline, v, r, s);
    }

    function test_permit_revertsOnReplay() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            signer, alice, 100e18, tok.nonces(signer), deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tok.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        tok.permit(signer, alice, 100e18, deadline, v, r, s);
        vm.expectRevert(BlitzrToken.InvalidSignature.selector); // nonce already consumed → signer mismatch
        tok.permit(signer, alice, 100e18, deadline, v, r, s);
    }
}
