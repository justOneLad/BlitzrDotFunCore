// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Minimal slice of Uniswap Permit2's ISignatureTransfer (https://github.com/Uniswap/permit2) —
// only the single-token, non-witness transfer path BlitzrSwapRouter uses.
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}
