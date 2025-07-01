// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@fps/addresses/Addresses.sol";

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StrategyFactory} from "@contracts/StrategyFactory.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployFactoriesAndMulticall} from "@multisig/003_DeployFactoriesAndMulticall.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {DeployConfig} from "@script/DeployConfig.sol";

import {DeploySlippagePriceChecker} from "@script/DeploySlippagePriceChecker.s.sol";
import {StrategyFactoryDeployer} from "@script/StrategyFactoryDeployer.s.sol";
import {StrategyRegistryDeploy} from "@script/StrategyRegistryDeploy.s.sol";

import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";

import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {FixIsRewardToken} from "@multisig/002_FixIsRewardToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StrategyFactoryIntegrationTest is Test {
    Addresses public addresses;
    StrategyFactory public factory;
    MamoStrategyRegistry public registry;

    // Configuration
    DeployConfig.DeploymentConfig public config;
    DeployAssetConfig.Config public assetConfig;

    // Addresses
    address public admin;
    address public backend;
    address public guardian;
    address public deployer;
    address public mamoMultisig;

    // Strategy parameters
    uint256 public strategyTypeId;
    uint256 public splitMToken;
    uint256 public splitVault;

    function setUp() public {
        // workaround to make test contract work with mappings
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        // Create a new addresses instance for testing
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get the environment from command line arguments or use default
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));
        string memory assetConfigPath = vm.envString("ASSET_CONFIG_PATH");

        // Load configurations
        DeployConfig configDeploy = new DeployConfig(configPath);
        config = configDeploy.getConfig();

        DeployAssetConfig assetConfigDeploy = new DeployAssetConfig(assetConfigPath);
        assetConfig = assetConfigDeploy.getConfig();

        // Get the addresses for the roles
        admin = addresses.getAddress(config.admin);
        backend = addresses.getAddress(config.backend);
        guardian = addresses.getAddress(config.guardian);
        deployer = addresses.getAddress(config.deployer);
        mamoMultisig = admin; // Use admin as mamo multisig for testing

        factory = StrategyFactory(payable(addresses.getAddress("cbBTC_STRATEGY_FACTORY")));
        registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        splitMToken = assetConfig.strategyParams.splitMToken;
        splitVault = assetConfig.strategyParams.splitVault;
        strategyTypeId = assetConfig.strategyParams.strategyTypeId;
    }

    function testFactoryDeployment() public view {
        // Test that the factory was deployed correctly
        assertTrue(address(factory) != address(0), "Factory not deployed");

        // Test that the factory has the correct parameters
        assertEq(factory.mamoStrategyRegistry(), address(registry), "Registry address mismatch");
        assertEq(factory.mamoBackend(), backend, "Backend address mismatch");
        assertEq(factory.splitMToken(), splitMToken, "Split mToken mismatch");
        assertEq(factory.splitVault(), splitVault, "Split vault mismatch");
        assertEq(factory.strategyTypeId(), strategyTypeId, "Strategy type ID mismatch");
    }

    function testCreateStrategyForUser() public {
        address user = makeAddr("user");

        // Prank as backend to create strategy
        vm.startPrank(backend);

        // Expect the StrategyCreated event to be emitted (check user and event type, ignore address)
        vm.expectEmit(true, false, false, false);
        emit StrategyFactory.StrategyCreated(user, address(0));

        // Create strategy for user
        address strategy = factory.createStrategyForUser(user);

        vm.stopPrank();

        // Verify strategy was created
        assertTrue(strategy != address(0), "Strategy not created");

        // Verify strategy is registered in the registry
        assertTrue(registry.isUserStrategy(user, strategy), "Strategy not registered for user");

        // Verify strategy has correct owner
        ERC20MoonwellMorphoStrategy strategyContract = ERC20MoonwellMorphoStrategy(payable(strategy));
        assertEq(strategyContract.owner(), user, "Strategy owner mismatch");

        // Verify strategy has correct parameters
        assertEq(address(strategyContract.mamoStrategyRegistry()), address(registry), "Registry mismatch in strategy");
    }

    function testUserCanCreateStrategyForThemselves() public {
        address user = makeAddr("user");

        // Prank as user to create strategy for themselves
        vm.startPrank(user);

        // Expect the StrategyCreated event to be emitted (check user and event type, ignore address)
        vm.expectEmit(true, false, false, false);
        emit StrategyFactory.StrategyCreated(user, address(0));

        // Create strategy for user
        address strategy = factory.createStrategyForUser(user);

        vm.stopPrank();

        // Verify strategy was created
        assertTrue(strategy != address(0), "Strategy not created");

        // Verify strategy is registered in the registry
        assertTrue(registry.isUserStrategy(user, strategy), "Strategy not registered for user");

        // Verify strategy has correct owner
        ERC20MoonwellMorphoStrategy strategyContract = ERC20MoonwellMorphoStrategy(payable(strategy));
        assertEq(strategyContract.owner(), user, "Strategy owner mismatch");

        // Verify strategy has correct parameters
        assertEq(address(strategyContract.mamoStrategyRegistry()), address(registry), "Registry mismatch in strategy");
    }

    function testCreateMultipleStrategiesForDifferentUsers() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        vm.startPrank(backend);

        // Create strategies for both users
        address strategy1 = factory.createStrategyForUser(user1);
        address strategy2 = factory.createStrategyForUser(user2);

        vm.stopPrank();

        // Verify strategies were created and are different
        assertTrue(strategy1 != address(0), "Strategy1 not created");
        assertTrue(strategy2 != address(0), "Strategy2 not created");
        assertTrue(strategy1 != strategy2, "Strategies should be different");

        // Verify strategies are registered for correct users
        assertTrue(registry.isUserStrategy(user1, strategy1), "Strategy1 not registered for user1");
        assertTrue(registry.isUserStrategy(user2, strategy2), "Strategy2 not registered for user2");
        assertFalse(registry.isUserStrategy(user1, strategy2), "Strategy2 should not be registered for user1");
        assertFalse(registry.isUserStrategy(user2, strategy1), "Strategy1 should not be registered for user2");
    }

    function testRevertIfNonBackendNonUserCallsCreateStrategy() public {
        address user = makeAddr("user");
        address nonBackendNonUser = makeAddr("nonBackendNonUser");

        // Verify the caller is neither backend nor the user
        assertFalse(factory.mamoBackend() == nonBackendNonUser, "Should not be backend");
        assertFalse(user == nonBackendNonUser, "Should not be user");

        vm.startPrank(nonBackendNonUser);

        // Expect the call to revert since only backend or user can create strategy
        vm.expectRevert("Only backend or user can create strategy");

        // Call the createStrategyForUser function
        factory.createStrategyForUser(user);

        vm.stopPrank();
    }

    function testFactoryParametersValidation() public view {
        // Test that factory parameters are correctly set during deployment
        assertEq(factory.mamoStrategyRegistry(), address(registry), "Registry address should match");
        assertEq(factory.mamoBackend(), backend, "Backend address should match");
        assertEq(factory.mToken(), addresses.getAddress(assetConfig.moonwellMarket), "mToken address should match");
        assertEq(
            factory.metaMorphoVault(),
            addresses.getAddress(assetConfig.metamorphoVault),
            "MetaMorpho vault should match"
        );
        assertEq(factory.token(), addresses.getAddress(assetConfig.token), "Token address should match");
        assertEq(factory.feeRecipient(), admin, "Fee recipient should match");
        assertEq(factory.splitMToken() + factory.splitVault(), 10000, "Splits should add up to 10000");
        assertEq(factory.strategyTypeId(), strategyTypeId, "Strategy type ID should match");
        assertTrue(factory.hookGasLimit() > 0, "Hook gas limit should be positive");
        assertTrue(factory.allowedSlippageInBps() <= 1000, "Slippage should be within bounds");
        assertTrue(factory.compoundFee() <= 1000, "Compound fee should be within bounds");
    }
}
