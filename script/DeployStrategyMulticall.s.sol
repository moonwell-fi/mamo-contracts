// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployConfig} from "./DeployConfig.sol";

import {StrategyMulticall} from "@contracts/StrategyMulticall.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployStrategyMulticall
 * @notice Script to deploy and manage StrategyMulticall contract
 */
contract DeployStrategyMulticall is Script {
    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID
        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        deployStrategyMulticall(addresses);

        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deployStrategyMulticall(Addresses addresses) public returns (address) {
        // Get the addresses for the initialization parameters
        address owner = addresses.getAddress("MAMO_BACKEND");

        console.log("Deploying StrategyMulticall with owner:", owner);

        // Deploy the StrategyMulticall
        StrategyMulticall multicall = new StrategyMulticall(owner);

        console.log("StrategyMulticall deployed at:", address(multicall));

        // Check if the multicall address already exists
        string memory multicallName = "STRATEGY_MULTICALL";
        if (addresses.isAddressSet(multicallName)) {
            // Update the existing address
            addresses.changeAddress(multicallName, address(multicall), true);
            console.log("Updated existing STRATEGY_MULTICALL address");
        } else {
            // Add the multicall address to the addresses contract
            addresses.addAddress(multicallName, address(multicall), true);
            console.log("Added new STRATEGY_MULTICALL address");
        }

        return address(multicall);
    }
}
