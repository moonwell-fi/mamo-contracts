// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {USDCStrategyFactory} from "@contracts/USDCStrategyFactory.sol";

/**
 * @title USDCStrategyFactoryDeployer
 * @notice Script to deploy the USDCStrategyFactory contract
 */
contract USDCStrategyFactoryDeployer is Script {
    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the USDCStrategyFactory
        deployUSDCStrategyFactory(addresses);

        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deployUSDCStrategyFactory(Addresses addresses) public returns (address) {
        vm.startBroadcast();

        // Get the addresses for the initialization parameters
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address mamoBackend = addresses.getAddress("MAMO_BACKEND");
        address mToken = addresses.getAddress("MOONWELL_USDC");
        address metaMorphoVault = addresses.getAddress("USDC_METAMORPHO_VAULT");
        address usdc = addresses.getAddress("USDC");
        address slippagePriceChecker = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        address strategyImplementation = addresses.getAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL");

        // Define the split parameters (50/50 by default)
        uint256 splitMToken = 5000; // 50% in basis points
        uint256 splitVault = 5000; // 50% in basis points
        uint256 strategyTypeId = 1;

        // Deploy the USDCStrategyFactory
        USDCStrategyFactory factory = new USDCStrategyFactory(
            mamoStrategyRegistry,
            mamoBackend,
            mToken,
            metaMorphoVault,
            usdc,
            slippagePriceChecker,
            strategyImplementation,
            splitMToken,
            splitVault,
            strategyTypeId
        );

        vm.stopBroadcast();

        // Check if the factory address already exists
        string memory factoryName = "USDC_STRATEGY_FACTORY";
        if (addresses.isAddressSet(factoryName)) {
            // Update the existing address
            addresses.changeAddress(factoryName, address(factory), true);
        } else {
            // Add the factory address to the addresses contract
            addresses.addAddress(factoryName, address(factory), true);
        }

        // Log the deployed contract address
        console.log("USDCStrategyFactory deployed at:", address(factory));

        return address(factory);
    }
}
