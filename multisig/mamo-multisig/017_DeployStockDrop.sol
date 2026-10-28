// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DropAutomation} from "@contracts/DropAutomation.sol";
import {DropAutomationV2} from "@contracts/DropAutomationV2.sol";
import {MamoStakingRegistryV2} from "@contracts/MamoStakingRegistryV2.sol";
import {MamoStakingStrategyFactory} from "@contracts/MamoStakingStrategyFactory.sol";
import {MamoStakingStrategyV2} from "@contracts/MamoStakingStrategyV2.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";

import {SlippagePriceCheckerHardening} from "./013_SlippagePriceCheckerOracleHardening.sol";

/**
 * @title DeployStockDrop
 * @notice First of the stock drop proposals, the MAMO_MULTISIG batch:
 *           - ships the price checker hardening of proposal 013 itself: deploys the new SlippagePriceChecker
 *             implementation, then upgrades the proxy, enables the sequencer guard, backfills the pair counts and
 *             corrects the WETH pairs' heartbeat before anything below prices through it;
 *           - deploys {DropAutomationV2}, {MamoStakingRegistryV2} (the cbBTC, WETH and USDC pools and
 *             the stock routes to MAMO), the {MamoStakingStrategyV2} implementation and a staking factory for it;
 *           - as the multisig: whitelists the staking implementation under the existing staking type id so
 *             live accounts can upgrade, moves BACKEND_ROLE from the old staking factory to the new one and revokes
 *             the deprecated factory's, points the V2 stock registry's fee recipient at DropAutomationV2, and
 *             configures the USDC, cbBTC and WETH -> MAMO pairs on the Chainlink checker.
 * @dev 013 is not executed on its own; if it ever were, this batch skips the upgrade and the rest of its steps
 *      re-apply harmlessly. Runs after mamo-multisig/019, which redeploys the stock accounts system this reads.
 *      F-MAMO owns MultiRewards, DropAutomation v1 and the fee lockers, so the drop cutover is a separate F-MAMO
 *      proposal (f-mamo/006), and the in-kind rewards a later one (f-mamo/007) once staking accounts have upgraded.
 */
