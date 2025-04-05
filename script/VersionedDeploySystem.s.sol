// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployConfig} from "./DeployConfig.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {Script} from "@forge-std/Script.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {StdStyle} from "@forge-std/StdStyle.sol";
import {Vm} from "@forge-std/Vm.sol";
import {console} from "@forge-std/console.sol";

// Import all the necessary deployment scripts
import {DeploySlippagePriceChecker} from "./DeploySlippagePriceChecker.s.sol";
import {StrategyRegistryDeploy} from "./StrategyRegistryDeploy.s.sol";
import {USDCStrategyFactoryDeployer} from "./USDCStrategyFactoryDeployer.s.sol";
import {USDCStrategyImplDeployer} from "./USDCStrategyImplDeployer.s.sol";

/**
 * @title VersionedDeploySystem
 * @notice Script to deploy the entire Mamo system using version-based configuration
 * @dev Reads configuration from JSON files in the deploy/ directory
 */
contract VersionedDeploySystem is Script {
    function run() external {
        // Get the environment from command line arguments or use default
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_TESTING.json"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== MAMO SYSTEM DEPLOYMENT ===")));
        console.log("%s: %s\n", StdStyle.bold("Environment"), StdStyle.yellow(environment));
        console.log("%s\n", StdStyle.bold("Starting full system deployment..."));

        // Load the addresses and configuration
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);
        DeployConfig config = new DeployConfig(configPath);

        // Log configuration details
        console.log("Deploying version: %s", StdStyle.yellow(config.getVersion()));
        console.log("Network: Chain ID: %s", StdStyle.yellow(vm.toString(config.getChainId())));

        // Step 1: Deploy the MamoStrategyRegistry
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Deploying MamoStrategyRegistry...")));
        StrategyRegistryDeploy strategyRegistryDeploy = new StrategyRegistryDeploy();
        MamoStrategyRegistry registry = strategyRegistryDeploy.deployStrategyRegistry(addresses, config.getConfig());
        console.log("MamoStrategyRegistry deployed at: %s", StdStyle.yellow(vm.toString(address(registry))));

        // Step 2: Deploy the SlippagePriceChecker
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 2: Deploying SlippagePriceChecker...")));
        DeploySlippagePriceChecker deploySlippagePriceChecker = new DeploySlippagePriceChecker();
        SlippagePriceChecker priceChecker =
            deploySlippagePriceChecker.deploySlippagePriceChecker(addresses, config.getConfig());
        console.log("SlippagePriceChecker deployed at: %s", StdStyle.yellow(vm.toString(address(priceChecker))));

        // Step 3: Configure the SlippagePriceChecker for reward tokens
        console.log(
            "\n%s", StdStyle.bold(StdStyle.green("Step 3: Configuring SlippagePriceChecker for reward tokens..."))
        );

        // Configure reward tokens
        _configureRewardTokens(config, addresses, priceChecker, config.getConfig());

        // Step 4: Deploy the USDC strategy implementation
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 4: Deploying USDC strategy implementation...")));
        USDCStrategyImplDeployer usdcStrategyImplDeployer = new USDCStrategyImplDeployer();
        address strategyImpl = usdcStrategyImplDeployer.deployImplementation(addresses, config.getConfig());
        console.log("USDC strategy implementation deployed at: %s", StdStyle.yellow(vm.toString(strategyImpl)));

        // Step 5: Whitelist the USDC strategy implementation
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 5: Whitelisting USDC strategy implementation...")));
        whitelistUSDCStrategy(addresses, config.getConfig());
        console.log("%s", StdStyle.italic("USDC strategy implementation whitelisted successfully"));

        // Step 6: Deploy the USDCStrategyFactory
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 6: Deploying USDCStrategyFactory...")));
        USDCStrategyFactoryDeployer factoryDeployer = new USDCStrategyFactoryDeployer();
        address factoryAddress = factoryDeployer.deployUSDCStrategyFactory(addresses, config.getConfig());
        console.log("USDCStrategyFactory deployed at: %s", StdStyle.yellow(vm.toString(factoryAddress)));

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== DEPLOYMENT COMPLETE ===")));
        console.log("%s", StdStyle.bold(StdStyle.green("System deployment completed successfully!")));
    }

    /**
     * @notice Helper function to parse a boolean from the JSON config
     * @param config The deployment configuration
     * @param key The key to parse
     * @return The boolean value
     */
    function _parseJsonBool(DeployConfig config, string memory key) private view returns (bool) {
        return config.getBool(key);
    }

    /**
     * @notice Helper function to configure reward tokens
     * @param config The deployment configuration
     * @param addresses The addresses contract
     * @param priceChecker The SlippagePriceChecker contract
     */
    function _configureRewardTokens(
        DeployConfig config,
        Addresses addresses,
        SlippagePriceChecker priceChecker,
        DeployConfig.DeploymentConfig memory deployConfig
    ) private {
        // Get the number of reward tokens from the config
        uint256 rewardTokenCount = config.getRewardTokenCount();
        console.log("Configuring %d reward tokens", rewardTokenCount);

        for (uint256 i = 0; i < rewardTokenCount; i++) {
            _configureRewardToken(i, config, addresses, priceChecker, deployConfig);
        }
    }

    /**
     * @notice Helper function to configure a single reward token
     * @param index The index of the reward token in the config
     * @param config The deployment configuration
     * @param addresses The addresses contract
     * @param priceChecker The SlippagePriceChecker contract
     */
    function _configureRewardToken(
        uint256 index,
        DeployConfig config,
        Addresses addresses,
        SlippagePriceChecker priceChecker,
        DeployConfig.DeploymentConfig memory deployConfig
    ) private {
        // Get reward token configuration
        (string memory tokenName, string memory priceFeedName, bool reverse, uint256 heartbeat) =
            config.getRewardToken(index);

        address token = addresses.getAddress(tokenName);
        address priceFeed = addresses.getAddress(priceFeedName);

        console.log("Configuring token: %s", StdStyle.yellow(tokenName));
        console.log("  Price feed: %s", StdStyle.yellow(priceFeedName));
        console.log("  Reverse: %s", StdStyle.yellow(reverse ? "true" : "false"));
        console.log("  Heartbeat: %s seconds", StdStyle.yellow(vm.toString(heartbeat)));

        // Create token configuration
        ISlippagePriceChecker.TokenFeedConfiguration[] memory tokenConfigs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);

        tokenConfigs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: priceFeed,
            reverse: reverse,
            heartbeat: heartbeat
        });

        // Add token configuration
        vm.startBroadcast();
        priceChecker.addTokenConfiguration(token, tokenConfigs, deployConfig.maxPriceValidTime);
        vm.stopBroadcast();

        console.log("Token %s configured successfully", StdStyle.yellow(tokenName));
    }

    function whitelistUSDCStrategy(Addresses addresses, DeployConfig.DeploymentConfig memory config) public {
        // Start broadcasting transactions
        vm.startBroadcast();

        // Get the addresses
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address usdcStrategyImplementation = addresses.getAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL");

        // Whitelist the implementation in the registry
        MamoStrategyRegistry registry = MamoStrategyRegistry(mamoStrategyRegistry);
        uint256 strategyTypeId = registry.whitelistImplementation(usdcStrategyImplementation, 0);

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
