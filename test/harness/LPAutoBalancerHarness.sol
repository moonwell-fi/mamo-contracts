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

    function readFeed(address feed) external view returns (uint256, uint8) {
        return _readFeed(feed);
    }

    function valueInUsd(uint256 a0, uint256 a1, address o0, address o1, uint8 d0, uint8 d1)
        external
        view
        returns (uint256)
    {
        return _valueInUsd(a0, a1, o0, o1, d0, d1);
    }

    function computeSwap(
        uint160 sqrtP,
        int24 tl,
        int24 tu,
        uint256 b0,
        uint256 b1,
        uint8 policy,
        address t0,
        address t1,
        address prot
    ) external pure returns (bool, uint256) {
        return _computeSwap(sqrtP, tl, tu, b0, b1, policy, t0, t1, prot);
    }

    function executeSwap(address tin, address tout, uint256 amtIn, int24 spacing, uint256 callerMin, uint16 slippage)
        external
        returns (uint256)
    {
        return _executeSwap(tin, tout, amtIn, spacing, callerMin, slippage);
    }
}
