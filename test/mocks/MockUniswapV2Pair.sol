// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Test double for a Uniswap V2 pair's oracle-relevant surface (OracleLib only reads
// token0/getReserves/price{0,1}CumulativeLast — never swaps against this mock directly). Test
// helpers let a test directly control the cumulative accumulators and timestamp rather than
// simulating real reserve/swap mechanics, since OracleLib.getV2Value only cares about the delta
// between two recorded points.
contract MockUniswapV2Pair {
    address public token0;
    address public token1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32  public blockTimestampLast;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (0, 0, blockTimestampLast);
    }

    function setCumulative(uint256 price0CumulativeLast_, uint256 price1CumulativeLast_, uint32 blockTimestampLast_)
        external
    {
        price0CumulativeLast = price0CumulativeLast_;
        price1CumulativeLast = price1CumulativeLast_;
        blockTimestampLast = blockTimestampLast_;
    }
}
