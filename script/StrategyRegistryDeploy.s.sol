// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

contract StrategyRegistryDeploy is Script {
    Addresses public addresses;

    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get the addresses for the roles
        address admin = addresses.getAddress("ADMIN");
        address backend = addresses.getAddress("BACKEND");
        address guardian = addresses.getAddress("GUARDIAN");

        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy the strategy registry
        MamoStrategyRegistry registry = deployStrategyRegistry(admin, backend, guardian);

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Add the registry address to the addresses contract
        addresses.addAddress("MAMO_STRATEGY_REGISTRY", address(registry), true);

        // Update the JSON file with the new address
        addresses.updateJson();

        // Log the deployed contract address
        console.log("MamoStrategyRegistry deployed at:", address(registry));

    }

    function deployStrategyRegistry(address admin, address backend, address guardian)
        public
        returns (MamoStrategyRegistry registry)
    {
        // Deploy the MamoStrategyRegistry with the specified roles
        registry = new MamoStrategyRegistry(admin, backend, guardian);
    }
}
