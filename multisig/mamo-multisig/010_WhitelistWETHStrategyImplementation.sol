// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoMultiMarketStrategy} from "@contracts/MamoMultiMarketStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {StrategyFactory} from "@contracts/StrategyFactory.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {StrategyFactoryDeployer} from "@script/StrategyFactoryDeployer.s.sol";

/**
 * @title WhitelistWETHStrategyImplementation
 * @notice Multisig proposal to whitelist a new strategy implementation for WETH accounts.
 *         The new implementation includes receive() function that wraps any received ETH to WETH
 * @dev This script will deploy a new MamoMultiMarketStrategy implementation and whitelist it
 *      for strategy type ID 4, which is used for WETH strategy.
 */
contract WhitelistWETHStrategyImplementation is MultisigProposal {
    uint256 public immutable strategyTypeId;
    DeployAssetConfig public immutable deployAssetConfigWeth;
    StrategyFactoryDeployer public immutable strategyFactoryDeployer;
    string public strategyImplementation;

    constructor() {
        // Load asset configurations for WETH strategy
        deployAssetConfigWeth = new DeployAssetConfig("./config/strategies/WETHStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfigWeth));

        // Initialize deployer contracts
        strategyFactoryDeployer = new StrategyFactoryDeployer();
        vm.makePersistent(address(strategyFactoryDeployer));

        strategyImplementation = deployAssetConfigWeth.getConfig().strategyImplementation;
        strategyTypeId = deployAssetConfigWeth.getConfig().strategyParams.strategyTypeId;
    }

    function run() public override {
        _initalizeAddresses();

        if (DO_DEPLOY) {
            deploy();
            //addresses.updateJson();
            addresses.printJSONChanges();
        }

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
        if (DO_UPDATE_ADDRESS_JSON) addresses.updateJson();
    }

    function name() public pure override returns (string memory) {
        return "010_WhitelistETHAccountImplementation";
    }

    function description() public pure override returns (string memory) {
        return
        "Deploy and whitelist new MamoMultiMarketStrategy implementation for token type 4, with support for WETH";
    }

    function deploy() public override {
        if (addresses.isAddressSet(strategyImplementation)) {
            return;
        }

        // Deploy new strategy implementation
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        vm.startBroadcast(deployer);

        address newImplementation = address(new MamoMultiMarketStrategy());
        vm.stopBroadcast();

        addresses.addAddress(strategyImplementation, newImplementation, true);

        // Deploy WETH strategy factory
        strategyFactoryDeployer.deployStrategyFactory(addresses, deployAssetConfigWeth.getConfig(), deployer);
    }

    function preBuildMock() public view override {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Make sure the nextStrategyTypeId() matches the config
        assertEq(registry.nextStrategyTypeId(), strategyTypeId);

        // Make sure that the strategy type id does not have an implementation
        assertEq(registry.latestImplementationById(strategyTypeId), address(0));
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Get the strategy registry
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Get the new implementation address
        address newImplementation = addresses.getAddress(strategyImplementation);

        // Whitelist the new implementation for strategy type
        // This will update latestImplementationById to point to the new implementation
        registry.whitelistImplementation(newImplementation, strategyTypeId);

        // give the backend role to the new factories
        registry.grantRole(registry.BACKEND_ROLE(), addresses.getAddress("WETH_STRATEGY_FACTORY"));

        // Configure reward tokens in SlippagePriceChecker
        _configureRewardTokens();
    }

    function _configureRewardTokens() internal {
        // Get the SlippagePriceChecker proxy address
        address slippagePriceCheckerProxy = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        SlippagePriceChecker priceChecker = SlippagePriceChecker(slippagePriceCheckerProxy);

        // Get the configuration
        DeployAssetConfig.Config memory configWeth = deployAssetConfigWeth.getConfig();

        // Get the target token (WETH)
        address toWeth = addresses.getAddress(configWeth.token);

        // Process each reward token
        for (uint256 i = 0; i < configWeth.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = configWeth.rewardTokens[i];

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

            // Add the token configuration for reward token -> WETH
            priceChecker.addTokenConfiguration(from, toWeth, feedConfigs);

            // Set the max time price valid
            priceChecker.setMaxTimePriceValid(from, rewardToken.maxTimePriceValid);
        }
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");

        _simulateActions(multisig);
    }

    function validate() public view override {
        // Get addresses
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        address newImplementation = addresses.getAddress(strategyImplementation);

        // Validate that the new implementation is whitelisted
        assertTrue(registry.whitelistedImplementations(newImplementation), "New implementation should be whitelisted");

        // Validate that the new implementation is registered for strategy type
        assertEq(
            registry.implementationToId(newImplementation),
            strategyTypeId,
            "Implementation should have correct strategy type ID"
        );

        // Validate that strategy type now points to the new implementation
        assertEq(
            registry.latestImplementationById(strategyTypeId),
            newImplementation,
            "Latest implementation for type should be updated"
        );

        // Validate that the new factories have the backend role
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("WETH_STRATEGY_FACTORY")));

        // Validate reward token configurations
        _validateRewardTokens();

        assertEq(
            StrategyFactory(addresses.getAddress("WETH_STRATEGY_FACTORY")).strategyTypeId(),
            strategyTypeId
        );

        // Validate factory storage variables against config
        _validateFactoryConfig();
    }

    function _validateFactoryConfig() internal view {
        StrategyFactory factory = StrategyFactory(addresses.getAddress("WETH_STRATEGY_FACTORY"));
        DeployAssetConfig.Config memory config = deployAssetConfigWeth.getConfig();

        // Validate strategy parameters from config
        assertEq(
            factory.splitMToken(),
            config.strategyParams.splitMToken,
            "Factory splitMToken should match config"
        );

        assertEq(
            factory.splitVault(),
            config.strategyParams.splitVault,
            "Factory splitVault should match config"
        );

        assertEq(
            factory.hookGasLimit(),
            config.strategyParams.hookGasLimit,
            "Factory hookGasLimit should match config"
        );

        assertEq(
            factory.allowedSlippageInBps(),
            config.strategyParams.allowedSlippageInBps,
            "Factory allowedSlippageInBps should match config"
        );

        assertEq(
            factory.compoundFee(),
            config.strategyParams.compoundFee,
            "Factory compoundFee should match config"
        );

        assertEq(
            factory.strategyTypeId(),
            config.strategyParams.strategyTypeId,
            "Factory strategyTypeId should match config"
        );

        // Validate addresses
        assertEq(
            factory.mamoStrategyRegistry(),
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            "Factory mamoStrategyRegistry should match registry address"
        );

        assertEq(
            factory.mamoBackend(),
            addresses.getAddress("MAMO_BACKEND"),
            "Factory mamoBackend should match backend address"
        );

        assertEq(
            factory.mToken(),
            addresses.getAddress(config.moonwellMarket),
            "Factory mToken should match configured moonwell market"
        );

        assertEq(
            factory.metaMorphoVault(),
            addresses.getAddress(config.metamorphoVault),
            "Factory metaMorphoVault should match configured vault"
        );

        assertEq(
            factory.token(),
            addresses.getAddress(config.token),
            "Factory token should match configured token"
        );

        assertEq(
            factory.slippagePriceChecker(),
            addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"),
            "Factory slippagePriceChecker should match price checker proxy"
        );

        assertEq(
            factory.strategyImplementation(),
            addresses.getAddress(config.strategyImplementation),
            "Factory strategyImplementation should match configured implementation"
        );

        assertEq(
            factory.feeRecipient(),
            addresses.getAddress("MAMO_MULTISIG"),
            "Factory feeRecipient should be MAMO_MULTISIG"
        );

        // Validate reward tokens (hardcoded to xWELL_PROXY and MORPHO in StrategyFactoryDeployer)
        assertEq(
            factory.rewardTokens(0),
            addresses.getAddress("xWELL_PROXY"),
            "Factory reward token 0 should be xWELL_PROXY"
        );

        assertEq(
            factory.rewardTokens(1),
            addresses.getAddress("MORPHO"),
            "Factory reward token 1 should be MORPHO"
        );
    }

    function _validateRewardTokens() internal view {
        // Get the SlippagePriceChecker proxy
        SlippagePriceChecker priceChecker = SlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));

        // Get the configuration
        DeployAssetConfig.Config memory configWeth = deployAssetConfigWeth.getConfig();
        address toWeth = addresses.getAddress(configWeth.token);

        // Validate each reward token configuration
        for (uint256 i = 0; i < configWeth.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = configWeth.rewardTokens[i];
            address from = addresses.getAddress(rewardToken.token);

            // Check that the reward token is configured
            assertTrue(
                priceChecker.isTokenPairConfigured(from, toWeth),
                string(abi.encodePacked(rewardToken.token, " -> WETH should be configured"))
            );

            // Check max time price valid
            assertEq(
                priceChecker.maxTimePriceValid(from),
                rewardToken.maxTimePriceValid,
                string(abi.encodePacked("Incorrect maxTimePriceValid for ", rewardToken.token))
            );

            // Get and validate token pair oracle information
            ISlippagePriceChecker.TokenFeedConfiguration[] memory feedConfigs =
                priceChecker.tokenPairOracleInformation(from, toWeth);

            // Validate the number of price feeds matches configuration
            assertEq(
                feedConfigs.length,
                rewardToken.priceFeeds.length,
                string(
                    abi.encodePacked(
                        rewardToken.token, " -> WETH should have ", vm.toString(rewardToken.priceFeeds.length), " feeds"
                    )
                )
            );

            // Validate each price feed configuration
            for (uint256 j = 0; j < rewardToken.priceFeeds.length; j++) {
                DeployAssetConfig.PriceFeedConfig memory expectedFeed = rewardToken.priceFeeds[j];

                assertEq(
                    feedConfigs[j].chainlinkFeed,
                    addresses.getAddress(expectedFeed.priceFeed),
                    string(abi.encodePacked("Incorrect price feed ", vm.toString(j), " for ", rewardToken.token))
                );

                assertEq(
                    feedConfigs[j].reverse,
                    expectedFeed.reverse,
                    string(abi.encodePacked("Incorrect reverse flag ", vm.toString(j), " for ", rewardToken.token))
                );

                assertEq(
                    feedConfigs[j].heartbeat,
                    expectedFeed.heartbeat,
                    string(abi.encodePacked("Incorrect heartbeat ", vm.toString(j), " for ", rewardToken.token))
                );
            }
        }
    }

    function _initalizeAddresses() internal {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }
}
