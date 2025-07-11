// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@fps/addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {console} from "forge-std/console.sol";

contract FixChainlinkCBBTCFeedConfig is MultisigProposal {
    DeployAssetConfig public immutable deployAssetConfigBtc;
    DeployAssetConfig public immutable deployAssetConfigUsdc;

    constructor() {
        setPrimaryForkId(vm.createSelectFork("base"));

        // TODO move four below lines to a generic function as we use all the time
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        deployAssetConfigBtc = new DeployAssetConfig("./config/strategies/cbBTCStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfigBtc));

        deployAssetConfigUsdc = new DeployAssetConfig("./config/strategies/USDCStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfigUsdc));
    }

    function name() public pure override returns (string memory) {
        return "001_FixChainlinkCBBTCFeedConfig";
    }

    function description() public pure override returns (string memory) {
        return "Fix Chainlink CBBTC Feed Config";
    }

    function deploy() public override {
        // deploy the new slippage price checker implementation
        address slippagePriceCheckerImplementation = address(new SlippagePriceChecker());
        addresses.changeAddress("CHAINLINK_SWAP_CHECKER_IMPLEMENTATION", slippagePriceCheckerImplementation, true);
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Get the SlippagePriceChecker proxy address
        address slippagePriceCheckerProxy = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        SlippagePriceChecker priceChecker = SlippagePriceChecker(slippagePriceCheckerProxy);

        address slippagePriceCheckerImplementation = addresses.getAddress("CHAINLINK_SWAP_CHECKER_IMPLEMENTATION");

        // upgrade the slippage price checker proxy
        UUPSUpgradeable(slippagePriceCheckerProxy).upgradeToAndCall(slippagePriceCheckerImplementation, "");

        // Get the configuration
        DeployAssetConfig.Config memory configBtc = deployAssetConfigBtc.getConfig();

        address toBtc = addresses.getAddress(configBtc.token);

        // Process each reward token
        for (uint256 i = 0; i < configBtc.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = configBtc.rewardTokens[i];

            // Get the token address
            address from = addresses.getAddress(rewardToken.token);

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

            // Add the new token configuration
            priceChecker.addTokenConfiguration(from, toBtc, feedConfigs);
        }

        DeployAssetConfig.Config memory configUsdc = deployAssetConfigUsdc.getConfig();
        address toUsdc = addresses.getAddress(configUsdc.token);

        for (uint256 i = 0; i < configUsdc.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = configUsdc.rewardTokens[i];

            address from = addresses.getAddress(rewardToken.token);

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

            // Add the new token configuration
            priceChecker.addTokenConfiguration(from, toUsdc, feedConfigs);
        }
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");

        _simulateActions(multisig);
    }

    function validate() public override {
        // check if the feeds are added correctly
        address slippagePriceCheckerProxy = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        SlippagePriceChecker priceChecker = SlippagePriceChecker(slippagePriceCheckerProxy);

        // check if the feeds are added correctly
        address well = addresses.getAddress("xWELL_PROXY");
        address btc = addresses.getAddress("cbBTC");
        address usdc = addresses.getAddress("USDC");
        address morpho = addresses.getAddress("MORPHO");

        ISlippagePriceChecker.TokenFeedConfiguration[] memory feedConfigsWellBtc =
            priceChecker.tokenPairOracleInformation(well, btc);

        assertEq(feedConfigsWellBtc.length, 2, "WELL > BTC should have 2 configurations");
        assertEq(
            feedConfigsWellBtc[0].chainlinkFeed,
            addresses.getAddress("CHAINLINK_WELL_USD"),
            "First price feed should match"
        );
        assertEq(feedConfigsWellBtc[0].reverse, false, "First reverse flag should match");
        assertEq(
            feedConfigsWellBtc[1].chainlinkFeed,
            addresses.getAddress("CHAINLINK_BTC_USD"),
            "Second price feed should match"
        );
        assertEq(feedConfigsWellBtc[1].reverse, true, "Second reverse flag should match");

        ISlippagePriceChecker.TokenFeedConfiguration[] memory feedConfigsWellUsdc =
            priceChecker.tokenPairOracleInformation(well, usdc);

        assertEq(feedConfigsWellUsdc.length, 1, "WELL > USDC should have 1 configuration");
        assertEq(
            feedConfigsWellUsdc[0].chainlinkFeed,
            addresses.getAddress("CHAINLINK_WELL_USD"),
            "First price feed should match"
        );
        assertEq(feedConfigsWellUsdc[0].reverse, false, "First reverse flag should match");

        ISlippagePriceChecker.TokenFeedConfiguration[] memory feedConfigsMorphoBtc =
            priceChecker.tokenPairOracleInformation(morpho, btc);

        assertEq(feedConfigsMorphoBtc.length, 2, "MORPHO > BTC should have 2 configurations");
        assertEq(
            feedConfigsMorphoBtc[0].chainlinkFeed,
            addresses.getAddress("CHAINLINK_MORPHO_USD"),
            "First price feed should match"
        );
        assertEq(feedConfigsMorphoBtc[0].reverse, false, "First reverse flag should match");
        assertEq(
            feedConfigsMorphoBtc[1].chainlinkFeed,
            addresses.getAddress("CHAINLINK_BTC_USD"),
            "Second price feed should match"
        );
        assertEq(feedConfigsMorphoBtc[1].reverse, true, "Second reverse flag should match");

        ISlippagePriceChecker.TokenFeedConfiguration[] memory feedConfigsMorphoUsdc =
            priceChecker.tokenPairOracleInformation(morpho, usdc);

        assertEq(feedConfigsMorphoUsdc.length, 1, "MORPHO > USDC should have 1 configuration");
        assertEq(
            feedConfigsMorphoUsdc[0].chainlinkFeed,
            addresses.getAddress("CHAINLINK_MORPHO_USD"),
            "First price feed should match"
        );
        assertEq(feedConfigsMorphoUsdc[0].reverse, false, "First reverse flag should match");
    }
}
