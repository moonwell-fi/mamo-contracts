// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccountRegistry} from "@contracts/AccountRegistry.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoAccount} from "@contracts/MamoAccount.sol";
import {MamoAccountFactory} from "@contracts/MamoAccountFactory.sol";
import {MamoStakingStrategy} from "@contracts/MamoStakingStrategy.sol";
// MultiRewards is deployed using vm.deployCode due to Solidity version compatibility

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

        // Whitelist MamoAccount implementation in MamoStrategyRegistry
        whitelistMamoAccountImplementation(addresses, deployer);

        return deployedContracts;
    }

    function deployAccountRegistry(Addresses addresses, address deployer) public returns (address) {
        // Get the addresses for the initialization parameters
        address admin = addresses.getAddress("MAMO_MULTISIG");
        address backend = addresses.getAddress("MAMO_BACKEND");
        address guardian = addresses.getAddress("MAMO_MULTISIG");

        vm.startBroadcast(deployer);
        // Deploy the AccountRegistry
        AccountRegistry accountRegistry = new AccountRegistry(admin, backend, guardian);
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
        address admin = addresses.getAddress("MAMO_MULTISIG");
        address backend = addresses.getAddress("MAMO_BACKEND");
        address guardian = addresses.getAddress("MAMO_MULTISIG");
        AccountRegistry registry = AccountRegistry(addresses.getAddress("ACCOUNT_REGISTRY"));
        IMamoStrategyRegistry mamoStrategyRegistry =
            IMamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Deploy MamoAccount implementation if it doesn't exist
        address accountImplementation;
        if (addresses.isAddressSet("MAMO_ACCOUNT_IMPLEMENTATION")) {
            accountImplementation = addresses.getAddress("MAMO_ACCOUNT_IMPLEMENTATION");
        } else {
            vm.startBroadcast(deployer);
            MamoAccount impl = new MamoAccount();
            vm.stopBroadcast();
            accountImplementation = address(impl);
            addresses.addAddress("MAMO_ACCOUNT_IMPLEMENTATION", accountImplementation, true);
        }

        vm.startBroadcast(deployer);
        // Deploy the MamoAccountFactory
        MamoAccountFactory mamoAccountFactory = new MamoAccountFactory(
            admin,
            backend,
            guardian,
            registry,
            mamoStrategyRegistry,
            accountImplementation,
            1 // Account strategy type ID
        );
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
        address admin = addresses.getAddress("MAMO_MULTISIG");
        address backend = addresses.getAddress("MAMO_BACKEND");
        address guardian = addresses.getAddress("MAMO_MULTISIG");
        AccountRegistry registry = AccountRegistry(addresses.getAddress("ACCOUNT_REGISTRY"));

        // Use MAMO instead of MAMO_TOKEN (different naming convention)
        IERC20 mamoToken = IERC20(addresses.getAddress("MAMO"));

        // Deploy missing components if they don't exist
        address multiRewardsAddr = deployMultiRewards(addresses, deployer, address(mamoToken));
        address dexRouterAddr = addresses.getAddress("AERODROME_ROUTER");
        address morphoStrategyAddr = deployMorphoStrategy(addresses, deployer);

        IMultiRewards multiRewards = IMultiRewards(multiRewardsAddr);
        IDEXRouter dexRouter = IDEXRouter(dexRouterAddr);

        vm.startBroadcast(deployer);
        // Deploy the MamoStakingStrategy
        MamoStakingStrategy mamoStakingStrategy =
            new MamoStakingStrategy(admin, backend, guardian, registry, multiRewards, mamoToken, dexRouter);
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

    /**
     * @notice Whitelists the MamoAccount implementation in the MamoStrategyRegistry
     * @param addresses The addresses contract
     * @param deployer The deployer address
     */
    function whitelistMamoAccountImplementation(Addresses addresses, address deployer) public {
        // Get the MamoAccount implementation address
        address accountImplementation = addresses.getAddress("MAMO_ACCOUNT_IMPLEMENTATION");
        require(accountImplementation != address(0), "MamoAccount implementation not deployed");

        // Get the MamoStrategyRegistry
        IMamoStrategyRegistry mamoStrategyRegistry =
            IMamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Check if implementation is already whitelisted
        if (mamoStrategyRegistry.whitelistedImplementations(accountImplementation)) {
            console.log("MamoAccount implementation already whitelisted");
            return;
        }

        // Get the admin address for the registry
        address admin = addresses.getAddress("MAMO_MULTISIG");

        // Whitelist the MamoAccount implementation with strategy type ID 1
        vm.startPrank(admin);
        uint256 assignedStrategyTypeId = mamoStrategyRegistry.whitelistImplementation(accountImplementation, 1);
        vm.stopPrank();

        console.log("Whitelisted MamoAccount implementation with strategy type ID:", assignedStrategyTypeId);
    }
}
