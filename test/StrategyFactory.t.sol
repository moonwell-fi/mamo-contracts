// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {StrategyFactory} from "@contracts/StrategyFactory.sol";

import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";

// Mock contracts for testing
contract MockMamoStrategyRegistry {
    mapping(address => bool) public whitelistedImplementations;
    mapping(address => mapping(address => bool)) public userStrategies;

    bool public shouldRevertOnAddStrategy;

    function setWhitelistedImplementation(address implementation, bool whitelisted) external {
        whitelistedImplementations[implementation] = whitelisted;
    }

    function setShouldRevertOnAddStrategy(bool shouldRevert) external {
        shouldRevertOnAddStrategy = shouldRevert;
    }

    function addStrategy(address user, address strategy) external {
        if (shouldRevertOnAddStrategy) {
            revert("Registry add strategy failed");
        }
        userStrategies[user][strategy] = true;
    }
}

contract MockERC20MoonwellMorphoStrategy {
    bool public initialized;
    address public owner;
    address public mamoStrategyRegistry;
    uint256 public strategyTypeId;

    struct InitParams {
        address mamoStrategyRegistry;
        address mamoBackend;
        address mToken;
        address metaMorphoVault;
        address token;
        address slippagePriceChecker;
        address feeRecipient;
        uint256 splitMToken;
        uint256 splitVault;
        uint256 strategyTypeId;
        address[] rewardTokens;
        address owner;
        uint256 hookGasLimit;
        uint256 allowedSlippageInBps;
        uint256 compoundFee;
    }

    function initialize(InitParams memory params) external {
        require(!initialized, "Already initialized");
        initialized = true;
        owner = params.owner;
        mamoStrategyRegistry = params.mamoStrategyRegistry;
        strategyTypeId = params.strategyTypeId;
    }
}

