// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {BlitzrLocker} from "../../../contracts/BlitzrLocker.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockV3Factory, MockPositionManager} from "../../mocks/MockUniswapV3.sol";

// Bounded random actor for BlitzrLocker invariant fuzzing. Registers a handful of token
// positions up front (registerToken, called from the invariant test's setUp — not itself a fuzz
// target, so the token set stays fixed and enumerable) then randomly accrues fees, claims, and
// toggles burn across them.
contract BlitzrLockerHandler is Test {
    BlitzrLocker public immutable locker;
    MockV3Factory public immutable factory;
    MockPositionManager public immutable positionManager;
    address public immutable feeWallet;

    uint24 private constant FEE = 10_000;
    uint256 private constant MAX_TOKENS = 4;

    address[] public launchedTokens; // token0 side, "the launched token" by this suite's convention
    address[] public quoteTokens;    // token1 side
    uint256[] public tokenIds;
    address[] public pools;

    constructor(BlitzrLocker locker_, MockV3Factory factory_, MockPositionManager pm_, address feeWallet_) {
        locker = locker_;
        factory = factory_;
        positionManager = pm_;
        feeWallet = feeWallet_;
    }

    function launchedTokenCount() external view returns (uint256) {
        return launchedTokens.length;
    }

    function registerToken() public {
        if (launchedTokens.length >= MAX_TOKENS) return;

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        address pool = factory.createPool(t0, t1, FEE);

        uint256 seedAmount = 1_000_000e18;
        MockERC20(t0).mint(address(this), seedAmount);
        MockERC20(t0).approve(address(positionManager), seedAmount);

        MockPositionManager.MintParams memory params = MockPositionManager.MintParams({
            token0: t0,
            token1: t1,
            fee: FEE,
            tickLower: -200,
            tickUpper: 200,
            amount0Desired: seedAmount,
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(locker),
            deadline: block.timestamp
        });
        (uint256 tokenId,,,) = positionManager.mint(params);
        locker.registerPosition(t0, tokenId, feeWallet, t0, t1, pool, address(positionManager));

        launchedTokens.push(t0);
        quoteTokens.push(t1);
        tokenIds.push(tokenId);
        pools.push(pool);
    }

    function accrueAndClaim(uint256 tokenSeed, uint256 amount0, uint256 amount1) external {
        if (launchedTokens.length == 0) return;
        uint256 i = tokenSeed % launchedTokens.length;
        amount0 = bound(amount0, 0, 1_000e18);
        amount1 = bound(amount1, 0, 1_000e18);
        if (amount0 > 0) MockERC20(launchedTokens[i]).mint(pools[i], amount0);
        if (amount1 > 0) MockERC20(quoteTokens[i]).mint(pools[i], amount1);
        positionManager.setCollectable(tokenIds[i], amount0, amount1);
        try locker.claimFees(launchedTokens[i]) {} catch {}
    }

    function toggleBurn(uint256 tokenSeed, bool enabled) external {
        if (launchedTokens.length == 0) return;
        uint256 i = tokenSeed % launchedTokens.length;
        vm.prank(feeWallet);
        try locker.setBurnEnabled(launchedTokens[i], enabled) {} catch {}
    }

    function claimAll() external {
        try locker.claimAllFees() {} catch {}
    }
}
