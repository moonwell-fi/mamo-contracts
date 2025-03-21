// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";

/**
 * @title DeploySlippagePriceChecker
 * @notice Script to deploy the SlippagePriceChecker contract with UUPS proxy
 * @dev Deploys the SlippagePriceChecker implementation and proxy, then updates the addresses JSON file
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
     * @notice Deploys the SlippagePriceChecker implementation and proxy
     * @return slippagePriceCheckerProxy The deployed SlippagePriceChecker proxy contract
     */
    function deploySlippagePriceChecker(Addresses addresses)
        public
        returns (SlippagePriceChecker slippagePriceCheckerProxy)
    {
        vm.startBroadcast();

        // Get the MAMO_MULTISIG address from the addresses contract
        address mamoMultisig = addresses.getAddress("MAMO_MULTISIG");

        // Deploy the SlippagePriceChecker implementation
        SlippagePriceChecker implementation = new SlippagePriceChecker();

        // Prepare initialization data for the proxy
        bytes memory initData = abi.encodeWithSelector(SlippagePriceChecker.initialize.selector, mamoMultisig);

        // Deploy the proxy with the implementation and initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Cast the proxy to SlippagePriceChecker for easier interaction
        slippagePriceCheckerProxy = SlippagePriceChecker(address(proxy));

        vm.stopBroadcast();

        // Add the implementation and proxy addresses to the addresses contract
        addresses.addAddress("CHAINLINK_SWAP_CHECKER_IMPLEMENTATION", address(implementation), true);
        addresses.addAddress("CHAINLINK_SWAP_CHECKER_PROXY", address(slippagePriceCheckerProxy), true);
    }
}
