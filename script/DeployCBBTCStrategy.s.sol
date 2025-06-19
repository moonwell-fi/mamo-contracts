// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Addresses} from "../addresses/Addresses.sol";

import {ERC20MoonwellMorphoStrategy} from "../src/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "../src/MamoStrategyRegistry.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {DeployAssetConfig} from "./DeployAssetConfig.sol";

/**
 * @title DeployCBBTCStrategy
 * @notice Comprehensive deployment script for cbBTC strategy that integrates with the existing factory system
 * @dev Handles factory interaction, strategy parameter configuration, ownership setup, and post-deployment validation
 */
contract DeployCBBTCStrategy is Script {
    /// @notice Configuration for the cbBTC strategy
    DeployAssetConfig.Config private config;

    /// @notice Addresses contract for managing deployed contract addresses
    Addresses private addresses;

    /// @notice The deployed strategy factory
    StrategyFactory private strategyFactory;

    /// @notice Events for deployment tracking
    event CBBTCStrategyDeployed(address indexed user, address indexed strategy, address indexed factory);
    event OwnershipTransferred(address indexed strategy, address indexed previousOwner, address indexed newOwner);

    /**
     * @notice Main deployment function
     * @dev Reads configuration, validates factory, and deploys user strategy
     */
    function run() public {
        // Load addresses and configuration
        _loadConfiguration();

        // Load the existing factory
        _loadExistingFactory();

        // Deploy strategy for user
        _deployUserStrategy();
    }

    /**
     * @notice Deploy cbBTC strategy for a specific user
     * @param user The address of the user to create the strategy for
     * @return strategy The address of the newly deployed strategy
     */
    function deployStrategyForUser(address user) public returns (address strategy) {
        require(user != address(0), "Invalid user address");

        // Load configuration if not already loaded
        if (address(addresses) == address(0)) {
            _loadConfiguration();
            _loadExistingFactory();
        }

        vm.startBroadcast();

        // Create strategy through factory
        strategy = strategyFactory.createStrategyForUser(user);

        // Validate strategy deployment
        require(strategy != address(0), "Strategy deployment failed");

        // Verify strategy initialization
        ERC20MoonwellMorphoStrategy strategyContract = ERC20MoonwellMorphoStrategy(payable(strategy));
        require(strategyContract.owner() == user, "Strategy ownership not set correctly");

        vm.stopBroadcast();

        // Log deployment details
        console.log("=== cbBTC Strategy Deployed ===");
        console.log("User:", user);
        console.log("Strategy:", strategy);
        console.log("Factory:", address(strategyFactory));
        console.log("Strategy Type ID:", strategyContract.strategyTypeId());

        emit CBBTCStrategyDeployed(user, strategy, address(strategyFactory));

        return strategy;
    }

    /**
     * @notice Load configuration and addresses
     * @dev Internal function to initialize deployment dependencies
     */
    function _loadConfiguration() private {
        // Load addresses from JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Load cbBTC strategy configuration
        string memory configPath = "config/strategies/cbBTCStrategyConfig.json";
        DeployAssetConfig assetConfigDeploy = new DeployAssetConfig(configPath);
        config = assetConfigDeploy.getConfig();

        console.log("=== Configuration Loaded ===");
        console.log("Chain ID:", block.chainid);
        console.log("Config Path:", configPath);
        console.log("Token:", config.token);
        console.log("Strategy Type ID:", config.strategyParams.strategyTypeId);
    }

    /**
     * @notice Load the existing cbBTC factory
     * @dev Loads the factory from the addresses file
     */
    function _loadExistingFactory() private {
        string memory factoryName = "cbBTC_STRATEGY_FACTORY";

        // Load the existing factory
        require(addresses.isAddressSet(factoryName), "cbBTC factory not found in addresses");
        address factoryAddress = addresses.getAddress(factoryName);
        strategyFactory = StrategyFactory(factoryAddress);

        console.log("=== Factory Loaded ===");
        console.log("Factory Address:", factoryAddress);
        console.log("Strategy Type ID:", strategyFactory.strategyTypeId());
    }

    /**
     * @notice Deploy strategy for a test user (for demonstration)
     * @dev Creates a strategy for the testing EOA from addresses
     */
    function _deployUserStrategy() private {
        // Get testing EOA address for demonstration
        address testUser = addresses.getAddress("DEPLOYER_EOA");

        console.log("=== Deploying Strategy for Test User ===");
        console.log("Test User:", testUser);

        // Deploy strategy
        address strategy = deployStrategyForUser(testUser);

        // Perform post-deployment validation
        _validateStrategyDeployment(strategy, testUser);
    }

    /**
     * @notice Validate strategy deployment and configuration
     * @param strategy Address of the deployed strategy
     * @param expectedOwner Expected owner of the strategy
     */
    function _validateStrategyDeployment(address strategy, address expectedOwner) private view {
        ERC20MoonwellMorphoStrategy strategyContract = ERC20MoonwellMorphoStrategy(payable(strategy));

        // Validate ownership
        require(strategyContract.owner() == expectedOwner, "Strategy ownership validation failed");

        // Validate strategy parameters
        require(strategyContract.strategyTypeId() == config.strategyParams.strategyTypeId, "Strategy type ID mismatch");
        require(strategyContract.hookGasLimit() == config.strategyParams.hookGasLimit, "Hook gas limit mismatch");
        require(
            strategyContract.allowedSlippageInBps() == config.strategyParams.allowedSlippageInBps,
            "Slippage parameter mismatch"
        );
        require(strategyContract.compoundFee() == config.strategyParams.compoundFee, "Compound fee mismatch");

        // Validate token addresses
        require(address(strategyContract.token()) == addresses.getAddress(config.token), "Token address mismatch");
        require(
            address(strategyContract.mToken()) == addresses.getAddress(config.moonwellMarket), "mToken address mismatch"
        );
        require(
            address(strategyContract.metaMorphoVault()) == addresses.getAddress(config.metamorphoVault),
            "MetaMorpho vault address mismatch"
        );

        console.log("=== Strategy Validation: PASSED ===");
    }
}
