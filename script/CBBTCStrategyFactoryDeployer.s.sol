// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployConfig} from "./DeployConfig.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {StrategyFactory} from "@contracts/StrategyFactory.sol";

/**
 * @title CBBTCStrategyFactoryDeployer
 * @notice Script to deploy the CBBTCStrategyFactory contract
 */
contract CBBTStrategyFactoryDeployer is Script {
    function deployCBBTCStrategyFactory(
        Addresses addresses,
        DeployConfig.DeploymentConfig memory config,
        uint256 strategyTypeId
    ) public returns (address) {
        vm.startBroadcast();

        // Get the addresses for the initialization parameters
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address mamoBackend = addresses.getAddress("MAMO_BACKEND");
        address mToken = addresses.getAddress("MOONWELL_CBBTC");
        address metaMorphoVault = addresses.getAddress("CBBTC_METAMORPHO_VAULT");
        address cbbtc = addresses.getAddress("CBBTC");
        address slippagePriceChecker = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        address strategyImplementation = addresses.getAddress("CBBTC_MOONWELL_MORPHO_STRATEGY_IMPL");
        // TODO: change this to the fee recipient address
        address feeRecipient = addresses.getAddress("MAMO_MULTISIG");

        // Get reward token addresses
        address well = addresses.getAddress("xWELL_PROXY");
        address morpho = addresses.getAddress("MORPHO");

        // Create reward tokens array
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = well;
        rewardTokens[1] = morpho;

        // Deploy the CBBTCStrategyFactory
        StrategyFactory factory = new StrategyFactory(
            mamoStrategyRegistry,
            mamoBackend,
            mToken,
            metaMorphoVault,
            cbbtc,
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
        string memory factoryName = "CBBTC_STRATEGY_FACTORY";
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
