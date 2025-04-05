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
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_TESTING"));
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
        address strategyImpl = usdcStrategyImplDeployer.deployImplementation(addresses);
        console.log("USDC strategy implementation deployed at: %s", StdStyle.yellow(vm.toString(strategyImpl)));

        // Step 5: Whitelist the USDC strategy implementation
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 5: Whitelisting USDC strategy implementation...")));
        uint256 strategyTypeId = _whitelistUSDCStrategy(addresses);
        console.log("%s", StdStyle.italic("USDC strategy implementation whitelisted successfully"));

        // Step 6: Deploy the USDCStrategyFactory
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 6: Deploying USDCStrategyFactory...")));
        USDCStrategyFactoryDeployer factoryDeployer = new USDCStrategyFactoryDeployer();
        address factoryAddress =
            factoryDeployer.deployUSDCStrategyFactory(addresses, config.getConfig(), strategyTypeId);
        console.log("USDCStrategyFactory deployed at: %s", StdStyle.yellow(vm.toString(factoryAddress)));

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== DEPLOYMENT COMPLETE ===")));
        console.log("%s", StdStyle.bold(StdStyle.green("System deployment completed successfully!")));
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
        for (uint256 i = 0; i < deployConfig.rewardTokens.length; i++) {
            string memory tokenName = deployConfig.rewardTokens[i].token;
            address token = addresses.getAddress(tokenName);
            address priceFeed = addresses.getAddress(deployConfig.rewardTokens[i].priceFeed);

            // Create token configuration
            ISlippagePriceChecker.TokenFeedConfiguration[] memory tokenConfigs =
                new ISlippagePriceChecker.TokenFeedConfiguration[](1);

            tokenConfigs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
                chainlinkFeed: priceFeed,
                reverse: deployConfig.rewardTokens[i].reverse,
                heartbeat: deployConfig.rewardTokens[i].heartbeat
            });

            // Add token configuration
            vm.startBroadcast();
            priceChecker.addTokenConfiguration(token, tokenConfigs, deployConfig.maxPriceValidTime);
            vm.stopBroadcast();
        }
    }

    function _whitelistUSDCStrategy(Addresses addresses) private returns (uint256 strategyTypeId) {
        // Start broadcasting transactions
        vm.startBroadcast();

        // Get the addresses
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address usdcStrategyImplementation = addresses.getAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL");

        // Whitelist the implementation in the registry
        MamoStrategyRegistry registry = MamoStrategyRegistry(mamoStrategyRegistry);
        strategyTypeId = registry.whitelistImplementation(usdcStrategyImplementation, 0);

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
