// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoMultiMarketStrategy} from "@contracts/MamoMultiMarketStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {MarketRegistry} from "@contracts/MarketRegistry.sol";
import {MultiMarketStrategyFactory} from "@contracts/MultiMarketStrategyFactory.sol";
import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";

import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {DeployConfig} from "@script/DeployConfig.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployMultiMarketSystem} from "../multisig/mamo-multisig/011_DeployMultiMarketSystem.sol";

/// @dev Test-only contract that simulates v1 legacy initialization for migration tests.
///      The production strategy no longer has initializeLegacy, but we need to populate
///      the deprecated storage slots (mToken, metaMorphoVault, splitMToken, splitVault)
///      to test migrateV1ToMarketRegistry.
contract LegacyV1Strategy is MamoMultiMarketStrategy {
    function initializeLegacyForTest(
        address _mamoStrategyRegistry,
        address _mToken,
        address _metaMorphoVault,
        address _token,
        address _slippagePriceChecker,
        address _feeRecipient,
        uint256 _splitMToken,
        uint256 _splitVault,
        uint256 _strategyTypeId,
        address _owner,
        uint256 _hookGasLimit,
        uint256 _allowedSlippageInBps,
        uint256 _compoundFee
    ) external initializer {
        __BaseStrategy_init(_mamoStrategyRegistry, _strategyTypeId, _owner);

        mToken = IMToken(_mToken);
        metaMorphoVault = IERC4626(_metaMorphoVault);
        token = IERC20(_token);
        slippagePriceChecker = ISlippagePriceChecker(_slippagePriceChecker);
        allowedSlippageInBps = _allowedSlippageInBps;
        compoundFee = _compoundFee;
        splitMToken = _splitMToken;
        splitVault = _splitVault;
        feeRecipient = _feeRecipient;
        hookGasLimit = _hookGasLimit;
    }
}

