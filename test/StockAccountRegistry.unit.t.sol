// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";
import {MockPriceChecker} from "@test/mocks/MockPriceChecker.sol";
import {MockStockAccountRegistry} from "@test/mocks/MockStockAccountRegistry.sol";

contract Stub {}

contract StockAccountRegistryUnitTest is Test {
    StockAccountRegistry internal registry;

    ISwapRouter internal router;
    MockPriceChecker internal checker;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    address internal asset = makeAddr("asset");
    address internal token;
    address internal pool;
    address internal feed;

    function setUp() public {
        router = ISwapRouter(_stub());
        checker = new MockPriceChecker();
        token = address(new MockERC20Decimals("TOKEN", 8));
        pool = _stub();
        feed = _stub();

        checker.setRate(token, asset, 1e18);

        registry = new StockAccountRegistry(defaultConfig());
    }

    function _stub() internal returns (address) {
        return address(new Stub());
    }

    function defaultConfig() internal view returns (StockAccountRegistry.Config memory config) {
        config = StockAccountRegistry.Config({
            admin: admin,
            aerodromeRouter: router,
            asset: asset,
            guardian: guardian,
            maxBackendSlippageBps: 100,
            maxDeviationBps: 500,
            maxPositions: 10,
            maxStrategyDeposit: 1_000_000e6,
            maxWithdrawSlippageBps: 200,
            minStrategyDeposit: 100e6,
            minTargetBps: 250,
            managementFeeBps: 100,
            priceChecker: checker,
            twapWindow: 1800
        });
    }

    function activeConfig() internal view returns (IStockAccountRegistry.TokenConfig memory) {
        return IStockAccountRegistry.TokenConfig({
            status: IStockAccountRegistry.TokenStatus.Active,
            source: IStockAccountRegistry.PriceSource.PoolTwap,
            pool: pool,
            chainlinkFeed: address(0)
        });
    }

    function listDefaultToken() internal {
        vm.prank(admin);
        registry.listToken(token, activeConfig());
    }

    function expectNotAdmin(address caller) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
    }

    function testConstructorStoresConfig() public view {
        assertEq(address(registry.aerodromeRouter()), address(router), "router mismatch");
        assertEq(address(registry.priceChecker()), address(checker), "price checker mismatch");
        assertEq(registry.asset(), asset, "asset mismatch");
        assertEq(registry.maxPositions(), 10, "max positions mismatch");
        assertEq(registry.minTargetBps(), 250, "min target mismatch");
        assertEq(registry.maxDeviationBps(), 500, "max deviation mismatch");
        assertEq(registry.maxBackendSlippageBps(), 100, "backend slippage mismatch");
        assertEq(registry.maxWithdrawSlippageBps(), 200, "withdraw slippage mismatch");
        assertEq(registry.twapWindow(), 1800, "twap window mismatch");
        assertEq(registry.minStrategyDeposit(), 100e6, "min deposit mismatch");
        assertEq(registry.maxStrategyDeposit(), 1_000_000e6, "max deposit mismatch");
        assertEq(registry.managementFeeBps(), 100, "management fee mismatch");
        assertEq(registry.maxManagementFeeBps(), 200, "max management fee mismatch");
        assertEq(registry.allTokens().length, 0, "token list should start empty");
    }

    function testConstructorGrantsRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin), "admin role not granted");
        assertTrue(registry.hasRole(registry.GUARDIAN_ROLE(), guardian), "guardian role not granted");
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), guardian), "guardian should not be admin");
    }

    function testConstructorRevertsOnZeroAdmin() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.admin = address(0);

        vm.expectRevert(IStockAccountRegistry.ZeroAddress.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroGuardian() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.guardian = address(0);

        vm.expectRevert(IStockAccountRegistry.ZeroAddress.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroAsset() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.asset = address(0);

        vm.expectRevert(IStockAccountRegistry.ZeroAddress.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroRouter() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.aerodromeRouter = ISwapRouter(address(0));

        vm.expectRevert(IStockAccountRegistry.ZeroAddress.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnEOARouter() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        address eoaRouter = makeAddr("eoaRouter");
        config.aerodromeRouter = ISwapRouter(eoaRouter);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.NotAContract.selector, eoaRouter));
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroPriceChecker() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.priceChecker = ISlippagePriceChecker(address(0));

        vm.expectRevert(IStockAccountRegistry.ZeroAddress.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnEOAPriceChecker() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        address eoaChecker = makeAddr("eoaChecker");
        config.priceChecker = ISlippagePriceChecker(eoaChecker);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.NotAContract.selector, eoaChecker));
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroMaxPositions() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.maxPositions = 0;

        vm.expectRevert(IStockAccountRegistry.InvalidMaxPositions.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroMinTarget() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.minTargetBps = 0;

        vm.expectRevert(IStockAccountRegistry.InvalidMinTarget.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnMinTargetAboveMax() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.minTargetBps = 10_001;

        vm.expectRevert(IStockAccountRegistry.InvalidMinTarget.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnMaxDeviationTooHigh() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.maxDeviationBps = 10_001;

        vm.expectRevert(IStockAccountRegistry.InvalidMaxDeviation.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnBackendSlippageTooHigh() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.maxBackendSlippageBps = 10_001;

        vm.expectRevert(IStockAccountRegistry.InvalidSlippageCap.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnWithdrawSlippageTooHigh() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.maxWithdrawSlippageBps = 10_001;

        vm.expectRevert(IStockAccountRegistry.InvalidSlippageCap.selector);
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroTwapWindow() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.twapWindow = 0;

        vm.expectRevert(IStockAccountRegistry.InvalidTwapWindow.selector);
        new StockAccountRegistry(config);
    }

    function testAdminUpdatesEveryScalarAndEmits() public {
        ISwapRouter newRouter = ISwapRouter(_stub());
        ISlippagePriceChecker newChecker = ISlippagePriceChecker(_stub());

        vm.startPrank(admin);

        vm.expectEmit(true, true, false, true, address(registry));
        emit StockAccountRegistry.AerodromeRouterUpdated(address(router), address(newRouter));
        registry.setAerodromeRouter(newRouter);

        vm.expectEmit(true, true, false, true, address(registry));
        emit StockAccountRegistry.PriceCheckerUpdated(address(checker), address(newChecker));
        registry.setPriceChecker(newChecker);

        vm.expectEmit(address(registry));
        emit StockAccountRegistry.MaxPositionsUpdated(10, 7);
        registry.setMaxPositions(7);

        vm.expectEmit(address(registry));
        emit StockAccountRegistry.MinTargetBpsUpdated(250, 300);
        registry.setMinTargetBps(300);

        vm.expectEmit(address(registry));
        emit StockAccountRegistry.MaxDeviationBpsUpdated(500, 400);
        registry.setMaxDeviationBps(400);

        vm.expectEmit(address(registry));
        emit StockAccountRegistry.MaxBackendSlippageBpsUpdated(100, 50);
        registry.setMaxBackendSlippageBps(50);

        vm.expectEmit(address(registry));
        emit StockAccountRegistry.MaxWithdrawSlippageBpsUpdated(200, 75);
        registry.setMaxWithdrawSlippageBps(75);

        vm.expectEmit(address(registry));
        emit StockAccountRegistry.TwapWindowUpdated(1800, 600);
        registry.setTwapWindow(600);

        vm.expectEmit(address(registry));
        emit StockAccountRegistry.MinStrategyDepositUpdated(100e6, 250e6);
        registry.setMinStrategyDeposit(250e6);

        vm.expectEmit(address(registry));
        emit StockAccountRegistry.MaxStrategyDepositUpdated(1_000_000e6, 500e6);
        registry.setMaxStrategyDeposit(500e6);

        vm.expectEmit(address(registry));
        emit StockAccountRegistry.ManagementFeeBpsUpdated(100, 25);
        registry.setManagementFeeBps(25);

        vm.stopPrank();

        assertEq(address(registry.aerodromeRouter()), address(newRouter), "router mismatch");
        assertEq(address(registry.priceChecker()), address(newChecker), "price checker mismatch");
        assertEq(registry.maxPositions(), 7, "max positions mismatch");
        assertEq(registry.minTargetBps(), 300, "min target mismatch");
        assertEq(registry.maxDeviationBps(), 400, "max deviation mismatch");
        assertEq(registry.maxBackendSlippageBps(), 50, "backend slippage mismatch");
        assertEq(registry.maxWithdrawSlippageBps(), 75, "withdraw slippage mismatch");
        assertEq(registry.twapWindow(), 600, "twap window mismatch");
        assertEq(registry.minStrategyDeposit(), 250e6, "min deposit mismatch");
        assertEq(registry.maxStrategyDeposit(), 500e6, "max deposit mismatch");
        assertEq(registry.managementFeeBps(), 25, "management fee mismatch");
    }

    function testGuardianCannotUpdateScalars() public {
        ISwapRouter newRouter = ISwapRouter(_stub());
        ISlippagePriceChecker newChecker = ISlippagePriceChecker(_stub());

        vm.startPrank(guardian);

        expectNotAdmin(guardian);
        registry.setAerodromeRouter(newRouter);

        expectNotAdmin(guardian);
        registry.setPriceChecker(newChecker);

        expectNotAdmin(guardian);
        registry.setMaxPositions(7);

        expectNotAdmin(guardian);
        registry.setMinTargetBps(300);

        expectNotAdmin(guardian);
        registry.setMaxDeviationBps(400);

        expectNotAdmin(guardian);
        registry.setMaxBackendSlippageBps(50);

        expectNotAdmin(guardian);
        registry.setMaxWithdrawSlippageBps(75);

        expectNotAdmin(guardian);
        registry.setTwapWindow(600);

        expectNotAdmin(guardian);
        registry.setMinStrategyDeposit(250e6);

        expectNotAdmin(guardian);
        registry.setMaxStrategyDeposit(500e6);

        expectNotAdmin(guardian);
        registry.setManagementFeeBps(25);

        vm.stopPrank();
    }

    function testGuardianCannotListToken() public {
        expectNotAdmin(guardian);
        vm.prank(guardian);
        registry.listToken(token, activeConfig());
    }

    function testScalarSettersRevertOnSameValue() public {
        vm.startPrank(admin);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setAerodromeRouter(router);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setPriceChecker(checker);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setMaxPositions(10);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setMinTargetBps(250);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setMaxDeviationBps(500);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setMaxBackendSlippageBps(100);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setMaxWithdrawSlippageBps(200);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setTwapWindow(1800);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setMinStrategyDeposit(100e6);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setMaxStrategyDeposit(1_000_000e6);

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        registry.setManagementFeeBps(100);

        vm.stopPrank();
    }

    function testScalarSettersRevertOnInvalidValues() public {
        vm.startPrank(admin);

        vm.expectRevert(IStockAccountRegistry.ZeroAddress.selector);
        registry.setAerodromeRouter(ISwapRouter(address(0)));

        address eoaRouter = makeAddr("eoaRouter");
        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.NotAContract.selector, eoaRouter));
        registry.setAerodromeRouter(ISwapRouter(eoaRouter));

        vm.expectRevert(IStockAccountRegistry.ZeroAddress.selector);
        registry.setPriceChecker(ISlippagePriceChecker(address(0)));

        address eoaChecker = makeAddr("eoaChecker");
        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.NotAContract.selector, eoaChecker));
        registry.setPriceChecker(ISlippagePriceChecker(eoaChecker));

        vm.expectRevert(IStockAccountRegistry.InvalidMaxPositions.selector);
        registry.setMaxPositions(0);

        vm.expectRevert(IStockAccountRegistry.InvalidMinTarget.selector);
        registry.setMinTargetBps(0);

        vm.expectRevert(IStockAccountRegistry.InvalidMinTarget.selector);
        registry.setMinTargetBps(10_001);

        vm.expectRevert(IStockAccountRegistry.InvalidMaxDeviation.selector);
        registry.setMaxDeviationBps(10_001);

        vm.expectRevert(IStockAccountRegistry.InvalidSlippageCap.selector);
        registry.setMaxBackendSlippageBps(10_001);

        vm.expectRevert(IStockAccountRegistry.InvalidSlippageCap.selector);
        registry.setMaxWithdrawSlippageBps(10_001);

        vm.expectRevert(IStockAccountRegistry.InvalidTwapWindow.selector);
        registry.setTwapWindow(0);

        vm.expectRevert(IStockAccountRegistry.InvalidManagementFee.selector);
        registry.setManagementFeeBps(201);

        vm.stopPrank();
    }

    function testManagementFeeCanBeSetToTheCapAndToZero() public {
        vm.startPrank(admin);

        registry.setManagementFeeBps(registry.maxManagementFeeBps());
        assertEq(registry.managementFeeBps(), 200, "capped fee mismatch");

        registry.setManagementFeeBps(0);
        assertEq(registry.managementFeeBps(), 0, "promo fee mismatch");

        vm.stopPrank();
    }

    function testConstructorRevertsOnFeeAboveCap() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.managementFeeBps = 201;

        vm.expectRevert(IStockAccountRegistry.InvalidManagementFee.selector);
        new StockAccountRegistry(config);
    }

    function testListTokenStoresConfigAndEmits() public {
        IStockAccountRegistry.TokenConfig memory cfg = activeConfig();

        vm.expectEmit(true, false, false, true, address(registry));
        emit StockAccountRegistry.TokenListed(token, cfg);
        vm.prank(admin);
        registry.listToken(token, cfg);

        IStockAccountRegistry.TokenConfig memory stored = registry.tokenConfig(token);
        assertEq(uint256(stored.status), uint256(IStockAccountRegistry.TokenStatus.Active), "status mismatch");
        assertEq(uint256(stored.source), uint256(IStockAccountRegistry.PriceSource.PoolTwap), "source mismatch");
        assertEq(stored.pool, pool, "pool mismatch");
        assertEq(stored.chainlinkFeed, address(0), "feed mismatch");

        address[] memory tokens = registry.allTokens();
        assertEq(tokens.length, 1, "token list length mismatch");
        assertEq(tokens[0], token, "listed token mismatch");
    }

    function testListTokenWithChainlinkSource() public {
        IStockAccountRegistry.TokenConfig memory cfg = activeConfig();
        cfg.source = IStockAccountRegistry.PriceSource.Chainlink;
        cfg.chainlinkFeed = feed;

        vm.prank(admin);
        registry.listToken(token, cfg);

        assertEq(registry.tokenConfig(token).chainlinkFeed, feed, "feed mismatch");
    }

    function testListTokenRevertsWhenAlreadyListed() public {
        listDefaultToken();

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.TokenAlreadyListed.selector, token));
        vm.prank(admin);
        registry.listToken(token, activeConfig());
    }

    function testListTokenRevertsWhenNotActive() public {
        IStockAccountRegistry.TokenConfig memory cfg = activeConfig();
        cfg.status = IStockAccountRegistry.TokenStatus.SellOnly;

        vm.expectRevert(IStockAccountRegistry.MustListAsActive.selector);
        vm.prank(admin);
        registry.listToken(token, cfg);
    }

    function testListTokenRevertsWhenTokenNotContract() public {
        address eoaToken = makeAddr("eoaToken");

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.NotAContract.selector, eoaToken));
        vm.prank(admin);
        registry.listToken(eoaToken, activeConfig());
    }

    function testListTokenRevertsWhenPoolNotContract() public {
        IStockAccountRegistry.TokenConfig memory cfg = activeConfig();
        cfg.pool = makeAddr("eoaPool");

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.NotAContract.selector, cfg.pool));
        vm.prank(admin);
        registry.listToken(token, cfg);
    }

    function testListTokenRevertsWhenPoolIsToken() public {
        IStockAccountRegistry.TokenConfig memory cfg = activeConfig();
        cfg.pool = token;

        vm.expectRevert(IStockAccountRegistry.PoolIsToken.selector);
        vm.prank(admin);
        registry.listToken(token, cfg);
    }

    function testListTokenRevertsWhenChainlinkFeedNotContract() public {
        IStockAccountRegistry.TokenConfig memory cfg = activeConfig();
        cfg.source = IStockAccountRegistry.PriceSource.Chainlink;
        cfg.chainlinkFeed = makeAddr("eoaFeed");

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.NotAContract.selector, cfg.chainlinkFeed));
        vm.prank(admin);
        registry.listToken(token, cfg);
    }

    function testListTokenRevertsWhenTwapCarriesFeed() public {
        IStockAccountRegistry.TokenConfig memory cfg = activeConfig();
        cfg.chainlinkFeed = feed;

        vm.expectRevert(IStockAccountRegistry.FeedOnlyForChainlink.selector);
        vm.prank(admin);
        registry.listToken(token, cfg);
    }

    function testListTokenRevertsWhenTokenHasNoQuote() public {
        checker.setRate(token, asset, 0);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.TokenNotPriceable.selector, token));
        vm.prank(admin);
        registry.listToken(token, activeConfig());

        assertEq(registry.allTokens().length, 0, "token list should stay empty");
        assertEq(
            uint256(registry.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.None),
            "token should stay unlisted"
        );
    }

    function testListTokenRevertsWhenQuoteIsZero() public {
        checker.setRate(token, asset, 1);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.TokenNotPriceable.selector, token));
        vm.prank(admin);
        registry.listToken(token, activeConfig());

        assertEq(registry.allTokens().length, 0, "token list should stay empty");
    }

    function testReactivationRevertsWhenTokenNoLongerPriceable() public {
        listDefaultToken();

        vm.prank(guardian);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Halted);

        checker.setRate(token, asset, 0);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.TokenNotPriceable.selector, token));
        vm.prank(admin);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Active);
        assertEq(
            uint256(registry.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.Halted),
            "status should stay halted"
        );

        checker.setRate(token, asset, 1e18);

        vm.prank(admin);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Active);
        assertEq(
            uint256(registry.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.Active),
            "status should be active"
        );
    }

    function testLoweringStatusNeverProbes() public {
        listDefaultToken();
        checker.setRate(token, asset, 0);

        vm.startPrank(guardian);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.SellOnly);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Halted);
        vm.stopPrank();

        assertEq(
            uint256(registry.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.Halted),
            "status should be halted"
        );

        vm.prank(admin);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.SellOnly);
        assertEq(
            uint256(registry.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.SellOnly),
            "status should be sell only"
        );
    }

    function testAdminRaisesAndLowersTokenStatus() public {
        listDefaultToken();

        vm.expectEmit(true, false, false, true, address(registry));
        emit StockAccountRegistry.TokenStatusUpdated(
            token, IStockAccountRegistry.TokenStatus.Active, IStockAccountRegistry.TokenStatus.Halted
        );
        vm.prank(admin);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Halted);
        assertEq(
            uint256(registry.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.Halted),
            "status not halted"
        );

        vm.prank(admin);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Active);
        assertEq(
            uint256(registry.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.Active),
            "status not restored"
        );
    }

    function testGuardianCanOnlyLowerTokenStatus() public {
        listDefaultToken();

        vm.startPrank(guardian);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.SellOnly);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Halted);

        vm.expectRevert(IStockAccountRegistry.GuardianCanOnlyLower.selector);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Active);
        vm.stopPrank();

        assertEq(
            uint256(registry.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.Halted),
            "status mismatch"
        );
    }

    function testSetTokenStatusRevertsForStranger() public {
        listDefaultToken();

        vm.expectRevert(IStockAccountRegistry.NotAdminOrGuardian.selector);
        vm.prank(stranger);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Halted);
    }

    function testSetTokenStatusRevertsForUnlistedToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.TokenNotListed.selector, token));
        vm.prank(admin);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Halted);
    }

    function testSetTokenStatusRevertsOnNoneStatus() public {
        listDefaultToken();

        vm.expectRevert(IStockAccountRegistry.InvalidStatus.selector);
        vm.prank(admin);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.None);
    }

    function testSetTokenStatusRevertsOnSameStatus() public {
        listDefaultToken();

        vm.expectRevert(IStockAccountRegistry.AlreadySet.selector);
        vm.prank(admin);
        registry.setTokenStatus(token, IStockAccountRegistry.TokenStatus.Active);
    }

    function testPauseBlocksWritesButNotReads() public {
        listDefaultToken();
        address otherToken = _stub();

        vm.prank(guardian);
        registry.pause();
        assertTrue(registry.paused(), "registry should be paused");

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(admin);
        registry.setMaxPositions(7);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(admin);
        registry.listToken(otherToken, activeConfig());

        assertEq(registry.maxPositions(), 10, "max positions mismatch");
        assertEq(registry.allTokens().length, 1, "token list length mismatch");
        assertEq(
            uint256(registry.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.Active),
            "status mismatch"
        );
    }

    function testUnpauseRestoresWrites() public {
        vm.startPrank(guardian);
        registry.pause();
        registry.unpause();
        vm.stopPrank();

        assertFalse(registry.paused(), "registry should be unpaused");

        vm.prank(admin);
        registry.setMaxPositions(7);
        assertEq(registry.maxPositions(), 7, "max positions mismatch");
    }

    function testOnlyGuardianCanPause() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, registry.GUARDIAN_ROLE()
            )
        );
        vm.prank(admin);
        registry.pause();
    }

    function testMockSetTokenConfigStoresAndLists() public {
        MockStockAccountRegistry mock = new MockStockAccountRegistry();

        mock.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: pool,
                chainlinkFeed: feed
            })
        );

        IStockAccountRegistry.TokenConfig memory stored = mock.tokenConfig(token);
        assertEq(uint256(stored.status), uint256(IStockAccountRegistry.TokenStatus.Active), "status mismatch");
        assertEq(uint256(stored.source), uint256(IStockAccountRegistry.PriceSource.PoolTwap), "source mismatch");
        assertEq(stored.pool, pool, "pool mismatch");
        assertEq(stored.chainlinkFeed, feed, "feed mismatch");

        address[] memory tokens = mock.allTokens();
        assertEq(tokens.length, 1, "token list length mismatch");
        assertEq(tokens[0], token, "listed token mismatch");
    }

    function testMockSetTokenConfigTwiceKeepsSingleEntry() public {
        MockStockAccountRegistry mock = new MockStockAccountRegistry();

        IStockAccountRegistry.TokenConfig memory cfg = IStockAccountRegistry.TokenConfig({
            status: IStockAccountRegistry.TokenStatus.Active,
            source: IStockAccountRegistry.PriceSource.Chainlink,
            pool: address(0),
            chainlinkFeed: feed
        });
        mock.setTokenConfig(token, cfg);

        cfg.status = IStockAccountRegistry.TokenStatus.SellOnly;
        mock.setTokenConfig(token, cfg);

        assertEq(mock.allTokens().length, 1, "token list length mismatch");
        assertEq(
            uint256(mock.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.SellOnly),
            "status not updated"
        );
    }

    function testMockScalarSettersRoundTrip() public {
        MockStockAccountRegistry mock = new MockStockAccountRegistry();

        mock.setMaxPositions(7);
        mock.setMinTargetBps(300);
        mock.setMaxDeviationBps(400);
        mock.setMinStrategyDeposit(100e6);
        mock.setMaxStrategyDeposit(500e6);
        mock.setTwapWindow(600);
        mock.setMaxBackendSlippageBps(50);
        mock.setMaxWithdrawSlippageBps(75);
        mock.setManagementFeeBps(150);
        mock.setAerodromeRouter(router);
        mock.setPriceChecker(checker);
        mock.setAsset(asset);

        assertEq(mock.maxPositions(), 7, "max positions mismatch");
        assertEq(mock.minTargetBps(), 300, "min target mismatch");
        assertEq(mock.maxDeviationBps(), 400, "max deviation mismatch");
        assertEq(mock.minStrategyDeposit(), 100e6, "min deposit mismatch");
        assertEq(mock.maxStrategyDeposit(), 500e6, "max deposit mismatch");
        assertEq(mock.twapWindow(), 600, "twap window mismatch");
        assertEq(mock.maxBackendSlippageBps(), 50, "backend slippage mismatch");
        assertEq(mock.maxWithdrawSlippageBps(), 75, "withdraw slippage mismatch");
        assertEq(mock.managementFeeBps(), 150, "management fee mismatch");
        assertEq(address(mock.aerodromeRouter()), address(router), "router mismatch");
        assertEq(address(mock.priceChecker()), address(checker), "price checker mismatch");
        assertEq(mock.asset(), asset, "asset mismatch");
    }

    function testSetPriceCheckerRevertsWhenAListedTokenCannotBeQuoted() public {
        listDefaultToken();

        MockPriceChecker other = new MockPriceChecker();

        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.TokenNotPriceable.selector, token));
        vm.prank(admin);
        registry.setPriceChecker(other);

        other.setRate(token, asset, 1e18);

        vm.prank(admin);
        registry.setPriceChecker(other);
        assertEq(address(registry.priceChecker()), address(other), "checker not swapped");
    }
}
