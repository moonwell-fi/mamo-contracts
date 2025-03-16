// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {StrategyRegistryDeploy} from "script/StrategyRegistryDeploy.s.sol";
import {USDCStrategyDeployer} from "script/USDCStrategyDeployer.s.sol";

contract MamoStrategyRegistryIntegrationTest is Test {
    MamoStrategyRegistry public registry;
    ERC20MoonwellMorphoStrategy strategy;
    Addresses public addresses;

    function setUp() public {
        // Create test addresses
        address admin = makeAddr("admin");
        address backend = makeAddr("backend");
        address guardian = makeAddr("guardian");

        // Create a new addresses instance for testing
        // We'll create it with an empty array of chainIds to avoid file reading issues
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](0);
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the MamoStrategyRegistry using the script
        StrategyRegistryDeploy deployScript = new StrategyRegistryDeploy();
        
        // Call the run() function to deploy the registry
        deployScript.run();
        
        // Call the deployStrategyRegistry function with the addresses
        registry = deployScript.deployStrategyRegistry(admin, backend, guardian);

        // Test USDC strategy deployment using the deployer script
        USDCStrategyDeployer strategyDeployer = new USDCStrategyDeployer();

        strategy = ERC20MoonwellMorphoStrategy(payable(strategyDeployer.deployUSDCStrategy()));

    }
    

}
