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
        // Deploy the strategy registry
        MamoStrategyRegistry registry = deployStrategyRegistry(addresses);

        // Update the JSON file with the new address
        addresses.updateJson();

        // Log the deployed contract address
        console.log("MamoStrategyRegistry deployed at:", address(registry));
    }

    function deployStrategyRegistry(Addresses addresses)
        public
        returns (MamoStrategyRegistry registry)
    {

        // Get the addresses for the roles
        address admin = addresses.getAddress("MAMO_MULTISIG");
        address backend = addresses.getAddress("MAMO_BACKEND");
        address guardian = addresses.getAddress("MAMO_MULTISIG");

        vm.startBroadcast();
        // Deploy the MamoStrategyRegistry with the specified roles
        registry = new MamoStrategyRegistry(admin, backend, guardian);

        vm.stopBroadcast();

        // Add the registry address to the addresses contract
        addresses.addAddress("MAMO_STRATEGY_REGISTRY", address(registry), true);
    }
}
