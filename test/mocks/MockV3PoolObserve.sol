// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Test double for a Uniswap V3 pool's observe()-based TWAP surface — OracleLib.getV3Value only
// calls token0() and observe(). A test sets the two tickCumulative values directly (matching
// whatever mean tick it wants the TWAP math to produce) rather than simulating real swap-driven
// tick accumulation.
contract MockV3PoolObserve {
    address public token0;
    int56   public tickCumulativeStart; // value "window" seconds ago
    int56   public tickCumulativeNow;   // value now

    constructor(address token0_) {
        token0 = token0_;
    }

    function setTickCumulatives(int56 start, int56 now_) external {
        tickCumulativeStart = start;
        tickCumulativeNow = now_;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(secondsAgos.length == 2, "expected 2 secondsAgos");
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulativeStart;
        tickCumulatives[1] = tickCumulativeNow;
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }
}
