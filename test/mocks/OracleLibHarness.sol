// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {OracleLib} from "../../BlitzrSwapRouter/libraries/OracleLib.sol";

// OracleLib's V2 functions operate on a storage mapping passed by reference — this harness just
// holds that mapping and exposes thin wrappers so tests can call the library directly.
contract OracleLibHarness {
    mapping(address => OracleLib.V2Observation) public observations;

    function updateV2Observation(address pair) external {
        OracleLib.updateV2Observation(observations, pair);
    }

    function getV2Value(address pair, address token, uint256 amountIn, uint256 minElapsed)
        external
        view
        returns (uint256)
    {
        return OracleLib.getV2Value(observations, pair, token, amountIn, minElapsed);
    }

    function getV3Value(address pool, address token, uint256 amountIn, uint32 window) external view returns (uint256) {
        return OracleLib.getV3Value(pool, token, amountIn, window);
    }

    function getV3TwapTick(address pool, uint32 window) external view returns (int24) {
        return OracleLib.getV3TwapTick(pool, window);
    }
}
