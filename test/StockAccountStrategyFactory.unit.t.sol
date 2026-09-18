// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {MockERC20} from "@test/MockERC20.sol";
import {MockGPv2Settlement} from "@test/mocks/MockGPv2Settlement.sol";
import {MockStockAccountRegistry} from "@test/mocks/MockStockAccountRegistry.sol";

contract StockAccountStrategyFactoryUnitTest is Test {
    bytes32 public constant SEPARATOR = keccak256("cow-domain-separator");

    MamoStrategyRegistry public registry;
    MockStockAccountRegistry public stockRegistry;
    MockGPv2Settlement public settlement;
    MockERC20 public usdc;
    MockERC20 public nvda;
    MockERC20 public aapl;

    StockAccountStrategy public implementation;
    StockAccountStrategyFactory public factory;

    address public admin = makeAddr("admin");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");
    address public relayer = makeAddr("relayer");
    address public user = makeAddr("user");
    address public stranger = makeAddr("stranger");
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public strategyTypeId;

    event StrategyCreated(address indexed user, address indexed strategy);

    function setUp() public {
        registry = new MamoStrategyRegistry(admin, backend, guardian);

        usdc = new MockERC20("USD Coin", "USDC");
        nvda = new MockERC20("NVDA Coin", "NVDAc");
        aapl = new MockERC20("AAPL Coin", "AAPLc");

        settlement = new MockGPv2Settlement(SEPARATOR, relayer);

        stockRegistry = new MockStockAccountRegistry();
        stockRegistry.setMaxPositions(10);
        stockRegistry.setMinTargetBps(100);
        _listActive(address(nvda));
        _listActive(address(aapl));

        implementation = new StockAccountStrategy();

        vm.prank(admin);
        strategyTypeId = registry.whitelistImplementation(address(implementation), 0);

        factory = new StockAccountStrategyFactory(
            admin,
            backend,
            address(registry),
            address(stockRegistry),
            address(usdc),
            address(settlement),
            address(implementation),
            strategyTypeId,
            feeRecipient
        );

        bytes32 backendRole = registry.BACKEND_ROLE();

        vm.prank(admin);
        registry.grantRole(backendRole, address(factory));
    }

    function _listActive(address token) internal {
        stockRegistry.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: address(0),
                chainlinkFeed: address(0)
            })
        );
    }

    function _entries(uint16 bpsA, uint16 bpsB)
        internal
        view
        returns (IStockAccountStrategy.BasketEntry[] memory entries)
    {
        entries = new IStockAccountStrategy.BasketEntry[](2);
        entries[0] = IStockAccountStrategy.BasketEntry({token: address(nvda), targetBps: bpsA});
        entries[1] = IStockAccountStrategy.BasketEntry({token: address(aapl), targetBps: bpsB});
    }

    function testConstructorStoresImmutables() public view {
        assertEq(address(factory.mamoStrategyRegistry()), address(registry), "registry");
        assertEq(factory.stockRegistry(), address(stockRegistry), "stock registry");
        assertEq(factory.asset(), address(usdc), "asset");
        assertEq(factory.cowSettlement(), address(settlement), "settlement");
        assertEq(factory.strategyImplementation(), address(implementation), "implementation");
        assertEq(factory.strategyTypeId(), strategyTypeId, "strategy type id");
        assertEq(factory.feeRecipient(), feeRecipient, "fee recipient");
    }

    function testConstructorGrantsRoles() public view {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin), "admin role");
        assertTrue(factory.hasRole(factory.BACKEND_ROLE(), backend), "backend role");
        assertFalse(factory.hasRole(factory.BACKEND_ROLE(), stranger), "stranger has no role");
    }

    function testConstructorRevertsWithZeroAdmin() public {
        vm.expectRevert(StockAccountStrategyFactory.ZeroAddress.selector);
        new StockAccountStrategyFactory(
            address(0),
            backend,
            address(registry),
            address(stockRegistry),
            address(usdc),
            address(settlement),
            address(implementation),
            strategyTypeId,
            feeRecipient
        );
    }

    function testConstructorRevertsWithZeroBackend() public {
        vm.expectRevert(StockAccountStrategyFactory.ZeroAddress.selector);
        new StockAccountStrategyFactory(
            admin,
            address(0),
            address(registry),
            address(stockRegistry),
            address(usdc),
            address(settlement),
            address(implementation),
            strategyTypeId,
            feeRecipient
        );
    }

    function testConstructorRevertsWithZeroMamoStrategyRegistry() public {
        vm.expectRevert(StockAccountStrategyFactory.ZeroAddress.selector);
        new StockAccountStrategyFactory(
            admin,
            backend,
            address(0),
            address(stockRegistry),
            address(usdc),
            address(settlement),
            address(implementation),
            strategyTypeId,
            feeRecipient
        );
    }

    function testConstructorRevertsWithZeroStockRegistry() public {
        vm.expectRevert(StockAccountStrategyFactory.ZeroAddress.selector);
        new StockAccountStrategyFactory(
            admin,
            backend,
            address(registry),
            address(0),
            address(usdc),
            address(settlement),
            address(implementation),
            strategyTypeId,
            feeRecipient
        );
    }

    function testConstructorRevertsWithZeroAsset() public {
        vm.expectRevert(StockAccountStrategyFactory.ZeroAddress.selector);
        new StockAccountStrategyFactory(
            admin,
            backend,
            address(registry),
            address(stockRegistry),
            address(0),
            address(settlement),
            address(implementation),
            strategyTypeId,
            feeRecipient
        );
    }

    function testConstructorRevertsWithZeroSettlement() public {
        vm.expectRevert(StockAccountStrategyFactory.ZeroAddress.selector);
        new StockAccountStrategyFactory(
            admin,
            backend,
            address(registry),
            address(stockRegistry),
            address(usdc),
            address(0),
            address(implementation),
            strategyTypeId,
            feeRecipient
        );
    }

    function testConstructorRevertsWithZeroImplementation() public {
        vm.expectRevert(StockAccountStrategyFactory.ZeroAddress.selector);
        new StockAccountStrategyFactory(
            admin,
            backend,
            address(registry),
            address(stockRegistry),
            address(usdc),
            address(settlement),
            address(0),
            strategyTypeId,
            feeRecipient
        );
    }

    function testConstructorRevertsWithZeroStrategyTypeId() public {
        vm.expectRevert(StockAccountStrategyFactory.StrategyTypeIdNotSet.selector);
        new StockAccountStrategyFactory(
            admin,
            backend,
            address(registry),
            address(stockRegistry),
            address(usdc),
            address(settlement),
            address(implementation),
            0,
            feeRecipient
        );
    }

    function testConstructorRevertsWithZeroFeeRecipient() public {
        vm.expectRevert(StockAccountStrategyFactory.ZeroAddress.selector);
        new StockAccountStrategyFactory(
            admin,
            backend,
            address(registry),
            address(stockRegistry),
            address(usdc),
            address(settlement),
            address(implementation),
            strategyTypeId,
            address(0)
        );
    }

    function testComputeStrategyAddressIsDeterministic() public view {
        assertEq(factory.computeStrategyAddress(user), factory.computeStrategyAddress(user), "stable");
        assertTrue(factory.computeStrategyAddress(user) != factory.computeStrategyAddress(stranger), "per user");
    }

    function testBackendCreatesStrategyForUser() public {
        address predicted = factory.computeStrategyAddress(user);

        vm.expectEmit(true, true, false, false, address(factory));
        emit StrategyCreated(user, predicted);

        vm.prank(backend);
        address strategy = factory.createStrategyForUser(user, _entries(6000, 3000), 1000);

        assertEq(strategy, predicted, "deployed at computed address");

        StockAccountStrategy account = StockAccountStrategy(payable(strategy));
        assertEq(account.owner(), user, "owner");
        assertEq(address(account.asset()), address(usdc), "asset");
        assertEq(address(account.stockRegistry()), address(stockRegistry), "stock registry");
        assertEq(address(account.mamoStrategyRegistry()), address(registry), "mamo registry");
        assertEq(account.strategyTypeId(), strategyTypeId, "strategy type id");
        assertEq(account.cowDomainSeparator(), SEPARATOR, "domain separator");
        assertEq(account.cowVaultRelayer(), relayer, "vault relayer");
        assertEq(account.feeRecipient(), feeRecipient, "fee recipient");
        assertEq(account.lastFeePaid(), block.timestamp, "last fee paid");
        assertEq(
            account.appDataHash(address(nvda)),
            keccak256(bytes(account.appDataDocument(address(nvda)))),
            "app data hash"
        );

        (IStockAccountStrategy.BasketEntry[] memory entries, uint16 cashTargetBps) = account.getBasket();
        assertEq(entries.length, 2, "entries length");
        assertEq(entries[0].token, address(nvda), "first token");
        assertEq(entries[0].targetBps, 6000, "first weight");
        assertEq(entries[1].token, address(aapl), "second token");
        assertEq(entries[1].targetBps, 3000, "second weight");
        assertEq(cashTargetBps, 1000, "cash target");

        assertTrue(registry.isUserStrategy(user, strategy), "registered for user");
    }

    function testUserCreatesStrategyForSelf() public {
        vm.prank(user);
        address strategy = factory.createStrategyForUser(user, _entries(5000, 5000), 0);

        assertEq(strategy, factory.computeStrategyAddress(user), "deployed at computed address");
        assertEq(StockAccountStrategy(payable(strategy)).owner(), user, "owner");
        assertTrue(registry.isUserStrategy(user, strategy), "registered for user");
    }

    function testStrangerCannotCreateStrategy() public {
        vm.prank(stranger);
        vm.expectRevert(StockAccountStrategyFactory.NotBackendOrUser.selector);
        factory.createStrategyForUser(user, _entries(5000, 5000), 0);
    }

    function testCannotCreateSecondStrategyForSameUser() public {
        vm.prank(backend);
        factory.createStrategyForUser(user, _entries(5000, 5000), 0);

        address existing = factory.computeStrategyAddress(user);

        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(StockAccountStrategyFactory.StrategyAlreadyExists.selector, existing));
        factory.createStrategyForUser(user, _entries(5000, 5000), 0);
    }

    function testCannotCreateStrategyForZeroAddress() public {
        vm.prank(backend);
        vm.expectRevert(StockAccountStrategyFactory.ZeroAddress.selector);
        factory.createStrategyForUser(address(0), _entries(5000, 5000), 0);
    }

    function testInvalidBasketReverts() public {
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.WeightsMustTotal.selector, 9000));
        factory.createStrategyForUser(user, _entries(5000, 4000), 0);
    }
}
