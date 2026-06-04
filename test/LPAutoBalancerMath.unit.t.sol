// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {FixedPoint96} from "@libraries/uniswap/FixedPoint96.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";

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
}
