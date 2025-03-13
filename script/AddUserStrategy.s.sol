// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Addresses} from "../addresses/Addresses.sol";
import {MamoStrategyRegistry} from "../src/MamoStrategyRegistry.sol";

contract AddUserStrategy is Script {
    Addresses public addresses;

    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Add the strategy for a user
        addUserStrategy();
    }

    function addUserStrategy() public {
        // Get the private key for deployment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get the addresses
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address userStrategy = addresses.getAddress("USER_STRATEGY_PROXY");
        address user = addresses.getAddress("USER");

        // Add the strategy for the user
        MamoStrategyRegistry registry = MamoStrategyRegistry(mamoStrategyRegistry);
        registry.addStrategy(user, userStrategy);

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Log the added strategy
        console.log("Strategy added for user");
        console.log("User address:", user);
        console.log("Strategy address:", userStrategy);

        // Get and log all strategies for the user
        address[] memory userStrategies = registry.getUserStrategies(user);
        console.log("Total strategies for user:", userStrategies.length);
        for (uint256 i = 0; i < userStrategies.length; i++) {
            console.log("Strategy", i + 1, ":", userStrategies[i]);
        }
    }
}
