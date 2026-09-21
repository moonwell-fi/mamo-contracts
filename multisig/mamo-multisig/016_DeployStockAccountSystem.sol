// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";
import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";

/**
 * @title DeployStockAccountSystem
 * @notice Multisig proposal that deploys the stock accounts system and wires it into the existing
 *         Mamo system in a single Safe batch:
 *           - deploys {StockAccountRegistry}, {StockAccountPriceChecker}, the {StockAccountStrategy}
 *             implementation and {StockAccountStrategyFactory} as the deployer;
 *           - as the multisig: points the stock registry at the real price checker, whitelists the
 *             implementation under the CONFIGURED strategy type id, grants the factory BACKEND_ROLE
 *             on the {MamoStrategyRegistry}, configures the cbBTC/USDC pair on the existing audited
 *             {SlippagePriceChecker}, and lists all five launch tokens.
 *
 * @dev THIS IS THE MAINNET PATH. `script/DeployStockAccounts.s.sol` stays the vnet path that
 *      `script/stock-accounts/vnet-up.sh` drives; the two are deliberately not merged, because the
 *      vnet path impersonates unlocked admins and this one has to produce one signable batch.
 *
 *      ONE SAFE IS WHAT MAKES ONE BATCH POSSIBLE. In `8453_PROD.json` the stock registry admin, the
 *      Mamo registry's `DEFAULT_ADMIN_ROLE` holder and the existing price checker's `owner()` are all
 *      MAMO_MULTISIG. {preBuildMock} asserts that identity rather than assuming it: if any of the
 *      three moves, the batch stops being executable and this proposal has to be split.
 *
 *      BOOTSTRAP ORDER. The price checker takes the stock registry as an immutable and the registry's
 *      constructor requires a code-bearing checker, so the registry is deployed against the config's
 *      placeholder and repointed by the batch's first action.
 *
 *      ORDER INSIDE {build} IS LOAD-BEARING, both constraints coming from the probe at the end of
 *      `listToken`: `setPriceChecker` must land before any listing, or the probe goes to the
 *      placeholder; and the cbBTC pair must be configured on the existing checker before cbBTC is
 *      listed, or the probe delegates into that checker and reverts `Token pair not configured`.
 *
 *      THE TYPE ID IS CHOSEN, NEVER AUTO-ASSIGNED. `nextStrategyTypeId()` only moves when an
 *      implementation is whitelisted with a zero id, and every whitelist since the USDC strategy has
 *      passed an explicit one, so the counter is a stale lower bound rather than the next free slot:
 *      it reads 4 on Base while slot 4 already holds the live Moonwell Morpho V2 implementation.
 *      {preBuildMock} snapshots slots 1-4 and {validate} asserts they are untouched.
 *
 *      NODE-NATIVE TOKENS. The four B20 stocks have the single reserved byte 0xEF as their onchain
 *      code; revm refuses to execute it, so `listToken`'s `decimals()` probe reverts locally. FPS
 *      records actions BY EXECUTING THEM, so without a stand-in those four listings would never reach
 *      the batch at all. {preBuildMock} etches a minimal ERC20 over each token whose code is exactly
 *      that byte — see {_standInForNodeNativeTokens} for exactly what that does and does not prove.
 */
