// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {LPAutoBalancerHarness} from "./harness/LPAutoBalancerHarness.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

/// @notice Unit tests for _alignedRange / _floorAlign (Task 8).
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
}
