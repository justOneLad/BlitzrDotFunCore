// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Minimal ERC20 for tests — standard transfer/approve semantics, no fee-on-transfer or
// zero-amount-reverts quirks, so tests exercising those quirks use a dedicated mock instead.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8  public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "ERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

// Rejects plain-value transfers with calldata (no fallback) — used to test that Treasury's
// receive() only accepts calldata-less transfers, and that a token which returns false instead
// of reverting on failure is handled by the callers' return-data check.
contract MockERC20NoRevert is MockERC20 {
    constructor() MockERC20("NoRevert", "NR", 18) {}

    // Always "succeeds" per raw call semantics but returns false — exercises the
    // `!ok || (data.length > 0 && !abi.decode(data, (bool)))` branch in callers' safe-transfer helpers.
    function transfer(address, uint256) external pure override returns (bool) {
        return false;
    }
}
