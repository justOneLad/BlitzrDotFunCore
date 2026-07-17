// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IBlitzrLaunchToken {
    function postMigrateSetup() external;
    function metaURI() external view returns (string memory);
    function setMetaURI(string calldata uri_) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Arc has no WETH, so unlike the BSC contract's IPancakeRouter02TT (which declares WETH() and
// the ETH-suffixed addLiquidityETH/swapExactTokensForETH...), this router interface is ERC20-only:
// addLiquidity pulls both legs via transferFrom, and reflection/marketing swaps always land as
// ARC_USDC ERC20 balance rather than native balance.
interface IPancakeRouter02TT {
    function factory() external pure returns (address);
    function addLiquidity(
        address tokenA, address tokenB,
        uint amountADesired, uint amountBDesired,
        uint amountAMin, uint amountBMin,
        address to, uint deadline
    ) external returns (uint, uint, uint);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path,
        address to, uint deadline
    ) external;
}

interface IPancakeFactoryTT {
    function createPair(address tokenA, address tokenB) external returns (address);
    function getPair(address tokenA, address tokenB)   external view returns (address);
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// Queried back against launchManager (the BlitzrBondingCurveArc factory) so this contract enforces
// its own reflection-token invariant regardless of which launchManager deployed it.
interface IBlitzrBondingCurveWhitelist {
    function reflectionTokenAllowed(address token) external view returns (bool);
}
// Blitzr — https://blitzr.fun
//
// Arc-network variant of BlitzrTaxToken. Arc's native gas token IS USDC (6 decimals), mirrored
// 1:1 as an ERC20 at the fixed address ARC_USDC below — there is no WETH on Arc. The DEX pair is
// created directly against ARC_USDC, and every tax-proceeds swap (marketing/liquidity/reflection)
// runs through the plain ERC20 Tokens-for-Tokens router function rather than the ETH-suffixed
// sugar methods, since Arc's router isn't assumed to implement those; swap proceeds are measured
// and moved as ARC_USDC ERC20 balance rather than native balance.
//
// Buy/sell tax across exactly three categories — liquidity, reflection, marketing — each capped
// so the two directions never exceed MAX_TOTAL_TAX combined. The reflection portion is swapped
// into 1-4 creator-chosen tokens (drawn from BlitzrBondingCurveArc's owner-managed whitelist);
// swapping and distributing are separate steps — swaps happen automatically once accumulated
// tax crosses swapThreshold, but the swapped-out reflection tokens simply sit in this contract's
// own balance until anyone calls the permissionless distributeReflection(), which pushes them
// out proportionally to qualifying holders. There is no native-supply-rebasing reflection mode.
// All tax/wallet/reflection-token configuration is fixed at launch — there is no owner and no
// post-launch setter, so nothing here can be changed after the fact.
contract BlitzrTaxTokenArc is IBlitzrLaunchToken {

    error NotLaunchManager();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error TaxExceedsMax();
    error DexAlreadyConfigured();
    error ExceedsAllowance();
    error InsufficientBalance();
    error NothingToSwap();
    error USDCTransferFailed();
    error PermitExpired();
    error InvalidSignature();
    error LaunchPhaseTransferRestricted();
    error ReflectionTokenRequired();
    error TooManyReflectionTokens();
    error DuplicateReflectionToken();
    error ReflectionTokenNotAllowed();
    error MetaURIImmutable();
    error NothingToDistribute();

    // Arc's native gas token IS USDC (6 decimals), mirrored as an ERC20 at this fixed,
    // network-wide address — balances are always in sync with native value, so no wrap/unwrap
    // step is ever needed before using it in DEX calls.
    address private constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    address public launchManager;
    bool    private _initialized;
    bool    private _inLaunchPhase;

    string  private _name;
    string  private _symbol;
    string  private _metaURI;
    uint8   private constant DECIMALS = 18;
    uint256 private _totalSupply;

    uint256 public buyLiquidityTax;
    uint256 public buyReflectionTax;
    uint256 public buyMarketingTax;

    uint256 public sellLiquidityTax;
    uint256 public sellReflectionTax;
    uint256 public sellMarketingTax;

    uint256 public constant MAX_TOTAL_TAX = 300; // 3 %, per direction
    uint256 public constant MAX_REFLECTION_TOKENS = 4;
    uint256 private constant MIN_REFLECTION_BPS = 2; // 0.02 % — floor for reflectionMinBalance
    uint256 private constant BPS_DENOM          = 10000;

    // Bounds the holder list a distributeReflection() call iterates over. Swapping and
    // distributing are separate steps (see below), so this cost is never forced onto an
    // ordinary buy/sell — only onto whoever chooses to call distributeReflection() directly.
    uint256 public constant MAX_REFLECTION_HOLDERS = 500;

    uint256 public swapThreshold;
    uint256 public reflectionMinBalance;

    address public marketingWallet;
    address[] public reflectionTokens; // 1-4 entries if reflection tax > 0, fixed at launch

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool)                        private _isExcludedFromFee;
    mapping(address => bool)                        private _isExcludedFromReflection;

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;
    bytes32 private _DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;

