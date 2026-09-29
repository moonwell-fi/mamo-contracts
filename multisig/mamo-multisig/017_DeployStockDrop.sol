// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DropAutomation} from "@contracts/DropAutomation.sol";
import {DropAutomationV2} from "@contracts/DropAutomationV2.sol";
import {MamoStakingRegistryV2} from "@contracts/MamoStakingRegistryV2.sol";
import {MamoStakingStrategyFactory} from "@contracts/MamoStakingStrategyFactory.sol";
import {MamoStakingStrategyV2} from "@contracts/MamoStakingStrategyV2.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";

/**
 * @title DeployStockDrop
 * @notice First of the stock drop proposals, the MAMO_MULTISIG batch:
 *           - deploys {DropAutomationV2}, {MamoStakingRegistryV2} (with the cbBTC pool and the stock
 *             routes to MAMO), the {MamoStakingStrategyV2} implementation, a staking factory for it, and a
 *             stock account factory whose fee recipient is DropAutomationV2;
 *           - as the multisig: whitelists the staking implementation under the existing staking type id so
 *             live accounts can upgrade, moves BACKEND_ROLE from the old staking and stock factories to the
 *             new ones, and configures the USDC -> MAMO and cbBTC -> MAMO pairs on the Chainlink checker.
 * @dev F-MAMO owns MultiRewards, DropAutomation v1 and the fee lockers, so the drop cutover is a separate F-MAMO
 *      proposal (f-mamo/006), and stock rewards a later one (f-mamo/007) once staking accounts have upgraded.
 */
