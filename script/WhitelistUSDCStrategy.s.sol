// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Addresses} from "../addresses/Addresses.sol";
import {MamoStrategyRegistry} from "../src/MamoStrategyRegistry.sol";

contract WhitelistUSDCStrategy is Script {
    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Whitelist the USDC strategy implementation
        whitelistUSDCStrategy(addresses);
    }

    function whitelistUSDCStrategy(Addresses addresses) public {
        // Start broadcasting transactions
        vm.startBroadcast();

        // Get the addresses
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address usdcStrategyImplementation = addresses.getAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL");

        // Whitelist the implementation in the registry
        MamoStrategyRegistry registry = MamoStrategyRegistry(mamoStrategyRegistry);
        uint256 strategyTypeId = registry.whitelistImplementation(usdcStrategyImplementation, 0);

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Log the whitelisted implementation
        console.log("USDC Strategy implementation whitelisted in the registry");
        console.log("Implementation address:", usdcStrategyImplementation);
        console.log("Strategy type ID:", strategyTypeId);
    }
}
