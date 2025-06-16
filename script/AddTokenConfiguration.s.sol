// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {DeployAssetConfig} from "./DeployAssetConfig.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

/**
 * @title AddTokenConfiguration
 * @notice Script to add token configurations to the SlippagePriceChecker contract
 * @dev Loads addresses from addresses JSON and configuration from strategy config JSON
 */
contract AddTokenConfiguration is Script, Test {
    /**
     * @notice Adds token configurations to the SlippagePriceChecker
     * @param addresses The addresses contract instance
     * @param assetConfig The asset configuration contract instance
     */
    function addTokenConfiguration(Addresses addresses, DeployAssetConfig assetConfig) public {
        // Get the SlippagePriceChecker proxy address
        address slippagePriceCheckerProxy = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        SlippagePriceChecker priceChecker = SlippagePriceChecker(slippagePriceCheckerProxy);

        // Get the configuration
        DeployAssetConfig.Config memory config = assetConfig.getConfig();

        // Process each reward token
        for (uint256 i = 0; i < config.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = config.rewardTokens[i];

            // Get the token address
            address tokenAddress = addresses.getAddress(rewardToken.token);

            // Convert price feed configurations
            ISlippagePriceChecker.TokenFeedConfiguration[] memory feedConfigs =
                new ISlippagePriceChecker.TokenFeedConfiguration[](rewardToken.priceFeeds.length);

            for (uint256 j = 0; j < rewardToken.priceFeeds.length; j++) {
                DeployAssetConfig.PriceFeedConfig memory priceFeedConfig = rewardToken.priceFeeds[j];

                feedConfigs[j] = ISlippagePriceChecker.TokenFeedConfiguration({
                    chainlinkFeed: addresses.getAddress(priceFeedConfig.priceFeed),
                    reverse: priceFeedConfig.reverse,
                    heartbeat: priceFeedConfig.heartbeat
                });
            }

            console.log("Adding token configuration for:", rewardToken.token);
            console.log("Token address:", tokenAddress);
            console.log("Max time price valid:", rewardToken.maxTimePriceValid);
            console.log("Number of price feeds:", feedConfigs.length);

            // Add the token configuration
            priceChecker.addTokenConfiguration(tokenAddress, feedConfigs, rewardToken.maxTimePriceValid);

            console.log("Successfully added configuration for token:", rewardToken.token);
        }
    }

    /**
     * @notice Main run function for the script
     * @dev Loads addresses and configuration, then adds token configurations
     */
    function run() external {
        // Initialize addresses contract with chain IDs
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 8453; // Base chain ID

        Addresses addresses = new Addresses("addresses", chainIds);

        // Load asset configuration
        DeployAssetConfig assetConfig = new DeployAssetConfig("config/strategies/cbBTCStrategyConfig.json");

        // Add token configurations
        addTokenConfiguration(addresses, assetConfig);

        console.log("Token configuration script completed successfully");
    }
}
