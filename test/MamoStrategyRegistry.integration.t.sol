// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {StrategyRegistryDeploy} from "@script/StrategyRegistryDeploy.s.sol";

// Mock strategy contract for testing
contract MockStrategy is Initializable, AccessControlEnumerable, UUPSUpgradeable {
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    function initialize(address owner, address upgrader, address backend) external initializer {
        _grantRole(OWNER_ROLE, owner);
        _grantRole(UPGRADER_ROLE, upgrader);
        _grantRole(BACKEND_ROLE, backend);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {}
}

contract MamoStrategyRegistryIntegrationTest is Test {
    MamoStrategyRegistry public registry;
    Addresses public addresses;

    address public admin;
    address public backend;
    address public guardian;

    function setUp() public {
        // Create test addresses
        admin = makeAddr("admin");
        backend = makeAddr("backend");
        guardian = makeAddr("guardian");

        // Create a new addresses instance for testing
        // We'll create it with an empty array of chainIds to avoid file reading issues
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](0);
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the MamoStrategyRegistry using the script
        StrategyRegistryDeploy deployScript = new StrategyRegistryDeploy();

        // Call the deployStrategyRegistry function with the addresses
        registry = deployScript.deployStrategyRegistry(admin, backend, guardian);
    }

    function testRegistryDeployment() view public {
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

        // Switch to the backend role to call the whitelistImplementation function
        vm.startPrank(backend);

        // Expect the ImplementationWhitelisted event to be emitted
        // We check that the registry is the event emitter by passing its address
        vm.expectEmit(address(registry));
        // We emit the event we expect to see with the correct parameters
        emit MamoStrategyRegistry.ImplementationWhitelisted(mockImplementation, 1);

        // Call the whitelistImplementation function and capture the returned strategy type ID
        uint256 strategyTypeId = registry.whitelistImplementation(mockImplementation);

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

        // Verify the strategy type ID is 1 (first implementation)
        assertEq(strategyTypeId, 1, "First strategy type ID should be 1");

        // Test whitelisting a second implementation
        address mockImplementation2 = makeAddr("mockImplementation2");

        vm.startPrank(backend);

        // Expect the ImplementationWhitelisted event to be emitted for the second implementation
        vm.expectEmit(address(registry));
        emit MamoStrategyRegistry.ImplementationWhitelisted(mockImplementation2, 2);

        uint256 strategyTypeId2 = registry.whitelistImplementation(mockImplementation2);
        vm.stopPrank();

        // Verify the second implementation has ID 2
        assertEq(strategyTypeId2, 2, "Second strategy type ID should be 2");

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
        bytes32 role = registry.BACKEND_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonBackend, role));

        // Call the whitelistImplementation function
        registry.whitelistImplementation(mockImplementation);

        // Stop impersonating the non-backend address
        vm.stopPrank();
    }

    function testRevertIfImplementationAddressIsZero() public {
        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Invalid implementation address"
        vm.expectRevert("Invalid implementation address");

        // Call the whitelistImplementation function with the zero address
        registry.whitelistImplementation(address(0));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function testRevertIfImplementationIsAlreadyWhitelisted() public {
        // Create a mock implementation address
        address mockImplementation = makeAddr("mockImplementation");

        // Switch to the backend role
        vm.startPrank(backend);

        // First call should succeed
        registry.whitelistImplementation(mockImplementation);

        // Verify the implementation is now whitelisted
        assertTrue(registry.whitelistedImplementations(mockImplementation), "Implementation should be whitelisted");

        // Expect the second call to revert with "Implementation already whitelisted"
        vm.expectRevert("Implementation already whitelisted");

        // Call the whitelistImplementation function again with the same implementation
        registry.whitelistImplementation(mockImplementation);

        // Stop impersonating the backend
        vm.stopPrank();
    }

    // ==================== TESTS FOR addStrategy METHOD ====================

    function testAddStrategySucceed() public {
        // Deploy a mock strategy
        MockStrategy strategyImpl = new MockStrategy();

        vm.startPrank(backend);
        registry.whitelistImplementation(address(strategyImpl));

        vm.stopPrank();
        // Create a user address
        address user = makeAddr("user");

        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), backend))
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

        vm.startPrank(backend);
        registry.whitelistImplementation(implementation);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");

        // Initialize the strategy with the correct roles
        strategy.initialize(user, address(registry), backend);

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
        vm.startPrank(backend);
        registry.whitelistImplementation(address(strategyImpl));
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), backend))
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

        vm.startPrank(backend);
        registry.whitelistImplementation(implementation);
        vm.stopPrank();

        // Create a user address (zero address)
        address user = address(0);
        address someUser = makeAddr("someUser");

        // Initialize the strategy with the correct roles
        strategy.initialize(someUser, address(registry), backend);

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

    function testRevertIfAddStrategyAlreadyAddedForUser() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(backend);
        registry.whitelistImplementation(address(strategyImpl));
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), backend))
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
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), backend))
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

    function testRevertIfAddStrategyWithIncorrectOwnerRole() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(backend);
        registry.whitelistImplementation(address(strategyImpl));
        vm.stopPrank();

        // Create a user address and a wrong user address
        address user = makeAddr("user");
        address wrongUser = makeAddr("wrongUser");

        // Create a proxy with the mock strategy implementation but with wrong owner role
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (wrongUser, address(registry), backend))
        );

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Owner role not set correctly"
        vm.expectRevert("Owner role not set correctly");

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function testRevertIfAddStrategyWithIncorrectUpgraderRole() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(backend);
        registry.whitelistImplementation(address(strategyImpl));
        vm.stopPrank();

        // Create a user address and a wrong upgrader address
        address user = makeAddr("user");
        address wrongUpgrader = makeAddr("wrongUpgrader");

        // Create a proxy with the mock strategy implementation but with wrong upgrader role
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, wrongUpgrader, backend))
        );

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Upgrader role not set correctly"
        vm.expectRevert("Upgrader role not set correctly");

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function testRevertIfAddStrategyWithIncorrectBackendRole() public {
        // Deploy a mock strategy implementation
        MockStrategy strategyImpl = new MockStrategy();

        // Whitelist the implementation
        vm.startPrank(backend);
        registry.whitelistImplementation(address(strategyImpl));
        vm.stopPrank();

        // Create a user address and a wrong backend address
        address user = makeAddr("user");
        address wrongBackend = makeAddr("wrongBackend");

        // Create a proxy with the mock strategy implementation but with wrong backend role
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user, address(registry), wrongBackend))
        );

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Backend role not set correctly"
        vm.expectRevert("Backend role not set correctly");

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    // ==================== TESTS FOR GETTER FUNCTIONS ====================

    function testNextStrategyTypeId() public {
        // Verify the initial value of nextStrategyTypeId is 1
        assertEq(registry.nextStrategyTypeId(), 1, "nextStrategyTypeId should be initialized to 1");

        // Whitelist an implementation and verify nextStrategyTypeId increments
        address mockImplementation = makeAddr("mockImplementation");
        vm.startPrank(backend);
        registry.whitelistImplementation(mockImplementation);
        vm.stopPrank();

        // Verify nextStrategyTypeId is now 2
        assertEq(registry.nextStrategyTypeId(), 2, "nextStrategyTypeId should be incremented to 2");

        // Whitelist another implementation and verify nextStrategyTypeId increments again
        address mockImplementation2 = makeAddr("mockImplementation2");
        vm.startPrank(backend);
        registry.whitelistImplementation(mockImplementation2);
        vm.stopPrank();

        // Verify nextStrategyTypeId is now 3
        assertEq(registry.nextStrategyTypeId(), 3, "nextStrategyTypeId should be incremented to 3");
    }

    function testImplementationToId() public {
        // Create a mock implementation address
        address mockImplementation = makeAddr("mockImplementation");

        // Whitelist the implementation
        vm.startPrank(backend);
        uint256 strategyTypeId = registry.whitelistImplementation(mockImplementation);
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
        vm.startPrank(backend);
        uint256 strategyTypeId1 = registry.whitelistImplementation(mockImplementation1);
        uint256 strategyTypeId2 = registry.whitelistImplementation(mockImplementation2);
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
        vm.startPrank(backend);
        registry.whitelistImplementation(address(strategyImpl1));
        registry.whitelistImplementation(address(strategyImpl2));
        vm.stopPrank();

        // Create user addresses
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Create proxies with the mock strategy implementations
        ERC1967Proxy strategy1 = new ERC1967Proxy(
            address(strategyImpl1), abi.encodeCall(MockStrategy.initialize, (user1, address(registry), backend))
        );
        ERC1967Proxy strategy2 = new ERC1967Proxy(
            address(strategyImpl2), abi.encodeCall(MockStrategy.initialize, (user1, address(registry), backend))
        );
        ERC1967Proxy strategy3 = new ERC1967Proxy(
            address(strategyImpl1), abi.encodeCall(MockStrategy.initialize, (user2, address(registry), backend))
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
        vm.startPrank(backend);
        registry.whitelistImplementation(address(strategyImpl));
        vm.stopPrank();

        // Create user addresses
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Create a proxy with the mock strategy implementation
        ERC1967Proxy strategy = new ERC1967Proxy(
            address(strategyImpl), abi.encodeCall(MockStrategy.initialize, (user1, address(registry), backend))
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

    // TODO add onlyGuardian checks
    // TODO add withdrawn ERC20 tests
}
