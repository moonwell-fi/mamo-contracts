// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";

/**
 * @title DeploySlippagePriceChecker
 * @notice Script to deploy the SlippagePriceChecker contract
 * @dev Deploys the SlippagePriceChecker contract and updates the addresses JSON file
 */
contract DeploySlippagePriceChecker is Script {
    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        deploySlippagePriceChecker(addresses);

        // Update the JSON file with the new address
        addresses.updateJson();
        addresses.printJSONChanges();
    }

    /**
     * @notice Deploys the SlippagePriceChecker contract
     * @return slippagePriceChecker The deployed SlippagePriceChecker contract
     */
    function deploySlippagePriceChecker(Addresses addresses)
        public
        returns (SlippagePriceChecker slippagePriceChecker)
    {
        vm.startBroadcast();

        // Get the MAMO_MULTISIG address from the addresses contract
        address mamoMultisig = addresses.getAddress("MAMO_MULTISIG");

        // Deploy the SlippagePriceChecker with the owner
        slippagePriceChecker = new SlippagePriceChecker(mamoMultisig);

        vm.stopBroadcast();

        // Add the SlippagePriceChecker address to the addresses contract
        addresses.addAddress("CHAINLINK_SWAP_CHECKER", address(slippagePriceChecker), true);
    }
}
