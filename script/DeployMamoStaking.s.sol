// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStakingRegistry} from "@contracts/MamoStakingRegistry.sol";
import {MamoStakingStrategy} from "@contracts/MamoStakingStrategy.sol";
import {MamoStakingStrategyFactory} from "@contracts/MamoStakingStrategyFactory.sol";
// MultiRewards is deployed using vm.deployCode due to Solidity version compatibility

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployMamoStaking
 * @notice Script to deploy and manage MamoStakingRegistry and MamoStakingStrategy contracts
 */
contract DeployMamoStaking is Script {
    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID
        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        deploy(addresses, addresses.getAddress("DEPLOYER_EOA"));

        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deploy(Addresses addresses, address deployer) public returns (address[] memory) {
        address[] memory deployedContracts = new address[](2);

        // Deploy contracts in dependency order
        deployedContracts[0] = deployMamoStakingStrategyFactory(addresses, deployer);

        return deployedContracts;
    }

    function deployMamoStakingStrategyFactory(Addresses addresses, address deployer) public returns (address) {
        // Get the addresses for the initialization parameters
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address mamoBackend = addresses.getAddress("MAMO_BACKEND");
        address stakingRegistry = addresses.getAddress("STAKING_REGISTRY");
        address mamoToken = addresses.getAddress("MAMO");
        address strategyImplementation = addresses.getAddress("MAMO_STAKING_STRATEGY_IMPLEMENTATION");

        // Deploy missing components if they don't exist
        address multiRewardsAddr = deployMultiRewards(addresses, deployer, mamoToken);

        // Strategy configuration
        uint256 strategyTypeId = 2; // Assuming staking strategy type ID is 2
        uint256 defaultSlippageInBps = 100; // 1% default slippage

        vm.startBroadcast(deployer);
        // Deploy the MamoStakingStrategyFactory
        MamoStakingStrategyFactory factory = new MamoStakingStrategyFactory(
            mamoStrategyRegistry,
            mamoBackend,
            stakingRegistry,
            multiRewardsAddr,
            mamoToken,
            strategyImplementation,
            strategyTypeId,
            defaultSlippageInBps
        );
        vm.stopBroadcast();

        // Check if the factory address already exists
        string memory factoryName = "MAMO_STAKING_STRATEGY_FACTORY";
        if (addresses.isAddressSet(factoryName)) {
            // Update the existing address
            addresses.changeAddress(factoryName, address(factory), true);
        } else {
            // Add the factory address to the addresses contract
            addresses.addAddress(factoryName, address(factory), true);
        }

        return address(factory);
    }

    function deployMultiRewards(Addresses addresses, address deployer, address stakingToken) public returns (address) {
        // Check if MultiRewards already exists
        if (addresses.isAddressSet("MULTI_REWARDS")) {
            return addresses.getAddress("MULTI_REWARDS");
        }

        address owner = addresses.getAddress("MAMO_MULTISIG");

        vm.startBroadcast(deployer);
        bytes memory constructorArgs = abi.encode(owner, stakingToken);
        address multiRewardsAddr = vm.deployCode("MultiRewards.sol:MultiRewards", constructorArgs);
        vm.stopBroadcast();

        if (addresses.isAddressSet("MULTI_REWARDS")) {
            addresses.changeAddress("MULTI_REWARDS", multiRewardsAddr, true);
        } else {
            addresses.addAddress("MULTI_REWARDS", multiRewardsAddr, true);
        }
        return multiRewardsAddr;
    }
}
