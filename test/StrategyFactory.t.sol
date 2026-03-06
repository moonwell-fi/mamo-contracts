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
        address token;
        address slippagePriceChecker;
        address feeRecipient;
        uint256 strategyTypeId;
        address[] rewardTokens;
        address owner;
        uint256 hookGasLimit;
        uint256 allowedSlippageInBps;
        uint256 compoundFee;
        address marketRegistry;
        uint256[] defaultSplitBps;
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
    address public token;
    address public slippagePriceChecker;
    address public feeRecipient;
    address public marketRegistry;
    address public user;

    // Test parameters
    uint256 public constant STRATEGY_TYPE_ID = 1;
    uint256 public constant HOOK_GAS_LIMIT = 500000;
    uint256 public constant ALLOWED_SLIPPAGE_IN_BPS = 100; // 1%
    uint256 public constant COMPOUND_FEE = 200; // 2%
    address[] public rewardTokens;
    uint256[] public defaultSplitBps;

    function setUp() public {
        // Create test addresses
        mamoBackend = makeAddr("mamoBackend");
        token = makeAddr("token");
        slippagePriceChecker = makeAddr("slippagePriceChecker");
        feeRecipient = makeAddr("feeRecipient");
        marketRegistry = makeAddr("marketRegistry");
        user = makeAddr("user");

        // Setup reward tokens
        rewardTokens.push(makeAddr("rewardToken1"));
        rewardTokens.push(makeAddr("rewardToken2"));

        // Setup default splits
        defaultSplitBps.push(6000);
        defaultSplitBps.push(4000);

        // Deploy mock contracts
        mockRegistry = new MockMamoStrategyRegistry();
        mockStrategyImpl = new MockERC20MoonwellMorphoStrategy();

        // Whitelist the implementation in the mock registry
        mockRegistry.setWhitelistedImplementation(address(mockStrategyImpl), true);

        // Deploy the factory
        factory = new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    // ==================== CONSTRUCTOR TESTS ====================

    function testConstructorSuccess() public view {
        assertEq(factory.mamoStrategyRegistry(), address(mockRegistry));
        assertEq(factory.mamoBackend(), mamoBackend);
        assertEq(factory.token(), token);
        assertEq(factory.slippagePriceChecker(), slippagePriceChecker);
        assertEq(factory.strategyImplementation(), address(mockStrategyImpl));
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(factory.marketRegistry(), marketRegistry);
        assertEq(factory.strategyTypeId(), STRATEGY_TYPE_ID);
        assertEq(factory.hookGasLimit(), HOOK_GAS_LIMIT);
        assertEq(factory.allowedSlippageInBps(), ALLOWED_SLIPPAGE_IN_BPS);
        assertEq(factory.compoundFee(), COMPOUND_FEE);

        assertEq(factory.rewardTokens(0), rewardTokens[0]);
        assertEq(factory.rewardTokens(1), rewardTokens[1]);
    }

    function testRevertIfInvalidMamoStrategyRegistryAddress() public {
        vm.expectRevert("Invalid mamoStrategyRegistry address");
        new StrategyFactory(
            address(0),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfInvalidMamoBackendAddress() public {
        vm.expectRevert("Invalid mamoBackend address");
        new StrategyFactory(
            address(mockRegistry),
            address(0),
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfInvalidTokenAddress() public {
        vm.expectRevert("Invalid token address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            address(0),
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfInvalidSlippagePriceCheckerAddress() public {
        vm.expectRevert("Invalid slippagePriceChecker address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            address(0),
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfInvalidStrategyImplementationAddress() public {
        vm.expectRevert("Invalid strategyImplementation address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(0),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfInvalidFeeRecipientAddress() public {
        vm.expectRevert("Invalid feeRecipient address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            address(0),
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfInvalidMarketRegistryAddress() public {
        vm.expectRevert("Invalid marketRegistry address");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            address(0),
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfInvalidSplitParameters() public {
        uint256[] memory badSplits = new uint256[](2);
        badSplits[0] = 5000;
        badSplits[1] = 4000; // Total 9000, not 10000

        vm.expectRevert("Splits must add up to 10000");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            badSplits
        );
    }

    function testRevertIfInvalidStrategyTypeId() public {
        vm.expectRevert("Strategy type id not set");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            0,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfInvalidHookGasLimit() public {
        vm.expectRevert("Invalid hook gas limit");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            0,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfSlippageExceedsMaximum() public {
        vm.expectRevert("Slippage exceeds maximum");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            1001,
            COMPOUND_FEE,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testRevertIfCompoundFeeExceedsMaximum() public {
        vm.expectRevert("Compound fee exceeds maximum");
        new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            1001,
            rewardTokens,
            defaultSplitBps
        );
    }

    function testConstructorWithEmptyRewardTokens() public {
        address[] memory emptyRewardTokens = new address[](0);

        StrategyFactory factoryWithEmptyRewards = new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            ALLOWED_SLIPPAGE_IN_BPS,
            COMPOUND_FEE,
            emptyRewardTokens,
            defaultSplitBps
        );

        assertTrue(address(factoryWithEmptyRewards) != address(0));
    }

    // ==================== createStrategyForUser TESTS ====================

    function testCreateStrategyForUserSuccess() public {
        vm.expectEmit(true, false, false, false);
        emit StrategyFactory.StrategyCreated(user, address(0));

        vm.prank(mamoBackend);
        address strategyAddress = factory.createStrategyForUser(user);

        assertTrue(strategyAddress != address(0), "Strategy address should not be zero");
        assertTrue(mockRegistry.userStrategies(user, strategyAddress), "Strategy should be registered for user");
    }

    function testCreateStrategyForUserInitializesCorrectly() public {
        vm.prank(mamoBackend);
        address strategyAddress = factory.createStrategyForUser(user);

        MockERC20MoonwellMorphoStrategy strategy = MockERC20MoonwellMorphoStrategy(strategyAddress);

        assertTrue(strategy.initialized(), "Strategy should be initialized");
        assertEq(strategy.owner(), user, "Strategy owner should be set correctly");
        assertEq(strategy.mamoStrategyRegistry(), address(mockRegistry), "Registry should be set correctly");
        assertEq(strategy.strategyTypeId(), STRATEGY_TYPE_ID, "Strategy type ID should be set correctly");
    }

    function testCreateStrategyForUserMultipleUsers() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        vm.startPrank(mamoBackend);
        address strategy1 = factory.createStrategyForUser(user1);
        address strategy2 = factory.createStrategyForUser(user2);
        vm.stopPrank();

        assertTrue(strategy1 != strategy2, "Strategies for different users should be different");
        assertTrue(mockRegistry.userStrategies(user1, strategy1), "Strategy 1 should be registered for user 1");
        assertTrue(mockRegistry.userStrategies(user2, strategy2), "Strategy 2 should be registered for user 2");
        assertFalse(mockRegistry.userStrategies(user1, strategy2), "User 1 should not own strategy 2");
        assertFalse(mockRegistry.userStrategies(user2, strategy1), "User 2 should not own strategy 1");
    }

    function testCreateStrategyForUserMultipleStrategiesPerUser() public {
        vm.startPrank(mamoBackend);
        address strategy1 = factory.createStrategyForUser(user);
        address strategy2 = factory.createStrategyForUser(user);
        vm.stopPrank();

        assertTrue(strategy1 != strategy2, "Multiple strategies for same user should be different");
        assertTrue(mockRegistry.userStrategies(user, strategy1), "Strategy 1 should be registered for user");
        assertTrue(mockRegistry.userStrategies(user, strategy2), "Strategy 2 should be registered for user");
    }

    function testRevertWhenRegistryAddStrategyFails() public {
        mockRegistry.setShouldRevertOnAddStrategy(true);

        vm.expectRevert("Registry add strategy failed");
        vm.prank(mamoBackend);
        factory.createStrategyForUser(user);
    }

    // ==================== ACCESS CONTROL TESTS ====================

    function testCreateStrategyForUserAsUser() public {
        vm.prank(user);
        address strategyAddress = factory.createStrategyForUser(user);

        assertTrue(strategyAddress != address(0), "Strategy should be created");
        assertTrue(mockRegistry.userStrategies(user, strategyAddress), "Strategy should be registered for user");
    }

    function testRevertCreateStrategyForUserAsNonBackendNonUser() public {
        address nonAuthorized = makeAddr("nonAuthorized");

        vm.expectRevert("Only backend or user can create strategy");
        vm.prank(nonAuthorized);
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
        vm.expectRevert("Invalid user address");
        vm.prank(mamoBackend);
        factory.createStrategyForUser(address(0));
    }

    function testCreateStrategyWithMaximumValidParameters() public {
        StrategyFactory maxParamsFactory = new StrategyFactory(
            address(mockRegistry),
            mamoBackend,
            token,
            slippagePriceChecker,
            address(mockStrategyImpl),
            feeRecipient,
            marketRegistry,
            STRATEGY_TYPE_ID,
            HOOK_GAS_LIMIT,
            1000, // MAX_SLIPPAGE_IN_BPS
            1000, // MAX_COMPOUND_FEE
            rewardTokens,
            defaultSplitBps
        );

        vm.prank(mamoBackend);
        address strategy = maxParamsFactory.createStrategyForUser(user);
        assertTrue(strategy != address(0), "Strategy should be created with maximum valid parameters");
    }
}
