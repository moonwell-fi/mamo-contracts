// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {LPAutoBalancerHarness} from "./harness/LPAutoBalancerHarness.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

/// @notice Unit tests for _alignedRange / _floorAlign (Task 8) and
///         _consultTwapTick / _checkDeviation (Task 9).
contract LPAutoBalancerMath2UnitTest is Test {
    LPAutoBalancerHarness harness;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");
    address router = makeAddr("router");
    address quoter = makeAddr("quoter");
    address aero = makeAddr("aero");

    function setUp() public {
        MockPositionManager mockPM = new MockPositionManager(address(0));
        harness = new LPAutoBalancerHarness(admin, manager, rebalancer, guardian, address(mockPM), router, quoter, aero);
    }

    // ─── _alignedRange tests ─────────────────────────────────────────────────

    function test_alignedRange_centersAndAligns() public view {
        (int24 lo, int24 hi) = harness.alignedRange(0, 2000, 200, 0);
        assertEq(lo, -1000);
        assertEq(hi, 1000);
        assertEq(lo % 200, 0);
        assertEq(hi % 200, 0);
        assertTrue(lo < 0 && 0 < hi);
    }

    function test_alignedRange_negativeFloor() public view {
        (int24 lo, int24 hi) = harness.alignedRange(-150, 2000, 200, -150);
        assertEq(hi - lo, 2000);
        assertEq(lo % 200, 0);
        assertEq(hi % 200, 0);
        assertTrue(lo < -150 && -150 < hi);
    }

    function test_alignedRange_revertNoStraddle() public {
        // currentTick outside [lo,hi] must revert
        vm.expectRevert(bytes("no straddle"));
        harness.alignedRange(0, 2000, 200, 5000);
    }

    // ─── _consultTwapTick tests (Task 9) ─────────────────────────────────────

    /// @dev Positive delta: TWAP tick = 2000*60 / 60 = 2000.
    function test_consultTwapTick_positive() public {
        MockCLPool pool = new MockCLPool();
        // delta = cum[1] - cum[0] = 120000 - 0 = 120000; window = 60 → twap = 2000
        pool.setObserve(0, int56(2000) * int56(uint56(60)));
        int24 result = harness.consultTwapTick(address(pool), 60);
        assertEq(result, 2000);
    }

    /// @dev Negative delta not evenly divisible: must round toward -inf (floor).
    ///      window=60, delta=-120001. truncated = -120001/60 = -2000 (toward zero).
    ///      Since delta<0 and delta%60 = -1 != 0, result must be -2001.
    function test_consultTwapTick_negativeRoundsTowardNegInf() public {
        MockCLPool pool = new MockCLPool();
        // cum[0]=0, cum[1]=-120001 → delta = -120001
        pool.setObserve(0, -120001);
        int24 result = harness.consultTwapTick(address(pool), 60);
        assertEq(result, -2001);
    }

    // ─── _checkDeviation tests (Task 9) ──────────────────────────────────────

    /// @dev diff = |1000 - 950| = 50 <= 100: must not revert.
    function test_checkDeviation_passWithinBound() public view {
        harness.checkDeviation(1000, 950, 100); // no revert
    }

    /// @dev diff = |1000 - 800| = 200 > 100: must revert with TwapDeviation.
    function test_checkDeviation_revertBeyondBound() public {
        vm.expectRevert(LPAutoBalancer.TwapDeviation.selector);
        harness.checkDeviation(1000, 800, 100);
    }

    /// @dev Negative ticks: diff = |-1000 - (-1050)| = 50 <= 100: must not revert.
    function test_checkDeviation_negativeSpot() public view {
        harness.checkDeviation(-1000, -1050, 100); // no revert
    }
}
