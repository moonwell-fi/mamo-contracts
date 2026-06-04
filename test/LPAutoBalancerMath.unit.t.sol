// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {FixedPoint96} from "@libraries/uniswap/FixedPoint96.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";

contract LPAutoBalancerMathUnitTest is Test {
    function test_fullMath_mulDiv_basic() public pure {
        assertEq(FullMath.mulDiv(6, 7, 2), 21);
    }

    function test_fullMath_mulDiv_phantomOverflow() public pure {
        // exercises the full 512-bit multiply + CRT reconstruction path
        assertEq(FullMath.mulDiv(type(uint256).max, 5, type(uint256).max), 5);
    }

    function test_fullMath_mulDivRoundingUp() public pure {
        // 7 * 1 / 2 = 3.5 -> floor 3 (sanity vs mulDiv)
        assertEq(FullMath.mulDiv(7, 1, 2), 3);
        // 7 * 1 / 2 = 3.5 -> ceil 4 (round-up branch: mulmod != 0)
        assertEq(FullMath.mulDivRoundingUp(7, 1, 2), 4);
        // 6 * 1 / 2 = 3 exact -> 3 (no rounding: mulmod == 0)
        assertEq(FullMath.mulDivRoundingUp(6, 1, 2), 3);
    }

    function test_fixedPoint96_q96() public pure {
        assertEq(FixedPoint96.Q96, 0x1000000000000000000000000); // 2**96
    }

    function test_tickMath_knownAnswers() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(0), 79228162514264337593543950336); // 2**96, price 1.0
        assertEq(TickMath.MIN_TICK, -887272);
        assertEq(TickMath.MAX_TICK, 887272);
        int24[3] memory ticks = [int24(200), int24(-200), int24(60000)];
        for (uint256 i; i < ticks.length; i++) {
            uint160 s = TickMath.getSqrtRatioAtTick(ticks[i]);
            int24 back = TickMath.getTickAtSqrtRatio(s);
            assertApproxEqAbs(int256(back), int256(ticks[i]), 1);
        }
    }

    function test_tickMath_extremeRoundTrip() public pure {
        int24[10] memory ticks = [int24(-887272), -700000, -500000, -100000, -1, 1, 100000, 500000, 700000, 887271];
        for (uint256 i; i < ticks.length; i++) {
            uint160 s = TickMath.getSqrtRatioAtTick(ticks[i]);
            int24 back = TickMath.getTickAtSqrtRatio(s);
            assertApproxEqAbs(int256(back), int256(ticks[i]), 1);
        }
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK), TickMath.MIN_SQRT_RATIO);
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK), TickMath.MAX_SQRT_RATIO);
    }
}
