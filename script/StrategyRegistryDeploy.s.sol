// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

contract StrategyRegistryDeploy is Script {
    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        deployStrategyRegistry(addresses);

        // Update the JSON file with the new address
        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deployStrategyRegistry(Addresses addresses) public returns (MamoStrategyRegistry registry) {
        // Get the addresses for the roles
        address admin = addresses.getAddress("TESTING_EOA");
        address backend = addresses.getAddress("TESTING_EOA");
        address guardian = addresses.getAddress("TESTING_EOA");

        vm.startBroadcast();
        // Deploy the MamoStrategyRegistry with the specified roles
        registry = new MamoStrategyRegistry(admin, backend, guardian);

        vm.stopBroadcast();

        // Check if the address already exists
        string memory registryName = "MAMO_STRATEGY_REGISTRY";
        if (addresses.isAddressSet(registryName)) {
            // Update the existing address
            addresses.changeAddress(registryName, address(registry), true);
        } else {
            // Add the registry address to the addresses contract
            addresses.addAddress(registryName, address(registry), true);
        }
    }
}
