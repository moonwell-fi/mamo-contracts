// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployConfig} from "./DeployConfig.sol";

import {MarketRegistry} from "@contracts/MarketRegistry.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

contract MarketRegistryDeployer is Script {
    function deployMarketRegistry(Addresses addresses, DeployConfig.DeploymentConfig memory config)
        public
        returns (MarketRegistry registry)
    {
        address backend = addresses.getAddress(config.backend);
        address guardian = addresses.getAddress(config.guardian);
        address admin = addresses.getAddress(config.admin);

        vm.startBroadcast();

        registry = new MarketRegistry(admin, backend, guardian);

        vm.stopBroadcast();

        string memory registryName = "MARKET_REGISTRY";
        if (addresses.isAddressSet(registryName)) {
            addresses.changeAddress(registryName, address(registry), true);
        } else {
            addresses.addAddress(registryName, address(registry), true);
        }
    }
}