contract DeployStockAccountSystem is MultisigProposal {
    string internal constant REGISTRY_KEY = "STOCK_ACCOUNT_REGISTRY";
    string internal constant PRICE_CHECKER_KEY = "STOCK_ACCOUNT_PRICE_CHECKER";
    string internal constant IMPL_KEY = "STOCK_ACCOUNT_STRATEGY_IMPL";
    string internal constant FACTORY_KEY = "STOCK_ACCOUNT_STRATEGY_FACTORY";

    /// @notice Staleness bound of the USDC/USD hop every Chainlink entry is quoted through
    /// @dev Deliberately above the feed's nominal 86,400 heartbeat, and identical to the value
    ///      `script/DeployStockAccounts.s.sol` uses. Walking the live Base aggregator over 31.8 days,
    ///      31 of its 32 round gaps ran past 86,400: the node fires tens of seconds late almost every
    ///      cycle, and valuation has no try/catch, so at 86,400 the quote reverts for a minute or so
    ///      each day. Do not tighten this back to the nominal heartbeat
    uint256 internal constant USDC_USD_HEARTBEAT = 90_000;

    /// @notice Strategy type slots that already hold live implementations and must survive untouched
    uint256 internal constant GUARDED_SLOTS = 4;

    StockAccountsConfig public immutable deployConfig;

    /// @notice The strategy type id the implementation is whitelisted under, from the deploy config
    uint256 public immutable strategyTypeId;

    /// @dev Slots 1..GUARDED_SLOTS as they read before the batch, captured by {preBuildMock}
    address[GUARDED_SLOTS] internal _implementationsBefore;
    bool internal _slotsSnapshotted;

    constructor() {
        deployConfig = new StockAccountsConfig("./deploy/stock-accounts/8453_PROD.json");
        vm.makePersistent(address(deployConfig));

        strategyTypeId = deployConfig.getConfig().strategyTypeId;
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
        return "016_DeployStockAccountSystem";
    }

    function description() public pure override returns (string memory) {
        return
        "Deploy the stock accounts system (registry, price checker, account implementation, factory), point the stock registry at the real price checker, whitelist the implementation under the configured strategy type id, grant the factory BACKEND_ROLE, configure the cbBTC pair on the existing price checker, and list the five launch tokens";
    }

    // ─── deploy: four contracts, each skipped when the address book already holds it ──────────────

    function deploy() public override {
        _deployStockRegistry();
        _deployPriceChecker();
        _deployImplementation();
        _deployFactory();
    }

    /// @dev Deployed against the config's PLACEHOLDER checker; the batch's first action repoints it
    function _deployStockRegistry() internal {
        if (addresses.isAddressSet(REGISTRY_KEY)) return;

        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();

        StockAccountRegistry.Config memory registryConfig = StockAccountRegistry.Config({
            admin: addresses.getAddress(cfg.admin),
            aerodromeRouter: ISwapRouter(addresses.getAddress(cfg.aerodromeRouter)),
            asset: addresses.getAddress(cfg.asset),
            guardian: addresses.getAddress(cfg.guardian),
            managementFeeBps: cfg.managementFeeBps,
            maxBackendSlippageBps: cfg.maxBackendSlippageBps,
            maxDeviationBps: cfg.maxDeviationBps,
            maxPositions: cfg.maxPositions,
            maxStrategyDeposit: cfg.maxStrategyDeposit,
            maxWithdrawSlippageBps: cfg.maxWithdrawSlippageBps,
            minStrategyDeposit: cfg.minStrategyDeposit,
            minTargetBps: cfg.minTargetBps,
            orderSigner: addresses.getAddress(cfg.orderSigner),
            priceChecker: ISlippagePriceChecker(addresses.getAddress(cfg.placeholderPriceChecker)),
            twapWindow: cfg.twapWindow
        });

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        StockAccountRegistry stockRegistry = new StockAccountRegistry(registryConfig);
        vm.stopBroadcast();

        addresses.addAddress(REGISTRY_KEY, address(stockRegistry), true);
    }

    function _deployPriceChecker() internal {
        if (addresses.isAddressSet(PRICE_CHECKER_KEY)) return;

        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        StockAccountPriceChecker priceChecker = new StockAccountPriceChecker(
            IStockAccountRegistry(addresses.getAddress(REGISTRY_KEY)),
            addresses.getAddress(cfg.asset),
            ISlippagePriceChecker(addresses.getAddress(cfg.existingPriceChecker))
        );
        vm.stopBroadcast();

        addresses.addAddress(PRICE_CHECKER_KEY, address(priceChecker), true);
    }

    function _deployImplementation() internal {
        if (addresses.isAddressSet(IMPL_KEY)) return;

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        StockAccountStrategy implementation = new StockAccountStrategy();
        vm.stopBroadcast();

        addresses.addAddress(IMPL_KEY, address(implementation), true);
    }

    /// @dev Deployable before the Safe executes the whitelist: the type id comes from the config, not
    ///      from whatever the registry would have auto-assigned at whitelist time
    function _deployFactory() internal {
        if (addresses.isAddressSet(FACTORY_KEY)) return;

        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        StockAccountStrategyFactory factory = new StockAccountStrategyFactory(
            addresses.getAddress(cfg.admin),
            addresses.getAddress(cfg.backend),
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            addresses.getAddress(REGISTRY_KEY),
            addresses.getAddress(cfg.asset),
            addresses.getAddress(cfg.cowSettlement),
            addresses.getAddress(IMPL_KEY),
            strategyTypeId,
            addresses.getAddress(cfg.feeRecipient)
        );
        vm.stopBroadcast();

        addresses.addAddress(FACTORY_KEY, address(factory), true);
    }

    // ─── preconditions + the one stand-in ────────────────────────────────────────────────────────

    function preBuildMock() public override {
        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));

        // Every action in the batch is sent by the same Safe. Asserted, not assumed: the three rights
        // the batch needs live on three different contracts.
        assertEq(addresses.getAddress(cfg.admin), multisig, "Stock registry admin should be MAMO_MULTISIG");
        assertTrue(
            mamoRegistry.hasRole(mamoRegistry.DEFAULT_ADMIN_ROLE(), multisig),
            "MAMO_MULTISIG should hold DEFAULT_ADMIN_ROLE on the Mamo registry"
        );
        assertTrue(
            stockRegistry.hasRole(stockRegistry.DEFAULT_ADMIN_ROLE(), multisig),
            "MAMO_MULTISIG should hold DEFAULT_ADMIN_ROLE on the stock registry"
        );
        assertEq(
            IERC5313(addresses.getAddress(cfg.existingPriceChecker)).owner(),
            multisig,
            "Existing price checker owner should be MAMO_MULTISIG"
        );

        // The configured type id must be an empty slot, and must sit above the auto-assign counter so
        // that counter can never hand our claimed id to another type before this batch executes.
        assertTrue(strategyTypeId != 0, "strategyTypeId must be set");
        assertEq(
            mamoRegistry.latestImplementationById(strategyTypeId),
            address(0),
            "Configured strategy type id already has an implementation"
        );
        assertLt(mamoRegistry.nextStrategyTypeId(), strategyTypeId, "strategy type id is within reach of the counter");

        // The factory constructor rejects a zero fee recipient, so it is a deploy-time blocker.
        assertTrue(addresses.getAddress(cfg.feeRecipient) != address(0), "Fee recipient should be set");

        // `setPriceChecker` reverts `AlreadySet` on a no-op, so the first action needs a real change.
        assertTrue(
            address(stockRegistry.priceChecker()) != addresses.getAddress(PRICE_CHECKER_KEY),
            "Stock registry already points at the deployed price checker"
        );

        _snapshotGuardedSlots(mamoRegistry);
        _standInForNodeNativeTokens();
    }

    /// @dev The regression test for the near-miss that motivated the explicit type id: whitelisting
    ///      with id 0 would have auto-assigned 4 and overwritten the live Moonwell Morpho V2 entry
    function _snapshotGuardedSlots(MamoStrategyRegistry mamoRegistry) internal {
        for (uint256 id = 1; id <= GUARDED_SLOTS; id++) {
            address implementation = mamoRegistry.latestImplementationById(id);
            assertTrue(implementation != address(0), "Guarded strategy type slot is unexpectedly empty");
            _implementationsBefore[id - 1] = implementation;
        }
        _slotsSnapshotted = true;
    }

    /**
     * @notice Stands a minimal ERC20 in over every launch token whose code is the single byte 0xEF
     * @dev WHAT THIS BUYS. The B20 stocks are node-native: `0xEF` is a reserved opcode revm refuses to
     *      execute, so any call into them reverts inside a fork simulation even though a real node
     *      serves them. `listToken` ends in a probe that reads `decimals()` off the token, and FPS
     *      records actions by EXECUTING them, so an unmocked listing reverts `build()` outright and
     *      the four stock listings never reach the batch.
     * @dev WHAT IT DOES NOT TOUCH. Only reads that the token itself answers are stood in: `decimals()`
     *      in the listing probe and in the price checker's TWAP scaling, and `balanceOf()` in account
     *      valuation. The pool leg — `token0`/`token1`/`observe` on the live Aerodrome Slipstream pool
     *      — and the quote arithmetic run against real mainnet state, unmocked. The decimals come from
     *      the config (which is why `TokenListEntry` carries them) rather than from a read, because
     *      the read is exactly what cannot happen here.
     * @dev WHAT THE SAFE SENDS IS UNAFFECTED. The recorded calldata targets the real token addresses
     *      and is byte-identical to what the Safe executes; the stand-in only exists so the call can
     *      be recorded at all. On the real chain the node executes the token natively and the probe
     *      reads the token's own decimals.
     * @dev The 0xEF gate means this never fires against a node or fork that can actually execute the
     *      token: cbBTC, an ordinary contract, is never stood in for.
     */
    function _standInForNodeNativeTokens() internal {
        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList();

        for (uint256 i = 0; i < entries.length; i++) {
            bytes memory code = entries[i].token.code;
            if (code.length != 1 || code[0] != 0xEF) continue;

            vm.etch(entries[i].token, address(new MockERC20Decimals(entries[i].symbol, entries[i].decimals)).code);
            assertEq(
                IERC20Metadata(entries[i].token).decimals(),
                entries[i].decimals,
                "Stand-in should report the configured decimals"
            );
        }
    }

    // ─── the batch ───────────────────────────────────────────────────────────────────────────────

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));
        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // 1. Replace the bootstrap placeholder with the real checker. Must precede every listing.
        stockRegistry.setPriceChecker(ISlippagePriceChecker(addresses.getAddress(PRICE_CHECKER_KEY)));

        // 2. Whitelist the account implementation under the configured (explicit) type id.
        mamoRegistry.whitelistImplementation(addresses.getAddress(IMPL_KEY), strategyTypeId);

        // 3. Grant the factory BACKEND_ROLE so it can register user accounts with the Mamo registry.
        mamoRegistry.grantRole(mamoRegistry.BACKEND_ROLE(), addresses.getAddress(FACTORY_KEY));

        // 4. Configure every Chainlink-priced launch token on the existing audited price checker.
        //    Must precede those tokens' listings: the listing probe delegates into this checker.
        _configureExistingChecker();

        // 5. List all five launch tokens on the stock registry.
        _listTokens(stockRegistry);
    }

    /// @dev Two hops, feed -> USD -> USDC, the shape every other Mamo config uses. cbBTC is the only
    ///      Chainlink entry on the launch list; the loop is over the config so adding one needs no edit
    function _configureExistingChecker() internal {
        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();
        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList();

        ISlippagePriceChecker existing = ISlippagePriceChecker(addresses.getAddress(cfg.existingPriceChecker));
        address asset = addresses.getAddress(cfg.asset);
        address usdcUsdFeed = addresses.getAddress("CHAINLINK_USDC_USD");

        for (uint256 i = 0; i < entries.length; i++) {
            if (keccak256(bytes(entries[i].source)) != keccak256(bytes("Chainlink"))) continue;

            if (existing.tokenPairOracleInformation(entries[i].token, asset).length == 0) {
                ISlippagePriceChecker.TokenFeedConfiguration[] memory feeds =
                    new ISlippagePriceChecker.TokenFeedConfiguration[](2);
                feeds[0] = ISlippagePriceChecker.TokenFeedConfiguration({
                    chainlinkFeed: entries[i].chainlinkFeed,
                    reverse: false,
                    heartbeat: entries[i].heartbeat
                });
                feeds[1] = ISlippagePriceChecker.TokenFeedConfiguration({
                    chainlinkFeed: usdcUsdFeed,
                    reverse: true,
                    heartbeat: USDC_USD_HEARTBEAT
                });

                existing.addTokenConfiguration(entries[i].token, asset, feeds);
            }

            if (existing.maxTimePriceValid(entries[i].token) == 0) {
                existing.setMaxTimePriceValid(entries[i].token, entries[i].heartbeat);
            }
        }
    }

    function _listTokens(StockAccountRegistry stockRegistry) internal {
        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList();

        for (uint256 i = 0; i < entries.length; i++) {
            if (stockRegistry.tokenConfig(entries[i].token).status != IStockAccountRegistry.TokenStatus.None) continue;

            stockRegistry.listToken(entries[i].token, _tokenConfigOf(entries[i]));
        }
    }

    function _tokenConfigOf(StockAccountsConfig.TokenListEntry memory entry)
        internal
        pure
        returns (IStockAccountRegistry.TokenConfig memory)
    {
        bool isChainlink = keccak256(bytes(entry.source)) == keccak256(bytes("Chainlink"));

        return IStockAccountRegistry.TokenConfig({
            status: IStockAccountRegistry.TokenStatus.Active,
            source: isChainlink ? IStockAccountRegistry.PriceSource.Chainlink : IStockAccountRegistry.PriceSource.PoolTwap,
            pool: entry.pool,
            chainlinkFeed: entry.chainlinkFeed
        });
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("MAMO_MULTISIG"));
    }

    // ─── post-conditions ─────────────────────────────────────────────────────────────────────────

    /// @dev Split by concern rather than into one frame: `this.`-calls would read `address(this)`,
    ///      which forge refuses inside a script contract, so these stay internal
    function validate() public view override {
        _validateWiring();
        _validateGuardedSlots();
        _validateStockRegistryConfig();
        _validateFactoryConfig();
        _validateTokenList();
    }

    /// @dev The four things the batch exists to change.
    function _validateWiring() internal view {
        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();
        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));
        address priceChecker = addresses.getAddress(PRICE_CHECKER_KEY);
        address implementation = addresses.getAddress(IMPL_KEY);

        assertEq(
            address(stockRegistry.priceChecker()), priceChecker, "Stock registry should point at the deployed checker"
        );

        assertTrue(mamoRegistry.whitelistedImplementations(implementation), "Implementation should be whitelisted");
        assertEq(
            mamoRegistry.implementationToId(implementation), strategyTypeId, "Implementation should map to the type id"
        );
        assertEq(
            mamoRegistry.latestImplementationById(strategyTypeId),
            implementation,
            "Type id should map back to the implementation"
        );

        assertTrue(
            mamoRegistry.hasRole(mamoRegistry.BACKEND_ROLE(), addresses.getAddress(FACTORY_KEY)),
            "Factory should hold BACKEND_ROLE on the Mamo registry"
        );

        // The price checker's own immutables, which decide what every quote is routed through.
        StockAccountPriceChecker checker = StockAccountPriceChecker(priceChecker);
        assertEq(address(checker.registry()), address(stockRegistry), "Checker registry mismatch");
        assertEq(checker.quoteAsset(), addresses.getAddress(cfg.asset), "Checker quote asset mismatch");
        assertEq(
            address(checker.existingChecker()),
            addresses.getAddress(cfg.existingPriceChecker),
            "Checker existingChecker mismatch"
        );
    }

    /// @notice Slots 1-4 still hold exactly the implementations they held before the batch
    /// @dev The assertion this proposal will not ship without: an auto-assigned id would have landed
    ///      on slot 4, which is live
    function _validateGuardedSlots() internal view {
        assertTrue(_slotsSnapshotted, "Guarded slots were never snapshotted; run preBuildMock");

        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        for (uint256 id = 1; id <= GUARDED_SLOTS; id++) {
            assertEq(
                mamoRegistry.latestImplementationById(id),
                _implementationsBefore[id - 1],
                "An existing strategy type slot was overwritten"
            );
        }
    }

    /// @dev Every registry parameter read back against the config that produced it.
    function _validateStockRegistryConfig() internal view {
        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));

        assertEq(
            address(stockRegistry.aerodromeRouter()),
            addresses.getAddress(cfg.aerodromeRouter),
            "Registry aerodromeRouter mismatch"
        );
        assertEq(stockRegistry.asset(), addresses.getAddress(cfg.asset), "Registry asset mismatch");
        assertEq(stockRegistry.orderSigner(), addresses.getAddress(cfg.orderSigner), "Registry orderSigner mismatch");
        assertEq(stockRegistry.maxPositions(), cfg.maxPositions, "Registry maxPositions mismatch");
        assertEq(stockRegistry.minTargetBps(), cfg.minTargetBps, "Registry minTargetBps mismatch");
        assertEq(stockRegistry.maxDeviationBps(), cfg.maxDeviationBps, "Registry maxDeviationBps mismatch");
        assertEq(
            stockRegistry.maxBackendSlippageBps(), cfg.maxBackendSlippageBps, "Registry maxBackendSlippageBps mismatch"
        );
        assertEq(
            stockRegistry.maxWithdrawSlippageBps(),
            cfg.maxWithdrawSlippageBps,
            "Registry maxWithdrawSlippageBps mismatch"
        );
        assertEq(stockRegistry.managementFeeBps(), cfg.managementFeeBps, "Registry managementFeeBps mismatch");
        assertEq(stockRegistry.twapWindow(), cfg.twapWindow, "Registry twapWindow mismatch");
        assertEq(stockRegistry.minStrategyDeposit(), cfg.minStrategyDeposit, "Registry minStrategyDeposit mismatch");
        assertEq(stockRegistry.maxStrategyDeposit(), cfg.maxStrategyDeposit, "Registry maxStrategyDeposit mismatch");
        assertFalse(stockRegistry.paused(), "Registry should not be paused");

        assertTrue(
            stockRegistry.hasRole(stockRegistry.DEFAULT_ADMIN_ROLE(), addresses.getAddress(cfg.admin)),
            "Registry admin role mismatch"
        );
        assertTrue(
            stockRegistry.hasRole(stockRegistry.GUARDIAN_ROLE(), addresses.getAddress(cfg.guardian)),
            "Registry guardian role mismatch"
        );
    }

    /// @dev Every factory immutable, all of which are unfixable after deployment.
    function _validateFactoryConfig() internal view {
        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();
        StockAccountStrategyFactory factory = StockAccountStrategyFactory(addresses.getAddress(FACTORY_KEY));

        assertEq(
            address(factory.mamoStrategyRegistry()),
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            "Factory mamoStrategyRegistry mismatch"
        );
        assertEq(factory.stockRegistry(), addresses.getAddress(REGISTRY_KEY), "Factory stockRegistry mismatch");
        assertEq(factory.asset(), addresses.getAddress(cfg.asset), "Factory asset mismatch");
        assertEq(factory.cowSettlement(), addresses.getAddress(cfg.cowSettlement), "Factory cowSettlement mismatch");
        assertEq(
            factory.strategyImplementation(), addresses.getAddress(IMPL_KEY), "Factory strategyImplementation mismatch"
        );
        assertEq(factory.strategyTypeId(), strategyTypeId, "Factory strategyTypeId mismatch");
        assertEq(factory.feeRecipient(), addresses.getAddress(cfg.feeRecipient), "Factory feeRecipient mismatch");

        assertTrue(
            factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), addresses.getAddress(cfg.admin)), "Factory admin mismatch"
        );
        assertTrue(
            factory.hasRole(factory.BACKEND_ROLE(), addresses.getAddress(cfg.backend)), "Factory backend mismatch"
        );
    }

    /// @dev Every launch token Active, with the configured source and pool, and quoting a real price.
    function _validateTokenList() internal view {
        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();
        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList();
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));
        StockAccountPriceChecker checker = StockAccountPriceChecker(addresses.getAddress(PRICE_CHECKER_KEY));
        address asset = addresses.getAddress(cfg.asset);

        assertEq(stockRegistry.allTokens().length, entries.length, "Listed token count mismatch");

        for (uint256 i = 0; i < entries.length; i++) {
            bool isChainlink = keccak256(bytes(entries[i].source)) == keccak256(bytes("Chainlink"));
            IStockAccountRegistry.TokenConfig memory listed = stockRegistry.tokenConfig(entries[i].token);

            assertEq(
                uint256(listed.status),
                uint256(IStockAccountRegistry.TokenStatus.Active),
                string.concat(entries[i].symbol, " should be Active")
            );
            assertEq(
                uint256(listed.source),
                uint256(
                    isChainlink
                        ? IStockAccountRegistry.PriceSource.Chainlink
                        : IStockAccountRegistry.PriceSource.PoolTwap
                ),
                string.concat(entries[i].symbol, " price source mismatch")
            );
            assertEq(listed.pool, entries[i].pool, string.concat(entries[i].symbol, " pool mismatch"));

            // One whole token has to quote something. For a pool-priced token this reads the live
            // Slipstream TWAP; for cbBTC it goes through the pair this batch just configured.
            assertGt(
                checker.getExpectedOut(10 ** entries[i].decimals, entries[i].token, asset),
                0,
                string.concat(entries[i].symbol, " should quote a non-zero price")
            );

            if (isChainlink) {
                ISlippagePriceChecker existing = ISlippagePriceChecker(addresses.getAddress(cfg.existingPriceChecker));
                assertTrue(
                    existing.isTokenPairConfigured(entries[i].token, asset),
                    string.concat(entries[i].symbol, " pair should be configured on the existing checker")
                );
                assertEq(
                    existing.maxTimePriceValid(entries[i].token),
                    entries[i].heartbeat,
                    string.concat(entries[i].symbol, " maxTimePriceValid mismatch")
                );
            }
        }
    }

    function _initializeAddresses() internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }
}
