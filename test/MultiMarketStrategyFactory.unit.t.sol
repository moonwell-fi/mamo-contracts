// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoMultiMarketStrategy} from "@contracts/MamoMultiMarketStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {MarketRegistry} from "@contracts/MarketRegistry.sol";
import {MultiMarketStrategyFactory} from "@contracts/MultiMarketStrategyFactory.sol";

import {Test} from "@forge-std/Test.sol";
import {MarketType} from "@interfaces/IMarketRegistry.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";

contract MultiMarketStrategyFactoryUnitTest is Test {
    address public admin = makeAddr("admin");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");
    address public token = makeAddr("token");
    address public slippagePriceChecker = makeAddr("slippagePriceChecker");
    address public feeRecipient = makeAddr("feeRecipient");

    address public mTokenMarket = makeAddr("mToken");
    address public vaultMarket = makeAddr("vault");

    MamoStrategyRegistry public registry;
    MarketRegistry public marketRegistry;
    MamoMultiMarketStrategy public implementation;
    address public registryAddr;
    uint256 public strategyTypeId;

    /// @dev Hoisted: a call in ARGUMENT position (registry.BACKEND_ROLE()) is evaluated first and
    ///      consumes a pending one-shot vm.prank, so the guarded call would run unpranked.
    bytes32 public backendRole;

    function setUp() public {
        registry = new MamoStrategyRegistry(admin, backend, guardian);
        registryAddr = address(registry);
        backendRole = registry.BACKEND_ROLE();
        marketRegistry = new MarketRegistry(admin, backend, guardian);

        implementation = new MamoMultiMarketStrategy();
        vm.prank(admin);
        strategyTypeId = registry.whitelistImplementation(address(implementation), 0);

        // Register 2 markets for token
        vm.startPrank(backend);
        marketRegistry.addMarket(token, mTokenMarket, MarketType.MTOKEN);
        marketRegistry.addMarket(token, vaultMarket, MarketType.ERC4626);
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
        address _token,
        address _slippagePriceChecker,
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
            _token,
            _slippagePriceChecker,
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
            token,
            slippagePriceChecker,
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

    /// @dev A factory that can actually register the strategies it creates.
    function _createGrantedFactory() internal returns (MultiMarketStrategyFactory factory) {
        factory = _createDefaultFactory();
        vm.prank(admin);
        registry.grantRole(backendRole, address(factory));
    }

    // ==================== CONSTRUCTOR SUCCESS ====================

    function testConstructorSetsImmutables() public {
        MultiMarketStrategyFactory factory = _createDefaultFactory();

        assertEq(factory.mamoStrategyRegistry(), registryAddr);
        assertEq(factory.token(), token);
        assertEq(factory.slippagePriceChecker(), slippagePriceChecker);
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(factory.marketRegistry(), address(marketRegistry));
        assertEq(factory.strategyTypeId(), strategyTypeId);
        assertEq(factory.hookGasLimit(), 100000);
        assertEq(factory.allowedSlippageInBps(), 100);
        assertEq(factory.compoundFee(), 500);
    }

    /// @notice MOO-725(c): the implementation is read from the registry, never pinned.
    function testStrategyImplementationResolvesFromRegistry() public {
        MultiMarketStrategyFactory factory = _createDefaultFactory();
        assertEq(factory.strategyImplementation(), address(implementation));
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
            token,
            slippagePriceChecker,
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
            address(0),
            slippagePriceChecker,
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
            token,
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
            token,
            slippagePriceChecker,
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
            token,
            slippagePriceChecker,
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
            token,
            slippagePriceChecker,
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
            token,
            slippagePriceChecker,
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
            token,
            slippagePriceChecker,
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
            token,
            slippagePriceChecker,
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
            token,
            slippagePriceChecker,
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

    function testRevertSplitsDontSumToTotal() public {
        uint256[] memory badSplits = new uint256[](2);
        badSplits[0] = 5000;
        badSplits[1] = 4000; // total = 9000

        vm.expectRevert("Splits must add up to 10000");
        _createFactory(
            registryAddr,
            token,
            slippagePriceChecker,
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

    function testRevertMoreSplitsThanMarkets() public {
        uint256[] memory tooManySplits = new uint256[](3);
        tooManySplits[0] = 5000;
        tooManySplits[1] = 4000;
        tooManySplits[2] = 1000;

        MultiMarketStrategyFactory factory = _createFactory(
            registryAddr,
            token,
            slippagePriceChecker,
            feeRecipient,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            tooManySplits
        );

        vm.expectRevert("Split count exceeds market count");
        vm.prank(backend);
        factory.createStrategyForUser(makeAddr("user"));
    }

    function testSlippageAtMaxBoundary() public {
        MultiMarketStrategyFactory factory = _createFactory(
            registryAddr,
            token,
            slippagePriceChecker,
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
            token,
            slippagePriceChecker,
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

    // ==================== CREATE STRATEGY ====================

    function testCreateStrategyForSelf() public {
        MultiMarketStrategyFactory factory = _createGrantedFactory();

        address user = makeAddr("user");
        vm.prank(user);
        address strategy = factory.createStrategyForUser(user);

        assertTrue(registry.isUserStrategy(user, strategy), "strategy registered for user");
        assertEq(MamoMultiMarketStrategy(payable(strategy)).marketSplitBps(mTokenMarket), 6000);
        assertEq(MamoMultiMarketStrategy(payable(strategy)).marketSplitBps(vaultMarket), 4000);
    }

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

    // ==================== MOO-725: ROUTINE OPS MUST NOT BRICK THE FACTORY ====================

    /// @notice MOO-725(a): registering a new market must not brick every existing factory.
    ///         The new market simply gets a zero allocation until the split config is updated.
    function testAddMarketThenCreateStillWorks() public {
        MultiMarketStrategyFactory factory = _createGrantedFactory();

        address newMarket = makeAddr("newVault");
        vm.prank(backend);
        marketRegistry.addMarket(token, newMarket, MarketType.ERC4626);

        address user = makeAddr("userAfterAddMarket");
        vm.prank(backend);
        address strategy = factory.createStrategyForUser(user);

        assertTrue(registry.isUserStrategy(user, strategy), "strategy created after addMarket");
        assertEq(MamoMultiMarketStrategy(payable(strategy)).marketSplitBps(mTokenMarket), 6000);
        assertEq(MamoMultiMarketStrategy(payable(strategy)).marketSplitBps(vaultMarket), 4000);
        assertEq(MamoMultiMarketStrategy(payable(strategy)).marketSplitBps(newMarket), 0, "new market unallocated");
    }

    /// @notice MOO-725(b): retiring a market is the documented lifecycle. After the operator
    ///         re-points the allocation, creation must work again — the inactive registry entry
    ///         is skipped, not rejected.
    function testDeactivateMarketThenCreateStillWorks() public {
        MultiMarketStrategyFactory factory = _createGrantedFactory();

        vm.prank(backend);
        marketRegistry.deactivateMarket(token, vaultMarket);

        uint256[] memory newSplits = new uint256[](2);
        newSplits[0] = 10000;
        newSplits[1] = 0;
        vm.prank(backend);
        factory.setDefaultSplitBps(newSplits);

        address user = makeAddr("userAfterDeactivate");
        vm.prank(backend);
        address strategy = factory.createStrategyForUser(user);

        assertTrue(registry.isUserStrategy(user, strategy), "strategy created after deactivateMarket");
        assertEq(MamoMultiMarketStrategy(payable(strategy)).marketSplitBps(mTokenMarket), 10000);
        assertEq(MamoMultiMarketStrategy(payable(strategy)).marketSplitBps(vaultMarket), 0);
    }

    /// @notice An inactive market may not carry an allocation — that would silently under-allocate.
    function testRevertCreateWhenInactiveMarketStillAllocated() public {
        MultiMarketStrategyFactory factory = _createGrantedFactory();

        vm.prank(backend);
        marketRegistry.deactivateMarket(token, vaultMarket);

        vm.expectRevert("Inactive market must have zero split");
        vm.prank(backend);
        factory.createStrategyForUser(makeAddr("userStaleSplits"));
    }

    /// @notice MOO-725(c): an implementation rollout must not take creation offline.
    function testWhitelistNewImplementationThenCreateStillWorks() public {
        MultiMarketStrategyFactory factory = _createGrantedFactory();

        MamoMultiMarketStrategy newImplementation = new MamoMultiMarketStrategy();
        vm.prank(admin);
        registry.whitelistImplementation(address(newImplementation), strategyTypeId);

        assertEq(factory.strategyImplementation(), address(newImplementation), "factory follows the registry");

        address user = makeAddr("userAfterUpgrade");
        vm.prank(backend);
        address strategy = factory.createStrategyForUser(user);

        assertTrue(registry.isUserStrategy(user, strategy), "strategy created after implementation rollout");
        assertEq(
            ERC1967Proxy(payable(strategy)).getImplementation(),
            address(newImplementation),
            "proxy points at the new implementation"
        );
    }

    // ==================== MOO-732: BACKEND IS A ROLE, NOT A PINNED ADDRESS ====================

    function testBackendRoleHolderCanCreateForAnyUser() public {
        MultiMarketStrategyFactory factory = _createGrantedFactory();

        vm.prank(backend);
        address strategy = factory.createStrategyForUser(makeAddr("someUser"));
        assertTrue(strategy != address(0));
    }

    /// @notice After a key rotation the retired key loses access and the new key gains it —
    ///         both at once, with no factory redeployment.
    function testBackendRotationRevokesOldAndEnablesNew() public {
        MultiMarketStrategyFactory factory = _createGrantedFactory();

        address newBackend = makeAddr("newBackend");
        vm.startPrank(admin);
        registry.grantRole(backendRole, newBackend);
        registry.revokeRole(backendRole, backend);
        vm.stopPrank();

        vm.prank(backend);
        vm.expectRevert("Only backend or user can create strategy");
        factory.createStrategyForUser(makeAddr("victimUser"));

        vm.prank(newBackend);
        address strategy = factory.createStrategyForUser(makeAddr("rotatedUser"));
        assertTrue(strategy != address(0), "new backend can onboard");
    }

    // ==================== SPLIT CONFIG SETTER ====================

    function testSetDefaultSplitBps() public {
        MultiMarketStrategyFactory factory = _createDefaultFactory();

        uint256[] memory newSplits = new uint256[](2);
        newSplits[0] = 2500;
        newSplits[1] = 7500;

        vm.prank(backend);
        factory.setDefaultSplitBps(newSplits);

        uint256[] memory stored = factory.getDefaultSplitBps();
        assertEq(stored.length, 2);
        assertEq(stored[0], 2500);
        assertEq(stored[1], 7500);
    }

    function testRevertSetDefaultSplitBpsNotBackend() public {
        MultiMarketStrategyFactory factory = _createDefaultFactory();

        vm.prank(makeAddr("random"));
        vm.expectRevert("Only backend can call");
        factory.setDefaultSplitBps(_defaultSplits());
    }

    function testRevertSetDefaultSplitBpsBadTotal() public {
        MultiMarketStrategyFactory factory = _createDefaultFactory();

        uint256[] memory badSplits = new uint256[](2);
        badSplits[0] = 2500;
        badSplits[1] = 2500;

        vm.prank(backend);
        vm.expectRevert("Splits must add up to 10000");
        factory.setDefaultSplitBps(badSplits);
    }

    // ==================== MOO-734: IMPLEMENTATION IS NOT INITIALIZABLE ====================

    function testImplementationCannotBeInitialized() public {
        MamoMultiMarketStrategy.InitParams memory params = MamoMultiMarketStrategy.InitParams({
            mamoStrategyRegistry: registryAddr,
            token: token,
            slippagePriceChecker: slippagePriceChecker,
            feeRecipient: feeRecipient,
            strategyTypeId: strategyTypeId,
            rewardTokens: new address[](0),
            owner: makeAddr("attacker"),
            hookGasLimit: 100000,
            allowedSlippageInBps: 100,
            compoundFee: 500,
            marketRegistry: address(marketRegistry),
            defaultSplitBps: _defaultSplits()
        });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(params);

        assertEq(implementation.owner(), address(0), "implementation stays unowned");
    }
}
