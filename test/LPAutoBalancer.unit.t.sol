// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";
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

    // ─── helper: register a slot and return its slotId ─────────────────────

    function _registerSlot() internal returns (uint256 slotId) {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        vm.prank(admin);
        slotId = lab.registerPosition(cfg);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Task 7 — admin/manager setters, pause, token recovery
    // ═══════════════════════════════════════════════════════════════════════

    // ─── setPositionConfig ──────────────────────────────────────────────────

    function test_setPositionConfig_happy() public {
        uint256 slotId = _registerSlot();

        vm.prank(manager);
        vm.expectEmit(true, false, false, false);
        emit LPAutoBalancer.PositionConfigUpdated(slotId);
        lab.setPositionConfig(slotId, 200, 1800, 600, 200, 3600, 200, 200, 7200);

        // Read back — check a few fields via the public getter tuple (22 fields total)
        // tokenId, pool, token0, token1, tickSpacing, gauge, staked, feeCollector,
        // oracle0, oracle1, swapPolicy, protectedToken, minWidth, maxWidth,
        // maxCenterDeviation, maxSlippageBps, twapWindow, maxTickDeviation,
        // maxRebalanceLossBps, minRebalanceInterval, lastRebalance, active
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            , // 12 skipped (tokenId..protectedToken)
            uint24 minW,
            uint24 maxW,
            , // maxCenterDeviation
            uint16 slip,
            uint32 twap,
            , // maxTickDeviation
            uint16 loss,
            , // minRebalanceInterval
            , // lastRebalance
                // active
        ) = lab.positions(slotId);
        assertEq(minW, 200);
        assertEq(maxW, 1800);
        assertEq(slip, 200);
        assertEq(twap, 3600);
        assertEq(loss, 200);
    }

    function test_setPositionConfig_revertNonManager() public {
        uint256 slotId = _registerSlot();
        address caller = makeAddr("rando");
        bytes32 managerRole = lab.MANAGER_ROLE();
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, managerRole)
        );
        lab.setPositionConfig(slotId, 200, 1800, 600, 200, 3600, 200, 200, 7200);
    }

    function test_setPositionConfig_revertNotActive() public {
        // slot 0 was never registered
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.NotActive.selector);
        lab.setPositionConfig(0, 200, 1800, 600, 200, 3600, 200, 200, 7200);
    }

    function test_setPositionConfig_revertSlippageCap() public {
        uint256 slotId = _registerSlot();
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.SlippageCapExceeded.selector);
        lab.setPositionConfig(slotId, 200, 1800, 600, 501, 3600, 200, 200, 7200);
    }

    function test_setPositionConfig_revertLossCap() public {
        uint256 slotId = _registerSlot();
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.LossCapExceeded.selector);
        lab.setPositionConfig(slotId, 200, 1800, 600, 200, 3600, 200, 501, 7200);
    }

    function test_setPositionConfig_revertWidthNotMultiple() public {
        uint256 slotId = _registerSlot(); // tickSpacing=200
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.InvalidWidth.selector);
        // minWidth=150 not multiple of 200
        lab.setPositionConfig(slotId, 150, 1800, 600, 200, 3600, 200, 200, 7200);
    }

    function test_setPositionConfig_revertMaxWidthNotMultiple() public {
        uint256 slotId = _registerSlot(); // tickSpacing=200
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.InvalidWidth.selector);
        // maxWidth=2100 not multiple of 200
        lab.setPositionConfig(slotId, 200, 2100, 600, 200, 3600, 200, 200, 7200);
    }

    function test_setPositionConfig_revertInvalidConfig_twapZero() public {
        uint256 slotId = _registerSlot();
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.setPositionConfig(slotId, 200, 1800, 600, 200, 0, 200, 200, 7200);
    }

    function test_setPositionConfig_revertInvalidConfig_tickDevZero() public {
        uint256 slotId = _registerSlot();
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.setPositionConfig(slotId, 200, 1800, 600, 200, 3600, 0, 200, 7200);
    }

    // ─── setFeeCollector ────────────────────────────────────────────────────

    function test_setFeeCollector_happy() public {
        uint256 slotId = _registerSlot();
        address newCollector = makeAddr("newCollector");

        vm.prank(manager);
        vm.expectEmit(true, true, false, false);
        emit LPAutoBalancer.FeeCollectorUpdated(slotId, newCollector);
        lab.setFeeCollector(slotId, newCollector);

        (,,,,,,, address storedFeeCollector,,,,,,,,,,,,,,) = lab.positions(slotId);
        assertEq(storedFeeCollector, newCollector);
    }

    function test_setFeeCollector_revertNonManager() public {
        uint256 slotId = _registerSlot();
        address caller = makeAddr("rando");
        bytes32 managerRole = lab.MANAGER_ROLE();
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, managerRole)
        );
        lab.setFeeCollector(slotId, makeAddr("newCollector"));
    }

    function test_setFeeCollector_revertNotActive() public {
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.NotActive.selector);
        lab.setFeeCollector(0, makeAddr("newCollector"));
    }

    function test_setFeeCollector_revertZeroAddress() public {
        uint256 slotId = _registerSlot();
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.ZeroAddress.selector);
        lab.setFeeCollector(slotId, address(0));
    }

    // ─── setOracles ─────────────────────────────────────────────────────────

    function test_setOracles_happy() public {
        uint256 slotId = _registerSlot();
        address newOracle0 = makeAddr("newOracle0");
        address newOracle1 = makeAddr("newOracle1");

        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit LPAutoBalancer.OraclesUpdated(slotId, newOracle0, newOracle1);
        lab.setOracles(slotId, newOracle0, newOracle1);

        (,,,,,,,, address storedOracle0, address storedOracle1,,,,,,,,,,,,) = lab.positions(slotId);
        assertEq(storedOracle0, newOracle0);
        assertEq(storedOracle1, newOracle1);
    }

    function test_setOracles_revertNonAdmin() public {
        uint256 slotId = _registerSlot();
        address caller = makeAddr("rando");
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.setOracles(slotId, makeAddr("o0"), makeAddr("o1"));
    }

    function test_setOracles_revertNotActive() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.NotActive.selector);
        lab.setOracles(0, makeAddr("o0"), makeAddr("o1"));
    }

    function test_setOracles_revertZeroOracle0() public {
        uint256 slotId = _registerSlot();
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.OracleRequired.selector);
        lab.setOracles(slotId, address(0), makeAddr("o1"));
    }

    function test_setOracles_revertZeroOracle1() public {
        uint256 slotId = _registerSlot();
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.OracleRequired.selector);
        lab.setOracles(slotId, makeAddr("o0"), address(0));
    }

    // ─── setSwapPolicy ──────────────────────────────────────────────────────

    function test_setSwapPolicy_happy_policyZero() public {
        uint256 slotId = _registerSlot();

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit LPAutoBalancer.SwapPolicyUpdated(slotId, 0, address(0));
        lab.setSwapPolicy(slotId, 0, address(0));

        (,,,,,,,,,, uint8 storedPolicy, address storedProtected,,,,,,,,,,) = lab.positions(slotId);
        assertEq(storedPolicy, 0);
        assertEq(storedProtected, address(0));
    }

    function test_setSwapPolicy_happy_policyOne() public {
        uint256 slotId = _registerSlot(); // token0 and token1 from _validConfig

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit LPAutoBalancer.SwapPolicyUpdated(slotId, 1, token0);
        lab.setSwapPolicy(slotId, 1, token0);

        (,,,,,,,,,, uint8 storedPolicy, address storedProtected,,,,,,,,,,) = lab.positions(slotId);
        assertEq(storedPolicy, 1);
        assertEq(storedProtected, token0);
    }

    function test_setSwapPolicy_revertNonAdmin() public {
        uint256 slotId = _registerSlot();
        address caller = makeAddr("rando");
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.setSwapPolicy(slotId, 0, address(0));
    }

    function test_setSwapPolicy_revertNotActive() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.NotActive.selector);
        lab.setSwapPolicy(0, 0, address(0));
    }

    function test_setSwapPolicy_revertInvalidPolicy() public {
        uint256 slotId = _registerSlot();
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidSwapPolicy.selector);
        lab.setSwapPolicy(slotId, 3, address(0));
    }

    function test_setSwapPolicy_revertProtectedNotPoolToken() public {
        uint256 slotId = _registerSlot();
        address notAToken = makeAddr("notAToken");
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.setSwapPolicy(slotId, 1, notAToken);
    }

    // ─── setGauge ───────────────────────────────────────────────────────────

    function test_setGauge_happy() public {
        uint256 slotId = _registerSlot();
        address newGauge = makeAddr("newGauge");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit LPAutoBalancer.GaugeUpdated(slotId, newGauge);
        lab.setGauge(slotId, newGauge);

        (,,,,, address storedGauge,,,,,,,,,,,,,,,,) = lab.positions(slotId);
        assertEq(storedGauge, newGauge);
    }

    function test_setGauge_allowsZero() public {
        uint256 slotId = _registerSlot();

        vm.prank(admin);
        lab.setGauge(slotId, address(0));

        (,,,,, address storedGauge,,,,,,,,,,,,,,,,) = lab.positions(slotId);
        assertEq(storedGauge, address(0));
    }

    function test_setGauge_revertNonAdmin() public {
        uint256 slotId = _registerSlot();
        address caller = makeAddr("rando");
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.setGauge(slotId, makeAddr("newGauge"));
    }

    function test_setGauge_revertNotActive() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.NotActive.selector);
        lab.setGauge(0, makeAddr("newGauge"));
    }

    // TODO(Task 13): test setGauge/deregister revert when staked once stake() exists

    // ─── setSwapPolicy — policy-zero clears protectedToken ──────────────────

    function test_setSwapPolicy_policyZeroClearsProtected() public {
        uint256 slotId = _registerSlot();

        // First set a non-zero policy so protectedToken is stored
        vm.prank(admin);
        lab.setSwapPolicy(slotId, 1, token0);

        // Now reset to policy 0 with a non-zero address — it must be cleared
        address someAddr = makeAddr("someNonZeroAddr");
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit LPAutoBalancer.SwapPolicyUpdated(slotId, 0, address(0));
        lab.setSwapPolicy(slotId, 0, someAddr);

        (,,,,,,,,,, uint8 storedPolicy, address storedProtected,,,,,,,,,,) = lab.positions(slotId);
        assertEq(storedPolicy, 0);
        assertEq(storedProtected, address(0));
    }

    // ─── setPositionConfig — zero maxCenterDeviation ─────────────────────────

    function test_setPositionConfig_revertZeroCenterDev() public {
        uint256 slotId = _registerSlot();
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        // maxCenterDeviation = 0 (3rd param after minWidth, maxWidth)
        lab.setPositionConfig(slotId, 200, 1800, 0, 200, 3600, 200, 200, 7200);
    }

    // ─── registerPosition — zero maxCenterDeviation ──────────────────────────

    function test_registerPosition_revertZeroCenterDev() public {
        LPAutoBalancer.ManagedPosition memory cfg = _validConfig();
        cfg.maxCenterDeviation = 0;
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.registerPosition(cfg);
    }

    // ─── setMaxOracleDelay ──────────────────────────────────────────────────

    function test_setMaxOracleDelay_happy() public {
        uint256 oldDelay = lab.maxOracleDelay();
        uint256 newDelay = 12 hours;

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit LPAutoBalancer.MaxOracleDelayUpdated(oldDelay, newDelay);
        lab.setMaxOracleDelay(newDelay);

        assertEq(lab.maxOracleDelay(), newDelay);
    }

    function test_setMaxOracleDelay_revertNonAdmin() public {
        address caller = makeAddr("rando");
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.setMaxOracleDelay(12 hours);
    }

    function test_setMaxOracleDelay_revertZero() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.setMaxOracleDelay(0);
    }

    function test_setMaxOracleDelay_revertExceedsSevenDays() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.setMaxOracleDelay(7 days + 1);
    }

    function test_setMaxOracleDelay_boundarySevenDays() public {
        vm.prank(admin);
        lab.setMaxOracleDelay(7 days); // exactly 7 days — should succeed
        assertEq(lab.maxOracleDelay(), 7 days);
    }

    // ─── pause / unpause ────────────────────────────────────────────────────

    function test_pause_happy() public {
        assertFalse(lab.paused());
        vm.prank(guardian);
        lab.pause();
        assertTrue(lab.paused());
    }

    function test_unpause_happy() public {
        vm.prank(guardian);
        lab.pause();
        assertTrue(lab.paused());

        vm.prank(guardian);
        lab.unpause();
        assertFalse(lab.paused());
    }

    function test_pause_revertNonGuardian() public {
        address caller = makeAddr("rando");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, lab.GUARDIAN_ROLE()
            )
        );
        vm.prank(caller);
        lab.pause();
    }

    function test_unpause_revertNonGuardian() public {
        vm.prank(guardian);
        lab.pause();

        address caller = makeAddr("rando");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, lab.GUARDIAN_ROLE()
            )
        );
        vm.prank(caller);
        lab.unpause();
    }

    // ─── recoverERC20 ───────────────────────────────────────────────────────

    function test_recoverERC20_happy() public {
        MockERC20 token = new MockERC20("Mock", "MCK");
        token.mint(address(lab), 1000 ether);

        address recipient = makeAddr("recipient");

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit LPAutoBalancer.TokensRecovered(address(token), recipient, 1000 ether);
        lab.recoverERC20(address(token), recipient, 1000 ether);

        assertEq(token.balanceOf(recipient), 1000 ether);
        assertEq(token.balanceOf(address(lab)), 0);
    }

    function test_recoverERC20_revertNonAdmin() public {
        MockERC20 token = new MockERC20("Mock", "MCK");
        address caller = makeAddr("rando");
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.recoverERC20(address(token), makeAddr("recipient"), 100);
    }

    function test_recoverERC20_revertZeroTo() public {
        MockERC20 token = new MockERC20("Mock", "MCK");
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.ZeroAddress.selector);
        lab.recoverERC20(address(token), address(0), 100);
    }

    // ─── recoverETH ─────────────────────────────────────────────────────────

    function test_recoverETH_happy() public {
        vm.deal(address(lab), 1 ether);
        address payable recipient = payable(makeAddr("ethRecipient"));

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit LPAutoBalancer.TokensRecovered(address(0), recipient, 1 ether);
        lab.recoverETH(recipient);

        assertEq(recipient.balance, 1 ether);
        assertEq(address(lab).balance, 0);
    }

    function test_recoverETH_revertNonAdmin() public {
        address caller = makeAddr("rando");
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.recoverETH(payable(makeAddr("recipient")));
    }

    function test_recoverETH_revertZeroTo() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.ZeroAddress.selector);
        lab.recoverETH(payable(address(0)));
    }
}
