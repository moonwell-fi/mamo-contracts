// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";
import {MockCLGauge} from "./mocks/MockCLGauge.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {Test} from "@forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract LPAutoBalancerV2UnitTest is Test {
    LPAutoBalancerV2 lab;
    MockPositionManager mockPM;
    MockERC20 mockAero;
    MockCLGauge mockGauge;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");

    // Addresses for valid config
    address pool = makeAddr("pool");
    address token0 = makeAddr("token0");
    address token1 = makeAddr("token1");
    address gauge; // set in setUp to address(mockGauge)
    address feeCollector = makeAddr("feeCollector");
    address oracle0; // set in setUp to a MockPriceFeed (registerPosition probes feeds)
    address oracle1;

    uint256 constant TOKEN_ID = 42;

    function setUp() public {
        // Deploy mock AERO token (real ERC20 so SafeERC20 transfers work)
        mockAero = new MockERC20("Aerodrome", "AERO");

        // Deploy mock gauge backed by mockAero
        mockGauge = new MockCLGauge(address(mockAero));
        gauge = address(mockGauge);

        // mockPM owner defaults to address(0); will be updated after lab deploy
        mockPM = new MockPositionManager(address(0));

        // Real mock feeds: registerPosition probes latestRoundData at set-time
        oracle0 = address(new MockPriceFeed(1e8, 8, block.timestamp));
        oracle1 = address(new MockPriceFeed(1e8, 8, block.timestamp));

        // V2 constructor: no swapRouter, no quoter
        lab = new LPAutoBalancerV2(admin, manager, rebalancer, guardian, address(mockPM), address(mockAero));

        // Now that lab is deployed, point mockPM owner to lab so ownerOf checks pass
        mockPM.setMockOwner(address(lab));
    }

    // ─── helper ─────────────────────────────────────────────────────────────

    /// @dev Build and register a ManagedPositionV2 slot.
    ///      withGauge=true sets gauge field; false leaves it address(0).
    function _registerSlot(bool withGauge) internal returns (uint256 slotId) {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: withGauge ? gauge : address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 200,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 100,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 3600,
            lastRebalance: 999, // should be forced to 0 by _store
            active: false // should be forced to true by _store
        });
        vm.prank(admin);
        slotId = lab.registerPosition(cfg);
    }

    // ─── constructor tests ───────────────────────────────────────────────────

    function test_rolesGranted() public view {
        assertTrue(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(lab.hasRole(lab.MANAGER_ROLE(), manager));
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), rebalancer));
        assertTrue(lab.hasRole(lab.GUARDIAN_ROLE(), guardian));
    }

    function test_immutablesWired() public view {
        assertEq(address(lab.POSITION_MANAGER()), address(mockPM));
        assertEq(lab.AERO(), address(mockAero));
        assertEq(lab.maxOracleDelay(), 26 hours);
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        new LPAutoBalancerV2(address(0), manager, rebalancer, guardian, address(mockPM), address(mockAero));
    }

    function test_constructorRejectsZeroPositionManager() public {
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        new LPAutoBalancerV2(admin, manager, rebalancer, guardian, address(0), address(mockAero));
    }

    function test_constructorRejectsZeroAero() public {
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        new LPAutoBalancerV2(admin, manager, rebalancer, guardian, address(mockPM), address(0));
    }

    // ─── smoke test ──────────────────────────────────────────────────────────

    function test_deploys_and_registers() public {
        uint256 slotId = _registerSlot(false);

        // ManagedPositionV2 public getter tuple — 21 fields in declaration order:
        // mainTokenId, altTokenId, pool, token0, token1, tickSpacing,
        // gauge, mainStaked, altStaked, feeCollector, oracle0, oracle1,
        // minWidth, maxWidth, maxCenterDeviation, twapWindow, maxTickDeviation,
        // maxRebalanceLossBps, minRebalanceInterval, lastRebalance, active
        (
            uint256 storedMainTokenId,
            uint256 storedAltTokenId,
            address storedPool,,,
            int24 storedTickSpacing,,
            bool storedMainStaked,
            bool storedAltStaked,,,,,,,,,,,
            uint256 storedLastRebalance,
            bool storedActive
        ) = lab.positions(slotId);

        assertEq(slotId, 0);
        assertEq(lab.nextSlotId(), 1);
        assertEq(storedMainTokenId, TOKEN_ID); // registered tokenId
        assertEq(storedAltTokenId, 0); // forced to 0 by _store
        assertEq(storedPool, pool);
        assertEq(storedTickSpacing, 200);
        assertFalse(storedMainStaked); // forced false
        assertFalse(storedAltStaked); // forced false
        assertEq(storedLastRebalance, 0); // forced 0 by _store
        assertTrue(storedActive); // forced true by _store
    }

    // ─── registerPosition validation ─────────────────────────────────────────

    function test_registerPosition_revertNonAdmin() public {
        address caller = makeAddr("nonAdmin");
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 200,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 100,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 3600,
            lastRebalance: 0,
            active: false
        });
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertLossCap() public {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 200,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 100,
            maxRebalanceLossBps: 501, // exceeds MAX_LOSS_CAP_BPS=500
            minRebalanceInterval: 3600,
            lastRebalance: 0,
            active: false
        });
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.LossCapExceeded.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertNotHeld() public {
        mockPM.setMockOwner(makeAddr("someoneElse"));
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 200,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 100,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 3600,
            lastRebalance: 0,
            active: false
        });
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.NotHeld.selector);
        lab.registerPosition(cfg);
    }

    // ─── no swapPolicy / no slippage cap ─────────────────────────────────────

    function test_noSwapPolicyField() public {
        // Verify struct has no swapPolicy: compile-time check via _registerSlot succeeding
        // and no runtime revert for any "slippage cap exceeded" path
        uint256 slotId = _registerSlot(false);
        assertTrue(slotId == 0); // just confirm it registered
    }
}
