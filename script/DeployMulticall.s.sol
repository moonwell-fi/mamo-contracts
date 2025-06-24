// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Multicall} from "@contracts/Multicall.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployMulticall
 * @notice Script to deploy and manage Multicall contract
 */
contract DeployMulticall is Script {
    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID
        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        deploy(addresses);

        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deploy(Addresses addresses) public returns (address) {
        // Get the addresses for the initialization parameters
        address owner = addresses.getAddress("MAMO_COMPOUNDER");

        console.log("Deploying Multicall with owner:", owner);

        // Deploy the Multicall
        Multicall multicall = new Multicall(owner);

        console.log("Multicall deployed at:", address(multicall));

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
