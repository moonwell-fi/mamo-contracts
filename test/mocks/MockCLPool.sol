// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICLPool} from "@interfaces/ICLPool.sol";

/// @notice Minimal mock of ICLPool.observe for unit-testing _consultTwapTick.
///         Caller sets `tickCumulative0` and `tickCumulative1` which are returned
///         for secondsAgos[0] (window) and secondsAgos[1] (0) respectively.
contract MockCLPool is ICLPool {
    int56 public tickCumulative0; // returned for secondsAgos[0] (older timestamp)
    int56 public tickCumulative1; // returned for secondsAgos[1] (current timestamp)

    function setObserve(int56 cum0, int56 cum1) external {
        tickCumulative0 = cum0;
        tickCumulative1 = cum1;
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulative0;
        tickCumulatives[1] = tickCumulative1;

        secondsPerLiquidityCumulativeX128 = new uint160[](2);
        // both zero — unused in _consultTwapTick
    }

    // ── Unused ICLPool methods ────────────────────────────────────────────────

    function slot0()
        external
        pure
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        )
    {
        return (0, 0, 0, 0, 0, true);
    }

    function token0() external pure returns (address) {
        return address(0);
    }

    function token1() external pure returns (address) {
        return address(0);
    }

    function tickSpacing() external pure returns (int24) {
        return 1;
    }

    function liquidity() external pure returns (uint128) {
        return 0;
    }
}
