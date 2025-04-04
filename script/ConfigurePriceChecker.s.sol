// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

/**
 * @title DeploySlippagePriceChecker
 * @notice Script to deploy the SlippagePriceChecker contract with UUPS proxy
 * @dev Deploys the SlippagePriceChecker implementation and proxy, then updates the addresses JSON file
 */
contract DeploySlippagePriceChecker is Script {
    uint256 public constant DEFAULT_MAX_TIME_PRICE_VALID = 3600; // 1 hour in seconds

    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        configureSlippageForToken(addresses);
    }

    /**
     * @notice Configure price checker for a token
     */
    function configureSlippageForToken(Addresses addresses) public {
        // Deploy the SlippagePriceChecker implementation
        SlippagePriceChecker priceChecker = SlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));

        // Configure WELL token with WELL/USD price feed
        ISlippagePriceChecker.TokenFeedConfiguration[] memory wellConfigs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        wellConfigs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: addresses.getAddress("CHAINLINK_WELL_USD"),
            reverse: false,
            heartbeat: 1 hours
        });

        vm.startBroadcast();

        priceChecker.addTokenConfiguration(
            addresses.getAddress("xWELL_PROXY"), wellConfigs, DEFAULT_MAX_TIME_PRICE_VALID
        );

        vm.stopBroadcast();
    }
}
