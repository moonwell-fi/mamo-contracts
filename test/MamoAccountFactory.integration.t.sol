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

import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IMulticall} from "@interfaces/IMulticall.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {DeployMamoStaking} from "@script/DeployMamoStaking.s.sol";

contract MamoAccountFactoryIntegrationTest is Test {
    Addresses public addresses;
    MamoAccountRegistry public accountRegistry;
    MamoAccountFactory public mamoAccountFactory;
    MamoStrategyRegistry public mamoStrategyRegistry;

    address public user;
    address public backend;
    address public guardian;
    address public deployer;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));

        // Create addresses instance
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get deployer address from addresses
        deployer = addresses.getAddress("DEPLOYER_EOA");

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

    // ========== CONSTRUCTOR AND INITIALIZATION TESTS ==========

    function testFactoryInitialization() public {
        // Verify factory is properly initialized
        assertEq(mamoAccountFactory.mamoBackend(), backend, "Backend should be set correctly");
        assertEq(address(mamoAccountFactory.registry()), address(accountRegistry), "Registry should be set correctly");
        assertEq(
            address(mamoAccountFactory.mamoStrategyRegistry()),
            address(mamoStrategyRegistry),
            "Strategy registry should be set correctly"
        );
        assertNotEq(mamoAccountFactory.accountImplementation(), address(0), "Implementation should be set");
        assertEq(mamoAccountFactory.accountStrategyTypeId(), 2, "Strategy type ID should be 2");
    }

    // ========== USER ACCOUNT CREATION TESTS - HAPPY PATH ==========

    function testUserCanCreateAccountForThemselves() public {
        // User creates account for themselves
        vm.startPrank(user);
        address accountAddress = mamoAccountFactory.createAccount();
        vm.stopPrank();

        // Verify account was created
        assertNotEq(accountAddress, address(0), "Account address should not be zero");
        assertEq(mamoAccountFactory.getAccountForUser(user), accountAddress, "Account should be mapped to user");

        // Verify account is properly initialized
        MamoAccount account = MamoAccount(accountAddress);
        assertEq(account.owner(), user, "Owner should be set correctly");
        assertEq(address(account.registry()), address(accountRegistry), "Registry should be set correctly");
        assertEq(
            address(account.mamoStrategyRegistry()),
            address(mamoStrategyRegistry),
            "Strategy registry should be set correctly"
        );
        assertEq(account.strategyTypeId(), 2, "Strategy type ID should be 2");
    }

    function testBackendCanCreateAccountForUser() public {
        // Backend creates account for user
        vm.startPrank(backend);
        address accountAddress = mamoAccountFactory.createAccountForUser(user);
        vm.stopPrank();

        // Verify account was created
        assertNotEq(accountAddress, address(0), "Account address should not be zero");
        assertEq(mamoAccountFactory.getAccountForUser(user), accountAddress, "Account should be mapped to user");

        // Verify account is properly initialized
        MamoAccount account = MamoAccount(accountAddress);
        assertEq(account.owner(), user, "Owner should be set correctly");
        assertEq(address(account.registry()), address(accountRegistry), "Registry should be set correctly");
        assertEq(
            address(account.mamoStrategyRegistry()),
            address(mamoStrategyRegistry),
            "Strategy registry should be set correctly"
        );
        assertEq(account.strategyTypeId(), 2, "Strategy type ID should be 2");
    }

    function testAccountCreationEmitsEvent() public {
        vm.startPrank(user);

        // Calculate expected account address using CREATE2
        bytes32 salt = keccak256(abi.encodePacked(user));
        address expectedAccount = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode, abi.encode(mamoAccountFactory.accountImplementation(), "")
                )
            ),
            address(mamoAccountFactory)
        );

        // Expect AccountCreated event with all arguments
        vm.expectEmit(true, true, true, true);
        emit MamoAccountFactory.AccountCreated(user, expectedAccount, user);

        address accountAddress = mamoAccountFactory.createAccount();
        vm.stopPrank();

        assertEq(accountAddress, expectedAccount, "Account address should match expected");
    }

    function testBackendAccountCreationEmitsEvent() public {
        vm.startPrank(backend);

        // Calculate expected account address using CREATE2
        bytes32 salt = keccak256(abi.encodePacked(user));
        address expectedAccount = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode, abi.encode(mamoAccountFactory.accountImplementation(), "")
                )
            ),
            address(mamoAccountFactory)
        );

        // Expect AccountCreated event with backend as creator
        vm.expectEmit(true, true, true, true);
        emit MamoAccountFactory.AccountCreated(user, expectedAccount, backend);

        address accountAddress = mamoAccountFactory.createAccountForUser(user);
        vm.stopPrank();

        assertEq(accountAddress, expectedAccount, "Account address should match expected");
    }

    function testAccountIsRegisteredInStrategyRegistry() public {
        // Create account
        vm.startPrank(user);
        address accountAddress = mamoAccountFactory.createAccount();
        vm.stopPrank();

        // Verify account is registered in strategy registry
        address[] memory userStrategies = mamoStrategyRegistry.getUserStrategies(user);
        assertEq(userStrategies.length, 1, "User should have one strategy registered");
        assertEq(userStrategies[0], accountAddress, "Account should be registered as user's strategy");
        assertTrue(mamoStrategyRegistry.isUserStrategy(user, accountAddress), "Account should be user's strategy");
    }

    function testDeterministicAddressGeneration() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Create accounts for different users
        vm.startPrank(backend);
        address account1 = mamoAccountFactory.createAccountForUser(user1);
        address account2 = mamoAccountFactory.createAccountForUser(user2);
        vm.stopPrank();

        // Addresses should be different
        assertNotEq(account1, account2, "Different users should get different account addresses");

        // Create another user1 account (should fail due to duplicate check, but address would be the same)
        // We can't test this directly due to the duplicate check, but we can verify the mapping
        assertEq(mamoAccountFactory.getAccountForUser(user1), account1, "User1 account mapping should be consistent");
        assertEq(mamoAccountFactory.getAccountForUser(user2), account2, "User2 account mapping should be consistent");
    }

    function testMultipleUsersCanCreateAccounts() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        // Create accounts for multiple users
        vm.startPrank(user1);
        address account1 = mamoAccountFactory.createAccount();
        vm.stopPrank();

        vm.startPrank(backend);
        address account2 = mamoAccountFactory.createAccountForUser(user2);
        vm.stopPrank();

        vm.startPrank(user3);
        address account3 = mamoAccountFactory.createAccount();
        vm.stopPrank();

        // All accounts should be created and mapped correctly
        assertEq(mamoAccountFactory.getAccountForUser(user1), account1, "User1 account should be mapped");
        assertEq(mamoAccountFactory.getAccountForUser(user2), account2, "User2 account should be mapped");
        assertEq(mamoAccountFactory.getAccountForUser(user3), account3, "User3 account should be mapped");

        // All accounts should be different
        assertNotEq(account1, account2, "Account1 and Account2 should be different");
        assertNotEq(account1, account3, "Account1 and Account3 should be different");
        assertNotEq(account2, account3, "Account2 and Account3 should be different");
    }

    // ========== ACCOUNT CREATION TESTS - UNHAPPY PATH ==========

    function testCannotCreateDuplicateAccountForUser() public {
        // Create first account
        vm.startPrank(user);
        mamoAccountFactory.createAccount();
        vm.stopPrank();

        // Try to create second account - should fail
        vm.startPrank(user);
        vm.expectRevert("Account already exists");
        mamoAccountFactory.createAccount();
        vm.stopPrank();
    }

    function testBackendCannotCreateDuplicateAccountForUser() public {
        // Backend creates first account
        vm.startPrank(backend);
        mamoAccountFactory.createAccountForUser(user);
        vm.stopPrank();

        // Backend tries to create second account - should fail
        vm.startPrank(backend);
        vm.expectRevert("Account already exists");
        mamoAccountFactory.createAccountForUser(user);
        vm.stopPrank();
    }

    function testCannotCreateAccountForZeroAddress() public {
        vm.startPrank(backend);
        vm.expectRevert("Invalid user");
        mamoAccountFactory.createAccountForUser(address(0));
        vm.stopPrank();
    }

    function testOnlyBackendCanCreateAccountForUser() public {
        address attacker = makeAddr("attacker");

        vm.startPrank(attacker);
        vm.expectRevert("Only backend can create accounts for users");
        mamoAccountFactory.createAccountForUser(user);
        vm.stopPrank();
    }

    function testNonBackendCannotCreateAccountForAnotherUser() public {
        address anotherUser = makeAddr("anotherUser");

        vm.startPrank(user);
        vm.expectRevert("Only backend can create accounts for users");
        mamoAccountFactory.createAccountForUser(anotherUser);
        vm.stopPrank();
    }

    function testUserCannotCreateAccountAfterBackendCreatedOne() public {
        // Backend creates account first
        vm.startPrank(backend);
        mamoAccountFactory.createAccountForUser(user);
        vm.stopPrank();

        // User tries to create account - should fail
        vm.startPrank(user);
        vm.expectRevert("Account already exists");
        mamoAccountFactory.createAccount();
        vm.stopPrank();
    }

    function testBackendCannotCreateAccountAfterUserCreatedOne() public {
        // User creates account first
        vm.startPrank(user);
        mamoAccountFactory.createAccount();
        vm.stopPrank();

        // Backend tries to create account - should fail
        vm.startPrank(backend);
        vm.expectRevert("Account already exists");
        mamoAccountFactory.createAccountForUser(user);
        vm.stopPrank();
    }

    // ========== VIEW FUNCTION TESTS ==========

    function testGetAccountForUserReturnsZeroForNonExistentAccount() public {
        address nonExistentUser = makeAddr("nonExistentUser");
        assertEq(
            mamoAccountFactory.getAccountForUser(nonExistentUser),
            address(0),
            "Should return zero for non-existent account"
        );
    }

    function testGetAccountForUserReturnsCorrectAddress() public {
        // Create account
        vm.startPrank(user);
        address accountAddress = mamoAccountFactory.createAccount();
        vm.stopPrank();

        // Verify getter returns correct address
        assertEq(mamoAccountFactory.getAccountForUser(user), accountAddress, "Should return correct account address");
    }

    function testGetAccountForUserWorksForBackendCreatedAccounts() public {
        // Backend creates account
        vm.startPrank(backend);
        address accountAddress = mamoAccountFactory.createAccountForUser(user);
        vm.stopPrank();

        // Verify getter returns correct address
        assertEq(mamoAccountFactory.getAccountForUser(user), accountAddress, "Should return correct account address");
    }

    // ========== ACCOUNT FUNCTIONALITY TESTS ==========

    function testCreatedAccountIsFullyFunctional() public {
        // Create account
        vm.startPrank(user);
        address accountAddress = mamoAccountFactory.createAccount();
        vm.stopPrank();

        MamoAccount account = MamoAccount(accountAddress);

        // Test basic account functionality
        assertEq(account.owner(), user, "Owner should be correct");

        // Test that account can be used in multicall by first setting up a whitelisted strategy
        address mockStrategy = makeAddr("mockStrategy");

        // Approve strategy in registry
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(mockStrategy, true);
        vm.stopPrank();

        // Whitelist strategy for account
        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(accountAddress, mockStrategy, true);
        vm.stopPrank();

        // Create a simple multicall to test account functionality
        vm.startPrank(mockStrategy);
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: makeAddr("simpleTarget"), data: "", value: 0});
        account.multicall(calls); // Should succeed with whitelisted strategy
        vm.stopPrank();
    }

    function testAccountHasCorrectImplementation() public {
        // Create account
        vm.startPrank(user);
        address accountAddress = mamoAccountFactory.createAccount();
        vm.stopPrank();

        // Verify account uses correct implementation
        ERC1967Proxy proxy = ERC1967Proxy(payable(accountAddress));
        assertEq(
            proxy.getImplementation(), mamoAccountFactory.accountImplementation(), "Should use correct implementation"
        );
    }

    function testAccountCannotBeInitializedTwice() public {
        // Create account
        vm.startPrank(user);
        address accountAddress = mamoAccountFactory.createAccount();
        vm.stopPrank();

        MamoAccount account = MamoAccount(accountAddress);

        // Try to initialize again - should fail
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        account.initialize(user, accountRegistry, IMamoStrategyRegistry(address(mamoStrategyRegistry)), 2);
    }

    // ========== INTEGRATION TESTS ==========

    function testAccountWorksWithRegistryPermissions() public {
        // Create account
        vm.startPrank(user);
        address accountAddress = mamoAccountFactory.createAccount();
        vm.stopPrank();

        MamoAccount account = MamoAccount(accountAddress);

        // Test that account can interact with registry (verifies integration)
        // The account should be able to access registry functions
        assertEq(
            address(account.registry()), address(accountRegistry), "Account should have correct registry reference"
        );
        assertEq(
            address(account.mamoStrategyRegistry()),
            address(mamoStrategyRegistry),
            "Account should have correct strategy registry reference"
        );
    }

    function testFactoryContractStorage() public {
        // Test that factory properly stores immutable values
        assertEq(mamoAccountFactory.mamoBackend(), backend, "Backend should be stored correctly");
        assertEq(
            address(mamoAccountFactory.registry()), address(accountRegistry), "Registry should be stored correctly"
        );
        assertEq(
            address(mamoAccountFactory.mamoStrategyRegistry()),
            address(mamoStrategyRegistry),
            "Strategy registry should be stored correctly"
        );
        assertNotEq(mamoAccountFactory.accountImplementation(), address(0), "Implementation should be stored");
        assertEq(mamoAccountFactory.accountStrategyTypeId(), 2, "Strategy type ID should be stored correctly");
    }

    function testMultipleAccountsHaveDifferentAddresses() public {
        address[] memory users = new address[](5);
        address[] memory accounts = new address[](5);

        // Create multiple users and accounts
        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));

            vm.startPrank(users[i]);
            accounts[i] = mamoAccountFactory.createAccount();
            vm.stopPrank();
        }

        // Verify all accounts have different addresses
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = i + 1; j < 5; j++) {
                assertNotEq(accounts[i], accounts[j], "Accounts should have different addresses");
            }
        }

        // Verify all accounts are properly mapped
        for (uint256 i = 0; i < 5; i++) {
            assertEq(mamoAccountFactory.getAccountForUser(users[i]), accounts[i], "Account should be mapped correctly");
        }
    }
}
