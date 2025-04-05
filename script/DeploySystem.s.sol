// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";

// Import all the necessary deployment scripts
import {AddUserStrategy} from "./AddUserStrategy.s.sol";
import {DeploySlippagePriceChecker as ConfigurePriceChecker} from "./ConfigurePriceChecker.s.sol";
import {DeploySlippagePriceChecker} from "./DeploySlippagePriceChecker.s.sol";
import {StrategyRegistryDeploy} from "./StrategyRegistryDeploy.s.sol";

import {USDCStrategyFactoryDeployer} from "./USDCStrategyFactoryDeployer.s.sol";
import {USDCStrategyImplDeployer} from "./USDCStrategyImplDeployer.s.sol";
import {WhitelistUSDCStrategy} from "./WhitelistUSDCStrategy.s.sol";

/**
 * @title DeploySystem
 * @notice Script to deploy the entire Mamo system in one go
 * @dev Calls all the necessary deployment scripts in the correct order
 */
contract DeploySystem is Script {
    function run() external {
        console.log("Starting full system deployment...");

        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Step 1: Deploy the MamoStrategyRegistry
        console.log("Step 1: Deploying MamoStrategyRegistry...");
        StrategyRegistryDeploy strategyRegistryDeploy = new StrategyRegistryDeploy();
        MamoStrategyRegistry registry = strategyRegistryDeploy.deployStrategyRegistry(addresses);
        console.log("MamoStrategyRegistry deployed at:", address(registry));

        // Step 2: Deploy the SlippagePriceChecker
        console.log("Step 2: Deploying SlippagePriceChecker...");
        DeploySlippagePriceChecker deploySlippagePriceChecker = new DeploySlippagePriceChecker();
        SlippagePriceChecker priceChecker = deploySlippagePriceChecker.deploySlippagePriceChecker(addresses);
        console.log("SlippagePriceChecker deployed at:", address(priceChecker));

        // Step 3: Configure the SlippagePriceChecker
        console.log("Step 3: Configuring SlippagePriceChecker...");
        ConfigurePriceChecker configurePriceChecker = new ConfigurePriceChecker();
        configurePriceChecker.configureSlippageForToken(addresses);
        console.log("SlippagePriceChecker configured successfully");

        // Create instances of the deployment scripts
        WhitelistUSDCStrategy whitelistUSDCStrategy = new WhitelistUSDCStrategy();
        USDCStrategyImplDeployer usdcStrategyImplDeployer = new USDCStrategyImplDeployer();

        // Step 4: Deploy the USDC strategy implementation
        console.log("Step 4: Deploying USDC strategy implementation...");
        address strategyImpl = usdcStrategyImplDeployer.deployImplementation(addresses);
        console.log("USDC strategy implementation deployed at:", strategyImpl);

        // Step 5: Whitelist the USDC strategy implementation
        console.log("Step 5: Whitelisting USDC strategy implementation...");
        whitelistUSDCStrategy.whitelistUSDCStrategy(addresses);
        console.log("USDC strategy implementation whitelisted successfully");

        // Step 6: Deploy the USDCStrategyFactory
        console.log("Step 6: Deploying USDCStrategyFactory...");
        USDCStrategyFactoryDeployer factoryDeployer = new USDCStrategyFactoryDeployer();
        address factoryAddress = factoryDeployer.deployUSDCStrategyFactory(addresses);
        console.log("USDCStrategyFactory deployed at:", factoryAddress);

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("System deployment completed successfully!");
    }
}
