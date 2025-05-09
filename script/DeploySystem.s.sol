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
 * @title DeploySystem
 * @notice Script to deploy the entire Mamo system
 * @dev Reads configuration from JSON files in the deploy/ directory
 */
contract DeploySystem is Script {
    function run() external {
        // Get the environment from command line arguments or use default
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_TESTING"));
        console.log("Environment: %s", StdStyle.yellow(environment));
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
        _configureRewardTokens(addresses, priceChecker, config.getConfig());

        // Step 4: Deploy the USDC strategy implementation
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 4: Deploying USDC strategy implementation...")));
        USDCStrategyImplDeployer usdcStrategyImplDeployer = new USDCStrategyImplDeployer();
        address strategyImpl = usdcStrategyImplDeployer.deployImplementation(addresses);
        console.log("USDC strategy implementation deployed at: %s", StdStyle.yellow(vm.toString(strategyImpl)));

        // Step 5: Whitelist the USDC strategy implementation
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 5: Whitelisting USDC strategy implementation...")));
        uint256 strategyTypeId = _whitelistUSDCStrategy(addresses);
        console.log("%s", StdStyle.italic("USDC strategy implementation whitelisted successfully"));

        // Step 6: Grant admin role to the multisig
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 6: Granting admin role to the multisig...")));

        vm.startBroadcast();
        // transfer registry ownership to the multisig
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), addresses.getAddress("MAMO_MULTISIG"));

        // Step 7: Revoke admin role from the deployer
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 7: Revoking admin role from the deployer...")));

        // revoke admin role from the deployer
        registry.revokeRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender);

        vm.stopBroadcast();

        // Step 8: Deploy the USDCStrategyFactory
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 8: Deploying USDCStrategyFactory...")));
        USDCStrategyFactoryDeployer factoryDeployer = new USDCStrategyFactoryDeployer();
        address factoryAddress =
            factoryDeployer.deployUSDCStrategyFactory(addresses, config.getConfig(), strategyTypeId);
        console.log("USDCStrategyFactory deployed at: %s", StdStyle.yellow(vm.toString(factoryAddress)));

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== DEPLOYMENT COMPLETE ===")));
        console.log("%s", StdStyle.bold(StdStyle.green("System deployment completed successfully!")));

        // Validate the deployment
        console.log("\n%s", StdStyle.bold(StdStyle.green("Validating deployment...")));
        validate(addresses, registry, priceChecker, config.getConfig());
        console.log("%s", StdStyle.bold(StdStyle.green("Validation successful!")));
    }

    /**
     * @notice Validates the deployment to ensure all roles, ownership, and parameters are correctly set
     * @param addresses The addresses contract
     * @param registry The MamoStrategyRegistry contract
     * @param priceChecker The SlippagePriceChecker contract
     * @param deployConfig The deployment configuration
     */
    function validate(
        Addresses addresses,
        MamoStrategyRegistry registry,
        SlippagePriceChecker priceChecker,
        DeployConfig.DeploymentConfig memory deployConfig
    ) public view {
        address admin = addresses.getAddress(deployConfig.admin);
        address deployer = addresses.getAddress(deployConfig.deployer);

        // Validate roles in the registry
        console.log("Validating registry roles...");
        require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin), "admin does not have DEFAULT_ADMIN_ROLE");
        require(!registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer), "Deployer still has DEFAULT_ADMIN_ROLE");

        // Validate ownership of the SlippagePriceChecker
        console.log("Validating SlippagePriceChecker ownership...");
        require(priceChecker.owner() == admin, "SlippagePriceChecker is not owned by admin");

        // Validate reward token configurations
        console.log("Validating reward token configurations...");
        for (uint256 i = 0; i < deployConfig.rewardTokens.length; i++) {
            string memory tokenName = deployConfig.rewardTokens[i].token;
            address token = addresses.getAddress(tokenName);

            // Verify token is configured as a reward token
            require(
                priceChecker.isRewardToken(token),
                string(abi.encodePacked("Token is not configured as a reward token: ", tokenName))
            );

            // Verify max price valid time
            require(
                priceChecker.maxTimePriceValid(token) == deployConfig.maxPriceValidTime,
                string(abi.encodePacked("Incorrect maxPriceValidTime for ", tokenName))
            );

            // Get token oracle information
            ISlippagePriceChecker.TokenFeedConfiguration[] memory feeds = priceChecker.tokenOracleInformation(token);

            // Verify feed configurations exist
            require(feeds.length > 0, string(abi.encodePacked("No feed configurations for ", tokenName)));

            // Verify the first feed configuration (we only add one in _configureRewardTokens)
            address expectedPriceFeed = addresses.getAddress(deployConfig.rewardTokens[i].priceFeed);
            require(
                feeds[0].chainlinkFeed == expectedPriceFeed,
                string(abi.encodePacked("Incorrect price feed for ", tokenName))
            );

            require(
                feeds[0].reverse == deployConfig.rewardTokens[i].reverse,
                string(abi.encodePacked("Incorrect reverse flag for ", tokenName))
            );

            require(
                feeds[0].heartbeat == deployConfig.rewardTokens[i].heartbeat,
                string(abi.encodePacked("Incorrect heartbeat for ", tokenName))
            );
        }

        // Validate USDC strategy implementation is whitelisted
        console.log("Validating USDC strategy implementation...");
        address usdcStrategyImpl = addresses.getAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL");
        require(
            registry.whitelistedImplementations(usdcStrategyImpl), "USDC strategy implementation is not whitelisted"
        );
    }

    /**
     * @notice Helper function to configure reward tokens
     * @param addresses The addresses contract
     * @param priceChecker The SlippagePriceChecker contract
     * @param deployConfig The deployment configuration
     */
    function _configureRewardTokens(
        Addresses addresses,
        SlippagePriceChecker priceChecker,
        DeployConfig.DeploymentConfig memory deployConfig
    ) private {
        // Start a single broadcast for all token configurations
        vm.startBroadcast();

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
            priceChecker.addTokenConfiguration(token, tokenConfigs, deployConfig.maxPriceValidTime);
        }

        // Transfer ownership to the multisig only once after all tokens are configured
        priceChecker.transferOwnership(addresses.getAddress("MAMO_MULTISIG"));

        vm.stopBroadcast();
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