contract DeployStockDrop is MultisigProposal {
    string internal constant DROP_KEY = "DROP_AUTOMATION_V2";
    string internal constant STAKING_REGISTRY_KEY = "MAMO_STAKING_REGISTRY_V2";
    string internal constant STAKING_IMPL_KEY = "MAMO_STAKING_STRATEGY_V2";
    string internal constant STAKING_FACTORY_KEY = "MAMO_STAKING_STRATEGY_FACTORY_V2";
    string internal constant STOCK_FACTORY_KEY = "STOCK_ACCOUNT_STRATEGY_FACTORY_V2";

    /// @notice The staking strategy type id, whose latest implementation live accounts upgrade to
    uint256 internal constant STAKING_TYPE_ID = 3;

    uint256 internal constant DEFAULT_SLIPPAGE_IN_BPS = 100;

    /// @dev Above the nominal 86,400: the USDC/USD node fires late most cycles (see 016)
    uint256 internal constant USDC_USD_HEARTBEAT = 90_000;
    uint256 internal constant MAMO_USD_HEARTBEAT = 86_400;
    uint256 internal constant BTC_USD_HEARTBEAT = 3_600;

    /// @notice The longest a CoW order selling USDC may stay valid
    uint256 internal constant USDC_ORDER_LIFETIME = 1 hours;

    StockAccountsConfig public immutable deployConfig;

    constructor() {
        deployConfig = new StockAccountsConfig("./deploy/stock-accounts/8453_PROD.json");
        vm.makePersistent(address(deployConfig));
    }

    function run() public override {
        _initializeAddresses();

        if (DO_DEPLOY) {
            deploy();
            addresses.printJSONChanges();
        }

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
        if (DO_UPDATE_ADDRESS_JSON) addresses.updateJson();
    }

    function name() public pure override returns (string memory) {
        return "017_DeployStockDrop";
    }

    function description() public pure override returns (string memory) {
        return
        "Deploy the stock drop contracts (DropAutomationV2, staking registry V2 with stock routes, staking strategy V2 and its factory, stock account factory paying fees to DropAutomationV2), whitelist the staking implementation under type id 3, move BACKEND_ROLE to the new factories, and configure the USDC and cbBTC to MAMO pairs on the Chainlink checker";
    }

    // ─── deploy ──────────────────────────────────────────────────────────────────────────────────

    function deploy() public override {
        _deployDropAutomation();
        _deployStakingRegistry();
        _deployStakingStrategy();
        _deployStockFactory();
    }

    function _deployDropAutomation() internal {
        if (addresses.isAddressSet(DROP_KEY)) return;

        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = addresses.getAddress("MAMO");
        rewardTokens[1] = addresses.getAddress("cbBTC");

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        DropAutomationV2 drop = new DropAutomationV2(
            addresses.getAddress("F-MAMO"),
            DropAutomation(addresses.getAddress("DROP_AUTOMATION")).dedicatedMsgSender(),
            addresses.getAddress("MAMO"),
            addresses.getAddress("cbBTC"),
            addresses.getAddress("MAMO_MULTI_REWARDS"),
            addresses.getAddress("AERODROME_ROUTER"),
            addresses.getAddress("AERODROME_QUOTER"),
            addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"),
            rewardTokens
        );
        vm.stopBroadcast();

        addresses.addAddress(DROP_KEY, address(drop), true);
    }

    /// @dev The deployer holds both roles while it lists the reward tokens and routes, then hands them over
    function _deployStakingRegistry() internal {
        if (addresses.isAddressSet(STAKING_REGISTRY_KEY)) return;

        address deployer = addresses.getAddress("DEPLOYER_EOA");

        vm.startBroadcast(deployer);
        MamoStakingRegistryV2 registry = new MamoStakingRegistryV2(
            deployer,
            deployer,
            addresses.getAddress("F-MAMO"),
            addresses.getAddress("MAMO"),
            addresses.getAddress("AERODROME_ROUTER"),
            addresses.getAddress("AERODROME_QUOTER"),
            addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"),
            DEFAULT_SLIPPAGE_IN_BPS
        );

        registry.addRewardToken(addresses.getAddress("cbBTC"), addresses.getAddress("cbBTC_MAMO_POOL"));

        StockAccountsConfig.TokenListEntry[] memory stocks = _stocks();
        for (uint256 i = 0; i < stocks.length; i++) {
            registry.addRewardToken(stocks[i].token, stocks[i].pool);
            registry.setRoute(stocks[i].token, _stockRoute(stocks[i].pool));
        }

        registry.grantRole(registry.BACKEND_ROLE(), addresses.getAddress("STRATEGY_MULTICALL"));
        registry.revokeRole(registry.BACKEND_ROLE(), deployer);
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), addresses.getAddress("F-MAMO"));
        registry.revokeRole(registry.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopBroadcast();

        addresses.addAddress(STAKING_REGISTRY_KEY, address(registry), true);
    }

    function _deployStakingStrategy() internal {
        if (!addresses.isAddressSet(STAKING_IMPL_KEY)) {
            vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
            MamoStakingStrategyV2 implementation = new MamoStakingStrategyV2();
            vm.stopBroadcast();

            addresses.addAddress(STAKING_IMPL_KEY, address(implementation), true);
        }

        if (addresses.isAddressSet(STAKING_FACTORY_KEY)) return;

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        MamoStakingStrategyFactory factory = new MamoStakingStrategyFactory(
            addresses.getAddress("F-MAMO"),
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            addresses.getAddress("MAMO_STAKING_BACKEND"),
            addresses.getAddress(STAKING_REGISTRY_KEY),
            addresses.getAddress("MAMO_MULTI_REWARDS"),
            addresses.getAddress("MAMO"),
            addresses.getAddress(STAKING_IMPL_KEY),
            STAKING_TYPE_ID
        );
        vm.stopBroadcast();

        addresses.addAddress(STAKING_FACTORY_KEY, address(factory), true);
    }

    /// @dev The live factory with DropAutomationV2 as the fee recipient, which is immutable on the factory
    function _deployStockFactory() internal {
        if (addresses.isAddressSet(STOCK_FACTORY_KEY)) return;

        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();
        StockAccountStrategyFactory live =
            StockAccountStrategyFactory(addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY"));

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        StockAccountStrategyFactory factory = new StockAccountStrategyFactory(
            addresses.getAddress(cfg.admin),
            addresses.getAddress(cfg.backend),
            address(live.mamoStrategyRegistry()),
            live.stockRegistry(),
            live.asset(),
            live.cowSettlement(),
            live.strategyImplementation(),
            live.strategyTypeId(),
            addresses.getAddress(DROP_KEY)
        );
        vm.stopBroadcast();

        addresses.addAddress(STOCK_FACTORY_KEY, address(factory), true);
    }

    // ─── preconditions ───────────────────────────────────────────────────────────────────────────

    function preBuildMock() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        assertTrue(
            mamoRegistry.hasRole(mamoRegistry.DEFAULT_ADMIN_ROLE(), multisig),
            "MAMO_MULTISIG should hold DEFAULT_ADMIN_ROLE on the Mamo registry"
        );
        assertEq(
            IERC5313(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY")).owner(),
            multisig,
            "Price checker owner should be MAMO_MULTISIG"
        );

        // Live accounts upgrade from the implementation type id 3 points at today
        assertEq(
            mamoRegistry.latestImplementationById(STAKING_TYPE_ID),
            addresses.getAddress("MAMO_STAKING_STRATEGY"),
            "Staking type id should point at the live staking implementation"
        );

        // setStakingRegistry's admin arm needs the same admin on both registries
        MamoStakingRegistryV2 registry = MamoStakingRegistryV2(addresses.getAddress(STAKING_REGISTRY_KEY));
        address fMamo = addresses.getAddress("F-MAMO");
        MamoStakingRegistryV2 liveRegistry = MamoStakingRegistryV2(addresses.getAddress("MAMO_STAKING_REGISTRY"));
        assertTrue(
            liveRegistry.hasRole(liveRegistry.DEFAULT_ADMIN_ROLE(), fMamo), "F-MAMO should admin the live registry"
        );
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), fMamo), "F-MAMO should admin the V2 registry");
    }

    // ─── the batch ───────────────────────────────────────────────────────────────────────────────

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        bytes32 backendRole = mamoRegistry.BACKEND_ROLE();

        // 1. The upgrade target for live staking accounts, under the existing type id
        mamoRegistry.whitelistImplementation(addresses.getAddress(STAKING_IMPL_KEY), STAKING_TYPE_ID);

        // 2. New accounts come only from the new factories
        mamoRegistry.grantRole(backendRole, addresses.getAddress(STAKING_FACTORY_KEY));
        mamoRegistry.revokeRole(backendRole, addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY"));
        mamoRegistry.grantRole(backendRole, addresses.getAddress(STOCK_FACTORY_KEY));
        mamoRegistry.revokeRole(backendRole, addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY"));

        // 3. The pairs the CoW sale and the compound routes price against
        _configurePriceChecker();
    }

    function _configurePriceChecker() internal {
        ISlippagePriceChecker checker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        address mamo = addresses.getAddress("MAMO");
        address usdc = addresses.getAddress("USDC");
        address cbBtc = addresses.getAddress("cbBTC");

        if (checker.tokenPairOracleInformation(usdc, mamo).length == 0) {
            checker.addTokenConfiguration(usdc, mamo, _toMamo("CHAINLINK_USDC_USD", USDC_USD_HEARTBEAT));
        }
        if (checker.maxTimePriceValid(usdc) == 0) checker.setMaxTimePriceValid(usdc, USDC_ORDER_LIFETIME);

        if (checker.tokenPairOracleInformation(cbBtc, mamo).length == 0) {
            checker.addTokenConfiguration(cbBtc, mamo, _toMamo("CHAINLINK_BTC_USD", BTC_USD_HEARTBEAT));
        }
    }

    /// @dev token -> USD -> MAMO
    function _toMamo(string memory feed, uint256 heartbeat)
        internal
        view
        returns (ISlippagePriceChecker.TokenFeedConfiguration[] memory feeds)
    {
        feeds = new ISlippagePriceChecker.TokenFeedConfiguration[](2);
        feeds[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: addresses.getAddress(feed),
            reverse: false,
            heartbeat: heartbeat
        });
        feeds[1] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: addresses.getAddress("CHAINLINK_MAMO_USD"),
            reverse: true,
            heartbeat: MAMO_USD_HEARTBEAT
        });
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("MAMO_MULTISIG"));
    }

    // ─── post-conditions ─────────────────────────────────────────────────────────────────────────

    function validate() public view override {
        _validateRegistryWiring();
        _validateDropAutomation();
        _validateStakingRegistry();
        _validateFactories();
        _validatePriceChecker();
    }

    function _validateRegistryWiring() internal view {
        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        address implementation = addresses.getAddress(STAKING_IMPL_KEY);
        bytes32 backendRole = mamoRegistry.BACKEND_ROLE();

        assertTrue(mamoRegistry.whitelistedImplementations(implementation), "Staking V2 should be whitelisted");
        assertEq(mamoRegistry.latestImplementationById(STAKING_TYPE_ID), implementation, "Type id 3 should be V2");

        assertTrue(mamoRegistry.hasRole(backendRole, addresses.getAddress(STAKING_FACTORY_KEY)), "Staking factory role");
        assertTrue(mamoRegistry.hasRole(backendRole, addresses.getAddress(STOCK_FACTORY_KEY)), "Stock factory role");
        assertFalse(
            mamoRegistry.hasRole(backendRole, addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY")),
            "Old staking factory should lose BACKEND_ROLE"
        );
        assertFalse(
            mamoRegistry.hasRole(backendRole, addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY")),
            "Old stock factory should lose BACKEND_ROLE"
        );
    }

    function _validateDropAutomation() internal view {
        DropAutomationV2 drop = DropAutomationV2(addresses.getAddress(DROP_KEY));

        assertEq(drop.owner(), addresses.getAddress("F-MAMO"), "Drop owner");
        assertEq(
            drop.dedicatedMsgSender(),
            DropAutomation(addresses.getAddress("DROP_AUTOMATION")).dedicatedMsgSender(),
            "Drop operator should match v1"
        );
        assertEq(address(drop.MULTI_REWARDS()), addresses.getAddress("MAMO_MULTI_REWARDS"), "Drop MultiRewards");
        assertEq(address(drop.AERODROME_CL_ROUTER()), addresses.getAddress("AERODROME_ROUTER"), "Drop router");
        assertEq(address(drop.AERODROME_QUOTER()), addresses.getAddress("AERODROME_QUOTER"), "Drop quoter");
        assertEq(address(drop.PRICE_CHECKER()), addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"), "Drop checker");
        assertEq(drop.getRewardTokens().length, 2, "Drop starts with MAMO and cbBTC");
        assertTrue(drop.isRewardToken(addresses.getAddress("MAMO")), "MAMO reward token");
        assertTrue(drop.isRewardToken(addresses.getAddress("cbBTC")), "cbBTC reward token");
    }

    function _validateStakingRegistry() internal view {
        MamoStakingRegistryV2 registry = MamoStakingRegistryV2(addresses.getAddress(STAKING_REGISTRY_KEY));
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        StockAccountsConfig.TokenListEntry[] memory stocks = _stocks();

        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), addresses.getAddress("F-MAMO")), "Registry admin");
        assertTrue(registry.hasRole(registry.GUARDIAN_ROLE(), addresses.getAddress("F-MAMO")), "Registry guardian");
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("STRATEGY_MULTICALL")), "Registry backend"
        );
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer), "Deployer should not admin");
        assertFalse(registry.hasRole(registry.BACKEND_ROLE(), deployer), "Deployer should not be backend");
        assertEq(registry.defaultSlippageInBps(), DEFAULT_SLIPPAGE_IN_BPS, "Registry default slippage");

        assertEq(registry.getRewardTokenCount(), 1 + stocks.length, "cbBTC and every stock");
        assertEq(
            registry.getRewardTokenPool(addresses.getAddress("cbBTC")),
            addresses.getAddress("cbBTC_MAMO_POOL"),
            "cbBTC pool"
        );

        for (uint256 i = 0; i < stocks.length; i++) {
            MamoStakingRegistryV2.Hop[] memory route = registry.getRoute(stocks[i].token);
            assertEq(route.length, 2, string.concat(stocks[i].symbol, " route length"));
            assertEq(route[0].pool, stocks[i].pool, string.concat(stocks[i].symbol, " route pool"));
            assertEq(
                address(route[0].router),
                addresses.getAddress("AERODROME_STOCKS_SWAP_ROUTER"),
                string.concat(stocks[i].symbol, " route router")
            );
            assertEq(
                address(route[0].checker),
                addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER"),
                string.concat(stocks[i].symbol, " route checker")
            );
            assertEq(route[1].pool, addresses.getAddress("USDC_MAMO_CL_POOL"), "USDC to MAMO hop");
        }
    }

    function _validateFactories() internal view {
        MamoStakingStrategyFactory stakingFactory =
            MamoStakingStrategyFactory(addresses.getAddress(STAKING_FACTORY_KEY));
        assertEq(
            stakingFactory.stakingRegistry(), addresses.getAddress(STAKING_REGISTRY_KEY), "Staking factory registry"
        );
        assertEq(
            stakingFactory.strategyImplementation(), addresses.getAddress(STAKING_IMPL_KEY), "Staking factory impl"
        );
        assertEq(stakingFactory.strategyTypeId(), STAKING_TYPE_ID, "Staking factory type id");
        assertEq(stakingFactory.multiRewards(), addresses.getAddress("MAMO_MULTI_REWARDS"), "Staking factory rewards");

        StockAccountStrategyFactory live =
            StockAccountStrategyFactory(addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY"));
        StockAccountStrategyFactory stockFactory = StockAccountStrategyFactory(addresses.getAddress(STOCK_FACTORY_KEY));
        assertEq(stockFactory.feeRecipient(), addresses.getAddress(DROP_KEY), "Stock fees go to DropAutomationV2");
        assertEq(stockFactory.strategyImplementation(), live.strategyImplementation(), "Stock factory impl");
        assertEq(stockFactory.strategyTypeId(), live.strategyTypeId(), "Stock factory type id");
        assertEq(stockFactory.stockRegistry(), live.stockRegistry(), "Stock factory registry");
    }

    function _validatePriceChecker() internal view {
        ISlippagePriceChecker checker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        address mamo = addresses.getAddress("MAMO");

        assertGt(checker.getExpectedOut(1e6, addresses.getAddress("USDC"), mamo), 0, "USDC should price in MAMO");
        assertGt(checker.getExpectedOut(1e8, addresses.getAddress("cbBTC"), mamo), 0, "cbBTC should price in MAMO");
        assertEq(checker.maxTimePriceValid(addresses.getAddress("USDC")), USDC_ORDER_LIFETIME, "USDC order lifetime");
    }

    // ─── helpers ─────────────────────────────────────────────────────────────────────────────────

    /// @dev The pool-priced entries of the stock list, i.e. the B20 stocks
    function _stocks() internal view returns (StockAccountsConfig.TokenListEntry[] memory stocks) {
        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList();
        stocks = new StockAccountsConfig.TokenListEntry[](entries.length);

        uint256 count;
        for (uint256 i = 0; i < entries.length; i++) {
            if (keccak256(bytes(entries[i].source)) == keccak256("PoolTwap")) stocks[count++] = entries[i];
        }

        assembly ("memory-safe") {
            mstore(stocks, count)
        }
    }

    /// @dev Stock -> USDC on the stocks router, priced by the stock checker; then USDC -> MAMO on the registry's
    ///      router and checker (zero = global)
    function _stockRoute(address stockPool) internal view returns (MamoStakingRegistryV2.Hop[] memory route) {
        route = new MamoStakingRegistryV2.Hop[](2);
        route[0] = MamoStakingRegistryV2.Hop({
            pool: stockPool,
            router: ISwapRouter(addresses.getAddress("AERODROME_STOCKS_SWAP_ROUTER")),
            checker: ISlippagePriceChecker(addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER"))
        });
        route[1] = MamoStakingRegistryV2.Hop({
            pool: addresses.getAddress("USDC_MAMO_CL_POOL"),
            router: ISwapRouter(address(0)),
            checker: ISlippagePriceChecker(address(0))
        });
    }

    function _initializeAddresses() internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }
}
