// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";

import {Test} from "@forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Unit coverage for the registry's privileged-identity and strategy-type bookkeeping.
/// @dev Deliberately NOT a fork test: the integration suite binds to the already-deployed
///      MAMO_STRATEGY_REGISTRY on Base, so it can never exercise changes to this source file.
contract MamoStrategyRegistryUnitTest is Test {
    MamoStrategyRegistry public registry;

    address public admin = makeAddr("admin");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");

    /// @dev Hoisted: a call in ARGUMENT position (registry.BACKEND_ROLE()) is evaluated first and
    ///      consumes a pending one-shot vm.prank, so the guarded call would run unpranked.
    bytes32 public backendRole;
    bytes32 public adminRole;

    function setUp() public {
        registry = new MamoStrategyRegistry(admin, backend, guardian);
        backendRole = registry.BACKEND_ROLE();
        adminRole = registry.DEFAULT_ADMIN_ROLE();
    }

    // ==================== MOO-731: OPERATOR IDENTITY IS NOT SET ORDERING ====================

    function testStrategyOperatorDefaultsToConstructorBackend() public view {
        assertEq(registry.strategyOperator(), backend);
        assertEq(registry.getBackendAddress(), backend);
    }

    /// @notice The finding: BACKEND_ROLE is shared with the factories, and EnumerableSet removal
    ///         is swap-and-pop. Revoking the member at index 0 used to move the LAST member —
    ///         plausibly a factory — into the operator slot, silently handing it updatePosition /
    ///         claimRewards / setFeeRecipient rights (and halting the real operator).
    function testRevokingRoleMemberZeroDoesNotMoveOperator() public {
        address factory = makeAddr("factory");

        vm.startPrank(admin);
        registry.grantRole(backendRole, factory);
        vm.stopPrank();

        // Sanity: the pre-fix implementation read exactly this member.
        assertEq(registry.getRoleMember(backendRole, 0), backend);

        vm.prank(admin);
        registry.revokeRole(backendRole, backend);

        // Swap-and-pop really did move the factory into slot zero...
        assertEq(registry.getRoleMember(backendRole, 0), factory, "swap-and-pop moved the factory");
        // ...but the operator identity is unaffected by set ordering.
        assertEq(registry.getBackendAddress(), backend, "operator must not follow set ordering");
        assertTrue(registry.getBackendAddress() != factory, "factory must not inherit operator rights");
    }

    function testSetStrategyOperator() public {
        address newOperator = makeAddr("newOperator");

        vm.expectEmit(true, true, false, false);
        emit MamoStrategyRegistry.StrategyOperatorUpdated(backend, newOperator);
        vm.prank(admin);
        registry.setStrategyOperator(newOperator);

        assertEq(registry.strategyOperator(), newOperator);
        assertEq(registry.getBackendAddress(), newOperator);
    }

    function testRevertSetStrategyOperatorNotAdmin() public {
        vm.prank(backend);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, backend, adminRole)
        );
        registry.setStrategyOperator(makeAddr("newOperator"));
    }

    function testRevertSetStrategyOperatorZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("Invalid strategy operator address");
        registry.setStrategyOperator(address(0));
    }

    /// @notice The rotation the finding describes: revoke the compromised key, grant the new one,
    ///         move the operator. Nothing is derived from the member set at any point.
    function testKeyRotationKeepsOperatorExplicit() public {
        address newBackend = makeAddr("newBackend");

        vm.startPrank(admin);
        registry.grantRole(backendRole, newBackend);
        registry.revokeRole(backendRole, backend);
        registry.setStrategyOperator(newBackend);
        vm.stopPrank();

        assertEq(registry.getBackendAddress(), newBackend);
        assertFalse(registry.hasRole(backendRole, backend));
    }

    // ============ MOO-731 FOLLOW-UP: FAST-PATH CONTAINMENT OF A COMPROMISED OPERATOR ============

    /// @notice Making the operator explicit slowed containment down: revoking BACKEND_ROLE no
    ///         longer strips a compromised key of its strategy-level authority, and the only
    ///         replacement path is DEFAULT_ADMIN (a timelocked multisig). Pausing the registry does
    ///         not help either — the strategies' onlyBackend entry points are not pausable. The
    ///         guardian therefore gets a one-way OFF switch.
    function testGuardianCanFreezeStrategyOperator() public {
        vm.expectEmit(true, true, false, false);
        emit MamoStrategyRegistry.StrategyOperatorUpdated(backend, address(registry));
        vm.prank(guardian);
        registry.freezeStrategyOperator();

        // The compromised key is no longer "the backend" as far as any strategy is concerned.
        assertEq(registry.getBackendAddress(), address(registry), "operator points at the sentinel");
        assertTrue(registry.getBackendAddress() != backend, "compromised key lost strategy authority");

        // Revoking the role alone would NOT have achieved this — the pre-freeze state is the
        // proof: role membership and operator identity are independent by design.
        assertTrue(registry.hasRole(backendRole, backend), "role membership is untouched by the freeze");
    }

    /// @notice The freeze must never be a way for the guardian to BECOME the operator; the only
    ///         reachable value is the registry itself, which no key controls and which never calls
    ///         a strategy's onlyBackend surface.
    function testFreezeCannotHandTheGuardianOperatorRights() public {
        vm.prank(guardian);
        registry.freezeStrategyOperator();

        assertTrue(registry.getBackendAddress() != guardian, "guardian cannot install itself");

        // Recovery is deliberately the slow path: only DEFAULT_ADMIN can install a live operator.
        address freshOperator = makeAddr("freshOperator");
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, adminRole)
        );
        registry.setStrategyOperator(freshOperator);

        vm.prank(admin);
        registry.setStrategyOperator(freshOperator);
        assertEq(registry.getBackendAddress(), freshOperator);
    }

    function testRevertFreezeStrategyOperatorNotGuardian() public {
        bytes32 guardianRole = registry.GUARDIAN_ROLE();

        vm.prank(backend);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, backend, guardianRole)
        );
        registry.freezeStrategyOperator();
    }

    function testRevertFreezeStrategyOperatorTwice() public {
        vm.prank(guardian);
        registry.freezeStrategyOperator();

        vm.prank(guardian);
        vm.expectRevert("Strategy operator already frozen");
        registry.freezeStrategyOperator();
    }

    // ============ MOO-737: ONLY AUTO-ASSIGNMENT MAY CREATE A STRATEGY TYPE ============

    /// @notice An explicit id may only ROLL OUT an implementation for a type that already exists.
    ///         Creating a type at a caller-chosen id is what let an explicit registration squat the
    ///         slot the counter was about to hand out.
    function testExplicitUnknownStrategyTypeIdReverts() public {
        assertEq(registry.nextStrategyTypeId(), 1);

        vm.prank(admin);
        vm.expectRevert("Unknown strategy type");
        registry.whitelistImplementation(makeAddr("implA"), 7);

        assertEq(registry.nextStrategyTypeId(), 1, "a rejected call must not move the counter");
        assertEq(registry.latestImplementationById(7), address(0), "no phantom type may be created");
    }

    /// @notice A mistyped id is now a revert rather than a strategy type nothing can deploy against.
    function testExplicitIdOneAboveTheCounterReverts() public {
        vm.startPrank(admin);
        registry.whitelistImplementation(makeAddr("implA"), 0); // id 1, counter -> 2
        vm.expectRevert("Unknown strategy type");
        registry.whitelistImplementation(makeAddr("implB"), 2); // the very next slot: still unknown
        vm.stopPrank();

        assertEq(registry.nextStrategyTypeId(), 2, "counter untouched by the rejected call");
    }

    /// @notice The original finding, now impossible by construction: an explicit id can no longer
    ///         occupy a free slot, so the next automatic registration cannot collide with one and
    ///         overwrite latestImplementationById.
    function testAutomaticIdCannotCollideWithAnExplicitId() public {
        address implA = makeAddr("implA");
        address implB = makeAddr("implB");

        vm.startPrank(admin);
        uint256 assignedA = registry.whitelistImplementation(implA, 0);
        uint256 assignedB = registry.whitelistImplementation(implB, 0);
        vm.stopPrank();

        assertEq(assignedA, 1);
        assertEq(assignedB, 2, "automatic ids never repeat");
        assertEq(registry.latestImplementationById(1), implA, "earlier implementation still current for its type");
        assertEq(registry.latestImplementationById(2), implB);
        assertEq(registry.implementationToId(implA), 1);
        assertEq(registry.implementationToId(implB), 2);
    }

    function testRolloutForAnExistingTypeDoesNotMoveTheCounter() public {
        vm.startPrank(admin);
        registry.whitelistImplementation(makeAddr("implA"), 0); // id 1, counter -> 2
        registry.whitelistImplementation(makeAddr("implB"), 0); // id 2, counter -> 3
        uint256 assigned = registry.whitelistImplementation(makeAddr("implC"), 1); // rollout for type 1
        vm.stopPrank();

        assertEq(assigned, 1);
        assertEq(registry.nextStrategyTypeId(), 3, "a rollout must not move the counter");
    }

    /// @notice Re-registering an occupied id is the implementation ROLLOUT path and must keep
    ///         working — rejecting occupied slots would break upgrades, not collisions.
    function testImplementationRolloutReusesTypeId() public {
        address v1 = makeAddr("v1");
        address v2 = makeAddr("v2");

        vm.startPrank(admin);
        uint256 typeId = registry.whitelistImplementation(v1, 0);
        registry.whitelistImplementation(v2, typeId);
        vm.stopPrank();

        assertEq(registry.latestImplementationById(typeId), v2);
        assertTrue(registry.whitelistedImplementations(v1), "old implementation stays whitelisted for upgrades");
    }
}
