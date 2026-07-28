// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Lightweight test double for a Uniswap V3 pool. Does not implement real AMM/tick math — the
// currentTick returned by slot0() is whatever the factory configured when creating this pool
// (see MockV3Factory.setNextTick), independent of the sqrtPriceX96 passed to initialize(). That's
// fine here: BlitzrLauncher/BlitzrLocker treat slot0()'s tick as ground truth and never re-derive
// it from price themselves, so exercising their orchestration logic doesn't require a mock that
// reproduces Uniswap's actual price<->tick relationship.
contract MockV3Pool {
    uint160 public sqrtPriceX96;
    int24   public tick;
    bool    public initialized;

    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    struct TickInfo {
        uint128 liquidityGross;
        int128  liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }
    mapping(int24 => TickInfo) public tickInfo;

    constructor(int24 tick_) {
        tick = tick_;
    }

    function initialize(uint160 sqrtPriceX96_) external {
        require(!initialized, "already initialized");
        initialized = true;
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function slot0() external view returns (
        uint160 sqrtPriceX96_, int24 tick_, uint16, uint16, uint16, uint32, bool unlocked
    ) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, initialized);
    }

    // --- test-only setup helpers ---

    function setFeeGrowthGlobal(uint256 fg0, uint256 fg1) external {
        feeGrowthGlobal0X128 = fg0;
        feeGrowthGlobal1X128 = fg1;
    }

    function setTickInfo(int24 t, uint256 fgOutside0, uint256 fgOutside1) external {
        tickInfo[t] = TickInfo({
            liquidityGross: 0,
            liquidityNet: 0,
            feeGrowthOutside0X128: fgOutside0,
            feeGrowthOutside1X128: fgOutside1
        });
    }

    // Test-only escape hatch standing in for the real pool's internal balance accounting —
    // lets MockPositionManager (mint's transferFrom target) pay back out on collect()/swap.
    function transferOut(address token, address to, uint256 amount) external {
        require(IERC20Like(token).transfer(to, amount), "transferOut failed");
    }

    function ticks(int24 t) external view returns (
        uint128 liquidityGross,
        int128  liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        int56   tickCumulativeOutside,
        uint160 secondsPerLiquidityOutsideX128,
        uint32  secondsOutside,
        bool    tickInitialized
    ) {
        TickInfo storage info = tickInfo[t];
        return (info.liquidityGross, info.liquidityNet, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128, 0, 0, 0, true);
    }
}

contract MockV3Factory {
    mapping(bytes32 => address) public pools;
    int24 public nextTick;

    event PoolCreated(address pool);

    function setNextTick(int24 tick_) external {
        nextTick = tick_;
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(a, b, fee));
    }

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        bytes32 key = _key(tokenA, tokenB, fee);
        require(pools[key] == address(0), "pool exists");
        pool = address(new MockV3Pool(nextTick));
        pools[key] = pool;
        emit PoolCreated(pool);
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    // Test helper to simulate a front-runner pre-creating an (uninitialized) pool shell before
    // BlitzrLauncher's own createPool() call — mirrors the "adopt an uninitialized shell" path
    // in BlitzrLauncher._setupAndRegister.
    function frontRunCreatePool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        bytes32 key = _key(tokenA, tokenB, fee);
        require(pools[key] == address(0), "pool exists");
        pool = address(new MockV3Pool(nextTick));
        pools[key] = pool;
    }
}

