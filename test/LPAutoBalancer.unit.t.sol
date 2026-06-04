// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";
import {Test} from "@forge-std/Test.sol";

contract LPAutoBalancerUnitTest is Test {
    LPAutoBalancer lab;
    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");
    address pm = makeAddr("positionManager");
    address router = makeAddr("router");
    address quoter = makeAddr("quoter");
    address aero = makeAddr("aero");

    function setUp() public {
        lab = new LPAutoBalancer(admin, manager, rebalancer, guardian, pm, router, quoter, aero);
    }

    function test_rolesGranted() public view {
        assertTrue(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(lab.hasRole(lab.MANAGER_ROLE(), manager));
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), rebalancer));
        assertTrue(lab.hasRole(lab.GUARDIAN_ROLE(), guardian));
    }

    function test_immutablesWired() public view {
        assertEq(address(lab.POSITION_MANAGER()), pm);
        assertEq(address(lab.SWAP_ROUTER()), router);
        assertEq(address(lab.QUOTER()), quoter);
        assertEq(lab.AERO(), aero);
        assertEq(lab.maxOracleDelay(), 26 hours);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(LPAutoBalancer.ZeroAddress.selector);
        new LPAutoBalancer(address(0), manager, rebalancer, guardian, pm, router, quoter, aero);
    }
}
