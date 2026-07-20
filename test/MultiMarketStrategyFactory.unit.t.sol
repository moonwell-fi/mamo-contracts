// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MarketRegistry} from "@contracts/MarketRegistry.sol";
import {MultiMarketStrategyFactory} from "@contracts/MultiMarketStrategyFactory.sol";

import {Test} from "@forge-std/Test.sol";
import {MarketType} from "@interfaces/IMarketRegistry.sol";

contract MultiMarketStrategyFactoryUnitTest is Test {
    address public admin = makeAddr("admin");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");
    address public token = makeAddr("token");
    address public slippagePriceChecker = makeAddr("slippagePriceChecker");
    address public implementation = makeAddr("implementation");
    address public feeRecipient = makeAddr("feeRecipient");

    MarketRegistry public marketRegistry;
    address public registryAddr;
    uint256 public strategyTypeId = 1;

    function setUp() public {
        registryAddr = makeAddr("registry");
        marketRegistry = new MarketRegistry(admin, backend, guardian);

        // Register 2 markets for token
        vm.startPrank(backend);
        marketRegistry.addMarket(token, makeAddr("mToken"), MarketType.MTOKEN);
        marketRegistry.addMarket(token, makeAddr("vault"), MarketType.ERC4626);
        vm.stopPrank();
    }

    function _defaultSplits() internal pure returns (uint256[] memory) {
        uint256[] memory splits = new uint256[](2);
        splits[0] = 6000;
        splits[1] = 4000;
        return splits;
    }

    function _createFactory(
        address _registry,
        address _backend,
        address _token,
        address _slippagePriceChecker,
        address _implementation,
        address _feeRecipient,
        address _marketRegistry,
        uint256 _strategyTypeId,
        uint256 _hookGasLimit,
        uint256 _allowedSlippageInBps,
        uint256 _compoundFee,
        address[] memory _rewardTokens,
        uint256[] memory _defaultSplitBps
    ) internal returns (MultiMarketStrategyFactory) {
        return new MultiMarketStrategyFactory(
            _registry,
            _backend,
            _token,
            _slippagePriceChecker,
            _implementation,
            _feeRecipient,
            _marketRegistry,
            _strategyTypeId,
            _hookGasLimit,
            _allowedSlippageInBps,
            _compoundFee,
            _rewardTokens,
            _defaultSplitBps
        );
    }

    function _createDefaultFactory() internal returns (MultiMarketStrategyFactory) {
        return _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    // ==================== CONSTRUCTOR SUCCESS ====================

    function testConstructorSetsImmutables() public {
        MultiMarketStrategyFactory factory = _createDefaultFactory();

        assertEq(factory.mamoStrategyRegistry(), registryAddr);
        assertEq(factory.mamoBackend(), backend);
        assertEq(factory.token(), token);
        assertEq(factory.slippagePriceChecker(), slippagePriceChecker);
        assertEq(factory.strategyImplementation(), implementation);
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(factory.marketRegistry(), address(marketRegistry));
        assertEq(factory.strategyTypeId(), strategyTypeId);
        assertEq(factory.hookGasLimit(), 100000);
        assertEq(factory.allowedSlippageInBps(), 100);
        assertEq(factory.compoundFee(), 500);
    }

    function testConstructorStoresDefaultSplits() public {
        MultiMarketStrategyFactory factory = _createDefaultFactory();

        uint256[] memory splits = factory.getDefaultSplitBps();
        assertEq(splits.length, 2);
        assertEq(splits[0], 6000);
        assertEq(splits[1], 4000);
    }

    // ==================== CONSTRUCTOR REVERTS ====================

    function testRevertZeroRegistry() public {
        vm.expectRevert("Invalid mamoStrategyRegistry address");
        _createFactory(
            address(0),
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertZeroBackend() public {
        vm.expectRevert("Invalid mamoBackend address");
        _createFactory(
            registryAddr,
            address(0),
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertZeroToken() public {
        vm.expectRevert("Invalid token address");
        _createFactory(
            registryAddr,
            backend,
            address(0),
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertZeroSlippagePriceChecker() public {
        vm.expectRevert("Invalid slippagePriceChecker address");
        _createFactory(
            registryAddr,
            backend,
            token,
            address(0),
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertZeroImplementation() public {
        vm.expectRevert("Invalid strategyImplementation address");
        _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            address(0),
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertZeroFeeRecipient() public {
        vm.expectRevert("Invalid feeRecipient address");
        _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            address(0),
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertZeroMarketRegistry() public {
        vm.expectRevert("Invalid marketRegistry address");
        _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(0),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertZeroStrategyTypeId() public {
        vm.expectRevert("Strategy type id not set");
        _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            0,
            100000,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertZeroHookGasLimit() public {
        vm.expectRevert("Invalid hook gas limit");
        _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            0,
            100,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertSlippageExceedsMax() public {
        vm.expectRevert("Slippage exceeds maximum");
        _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            1001,
            500,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertCompoundFeeExceedsMax() public {
        vm.expectRevert("Compound fee exceeds maximum");
        _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            1001,
            new address[](0),
            _defaultSplits()
        );
    }

    function testRevertEmptySplits() public {
        vm.expectRevert("At least one split required");
        _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            new uint256[](0)
        );
    }

    function testRevertSplitCountMismatchWithMarketCount() public {
        // Only 1 split but 2 markets in registry — validated at createStrategyForUser time
        uint256[] memory wrongSplits = new uint256[](1);
        wrongSplits[0] = 10000;

        MultiMarketStrategyFactory factory = _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            wrongSplits
        );

        vm.expectRevert("Split count must match market count");
        vm.prank(backend);
        factory.createStrategyForUser(makeAddr("user"));
    }

    function testRevertSplitsDontSumToTotal() public {
        uint256[] memory badSplits = new uint256[](2);
        badSplits[0] = 5000;
        badSplits[1] = 4000; // total = 9000

        vm.expectRevert("Splits must add up to 10000");
        _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            badSplits
        );
    }

    function testSlippageAtMaxBoundary() public {
        MultiMarketStrategyFactory factory = _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            1000,
            500,
            new address[](0),
            _defaultSplits()
        );
        assertEq(factory.allowedSlippageInBps(), 1000);
    }

    function testCompoundFeeAtMaxBoundary() public {
        MultiMarketStrategyFactory factory = _createFactory(
            registryAddr,
            backend,
            token,
            slippagePriceChecker,
            implementation,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            1000,
            new address[](0),
            _defaultSplits()
        );
        assertEq(factory.compoundFee(), 1000);
    }

    // ==================== CREATE STRATEGY REVERTS ====================

    function testRevertCreateStrategyZeroUser() public {
        MultiMarketStrategyFactory factory = _createDefaultFactory();

        vm.expectRevert("Invalid user address");
        factory.createStrategyForUser(address(0));
    }

    function testRevertCreateStrategyUnauthorized() public {
        MultiMarketStrategyFactory factory = _createDefaultFactory();

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert("Only backend or user can create strategy");
        factory.createStrategyForUser(makeAddr("otherUser"));
    }
}
