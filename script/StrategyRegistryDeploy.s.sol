// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployConfig} from "./DeployConfig.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

contract StrategyRegistryDeploy is Script {
    function deployStrategyRegistry(Addresses addresses, DeployConfig.DeploymentConfig memory config)
        public
        returns (MamoStrategyRegistry registry)
    {
        // Get the addresses for the roles
        address admin = addresses.getAddress(config.admin);
        address backend = addresses.getAddress(config.backend);
        address guardian = addresses.getAddress(config.guardian);

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
