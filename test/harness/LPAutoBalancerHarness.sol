// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

/// @notice Test-only subclass that re-exposes internal math helpers as public.
contract LPAutoBalancerHarness is LPAutoBalancer {
    constructor(address a, address m, address r, address g, address pm, address sr, address q, address aero)
        LPAutoBalancer(a, m, r, g, pm, sr, q, aero)
    {}

    function alignedRange(int24 ref, uint24 width, int24 spacing, int24 cur) external pure returns (int24, int24) {
        return _alignedRange(ref, width, spacing, cur);
    }

    function consultTwapTick(address pool, uint32 window) external view returns (int24) {
        return _consultTwapTick(pool, window);
    }

    function checkDeviation(int24 spot, int24 twap, int24 maxDev) external pure {
        _checkDeviation(spot, twap, maxDev);
    }
}
