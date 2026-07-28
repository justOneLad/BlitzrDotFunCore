// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Blitzr — https://blitzr.fun
//
// Pre-funded token vault for BlitzrSwapRouter's referral/cashback payouts. Deliberately separate
// from BlitzrSwapRouter's own storage — a bug in the router's swap logic can only ever drain what
// sits here, nothing beyond it. `router` must be set to the router's PROXY address, not a
// particular implementation, so it stays valid across upgrades.
contract BlitzrSwapRouterRewardVault {

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();

    address public owner;
    address public router;

    event RouterSet(address indexed router);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Funded(address indexed from, address indexed token, uint256 amount);
    event Paid(address indexed token, address indexed to, uint256 amount, address indexed swapper);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner()  { if (msg.sender != owner)  revert NotOwner(); _; }
    modifier onlyRouter() { if (msg.sender != router) revert NotOwner(); _; }

    constructor(address owner_, address router_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        router = router_; // may be address(0) if the router proxy isn't deployed yet
        emit RouterSet(router_);
    }

    function setRouter(address router_) external onlyOwner {
        router = router_;
        emit RouterSet(router_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // Permissionless — anyone can top up rewards, not just the owner.
    function fund(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), amount) // transferFrom(address,address,uint256)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        emit Funded(msg.sender, token, amount);
    }

    // `swapper` is event metadata only, not an authorization input.
    function payout(address token, address to, uint256 amount, address swapper) external onlyRouter {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _safeTransfer(token, to, amount);
        emit Paid(token, to, amount, swapper);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _safeTransfer(token, to, amount);
        emit Rescued(token, to, amount);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount) // transfer(address,uint256)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