    IPancakeRouter02TT public pancakeRouter;
    address            public pancakePair;

    bool private inSwap;
    bool public  swapEnabled;

    address[] private _holders;
    mapping(address => uint256) private _holderIndex; // 1-based index; 0 = not in list

    uint256 private _toSwapForReflection;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 usdc);
    event DexConfigured(address pair, address router);
    event ReflectionSwapped(address indexed token, uint256 tokensSpent, uint256 received);
    event ReflectionDistributed(address indexed token, uint256 amount, uint256 recipients);

    modifier lockSwap() { inSwap = true; _; inSwap = false; }
    modifier onlyLaunchManager() { if (msg.sender != launchManager) revert NotLaunchManager(); _; }

    constructor() { _initialized = true; }

    struct TaxConfig {
        uint256 buyLiquidityTax;
        uint256 buyReflectionTax;
        uint256 buyMarketingTax;
        uint256 sellLiquidityTax;
        uint256 sellReflectionTax;
        uint256 sellMarketingTax;
        address marketingWallet;
        address[] reflectionTokens;
    }

    function initForBlitzr(
        string    calldata name_,
        string    calldata symbol_,
        uint256            totalSupply_,
        address            launchManager_,
        address            creator_,
        string    calldata metaURI_,
        address            router_,
        TaxConfig calldata cfg
    ) external {
        if (_initialized)                  revert AlreadyInitialized();
        if (launchManager_ == address(0))  revert ZeroAddress();
        if (creator_        == address(0)) revert ZeroAddress();
        if (router_         == address(0)) revert ZeroAddress();

        if (cfg.buyLiquidityTax + cfg.buyReflectionTax + cfg.buyMarketingTax > MAX_TOTAL_TAX)
            revert TaxExceedsMax();
        if (cfg.sellLiquidityTax + cfg.sellReflectionTax + cfg.sellMarketingTax > MAX_TOTAL_TAX)
            revert TaxExceedsMax();

        uint256 rlen = cfg.reflectionTokens.length;
        if (rlen > MAX_REFLECTION_TOKENS) revert TooManyReflectionTokens();
        if ((cfg.buyReflectionTax > 0 || cfg.sellReflectionTax > 0) && rlen == 0)
            revert ReflectionTokenRequired();
        for (uint256 i; i < rlen; ++i) {
            address rt = cfg.reflectionTokens[i];
            if (rt == address(0)) revert ZeroAddress();
            if (!IBlitzrBondingCurveWhitelist(launchManager_).reflectionTokenAllowed(rt))
                revert ReflectionTokenNotAllowed();
            for (uint256 j; j < i; ++j) {
                if (cfg.reflectionTokens[j] == rt) revert DuplicateReflectionToken();
            }
            reflectionTokens.push(rt);
        }

        _initialized    = true;
        _inLaunchPhase  = true;
        launchManager   = launchManager_;

        _name        = name_;
        _symbol      = symbol_;
        _totalSupply = totalSupply_;

        buyLiquidityTax   = cfg.buyLiquidityTax;
        buyReflectionTax  = cfg.buyReflectionTax;
        buyMarketingTax   = cfg.buyMarketingTax;
        sellLiquidityTax  = cfg.sellLiquidityTax;
        sellReflectionTax = cfg.sellReflectionTax;
        sellMarketingTax  = cfg.sellMarketingTax;

        marketingWallet = cfg.marketingWallet == address(0) ? creator_ : cfg.marketingWallet;

        swapThreshold        = totalSupply_ / 1000;
        reflectionMinBalance = (totalSupply_ * MIN_REFLECTION_BPS) / BPS_DENOM;
        swapEnabled          = false;

        _isExcludedFromFee[launchManager_] = true;
        _isExcludedFromFee[creator_]       = true;
        _isExcludedFromFee[address(this)]  = true;

        _isExcludedFromReflection[launchManager_] = true;
        _isExcludedFromReflection[address(this)]  = true;

        _metaURI = metaURI_;

        // Pair is created now; liquidity is added only at migration.
        pancakeRouter = IPancakeRouter02TT(router_);
        pancakePair   = IPancakeFactoryTT(pancakeRouter.factory()).createPair(address(this), ARC_USDC);
        _isExcludedFromReflection[pancakePair] = true;

        _balances[launchManager_] = totalSupply_;
        emit Transfer(address(0), launchManager_, totalSupply_);

        _cachedChainId    = block.chainid;
        _DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    function metaURI() external view override returns (string memory) { return _metaURI; }

    // No owner exists post-launch — metadata is fixed at initForBlitzr and can never change.
    function setMetaURI(string calldata) external pure override {
        revert MetaURIImmutable();
    }

    function postMigrateSetup() external onlyLaunchManager {
        if (!_inLaunchPhase) revert DexAlreadyConfigured();
        _inLaunchPhase = false;
        swapEnabled     = true;
        emit DexConfigured(pancakePair, address(pancakeRouter));
    }

    function name()        public view returns (string memory) { return _name;   }
    function symbol()      public view returns (string memory) { return _symbol; }
    function decimals()    public pure returns (uint8)         { return DECIMALS;}
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address a) public view override returns (uint256) { return _balances[a]; }

    function allowance(address owner_, address spender) public view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed < amount) revert ExceedsAllowance();
        unchecked { _allowances[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0)                            revert ZeroAmount();
        if (_inLaunchPhase) {
            if (from != launchManager && to != launchManager) revert LaunchPhaseTransferRestricted();
        }
        if (_balances[from] < amount)               revert InsufficientBalance();

        bool takeFee = !(_isExcludedFromFee[from] || _isExcludedFromFee[to]);

        if (!_inLaunchPhase && swapEnabled && takeFee && !inSwap && from != pancakePair) {
            uint256 taxBalance = _balances[address(this)];
            if (taxBalance >= swapThreshold) _autoSwap(taxBalance);
        }

        _executeTransfer(from, to, amount, takeFee);
        _updateHolderList(from);
        _updateHolderList(to);
    }

    function _executeTransfer(address sender, address recipient, uint256 amount, bool takeFee) private {
        if (!takeFee) {
            _balances[sender]    -= amount;
            _balances[recipient] += amount;
            emit Transfer(sender, recipient, amount);
            return;
        }

        bool isBuy  = (sender    == pancakePair);
        bool isSell = (recipient == pancakePair);

        uint256 reflectionAmt;
        uint256 contractAmt; // liquidity + marketing, swapped to USDC
        if (isBuy) {
            reflectionAmt = (amount * buyReflectionTax) / BPS_DENOM;
            contractAmt   = (amount * (buyLiquidityTax + buyMarketingTax)) / BPS_DENOM;
        } else if (isSell) {
            reflectionAmt = (amount * sellReflectionTax) / BPS_DENOM;
            contractAmt   = (amount * (sellLiquidityTax + sellMarketingTax)) / BPS_DENOM;
        }

        uint256 totalTax     = reflectionAmt + contractAmt;
        uint256 transferAmt  = amount - totalTax;

        _balances[sender]    -= amount;
        _balances[recipient] += transferAmt;
        emit Transfer(sender, recipient, transferAmt);

        if (totalTax > 0) {
            _balances[address(this)] += totalTax;
            emit Transfer(sender, address(this), totalTax);
            if (reflectionAmt > 0) _toSwapForReflection += reflectionAmt;
        }
    }

    // Swaps only — does not push anything to holders. The reflection-tax share is converted
    // into the configured reflection tokens and simply accumulates in this contract's own
    // balance of each; a holder only ever receives reflection via a separate, explicit
    // distributeReflection() call (see below), never as a side effect of someone else's
    // buy/sell triggering this swap.
    function _autoSwap(uint256 tokenAmount) private lockSwap {
        uint256 reflAmount = _toSwapForReflection;
        if (reflAmount > 0) {
            _toSwapForReflection = 0;
            _swapReflection(reflAmount);
            tokenAmount -= reflAmount;
        }

        uint256 lpBPS    = buyLiquidityTax + sellLiquidityTax;
        uint256 totalTax = lpBPS + buyMarketingTax + sellMarketingTax;
        if (tokenAmount == 0 || totalTax == 0) return;

        uint256 halfLP  = (tokenAmount * lpBPS / totalTax) / 2;
        uint256 gotUSDC = _swapTokensForUSDC(tokenAmount - halfLP);

        uint256 denom = totalTax - lpBPS / 2;
        if (denom == 0) return;

        uint256 usdcLP = (gotUSDC * (lpBPS / 2)) / denom;

        if (halfLP > 0 && usdcLP > 0) {
            _addLiquidity(halfLP, usdcLP);
            emit SwapAndLiquify(halfLP, usdcLP);
        }
        _safeTransferUSDC(marketingWallet, gotUSDC - usdcLP);
    }

    // Splits reflAmount evenly across the configured reflection tokens (remainder folded into
    // the last one) and swaps each share independently. Received amounts are left sitting in
    // this contract's own balance — distributeReflection() is what pushes them to holders.
    function _swapReflection(uint256 reflAmount) private {
        uint256 n = reflectionTokens.length;
        if (n == 0) return; // no reflection tax configured without reflection tokens (enforced at init)

        uint256 share = reflAmount / n;
        uint256 dust  = reflAmount - share * n;
        for (uint256 i; i < n; ) {
            uint256 amt = share + (i == n - 1 ? dust : 0);
            if (amt > 0) {
                address rt     = reflectionTokens[i];
                uint256 preBal = IERC20Minimal(rt).balanceOf(address(this));
                _swapForReflectionToken(rt, amt);
                uint256 received = IERC20Minimal(rt).balanceOf(address(this)) - preBal;
                if (received > 0) emit ReflectionSwapped(rt, amt, received);
            }
            unchecked { ++i; }
        }
    }

    // Permissionless — pushes whatever balance of each configured reflection token this
    // contract currently holds out to every holder at or above reflectionMinBalance,
    // proportionally by their BlitzrTaxTokenArc balance. Funds always land with the token's
    // actual current holders, so calling this early, often, or by anyone can't misdirect
    // anything, only affects *when* accumulated reflection actually reaches holders.
    // Eligibility is computed once and reused across every reflection token, since nothing in
    // this loop changes this token's own holder balances.
    function distributeReflection() external {
        uint256 n = reflectionTokens.length;
        if (n == 0) revert NothingToDistribute();

        uint256 minBal         = reflectionMinBalance;
        uint256 eligibleSupply = _eligibleReflectionSupply(minBal);
        if (eligibleSupply == 0) revert NothingToDistribute();

        bool distributedAny;
        for (uint256 i; i < n; ) {
            address rt  = reflectionTokens[i];
            uint256 bal = IERC20Minimal(rt).balanceOf(address(this));
            if (bal > 0) {
                distributedAny = true;
                uint256 recipients = _distributeReflection(rt, bal, minBal, eligibleSupply);
                emit ReflectionDistributed(rt, bal, recipients);
            }
            unchecked { ++i; }
        }
        if (!distributedAny) revert NothingToDistribute();
    }

    // Swaps this token for ARC_USDC — proceeds land as ERC20 balance (not native balance), since
    // this always goes through the plain Tokens-for-Tokens router function.
    function _swapTokensForUSDC(uint256 tokenAmount) private returns (uint256 received) {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = ARC_USDC;
        _approve(address(this), address(pancakeRouter), tokenAmount);
        uint256 preBal = IERC20Minimal(ARC_USDC).balanceOf(address(this));
        // amountOutMin = 0: no on-chain oracle available; manualSwap() can be retried later if
        // conditions were briefly bad, since accumulated tax simply keeps growing until then.
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
        received = IERC20Minimal(ARC_USDC).balanceOf(address(this)) - preBal;
    }

    // Single-hop if the reflection token is ARC_USDC, otherwise this-token → ARC_USDC → token.
    function _swapForReflectionToken(address token, uint256 tokenAmount) private {
        address[] memory path;
        if (token == ARC_USDC) {
            path = new address[](2);
            path[0] = address(this);
            path[1] = ARC_USDC;
        } else {
            path = new address[](3);
            path[0] = address(this);
            path[1] = ARC_USDC;
            path[2] = token;
        }
        _approve(address(this), address(pancakeRouter), tokenAmount);
        // amountOutMin = 0: same rationale as _swapTokensForUSDC.
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
    }

    function _updateHolderList(address addr) private {
        if (addr == address(0) || _isExcludedFromReflection[addr]) return;
        uint256 bal = _balances[addr];
        if (bal > 0) {
            if (_holderIndex[addr] == 0 && _holders.length < MAX_REFLECTION_HOLDERS) {
                _holders.push(addr);
                _holderIndex[addr] = _holders.length; // 1-based index
            }
        } else {
            uint256 idx = _holderIndex[addr];
            if (idx != 0) {
                uint256 last = _holders.length - 1;
                address lastHolder = _holders[last];
                _holders[idx - 1] = lastHolder;
                _holderIndex[lastHolder] = idx;
                _holders.pop();
                _holderIndex[addr] = 0;
            }
        }
    }

    function _eligibleReflectionSupply(uint256 minBal) private view returns (uint256 eligibleSupply) {
        uint256 len = _holders.length;
        for (uint256 i; i < len; ) {
            uint256 bal = _balances[_holders[i]];
            if (bal >= minBal) eligibleSupply += bal;
            unchecked { ++i; }
        }
    }

    function _distributeReflection(
        address token, uint256 amount, uint256 minBal, uint256 eligibleSupply
    ) private returns (uint256 recipients) {
        uint256 len = _holders.length;
        for (uint256 i; i < len; ) {
            address holder = _holders[i];
            uint256 bal = _balances[holder];
            if (bal >= minBal) {
                uint256 share = amount * bal / eligibleSupply;
                if (share > 0) {
                    try IERC20Minimal(token).transfer(holder, share) returns (bool ok) {
                        if (ok) { unchecked { ++recipients; } }
                    } catch {}
                }
            }
            unchecked { ++i; }
        }
    }

    // Approves both legs (this token via the internal _approve, ARC_USDC via a raw-call
    // external approve) and adds liquidity through the plain ERC20 addLiquidity — both legs are
    // pulled via transferFrom. LP goes to the burn address, so any under-valuation is
    // irreversible and does not benefit an attacker; minimums = 0 accordingly.
    function _addLiquidity(uint256 tokenAmount, uint256 usdcAmount) private {
        _approve(address(this), address(pancakeRouter), tokenAmount);
        _safeApproveExternal(ARC_USDC, address(pancakeRouter), usdcAmount);
        pancakeRouter.addLiquidity(
            address(this), ARC_USDC, tokenAmount, usdcAmount, 0, 0,
            0x000000000000000000000000000000000000dEaD, block.timestamp
        );
    }

    function _safeTransferUSDC(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory data) = ARC_USDC.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount) // transfer(address,uint256)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert USDCTransferFailed();
    }

    // Reset allowance to 0 before setting — handles USDT-style non-zero→non-zero restrictions.
    function _safeApproveExternal(address token_, address spender, uint256 amount) private {
        (bool reset,) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, 0));
        reset;
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert USDCTransferFailed();
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        if (owner_ == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    // Recomputed on chain forks.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _cachedChainId) return _DOMAIN_SEPARATOR;
        return _buildDomainSeparator();
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
        uint8   v,
        bytes32 r,
        bytes32 s
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

    // Permissionless — funds always land at the fixed destinations (marketingWallet, the LP
    // pair, or this contract's own reflection-token balances awaiting distributeReflection())
    // regardless of who triggers it, so calling this early or often can't misdirect anything,
    // only affects *when* it happens.
    function manualSwap() external {
        uint256 taxBalance = _balances[address(this)];
        if (taxBalance == 0) revert NothingToSwap();
        _autoSwap(taxBalance);
    }

    // ── Views: tax config ─────────────────────────────────────────────────────────

    function getTotalBuyTax()  public view returns (uint256) {
        return buyLiquidityTax + buyReflectionTax + buyMarketingTax;
    }
    function getTotalSellTax() public view returns (uint256) {
        return sellLiquidityTax + sellReflectionTax + sellMarketingTax;
    }

    // All six tax bps plus marketingWallet in one call — everything here is fixed at launch.
    function getTaxConfig() external view returns (
        uint256 buyLiquidityTax_,
        uint256 buyReflectionTax_,
        uint256 buyMarketingTax_,
        uint256 sellLiquidityTax_,
        uint256 sellReflectionTax_,
        uint256 sellMarketingTax_,
        address marketingWallet_
    ) {
        return (
            buyLiquidityTax, buyReflectionTax, buyMarketingTax,
            sellLiquidityTax, sellReflectionTax, sellMarketingTax,
            marketingWallet
        );
    }

    function isExcludedFromFee(address a) public view returns (bool) { return _isExcludedFromFee[a]; }
    function inLaunchPhase()              public view returns (bool) { return _inLaunchPhase; }

    // ── Views: reflection tokens ──────────────────────────────────────────────────

    function reflectionTokenCount() external view returns (uint256) { return reflectionTokens.length; }

    function getReflectionTokens() external view returns (address[] memory) { return reflectionTokens; }

    function isReflectionToken(address token) public view returns (bool) {
        uint256 n = reflectionTokens.length;
        for (uint256 i; i < n; ) {
            if (reflectionTokens[i] == token) return true;
            unchecked { ++i; }
        }
        return false;
    }

    // Current balance of `token` sitting in this contract, awaiting distributeReflection().
    // Works for any address, not just configured reflection tokens (e.g. to preview a
    // rescue-worthy stray balance) — it never implies the balance will actually be distributed.
    function pendingReflectionBalance(address token) public view returns (uint256) {
        return IERC20Minimal(token).balanceOf(address(this));
    }

    // pendingReflectionBalance() for every configured reflection token, in one call.
    function pendingReflectionBalances() external view returns (address[] memory tokensOut, uint256[] memory balances) {
        uint256 n = reflectionTokens.length;
        tokensOut = new address[](n);
        balances  = new uint256[](n);
        for (uint256 i; i < n; ) {
            tokensOut[i] = reflectionTokens[i];
            balances[i]  = pendingReflectionBalance(reflectionTokens[i]);
            unchecked { ++i; }
        }
    }

    // Total holder balance currently eligible for reflection (>= reflectionMinBalance, not
    // excluded) — exactly what distributeReflection() would use as its denominator right now.
    function eligibleReflectionSupply() public view returns (uint256) {
        return _eligibleReflectionSupply(reflectionMinBalance);
    }

    // Preview of what `holder` would receive from each configured reflection token if
    // distributeReflection() were called right now — mirrors _distributeReflection's math
    // exactly, but is a plain view with no side effects. All zero if the holder is excluded
    // from reflection or below reflectionMinBalance.
    function pendingReflectionFor(address holder)
        external view
        returns (address[] memory tokensOut, uint256[] memory amounts)
    {
        uint256 n = reflectionTokens.length;
        tokensOut = new address[](n);
        amounts   = new uint256[](n);
        for (uint256 i; i < n; ) { tokensOut[i] = reflectionTokens[i]; unchecked { ++i; } }

        uint256 minBal    = reflectionMinBalance;
        uint256 holderBal = _balances[holder];
        if (_isExcludedFromReflection[holder] || holderBal < minBal) return (tokensOut, amounts);

        uint256 eligibleSupply = eligibleReflectionSupply();
        if (eligibleSupply == 0) return (tokensOut, amounts);

        for (uint256 i; i < n; ) {
            amounts[i] = pendingReflectionBalance(tokensOut[i]) * holderBal / eligibleSupply;
            unchecked { ++i; }
        }
    }

    // ── Views: holders ────────────────────────────────────────────────────────────

    function isExcludedFromReflection(address a) public view returns (bool) { return _isExcludedFromReflection[a]; }
    function holderCount() external view returns (uint256) { return _holders.length; }
    function isHolder(address a) external view returns (bool) { return _holderIndex[a] != 0; }

    // Full current holder list — bounded by MAX_REFLECTION_HOLDERS (500) by construction.
    function getHolders() external view returns (address[] memory) { return _holders; }

    // Stray native sends are automatically mirrored as ARC_USDC ERC20 balance on Arc (balances
    // are in sync); nothing here depends on native balance directly, this is just a no-op safety
    // net so an accidental send doesn't revert.
    receive() external payable {}
}
