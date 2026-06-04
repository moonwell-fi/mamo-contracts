// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";
import {Test} from "@forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract LPAutoBalancerUnitTest is Test {
    LPAutoBalancer lab;
    MockPositionManager mockPM;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");
    address router = makeAddr("router");
    address quoter = makeAddr("quoter");
    address aero = makeAddr("aero");

    // Addresses for valid config
    address pool = makeAddr("pool");
    address token0 = makeAddr("token0");
    address token1 = makeAddr("token1");
    address gauge = makeAddr("gauge");
    address feeCollector = makeAddr("feeCollector");
    address oracle0 = makeAddr("oracle0");
    address oracle1 = makeAddr("oracle1");
    address protectedToken = makeAddr("protectedToken");

    uint256 constant TOKEN_ID = 42;

    function setUp() public {
        // mockPM owner defaults to address(0); will be updated after lab deploy
        mockPM = new MockPositionManager(address(0));

        lab = new LPAutoBalancer(admin, manager, rebalancer, guardian, address(mockPM), router, quoter, aero);

        // Now that lab is deployed, point mockPM owner to lab so ownerOf checks pass
        mockPM.setMockOwner(address(lab));
    }

    // ─── existing construction tests ────────────────────────────────────────

    function test_rolesGranted() public view {
        assertTrue(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(lab.hasRole(lab.MANAGER_ROLE(), manager));
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), rebalancer));
        assertTrue(lab.hasRole(lab.GUARDIAN_ROLE(), guardian));
    }

    function test_immutablesWired() public view {
        assertEq(address(lab.POSITION_MANAGER()), address(mockPM));
        assertEq(address(lab.SWAP_ROUTER()), router);
        assertEq(address(lab.QUOTER()), quoter);
        assertEq(lab.AERO(), aero);
        assertEq(lab.maxOracleDelay(), 26 hours);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(LPAutoBalancer.ZeroAddress.selector);
        new LPAutoBalancer(address(0), manager, rebalancer, guardian, address(mockPM), router, quoter, aero);
    }

    // ─── helpers ────────────────────────────────────────────────────────────

    function _validConfig() internal view returns (LPAutoBalancer.ManagedPosition memory) {
        return LPAutoBalancer.ManagedPosition({
            tokenId: TOKEN_ID,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: gauge,
            staked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            swapPolicy: 0,
            protectedToken: protectedToken,
            minWidth: 200,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            maxSlippageBps: 100,
            twapWindow: 1800,
            maxTickDeviation: 100,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 3600,
            lastRebalance: 999, // should be forced to 0 by _store
            active: false // should be forced to true by _store
        });
    }

    // ─── registerPosition tests ──────────────────────────────────────────────

    function test_registerPosition_revertNonAdmin() public {
        address caller = makeAddr("nonAdmin");
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertSlippageCap() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.maxSlippageBps = 501;
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.SlippageCapExceeded.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertLossCap() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.maxRebalanceLossBps = 501;
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.LossCapExceeded.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertWidth_notMultiple() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        // tickSpacing=200, minWidth=150 is not a multiple of 200
        cfg.minWidth = 150;
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidWidth.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertWidth_minGtMax() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.minWidth = 2200; // > maxWidth=2000
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidWidth.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertOracle() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.oracle0 = address(0);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.OracleRequired.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertNotHeld() public {
        mockPM.setMockOwner(makeAddr("someoneElse"));
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.NotHeld.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_happy() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        vm.prank(admin);
        uint256 slotId = lab.registerPosition(cfg);

        assertEq(slotId, 0);
        assertEq(lab.nextSlotId(), 1);

        // Destructure the stored position matching struct field order:
        // tokenId, pool, token0, token1, tickSpacing, gauge, staked, feeCollector,
        // oracle0, oracle1, swapPolicy, protectedToken, minWidth, maxWidth,
        // maxCenterDeviation, maxSlippageBps, twapWindow, maxTickDeviation,
        // maxRebalanceLossBps, minRebalanceInterval, lastRebalance, active
        (
            uint256 storedTokenId,
            address storedPool,
            ,
            ,
            int24 storedTickSpacing,
            ,
            bool storedStaked,
            ,
            ,
            ,
            uint8 storedSwapPolicy,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 storedLastRebalance,
            bool storedActive
        ) = lab.positions(0);

        assertEq(storedTokenId, TOKEN_ID);
        assertEq(storedPool, pool);
        assertEq(storedTickSpacing, 200);
        assertEq(storedSwapPolicy, 0);
        assertTrue(storedActive);
        assertFalse(storedStaked);
        assertEq(storedLastRebalance, 0); // _store forces this to 0
    }

    function test_registerPosition_revertPoolZero() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.pool = address(0);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertTwapZero() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.twapWindow = 0;
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertMaxTickDevZero() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.maxTickDeviation = 0;
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertTickSpacingZero() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.tickSpacing = 0;
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertWidth_maxNotMultiple() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        // tickSpacing=200, minWidth=200, maxWidth=2100 — 2100 % 200 != 0
        cfg.minWidth = 200;
        cfg.maxWidth = 2100;
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidWidth.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_slippageBoundaryValid() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.maxSlippageBps = 500; // exactly at cap — should succeed
        vm.prank(admin);
        uint256 slotId = lab.registerPosition(cfg);
        assertEq(slotId, 0);
    }

    function test_registerPosition_emitsEvent() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit LPAutoBalancer.PositionRegistered(0, pool, TOKEN_ID);
        lab.registerPosition(cfg);
    }

    // ─── deregisterPosition tests ────────────────────────────────────────────

    function test_deregisterPosition_happy() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        vm.prank(admin);
        lab.registerPosition(cfg);

        address recipient = makeAddr("recipient");
        vm.prank(admin);
        lab.deregisterPosition(0, recipient);

        // Mock PM recorded the safeTransferFrom
        assertEq(mockPM.lastFrom(), address(lab));
        assertEq(mockPM.lastTo(), recipient);
        assertEq(mockPM.lastTokenId(), TOKEN_ID);
        assertEq(mockPM.transferCallCount(), 1);

        // Position marked inactive — 22 fields, active is the last (index 21)
        (,,,,,,,,,,,,,,,,,,,,, bool storedActive) = lab.positions(0);
        assertFalse(storedActive);
    }

    function test_deregisterPosition_revertNonAdmin() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        vm.prank(admin);
        lab.registerPosition(cfg);

        address caller = makeAddr("nonAdmin");
        address recipient = makeAddr("recipient");
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.deregisterPosition(0, recipient);
    }

    function test_deregisterPosition_revertNotActive() public {
        // slotId 0 was never registered → active == false
        address recipient = makeAddr("recipient");
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.NotActive.selector);
        lab.deregisterPosition(0, recipient);
    }

    function test_deregisterPosition_revertZeroTo() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        vm.prank(admin);
        lab.registerPosition(cfg);

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.ZeroAddress.selector);
        lab.deregisterPosition(0, address(0));
    }

    function test_deregisterPosition_emitsEvent() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        vm.prank(admin);
        lab.registerPosition(cfg);

        address recipient = makeAddr("recipient");
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit LPAutoBalancer.PositionDeregistered(0, recipient);
        lab.deregisterPosition(0, recipient);
    }
}
