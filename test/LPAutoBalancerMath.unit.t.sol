// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {FixedPoint96} from "@libraries/uniswap/FixedPoint96.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";

contract LPAutoBalancerMathUnitTest is Test {
    function test_fullMath_mulDiv_basic() public pure {
        assertEq(FullMath.mulDiv(6, 7, 2), 21);
        assertEq(FullMath.mulDiv(type(uint256).max, 5, type(uint256).max), 5);
    }

    function test_fixedPoint96_q96() public pure {
        assertEq(FixedPoint96.Q96, 0x1000000000000000000000000); // 2**96
    }
}