contract MultiMarketStrategyTest is Test {
    Addresses public addresses;

    MamoMultiMarketStrategy public strategy;
    MamoStrategyRegistry public registry;
    MarketRegistry public marketRegistry;
    ISlippagePriceChecker public slippagePriceChecker;
    IERC20 public underlying;
    IMToken public mToken;
    IERC4626 public metaMorphoVault;

    address public owner;
    address public backend;
    address public admin;
    address public guardian;
    address public deployer;

    DeployConfig.DeploymentConfig public config;
    DeployAssetConfig.Config public assetConfig;
    uint256 public strategyTypeId;

    function setUp() public {
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        // Run the multi-market deployment proposal
        DeployMultiMarketSystem proposal = new DeployMultiMarketSystem();
        vm.makePersistent(address(proposal));
        proposal.run();

        // Get addresses and config from proposal
        addresses = proposal.addresses();
        string memory assetConfigPath =
            vm.envOr("ASSET_CONFIG_PATH", string("config/strategies/USDCStrategyConfig.json"));
        DeployAssetConfig assetCfg = new DeployAssetConfig(assetConfigPath);
        assetConfig = assetCfg.getConfig();
        uint256 assetIndex = proposal.findAssetIndex(assetConfig.token);
        strategyTypeId = proposal.getAssetKeys(assetIndex).strategyTypeId;

        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));
        DeployConfig configDeploy = new DeployConfig(configPath);
        config = configDeploy.getConfig();

        admin = addresses.getAddress(config.admin);
        backend = addresses.getAddress(config.backend);
        guardian = addresses.getAddress(config.guardian);
        deployer = addresses.getAddress(config.deployer);
        owner = makeAddr("owner");

        underlying = IERC20(addresses.getAddress(assetConfig.token));
        mToken = IMToken(addresses.getAddress(assetConfig.moonwellMarket));
        metaMorphoVault = IERC4626(addresses.getAddress(assetConfig.metamorphoVault));
        slippagePriceChecker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));

        registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        marketRegistry = MarketRegistry(addresses.getAddress("MARKET_REGISTRY"));

        // Create strategy for owner using the deployed factory
        string memory factoryKey = string(abi.encodePacked(assetConfig.token, "_MULTI_MARKET_STRATEGY_FACTORY"));
        MultiMarketStrategyFactory factory = MultiMarketStrategyFactory(addresses.getAddress(factoryKey));

        vm.prank(owner);
        strategy = MamoMultiMarketStrategy(payable(factory.createStrategyForUser(owner)));

        vm.warp(block.timestamp + 1 minutes);
    }

    // ==================== INITIALIZATION TESTS ====================

    function testInitializationWithMultipleMarkets() public view {
        MamoMultiMarketStrategy.Market[] memory markets = strategy.getMarkets();
        assertEq(markets.length, assetConfig.markets.length, "Market count should match config");

        assertEq(markets[0].target, address(mToken), "Market 0 should be mToken");
        assertEq(uint256(markets[0].marketType), uint256(MarketType.MTOKEN), "Market 0 should be MTOKEN type");
        assertTrue(markets[0].active, "Market 0 should be active");
        assertEq(markets[0].splitBps, assetConfig.markets[0].splitBps, "Market 0 split should match config");

        if (markets.length > 1) {
            assertEq(markets[1].target, address(metaMorphoVault), "Market 1 should be metaMorphoVault");
            assertEq(uint256(markets[1].marketType), uint256(MarketType.ERC4626), "Market 1 should be ERC4626 type");
            assertTrue(markets[1].active, "Market 1 should be active");
            assertEq(markets[1].splitBps, assetConfig.markets[1].splitBps, "Market 1 split should match config");
        }

        assertEq(address(strategy.marketRegistry()), address(marketRegistry), "MarketRegistry should be set");
    }

    function testRevertInitializeWithNoMarkets() public {
        // Deploy a fresh MarketRegistry with no markets registered
        MarketRegistry emptyMarketRegistry = new MarketRegistry(admin, backend, guardian);

        MamoMultiMarketStrategy impl = new MamoMultiMarketStrategy();
        uint256[] memory emptyDefaultSplits = new uint256[](0);

        bytes memory data = abi.encodeWithSelector(
            MamoMultiMarketStrategy.initialize.selector,
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                strategyTypeId: strategyTypeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: 100000,
                allowedSlippageInBps: 100,
                compoundFee: 500,
                marketRegistry: address(emptyMarketRegistry),
                defaultSplitBps: emptyDefaultSplits
            })
        );

        vm.expectRevert("No markets in registry");
        new ERC1967Proxy(address(impl), data);
    }

    function testRevertInitializeWithInvalidSplit() public {
        MamoMultiMarketStrategy impl = new MamoMultiMarketStrategy();

        // Splits that don't add up to 10000
        uint256[] memory badSplits = new uint256[](2);
        badSplits[0] = 5000;
        badSplits[1] = 4000; // total = 9000, not 10000

        bytes memory data = abi.encodeWithSelector(
            MamoMultiMarketStrategy.initialize.selector,
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                strategyTypeId: strategyTypeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: 100000,
                allowedSlippageInBps: 100,
                compoundFee: 500,
                marketRegistry: address(marketRegistry),
                defaultSplitBps: badSplits
            })
        );

        vm.expectRevert("Split parameters must add up to SPLIT_TOTAL");
        new ERC1967Proxy(address(impl), data);
    }

    function testRevertInitializeWithSplitCountMismatch() public {
        MamoMultiMarketStrategy impl = new MamoMultiMarketStrategy();

        // Only 1 split but 2 markets in registry
        uint256[] memory wrongCountSplits = new uint256[](1);
        wrongCountSplits[0] = 10000;

        bytes memory data = abi.encodeWithSelector(
            MamoMultiMarketStrategy.initialize.selector,
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                strategyTypeId: strategyTypeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: 100000,
                allowedSlippageInBps: 100,
                compoundFee: 500,
                marketRegistry: address(marketRegistry),
                defaultSplitBps: wrongCountSplits
            })
        );

        vm.expectRevert("Split count must match market count");
        new ERC1967Proxy(address(impl), data);
    }

    // ==================== DEPOSIT TESTS ====================

    function testDepositDistributesAcrossMarkets() public {
        // Rebalance to 70/30 split for multi-market testing
        _rebalanceTo7030();

        uint256 totalBefore = _getTotalBalance();

        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        uint256 totalExpected = totalBefore + depositAmount;
        uint256 delta = assetConfig.decimals == 18 ? 1e9 : 1e3;

        // Verify Moonwell got ~70% of total balance (seed + deposit)
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(mTokenBalance, (totalExpected * 7000) / 10000, delta, "Moonwell should have ~70%");

        // Verify MetaMorpho got ~30% of total balance
        uint256 vaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(vaultShares);
        assertApproxEqAbs(vaultBalance, (totalExpected * 3000) / 10000, delta, "MetaMorpho should have ~30%");

        // Verify no idle tokens remain (or minimal dust)
        assertLe(underlying.balanceOf(address(strategy)), 1, "No idle tokens should remain");
    }

    function testDepositWithDeactivatedLastMarket() public {
        // First deposit so updatePosition has something to rebalance
        uint256 seedAmount = 100 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, seedAmount);
        vm.startPrank(owner);
        underlying.approve(address(strategy), seedAmount);
        strategy.deposit(seedAmount);
        vm.stopPrank();

        // Deactivate the last market in the array (metaMorphoVault) and rebalance to 100% Moonwell
        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(metaMorphoVault));

        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](1);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 10000});

        vm.prank(backend);
        strategy.updatePosition(updates);

        // Now deposit — the last array entry is inactive, remainder should go to mToken
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // All funds should be in Moonwell
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertGt(mTokenBalance, depositAmount, "Moonwell should have all funds");
        assertLe(underlying.balanceOf(address(strategy)), 1, "No idle tokens should remain");
        assertEq(metaMorphoVault.balanceOf(address(strategy)), 0, "MetaMorpho should have no shares");
    }

    function testUpdatePositionAfterMarketDeactivation() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Deactivate metaMorphoVault
        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(metaMorphoVault));

        // Rebalance to 100% Moonwell — withdrawAll should still drain inactive vault
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](1);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 10000});

        vm.prank(backend);
        strategy.updatePosition(updates);

        // All funds should be in Moonwell now
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 delta = assetConfig.decimals == 18 ? 1e9 : 1e3;
        assertApproxEqAbs(mTokenBalance, depositAmount, delta, "Moonwell should have all funds after rebalance");
        assertEq(metaMorphoVault.balanceOf(address(strategy)), 0, "MetaMorpho should be drained");
    }

    // ==================== WITHDRAW TESTS ====================

    function testWithdrawFromMultipleMarkets() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        uint256 withdrawAmount = 500 * 10 ** assetConfig.decimals;
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        uint256 delta = assetConfig.decimals == 18 ? 1e9 : 1e3;
        assertApproxEqAbs(underlying.balanceOf(owner), withdrawAmount, delta, "Owner should receive withdrawn amount");
    }

    function testWithdrawAllFromMultipleMarkets() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        strategy.withdrawAll();
        vm.stopPrank();

        uint256 delta = assetConfig.decimals == 18 ? 1e9 : 1e3;
        assertApproxEqAbs(underlying.balanceOf(owner), depositAmount, delta, "Owner should receive all funds");

        // Verify no funds remain in markets
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 0, "Moonwell should be drained");
        assertEq(metaMorphoVault.balanceOf(address(strategy)), 0, "MetaMorpho should be drained");
    }

    // ==================== UPDATE POSITION TESTS ====================

    function testUpdatePositionRebalancesMarkets() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Rebalance to 50/50
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 5000});
        updates[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 5000});

        vm.prank(backend);
        strategy.updatePosition(updates);

        // Verify new splits via getMarkets
        MamoMultiMarketStrategy.Market[] memory markets = strategy.getMarkets();
        assertEq(markets[0].splitBps, 5000, "Market 0 split should be 5000");
        assertEq(markets[1].splitBps, 5000, "Market 1 split should be 5000");

        // Verify balances reflect new split (approximately)
        uint256 totalBalance = _getTotalBalance();
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 delta = assetConfig.decimals == 18 ? 1e9 : 1e3;
        assertApproxEqAbs(mTokenBalance, totalBalance / 2, delta, "Moonwell should have ~50%");
    }

    function testRevertUpdatePositionInvalidSplit() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 6000});
        updates[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 5000}); // 110% total

        vm.prank(backend);
        vm.expectRevert("Split parameters must add up to SPLIT_TOTAL");
        strategy.updatePosition(updates);
    }

    function testRevertUpdatePositionInvalidMarket() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        address fakeMarket = makeAddr("fakeMarket");
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](1);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: fakeMarket, splitBps: 10000});

        vm.prank(backend);
        vm.expectRevert(); // Market not registered / not active in registry
        strategy.updatePosition(updates);
    }

    function testRevertUpdatePositionDeactivatedMarket() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Deactivate metaMorphoVault in the registry
        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(metaMorphoVault));

        // Try to allocate to the deactivated market
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 5000});
        updates[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 5000});

        vm.prank(backend);
        vm.expectRevert("Market not registered or not active");
        strategy.updatePosition(updates);
    }

    function testRevertUpdatePositionNotBackend() public {
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 5000});
        updates[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 5000});

        vm.prank(owner);
        vm.expectRevert("Not backend");
        strategy.updatePosition(updates);
    }

    // ==================== MARKET REGISTRY VIEW TESTS ====================

    function testGetMarketCount() public view {
        assertEq(strategy.getMarketCount(), 2, "Should have 2 markets");
    }

    function testMarketSplitBpsByAddress() public view {
        assertEq(
            strategy.marketSplitBps(address(mToken)),
            assetConfig.markets[0].splitBps,
            "mToken split should match config"
        );
        if (assetConfig.markets.length > 1) {
            assertEq(
                strategy.marketSplitBps(address(metaMorphoVault)),
                assetConfig.markets[1].splitBps,
                "metaMorphoVault split should match config"
            );
        }
    }

    function testMarketRegistryAddress() public view {
        assertEq(address(strategy.marketRegistry()), address(marketRegistry), "MarketRegistry should match");
    }

    // ==================== MIGRATION TESTS ====================

    function _deployLegacyStrategy(uint256 _splitMToken, uint256 _splitVault)
        internal
        returns (MamoMultiMarketStrategy s, uint256 typeId)
    {
        LegacyV1Strategy v1Impl = new LegacyV1Strategy();

        vm.prank(admin);
        typeId = registry.whitelistImplementation(address(v1Impl), 0);

        // Markets may already be registered for this asset from the deployment proposal
        if (marketRegistry.getMarketCount(address(underlying)) == 0) {
            vm.startPrank(backend);
            marketRegistry.addMarket(address(underlying), address(mToken), MarketType.MTOKEN);
            marketRegistry.addMarket(address(underlying), address(metaMorphoVault), MarketType.ERC4626);
            vm.stopPrank();
        }

        vm.startPrank(backend);
        ERC1967Proxy proxy = new ERC1967Proxy(address(v1Impl), "");
        s = MamoMultiMarketStrategy(payable(address(proxy)));

        LegacyV1Strategy(payable(address(s))).initializeLegacyForTest(
            address(registry),
            address(mToken),
            address(metaMorphoVault),
            address(underlying),
            address(slippagePriceChecker),
            admin,
            _splitMToken,
            _splitVault,
            typeId,
            owner,
            100000,
            100,
            500
        );
        registry.addStrategy(owner, address(s));
        vm.stopPrank();
    }

    function testMigrationFromLegacyToMarketRegistry() public {
        (MamoMultiMarketStrategy legacyStrategy,) = _deployLegacyStrategy(7000, 3000);

        // Legacy strategy should not have marketRegistry set
        assertEq(address(legacyStrategy.marketRegistry()), address(0), "Legacy init should not set marketRegistry");

        // Verify legacy storage
        assertEq(legacyStrategy.splitMToken(), 7000, "splitMToken should be 7000");
        assertEq(legacyStrategy.splitVault(), 3000, "splitVault should be 3000");

        // Now migrate to MarketRegistry
        vm.expectEmit(true, false, false, false);
        emit MamoMultiMarketStrategy.MarketRegistryMigrated(address(marketRegistry));
        vm.prank(backend);
        legacyStrategy.migrateV1ToMarketRegistry(address(marketRegistry));

        // After migration, marketRegistry should be set and splits should be migrated
        assertEq(
            address(legacyStrategy.marketRegistry()),
            address(marketRegistry),
            "MarketRegistry should be set after migration"
        );
        assertEq(legacyStrategy.marketSplitBps(address(mToken)), 7000, "mToken split should be 7000 after migration");
        assertEq(
            legacyStrategy.marketSplitBps(address(metaMorphoVault)),
            3000,
            "metaMorphoVault split should be 3000 after migration"
        );
    }

    function testMigrateV1ToMarketRegistryRevertsOnSecondCall() public {
        (MamoMultiMarketStrategy s,) = _deployLegacyStrategy(7000, 3000);

        vm.startPrank(backend);
        // First migration should succeed
        s.migrateV1ToMarketRegistry(address(marketRegistry));

        // Second migration should revert (reinitializer(2) already used)
        vm.expectRevert();
        s.migrateV1ToMarketRegistry(address(marketRegistry));
        vm.stopPrank();
    }

    function testMigrationWith100PercentMoonwell() public {
        (MamoMultiMarketStrategy s,) = _deployLegacyStrategy(10000, 0);

        // Verify legacy storage
        assertEq(s.splitMToken(), 10000, "splitMToken should be 10000");
        assertEq(s.splitVault(), 0, "splitVault should be 0");

        // Migrate to MarketRegistry
        vm.prank(backend);
        s.migrateV1ToMarketRegistry(address(marketRegistry));

        // After migration, only mToken should have split (splitVault=0 means metaMorphoVault is skipped)
        assertEq(s.marketSplitBps(address(mToken)), 10000, "mToken split should be 10000 after migration");
        assertEq(s.marketSplitBps(address(metaMorphoVault)), 0, "metaMorphoVault split should be 0 after migration");
    }

    // ==================== MIGRATION ACCESS CONTROL ====================

    function testRevertMigrateNotOwnerOrBackend() public {
        (MamoMultiMarketStrategy s,) = _deployLegacyStrategy(7000, 3000);

        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        vm.expectRevert("Not owner or backend");
        s.migrateV1ToMarketRegistry(address(marketRegistry));
    }

    function testMigrateByOwnerSucceeds() public {
        (MamoMultiMarketStrategy s,) = _deployLegacyStrategy(7000, 3000);

        // Owner can call migrateV1ToMarketRegistry
        vm.prank(owner);
        s.migrateV1ToMarketRegistry(address(marketRegistry));

        assertEq(address(s.marketRegistry()), address(marketRegistry), "MarketRegistry should be set by owner");
    }

    // ==================== WITHDRAW WITH DEACTIVATED MARKET TESTS ====================

    function testWithdrawAllAfterMarketDeactivation() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Deactivate metaMorphoVault while strategy still has funds in it
        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(metaMorphoVault));

        // withdrawAll should still drain all markets including inactive ones
        vm.prank(owner);
        strategy.withdrawAll();

        uint256 delta = assetConfig.decimals == 18 ? 1e9 : 1e3;
        assertApproxEqAbs(underlying.balanceOf(owner), depositAmount, delta, "Owner should receive all funds");
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 0, "Moonwell should be drained");
        assertEq(metaMorphoVault.balanceOf(address(strategy)), 0, "MetaMorpho should be drained");
    }

    // ==================== REACTIVATE MARKET TESTS ====================

    function testReactivateMarketAndRebalance() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Deactivate metaMorphoVault and rebalance to 100% Moonwell
        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(metaMorphoVault));

        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates100 =
            new MamoMultiMarketStrategy.MarketSplitUpdate[](1);
        updates100[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 10000});

        vm.prank(backend);
        strategy.updatePosition(updates100);

        assertEq(metaMorphoVault.balanceOf(address(strategy)), 0, "MetaMorpho should be drained after deactivation");

        // Reactivate metaMorphoVault
        vm.prank(backend);
        marketRegistry.reactivateMarket(address(underlying), address(metaMorphoVault));

        // Rebalance back to 60/40
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates6040 =
            new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates6040[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 6000});
        updates6040[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 4000});

        vm.prank(backend);
        strategy.updatePosition(updates6040);

        // Verify funds are distributed again
        uint256 delta = assetConfig.decimals == 18 ? 1e9 : 1e3;
        uint256 vaultShares = metaMorphoVault.balanceOf(address(strategy));
        assertGt(vaultShares, 0, "MetaMorpho should have shares after reactivation");

        MamoMultiMarketStrategy.Market[] memory markets = strategy.getMarkets();
        assertEq(markets[0].splitBps, 6000, "mToken split should be 6000");
        assertEq(markets[1].splitBps, 4000, "metaMorphoVault split should be 4000");
        assertTrue(markets[1].active, "metaMorphoVault should be active again");
    }

    // ==================== PARTIAL WITHDRAW AFTER DEACTIVATION ====================

    function testPartialWithdrawAfterMarketDeactivation() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Deactivate metaMorphoVault while strategy still has funds in both markets
        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(metaMorphoVault));

        // Partial withdraw should still succeed — _getTotalBalance includes inactive markets
        uint256 withdrawAmount = 400 * 10 ** assetConfig.decimals;
        vm.prank(owner);
        strategy.withdraw(withdrawAmount);

        uint256 delta = assetConfig.decimals == 18 ? 1e9 : 1e3;
        assertApproxEqAbs(underlying.balanceOf(owner), withdrawAmount, delta, "Owner should receive partial withdrawal");
    }

    // ==================== DEPOSIT IDLE TOKENS ====================

    function testDepositIdleTokensDistributesAcrossMarkets() public {
        // Rebalance to 70/30 split for multi-market testing
        _rebalanceTo7030();

        uint256 totalBefore = _getTotalBalance();

        uint256 idleAmount = 500 * 10 ** assetConfig.decimals;
        deal(address(underlying), address(strategy), idleAmount);

        strategy.depositIdleTokens();

        uint256 totalExpected = totalBefore + idleAmount;
        uint256 delta = assetConfig.decimals == 18 ? 1e9 : 1e3;
        assertLe(underlying.balanceOf(address(strategy)), 1, "No idle tokens should remain");

        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(mTokenBalance, (totalExpected * 7000) / 10000, delta, "Moonwell should have ~70%");
    }

    // ==================== HELPERS ====================

    function _rebalanceTo7030() internal {
        // Seed the strategy with some tokens so updatePosition can rebalance
        uint256 seedAmount = 100 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, seedAmount);
        vm.startPrank(owner);
        underlying.approve(address(strategy), seedAmount);
        strategy.deposit(seedAmount);
        vm.stopPrank();

        // Update to 70/30 split
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 7000});
        updates[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 3000});

        vm.prank(backend);
        strategy.updatePosition(updates);
    }

    /// @notice A MAX withdrawal against the LIVE MetaMorpho vault: ask for exactly what the strategy
    ///         advertises. The unit suite models this, but only the real vault carries the actual
    ///         mechanism — MetaMorpho's `maxRedeem` is `convertToShares(maxWithdraw)`, a
    ///         shares -> assets -> shares round trip that floors at each step, so
    ///         `previewRedeem(maxRedeem) == maxWithdraw - 1`. Exiting on `maxRedeem` therefore lands
    ///         one unit under the requested amount and the trailing `remaining == 0` require takes
    ///         the whole withdrawal down. 50/50 is the case with no slack anywhere else to absorb it.
    function testMaxWithdrawAgainstLiveMetaMorpho() public {
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // The shipped configs are 100/0, which leaves the vault leg empty and the 4626 capacity
        // branch unreachable. Move everything into the vault: with no second leg holding anything,
        // pass 1 targets the vault at its full capacity — the branch under test — and there is
        // nothing anywhere to absorb a payout that lands under what was advertised. (A 50/50 split
        // does NOT express this: the two legs round apart by a unit, the vault's pass-1 target
        // lands just below its capacity, and the residual gets swept in pass 2 either way.)
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 0});
        updates[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 10000});

        vm.prank(backend);
        strategy.updatePosition(updates);

        // What the strategy will accept is previewRedeem of the whole share balance, not
        // convertToAssets — the two differ on a vault with an exit fee, and previewRedeem is what
        // the withdrawal path has to be able to actually deliver.
        uint256 shares = metaMorphoVault.balanceOf(address(strategy));
        assertGt(shares, 0, "the vault leg must be funded for this test to mean anything");
        uint256 advertised = metaMorphoVault.previewRedeem(shares) + mToken.balanceOfUnderlying(address(strategy))
            + underlying.balanceOf(address(strategy));

        vm.prank(owner);
        strategy.withdraw(advertised);

        assertEq(underlying.balanceOf(owner), advertised, "a max withdrawal delivers the full advertised total");
    }

    function _getTotalBalance() internal returns (uint256) {
        uint256 metaMorphoShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 metaMorphoBalance = metaMorphoShares > 0 ? metaMorphoVault.convertToAssets(metaMorphoShares) : 0;
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 tokenBalance = underlying.balanceOf(address(strategy));
        return metaMorphoBalance + mTokenBalance + tokenBalance;
    }
}
