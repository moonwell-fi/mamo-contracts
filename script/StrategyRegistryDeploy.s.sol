// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

import {MamoStrategyRegistry} from "../src/MamoStrategyRegistry.sol";
import {Addresses} from "../addresses/Addresses.sol";

contract StrategyRegistryDeploy is Script {
    Addresses public addresses;

    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID
        
        addresses = new Addresses(addressesFolderPath, chainIds);

         // Start broadcasting transactions
        vm.startBroadcast(); 

        // Deploy the strategy registry
        deployStrategyRegistry();

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }

    function deployStrategyRegistry() public {
        // Get the addresses for the roles
        address admin = addresses.getAddress("ADMIN");
        address backend = addresses.getAddress("BACKEND");
        address guardian = addresses.getAddress("GUARDIAN");
        
        // Deploy the MamoStrategyRegistry with the specified roles
        MamoStrategyRegistry registry = new MamoStrategyRegistry(
            admin,
            backend,
            guardian
        );
        
       
        // Log the deployed contract address
        console.log("MamoStrategyRegistry deployed at:", address(registry));
    }
}
