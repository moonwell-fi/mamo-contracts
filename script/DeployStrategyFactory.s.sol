// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployConfig} from "./DeployConfig.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {StrategyReserves} from "@contracts/StrategyReserves.sol";

/**
 * @title DeployStrategyFactory
 * @notice Script to deploy the StrategyFactory contract
 */
contract DeployStrategyFactory is Script {
    function deployStrategyFactory(Addresses addresses) public returns (address) {
        vm.startBroadcast();

        // Get the USDC address from the addresses contract
        address usdc = addresses.getAddress("USDC");

        // Use the provided owner address
        address owner = addresses.getAddress("MAMO_BACKEND");

        // Deploy the StrategyFactory
        StrategyReserves factory = new StrategyReserves(usdc, owner);

        vm.stopBroadcast();

        // Check if the factory address already exists
        string memory factoryName = "STRATEGY_FACTORY";
        if (addresses.isAddressSet(factoryName)) {
            // Update the existing address
            addresses.changeAddress(factoryName, address(factory), true);
        } else {
            // Add the factory address to the addresses contract
            addresses.addAddress(factoryName, address(factory), true);
        }

        console.log("StrategyFactory deployed at:", address(factory));
        console.log("Owner set to:", owner);
        console.log("USDC token:", usdc);

        return address(factory);
    }

    /**
     * @notice Main entry point for the script
     */
    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the factory
        deployStrategyFactory(addresses);
    }
}
