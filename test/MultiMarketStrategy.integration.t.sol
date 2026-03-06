// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {ERC20MoonwellMorphoStrategy, Market, MarketSplitUpdate} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {MarketRegistry} from "@contracts/MarketRegistry.sol";
import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";

import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";

import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {DeployConfig} from "@script/DeployConfig.sol";
import {DeploySlippagePriceChecker} from "@script/DeploySlippagePriceChecker.s.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MultiMarketStrategyTest is Test {
    Addresses public addresses;

    ERC20MoonwellMorphoStrategy public strategy;
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

        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));

        string memory assetConfigPath =
            vm.envOr("ASSET_CONFIG_PATH", string("config/strategies/USDCStrategyConfig.json"));

        DeployConfig configDeploy = new DeployConfig(configPath);
        config = configDeploy.getConfig();

        DeployAssetConfig assetConfigDeploy = new DeployAssetConfig(assetConfigPath);
        assetConfig = assetConfigDeploy.getConfig();

        admin = addresses.getAddress(config.admin);
        backend = addresses.getAddress(config.backend);
        guardian = addresses.getAddress(config.guardian);
        deployer = addresses.getAddress(config.deployer);
        owner = makeAddr("owner");

        underlying = IERC20(addresses.getAddress(assetConfig.token));
        mToken = IMToken(addresses.getAddress(assetConfig.moonwellMarket));
        metaMorphoVault = IERC4626(addresses.getAddress(assetConfig.metamorphoVault));

        if (addresses.isAddressSet("CHAINLINK_SWAP_CHECKER_PROXY")) {
            slippagePriceChecker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        } else {
            _setupSlippagePriceChecker();
        }

        // Deploy fresh registry for isolation
        registry = new MamoStrategyRegistry(admin, backend, guardian);

        // Deploy MarketRegistry and register markets
        marketRegistry = new MarketRegistry(admin, backend, guardian);

        // Deploy a new implementation and whitelist it
        ERC20MoonwellMorphoStrategy implementation = new ERC20MoonwellMorphoStrategy();

        vm.prank(admin);
        strategyTypeId = registry.whitelistImplementation(address(implementation), 0);

        // Register markets in the MarketRegistry
        vm.startPrank(backend);
        marketRegistry.addMarket(strategyTypeId, address(mToken), MarketType.MTOKEN);
        marketRegistry.addMarket(strategyTypeId, address(metaMorphoVault), MarketType.ERC4626);
        vm.stopPrank();

        // Deploy strategy with 2 markets: 70% Moonwell, 30% MetaMorpho
        uint256[] memory defaultSplitBps = new uint256[](2);
        defaultSplitBps[0] = 7000;
        defaultSplitBps[1] = 3000;

        // Deploy proxy and initialize
        vm.startPrank(backend);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        strategy = ERC20MoonwellMorphoStrategy(payable(address(proxy)));

        strategy.initialize(
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
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
                defaultSplitBps: defaultSplitBps
            })
        );

        registry.addStrategy(owner, address(strategy));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 minutes);
    }

    function _setupSlippagePriceChecker() private {
        DeploySlippagePriceChecker deployScript = new DeploySlippagePriceChecker();
        slippagePriceChecker = deployScript.deploySlippagePriceChecker(addresses, config);

        vm.startPrank(deployer);
        for (uint256 i = 0; i < config.rewardTokens.length; i++) {
            ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
                new ISlippagePriceChecker.TokenFeedConfiguration[](1);

            configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
                chainlinkFeed: addresses.getAddress(config.rewardTokens[i].priceFeed),
                reverse: config.rewardTokens[i].reverse,
                heartbeat: config.rewardTokens[i].heartbeat
            });

            slippagePriceChecker.addTokenConfiguration(
                address(addresses.getAddress(config.rewardTokens[i].token)), address(underlying), configs
            );
        }
        vm.stopPrank();
    }

    // ==================== INITIALIZATION TESTS ====================

    function testInitializationWithMultipleMarkets() public view {
        Market[] memory markets = strategy.getMarkets();
        assertEq(markets.length, 2, "Should have 2 markets");

        assertEq(markets[0].target, address(mToken), "Market 0 should be mToken");
        assertEq(uint256(markets[0].marketType), uint256(MarketType.MTOKEN), "Market 0 should be MTOKEN type");
        assertTrue(markets[0].active, "Market 0 should be active");
        assertEq(markets[0].splitBps, 7000, "Market 0 split should be 7000");

        assertEq(markets[1].target, address(metaMorphoVault), "Market 1 should be metaMorphoVault");
        assertEq(uint256(markets[1].marketType), uint256(MarketType.ERC4626), "Market 1 should be ERC4626 type");
        assertTrue(markets[1].active, "Market 1 should be active");
        assertEq(markets[1].splitBps, 3000, "Market 1 split should be 3000");

        assertEq(address(strategy.marketRegistry()), address(marketRegistry), "MarketRegistry should be set");
    }

    function testRevertInitializeWithNoMarkets() public {
        // Deploy a fresh MarketRegistry with no markets registered
        MarketRegistry emptyMarketRegistry = new MarketRegistry(admin, backend, guardian);

        ERC20MoonwellMorphoStrategy impl = new ERC20MoonwellMorphoStrategy();
        uint256[] memory emptyDefaultSplits = new uint256[](0);

        bytes memory data = abi.encodeWithSelector(
            ERC20MoonwellMorphoStrategy.initialize.selector,
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
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
        ERC20MoonwellMorphoStrategy impl = new ERC20MoonwellMorphoStrategy();

        // Splits that don't add up to 10000
        uint256[] memory badSplits = new uint256[](2);
        badSplits[0] = 5000;
        badSplits[1] = 4000; // total = 9000, not 10000

        bytes memory data = abi.encodeWithSelector(
            ERC20MoonwellMorphoStrategy.initialize.selector,
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
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
        ERC20MoonwellMorphoStrategy impl = new ERC20MoonwellMorphoStrategy();

        // Only 1 split but 2 markets in registry
        uint256[] memory wrongCountSplits = new uint256[](1);
        wrongCountSplits[0] = 10000;

        bytes memory data = abi.encodeWithSelector(
            ERC20MoonwellMorphoStrategy.initialize.selector,
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
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
        uint256 depositAmount = 1000 * 10 ** 6;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Verify Moonwell got ~70%
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(mTokenBalance, (depositAmount * 7000) / 10000, 1e3, "Moonwell should have ~70%");

        // Verify MetaMorpho got ~30%
        uint256 vaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(vaultShares);
        assertApproxEqAbs(vaultBalance, (depositAmount * 3000) / 10000, 1e3, "MetaMorpho should have ~30%");

        // Verify no idle tokens remain (or minimal dust)
        assertLe(underlying.balanceOf(address(strategy)), 1, "No idle tokens should remain");
    }

    function testDepositWithDeactivatedLastMarket() public {
        // First deposit so updatePosition has something to rebalance
        uint256 seedAmount = 100 * 10 ** 6;
        deal(address(underlying), owner, seedAmount);
        vm.startPrank(owner);
        underlying.approve(address(strategy), seedAmount);
        strategy.deposit(seedAmount);
        vm.stopPrank();

        // Deactivate the last market in the array (metaMorphoVault) and rebalance to 100% Moonwell
        vm.prank(backend);
        marketRegistry.deactivateMarket(strategyTypeId, address(metaMorphoVault));

        MarketSplitUpdate[] memory updates = new MarketSplitUpdate[](1);
        updates[0] = MarketSplitUpdate({market: address(mToken), splitBps: 10000});

        vm.prank(backend);
        strategy.updatePosition(updates);

        // Now deposit — the last array entry is inactive, remainder should go to mToken
        uint256 depositAmount = 1000 * 10 ** 6;
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
        uint256 depositAmount = 1000 * 10 ** 6;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Deactivate metaMorphoVault
        vm.prank(backend);
        marketRegistry.deactivateMarket(strategyTypeId, address(metaMorphoVault));

        // Rebalance to 100% Moonwell — withdrawAll should still drain inactive vault
        MarketSplitUpdate[] memory updates = new MarketSplitUpdate[](1);
        updates[0] = MarketSplitUpdate({market: address(mToken), splitBps: 10000});

        vm.prank(backend);
        strategy.updatePosition(updates);

        // All funds should be in Moonwell now
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(mTokenBalance, depositAmount, 1e3, "Moonwell should have all funds after rebalance");
        assertEq(metaMorphoVault.balanceOf(address(strategy)), 0, "MetaMorpho should be drained");
    }

    // ==================== WITHDRAW TESTS ====================

    function testWithdrawFromMultipleMarkets() public {
        uint256 depositAmount = 1000 * 10 ** 6;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        uint256 withdrawAmount = 500 * 10 ** 6;
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        assertApproxEqAbs(underlying.balanceOf(owner), withdrawAmount, 1e3, "Owner should receive withdrawn amount");
    }

    function testWithdrawAllFromMultipleMarkets() public {
        uint256 depositAmount = 1000 * 10 ** 6;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        strategy.withdrawAll();
        vm.stopPrank();

        assertApproxEqAbs(underlying.balanceOf(owner), depositAmount, 1e3, "Owner should receive all funds");

        // Verify no funds remain in markets
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 0, "Moonwell should be drained");
        assertEq(metaMorphoVault.balanceOf(address(strategy)), 0, "MetaMorpho should be drained");
    }

    // ==================== UPDATE POSITION TESTS ====================

    function testUpdatePositionRebalancesMarkets() public {
        uint256 depositAmount = 1000 * 10 ** 6;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Rebalance to 50/50
        MarketSplitUpdate[] memory updates = new MarketSplitUpdate[](2);
        updates[0] = MarketSplitUpdate({market: address(mToken), splitBps: 5000});
        updates[1] = MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 5000});

        vm.prank(backend);
        strategy.updatePosition(updates);

        // Verify new splits via getMarkets
        Market[] memory markets = strategy.getMarkets();
        assertEq(markets[0].splitBps, 5000, "Market 0 split should be 5000");
        assertEq(markets[1].splitBps, 5000, "Market 1 split should be 5000");

        // Verify balances reflect new split (approximately)
        uint256 totalBalance = _getTotalBalance();
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(mTokenBalance, totalBalance / 2, 1e3, "Moonwell should have ~50%");
    }

    function testRevertUpdatePositionInvalidSplit() public {
        uint256 depositAmount = 1000 * 10 ** 6;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        MarketSplitUpdate[] memory updates = new MarketSplitUpdate[](2);
        updates[0] = MarketSplitUpdate({market: address(mToken), splitBps: 6000});
        updates[1] = MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 5000}); // 110% total

        vm.prank(backend);
        vm.expectRevert("Split parameters must add up to SPLIT_TOTAL");
        strategy.updatePosition(updates);
    }

    function testRevertUpdatePositionInvalidMarket() public {
        uint256 depositAmount = 1000 * 10 ** 6;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        address fakeMarket = makeAddr("fakeMarket");
        MarketSplitUpdate[] memory updates = new MarketSplitUpdate[](1);
        updates[0] = MarketSplitUpdate({market: fakeMarket, splitBps: 10000});

        vm.prank(backend);
        vm.expectRevert(); // Market not registered / not active in registry
        strategy.updatePosition(updates);
    }

    function testRevertUpdatePositionDeactivatedMarket() public {
        uint256 depositAmount = 1000 * 10 ** 6;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Deactivate metaMorphoVault in the registry
        vm.prank(backend);
        marketRegistry.deactivateMarket(strategyTypeId, address(metaMorphoVault));

        // Try to allocate to the deactivated market
        MarketSplitUpdate[] memory updates = new MarketSplitUpdate[](2);
        updates[0] = MarketSplitUpdate({market: address(mToken), splitBps: 5000});
        updates[1] = MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 5000});

        vm.prank(backend);
        vm.expectRevert("Market not active in registry");
        strategy.updatePosition(updates);
    }

    function testRevertUpdatePositionNotBackend() public {
        MarketSplitUpdate[] memory updates = new MarketSplitUpdate[](2);
        updates[0] = MarketSplitUpdate({market: address(mToken), splitBps: 5000});
        updates[1] = MarketSplitUpdate({market: address(metaMorphoVault), splitBps: 5000});

        vm.prank(owner);
        vm.expectRevert("Not backend");
        strategy.updatePosition(updates);
    }

    // ==================== MARKET REGISTRY VIEW TESTS ====================

    function testGetMarketCount() public view {
        assertEq(strategy.getMarketCount(), 2, "Should have 2 markets");
    }

    function testMarketSplitBpsByAddress() public view {
        assertEq(strategy.marketSplitBps(address(mToken)), 7000, "mToken split should be 7000");
        assertEq(strategy.marketSplitBps(address(metaMorphoVault)), 3000, "metaMorphoVault split should be 3000");
    }

    function testMarketRegistryAddress() public view {
        assertEq(address(strategy.marketRegistry()), address(marketRegistry), "MarketRegistry should match");
    }

    // ==================== MIGRATION TESTS ====================

    function testMigrationFromLegacyToMarketRegistry() public {
        // Deploy v1 strategy using legacy init (no marketRegistry)
        ERC20MoonwellMorphoStrategy v1Impl = new ERC20MoonwellMorphoStrategy();

        vm.prank(admin);
        uint256 v1TypeId = registry.whitelistImplementation(address(v1Impl), 0);

        // Register markets for the v1 type ID too
        vm.startPrank(backend);
        marketRegistry.addMarket(v1TypeId, address(mToken), MarketType.MTOKEN);
        marketRegistry.addMarket(v1TypeId, address(metaMorphoVault), MarketType.ERC4626);
        vm.stopPrank();

        vm.startPrank(backend);
        ERC1967Proxy proxyV1 = new ERC1967Proxy(address(v1Impl), "");
        ERC20MoonwellMorphoStrategy legacyStrategy = ERC20MoonwellMorphoStrategy(payable(address(proxyV1)));

        legacyStrategy.initializeLegacy(
            ERC20MoonwellMorphoStrategy.LegacyInitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                mToken: address(mToken),
                metaMorphoVault: address(metaMorphoVault),
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                splitMToken: 7000,
                splitVault: 3000,
                strategyTypeId: v1TypeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: 100000,
                allowedSlippageInBps: 100,
                compoundFee: 500
            })
        );
        registry.addStrategy(owner, address(legacyStrategy));
        vm.stopPrank();

        // Legacy strategy should not have marketRegistry set
        assertEq(address(legacyStrategy.marketRegistry()), address(0), "Legacy init should not set marketRegistry");

        // Verify legacy storage
        assertEq(legacyStrategy.splitMToken(), 7000, "splitMToken should be 7000");
        assertEq(legacyStrategy.splitVault(), 3000, "splitVault should be 3000");

        // Now migrate to MarketRegistry
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
        // Deploy v1 strategy using legacy init
        ERC20MoonwellMorphoStrategy v1Impl = new ERC20MoonwellMorphoStrategy();

        vm.prank(admin);
        uint256 typeId = registry.whitelistImplementation(address(v1Impl), 0);

        // Register markets for the type ID
        vm.startPrank(backend);
        marketRegistry.addMarket(typeId, address(mToken), MarketType.MTOKEN);
        marketRegistry.addMarket(typeId, address(metaMorphoVault), MarketType.ERC4626);
        vm.stopPrank();

        vm.startPrank(backend);
        ERC1967Proxy proxy = new ERC1967Proxy(address(v1Impl), "");
        ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(address(proxy)));

        s.initializeLegacy(
            ERC20MoonwellMorphoStrategy.LegacyInitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                mToken: address(mToken),
                metaMorphoVault: address(metaMorphoVault),
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                splitMToken: 7000,
                splitVault: 3000,
                strategyTypeId: typeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: 100000,
                allowedSlippageInBps: 100,
                compoundFee: 500
            })
        );
        registry.addStrategy(owner, address(s));

        // First migration should succeed
        s.migrateV1ToMarketRegistry(address(marketRegistry));

        // Second migration should revert (reinitializer(2) already used)
        vm.expectRevert();
        s.migrateV1ToMarketRegistry(address(marketRegistry));
        vm.stopPrank();
    }

    function testMigrationWith100PercentMoonwell() public {
        // Legacy init with 100% Moonwell, 0% vault
        ERC20MoonwellMorphoStrategy impl = new ERC20MoonwellMorphoStrategy();

        vm.prank(admin);
        uint256 typeId = registry.whitelistImplementation(address(impl), 0);

        // Register only mToken market for this type
        vm.startPrank(backend);
        marketRegistry.addMarket(typeId, address(mToken), MarketType.MTOKEN);
        marketRegistry.addMarket(typeId, address(metaMorphoVault), MarketType.ERC4626);
        vm.stopPrank();

        vm.startPrank(backend);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(address(proxy)));

        s.initializeLegacy(
            ERC20MoonwellMorphoStrategy.LegacyInitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                mToken: address(mToken),
                metaMorphoVault: address(metaMorphoVault),
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                splitMToken: 10000,
                splitVault: 0,
                strategyTypeId: typeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: 100000,
                allowedSlippageInBps: 100,
                compoundFee: 500
            })
        );
        registry.addStrategy(owner, address(s));
        vm.stopPrank();

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
        // Deploy legacy strategy
        ERC20MoonwellMorphoStrategy v1Impl = new ERC20MoonwellMorphoStrategy();

        vm.prank(admin);
        uint256 typeId = registry.whitelistImplementation(address(v1Impl), 0);

        vm.startPrank(backend);
        ERC1967Proxy proxy = new ERC1967Proxy(address(v1Impl), "");
        ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(address(proxy)));

        s.initializeLegacy(
            ERC20MoonwellMorphoStrategy.LegacyInitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                mToken: address(mToken),
                metaMorphoVault: address(metaMorphoVault),
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                splitMToken: 7000,
                splitVault: 3000,
                strategyTypeId: typeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: 100000,
                allowedSlippageInBps: 100,
                compoundFee: 500
            })
        );
        registry.addStrategy(owner, address(s));
        vm.stopPrank();

        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        vm.expectRevert("Not owner or backend");
        s.migrateV1ToMarketRegistry(address(marketRegistry));
    }

    function testMigrateByOwnerSucceeds() public {
        // Deploy legacy strategy
        ERC20MoonwellMorphoStrategy v1Impl = new ERC20MoonwellMorphoStrategy();

        vm.prank(admin);
        uint256 typeId = registry.whitelistImplementation(address(v1Impl), 0);

        // Register markets for the type ID
        vm.startPrank(backend);
        marketRegistry.addMarket(typeId, address(mToken), MarketType.MTOKEN);
        marketRegistry.addMarket(typeId, address(metaMorphoVault), MarketType.ERC4626);
        vm.stopPrank();

        vm.startPrank(backend);
        ERC1967Proxy proxy = new ERC1967Proxy(address(v1Impl), "");
        ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(address(proxy)));

        s.initializeLegacy(
            ERC20MoonwellMorphoStrategy.LegacyInitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                mToken: address(mToken),
                metaMorphoVault: address(metaMorphoVault),
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                splitMToken: 7000,
                splitVault: 3000,
                strategyTypeId: typeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: 100000,
                allowedSlippageInBps: 100,
                compoundFee: 500
            })
        );
        registry.addStrategy(owner, address(s));
        vm.stopPrank();

        // Owner can call migrateV1ToMarketRegistry
        vm.prank(owner);
        s.migrateV1ToMarketRegistry(address(marketRegistry));

        assertEq(address(s.marketRegistry()), address(marketRegistry), "MarketRegistry should be set by owner");
    }

    // ==================== DEPOSIT IDLE TOKENS ====================

    function testDepositIdleTokensDistributesAcrossMarkets() public {
        uint256 idleAmount = 500 * 10 ** 6;
        deal(address(underlying), address(strategy), idleAmount);

        strategy.depositIdleTokens();

        assertLe(underlying.balanceOf(address(strategy)), 1, "No idle tokens should remain");

        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(mTokenBalance, (idleAmount * 7000) / 10000, 1e3, "Moonwell should have ~70%");
    }

    // ==================== HELPERS ====================

    function _getTotalBalance() internal returns (uint256) {
        uint256 metaMorphoShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 metaMorphoBalance = metaMorphoShares > 0 ? metaMorphoVault.convertToAssets(metaMorphoShares) : 0;
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 tokenBalance = underlying.balanceOf(address(strategy));
        return metaMorphoBalance + mTokenBalance + tokenBalance;
    }
}
