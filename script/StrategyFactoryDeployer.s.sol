// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployAssetConfig} from "./DeployAssetConfig.sol";
import {DeployConfig} from "./DeployConfig.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {StrategyFactory} from "@contracts/StrategyFactory.sol";

/**
 * @title StrategyFactoryDeployer
 * @notice Script to deploy the StrategyFactory contract
 */
contract StrategyFactoryDeployer is Script {
    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID
        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        string memory assetConfigPath = "config/strategies/cbBTCStrategyConfig.json";
        DeployAssetConfig assetConfigDeploy = new DeployAssetConfig(assetConfigPath);
        DeployAssetConfig.Config memory assetConfig = assetConfigDeploy.getConfig();

        deployStrategyFactory(addresses, assetConfig);

        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deployStrategyFactory(
        Addresses addresses,
        DeployConfig.DeploymentConfig memory config,
        uint256 strategyTypeId
    ) public returns (address) {
        vm.startBroadcast();

        // Get the addresses for the initialization parameters
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address mamoBackend = addresses.getAddress("MAMO_BACKEND");
        address mToken = addresses.getAddress("MOONWELL_USDC");
        address metaMorphoVault = addresses.getAddress("USDC_METAMORPHO_VAULT");
        address underlying = addresses.getAddress("USDC");
        address slippagePriceChecker = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        address strategyImplementation = addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL");
        // TODO: change this to the fee recipient address
        address feeRecipient = addresses.getAddress("MAMO_MULTISIG");

        // Get reward token addresses
        address well = addresses.getAddress("xWELL_PROXY");
        address morpho = addresses.getAddress("MORPHO");

        // Create reward tokens array
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = well;
        rewardTokens[1] = morpho;

        console.log("config.splitMToken", config.splitMToken);
        console.log("config.splitVault", config.splitVault);
        console.log("config.hookGasLimit", config.hookGasLimit);
        console.log("config.allowedSlippageInBps", config.allowedSlippageInBps);
        console.log("config.compoundFee", config.compoundFee);

        // Deploy the USDCStrategyFactory
        StrategyFactory factory = new StrategyFactory(
            mamoStrategyRegistry,
            mamoBackend,
            mToken,
            metaMorphoVault,
            underlying,
            slippagePriceChecker,
            strategyImplementation,
            feeRecipient,
            config.splitMToken,
            config.splitVault,
            strategyTypeId,
            config.hookGasLimit,
            config.allowedSlippageInBps,
            config.compoundFee,
            rewardTokens
        );

        vm.stopBroadcast();

        // Check if the factory address already exists
        string memory factoryName = "USDC_STRATEGY_FACTORY";
        if (addresses.isAddressSet(factoryName)) {
            // Update the existing address
            addresses.changeAddress(factoryName, address(factory), true);
        } else {
            // Add the factory address to the addresses contract
            addresses.addAddress(factoryName, address(factory), true);
        }

        return address(factory);
    }

    function deployStrategyFactory(Addresses addresses, DeployAssetConfig.Config memory assetConfig)
        public
        returns (address)
    {
        vm.startBroadcast();

        // Get the addresses for the initialization parameters
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address mamoBackend = addresses.getAddress("MAMO_BACKEND");
        address mToken = addresses.getAddress(assetConfig.moonwellMarket);
        address metaMorphoVault = addresses.getAddress(assetConfig.metamorphoVault);
        address slippagePriceChecker = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        address strategyImplementation = addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL");
        address feeRecipient = addresses.getAddress("MAMO_MULTISIG");
        address underlying = addresses.getAddress(assetConfig.token);

        // Get reward token addresses
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        rewardTokens[1] = addresses.getAddress("MORPHO");

        // Deploy the StrategyFactory
        StrategyFactory factory = new StrategyFactory(
            mamoStrategyRegistry,
            mamoBackend,
            mToken,
            metaMorphoVault,
            underlying,
            slippagePriceChecker,
            strategyImplementation,
            feeRecipient,
            assetConfig.strategyParams.splitMToken,
            assetConfig.strategyParams.splitVault,
            assetConfig.strategyParams.strategyTypeId,
            assetConfig.strategyParams.hookGasLimit,
            assetConfig.strategyParams.allowedSlippageInBps,
            assetConfig.strategyParams.compoundFee,
            rewardTokens
        );

        vm.stopBroadcast();

        // Check if the factory address already exists
        string memory factoryName = string(abi.encodePacked(assetConfig.token, "_STRATEGY_FACTORY_V2"));
        if (addresses.isAddressSet(factoryName)) {
            // Update the existing address
            addresses.changeAddress(factoryName, address(factory), true);
        } else {
            // Add the factory address to the addresses contract
            addresses.addAddress(factoryName, address(factory), true);
        }

        return address(factory);
    }
}
