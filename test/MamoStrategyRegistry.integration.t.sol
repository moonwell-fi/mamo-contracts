// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockFailingERC20} from "./MockFailingERC20.sol";

import {BaseStrategy} from "@contracts/BaseStrategy.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {DeployConfig} from "@script/DeployConfig.sol";
import {StrategyRegistryDeploy} from "@script/StrategyRegistryDeploy.s.sol";
// Mock proxy that returns address(0) for implementation

contract MockZeroImplProxy {
    // Mock implementation of getImplementation that returns address(0)
    function getImplementation() external pure returns (address) {
        return address(0);
    }
}

// Mock strategy contract for testing
contract MockStrategy is BaseStrategy {
    function initialize(address _owner, address upgrader, uint256 _strategyTypeId) external initializer {
        // Set state variables
        __BaseStrategy_init(upgrader, _strategyTypeId, _owner);
    }
}

contract MamoStrategyRegistryIntegrationTest is Test {
    MamoStrategyRegistry public registry;
    Addresses public addresses;

    address public admin;
    address public backend;
    address public guardian;

    function setUp() public {
        // Create a new addresses instance for testing
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get the environment from command line arguments or use default
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_TESTING"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));

        DeployConfig config = new DeployConfig(configPath);

        // Get the addresses for the roles
        admin = addresses.getAddress(config.getConfig().admin);
        backend = addresses.getAddress(config.getConfig().backend);
        guardian = addresses.getAddress(config.getConfig().guardian);

        // if (!addresses.isAddressSet("MAMO_STRATEGY_REGISTRY")) {
        // Deploy the MamoStrategyRegistry using the script
        StrategyRegistryDeploy deployScript = new StrategyRegistryDeploy();

        // Call the deployStrategyRegistry function with the addresses
        registry = deployScript.deployStrategyRegistry(addresses, config.getConfig());
        // } else {
        //     registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        // }
    }

    function testRegistryDeployment() public view {
        // Test that the registry was deployed correctly
        assertTrue(address(registry) != address(0), "Registry not deployed");

        // Test that the registry has the correct roles
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set correctly");
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), backend), "Backend role not set correctly");
        assertTrue(registry.hasRole(registry.GUARDIAN_ROLE(), guardian), "Guardian role not set correctly");
    }

    function testWhitelisImplementationSucceed() public {
        // Create a mock implementation address
        address mockImplementation = makeAddr("mockImplementation");

        // Verify the implementation is not already whitelisted
        assertFalse(
            registry.whitelistedImplementations(mockImplementation),
            "Implementation should not be whitelisted initially"
        );

        uint256 nextId = registry.nextStrategyTypeId();

        // Switch to the admin role to call the whitelistImplementation function
        vm.startPrank(admin);

        // Expect the ImplementationWhitelisted event to be emitted
        // We check that the registry is the event emitter by passing its address
        vm.expectEmit(address(registry));
        // We emit the event we expect to see with the correct parameters
        emit MamoStrategyRegistry.ImplementationWhitelisted(mockImplementation, nextId);

        // Call the whitelistImplementation function and capture the returned strategy type ID
        uint256 strategyTypeId = registry.whitelistImplementation(mockImplementation, 0);

        // Stop impersonating the backend
        vm.stopPrank();

        // Verify the implementation is now whitelisted
        assertTrue(registry.whitelistedImplementations(mockImplementation), "Implementation should be whitelisted");

        // Verify the implementation has been assigned the correct strategy type ID
        assertEq(
            registry.implementationToId(mockImplementation),
            strategyTypeId,
            "Implementation should have the correct strategy type ID"
        );

        // Verify the implementation is set as the latest implementation for that strategy type ID
        assertEq(
            registry.latestImplementationById(strategyTypeId),
            mockImplementation,
            "Implementation should be set as the latest for its strategy type ID"
        );

        // Test whitelisting a second implementation
        address mockImplementation2 = makeAddr("mockImplementation2");

        vm.startPrank(admin);

        // Expect the ImplementationWhitelisted event to be emitted for the second implementation
        vm.expectEmit(address(registry));
        emit MamoStrategyRegistry.ImplementationWhitelisted(mockImplementation2, ++nextId);

        registry.whitelistImplementation(mockImplementation2, 0);
        vm.stopPrank();

        // Verify both implementations are whitelisted
        assertTrue(
            registry.whitelistedImplementations(mockImplementation), "First implementation should still be whitelisted"
        );
        assertTrue(
            registry.whitelistedImplementations(mockImplementation2), "Second implementation should be whitelisted"
        );
    }

    function testRevertIfNonBackendCallWhitelistImplemention() public {
        // Create a mock implementation address
        address mockImplementation = makeAddr("mockImplementation");

        // Create a non-backend address
        address nonBackend = makeAddr("nonBackend");

        // Verify the non-backend address doesn't have the BACKEND_ROLE
        assertFalse(registry.hasRole(registry.BACKEND_ROLE(), nonBackend), "Non-backend should not have BACKEND_ROLE");

        // Switch to the non-backend address
        vm.startPrank(nonBackend);

        // Expect the call to revert with AccessControlUnauthorizedAccount error
        bytes32 role = registry.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonBackend, role));

        // Call the whitelistImplementation function
        registry.whitelistImplementation(mockImplementation, 0);

        // Stop impersonating the non-backend address
        vm.stopPrank();
    }

    function testRevertIfImplementationAddressIsZero() public {
        vm.startPrank(admin);

        // Expect the call to revert with "Invalid implementation address"
        vm.expectRevert("Invalid implementation address");

        // Call the whitelistImplementation function with the zero address
        registry.whitelistImplementation(address(0), 0);

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function testRevertIfImplementationIsAlreadyWhitelisted() public {
        // Create a mock implementation address
        address mockImplementation = makeAddr("mockImplementation");

        // Switch to the admin role
        vm.startPrank(admin);

        // First call should succeed
        registry.whitelistImplementation(mockImplementation, 0);

        // Verify the implementation is now whitelisted
        assertTrue(registry.whitelistedImplementations(mockImplementation), "Implementation should be whitelisted");

        // Expect the second call to revert with "Implementation already whitelisted"
        vm.expectRevert("Implementation already whitelisted");

        // Call the whitelistImplementation function again with the same implementation
        registry.whitelistImplementation(mockImplementation, 0);

        // Stop impersonating the backend
        vm.stopPrank();
    }

    // ==================== TESTS FOR addStrategy METHOD ====================

    function testAddStrategySucceed() public {
        // Deploy a mock strategy
        MockStrategy strategyImpl = new MockStrategy();

        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");

        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), strategyTypeId))
        );

        // Switch to the backend role to call addStrategy
        vm.startPrank(backend);

        // Expect the StrategyAdded event to be emitted
        vm.expectEmit(address(registry));
        emit MamoStrategyRegistry.StrategyAdded(user, address(strategy), address(strategyImpl));

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();

        // Verify the strategy was added for the user
        address[] memory userStrategies = registry.getUserStrategies(user);
        assertEq(userStrategies.length, 1, "User should have 1 strategy");
        assertEq(userStrategies[0], address(strategy), "Strategy address should match");

        // Verify isUserStrategy returns true
        assertTrue(registry.isUserStrategy(user, address(strategy)), "isUserStrategy should return true");
    }

    function testRevertIfNonBackendCallAddStrategy() public {
        // Deploy a mock strategy
        MockStrategy strategy = new MockStrategy();

        // Create a mock implementation address and whitelist it
        address implementation = makeAddr("implementation");

        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(implementation, 0);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");

        // Initialize the strategy with the correct roles
        strategy.initialize(user, address(registry), strategyTypeId);

        // Create a non-backend address
        address nonBackend = makeAddr("nonBackend");

        // Switch to the non-backend address
        vm.startPrank(nonBackend);

        // Expect the call to revert with AccessControlUnauthorizedAccount error
        bytes32 role = registry.BACKEND_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonBackend, role));

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the non-backend address
        vm.stopPrank();
    }

    function testRevertIfAddStrategyWhenPaused() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), strategyTypeId))
        );

        // Pause the registry
        vm.startPrank(guardian);
        registry.pause();
        vm.stopPrank();

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with EnforcedPause
        vm.expectRevert();

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function testRevertIfAddStrategyWithZeroUserAddress() public {
        // Deploy a mock strategy
        MockStrategy strategy = new MockStrategy();

        // Create a mock implementation address and whitelist it
        address implementation = makeAddr("implementation");

        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(implementation, 0);
        vm.stopPrank();

        // Create a user address (zero address)
        address user = address(0);
        address someUser = makeAddr("someUser");

        // Initialize the strategy with the correct roles
        strategy.initialize(someUser, address(registry), strategyTypeId);

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Invalid user address"
        vm.expectRevert("Invalid user address");

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function testRevertIfAddStrategyWithZeroStrategyAddress() public {
        // Create a user address
        address user = makeAddr("user");

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Invalid strategy address"
        vm.expectRevert("Invalid strategy address");

        // Call the addStrategy function with zero strategy address
        registry.addStrategy(user, address(0));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function testRevertIfAddStrategyWithImplAddressZero() public {
        // Create a mock proxy that returns address(0) for implementation
        MockZeroImplProxy mockProxy = new MockZeroImplProxy();

        // Create a user address
        address user = makeAddr("user");

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Invalid implementation"
        vm.expectRevert("Invalid implementation");

        // Call the addStrategy function with the mock proxy
        registry.addStrategy(user, address(mockProxy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function testRevertIfAddStrategyAlreadyAddedForUser() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), strategyTypeId))
        );

        // Switch to the backend role
        vm.startPrank(backend);

        // First call should succeed
        registry.addStrategy(user, address(strategy));

        // Expect the second call to revert with "Strategy already added for user"
        vm.expectRevert("Strategy already added for user");

        // Call the addStrategy function again with the same strategy
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function testRevertIfAddStrategyWithNonWhitelistedImplementation() public {
        // Deploy a mock strategy implementation (not whitelisted)
        MockStrategy strategyImpl = new MockStrategy();

        // Create a user address
        address user = makeAddr("user");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl),
            abi.encodeCall(MockStrategy.initialize, (user, address(registry), 0)) // This case is testing non-whitelisted impl
        );

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Implementation not whitelisted"
        vm.expectRevert("Implementation not whitelisted");

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    // Since the MockStrategy no longer uses roles, we need to update these tests
    // The registry still checks that the strategy is properly initialized

    function testRevertIfAddStrategyWithIncorrectRegistry() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");

        // Create a wrong registry address
        address wrongRegistry = makeAddr("wrongRegistry");

        // Create a proxy with the mock strategy implementation but with wrong registry
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, wrongRegistry, strategyTypeId))
        );

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Strategy registry not set correctly"
        // The registry checks that the strategy has the correct registry address
        vm.expectRevert("Strategy registry not set correctly");

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    // ==================== TESTS FOR GETTER FUNCTIONS ====================

    function testNextStrategyTypeId() public {
        uint256 next = registry.nextStrategyTypeId();

        // Whitelist an implementation and verify nextStrategyTypeId increments
        address mockImplementation = makeAddr("mockImplementation");
        vm.startPrank(admin);
        uint256 assignedId = registry.whitelistImplementation(mockImplementation, 0);
        vm.stopPrank();

        // Verify nextStrategyTypeId is now 2
        assertEq(registry.nextStrategyTypeId(), next + 1, "nextStrategyTypeId should be incremented by 1");
        assertEq(assignedId, next, "assigned id should be next");

        // Whitelist another implementation and verify nextStrategyTypeId increments again
        address mockImplementation2 = makeAddr("mockImplementation2");
        vm.startPrank(admin);
        registry.whitelistImplementation(mockImplementation2, 0);
        vm.stopPrank();

        // Verify nextStrategyTypeId is now 3
        assertEq(registry.nextStrategyTypeId(), next + 2, "nextStrategyTypeId should be incremented by 2");
    }

    function testImplementationToId() public {
        // Create a mock implementation address
        address mockImplementation = makeAddr("mockImplementation");

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(mockImplementation, 0);
        vm.stopPrank();

        // Verify implementationToId returns the correct ID
        assertEq(
            registry.implementationToId(mockImplementation),
            strategyTypeId,
            "implementationToId should return the correct strategy type ID"
        );

        // Verify implementationToId returns 0 for non-whitelisted implementation
        address nonWhitelistedImpl = makeAddr("nonWhitelistedImpl");
        assertEq(
            registry.implementationToId(nonWhitelistedImpl),
            0,
            "implementationToId should return 0 for non-whitelisted implementation"
        );
    }

    function testLatestImplementationById() public {
        // Create mock implementation addresses
        address mockImplementation1 = makeAddr("mockImplementation1");
        address mockImplementation2 = makeAddr("mockImplementation2");

        // Whitelist the implementations
        vm.startPrank(admin);
        uint256 strategyTypeId1 = registry.whitelistImplementation(mockImplementation1, 0);
        uint256 strategyTypeId2 = registry.whitelistImplementation(mockImplementation2, 0);
        vm.stopPrank();

        // Verify latestImplementationById returns the correct implementation for each strategy type ID
        assertEq(
            registry.latestImplementationById(strategyTypeId1),
            mockImplementation1,
            "latestImplementationById should return the correct implementation for strategy type ID 1"
        );
        assertEq(
            registry.latestImplementationById(strategyTypeId2),
            mockImplementation2,
            "latestImplementationById should return the correct implementation for strategy type ID 2"
        );

        // Verify latestImplementationById returns address(0) for non-existent strategy type ID
        uint256 nonExistentId = 999;
        assertEq(
            registry.latestImplementationById(nonExistentId),
            address(0),
            "latestImplementationById should return address(0) for non-existent strategy type ID"
        );
    }

    function testGetUserStrategies() public {
        // Deploy mock strategy implementations
        MockStrategy strategyImpl1 = new MockStrategy();
        MockStrategy strategyImpl2 = new MockStrategy();

        // Whitelist the implementations
        vm.startPrank(admin);
        uint256 strategyTypeId1 = registry.whitelistImplementation(address(strategyImpl1), 0);
        uint256 strategyTypeId2 = registry.whitelistImplementation(address(strategyImpl2), 0);
        vm.stopPrank();

        // Create user addresses
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Create proxies with the mock strategy implementations
        ERC1967Proxy strategy1 = new ERC1967Proxy(
            address(strategyImpl1), abi.encodeCall(MockStrategy.initialize, (user1, address(registry), strategyTypeId1))
        );
        ERC1967Proxy strategy2 = new ERC1967Proxy(
            address(strategyImpl2), abi.encodeCall(MockStrategy.initialize, (user1, address(registry), strategyTypeId2))
        );
        ERC1967Proxy strategy3 = new ERC1967Proxy(
            address(strategyImpl2), abi.encodeCall(MockStrategy.initialize, (user2, address(registry), strategyTypeId2))
        );

        // Add strategies for users
        vm.startPrank(backend);
        registry.addStrategy(user1, address(strategy1));
        registry.addStrategy(user1, address(strategy2));
        registry.addStrategy(user2, address(strategy3));
        vm.stopPrank();

        // Verify getUserStrategies returns the correct strategies for user1
        address[] memory user1Strategies = registry.getUserStrategies(user1);
        assertEq(user1Strategies.length, 2, "User1 should have 2 strategies");
        assertTrue(
            user1Strategies[0] == address(strategy1) || user1Strategies[1] == address(strategy1),
            "User1 strategies should include strategy1"
        );
        assertTrue(
            user1Strategies[0] == address(strategy2) || user1Strategies[1] == address(strategy2),
            "User1 strategies should include strategy2"
        );

        // Verify getUserStrategies returns the correct strategies for user2
        address[] memory user2Strategies = registry.getUserStrategies(user2);
        assertEq(user2Strategies.length, 1, "User2 should have 1 strategy");
        assertEq(user2Strategies[0], address(strategy3), "User2 strategies should include strategy3");

        // Verify getUserStrategies returns an empty array for a user with no strategies
        address userWithNoStrategies = makeAddr("userWithNoStrategies");
        address[] memory noStrategies = registry.getUserStrategies(userWithNoStrategies);
        assertEq(noStrategies.length, 0, "User with no strategies should have an empty array");
    }

    function testIsUserStrategy() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create user addresses
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user1, address(registry), strategyTypeId))
        );

        // Add the strategy for user1
        vm.startPrank(backend);
        registry.addStrategy(user1, address(strategy));
        vm.stopPrank();

        // Verify isUserStrategy returns true for user1 and the strategy
        assertTrue(
            registry.isUserStrategy(user1, address(strategy)),
            "isUserStrategy should return true for user1 and the strategy"
        );

        // Verify isUserStrategy returns false for user2 and the strategy
        assertFalse(
            registry.isUserStrategy(user2, address(strategy)),
            "isUserStrategy should return false for user2 and the strategy"
        );

        // Verify isUserStrategy returns false for user1 and a non-existent strategy
        address nonExistentStrategy = makeAddr("nonExistentStrategy");
        assertFalse(
            registry.isUserStrategy(user1, nonExistentStrategy),
            "isUserStrategy should return false for user1 and a non-existent strategy"
        );
    }

    function getImplementationAddress(address proxy) public view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }

    // ==================== TESTS FOR GUARDIAN ROLE FUNCTIONS ====================

    function testPauseSucceed() public {
        // Verify the registry is not paused initially
        assertFalse(registry.paused(), "Registry should not be paused initially");

        // Switch to the guardian role
        vm.startPrank(guardian);

        // Call the pause function
        registry.pause();

        // Stop impersonating the guardian
        vm.stopPrank();

        // Verify the registry is now paused
        assertTrue(registry.paused(), "Registry should be paused");
    }

    function testUnpauseSucceed() public {
        // First pause the registry
        vm.startPrank(guardian);
        registry.pause();
        vm.stopPrank();

        // Verify the registry is paused
        assertTrue(registry.paused(), "Registry should be paused");

        // Switch to the guardian role again
        vm.startPrank(guardian);

        // Call the unpause function
        registry.unpause();

        // Stop impersonating the guardian
        vm.stopPrank();

        // Verify the registry is now unpaused
        assertFalse(registry.paused(), "Registry should not be paused");
    }

    function testRevertIfNonGuardianCallPause() public {
        // Create a non-guardian address
        address nonGuardian = makeAddr("nonGuardian");

        // Verify the non-guardian address doesn't have the GUARDIAN_ROLE
        assertFalse(
            registry.hasRole(registry.GUARDIAN_ROLE(), nonGuardian), "Non-guardian should not have GUARDIAN_ROLE"
        );

        // Switch to the non-guardian address
        vm.startPrank(nonGuardian);

        // Expect the call to revert with AccessControlUnauthorizedAccount error
        bytes32 role = registry.GUARDIAN_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonGuardian, role));

        // Call the pause function
        registry.pause();

        // Stop impersonating the non-guardian address
        vm.stopPrank();
    }

    function testRevertIfNonGuardianCallUnpause() public {
        // First pause the registry
        vm.startPrank(guardian);
        registry.pause();
        vm.stopPrank();

        // Create a non-guardian address
        address nonGuardian = makeAddr("nonGuardian");

        // Verify the non-guardian address doesn't have the GUARDIAN_ROLE
        assertFalse(
            registry.hasRole(registry.GUARDIAN_ROLE(), nonGuardian), "Non-guardian should not have GUARDIAN_ROLE"
        );

        // Switch to the non-guardian address
        vm.startPrank(nonGuardian);

        // Expect the call to revert with AccessControlUnauthorizedAccount error
        bytes32 role = registry.GUARDIAN_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonGuardian, role));

        // Call the unpause function
        registry.unpause();

        // Stop impersonating the non-guardian address
        vm.stopPrank();
    }

    function testRevertIfPauseWhenAlreadyPaused() public {
        // First pause the registry
        vm.startPrank(guardian);
        registry.pause();

        // Expect the call to revert
        vm.expectRevert();

        // Call the pause function again
        registry.pause();

        // Stop impersonating the guardian
        vm.stopPrank();
    }

    function testRevertIfUnpauseWhenNotPaused() public {
        // Verify the registry is not paused initially
        assertFalse(registry.paused(), "Registry should not be paused initially");

        // Switch to the guardian role
        vm.startPrank(guardian);

        // Expect the call to revert
        vm.expectRevert();

        // Call the unpause function
        registry.unpause();

        // Stop impersonating the guardian
        vm.stopPrank();
    }

    // ==================== TESTS FOR ERC20 RECOVERY FUNCTIONS ====================

    function testRecoverERC20Succeed() public {
        // Create a mock ERC20 token
        MockERC20 token = new MockERC20("Mock Token", "MTK");

        // Mint some tokens to the registry
        uint256 amount = 1000 * 10 ** 18;
        token.mint(address(registry), amount);

        // Verify the registry has the tokens
        assertEq(token.balanceOf(address(registry)), amount, "Registry should have the tokens");

        // Create a recipient address
        address recipient = makeAddr("recipient");

        // Switch to the admin role
        vm.startPrank(admin);

        // Call the recoverERC20 function
        registry.recoverERC20(address(token), recipient, amount);

        // Stop impersonating the admin
        vm.stopPrank();

        // Verify the tokens were transferred to the recipient
        assertEq(token.balanceOf(address(registry)), 0, "Registry should have no tokens left");
        assertEq(token.balanceOf(recipient), amount, "Recipient should have received the tokens");
    }

    function testRevertIfNonAdminCallRecoverERC20() public {
        // Create a mock ERC20 token
        MockERC20 token = new MockERC20("Mock Token", "MTK");

        // Mint some tokens to the registry
        uint256 amount = 1000 * 10 ** 18;
        token.mint(address(registry), amount);

        // Create a recipient address
        address recipient = makeAddr("recipient");

        // Create a non-admin address
        address nonAdmin = makeAddr("nonAdmin");

        // Verify the non-admin address doesn't have the DEFAULT_ADMIN_ROLE
        assertFalse(
            registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), nonAdmin), "Non-admin should not have DEFAULT_ADMIN_ROLE"
        );

        // Switch to the non-admin address
        vm.startPrank(nonAdmin);

        // Expect the call to revert with AccessControlUnauthorizedAccount error
        bytes32 role = registry.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonAdmin, role));

        // Call the recoverERC20 function
        registry.recoverERC20(address(token), recipient, amount);

        // Stop impersonating the non-admin address
        vm.stopPrank();
    }

    function testRevertIfRecoverERC20WithZeroAddress() public {
        // Create a mock ERC20 token
        MockERC20 token = new MockERC20("Mock Token", "MTK");

        // Mint some tokens to the registry
        uint256 amount = 1000 * 10 ** 18;
        token.mint(address(registry), amount);

        // Switch to the admin role
        vm.startPrank(admin);

        // Expect the call to revert with "Cannot send to zero address"
        vm.expectRevert("Cannot send to zero address");

        // Call the recoverERC20 function with zero address as recipient
        registry.recoverERC20(address(token), address(0), amount);

        // Stop impersonating the admin
        vm.stopPrank();
    }

    function testRevertIfRecoverERC20WithZeroAmount() public {
        // Create a mock ERC20 token
        MockERC20 token = new MockERC20("Mock Token", "MTK");

        // Create a recipient address
        address recipient = makeAddr("recipient");

        // Switch to the admin role
        vm.startPrank(admin);

        // Expect the call to revert with "Amount must be greater than 0"
        vm.expectRevert("Amount must be greater than 0");

        // Call the recoverERC20 function with zero amount
        registry.recoverERC20(address(token), recipient, 0);

        // Stop impersonating the admin
        vm.stopPrank();
    }

    function testRevertIfRecoverERC20TransferFails() public {
        // Deploy the failing token
        MockFailingERC20 failingToken = new MockFailingERC20();

        // Set some balance for the registry in the failing token
        uint256 amount = 1000 * 10 ** 18; // 1000 tokens
        failingToken.setBalance(address(registry), amount);

        // Verify the registry has the tokens
        assertEq(failingToken.balanceOf(address(registry)), amount, "Registry should have the failing tokens");

        // Create a recipient address
        address recipient = makeAddr("recipient");

        // Admin attempts to recover the tokens - should fail
        vm.startPrank(admin);
        vm.expectRevert("Transfer failed");
        registry.recoverERC20(address(failingToken), recipient, amount);
        vm.stopPrank();

        // Verify the tokens remain in the registry
        assertEq(failingToken.balanceOf(address(registry)), amount, "Registry should still have the tokens");
    }

    // ==================== TESTS FOR upgradeStrategy METHOD ====================

    function testOwnerCanUpgrade() public {
        // 1. Deploy a first implementation and whitelist it
        MockStrategy strategyImpl = new MockStrategy();

        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // 2. Deploy a strategy for a user using that implementation
        address user = makeAddr("user");

        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), strategyTypeId))
        );

        // Add the strategy to the registry
        vm.startPrank(backend);
        registry.addStrategy(user, address(strategy));
        vm.stopPrank();

        // Verify the strategy was added for the user
        assertTrue(registry.isUserStrategy(user, address(strategy)), "Strategy should be added for user");

        // Get the current implementation address
        address oldImplementation = getImplementationAddress(address(strategy));
        assertEq(oldImplementation, address(strategyImpl), "Initial implementation should match");

        // 3. Deploy a new implementation
        MockStrategy newStrategyImpl = new MockStrategy();

        // 4. Whitelist the new implementation using the same strategy ID
        vm.startPrank(admin);
        registry.whitelistImplementation(address(newStrategyImpl), strategyTypeId);
        vm.stopPrank();

        // Verify the new implementation is now the latest for this strategy type
        assertEq(
            registry.latestImplementationById(strategyTypeId),
            address(newStrategyImpl),
            "New implementation should be set as latest"
        );

        // 5. Make the owner call to upgrade the strategy
        vm.startPrank(user);

        // Expect the StrategyImplementationUpdated event to be emitted
        vm.expectEmit(address(registry));
        emit MamoStrategyRegistry.StrategyImplementationUpdated(
            address(strategy), address(strategyImpl), address(newStrategyImpl)
        );

        // Call the upgradeStrategy function
        registry.upgradeStrategy(address(strategy), address(newStrategyImpl));
        vm.stopPrank();

        // Verify the implementation was updated
        address newImplementation = getImplementationAddress(address(strategy));
        assertEq(newImplementation, address(newStrategyImpl), "Implementation should be updated to the new one");
    }

    function testRevertIfNonOwnerCallUpgradeStrategy() public {
        // 1. Deploy a first implementation and whitelist it
        MockStrategy strategyImpl = new MockStrategy();

        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // 2. Deploy a strategy for user1 using that implementation
        address user1 = makeAddr("user1");

        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user1, address(registry), strategyTypeId))
        );

        // Add the strategy to the registry for user1
        vm.startPrank(backend);
        registry.addStrategy(user1, address(strategy));
        vm.stopPrank();

        // Verify the strategy was added for user1
        assertTrue(registry.isUserStrategy(user1, address(strategy)), "Strategy should be added for user1");

        // 3. Deploy a new implementation
        MockStrategy newStrategyImpl = new MockStrategy();

        // 4. Whitelist the new implementation using the same strategy ID
        vm.startPrank(admin);
        registry.whitelistImplementation(address(newStrategyImpl), strategyTypeId);
        vm.stopPrank();

        // 5. Create a different user (non-owner of the strategy)
        address user2 = makeAddr("user2");

        // Verify user2 is not the owner of the strategy
        assertFalse(registry.isUserStrategy(user2, address(strategy)), "User2 should not be the owner of the strategy");

        // 6. Try to upgrade the strategy as user2 (non-owner)
        vm.startPrank(user2);

        // Expect the call to revert with "Caller is not the owner of the strategy"
        vm.expectRevert("Caller is not the owner of the strategy");

        // Call the upgradeStrategy function
        registry.upgradeStrategy(address(strategy), address(newStrategyImpl));
        vm.stopPrank();
    }

    function testRevertIfUpgradeToSameImplementation() public {
        // 1. Deploy an implementation and whitelist it
        MockStrategy strategyImpl = new MockStrategy();

        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // 2. Deploy a strategy for a user using that implementation
        address user = makeAddr("user");

        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), strategyTypeId))
        );

        // Add the strategy to the registry
        vm.startPrank(backend);
        registry.addStrategy(user, address(strategy));
        vm.stopPrank();

        // Verify the current implementation
        address currentImplementation = getImplementationAddress(address(strategy));
        assertEq(currentImplementation, address(strategyImpl), "Initial implementation should match");

        // 3. Try to upgrade to the same implementation
        vm.startPrank(user);

        // Expect the call to revert with "Already using implementation"
        vm.expectRevert("Already using implementation");

        // Call the upgradeStrategy function with the same implementation
        registry.upgradeStrategy(address(strategy), address(strategyImpl));
        vm.stopPrank();
    }

    function testRevertIfUpgradeToNonLatestImplementation() public {
        // 1. Deploy a first implementation and whitelist it
        MockStrategy strategyImpl = new MockStrategy();

        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // 2. Deploy a strategy for a user using that implementation
        address user = makeAddr("user");

        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), strategyTypeId))
        );

        // 3. Deploy a new implementation and whitelist it (becomes latest)
        MockStrategy newStrategyImpl = new MockStrategy();

        vm.startPrank(admin);
        registry.whitelistImplementation(address(newStrategyImpl), strategyTypeId);
        vm.stopPrank();

        // Verify the latest implementation
        assertEq(
            registry.latestImplementationById(strategyTypeId),
            address(newStrategyImpl),
            "Latest implementation should be the newest one"
        );

        // Expect the call to revert with "Not latest implementation"
        vm.expectRevert("Not latest implementation");

        // Try to add strategy using newStrategyImpl (which is not the latest)
        vm.prank(backend);
        registry.addStrategy(user, address(strategy));
        vm.stopPrank();
    }

    function testStrategyOwnerIsSetCorrectly() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), strategyTypeId))
        );

        // Add strategy for user
        vm.startPrank(backend);
        registry.addStrategy(user, address(strategy));
        vm.stopPrank();

        // Verify isUserStrategy matches the owner mapping
        assertTrue(registry.isUserStrategy(user, address(strategy)), "isUserStrategy should return true for owner");
        assertFalse(
            registry.isUserStrategy(makeAddr("notOwner"), address(strategy)),
            "isUserStrategy should return false for non-owner"
        );
    }

    // ==================== TESTS FOR updateStrategyOwner METHOD ====================

    function testUpdateStrategyOwnerSucceed() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create user addresses
        address originalOwner = makeAddr("originalOwner");
        address newOwner = makeAddr("newOwner");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl),
            abi.encodeCall(MockStrategy.initialize, (originalOwner, address(registry), strategyTypeId))
        );

        // Add strategy for the original owner
        vm.startPrank(backend);
        registry.addStrategy(originalOwner, address(strategy));
        vm.stopPrank();

        // Verify the strategy is owned by the original owner
        assertTrue(
            registry.isUserStrategy(originalOwner, address(strategy)), "Strategy should be owned by the original owner"
        );
        assertFalse(
            registry.isUserStrategy(newOwner, address(strategy)), "Strategy should not be owned by the new owner yet"
        );

        // Call updateStrategyOwner as if it was called by the strategy
        vm.startPrank(address(strategy));

        // Expect the StrategyOwnerUpdated event to be emitted
        vm.expectEmit(address(registry));
        emit MamoStrategyRegistry.StrategyOwnerUpdated(address(strategy), originalOwner, newOwner);
        registry.updateStrategyOwner(newOwner);
        vm.stopPrank();

        // Verify the ownership was updated in the registry
        assertFalse(
            registry.isUserStrategy(originalOwner, address(strategy)),
            "Strategy should no longer be owned by the original owner"
        );
        assertTrue(
            registry.isUserStrategy(newOwner, address(strategy)), "Strategy should now be owned by the new owner"
        );
    }

    function testRevertIfNonStrategyCallsUpdateStrategyOwner() public {
        // Create user addresses
        address newOwner = makeAddr("newOwner");
        address nonStrategy = makeAddr("nonStrategy");

        // Call updateStrategyOwner from a non-strategy address
        vm.prank(nonStrategy);
        vm.expectRevert();
        registry.updateStrategyOwner(newOwner);
    }

    function testRevertIfUpdateStrategyOwnerWithZeroAddress() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create user address
        address originalOwner = makeAddr("originalOwner");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl),
            abi.encodeCall(MockStrategy.initialize, (originalOwner, address(registry), strategyTypeId))
        );

        // Add strategy for the original owner
        vm.startPrank(backend);
        registry.addStrategy(originalOwner, address(strategy));
        vm.stopPrank();

        // Call updateStrategyOwner with zero address
        vm.prank(address(strategy));
        vm.expectRevert();
        registry.updateStrategyOwner(address(0));
    }

    function testRevertIfUpdateStrategyOwnerWhenNotRegistered() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create user addresses
        address originalOwner = makeAddr("originalOwner");
        address newOwner = makeAddr("newOwner");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl),
            abi.encodeCall(MockStrategy.initialize, (originalOwner, address(registry), strategyTypeId))
        );

        // Call updateStrategyOwner
        vm.prank(address(strategy));
        vm.expectRevert();
        registry.updateStrategyOwner(newOwner);
    }

    function testRevertIfUpdateStrategyOwnerWhenPaused() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(admin);
        uint256 strategyTypeId = registry.whitelistImplementation(address(strategyImpl), 0);
        vm.stopPrank();

        // Create user addresses
        address originalOwner = makeAddr("originalOwner");
        address newOwner = makeAddr("newOwner");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl),
            abi.encodeCall(MockStrategy.initialize, (originalOwner, address(registry), strategyTypeId))
        );

        // Add strategy for the original owner
        vm.startPrank(backend);
        registry.addStrategy(originalOwner, address(strategy));
        vm.stopPrank();

        // Pause the registry
        vm.prank(guardian);
        registry.pause();

        // Call updateStrategyOwner when registry is paused
        vm.prank(address(strategy));
        vm.expectRevert();
        registry.updateStrategyOwner(newOwner);
    }
}
