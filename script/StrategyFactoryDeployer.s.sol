// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployAssetConfig} from "./DeployAssetConfig.sol";
import {DeployConfig} from "./DeployConfig.sol";

import {StrategyFactory} from "@contracts/StrategyFactory.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

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

        deployStrategyFactory(addresses, assetConfig, addresses.getAddress("DEPLOYER_EOA"));

        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deployStrategyFactory(
        Addresses addresses,
        DeployConfig.DeploymentConfig memory config,
        uint256 strategyTypeId,
        address deployer
    ) public returns (address) {
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        rewardTokens[1] = addresses.getAddress("MORPHO");

        uint256[] memory defaultSplitBps = new uint256[](2);
        defaultSplitBps[0] = config.splitMToken;
        defaultSplitBps[1] = config.splitVault;

        vm.startBroadcast(deployer);

        StrategyFactory factory = new StrategyFactory(
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            addresses.getAddress("MAMO_BACKEND"),
            addresses.getAddress("USDC"),
            addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"),
            addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL"),
            addresses.getAddress("MAMO_MULTISIG"),
            addresses.getAddress("MARKET_REGISTRY"),
            strategyTypeId,
            config.hookGasLimit,
            config.allowedSlippageInBps,
            config.compoundFee,
            rewardTokens,
            defaultSplitBps
        );

        vm.stopBroadcast();

        string memory factoryName = "USDC_STRATEGY_FACTORY";
        if (addresses.isAddressSet(factoryName)) {
            addresses.changeAddress(factoryName, address(factory), true);
        } else {
            addresses.addAddress(factoryName, address(factory), true);
        }

        return address(factory);
    }

    function deployStrategyFactory(Addresses addresses, DeployAssetConfig.Config memory assetConfig, address deployer)
        public
        returns (address)
    {
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        rewardTokens[1] = addresses.getAddress("MORPHO");

        uint256[] memory defaultSplitBps = new uint256[](2);
        defaultSplitBps[0] = assetConfig.strategyParams.splitMToken;
        defaultSplitBps[1] = assetConfig.strategyParams.splitVault;

        vm.startBroadcast(deployer);

        StrategyFactory factory = new StrategyFactory(
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            addresses.getAddress("MAMO_BACKEND"),
            addresses.getAddress(assetConfig.token),
            addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"),
            addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL"),
            addresses.getAddress("MAMO_MULTISIG"),
            addresses.getAddress("MARKET_REGISTRY"),
            assetConfig.strategyParams.strategyTypeId,
            assetConfig.strategyParams.hookGasLimit,
            assetConfig.strategyParams.allowedSlippageInBps,
            assetConfig.strategyParams.compoundFee,
            rewardTokens,
            defaultSplitBps
        );

        vm.stopBroadcast();

        string memory factoryName = string(abi.encodePacked(assetConfig.token, "_STRATEGY_FACTORY"));
        if (addresses.isAddressSet(factoryName)) {
            addresses.changeAddress(factoryName, address(factory), true);
        } else {
            addresses.addAddress(factoryName, address(factory), true);
        }

        return address(factory);
    }
}
