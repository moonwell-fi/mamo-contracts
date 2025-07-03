// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoAccountRegistry} from "@contracts/MamoAccountRegistry.sol";
import {MamoStakingStrategy} from "@contracts/MamoStakingStrategy.sol";
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
 * @notice Script to deploy and manage MamoAccountRegistry and MamoStakingStrategy contracts
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
        deployedContracts[0] = deployMamoAccountRegistry(addresses, deployer);
        deployedContracts[1] = deployMamoStakingStrategy(addresses, deployer);

        return deployedContracts;
    }

    function deployMamoAccountRegistry(Addresses addresses, address deployer) public returns (address) {
        // Get the addresses for the initialization parameters
        address admin = addresses.getAddress("MAMO_MULTISIG");
        address backend = addresses.getAddress("MAMO_BACKEND");
        address guardian = addresses.getAddress("MAMO_MULTISIG");

        vm.startBroadcast(deployer);
        // Deploy the MamoAccountRegistry
        MamoAccountRegistry accountRegistry = new MamoAccountRegistry(admin, backend, guardian);
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


    function deployMamoStakingStrategy(Addresses addresses, address deployer) public returns (address) {
        // Get the addresses for the initialization parameters
        address admin = addresses.getAddress("MAMO_MULTISIG");
        address backend = addresses.getAddress("MAMO_BACKEND");
        address guardian = addresses.getAddress("MAMO_MULTISIG");
        MamoAccountRegistry registry = MamoAccountRegistry(addresses.getAddress("ACCOUNT_REGISTRY"));

        // Use MAMO instead of MAMO_TOKEN (different naming convention)
        IERC20 mamoToken = IERC20(addresses.getAddress("MAMO"));

        // Deploy missing components if they don't exist
        address multiRewardsAddr = deployMultiRewards(addresses, deployer, address(mamoToken));
        address dexRouterAddr = addresses.getAddress("AERODROME_ROUTER");
        address quoterAddr = addresses.getAddress("AERODROME_QUOTER");
        address morphoStrategyAddr = deployMorphoStrategy(addresses, deployer);

        IMultiRewards multiRewards = IMultiRewards(multiRewardsAddr);
        ISwapRouter dexRouter = ISwapRouter(dexRouterAddr);
        IQuoter quoter = IQuoter(quoterAddr);

        vm.startBroadcast(deployer);
        // Deploy the MamoStakingStrategy
        MamoStakingStrategy mamoStakingStrategy =
            new MamoStakingStrategy(admin, backend, guardian, registry, multiRewards, mamoToken, dexRouter, quoter);
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

    function deployMorphoStrategy(Addresses addresses, address deployer) public returns (address) {
        // Check if MorphoStrategy already exists
        if (addresses.isAddressSet("MORPHO_STRATEGY")) {
            return addresses.getAddress("MORPHO_STRATEGY");
        }

        // Use the existing implementation from addresses
        if (addresses.isAddressSet("MOONWELL_MORPHO_STRATEGY_IMPL")) {
            address implementation = addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL");
            return implementation;
        }

        // If no implementation exists, we need to deploy one
        // For now, return the existing implementation address
        revert("No Morpho strategy implementation found");
    }

}
