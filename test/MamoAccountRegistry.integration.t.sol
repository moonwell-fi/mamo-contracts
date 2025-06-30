// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {Vm} from "@forge-std/Vm.sol";

import {MamoAccount} from "@contracts/MamoAccount.sol";
import {MamoAccountRegistry} from "@contracts/MamoAccountRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

// Mock account contract that implements Ownable
contract MockAccount is Ownable {
    constructor(address owner) Ownable(owner) {}
}

contract MamoAccountRegistryIntegrationTest is Test {
    MamoAccountRegistry public registry;
    MockAccount public userAccount;
    ERC20Mock public mockToken;

    address public admin;
    address public backend;
    address public guardian;
    address public user;
    address public strategy;
    address public randomUser;

    event StrategyWhitelisted(address indexed account, address indexed strategy, bool approved);
    event StrategyApproved(address indexed strategy, bool approved);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        admin = makeAddr("admin");
        backend = makeAddr("backend");
        guardian = makeAddr("guardian");
        user = makeAddr("user");
        strategy = makeAddr("strategy");
        randomUser = makeAddr("randomUser");

        // Deploy registry
        registry = new MamoAccountRegistry(admin, backend, guardian);

        // Create mock user account owned by user
        userAccount = new MockAccount(user);

        // Deploy mock token
        mockToken = new ERC20Mock();
    }

    // ==================== CONSTRUCTOR TESTS ====================

    function testConstructorSetsRolesCorrectly() public {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), backend));
        assertTrue(registry.hasRole(registry.GUARDIAN_ROLE(), guardian));
    }

    function testConstructorRevertsWithZeroAddresses() public {
        vm.expectRevert("Invalid admin address");
        new MamoAccountRegistry(address(0), backend, guardian);

        vm.expectRevert("Invalid backend address");
        new MamoAccountRegistry(admin, address(0), guardian);

        vm.expectRevert("Invalid guardian address");
        new MamoAccountRegistry(admin, backend, address(0));
    }

    // ==================== STRATEGY APPROVAL TESTS ====================

    function testBackendCanApproveStrategy() public {
        vm.startPrank(backend);
        vm.expectEmit(true, false, false, true);
        emit StrategyApproved(strategy, true);
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();

        assertTrue(registry.approvedStrategies(strategy));
    }

    function testBackendCanRevokeStrategy() public {
        // First approve
        vm.startPrank(backend);
        registry.setApprovedStrategy(strategy, true);

        // Then revoke
        vm.expectEmit(true, false, false, true);
        emit StrategyApproved(strategy, false);
        registry.setApprovedStrategy(strategy, false);
        vm.stopPrank();

        assertFalse(registry.approvedStrategies(strategy));
    }

    function testOnlyBackendCanApproveStrategy() public {
        vm.startPrank(randomUser);
        vm.expectRevert();
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert();
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();
    }

    function testBackendCannotApproveZeroAddressStrategy() public {
        vm.startPrank(backend);
        vm.expectRevert("Invalid strategy");
        registry.setApprovedStrategy(address(0), true);
        vm.stopPrank();
    }

    function testApproveStrategyRevertsWhenPaused() public {
        vm.startPrank(guardian);
        registry.pause();
        vm.stopPrank();

        vm.startPrank(backend);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();
    }

    // ==================== WHITELIST STRATEGY TESTS ====================

    function testAccountOwnerCanWhitelistApprovedStrategy() public {
        // First approve strategy by backend
        vm.startPrank(backend);
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();

        // Then whitelist by account owner
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true);
        emit StrategyWhitelisted(address(userAccount), strategy, true);
        registry.setWhitelistStrategy(address(userAccount), strategy, true);
        vm.stopPrank();

        assertTrue(registry.isWhitelistedStrategy(address(userAccount), strategy));
    }

    function testAccountOwnerCanRevokeWhitelistedStrategy() public {
        // Setup: approve and whitelist
        vm.startPrank(backend);
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();

        vm.startPrank(user);
        registry.setWhitelistStrategy(address(userAccount), strategy, true);

        // Then revoke
        vm.expectEmit(true, true, false, true);
        emit StrategyWhitelisted(address(userAccount), strategy, false);
        registry.setWhitelistStrategy(address(userAccount), strategy, false);
        vm.stopPrank();

        assertFalse(registry.isWhitelistedStrategy(address(userAccount), strategy));
    }

    function testOnlyAccountOwnerCanWhitelistStrategy() public {
        // First approve strategy by backend
        vm.startPrank(backend);
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();

        // Random user cannot whitelist
        vm.startPrank(randomUser);
        vm.expectRevert("Not account owner");
        registry.setWhitelistStrategy(address(userAccount), strategy, true);
        vm.stopPrank();

        // Backend cannot whitelist
        vm.startPrank(backend);
        vm.expectRevert("Not account owner");
        registry.setWhitelistStrategy(address(userAccount), strategy, true);
        vm.stopPrank();
    }

    function testCannotWhitelistUnapprovedStrategy() public {
        vm.startPrank(user);
        vm.expectRevert("Strategy not approved by backend");
        registry.setWhitelistStrategy(address(userAccount), strategy, true);
        vm.stopPrank();
    }

    function testWhitelistStrategyRevertsWhenPaused() public {
        // Setup
        vm.startPrank(backend);
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();

        vm.startPrank(guardian);
        registry.pause();
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        registry.setWhitelistStrategy(address(userAccount), strategy, true);
        vm.stopPrank();
    }

    // ==================== TOKEN RECOVERY TESTS ====================

    function testAdminCanRecoverERC20() public {
        uint256 amount = 1000e18;
        mockToken.mint(address(registry), amount);

        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(mockToken), admin, amount);
        registry.recoverERC20(address(mockToken), admin, amount);
        vm.stopPrank();

        assertEq(mockToken.balanceOf(admin), amount);
        assertEq(mockToken.balanceOf(address(registry)), 0);
    }

    function testAdminCanRecoverETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(registry), amount);

        uint256 adminBalanceBefore = admin.balance;

        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(0), admin, amount);
        registry.recoverETH(payable(admin));
        vm.stopPrank();

        assertEq(admin.balance, adminBalanceBefore + amount);
        assertEq(address(registry).balance, 0);
    }

    function testOnlyAdminCanRecoverTokens() public {
        uint256 amount = 1000e18;
        mockToken.mint(address(registry), amount);

        vm.startPrank(backend);
        vm.expectRevert();
        registry.recoverERC20(address(mockToken), backend, amount);
        vm.stopPrank();

        vm.startPrank(randomUser);
        vm.expectRevert();
        registry.recoverERC20(address(mockToken), randomUser, amount);
        vm.stopPrank();
    }

    function testRecoverERC20RevertsWithZeroAddress() public {
        uint256 amount = 1000e18;
        mockToken.mint(address(registry), amount);

        vm.startPrank(admin);
        vm.expectRevert("Cannot send to zero address");
        registry.recoverERC20(address(mockToken), address(0), amount);
        vm.stopPrank();
    }

    function testRecoverERC20RevertsWithZeroAmount() public {
        vm.startPrank(admin);
        vm.expectRevert("Amount must be greater than 0");
        registry.recoverERC20(address(mockToken), admin, 0);
        vm.stopPrank();
    }

    function testRecoverETHRevertsWithZeroAddress() public {
        vm.deal(address(registry), 1 ether);

        vm.startPrank(admin);
        vm.expectRevert("Cannot send to zero address");
        registry.recoverETH(payable(address(0)));
        vm.stopPrank();
    }

    function testRecoverETHRevertsWithEmptyBalance() public {
        vm.startPrank(admin);
        vm.expectRevert("Empty balance");
        registry.recoverETH(payable(admin));
        vm.stopPrank();
    }

    // ==================== PAUSABLE TESTS ====================

    function testGuardianCanPause() public {
        vm.startPrank(guardian);
        registry.pause();
        vm.stopPrank();

        assertTrue(registry.paused());
    }

    function testGuardianCanUnpause() public {
        vm.startPrank(guardian);
        registry.pause();
        registry.unpause();
        vm.stopPrank();

        assertFalse(registry.paused());
    }

    function testOnlyGuardianCanPause() public {
        vm.startPrank(backend);
        vm.expectRevert();
        registry.pause();
        vm.stopPrank();

        vm.startPrank(randomUser);
        vm.expectRevert();
        registry.pause();
        vm.stopPrank();
    }

    function testOnlyGuardianCanUnpause() public {
        vm.startPrank(guardian);
        registry.pause();
        vm.stopPrank();

        vm.startPrank(backend);
        vm.expectRevert();
        registry.unpause();
        vm.stopPrank();

        vm.startPrank(randomUser);
        vm.expectRevert();
        registry.unpause();
        vm.stopPrank();
    }

    // ==================== INTEGRATION TEST SCENARIOS ====================

    function testCompleteStrategyApprovalWorkflow() public {
        // Step 1: Backend approves strategy
        vm.startPrank(backend);
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();
        assertTrue(registry.approvedStrategies(strategy));

        // Step 2: Account owner whitelists strategy
        vm.startPrank(user);
        registry.setWhitelistStrategy(address(userAccount), strategy, true);
        vm.stopPrank();
        assertTrue(registry.isWhitelistedStrategy(address(userAccount), strategy));

        // Step 3: Account owner can revoke whitelist
        vm.startPrank(user);
        registry.setWhitelistStrategy(address(userAccount), strategy, false);
        vm.stopPrank();
        assertFalse(registry.isWhitelistedStrategy(address(userAccount), strategy));

        // Step 4: Backend can revoke global approval
        vm.startPrank(backend);
        registry.setApprovedStrategy(strategy, false);
        vm.stopPrank();
        assertFalse(registry.approvedStrategies(strategy));
    }

    function testMultipleStrategiesForSameAccount() public {
        address strategy1 = makeAddr("strategy1");
        address strategy2 = makeAddr("strategy2");

        // Backend approves both strategies
        vm.startPrank(backend);
        registry.setApprovedStrategy(strategy1, true);
        registry.setApprovedStrategy(strategy2, true);
        vm.stopPrank();

        // Account owner whitelists both
        vm.startPrank(user);
        registry.setWhitelistStrategy(address(userAccount), strategy1, true);
        registry.setWhitelistStrategy(address(userAccount), strategy2, true);
        vm.stopPrank();

        assertTrue(registry.isWhitelistedStrategy(address(userAccount), strategy1));
        assertTrue(registry.isWhitelistedStrategy(address(userAccount), strategy2));
    }

    function testEmergencyPauseStopsOperations() public {
        // Setup approved strategy
        vm.startPrank(backend);
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();

        // Guardian pauses contract
        vm.startPrank(guardian);
        registry.pause();
        vm.stopPrank();

        // Operations should be blocked
        vm.startPrank(backend);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        registry.setApprovedStrategy(makeAddr("newStrategy"), true);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        registry.setWhitelistStrategy(address(userAccount), strategy, true);
        vm.stopPrank();

        // Unpause and operations should work again
        vm.startPrank(guardian);
        registry.unpause();
        vm.stopPrank();

        vm.startPrank(user);
        registry.setWhitelistStrategy(address(userAccount), strategy, true);
        vm.stopPrank();

        assertTrue(registry.isWhitelistedStrategy(address(userAccount), strategy));
    }

    function testEventEmissionsShowCorrectData() public {
        // Test strategy approval event
        vm.startPrank(backend);
        vm.expectEmit(true, false, false, true);
        emit StrategyApproved(strategy, true);
        registry.setApprovedStrategy(strategy, true);
        vm.stopPrank();

        // Test strategy whitelist event
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true);
        emit StrategyWhitelisted(address(userAccount), strategy, true);
        registry.setWhitelistStrategy(address(userAccount), strategy, true);
        vm.stopPrank();

        // Test token recovery event
        uint256 amount = 1000e18;
        mockToken.mint(address(registry), amount);

        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(mockToken), admin, amount);
        registry.recoverERC20(address(mockToken), admin, amount);
        vm.stopPrank();
    }
}
