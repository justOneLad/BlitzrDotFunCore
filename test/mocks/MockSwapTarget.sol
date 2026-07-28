// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC20Like3 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Generic STANDARD-hop target — stands in for "some DEX router the off-chain route builder
// already knows how to call." executeSwap's signature is what gets pre-encoded into a Hop's
// `data` field. Pulls tokenIn via transferFrom (the caller — BlitzrSwapRouter — must have
// approved this contract first, exactly like a real V2/V3 router expects) and pays out
// `amountOut` of tokenOut, which must be pre-funded to this mock. Reverts if not pre-funded
// (funds are being pushed, not fabricated).
contract MockSwapTarget {
    function executeSwap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address recipient)
        external
        payable
    {
        if (tokenIn != address(0)) {
            require(IERC20Like3(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        }
        if (tokenOut == address(0)) {
            (bool ok,) = recipient.call{value: amountOut}("");
            require(ok, "native send failed");
        } else {
            require(IERC20Like3(tokenOut).transfer(recipient, amountOut), "send failed");
        }
    }

    receive() external payable {}
}