contract StrategyFactoryTest is Test {
    StrategyFactory public factory;
    MockMamoStrategyRegistry public mockRegistry;
    MockERC20MoonwellMorphoStrategy public mockStrategyImpl;

    // Test addresses
    address public mamoBackend;
    address public mToken;
    address public metaMorphoVault;
    address public token;
    address public slippagePriceChecker;
    address public feeRecipient;
    address public user;

    // Test parameters
    uint256 public constant SPLIT_M_TOKEN = 6000; // 60%
    uint256 public constant SPLIT_VAULT = 4000; // 40%
    uint256 public constant STRATEGY_TYPE_ID = 1;
    uint256 public constant HOOK_GAS_LIMIT = 500000;
    uint256 public constant ALLOWED_SLIPPAGE_IN_BPS = 100; // 1%
    uint256 public constant COMPOUND_FEE = 200; // 2%
    address[] public rewardTokens;

    function setUp() public {
        // Create test addresses
        mamoBackend = makeAddr("mamoBackend");
        mToken = makeAddr("mToken");
        metaMorphoVault = makeAddr("metaMorphoVault");
        token = makeAddr("token");
        slippagePriceChecker = makeAddr("slippagePriceChecker");
        feeRecipient = makeAddr("feeRecipient");
        user = makeAddr("user");

        // Setup reward tokens
        rewardTokens.push(makeAddr("rewardToken1"));
        rewardTokens.push(makeAddr("rewardToken2"));

        // Deploy mock contracts
        mockRegistry = new MockMamoStrategyRegistry();
        mockStrategyImpl = new MockERC20MoonwellMorphoStrategy();

        // Whitelist the implementation in the mock registry
        mockRegistry.setWhitelistedImplementation(address(mockStrategyImpl), true);

        // Deploy the factory
        factory = new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    // ==================== CONSTRUCTOR TESTS ====================

    function testConstructorSuccess() public view {
        // Verify all immutable variables are set correctly
        assertEq(factory.mamoStrategyRegistry(), address(mockRegistry));
        assertEq(factory.mamoBackend(), mamoBackend);
        assertEq(factory.mToken(), mToken);
        assertEq(factory.metaMorphoVault(), metaMorphoVault);
        assertEq(factory.token(), token);
        assertEq(factory.slippagePriceChecker(), slippagePriceChecker);
        assertEq(factory.strategyImplementation(), address(mockStrategyImpl));
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(factory.splitMToken(), SPLIT_M_TOKEN);
        assertEq(factory.splitVault(), SPLIT_VAULT);
        assertEq(factory.strategyTypeId(), STRATEGY_TYPE_ID);
        assertEq(factory.hookGasLimit(), HOOK_GAS_LIMIT);
        assertEq(factory.allowedSlippageInBps(), ALLOWED_SLIPPAGE_IN_BPS);
        assertEq(factory.compoundFee(), COMPOUND_FEE);

        // Verify reward tokens are stored correctly
        assertEq(factory.rewardTokens(0), rewardTokens[0]);
        assertEq(factory.rewardTokens(1), rewardTokens[1]);
    }

    function testRevertIfInvalidMamoStrategyRegistryAddress() public {
        vm.expectRevert("Invalid mamoStrategyRegistry address");
        new StrategyFactory(
            address(0), // Invalid address
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidMamoBackendAddress() public {
        vm.expectRevert("Invalid mamoBackend address");
        new StrategyFactory(
            address(mockRegistry),
            address(0), // Invalid address
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidMTokenAddress() public {
        vm.expectRevert("Invalid mToken address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            address(0), // Invalid address
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidMetaMorphoVaultAddress() public {
        vm.expectRevert("Invalid metaMorphoVault address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            address(0), // Invalid address
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidTokenAddress() public {
        vm.expectRevert("Invalid token address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            address(0), // Invalid address
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidSlippagePriceCheckerAddress() public {
        vm.expectRevert("Invalid slippagePriceChecker address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            address(0), // Invalid address
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidStrategyImplementationAddress() public {
        vm.expectRevert("Invalid strategyImplementation address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(0), // Invalid address
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidFeeRecipientAddress() public {
        vm.expectRevert("Invalid feeRecipient address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            address(0), // Invalid address
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidSplitParameters() public {
        vm.expectRevert("Split parameters must add up to 10000");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            5000, // These don't add up to 10000
            4000,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidStrategyTypeId() public {
        vm.expectRevert("Strategy type id not set");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            0, // Invalid strategy type ID
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfInvalidHookGasLimit() public {
        vm.expectRevert("Invalid hook gas limit");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            0, // Invalid hook gas limit
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfSlippageExceedsMaximum() public {
        vm.expectRevert("Slippage exceeds maximum");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            1001, // Exceeds MAX_SLIPPAGE_IN_BPS (1000)
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testRevertIfCompoundFeeExceedsMaximum() public {
        vm.expectRevert("Compound fee exceeds maximum");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            1001, // Exceeds MAX_COMPOUND_FEE (1000)
            rewardTokens
        );
    }

    function testRevertIfImplementationNotWhitelisted() public {
        // Deploy a non-whitelisted implementation
        MockERC20MoonwellMorphoStrategy nonWhitelistedImpl = new MockERC20MoonwellMorphoStrategy();

        vm.expectRevert("Implementation not whitelisted");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(nonWhitelistedImpl), // Not whitelisted
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens
        );
    }

    function testConstructorWithEmptyRewardTokens() public {
        address[] memory emptyRewardTokens = new address[](0);

        StrategyFactory factoryWithEmptyRewards = new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            emptyRewardTokens
        );

        // Should not revert and factory should be deployed successfully
        assertTrue(address(factoryWithEmptyRewards) != address(0));
    }

    // ==================== createStrategyForUser TESTS ====================

    function testCreateStrategyForUserSuccess() public {
        // Expect the StrategyCreated event to be emitted
        // Check first indexed parameter (user) but not second (strategy address since we don't know it yet)
        vm.expectEmit(true, false, false, false);
        emit StrategyFactory.StrategyCreated(user, address(0)); // address(0) is placeholder for strategy

        // Call createStrategyForUser
        address strategyAddress = factory.createStrategyForUser(user);

        // Verify strategy was created successfully
        assertTrue(strategyAddress != address(0), "Strategy address should not be zero");

        // Verify the strategy was registered in the mock registry
        assertTrue(mockRegistry.userStrategies(user, strategyAddress), "Strategy should be registered for user");
    }

    function testCreateStrategyForUserInitializesCorrectly() public {
        // Create strategy
        address strategyAddress = factory.createStrategyForUser(user);

        // Cast to the mock strategy to check initialization
        MockERC20MoonwellMorphoStrategy strategy = MockERC20MoonwellMorphoStrategy(strategyAddress);

        // Since we're using a proxy, we need to check the implementation
        // The proxy will forward calls to the implementation
        assertTrue(strategy.initialized(), "Strategy should be initialized");
        assertEq(strategy.owner(), user, "Strategy owner should be set correctly");
        assertEq(strategy.mamoStrategyRegistry(), address(mockRegistry), "Registry should be set correctly");
        assertEq(strategy.strategyTypeId(), STRATEGY_TYPE_ID, "Strategy type ID should be set correctly");
    }

    function testCreateStrategyForUserMultipleUsers() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Create strategies for different users
        address strategy1 = factory.createStrategyForUser(user1);
        address strategy2 = factory.createStrategyForUser(user2);

        // Verify strategies are different
        assertTrue(strategy1 != strategy2, "Strategies for different users should be different");

        // Verify both strategies are registered correctly
        assertTrue(mockRegistry.userStrategies(user1, strategy1), "Strategy 1 should be registered for user 1");
        assertTrue(mockRegistry.userStrategies(user2, strategy2), "Strategy 2 should be registered for user 2");

        // Verify cross-ownership is not set
        assertFalse(mockRegistry.userStrategies(user1, strategy2), "User 1 should not own strategy 2");
        assertFalse(mockRegistry.userStrategies(user2, strategy1), "User 2 should not own strategy 1");
    }

    function testCreateStrategyForUserMultipleStrategiesPerUser() public {
        // Create multiple strategies for the same user
        address strategy1 = factory.createStrategyForUser(user);
        address strategy2 = factory.createStrategyForUser(user);

        // Verify strategies are different
        assertTrue(strategy1 != strategy2, "Multiple strategies for same user should be different");

        // Verify both strategies are registered for the user
        assertTrue(mockRegistry.userStrategies(user, strategy1), "Strategy 1 should be registered for user");
        assertTrue(mockRegistry.userStrategies(user, strategy2), "Strategy 2 should be registered for user");
    }

    function testRevertWhenRegistryAddStrategyFails() public {
        // Set up the mock registry to fail on addStrategy
        mockRegistry.setShouldRevertOnAddStrategy(true);

        // Expect the call to revert with the registry error
        vm.expectRevert("Registry add strategy failed");

        // Try to create a strategy
        factory.createStrategyForUser(user);
    }

    // ==================== CONSTANTS TESTS ====================

    function testConstants() public view {
        assertEq(factory.SPLIT_TOTAL(), 10000, "SPLIT_TOTAL should be 10000");
        assertEq(factory.MAX_SLIPPAGE_IN_BPS(), 1000, "MAX_SLIPPAGE_IN_BPS should be 1000");
        assertEq(factory.MAX_COMPOUND_FEE(), 1000, "MAX_COMPOUND_FEE should be 1000");
    }

    // ==================== EDGE CASES ====================

    function testCreateStrategyWithZeroUserAddress() public {
        // This should work at the factory level - validation happens in the strategy
        address strategy = factory.createStrategyForUser(address(0));
        assertTrue(strategy != address(0), "Strategy should be created even with zero user address");
    }

    function testCreateStrategyWithMaximumValidParameters() public {
        // Test with maximum valid slippage and compound fee
        StrategyFactory maxParamsFactory = new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            mToken,
            metaMorphoVault,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            SPLIT_M_TOKEN,
            SPLIT_VAULT,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            1000, // MAX_SLIPPAGE_IN_BPS
            1000, // MAX_COMPOUND_FEE
            rewardTokens
        );

        address strategy = maxParamsFactory.createStrategyForUser(user);
        assertTrue(strategy != address(0), "Strategy should be created with maximum valid parameters");
    }
}
