// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployConfig} from "./DeployConfig.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {USDCStrategyFactory} from "@contracts/USDCStrategyFactory.sol";

/**
 * @title USDCStrategyFactoryDeployer
 * @notice Script to deploy the USDCStrategyFactory contract
 */
contract USDCStrategyFactoryDeployer is Script {
    function deployUSDCStrategyFactory(
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
        address usdc = addresses.getAddress("USDC");
        address slippagePriceChecker = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        address strategyImplementation = addresses.getAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL");

        // Get reward token addresses
        address well = addresses.getAddress("xWELL_PROXY");
        address morpho = addresses.getAddress("MORPHO");

        // Create reward tokens array
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = well;
        rewardTokens[1] = morpho;

        // Deploy the USDCStrategyFactory
        USDCStrategyFactory factory = new USDCStrategyFactory(
            mamoStrategyRegistry,
            mamoBackend,
            mToken,
            metaMorphoVault,
            usdc,
            slippagePriceChecker,
            strategyImplementation,
            config.splitMToken,
            config.splitVault,
            strategyTypeId,
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
}
