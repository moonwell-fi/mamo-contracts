// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {DeployConfig} from "./DeployConfig.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";

/**
 * @title DeploySlippagePriceChecker
 * @notice Script to deploy the SlippagePriceChecker contract with UUPS proxy
 * @dev Deploys the SlippagePriceChecker implementation and proxy, then updates the addresses JSON file
 */
contract DeploySlippagePriceChecker is Script {
    /**
     * @notice Deploys the SlippagePriceChecker implementation and proxy
     * @return slippagePriceCheckerProxy The deployed SlippagePriceChecker proxy contract
     */
    function deploySlippagePriceChecker(Addresses addresses, DeployConfig.DeploymentConfig memory config)
        public
        returns (SlippagePriceChecker slippagePriceCheckerProxy)
    {
        vm.startBroadcast();

        // Get the addresses from the addresses contract
        address deployer = addresses.getAddress(config.deployer);

        // Deploy the SlippagePriceChecker implementation
        SlippagePriceChecker implementation = new SlippagePriceChecker();

        // Prepare initialization data for the proxy
        bytes memory initData = abi.encodeWithSelector(SlippagePriceChecker.initialize.selector, deployer);

        // Deploy the proxy with the implementation and initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Cast the proxy to SlippagePriceChecker for easier interaction
        slippagePriceCheckerProxy = SlippagePriceChecker(address(proxy));

        vm.stopBroadcast();

        // Check if the implementation address already exists
        string memory implName = "CHAINLINK_SWAP_CHECKER_IMPLEMENTATION";
        if (addresses.isAddressSet(implName)) {
            // Update the existing address
            addresses.changeAddress(implName, address(implementation), true);
        } else {
            // Add the implementation address to the addresses contract
            addresses.addAddress(implName, address(implementation), true);
        }

        // Check if the proxy address already exists
        string memory proxyName = "CHAINLINK_SWAP_CHECKER_PROXY";
        if (addresses.isAddressSet(proxyName)) {
            // Update the existing address
            addresses.changeAddress(proxyName, address(slippagePriceCheckerProxy), true);
        } else {
            // Add the proxy address to the addresses contract
            addresses.addAddress(proxyName, address(slippagePriceCheckerProxy), true);
        }
    }
}
