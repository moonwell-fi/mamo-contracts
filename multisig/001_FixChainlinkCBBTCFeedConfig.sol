// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {MultisigProposal} from "@fps/proposals/MultisigProposal.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {console} from "forge-std/console.sol";

contract FixChainlinkCBBTCFeedConfig is MultisigProposal {
    DeployAssetConfig public immutable deployAssetConfig;

    constructor() {
        setPrimaryForkId(vm.createSelectFork("base"));

        // TODO move four below lines to a generic function as we use all the time
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        deployAssetConfig = new DeployAssetConfig("./config/strategies/cbBTCStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfig));
    }

    function name() public pure override returns (string memory) {
        return "001_FixChainlinkCBBTCFeedConfig";
    }

    function description() public pure override returns (string memory) {
        return "Fix Chainlink CBBTC Feed Config";
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Get the SlippagePriceChecker proxy address
        address slippagePriceCheckerProxy = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        SlippagePriceChecker priceChecker = SlippagePriceChecker(slippagePriceCheckerProxy);

        // Get the configuration
        DeployAssetConfig.Config memory config = deployAssetConfig.getConfig();

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

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");

        _simulateActions(multisig);
    }

    function validate() public override {
        // check if returns the correct well - btc exchange rate
        address well = addresses.getAddress("xWELL_PROXY");
        address btc = addresses.getAddress("cbBTC");
        address chainlinkBTC = addresses.getAddress("CHAINLINK_BTC_USD");
        address chainlinkWell = addresses.getAddress("CHAINLINK_WELL_USD");
    }
}
