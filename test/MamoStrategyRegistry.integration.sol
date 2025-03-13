// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {StrategyRegistryDeploy} from "@script/StrategyRegistryDeploy.s.sol";

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
        assertFalse(registry.whitelistedImplementations(mockImplementation), "Implementation should not be whitelisted initially");
        
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
        assertEq(registry.getImplementationId(mockImplementation), strategyTypeId, "Implementation should have the correct strategy type ID");
        
        // Verify the implementation is set as the latest implementation for that strategy type ID
        assertEq(registry.getLatestImplementation(strategyTypeId), mockImplementation, "Implementation should be set as the latest for its strategy type ID");
        
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
        assertTrue(registry.whitelistedImplementations(mockImplementation), "First implementation should still be whitelisted");
        assertTrue(registry.whitelistedImplementations(mockImplementation2), "Second implementation should be whitelisted");
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
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                nonBackend,
                role
            )
        );
        
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
}
