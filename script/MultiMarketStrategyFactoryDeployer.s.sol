// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";

import {DeployAssetConfig} from "./DeployAssetConfig.sol";

import {MultiMarketStrategyFactory} from "@contracts/MultiMarketStrategyFactory.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title MultiMarketStrategyFactoryDeployer
 * @notice Script to deploy the MultiMarketStrategyFactory contract
 */
contract MultiMarketStrategyFactoryDeployer is Script {
    function deployStrategyFactory(
        Addresses addresses,
        DeployAssetConfig.Config memory assetConfig,
        uint256 strategyTypeId,
        address deployer
    ) public returns (address) {
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address mamoBackend = addresses.getAddress("MAMO_BACKEND");
        address underlying = addresses.getAddress(assetConfig.token);
        address slippagePriceChecker = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        address strategyImplementation = addresses.getAddress(assetConfig.strategyImplementation);
        address feeRecipient = addresses.getAddress("MAMO_MULTISIG");
        address marketRegistryAddr = addresses.getAddress("MARKET_REGISTRY");

        // Build reward tokens array
        address[] memory rewardTokens = new address[](assetConfig.rewardTokens.length);
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            rewardTokens[i] = addresses.getAddress(assetConfig.rewardTokens[i].token);
        }

        // Build default split bps from markets config
        uint256[] memory defaultSplitBps = new uint256[](assetConfig.markets.length);
        for (uint256 i = 0; i < assetConfig.markets.length; i++) {
            defaultSplitBps[i] = assetConfig.markets[i].splitBps;
        }

        vm.startBroadcast(deployer);

        MultiMarketStrategyFactory factory = new MultiMarketStrategyFactory(
            mamoStrategyRegistry,
            mamoBackend,
            underlying,
            slippagePriceChecker,
            strategyImplementation,
            feeRecipient,
            marketRegistryAddr,
            strategyTypeId,
            assetConfig.strategyParams.hookGasLimit,
            assetConfig.strategyParams.allowedSlippageInBps,
            assetConfig.strategyParams.compoundFee,
            rewardTokens,
            defaultSplitBps
        );

        vm.stopBroadcast();

        string memory factoryName = string(abi.encodePacked(assetConfig.token, "_MULTI_MARKET_STRATEGY_FACTORY"));
        if (addresses.isAddressSet(factoryName)) {
            addresses.changeAddress(factoryName, address(factory), true);
        } else {
            addresses.addAddress(factoryName, address(factory), true);
        }

        return address(factory);
    }
}