contract DeployStockDrop is SlippagePriceCheckerHardening {
    string internal constant DROP_KEY = "DROP_AUTOMATION_V2";
    string internal constant STAKING_REGISTRY_KEY = "MAMO_STAKING_REGISTRY_V2";
    string internal constant STAKING_IMPL_KEY = "MAMO_STAKING_STRATEGY_V2";
    string internal constant STAKING_FACTORY_KEY = "MAMO_STAKING_STRATEGY_FACTORY_V2";
    string internal constant STOCK_REGISTRY_KEY = "STOCK_ACCOUNT_REGISTRY";

    /// @notice The staking strategy type id, whose latest implementation live accounts upgrade to
    uint256 internal constant STAKING_TYPE_ID = 3;

    uint256 internal constant DEFAULT_SLIPPAGE_IN_BPS = 100;

    /// @dev bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Above the nominal 86,400: the USDC/USD node fires late most cycles (see 016)
    uint256 internal constant USDC_USD_HEARTBEAT = 90_000;
    uint256 internal constant MAMO_USD_HEARTBEAT = 86_400;
    uint256 internal constant BTC_USD_HEARTBEAT = 3_600;
    uint256 internal constant ETH_USD_HEARTBEAT = 3_600;

    StockAccountsConfig public immutable deployConfig;

    /// @notice The stock list the V2 stock registry must already list every stock on, pool for pool
    string public tokenList = "./config/stock-accounts/8453.json";

    constructor() {
        deployConfig = new StockAccountsConfig("./deploy/stock-accounts/8453_PROD.json");
        vm.makePersistent(address(deployConfig));
    }

    /// @notice Points a rehearsal pinned before mamo-multisig/021 at the list the registry held then
    function setTokenList(string calldata path) external {
        tokenList = path;
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
        return "Deploy the stock drop contracts (DropAutomationV2, staking registry V2 with the reward pools and stock routes, staking strategy V2 and its factory), upgrade the Chainlink price checker with the sequencer guard, pair-count backfill and corrected WETH pair heartbeats (proposal 013, shipped in this batch), whitelist the staking implementation under type id 3, move BACKEND_ROLE to the new staking factory from the old and deprecated ones, point the V2 stock registry's fee recipient at DropAutomationV2, and configure the USDC, cbBTC and WETH to MAMO pairs on the Chainlink checker";
    }

    // ─── deploy ──────────────────────────────────────────────────────────────────────────────────

    function deploy() public override {
        _deployCheckerImplementation();
        _deployDropAutomation();
        _deployStakingRegistry();
        _deployStakingStrategy();
    }

    function _deployCheckerImplementation() internal {
        if (_checkerHardened()) return;

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        SlippagePriceChecker implementation = new SlippagePriceChecker();
        vm.stopBroadcast();

        addresses.changeAddress("CHAINLINK_SWAP_CHECKER_IMPLEMENTATION", address(implementation), true);
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
        registry.addRewardToken(addresses.getAddress("WETH"), addresses.getAddress("WETH_MAMO_CL_POOL"));
        registry.addRewardToken(addresses.getAddress("USDC"), addresses.getAddress("USDC_MAMO_CL_POOL"));

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
        // The pre-013 checker this batch upgrades, or 013's already live with its guard on
        if (_checkerHardened()) {
            assertEq(
                SlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY")).sequencerUptimeFeed(),
                addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"),
                "A hardened checker should already have its sequencer guard on"
            );
        } else {
            assertTrue(
                _checkerImplementation() != addresses.getAddress("CHAINLINK_SWAP_CHECKER_IMPLEMENTATION"),
                "deploy() should have staged the hardened checker implementation"
            );
        }

        // Live accounts upgrade from the implementation type id 3 points at today
        assertEq(
            mamoRegistry.latestImplementationById(STAKING_TYPE_ID),
            addresses.getAddress("MAMO_STAKING_STRATEGY"),
            "Staking type id should point at the live staking implementation"
        );
        assertTrue(
            mamoRegistry.hasRole(
                mamoRegistry.BACKEND_ROLE(), addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY_DEPRECATED")
            ),
            "Deprecated staking factory should still hold BACKEND_ROLE"
        );
        // Paired with validate(): the role churn below must not move BACKEND_ROLE index 0, which every
        // un-upgraded strategy proxy still reads as the backend (Sherlock #41, same pair as proposal 011)
        assertEq(
            mamoRegistry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 should be the strategy multicall before this proposal"
        );

        // setStakingRegistry's admin arm needs the same admin on both registries
        MamoStakingRegistryV2 registry = MamoStakingRegistryV2(addresses.getAddress(STAKING_REGISTRY_KEY));
        address fMamo = addresses.getAddress("F-MAMO");
        MamoStakingRegistryV2 liveRegistry = MamoStakingRegistryV2(addresses.getAddress("MAMO_STAKING_REGISTRY"));
        assertTrue(
            liveRegistry.hasRole(liveRegistry.DEFAULT_ADMIN_ROLE(), fMamo), "F-MAMO should admin the live registry"
        );
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), fMamo), "F-MAMO should admin the V2 registry");

        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(STOCK_REGISTRY_KEY));
        assertTrue(stockRegistry.hasRole(stockRegistry.DEFAULT_ADMIN_ROLE(), multisig), "Stock registry admin");
        assertFalse(stockRegistry.paused(), "Stock registry should not be paused");
        assertTrue(stockRegistry.feeRecipient() != addresses.getAddress(DROP_KEY), "Stock fees already go to drop");
    }

    // ─── the batch ───────────────────────────────────────────────────────────────────────────────

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        bytes32 backendRole = mamoRegistry.BACKEND_ROLE();

        // 1. Proposal 013: upgrade, sequencer guard, pair-count backfill, WETH pair heartbeats
        _buildOracleHardening();

        // 2. The upgrade target for live staking accounts, under the existing type id
        mamoRegistry.whitelistImplementation(addresses.getAddress(STAKING_IMPL_KEY), STAKING_TYPE_ID);

        // 3. New staking accounts come only from the new factory
        mamoRegistry.grantRole(backendRole, addresses.getAddress(STAKING_FACTORY_KEY));
        mamoRegistry.revokeRole(backendRole, addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY"));
        mamoRegistry.revokeRole(backendRole, addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY_DEPRECATED"));

        // 4. Stock account fees fund the drop
        StockAccountRegistry(addresses.getAddress(STOCK_REGISTRY_KEY)).setFeeRecipient(addresses.getAddress(DROP_KEY));

        // 5. The pairs compounding prices against
        _configurePriceChecker();
    }

    function _configurePriceChecker() internal {
        _configureToMamo("USDC", "CHAINLINK_USDC_USD", USDC_USD_HEARTBEAT);
        _configureToMamo("cbBTC", "CHAINLINK_BTC_USD", BTC_USD_HEARTBEAT);
        _configureToMamo("WETH", "CHAINLINK_ETH_USD", ETH_USD_HEARTBEAT);
    }

    function _configureToMamo(string memory token, string memory feed, uint256 heartbeat) internal {
        ISlippagePriceChecker checker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        address from = addresses.getAddress(token);
        address mamo = addresses.getAddress("MAMO");

        if (checker.tokenPairOracleInformation(from, mamo).length == 0) {
            checker.addTokenConfiguration(from, mamo, _toMamo(feed, heartbeat));
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
            chainlinkFeed: addresses.getAddress(feed), reverse: false, heartbeat: heartbeat
        });
        feeds[1] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: addresses.getAddress("CHAINLINK_MAMO_USD"), reverse: true, heartbeat: MAMO_USD_HEARTBEAT
        });
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("MAMO_MULTISIG"));
    }

    // ─── post-conditions ─────────────────────────────────────────────────────────────────────────

    function validate() public view override {
        _validateOracleHardening();
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
        assertFalse(
            mamoRegistry.hasRole(backendRole, addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY")),
            "Old staking factory should lose BACKEND_ROLE"
        );
        assertFalse(
            mamoRegistry.hasRole(backendRole, addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY_DEPRECATED")),
            "Deprecated staking factory should lose BACKEND_ROLE"
        );
        assertEq(
            mamoRegistry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 must not move"
        );
        assertEq(
            StockAccountRegistry(addresses.getAddress(STOCK_REGISTRY_KEY)).feeRecipient(),
            addresses.getAddress(DROP_KEY),
            "Stock fees go to DropAutomationV2"
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
        assertEq(drop.getRewardTokens().length, 2, "Drop starts with MAMO and cbBTC");
        assertTrue(drop.isRewardToken(addresses.getAddress("MAMO")), "MAMO reward token");
        assertTrue(drop.isRewardToken(addresses.getAddress("cbBTC")), "cbBTC reward token");
    }

    function _validateStakingRegistry() internal view {
        MamoStakingRegistryV2 registry = MamoStakingRegistryV2(addresses.getAddress(STAKING_REGISTRY_KEY));
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        StockAccountsConfig.TokenListEntry[] memory stocks = _stocks();
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(STOCK_REGISTRY_KEY));

        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), addresses.getAddress("F-MAMO")), "Registry admin");
        assertTrue(registry.hasRole(registry.GUARDIAN_ROLE(), addresses.getAddress("F-MAMO")), "Registry guardian");
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("STRATEGY_MULTICALL")), "Registry backend"
        );
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer), "Deployer should not admin");
        assertFalse(registry.hasRole(registry.BACKEND_ROLE(), deployer), "Deployer should not be backend");
        assertEq(registry.defaultSlippageInBps(), DEFAULT_SLIPPAGE_IN_BPS, "Registry default slippage");

        assertEq(registry.getRewardTokenCount(), 3 + stocks.length, "cbBTC, WETH, USDC and every stock");
        assertEq(stockRegistry.allTokens().length, stocks.length, "Routes cover every V2 stock listing");
        assertEq(
            registry.getRewardTokenPool(addresses.getAddress("WETH")),
            addresses.getAddress("WETH_MAMO_CL_POOL"),
            "WETH pool"
        );
        assertEq(
            registry.getRewardTokenPool(addresses.getAddress("USDC")),
            addresses.getAddress("USDC_MAMO_CL_POOL"),
            "USDC pool"
        );
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
                address(stockRegistry.aerodromeRouter()),
                string.concat(stocks[i].symbol, " route router")
            );
            assertEq(
                address(route[0].checker),
                addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER"),
                string.concat(stocks[i].symbol, " route checker")
            );
            assertEq(route[1].pool, addresses.getAddress("USDC_MAMO_CL_POOL"), "USDC to MAMO hop");

            // Every routed stock is listed and priced on the same pool by the V2 stock system
            IStockAccountRegistry.TokenConfig memory listing = stockRegistry.tokenConfig(stocks[i].token);
            assertEq(uint256(listing.status), uint256(IStockAccountRegistry.TokenStatus.Active), "Stock listed");
            assertEq(uint256(listing.source), uint256(IStockAccountRegistry.PriceSource.PoolTwap), "Stock source");
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
    }

    function _validatePriceChecker() internal view {
        ISlippagePriceChecker checker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        address mamo = addresses.getAddress("MAMO");

        assertEq(
            _checkerImplementation(),
            addresses.getAddress("CHAINLINK_SWAP_CHECKER_IMPLEMENTATION"),
            "Checker should run the recorded implementation"
        );

        assertGt(checker.getExpectedOut(1e6, addresses.getAddress("USDC"), mamo), 0, "USDC should price in MAMO");
        assertGt(checker.getExpectedOut(1e8, addresses.getAddress("cbBTC"), mamo), 0, "cbBTC should price in MAMO");
        assertGt(checker.getExpectedOut(1e18, addresses.getAddress("WETH"), mamo), 0, "WETH should price in MAMO");
    }

    // ─── helpers ─────────────────────────────────────────────────────────────────────────────────

    function _checkerImplementation() internal view returns (address) {
        return address(
            uint160(uint256(vm.load(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"), ERC1967_IMPLEMENTATION_SLOT)))
        );
    }

    /// @dev The pool-priced entries of the stock list, i.e. the B20 stocks. Each must already be listed on its
    ///      configured pool, so the deploy refuses to bake routes on pools mamo-multisig/021 is about to retire
    function _stocks() internal view returns (StockAccountsConfig.TokenListEntry[] memory stocks) {
        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList(tokenList);
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(STOCK_REGISTRY_KEY));
        stocks = new StockAccountsConfig.TokenListEntry[](entries.length);

        uint256 count;
        for (uint256 i = 0; i < entries.length; i++) {
            if (keccak256(bytes(entries[i].source)) != keccak256("PoolTwap")) continue;
            assertEq(
                stockRegistry.tokenConfig(entries[i].token).pool,
                entries[i].pool,
                string.concat(
                    entries[i].symbol, " is not listed on its configured pool; execute mamo-multisig/021 first"
                )
            );
            stocks[count++] = entries[i];
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
            router: ISwapRouter(
                address(StockAccountRegistry(addresses.getAddress(STOCK_REGISTRY_KEY)).aerodromeRouter())
            ),
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
