// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Concentrated liquidity pool stand-in that only reports a fixed tick spacing, for use in tests
contract MockCLPool {
    int24 public immutable tickSpacing;

    constructor(int24 tickSpacing_) {
        tickSpacing = tickSpacing_;
    }
}
