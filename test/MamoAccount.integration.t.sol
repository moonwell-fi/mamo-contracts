// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {Vm} from "@forge-std/Vm.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoAccount} from "@contracts/MamoAccount.sol";
import {MamoAccountFactory} from "@contracts/MamoAccountFactory.sol";
import {MamoAccountRegistry} from "@contracts/MamoAccountRegistry.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {IMulticall} from "@interfaces/IMulticall.sol";

import {DeployMamoStaking} from "@script/DeployMamoStaking.s.sol";

contract MamoAccountIntegrationTest is Test {
    Addresses public addresses;
    MamoAccountRegistry public accountRegistry;
    MamoAccountFactory public mamoAccountFactory;
    MamoStrategyRegistry public mamoStrategyRegistry;
    MamoAccount public userAccount;

    address public user;
    address public backend;
    address public guardian;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));

        // Create addresses instance
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get deployer address from addresses
        address deployer = addresses.getAddress("DEPLOYER_EOA");

        // Create an instance of the deployment script
        DeployMamoStaking deployScript = new DeployMamoStaking();

        // Deploy contracts using the DeployMamoStaking script functions
        address[] memory deployedContracts = deployScript.deploy(addresses, deployer);

        // Set contract instances
        accountRegistry = MamoAccountRegistry(deployedContracts[0]);
        mamoAccountFactory = MamoAccountFactory(deployedContracts[1]);

        // Get strategy registry from addresses
        mamoStrategyRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Get role addresses
        backend = addresses.getAddress("MAMO_BACKEND");
        guardian = addresses.getAddress("MAMO_MULTISIG");

        // Create test user
        user = makeAddr("testUser");
    }

    // Helper function to deploy user account
    function _deployUserAccount(address userAddress) internal returns (MamoAccount) {
        vm.startPrank(backend);
        MamoAccount account = MamoAccount(payable(mamoAccountFactory.createAccountForUser(userAddress)));
        vm.stopPrank();
        return account;
    }

    // Helper function to create a mock strategy contract
    function _createMockStrategy() internal returns (address) {
        return makeAddr("mockStrategy");
    }

    // ========== INITIALIZATION TESTS ==========

    function testAccountInitialization() public {
        userAccount = _deployUserAccount(user);

        // Verify initialization values
        assertEq(userAccount.owner(), user, "Owner should be set correctly");
        assertEq(address(userAccount.registry()), address(accountRegistry), "Registry should be set correctly");
        assertEq(
            address(userAccount.mamoStrategyRegistry()),
            address(mamoStrategyRegistry),
            "Strategy registry should be set correctly"
        );
        assertEq(userAccount.strategyTypeId(), 2, "Strategy type ID should be 2");
    }

    function testAccountHasCorrectStrategyTypeId() public {
        userAccount = _deployUserAccount(user);

        // Verify the MamoAccount has the correct strategyTypeId
        assertEq(userAccount.strategyTypeId(), 2, "MamoAccount should have strategyTypeId 2");
    }

    // ========== MULTICALL TESTS - HAPPY PATH ==========

    function testMulticallExecutesSuccessfully() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Approve strategy in registry
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        // Whitelist strategy for account
        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        // Create a simple target that will succeed (EOA)
        address payable simpleTarget = payable(makeAddr("simpleTarget"));

        // Prepare multicall data
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: simpleTarget, data: "", value: 0});

        // Execute multicall as whitelisted strategy
        vm.startPrank(mockStrategy);
        userAccount.multicall(calls);
        vm.stopPrank();
    }

    function testMulticallWithETHTransfer() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Approve strategy in registry
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        // Whitelist strategy for account
        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        // Create a target address to receive ETH
        address payable ethReceiver = payable(makeAddr("ethReceiver"));
        uint256 ethAmount = 1 ether;

        // Fund the mock strategy with ETH
        vm.deal(mockStrategy, ethAmount);

        // Prepare multicall data with ETH transfer
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: ethReceiver, data: "", value: ethAmount});

        uint256 initialBalance = ethReceiver.balance;

        // Execute multicall with ETH transfer
        vm.startPrank(mockStrategy);
        userAccount.multicall{value: ethAmount}(calls);
        vm.stopPrank();

        // Verify ETH was transferred
        assertEq(ethReceiver.balance, initialBalance + ethAmount, "ETH should be transferred to receiver");
    }

    function testMulticallWithExcessETHRefund() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Approve strategy in registry
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        // Whitelist strategy for account
        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        address payable ethReceiver = payable(makeAddr("ethReceiver"));
        uint256 callValue = 0.5 ether;
        uint256 sentValue = 1 ether;
        uint256 expectedRefund = sentValue - callValue;

        // Fund the mock strategy with ETH
        vm.deal(mockStrategy, sentValue);

        // Prepare multicall data
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: ethReceiver, data: "", value: callValue});

        uint256 initialStrategyBalance = mockStrategy.balance;

        // Execute multicall with excess ETH
        vm.startPrank(mockStrategy);
        userAccount.multicall{value: sentValue}(calls);
        vm.stopPrank();

        // Verify refund was sent back to strategy
        assertEq(mockStrategy.balance, initialStrategyBalance - callValue, "Excess ETH should be refunded to caller");
        assertEq(ethReceiver.balance, callValue, "Correct amount should be sent to receiver");
    }

    function testMulticallWithMultipleCalls() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Approve strategy in registry
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        // Whitelist strategy for account
        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        // Create multiple target addresses
        address target1 = makeAddr("target1");
        address target2 = makeAddr("target2");

        // Prepare multicall data with multiple calls
        IMulticall.Call[] memory calls = new IMulticall.Call[](2);
        calls[0] = IMulticall.Call({target: target1, data: "", value: 0});
        calls[1] = IMulticall.Call({target: target2, data: "", value: 0});

        // Execute multicall
        vm.startPrank(mockStrategy);
        userAccount.multicall(calls);
        vm.stopPrank();
    }

    // ========== MULTICALL TESTS - UNHAPPY PATH ==========

    function testMulticallRevertsWhenNotWhitelistedStrategy() public {
        userAccount = _deployUserAccount(user);
        address unauthorizedStrategy = makeAddr("unauthorizedStrategy");

        // Don't whitelist the strategy

        // Prepare multicall data
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: makeAddr("target"), data: "", value: 0});

        // Attempt multicall with non-whitelisted strategy
        vm.startPrank(unauthorizedStrategy);
        vm.expectRevert("Strategy not whitelisted");
        userAccount.multicall(calls);
        vm.stopPrank();
    }

    function testMulticallRevertsWithEmptyCallsArray() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Setup whitelisted strategy
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        // Prepare empty calls array
        IMulticall.Call[] memory calls = new IMulticall.Call[](0);

        // Attempt multicall with empty array
        vm.startPrank(mockStrategy);
        vm.expectRevert("Multicall: Empty calls array");
        userAccount.multicall(calls);
        vm.stopPrank();
    }

    function testMulticallRevertsWithInsufficientETH() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Setup whitelisted strategy
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        uint256 requiredETH = 1 ether;
        uint256 sentETH = 0.5 ether;

        // Prepare multicall data requiring more ETH than sent
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: makeAddr("target"), data: "", value: requiredETH});

        vm.deal(mockStrategy, sentETH);

        // Attempt multicall with insufficient ETH
        vm.startPrank(mockStrategy);
        vm.expectRevert("Multicall: Insufficient ETH provided");
        userAccount.multicall{value: sentETH}(calls);
        vm.stopPrank();
    }

    function testMulticallRevertsWithInvalidTargetAddress() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Setup whitelisted strategy
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        // Prepare multicall data with zero address target
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: address(0), data: "", value: 0});

        // Attempt multicall with invalid target
        vm.startPrank(mockStrategy);
        vm.expectRevert("Multicall: Invalid target address");
        userAccount.multicall(calls);
        vm.stopPrank();
    }

    function testMulticallRevertsWhenCallFails() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Setup whitelisted strategy
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        // Create a contract that will revert
        address revertingTarget = makeAddr("revertingTarget");
        // Deploy a contract that reverts on any call
        vm.etch(revertingTarget, hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT

        // Prepare multicall data that will fail
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: revertingTarget, data: abi.encodeWithSignature("someFunction()"), value: 0});

        // Attempt multicall with failing call
        vm.startPrank(mockStrategy);
        vm.expectRevert();
        userAccount.multicall(calls);
        vm.stopPrank();
    }

    // ========== OWNERSHIP TESTS ==========

    function testTransferOwnership() public {
        userAccount = _deployUserAccount(user);
        address newOwner = makeAddr("newOwner");

        // Mock the registry updateStrategyOwner call since MamoAccount is not a registered strategy
        vm.mockCall(
            address(mamoStrategyRegistry),
            abi.encodeWithSignature("updateStrategyOwner(address)", newOwner),
            abi.encode()
        );

        // Transfer ownership
        vm.startPrank(user);
        userAccount.transferOwnership(newOwner);
        vm.stopPrank();

        // Verify ownership transfer in contract
        assertEq(userAccount.owner(), newOwner, "Ownership should be transferred");
    }

    function testTransferOwnershipRevertsWhenNotOwner() public {
        userAccount = _deployUserAccount(user);
        address attacker = makeAddr("attacker");
        address newOwner = makeAddr("newOwner");

        // Attempt to transfer ownership as non-owner
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        userAccount.transferOwnership(newOwner);
        vm.stopPrank();
    }

    function testRenounceOwnershipReverts() public {
        userAccount = _deployUserAccount(user);

        // Attempt to renounce ownership
        vm.startPrank(user);
        vm.expectRevert("Ownership cannot be renounced in this contract");
        userAccount.renounceOwnership();
        vm.stopPrank();
    }

    function testRenounceOwnershipRevertsWhenNotOwner() public {
        userAccount = _deployUserAccount(user);
        address attacker = makeAddr("attacker");

        // Attempt to renounce ownership as non-owner
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        userAccount.renounceOwnership();
        vm.stopPrank();
    }

    // ========== UPGRADE TESTS ==========

    function testUpgradeToNewImplementation() public {
        userAccount = _deployUserAccount(user);

        // Deploy a new implementation by deploying another MamoAccount contract
        MamoAccount newImplementation = new MamoAccount();

        // Get current implementation to set up the strategy ID mapping
        address currentImplementation = ERC1967Proxy(payable(address(userAccount))).getImplementation();
        uint256 strategyId = mamoStrategyRegistry.implementationToId(currentImplementation);

        // Whitelist the new implementation with the same strategy ID (admin role required)
        address admin = addresses.getAddress("MAMO_MULTISIG");
        vm.startPrank(admin);
        mamoStrategyRegistry.whitelistImplementation(address(newImplementation), strategyId);
        vm.stopPrank();

        // Test that the upgrade works when called through the registry by the user
        vm.startPrank(user);
        mamoStrategyRegistry.upgradeStrategy(address(userAccount), address(newImplementation));
        vm.stopPrank();

        // Verify the implementation was updated
        assertEq(
            ERC1967Proxy(payable(address(userAccount))).getImplementation(),
            address(newImplementation),
            "Implementation should be updated"
        );
    }

    function testUpgradeRevertsWithNonWhitelistedImplementation() public {
        userAccount = _deployUserAccount(user);

        // Create a new implementation address that's not whitelisted
        address newImplementation = makeAddr("newImplementation");

        // Attempt upgrade with non-whitelisted implementation through the registry
        vm.startPrank(user);
        vm.expectRevert("Not latest implementation");
        mamoStrategyRegistry.upgradeStrategy(address(userAccount), newImplementation);
        vm.stopPrank();
    }

    function testUpgradeRevertsWhenNotOwner() public {
        userAccount = _deployUserAccount(user);
        address attacker = makeAddr("attacker");
        address newImplementation = makeAddr("newImplementation");

        // Attempt upgrade as non-owner through the registry
        vm.startPrank(attacker);
        vm.expectRevert("Caller is not the owner of the strategy");
        mamoStrategyRegistry.upgradeStrategy(address(userAccount), newImplementation);
        vm.stopPrank();
    }

    // ========== EVENTS TESTS ==========

    function testMulticallEmitsEvent() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Setup whitelisted strategy
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        // Prepare multicall data
        IMulticall.Call[] memory calls = new IMulticall.Call[](2);
        calls[0] = IMulticall.Call({target: makeAddr("target1"), data: "", value: 0});
        calls[1] = IMulticall.Call({target: makeAddr("target2"), data: "", value: 0});

        // Expect MulticallExecuted event
        vm.expectEmit(true, false, false, true);
        emit MamoAccount.MulticallExecuted(mockStrategy, 2);

        // Execute multicall
        vm.startPrank(mockStrategy);
        userAccount.multicall(calls);
        vm.stopPrank();
    }

    // ========== REGISTRY INTEGRATION TESTS ==========

    function testAccountHasCorrectRegistryReference() public {
        userAccount = _deployUserAccount(user);

        // Verify the account references the correct registry
        assertEq(
            address(userAccount.mamoStrategyRegistry()),
            address(mamoStrategyRegistry),
            "Registry reference should be correct"
        );
    }

    // ========== REENTRANCY TESTS ==========

    function testMulticallReentrancyProtection() public {
        userAccount = _deployUserAccount(user);
        address mockStrategy = _createMockStrategy();

        // Setup whitelisted strategy
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), mockStrategy, true);
        vm.stopPrank();

        // Create a simple target that doesn't revert
        address simpleTarget = makeAddr("simpleTarget");

        // Prepare multicall data targeting a simple contract
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: simpleTarget, data: "", value: 0});

        // Execute multicall - should be protected by ReentrancyGuard
        vm.startPrank(mockStrategy);
        userAccount.multicall(calls);
        vm.stopPrank();
    }
}
