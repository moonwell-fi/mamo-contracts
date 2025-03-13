// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Addresses} from "../addresses/Addresses.sol";
import {StrategyRegistryDeploy} from "../script/StrategyRegistryDeploy.s.sol";
import {MamoStrategyRegistry} from "../src/MamoStrategyRegistry.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

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

        // Add the test addresses
        addresses.addAddress("ADMIN", admin, false);
        addresses.addAddress("BACKEND", backend, false);
        addresses.addAddress("GUARDIAN", guardian, false);

        // Deploy the MamoStrategyRegistry using the script
        StrategyRegistryDeploy deployScript = new StrategyRegistryDeploy();

        // Call the deployStrategyRegistry function with the addresses
        registry = deployScript.deployStrategyRegistry(admin, backend, guardian);

        // Add the registry address to the addresses contract
        addresses.addAddress("MAMO_STRATEGY_REGISTRY", address(registry), true);

        console.log("MamoStrategyRegistry deployed at:", address(registry));
    }

    function testRegistryDeployment() public {
        // Test that the registry was deployed correctly
        assertTrue(address(registry) != address(0), "Registry not deployed");

        // Test that the registry has the correct roles
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set correctly");
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), backend), "Backend role not set correctly");
        assertTrue(registry.hasRole(registry.GUARDIAN_ROLE(), guardian), "Guardian role not set correctly");
    }
}
