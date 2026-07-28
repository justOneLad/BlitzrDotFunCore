// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Blitzr — https://blitzr.fun

// Owner-controlled vault for platform revenue. Every outflow goes through queueWithdrawal → wait
// timelockDelay → executeWithdrawal, so a compromised owner key can't drain the balance in one
// transaction. timelockDelay is fixed at deploy time and never owner-adjustable: an adjustable
// delay would let that same compromised key set it to 0 and drain immediately.
contract BlitzrTreasury {

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroDelay();
    error TransferFailed();
    error AlreadyQueued();
    error NotQueued();
    error NotReady();

    address public owner;
    uint256 public immutable timelockDelay;

    // withdrawal id → timestamp at which it becomes executable (0 = not queued).
    // id = keccak256(token, to, amount) — token == address(0) means native value.
    mapping(bytes32 => uint256) public queuedAt;

    event Deposited(address indexed from, uint256 amount);
    event WithdrawalQueued(
        bytes32 indexed id, address indexed token, address indexed to, uint256 amount, uint256 executableAt
    );
    event WithdrawalCancelled(bytes32 indexed id);
    event WithdrawalExecuted(bytes32 indexed id, address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(address owner_, uint256 timelockDelay_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (timelockDelay_ == 0) revert ZeroDelay();
        owner = owner_;
        timelockDelay = timelockDelay_;
    }

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    function queueWithdrawal(address token, address to, uint256 amount) external onlyOwner returns (bytes32 id) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        id = keccak256(abi.encode(token, to, amount));
        if (queuedAt[id] != 0) revert AlreadyQueued();
        uint256 executableAt = block.timestamp + timelockDelay;
        queuedAt[id] = executableAt;
        emit WithdrawalQueued(id, token, to, amount, executableAt);
    }

    function cancelWithdrawal(address token, address to, uint256 amount) external onlyOwner {
        bytes32 id = keccak256(abi.encode(token, to, amount));
        if (queuedAt[id] == 0) revert NotQueued();
        delete queuedAt[id];
        emit WithdrawalCancelled(id);
    }

    function executeWithdrawal(address token, address to, uint256 amount) external onlyOwner {
        bytes32 id = keccak256(abi.encode(token, to, amount));
        uint256 executableAt = queuedAt[id];
        if (executableAt == 0) revert NotQueued();
        if (block.timestamp < executableAt) revert NotReady();
        delete queuedAt[id]; // effects before interactions

        emit WithdrawalExecuted(id, token, to, amount);
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            (bool ok, bytes memory data) = token.call(
                abi.encodeWithSelector(0xa9059cbb, to, amount) // transfer(address,uint256)
            );
            if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
