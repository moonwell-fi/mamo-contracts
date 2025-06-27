// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccountRegistry} from "@contracts/AccountRegistry.sol";

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoAccountFactory} from "@contracts/MamoAccountFactory.sol";
import {MamoStakingStrategy} from "@contracts/MamoStakingStrategy.sol";

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {IDEXRouter} from "@interfaces/IDEXRouter.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployMamoStaking
 * @notice Script to deploy and manage AccountRegistry, MamoAccountFactory, and MamoStakingStrategy contracts
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
        address[] memory deployedContracts = new address[](3);

        // Deploy contracts in dependency order
        deployedContracts[0] = deployAccountRegistry(addresses, deployer);
        deployedContracts[1] = deployMamoAccountFactory(addresses, deployer);
        deployedContracts[2] = deployMamoStakingStrategy(addresses, deployer);

        return deployedContracts;
    }

    function deployAccountRegistry(Addresses addresses, address deployer) public returns (address) {
        // Get the addresses for the initialization parameters
        address admin = addresses.getAddress("MAMO_COMPOUNDER");
        address backend = addresses.getAddress("BACKEND_ADDRESS");
        address guardian = addresses.getAddress("GUARDIAN_ADDRESS");
        address feeCollector = addresses.getAddress("FEE_COLLECTOR");

        vm.startBroadcast(deployer);
        // Deploy the AccountRegistry
        AccountRegistry accountRegistry = new AccountRegistry(admin, backend, guardian, feeCollector);
        vm.stopBroadcast();

        // Check if the account registry address already exists
        string memory accountRegistryName = "ACCOUNT_REGISTRY";
        if (addresses.isAddressSet(accountRegistryName)) {
            // Update the existing address
            addresses.changeAddress(accountRegistryName, address(accountRegistry), true);
        } else {
            // Add the account registry address to the addresses contract
            addresses.addAddress(accountRegistryName, address(accountRegistry), true);
        }

        return address(accountRegistry);
    }

    function deployMamoAccountFactory(Addresses addresses, address deployer) public returns (address) {
        // Get the addresses for the initialization parameters
        address admin = addresses.getAddress("MAMO_COMPOUNDER");
        address backend = addresses.getAddress("BACKEND_ADDRESS");
        address guardian = addresses.getAddress("GUARDIAN_ADDRESS");
        AccountRegistry registry = AccountRegistry(addresses.getAddress("ACCOUNT_REGISTRY"));
        IMamoStrategyRegistry mamoStrategyRegistry =
            IMamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        address accountImplementation = addresses.getAddress("MAMO_ACCOUNT_IMPLEMENTATION");

        vm.startBroadcast(deployer);
        // Deploy the MamoAccountFactory
        MamoAccountFactory mamoAccountFactory =
            new MamoAccountFactory(admin, backend, guardian, registry, mamoStrategyRegistry, accountImplementation);
        vm.stopBroadcast();

        // Check if the mamo account factory address already exists
        string memory mamoAccountFactoryName = "MAMO_ACCOUNT_FACTORY";
        if (addresses.isAddressSet(mamoAccountFactoryName)) {
            // Update the existing address
            addresses.changeAddress(mamoAccountFactoryName, address(mamoAccountFactory), true);
        } else {
            // Add the mamo account factory address to the addresses contract
            addresses.addAddress(mamoAccountFactoryName, address(mamoAccountFactory), true);
        }

        return address(mamoAccountFactory);
    }

    function deployMamoStakingStrategy(Addresses addresses, address deployer) public returns (address) {
        // Get the addresses for the initialization parameters
        address admin = addresses.getAddress("MAMO_COMPOUNDER");
        address backend = addresses.getAddress("BACKEND_ADDRESS");
        address guardian = addresses.getAddress("GUARDIAN_ADDRESS");
        AccountRegistry registry = AccountRegistry(addresses.getAddress("ACCOUNT_REGISTRY"));
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MULTI_REWARDS"));
        IERC20 mamoToken = IERC20(addresses.getAddress("MAMO_TOKEN"));
        IDEXRouter dexRouter = IDEXRouter(addresses.getAddress("DEX_ROUTER"));
        ERC20MoonwellMorphoStrategy morphoStrategy =
            ERC20MoonwellMorphoStrategy(payable(addresses.getAddress("MORPHO_STRATEGY")));
        uint256 compoundFee = 100; // 1% compound fee in basis points

        vm.startBroadcast(deployer);
        // Deploy the MamoStakingStrategy
        MamoStakingStrategy mamoStakingStrategy = new MamoStakingStrategy(
            admin, backend, guardian, registry, multiRewards, mamoToken, dexRouter, morphoStrategy, compoundFee
        );
        vm.stopBroadcast();

        // Check if the mamo staking strategy address already exists
        string memory mamoStakingStrategyName = "MAMO_STAKING_STRATEGY";
        if (addresses.isAddressSet(mamoStakingStrategyName)) {
            // Update the existing address
            addresses.changeAddress(mamoStakingStrategyName, address(mamoStakingStrategy), true);
        } else {
            // Add the mamo staking strategy address to the addresses contract
            addresses.addAddress(mamoStakingStrategyName, address(mamoStakingStrategy), true);
        }

        return address(mamoStakingStrategy);
    }
}
