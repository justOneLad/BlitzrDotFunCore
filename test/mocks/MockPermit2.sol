// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC20LikePermit2 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Minimal stand-in for Uniswap Permit2's ISignatureTransfer.permitTransferFrom — this repo's
// router only cares that the correct (owner, to, amount) transfer happens once the call is made
// and that nonce/deadline are respected. Real Permit2 additionally verifies an EIP-712 signature
// before doing so; that verification is Permit2's own already-audited/deployed logic, not this
// repo's, so it's deliberately not re-implemented here — `signature` is accepted but unchecked.
contract MockPermit2 {
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

    error Expired();
    error NonceUsed();
    error PullFailed();

    mapping(uint256 => bool) public nonceUsed;

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external {
        if (block.timestamp > permit.deadline) revert Expired();
        if (nonceUsed[permit.nonce]) revert NonceUsed();
        signature;
        nonceUsed[permit.nonce] = true;
        bool ok = IERC20LikePermit2(permit.permitted.token).transferFrom(
            owner, transferDetails.to, transferDetails.requestedAmount
        );
        if (!ok) revert PullFailed();
    }
}
