// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrToken} from "../../contracts/BlitzrToken.sol";
import {BlitzrTokenHandler} from "./handlers/BlitzrTokenHandler.sol";

// Stateful fuzz: random transfer/approve/transferFrom sequences from a fixed set of actors.
// Regardless of how much anti-bot cap enforcement rejects along the way, token movement between
// a closed set of holders can never create or destroy supply.
contract BlitzrTokenInvariantsTest is Test {
    BlitzrToken tok;
    BlitzrTokenHandler handler;
    address[] actors;

    function setUp() public {
        BlitzrToken impl = new BlitzrToken();
        for (uint256 i; i < 6; i++) {
            actors.push(makeAddr(string.concat("invariantActor", vm.toString(i))));
        }

        tok = BlitzrToken(_clone(address(impl), keccak256("invariant-salt")));
        tok.initBlitzr("Invariant Token", "INV", "ipfs://inv", actors[0], 10);

        handler = new BlitzrTokenHandler(tok, actors);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_totalSupplyConservedAcrossActors() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; i++) {
            sum += tok.balanceOf(actors[i]);
        }
        assertEq(sum, tok.totalSupply());
    }

    function _clone(address impl_, bytes32 salt) private returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl_))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "clone failed");
    }
}
