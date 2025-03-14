// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {StrategyRegistryDeploy} from "@script/StrategyRegistryDeploy.s.sol";
import {ERC1967Proxy } from "@contracts/ERC1967Proxy.sol";

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

    function testRegistryDeployment() public {
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
            registry.getImplementationId(mockImplementation),
            strategyTypeId,
            "Implementation should have the correct strategy type ID"
        );

        // Verify the implementation is set as the latest implementation for that strategy type ID
        assertEq(
            registry.getLatestImplementation(strategyTypeId),
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

        // Get the implementation address using our helper function
        address implFromRegistry = getImplementationAddress(address(strategy));
        
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

        // Pause the registry
        vm.startPrank(guardian);
        registry.pause();
        vm.stopPrank();

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Pausable: paused"
        vm.expectRevert("Pausable: paused");

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
        // Deploy a mock strategy
        MockStrategy strategy = new MockStrategy();

        // Create a mock implementation address (not whitelisted)
        address implementation = makeAddr("implementation");

        // Create a user address
        address user = makeAddr("user");

        // Initialize the strategy with the correct roles
        strategy.initialize(user, address(registry), backend);

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
        // Deploy a mock strategy
        MockStrategy strategy = new MockStrategy();

        // Create a mock implementation address and whitelist it
        address implementation = makeAddr("implementation");

        vm.startPrank(backend);
        registry.whitelistImplementation(implementation);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");
        address wrongUser = makeAddr("wrongUser");

        // Initialize the strategy with incorrect owner role
        strategy.initialize(wrongUser, address(registry), backend);

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
        // Deploy a mock strategy
        MockStrategy strategy = new MockStrategy();

        // Create a mock implementation address and whitelist it
        address implementation = makeAddr("implementation");

        vm.startPrank(backend);
        registry.whitelistImplementation(implementation);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");
        address wrongUpgrader = makeAddr("wrongUpgrader");

        // Initialize the strategy with incorrect upgrader role
        strategy.initialize(user, wrongUpgrader, backend);

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
        // Deploy a mock strategy
        MockStrategy strategy = new MockStrategy();

        // Create a mock implementation address and whitelist it
        address implementation = makeAddr("implementation");

        vm.startPrank(backend);
        registry.whitelistImplementation(implementation);
        vm.stopPrank();

        // Create a user address
        address user = makeAddr("user");
        address wrongBackend = makeAddr("wrongBackend");

        // Initialize the strategy with incorrect backend role
        strategy.initialize(user, address(registry), wrongBackend);

        // Switch to the backend role
        vm.startPrank(backend);

        // Expect the call to revert with "Backend role not set correctly"
        vm.expectRevert("Backend role not set correctly");

        // Call the addStrategy function
        registry.addStrategy(user, address(strategy));

        // Stop impersonating the backend
        vm.stopPrank();
    }

    function getImplementationAddress(address proxy) public view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
