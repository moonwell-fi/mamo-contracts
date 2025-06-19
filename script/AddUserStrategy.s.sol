// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {MamoStrategyRegistry} from "../src/MamoStrategyRegistry.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

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
        vm.startBroadcast();

        // Get the addresses
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address userStrategy = 0x3eFC7C5717627Cc05538B2bd8EbE7C494Bd20D1d;
        address user = 0x10b83c88e88910Cd5293324800d1a6e751004bE5;

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
