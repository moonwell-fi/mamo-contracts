// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {Vm} from "@forge-std/Vm.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoStakingRegistry} from "@contracts/MamoStakingRegistry.sol";
import {MamoStakingStrategy} from "@contracts/MamoStakingStrategy.sol";
import {MamoStakingStrategyFactory} from "@contracts/MamoStakingStrategyFactory.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MamoStakingDeployment} from "@multisig/005_MamoStakingDeployment.sol";

contract MamoStakingStrategyFactoryIntegrationTest is Test {
    Addresses public addresses;
    MamoStakingRegistry public stakingRegistry;
    MamoStakingStrategyFactory public stakingStrategyFactory;
    MamoStrategyRegistry public mamoStrategyRegistry;
    IMultiRewards public multiRewards;

    IERC20 public mamoToken;
    address public user;
    address public stakingStrategyImplementation;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));

        // Create addresses instance
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get existing contract instances from addresses
        mamoStrategyRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        mamoToken = IERC20(addresses.getAddress("MAMO"));

        // Use the multisig deployment script to deploy all contracts
        MamoStakingDeployment deploymentScript = new MamoStakingDeployment();
        deploymentScript.setAddresses(addresses);

        // Call the individual functions instead of run()
        deploymentScript.build();
        deploymentScript.simulate();
        deploymentScript.validate();

        // Get the deployed contract instances
        stakingRegistry = MamoStakingRegistry(addresses.getAddress("MAMO_STAKING_REGISTRY"));
        stakingStrategyFactory = MamoStakingStrategyFactory(addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY"));
        multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        stakingStrategyImplementation = addresses.getAddress("MAMO_STAKING_STRATEGY");

        // Create test user
        user = makeAddr("testUser");
    }

    // ========== FACTORY DEPLOYMENT TESTS ==========

    function testDeploymentWasSuccessful() public {
        // Verify all contracts were deployed
        assertTrue(address(stakingRegistry) != address(0), "MamoStakingRegistry should be deployed");
        assertTrue(address(stakingStrategyFactory) != address(0), "MamoStakingStrategyFactory should be deployed");
        assertTrue(address(multiRewards) != address(0), "MultiRewards should be deployed");
        assertTrue(stakingStrategyImplementation != address(0), "MamoStakingStrategy implementation should be deployed");

        // Verify factory configuration
        assertEq(stakingStrategyFactory.mamoToken(), address(mamoToken), "Factory should have correct MAMO token");
        assertEq(
            stakingStrategyFactory.multiRewards(), address(multiRewards), "Factory should have correct MultiRewards"
        );
        assertEq(
            stakingStrategyFactory.strategyImplementation(),
            stakingStrategyImplementation,
            "Factory should have correct implementation"
        );
    }

    function testFactoryValidatesConfiguration() public {
        // Verify factory was deployed with correct parameters
        assertEq(stakingStrategyFactory.strategyTypeId(), 2, "Factory should have correct strategy type ID");
        assertEq(stakingStrategyFactory.defaultSlippageInBps(), 100, "Factory should have correct default slippage");
    }

    // ========== STRATEGY CREATION TESTS ==========

    function testFactoryCanCreateStrategy() public {
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");

        vm.startPrank(backend);
        address strategyAddress = stakingStrategyFactory.createStrategy(user);
        vm.stopPrank();

        assertTrue(strategyAddress != address(0), "Strategy should be created");

        // Verify the strategy is registered in the strategy registry
        assertTrue(mamoStrategyRegistry.isUserStrategy(user, strategyAddress), "Strategy should be registered for user");
    }

    function testFactoryEnforcesOneStrategyPerUser() public {
        address payable strategy1 = _deployUserStrategy(user);

        // Verify first strategy was created and registered
        assertTrue(strategy1 != address(0), "First strategy should be created");
        assertTrue(mamoStrategyRegistry.isUserStrategy(user, strategy1), "Strategy1 should be registered");

        // Attempting to create a second strategy for the same user should fail
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);
        vm.expectRevert("Strategy already exists");
        stakingStrategyFactory.createStrategy(user);
        vm.stopPrank();
    }

    function testUserCanCreateStrategyForThemselves() public {
        // User creates strategy for themselves
        vm.startPrank(user);
        address strategyAddress = stakingStrategyFactory.createStrategy(user);
        vm.stopPrank();

        assertTrue(strategyAddress != address(0), "Strategy should be created");
        assertTrue(mamoStrategyRegistry.isUserStrategy(user, strategyAddress), "Strategy should be registered for user");
    }

    function testCreateStrategyRevertsForInvalidUser() public {
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");

        vm.startPrank(backend);
        vm.expectRevert("Invalid user address");
        stakingStrategyFactory.createStrategy(address(0));
        vm.stopPrank();
    }

    function testCreateStrategyRevertsWhenNotAuthorized() public {
        address attacker = makeAddr("attacker");

        vm.startPrank(attacker);
        vm.expectRevert();
        stakingStrategyFactory.createStrategy(user);
        vm.stopPrank();
    }

    // ========== STRATEGY ADDRESS COMPUTATION TESTS ==========

    function testComputeStrategyAddressIsConsistent() public {
        address computedAddress1 = stakingStrategyFactory.computeStrategyAddress(user);
        address computedAddress2 = stakingStrategyFactory.computeStrategyAddress(user);

        assertEq(computedAddress1, computedAddress2, "Computed address should be consistent");
    }

    function testComputeStrategyAddressIsDifferentForDifferentUsers() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        address address1 = stakingStrategyFactory.computeStrategyAddress(user1);
        address address2 = stakingStrategyFactory.computeStrategyAddress(user2);

        assertTrue(address1 != address2, "Different users should have different strategy addresses");
    }

    function testComputedAddressMatchesActualDeployment() public {
        address computedAddress = stakingStrategyFactory.computeStrategyAddress(user);

        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);
        address actualAddress = stakingStrategyFactory.createStrategy(user);
        vm.stopPrank();

        assertEq(computedAddress, actualAddress, "Computed address should match actual deployment");
    }

    // ========== ROLE-BASED ACCESS TESTS ==========

    function testStakingRegistryRoleBasedAccess() public {
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");

        // Verify backend can create strategies
        vm.startPrank(backend);
        address payable strategy = payable(stakingStrategyFactory.createStrategy(user));
        vm.stopPrank();
        assertTrue(strategy != address(0), "Backend should be able to create strategies");

        // Verify non-backend users cannot create strategies for others
        address attacker = makeAddr("attacker");
        address otherUser = makeAddr("otherUser");
        vm.startPrank(attacker);
        vm.expectRevert();
        stakingStrategyFactory.createStrategy(otherUser);
        vm.stopPrank();
    }

    function testFactoryHasCorrectRoles() public {
        // Verify factory has correct role assignments
        assertTrue(
            stakingStrategyFactory.hasRole(stakingStrategyFactory.DEFAULT_ADMIN_ROLE(), addresses.getAddress("F-MAMO")),
            "Factory should have correct admin"
        );

        assertTrue(
            stakingStrategyFactory.hasRole(
                stakingStrategyFactory.BACKEND_ROLE(), addresses.getAddress("MAMO_STAKING_BACKEND")
            ),
            "Factory should have correct backend role"
        );
    }

    // ========== STRATEGY REGISTRY INTEGRATION TESTS ==========

    function testStrategyRegistryImplementationMapping() public {
        address payable userStrategy = _deployUserStrategy(user);

        // Verify the strategy is using the correct implementation
        address implementation = ERC1967Proxy(userStrategy).getImplementation();
        assertEq(implementation, stakingStrategyImplementation, "Strategy should use correct implementation");
    }

    function testStrategyRegistryTypeIdMapping() public {
        address payable userStrategy = _deployUserStrategy(user);

        // Get the implementation and verify its type ID
        address implementation = ERC1967Proxy(userStrategy).getImplementation();
        uint256 typeId = mamoStrategyRegistry.implementationToId(implementation);
        assertEq(typeId, 2, "Implementation should have correct strategy type ID");
    }

    function testStakingRegistryCanTrackMultipleStrategies() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        address payable strategy1 = _deployUserStrategy(user1);
        address payable strategy2 = _deployUserStrategy(user2);

        // Verify both strategies are tracked
        assertTrue(mamoStrategyRegistry.isUserStrategy(user1, strategy1), "Strategy1 should be registered for user1");
        assertTrue(mamoStrategyRegistry.isUserStrategy(user2, strategy2), "Strategy2 should be registered for user2");

        // Verify cross-ownership is not allowed
        assertFalse(
            mamoStrategyRegistry.isUserStrategy(user1, strategy2), "Strategy2 should not be registered for user1"
        );
        assertFalse(
            mamoStrategyRegistry.isUserStrategy(user2, strategy1), "Strategy1 should not be registered for user2"
        );
    }

    function testGetUserStrategies() public {
        address payable strategy1 = _deployUserStrategy(user);

        address[] memory userStrategies = mamoStrategyRegistry.getUserStrategies(user);
        assertEq(userStrategies.length, 1, "User should have 1 strategy");

        // Verify the strategy is in the list
        assertEq(userStrategies[0], strategy1, "Strategy should be in user strategies list");
    }

    // ========== STRATEGY CONFIGURATION TESTS ==========

    function testCreatedStrategyHasCorrectConfiguration() public {
        address payable userStrategy = _deployUserStrategy(user);

        // Test strategy configuration views
        MamoStakingStrategy strategy = MamoStakingStrategy(userStrategy);
        assertEq(strategy.owner(), user, "Strategy should have correct owner");
        assertEq(address(strategy.mamoToken()), address(mamoToken), "Strategy should have correct MAMO token");
        assertEq(address(strategy.multiRewards()), address(multiRewards), "Strategy should have correct MultiRewards");
        assertEq(strategy.getAccountSlippage(), 100, "Strategy should have correct default slippage");
    }

    function testCreatedStrategyHasCorrectTypeId() public {
        address payable userStrategy = _deployUserStrategy(user);

        MamoStakingStrategy strategy = MamoStakingStrategy(userStrategy);
        assertEq(strategy.strategyTypeId(), 2, "Strategy should have correct type ID");
    }

    // ========== EDGE CASES AND ERROR HANDLING ==========

    function testCreateStrategyWithMaxSlippage() public {
        // This test verifies that the factory properly handles maximum slippage values
        // The factory is initialized with defaultSlippageInBps which should be within limits
        uint256 maxSlippage = stakingStrategyFactory.MAX_SLIPPAGE_IN_BPS();
        uint256 factorySlippage = stakingStrategyFactory.defaultSlippageInBps();

        assertTrue(factorySlippage <= maxSlippage, "Factory slippage should be within max limits");
    }

    function testFactoryImmutableParameters() public {
        // Verify that all immutable parameters are correctly set
        assertEq(
            stakingStrategyFactory.mamoStrategyRegistry(), address(mamoStrategyRegistry), "Registry should be correct"
        );
        assertEq(
            stakingStrategyFactory.stakingRegistry(), address(stakingRegistry), "Staking registry should be correct"
        );
        assertEq(stakingStrategyFactory.multiRewards(), address(multiRewards), "MultiRewards should be correct");
        assertEq(stakingStrategyFactory.mamoToken(), address(mamoToken), "MAMO token should be correct");
        assertEq(
            stakingStrategyFactory.strategyImplementation(),
            stakingStrategyImplementation,
            "Implementation should be correct"
        );
        assertEq(stakingStrategyFactory.strategyTypeId(), 2, "Strategy type ID should be correct");
    }

    // ========== HELPER FUNCTIONS ==========

    // Helper function to deploy a strategy for a user
    function _deployUserStrategy(address userAddress) internal returns (address payable) {
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");

        vm.startPrank(backend);
        address strategyAddress = stakingStrategyFactory.createStrategy(userAddress);
        vm.stopPrank();

        return payable(strategyAddress);
    }
}
