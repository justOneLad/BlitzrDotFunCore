// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Blitzr — https://blitzr.fun

interface IPositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);
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
    );
}

interface IUniswapV3PoolFees {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16  observationCardinality, uint16 observationCardinalityNext,
        uint32  feeProtocol, bool unlocked // PancakeSwap V3 packs this wider than uint8
    );
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick) external view returns (
        uint128 liquidityGross,
        int128  liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        int56   tickCumulativeOutside,
        uint160 secondsPerLiquidityOutsideX128,
        uint32  secondsOutside,
        bool    initialized
    );
}

contract BlitzrLocker {

    error NotOwner();
    error NotLauncher();
    error NotAuthorized();
    error ZeroAddress();
    error AlreadyRegistered();
    error UnknownToken();
    error TransferFailed();
    error InvalidBps();
    error WrongFee();

    uint256 public creatorBps  = 7_000; // 70 %
    uint256 public platformBps = 3_000; // 30 %
    uint256 private constant BPS = 10_000;

    uint256 public ctoFee = 0.05 ether; // anti-spam charge for applyForCTO, owner-adjustable

    // Not address(0): BlitzrToken._transfer reverts on transfers to the zero address, so the
    // conventional dead address is used instead — a normal, code-less address nobody holds the
    // key to, which BlitzrToken has no special-case rejection for.
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Inverted so the zero value (every mapping's default) means "burn enabled" — burn is on by
    // default for every token without needing an explicit write at registration time.
    mapping(address => bool) private _burnDisabled;

    struct Position {
        uint256 tokenId;
        address feeWallet;
        address token0;
        address token1;
        address pool;            // needed for fee-growth queries in pendingCreatorFees
        address positionManager; // NFT manager for this position's DEX
    }

    struct CTOApplication {
        address applicant;
        address proposedFeeWallet;
        uint256 feePaid;
    }

    address public owner;
    address public launcher;
    address public platformWallet;

    mapping(address => Position) public positions; // launched token → locked position
    mapping(address => CTOApplication) public ctoApplications; // launched token → pending CTO application
    address[] public allTokens;

    event PositionRegistered(
        address indexed token,
        uint256 indexed tokenId,
        address         feeWallet,
        address         pool,
        address         positionManager
    );
    event FeesClaimed(
        address indexed token,
        address indexed feeWallet,
        uint256 creator0,
        uint256 creator1,
        uint256 platform0,
        uint256 platform1
    );
    event FeesBurned(address indexed token, uint256 amount0, uint256 amount1);
    event BurnToggled(address indexed token, bool enabled);
    event LauncherSet(address indexed launcher);
    event PlatformWalletSet(address indexed wallet);
    event FeeBpsUpdated(uint256 creatorBps, uint256 platformBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenCTO(address indexed token, address indexed oldFeeWallet, address indexed newFeeWallet);
    event CTOApplied(address indexed token, address indexed applicant, address proposedFeeWallet, uint256 feePaid);
    event CTOFeeSet(uint256 fee);

    modifier onlyOwner()    { if (msg.sender != owner)    revert NotOwner();    _; }
    modifier onlyLauncher() { if (msg.sender != launcher) revert NotLauncher(); _; }

    constructor(address platformWallet_) {
        if (platformWallet_ == address(0)) revert ZeroAddress();
        owner          = msg.sender;
        platformWallet = platformWallet_;
    }

    function setLauncher(address launcher_) external onlyOwner {
        if (launcher_ == address(0)) revert ZeroAddress();
        launcher = launcher_;
        emit LauncherSet(launcher_);
    }

    function setPlatformWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        platformWallet = wallet;
        emit PlatformWalletSet(wallet);
    }

    function setFeeBps(uint256 creator_, uint256 platform_) external onlyOwner {
        if (creator_ + platform_ != BPS) revert InvalidBps();
        creatorBps  = creator_;
        platformBps = platform_;
        emit FeeBpsUpdated(creator_, platform_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // Reassigns a token's creator fee wallet — a community takeover (CTO) lever for when the
    // original creator is unreachable or has abandoned the project.
    function ctoFeeWallet(address token, address newFeeWallet) external onlyOwner {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();
        if (newFeeWallet == address(0)) revert ZeroAddress();
        emit TokenCTO(token, pos.feeWallet, newFeeWallet);
        pos.feeWallet = newFeeWallet;
        delete ctoApplications[token];
    }

    function setCTOFee(uint256 fee_) external onlyOwner {
        ctoFee = fee_;
        emit CTOFeeSet(fee_);
    }

    // Public entry point for proposing a community takeover of an abandoned token's fee wallet.
    // Gated by ctoFee (paid to platformWallet) so bots can't spam applications for free; the
    // owner still reviews and executes via ctoFeeWallet — this only records the proposal.
    // The fee is non-refundable: it's forwarded immediately and unconditionally, whether or
    // not the owner ends up approving the application.
    function applyForCTO(address token, address proposedFeeWallet) external payable {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();
        if (proposedFeeWallet == address(0)) revert ZeroAddress();
        if (msg.value < ctoFee) revert WrongFee();

        ctoApplications[token] = CTOApplication({
            applicant:          msg.sender,
            proposedFeeWallet:  proposedFeeWallet,
            feePaid:            msg.value
        });

        if (msg.value > 0) {
            (bool ok,) = platformWallet.call{value: msg.value}("");
            if (!ok) revert TransferFailed();
        }

        emit CTOApplied(token, msg.sender, proposedFeeWallet, msg.value);
    }

    function registerPosition(
        address token,
        uint256 tokenId,
        address feeWallet,
        address token0,
        address token1,
        address pool,
        address positionManager
    ) external onlyLauncher {
        if (positions[token].tokenId != 0) revert AlreadyRegistered();
        positions[token] = Position({
            tokenId:         tokenId,
            feeWallet:       feeWallet,
            token0:          token0,
            token1:          token1,
            pool:            pool,
            positionManager: positionManager
        });
        allTokens.push(token);
        emit PositionRegistered(token, tokenId, feeWallet, pool, positionManager);
    }

    function burnEnabled(address token) public view returns (bool) {
        return !_burnDisabled[token];
    }

    // Callable by either the token's own feeWallet (their project, their tokenomics) or the
    // platform owner (same override authority ctoFeeWallet already has). Takes effect on the
    // next claim; doesn't retroactively affect fees already distributed.
    function setBurnEnabled(address token, bool enabled) external {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();
        if (msg.sender != pos.feeWallet && msg.sender != owner) revert NotAuthorized();
        _burnDisabled[token] = !enabled;
        emit BurnToggled(token, enabled);
    }

    function claimFees(address token) external {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();
        // address(this) allowed so claimAllFees / claimFeesRange can use try this.claimFees()
        if (msg.sender != pos.feeWallet && msg.sender != owner && msg.sender != address(this))
            revert NotAuthorized();
        _collectAndDistribute(token, pos);
    }

    function claimAllFees() external onlyOwner {
        uint256 len = allTokens.length;
        for (uint256 i; i < len; ++i) {
            try this.claimFees(allTokens[i]) {} catch {} // skip failures, don't brick the sweep
        }
    }

    // Paginated variant of claimAllFees — use when the full list exceeds block gas limit.
    function claimFeesRange(uint256 from, uint256 to) external onlyOwner {
        uint256 len = allTokens.length;
        if (to > len) to = len;
        for (uint256 i = from; i < to; ++i) {
            try this.claimFees(allTokens[i]) {} catch {}
        }
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    // Returns the creator's share of currently uncollected fees using V3 fee-growth math.
    // See BLITZR.md → "Pending Fee Formula" for derivation. If burn is enabled for this token,
    // the leg matching the launched token itself is reported as 0 here — that leg goes to
    // BURN_ADDRESS on claim, not to the creator.
    function pendingCreatorFees(address token) external view returns (
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();

        token0 = pos.token0;
        token1 = pos.token1;

        (,,,,,int24 tickLower, int24 tickUpper, uint128 liquidity,
         uint256 fg0Last, uint256 fg1Last, uint128 owed0, uint128 owed1) =
            IPositionManager(pos.positionManager).positions(pos.tokenId);

        if (liquidity == 0) return (token0, token1, 0, 0);

        IUniswapV3PoolFees poolView = IUniswapV3PoolFees(pos.pool);
        (, int24 currentTick,,,,,) = poolView.slot0();

        // Pass fgGlobal values inline to avoid two extra stack slots.
        (uint256 fgi0, uint256 fgi1) = _feeGrowthInside(
            poolView, tickLower, tickUpper, currentTick,
            poolView.feeGrowthGlobal0X128(), poolView.feeGrowthGlobal1X128()
        );

        bool tokenIsToken0 = token == token0;
        bool burning = burnEnabled(token);

        unchecked {
            uint256 liq = uint256(liquidity);
            uint256 raw0 = liq * (fgi0 - fg0Last) / (1 << 128) + owed0;
            uint256 raw1 = liq * (fgi1 - fg1Last) / (1 << 128) + owed1;
            amount0 = (burning && tokenIsToken0)  ? 0 : raw0 * creatorBps / BPS;
            amount1 = (burning && !tokenIsToken0) ? 0 : raw1 * creatorBps / BPS;
        }
    }

    // Standard V3 fee-growth-inside derivation; all unchecked subtraction wraps intentionally.
    function _feeGrowthInside(
        IUniswapV3PoolFees pool,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint256 fgGlobal0,
        uint256 fgGlobal1
    ) private view returns (uint256 fgInside0, uint256 fgInside1) {
        (,, uint256 lo0, uint256 lo1,,,,) = pool.ticks(tickLower);
        (,, uint256 hi0, uint256 hi1,,,,) = pool.ticks(tickUpper);
        unchecked {
            uint256 below0 = currentTick >= tickLower ? lo0 : fgGlobal0 - lo0;
            uint256 above0 = currentTick <  tickUpper ? hi0 : fgGlobal0 - hi0;
            uint256 below1 = currentTick >= tickLower ? lo1 : fgGlobal1 - lo1;
            uint256 above1 = currentTick <  tickUpper ? hi1 : fgGlobal1 - hi1;
            fgInside0 = fgGlobal0 - below0 - above0;
            fgInside1 = fgGlobal1 - below1 - above1;
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return 0x150b7a02; // bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))
    }

    function _collectAndDistribute(address token, Position storage pos) private {
        (uint256 a0, uint256 a1) = IPositionManager(pos.positionManager).collect(
            IPositionManager.CollectParams({
                tokenId:    pos.tokenId,
                recipient:  address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        if (a0 == 0 && a1 == 0) return; // nothing to claim

        uint256 creator0;  uint256 creator1;
        uint256 platform0; uint256 platform1;
        uint256 burned0;   uint256 burned1;

        // Snapshot before external transfers — guards against re-entrancy changing bps/burn
        // setting mid-flight.
        uint256 cBps = creatorBps;
        bool tokenIsToken0 = token == pos.token0;
        bool burning = burnEnabled(token);

        if (a0 > 0) {
            if (burning && tokenIsToken0) {
                burned0 = a0;
                _safeTransfer(pos.token0, BURN_ADDRESS, burned0);
            } else {
                creator0  = a0 * cBps / BPS;
                platform0 = a0 - creator0; // remainder absorbs rounding dust
                _safeTransfer(pos.token0, pos.feeWallet,  creator0);
                _safeTransfer(pos.token0, platformWallet, platform0);
            }
        }
        if (a1 > 0) {
            if (burning && !tokenIsToken0) {
                burned1 = a1;
                _safeTransfer(pos.token1, BURN_ADDRESS, burned1);
            } else {
                creator1  = a1 * cBps / BPS;
                platform1 = a1 - creator1;
                _safeTransfer(pos.token1, pos.feeWallet,  creator1);
                _safeTransfer(pos.token1, platformWallet, platform1);
            }
        }

        emit FeesClaimed(token, pos.feeWallet, creator0, creator1, platform0, platform1);
        if (burned0 > 0 || burned1 > 0) emit FeesBurned(token, burned0, burned1);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        if (amount == 0) return; // USDT and some tokens revert on zero-amount transfer
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount) // transfer(address,uint256)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
