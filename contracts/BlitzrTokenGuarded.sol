// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Blitzr — https://blitzr.fun
//
// Guarded launch mode: same ERC20/permit/anti-bot core as BlitzrToken.sol, plus a decaying
// liquid/vested/burn split applied to every purchase from the pool during a protection window. A
// purchase at the very start of the window is hit hardest, decaying linearly to a plain 50/50
// liquid/vested split (no burn) by the end. A deliberate fork of BlitzrToken rather than an
// inherited variant — the base contract's internals are `private`. VEST_BPS/MAX_BURN_BPS are
// fixed, not owner-tunable (see BLITZR.md); windowBlocks/maxVestBlocks ARE, at the launcher level.
contract BlitzrTokenGuarded {

    error AlreadyInitialized();
    error GuardAlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error InsufficientBalance();
    error ExceedsAllowance();
    error PermitExpired();
    error InvalidSignature();
    error MaxWalletExceeded();

    bool    private _initialized;
    address private _owner;

    string  private _name;
    string  private _symbol;
    string  private _metaURI;
    uint256 private _totalSupply;

    uint256 public constant MAX_WALLET_BPS = 250; // 2.5 %
    uint256 private constant BPS = 10_000;
    uint256 public antiBotEndBlock;
    mapping(address => bool) public isExempt;

    // Not address(0): _transfer reverts on transfers to the zero address, so the conventional
    // dead address is used instead — matches BlitzrLocker.BURN_ADDRESS exactly.
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // --- guarded-launch state ---

    uint256 public constant VEST_BPS     = 5_000; // 50 %, fixed — every guarded-window purchase
    uint256 public constant MAX_BURN_BPS = 3_000; // 30 % at window start, decaying to 0

    address public pool;             // the address purchases are detected FROM; set once via initGuard
    uint256 public windowBlocks;     // protection window length
    uint256 public windowEndBlock;   // block.number (at initGuard) + windowBlocks
    uint256 public maxVestBlocks;    // vesting lock duration for a purchase at the very start of the window

    // One-shot exemption from the split for the creator's own launch-time instant buy — consumed
    // on the next transfer to this address. Separate from `isExempt`, which would also lift the
    // anti-bot wallet cap; the creator's instant buy stays subject to that cap.
    address public guardBypassOnce;

    struct VestEntry {
        uint256 amount;
        uint256 releaseBlock;
    }
    mapping(address => VestEntry[]) private _vestSchedules;
    mapping(address => uint256)     private _vestedTotal;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ExemptSet(address indexed account, bool exempt);
    event GuardInitialized(address indexed pool, uint256 windowEndBlock, uint256 maxVestBlocks);
    event VestScheduled(address indexed buyer, uint256 amount, uint256 releaseBlock);
    event VestClaimed(address indexed buyer, uint256 amount);
    event GuardBypassOnceSet(address indexed account);

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;
    bytes32 private _DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MetaURISet(string uri);

    constructor() { _initialized = true; } // blocks direct impl use

    function initBlitzr(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_,
        address         launcher_,
        uint256         antiBotBlocks_
    ) external {
        if (_initialized)            revert AlreadyInitialized();
        if (launcher_ == address(0)) revert ZeroAddress();
        _initialized = true;
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        _name    = name_;
        _symbol  = symbol_;
        _metaURI = metaURI_;
        emit MetaURISet(metaURI_);

        uint256 supply = 1_000_000_000e18;
        _totalSupply   = supply;
        _balances[launcher_] = supply;
        emit Transfer(address(0), launcher_, supply);

        antiBotEndBlock = block.number + antiBotBlocks_;

        _cachedChainId    = block.chainid;
        _DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    // One-time — `pool` is the address purchases are detected as coming FROM; windowBlocks_
    // starts counting from this call, not from initBlitzr.
    function initGuard(address pool_, uint256 windowBlocks_, uint256 maxVestBlocks_) external {
        if (msg.sender != _owner) revert NotOwner();
        if (pool != address(0)) revert GuardAlreadyInitialized();
        if (pool_ == address(0)) revert ZeroAddress();
        if (windowBlocks_ == 0) revert ZeroAmount();
        pool = pool_;
        windowBlocks = windowBlocks_;
        windowEndBlock = block.number + windowBlocks_;
        maxVestBlocks = maxVestBlocks_;
        emit GuardInitialized(pool_, windowEndBlock, maxVestBlocks_);
    }

    function setGuardBypassOnce(address account) external {
        if (msg.sender != _owner) revert NotOwner();
        guardBypassOnce = account;
        emit GuardBypassOnceSet(account);
    }

    // Owner-only — works during the init window before the launcher renounces.
    function setExempt(address account, bool exempt_) external {
        if (msg.sender != _owner) revert NotOwner();
        isExempt[account] = exempt_;
        emit ExemptSet(account, exempt_);
    }

    function name()        external view returns (string memory) { return _name;        }
    function symbol()      external view returns (string memory) { return _symbol;      }
    function decimals()    external pure returns (uint8)         { return 18;           }
    function totalSupply() external view returns (uint256)       { return _totalSupply; }
    function metaURI()     external view returns (string memory) { return _metaURI;     }
    function owner()       external view returns (address)       { return _owner;       }

    function setMetaURI(string calldata uri_) external {
        if (msg.sender != _owner) revert NotOwner();
        _metaURI = uri_;
        emit MetaURISet(uri_);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != _owner) revert NotOwner();
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() external {
        if (msg.sender != _owner) revert NotOwner();
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    // Still-locked portion of `account`'s guarded-window purchases — not included in
    // balanceOf/transferable until claimVested() releases it.
    function vestedBalanceOf(address account) external view returns (uint256) {
        return _vestedTotal[account];
    }

    function claimableVested(address account) external view returns (uint256 claimable) {
        VestEntry[] storage entries = _vestSchedules[account];
        uint256 len = entries.length;
        for (uint256 i; i < len; ++i) {
            if (block.number >= entries[i].releaseBlock) claimable += entries[i].amount;
        }
    }

    function vestScheduleLength(address account) external view returns (uint256) {
        return _vestSchedules[account].length;
    }

    function vestScheduleAt(address account, uint256 index) external view returns (uint256 amount, uint256 releaseBlock) {
        VestEntry storage e = _vestSchedules[account][index];
        return (e.amount, e.releaseBlock);
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert ExceedsAllowance();
            unchecked { _allowances[from][msg.sender] = allowed - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    // Releases whatever has matured in the caller's own vesting schedule.
    function claimVested() external returns (uint256 claimed) {
        claimed = _claimVestedFor(msg.sender);
    }

    // Permissionless claim-on-behalf — payout always lands with the rightful owner.
    function claimVestedFor(address account) external returns (uint256 claimed) {
        claimed = _claimVestedFor(account);
    }

    function _claimVestedFor(address account) private returns (uint256 claimed) {
        VestEntry[] storage entries = _vestSchedules[account];
        uint256 writeIndex;
        uint256 len = entries.length;
        for (uint256 i; i < len; ++i) {
            VestEntry memory e = entries[i];
            if (block.number >= e.releaseBlock) {
                claimed += e.amount;
            } else {
                if (writeIndex != i) entries[writeIndex] = e;
                ++writeIndex;
            }
        }
        while (entries.length > writeIndex) entries.pop();

        if (claimed > 0) {
            _vestedTotal[account] -= claimed;
            unchecked {
                _balances[address(this)] -= claimed;
                _balances[account] += claimed;
            }
            emit Transfer(address(this), account, claimed);
            emit VestClaimed(account, claimed);
        }
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();

        // Consumed here regardless of outcome — the ONLY place guardBypassOnce is read/cleared,
        // so it can never survive past the single transfer it was armed for.
        bool bypassOnce = to == guardBypassOnce && guardBypassOnce != address(0);
        if (bypassOnce) guardBypassOnce = address(0);

        // Only tokens leaving the pool are split — ordinary wallet-to-wallet transfers aren't.
        bool guardedBuy =
            pool != address(0) && from == pool && block.number < windowEndBlock && !isExempt[to] && !bypassOnce;

        uint256 liquidAmount = amount;
        uint256 vestedAmount;
        uint256 burnedAmount;
        uint256 releaseBlock;

        if (guardedBuy) {
            // progress: 1e18 at the first block of the window, decaying linearly toward 0.
            uint256 remaining = windowEndBlock - block.number;
            uint256 progress  = remaining * 1e18 / windowBlocks;

            uint256 burnBps = MAX_BURN_BPS * progress / 1e18;
            vestedAmount = amount * VEST_BPS / BPS;
            burnedAmount = amount * burnBps / BPS;
            liquidAmount = amount - vestedAmount - burnedAmount;
            releaseBlock = block.number + (maxVestBlocks * progress / 1e18);
        }

        uint256 newToBal;
        unchecked {
            _balances[from] = bal - amount;
            newToBal = _balances[to] + liquidAmount;
            _balances[to] = newToBal;
            if (vestedAmount > 0) _balances[address(this)] += vestedAmount;
            if (burnedAmount > 0) _balances[BURN_ADDRESS]  += burnedAmount;
        }

        if (block.number < antiBotEndBlock && !isExempt[to]) {
            // Includes still-vesting exposure — otherwise the split could be used to stash more
            // than MAX_WALLET_BPS by keeping half of it "invisible" in escrow.
            if (newToBal + _vestedTotal[to] + vestedAmount > _totalSupply * MAX_WALLET_BPS / BPS) {
                revert MaxWalletExceeded();
            }
        }

        if (vestedAmount > 0) {
            _vestSchedules[to].push(VestEntry({amount: vestedAmount, releaseBlock: releaseBlock}));
            _vestedTotal[to] += vestedAmount;
            emit Transfer(from, address(this), vestedAmount);
            emit VestScheduled(to, vestedAmount, releaseBlock);
        }
        if (burnedAmount > 0) {
            emit Transfer(from, BURN_ADDRESS, burnedAmount);
        }
        emit Transfer(from, to, liquidAmount);
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _cachedChainId ? _DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(_name)),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    function permit(
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH, owner_, spender, value, nonces[owner_]++, deadline
        ));
        address signer = ecrecover(
            keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash)),
            v, r, s
        );
        if (signer == address(0) || signer != owner_) revert InvalidSignature();
        _approve(owner_, spender, value);
    }
}
