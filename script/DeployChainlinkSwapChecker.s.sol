// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {ChainlinkSwapChecker} from "@contracts/ChainlinkSwapChecker.sol";

/**
 * @title DeployChainlinkSwapChecker
 * @notice Script to deploy the ChainlinkSwapChecker contract
 * @dev Deploys the ChainlinkSwapChecker contract and updates the addresses JSON file
 */
contract DeployChainlinkSwapChecker is Script {
    Addresses public addresses;

    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);
        
        // Deploy the ChainlinkSwapChecker
        ChainlinkSwapChecker swapChecker = deployChainlinkSwapChecker(addresses);

        // Update the JSON file with the new address
        addresses.updateJson();
        addresses.printJSONChanges();
    }

    /**
     * @notice Deploys the ChainlinkSwapChecker contract
     * @dev Uses a default slippage of 50 basis points (0.5%)
     * @return swapChecker The deployed ChainlinkSwapChecker contract
     */
    function deployChainlinkSwapChecker(Addresses addresses) public returns (ChainlinkSwapChecker swapChecker) {
        // Default slippage tolerance of 1% (100 basis points)
        uint256 allowedSlippageInBps = 100;
        
        vm.startBroadcast();
        
        // Get the MAMO_MULTISIG address from the addresses contract
        address mamoMultisig = addresses.getAddress("MAMO_MULTISIG");
        
        // Deploy the ChainlinkSwapChecker with the specified slippage and owner
        swapChecker = new ChainlinkSwapChecker(allowedSlippageInBps, mamoMultisig);
        
        vm.stopBroadcast();

        // Add the swapChecker address to the addresses contract
        addresses.addAddress("CHAINLINK_SWAP_CHECKER", address(swapChecker), true);

    }
}
