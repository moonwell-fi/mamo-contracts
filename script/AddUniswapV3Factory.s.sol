// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";

/**
 * @title AddUniswapV3Factory
 * @notice Script to add the Uniswap V3 Factory address to the addresses file
 */
contract AddUniswapV3Factory is Script {
    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 8453; // Base chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Add the Uniswap V3 Factory address
        address uniswapV3Factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

        vm.startBroadcast();

        // Add the address if it doesn't exist, otherwise update it
        if (addresses.isAddressSet("UNISWAP_V3_FACTORY", 8453)) {
            addresses.changeAddress("UNISWAP_V3_FACTORY", uniswapV3Factory, 8453, true);
            console.log("Updated UNISWAP_V3_FACTORY address: %s", uniswapV3Factory);
        } else {
            addresses.addAddress("UNISWAP_V3_FACTORY", uniswapV3Factory, 8453, true);
            console.log("Added UNISWAP_V3_FACTORY address: %s", uniswapV3Factory);
        }

        // Add WETH address for Base
        address weth = 0x4200000000000000000000000000000000000006;
        if (addresses.isAddressSet("WETH", 8453)) {
            addresses.changeAddress("WETH", weth, 8453, true);
            console.log("Updated WETH address: %s", weth);
        } else {
            addresses.addAddress("WETH", weth, 8453, true);
            console.log("Added WETH address: %s", weth);
        }

        vm.stopBroadcast();

        // Update the JSON file
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("Addresses have been updated in the JSON file");
    }
}