// Test double for NonfungiblePositionManager. Mint pulls the launched token's one-sided amount
// from the caller (BlitzrLauncher, which has approved this contract) and books a Position record
// the same shape BlitzrLocker reads via positions(tokenId). Also doubles as the token reservoir
// a MockSwapRouter draws from to simulate an instant-buy swap sourced from the just-seeded
// liquidity (see pullForSwap).
contract MockPositionManager {
    struct Position {
        address token0;
        address token1;
        int24   tickLower;
        int24   tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        address pool;
    }

    // Real Uniswap V3 deposits a minted position's underlying tokens into the pool contract
    // itself, not the position manager — BlitzrLauncher only exempts `pool` from the anti-bot
    // cap (never the position manager), so this mock must land funds there too, or a real
    // one-sided TOTAL_SUPPLY mint trips MaxWalletExceeded against a non-exempt holder.
    MockV3Factory public immutable factory;

    constructor(address factory_) {
        factory = MockV3Factory(factory_);
    }

    struct MintParams {
        address token0;
        address token1;
        uint24  fee;
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    uint256 public nextTokenId = 1;
    mapping(uint256 => Position) private _positions;
    mapping(uint256 => uint256) public collectable0;
    mapping(uint256 => uint256) public collectable1;
    // Set for both token0 and token1 of every minted position — resolves which pool holds a
    // given launched token's seeded liquidity, for MockSwapRouter's pullForSwap.
    mapping(address => address) public poolOfToken;

    event Minted(uint256 tokenId, address recipient);

    function mint(MintParams calldata params)
        external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address pool = factory.getPool(params.token0, params.token1, params.fee);
        require(pool != address(0), "pool not found");

        if (params.amount0Desired > 0) {
            require(IERC20Like(params.token0).transferFrom(msg.sender, pool, params.amount0Desired), "pull0 failed");
        }
        if (params.amount1Desired > 0) {
            require(IERC20Like(params.token1).transferFrom(msg.sender, pool, params.amount1Desired), "pull1 failed");
        }

        tokenId = nextTokenId++;
        liquidity = 1e18; // arbitrary nonzero placeholder — real magnitude is Uniswap's concern
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        _positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: 0,
            tokensOwed1: 0,
            pool: pool
        });
        poolOfToken[params.token0] = pool;
        poolOfToken[params.token1] = pool;
        emit Minted(tokenId, params.recipient);
    }

    function positions(uint256 tokenId) external view returns (
        uint96  nonce,
        address operator,
        address token0,
        address token1,
        uint24  fee,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) {
        Position storage p = _positions[tokenId];
        return (0, address(0), p.token0, p.token1, 0, p.tickLower, p.tickUpper, p.liquidity,
            p.feeGrowthInside0LastX128, p.feeGrowthInside1LastX128, p.tokensOwed0, p.tokensOwed1);
    }

    function poolOf(uint256 tokenId) external view returns (address) {
        return _positions[tokenId].pool;
    }

    // --- test-only setup helpers ---

    function setLiquidity(uint256 tokenId, uint128 liquidity_) external {
        _positions[tokenId].liquidity = liquidity_;
    }

    function setFeeGrowthInsideLast(uint256 tokenId, uint256 fg0, uint256 fg1) external {
        _positions[tokenId].feeGrowthInside0LastX128 = fg0;
        _positions[tokenId].feeGrowthInside1LastX128 = fg1;
    }

    function setTokensOwed(uint256 tokenId, uint128 owed0, uint128 owed1) external {
        _positions[tokenId].tokensOwed0 = owed0;
        _positions[tokenId].tokensOwed1 = owed1;
    }

    // Simulates fees accruing that collect() will pay out — funds must actually be sent to the
    // position's pool first (e.g. `token.mint(pool, amount)` in the test).
    function setCollectable(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        collectable0[tokenId] = amount0;
        collectable1[tokenId] = amount1;
    }

    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1) {
        amount0 = collectable0[params.tokenId];
        amount1 = collectable1[params.tokenId];
        if (amount0 > uint256(params.amount0Max)) amount0 = params.amount0Max;
        if (amount1 > uint256(params.amount1Max)) amount1 = params.amount1Max;
        collectable0[params.tokenId] -= amount0;
        collectable1[params.tokenId] -= amount1;
        Position storage p = _positions[params.tokenId];
        if (amount0 > 0) MockV3Pool(p.pool).transferOut(p.token0, params.recipient, amount0);
        if (amount1 > 0) MockV3Pool(p.pool).transferOut(p.token1, params.recipient, amount1);
    }

    // Lets a MockSwapRouter draw from the seeded pool's balance to simulate an instant-buy swap
    // sourced from the liquidity BlitzrLauncher just seeded one-sided into this position.
    function pullForSwap(address token, address to, uint256 amount) external {
        address pool = poolOfToken[token];
        require(pool != address(0), "no pool for token");
        MockV3Pool(pool).transferOut(token, to, amount);
    }
}

contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8  public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "WETH: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "WETH: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

// Test double for SwapRouter02. Doesn't run real AMM math — output amount is whatever the test
// configures via setNextAmountOut, drawn from MockPositionManager's stash (see pullForSwap) to
// model "the instant buy is sourced from the liquidity BlitzrLauncher just seeded".
contract MockSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    MockPositionManager public immutable positionManager;
    uint256 public nextAmountOut;

    constructor(address positionManager_) {
        positionManager = MockPositionManager(positionManager_);
    }

    function setNextAmountOut(uint256 amountOut) external {
        nextAmountOut = amountOut;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        require(IERC20Like(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "pull failed");
        amountOut = nextAmountOut;
        if (amountOut > 0) positionManager.pullForSwap(params.tokenOut, params.recipient, amountOut);
    }

    // path = abi.encodePacked(tokenIn, fee, mid, fee, tokenOut) — only tokenIn (first 20 bytes)
    // and tokenOut (last 20 bytes) are read here; the mock has no notion of an intermediate hop.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        address tokenIn = _firstAddress(params.path);
        address tokenOut = _lastAddress(params.path);
        require(IERC20Like(tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "pull failed");
        amountOut = nextAmountOut;
        if (amountOut > 0) positionManager.pullForSwap(tokenOut, params.recipient, amountOut);
    }

    function _firstAddress(bytes calldata path) private pure returns (address a) {
        assembly { a := shr(96, calldataload(path.offset)) }
    }

    function _lastAddress(bytes calldata path) private pure returns (address a) {
        assembly { a := shr(96, calldataload(add(path.offset, sub(path.length, 20)))) }
    }
}
