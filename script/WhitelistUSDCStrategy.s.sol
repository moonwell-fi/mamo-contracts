// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

import {MamoStrategyRegistry} from "../src/MamoStrategyRegistry.sol";
import {Addresses} from "../addresses/Addresses.sol";

contract WhitelistUSDCStrategy is Script {
    Addresses public addresses;

    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID
        
        addresses = new Addresses(addressesFolderPath, chainIds);
        
        // Whitelist the USDC strategy implementation
        whitelistUSDCStrategy();
    }

    function whitelistUSDCStrategy() public {
        // Start broadcasting transactions
        vm.startBroadcast();
        
        // Get the addresses
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address usdcStrategyImplementation = addresses.getAddress("USDC_STRATEGY_IMPLEMENTATION");
        address usdc = addresses.getAddress("USDC");
        address mUSDC = addresses.getAddress("MUSDC");
        address metaMorphoVault = addresses.getAddress("META_MORPHO_VAULT");
        
        // Create the strategy type ID for USDC strategy
        // The strategy type ID is structured as follows:
        // 1. The first element contains the number of addresses in the array (3 in this case)
        // 2. The subsequent elements contain the actual token addresses
        bytes32 strategyTypeId = bytes32(abi.encodePacked(uint8(3), usdc, mUSDC, metaMorphoVault));
        
        // Whitelist the implementation in the registry
        MamoStrategyRegistry registry = MamoStrategyRegistry(mamoStrategyRegistry);
        registry.whitelistImplementation(usdcStrategyImplementation, strategyTypeId);
        
        // Stop broadcasting transactions
        vm.stopBroadcast();
        
        // Log the whitelisted implementation
        console.log("USDC Strategy implementation whitelisted in the registry");
        console.log("Implementation address:", usdcStrategyImplementation);
        console.log("Strategy type ID:", vm.toString(strategyTypeId));
    }
}
