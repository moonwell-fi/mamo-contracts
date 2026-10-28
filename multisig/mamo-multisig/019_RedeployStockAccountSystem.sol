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

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";
import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";

/**
 * @title RedeployStockAccountSystem
 * @notice Multisig proposal that redeploys the stock accounts system under strategy type id 7 and
 *         retires v1 in one Safe batch: the v2 registry, price checker, implementation and factory
 *         are deployed, wired in and given the 12-stock list, and the queues app may create v2 accounts;
 *         the v1 factory loses BACKEND_ROLE and
 *         the v1 registry is paused with its order signer set to a dead address.
 * @dev v1 accounts are not upgraded. Pausing the v1 registry stops every order from validating while
 *      every v1 exit keeps working. Built on proposal 016's hooks; see it for the bootstrap order and
 *      the node-native token stand-in.
 */
contract RedeployStockAccountSystem is MultisigProposal {
    string internal constant REGISTRY_KEY = "STOCK_ACCOUNT_REGISTRY";
    string internal constant PRICE_CHECKER_KEY = "STOCK_ACCOUNT_PRICE_CHECKER";
    string internal constant IMPL_KEY = "STOCK_ACCOUNT_STRATEGY_IMPL";
    string internal constant FACTORY_KEY = "STOCK_ACCOUNT_STRATEGY_FACTORY";

    string internal constant V1_REGISTRY_KEY = "STOCK_ACCOUNT_REGISTRY_DEPRECATED";
    string internal constant V1_FACTORY_KEY = "STOCK_ACCOUNT_STRATEGY_FACTORY_DEPRECATED";

    /// @notice The list this proposal executed with, frozen so later list edits do not rewrite it
    string public constant TOKEN_LIST = "./config/stock-accounts/8453-018.json";

    /// @notice The mamo-queues app, which creates accounts on users' behalf through the factory
    string internal constant QUEUES_KEY = "MAMO_BACKEND";

    address internal constant DEAD_SIGNER = 0x000000000000000000000000000000000000dEaD;

    /// @notice Price checker's sequencer grace period, same as proposals 013 and 016
    uint256 internal constant SEQUENCER_GRACE_PERIOD = 3600;

    /// @notice Slots 1-5 hold live implementations; slot 6 is reserved for the leveraged-Aero account
    uint256 internal constant GUARDED_SLOTS = 5;
    uint256 internal constant RESERVED_SLOT = 6;

    StockAccountsConfig public immutable deployConfig;
    uint256 public immutable strategyTypeId;

    address[GUARDED_SLOTS] internal _implementationsBefore;
    bool internal _slotsSnapshotted;

    constructor() {
        deployConfig = new StockAccountsConfig("./deploy/stock-accounts/8453_PROD-019.json");
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
        return "019_RedeployStockAccountSystem";
    }

    function description() public pure override returns (string memory) {
        return "Redeploy the stock accounts system (registry, price checker, account implementation, factory) under strategy type id 7, list the twelve stocks, move BACKEND_ROLE from the v1 factory to the new one, let the queues app create accounts on the new factory, and retire v1 by setting its order signer to a dead address and pausing its registry";
    }

    // ─── deploy: four contracts, each skipped when the address book already holds it ──────────────

    function deploy() public override {
        _deployStockRegistry();
        _deployPriceChecker();
        _deployImplementation();
        _deployFactory();
    }

    function _deployStockRegistry() internal {
        if (addresses.isAddressSet(REGISTRY_KEY)) return;

        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();

        StockAccountRegistry.Config memory registryConfig = StockAccountRegistry.Config({
            admin: addresses.getAddress(cfg.admin),
            aerodromeRouter: ISwapRouter(addresses.getAddress(cfg.aerodromeRouter)),
            asset: addresses.getAddress(cfg.asset),
            feeRecipient: addresses.getAddress(cfg.feeRecipient),
            guardian: addresses.getAddress(cfg.guardian),
            managementFeeBps: cfg.managementFeeBps,
            maxBackendSlippageBps: cfg.maxBackendSlippageBps,
            maxDeviationBps: cfg.maxDeviationBps,
            maxOrderValue: cfg.maxOrderValue,
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
            ISlippagePriceChecker(addresses.getAddress(cfg.existingPriceChecker)),
            addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"),
            SEQUENCER_GRACE_PERIOD
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
            strategyTypeId
        );
        vm.stopBroadcast();

        addresses.addAddress(FACTORY_KEY, address(factory), true);
    }

    // ─── preconditions + the node-native stand-in ────────────────────────────────────────────────

    function preBuildMock() public override {
        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        MamoStrategyRegistry mamoRegistry = _mamoRegistry();
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));
        StockAccountRegistry v1Registry = StockAccountRegistry(addresses.getAddress(V1_REGISTRY_KEY));

        // Every action is sent by the same Safe, across four contracts
        assertEq(addresses.getAddress(cfg.admin), multisig, "Stock registry admin should be MAMO_MULTISIG");
        assertTrue(
            mamoRegistry.hasRole(mamoRegistry.DEFAULT_ADMIN_ROLE(), multisig),
            "MAMO_MULTISIG should hold DEFAULT_ADMIN_ROLE on the Mamo registry"
        );
        assertTrue(
            stockRegistry.hasRole(stockRegistry.DEFAULT_ADMIN_ROLE(), multisig),
            "MAMO_MULTISIG should hold DEFAULT_ADMIN_ROLE on the v2 stock registry"
        );
        assertTrue(
            v1Registry.hasRole(v1Registry.DEFAULT_ADMIN_ROLE(), multisig),
            "MAMO_MULTISIG should hold DEFAULT_ADMIN_ROLE on the v1 stock registry"
        );
        assertTrue(
            v1Registry.hasRole(v1Registry.GUARDIAN_ROLE(), multisig),
            "MAMO_MULTISIG should hold GUARDIAN_ROLE on the v1 stock registry"
        );

        assertEq(strategyTypeId, 7, "strategyTypeId should be 7");
        assertEq(mamoRegistry.latestImplementationById(strategyTypeId), address(0), "Type id 7 is already taken");
        assertLt(mamoRegistry.nextStrategyTypeId(), strategyTypeId, "strategy type id is within reach of the counter");
        assertTrue(addresses.getAddress(cfg.feeRecipient) != address(0), "Fee recipient should be set");
        assertTrue(
            address(stockRegistry.priceChecker()) != addresses.getAddress(PRICE_CHECKER_KEY),
            "v2 stock registry already points at the deployed price checker"
        );

        assertFalse(v1Registry.paused(), "v1 stock registry is already paused");
        assertTrue(v1Registry.orderSigner() != DEAD_SIGNER, "v1 order signer is already dead");
        assertTrue(
            mamoRegistry.hasRole(mamoRegistry.BACKEND_ROLE(), addresses.getAddress(V1_FACTORY_KEY)),
            "v1 factory should still hold BACKEND_ROLE"
        );
        assertEq(addresses.getAddress(QUEUES_KEY).code.length, 0, "Queues app should be a plain EOA");
        // Paired with validate(): the role churn must not move BACKEND_ROLE index 0, which every
        // un-upgraded strategy proxy still reads as the backend (Sherlock #41, same pair as proposal 011)
        assertEq(
            mamoRegistry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 should be the strategy multicall before this proposal"
        );

        _snapshotGuardedSlots(mamoRegistry);
        _standInForNodeNativeTokens(stockRegistry);
    }

    function _snapshotGuardedSlots(MamoStrategyRegistry mamoRegistry) internal {
        for (uint256 id = 1; id <= GUARDED_SLOTS; id++) {
            address implementation = mamoRegistry.latestImplementationById(id);
            assertTrue(implementation != address(0), "Guarded strategy type slot is unexpectedly empty");
            _implementationsBefore[id - 1] = implementation;
        }
        assertEq(mamoRegistry.latestImplementationById(RESERVED_SLOT), address(0), "Reserved slot 6 is taken");
        _slotsSnapshotted = true;
    }

    /// @dev Same stand-in as proposal 016: the B20 stocks' code is 0xEF, which revm cannot execute
    function _standInForNodeNativeTokens(StockAccountRegistry stockRegistry) internal {
        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList(TOKEN_LIST);

        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(entries[i].source, "PoolTwap", string.concat(entries[i].symbol, " should be PoolTwap"));
            assertEq(
                uint256(stockRegistry.tokenConfig(entries[i].token).status),
                uint256(IStockAccountRegistry.TokenStatus.None),
                string.concat(entries[i].symbol, " is already listed on the v2 registry")
            );

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
        StockAccountRegistry v1Registry = StockAccountRegistry(addresses.getAddress(V1_REGISTRY_KEY));
        MamoStrategyRegistry mamoRegistry = _mamoRegistry();

        // Must precede every listing: the listing probe quotes through the registry's checker
        stockRegistry.setPriceChecker(ISlippagePriceChecker(addresses.getAddress(PRICE_CHECKER_KEY)));

        mamoRegistry.whitelistImplementation(addresses.getAddress(IMPL_KEY), strategyTypeId);
        mamoRegistry.grantRole(mamoRegistry.BACKEND_ROLE(), addresses.getAddress(FACTORY_KEY));
        mamoRegistry.revokeRole(mamoRegistry.BACKEND_ROLE(), addresses.getAddress(V1_FACTORY_KEY));

        StockAccountStrategyFactory factory = StockAccountStrategyFactory(addresses.getAddress(FACTORY_KEY));
        factory.grantRole(factory.BACKEND_ROLE(), addresses.getAddress(QUEUES_KEY));

        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList(TOKEN_LIST);
        for (uint256 i = 0; i < entries.length; i++) {
            stockRegistry.listToken(entries[i].token, _poolTwapConfig(entries[i].pool));
        }

        // Signer first: `setOrderSigner` stays open while paused, but there is no reason to rely on it
        v1Registry.setOrderSigner(DEAD_SIGNER);
        v1Registry.pause();
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("MAMO_MULTISIG"));
    }

    // ─── post-conditions ─────────────────────────────────────────────────────────────────────────

    function validate() public view override {
        _validateWiring();
        _validateGuardedSlots();
        _validateStockRegistryConfig();
        _validateFactoryConfig();
        _validateTokenList();
        _validateV1Retired();
    }

    function _validateWiring() internal view {
        StockAccountsConfig.DeploymentConfig memory cfg = deployConfig.getConfig();
        MamoStrategyRegistry mamoRegistry = _mamoRegistry();
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));
        address priceChecker = addresses.getAddress(PRICE_CHECKER_KEY);
        address implementation = addresses.getAddress(IMPL_KEY);

        assertEq(address(stockRegistry.priceChecker()), priceChecker, "v2 registry should point at the v2 checker");

        assertTrue(mamoRegistry.whitelistedImplementations(implementation), "Implementation should be whitelisted");
        assertEq(mamoRegistry.implementationToId(implementation), strategyTypeId, "Implementation should map to 7");
        assertEq(mamoRegistry.latestImplementationById(strategyTypeId), implementation, "Type id 7 should map back");

        assertTrue(
            mamoRegistry.hasRole(mamoRegistry.BACKEND_ROLE(), addresses.getAddress(FACTORY_KEY)),
            "v2 factory should hold BACKEND_ROLE"
        );
        assertFalse(
            mamoRegistry.hasRole(mamoRegistry.BACKEND_ROLE(), addresses.getAddress(V1_FACTORY_KEY)),
            "v1 factory should no longer hold BACKEND_ROLE"
        );
        assertEq(
            mamoRegistry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 must not move"
        );

        StockAccountPriceChecker checker = StockAccountPriceChecker(priceChecker);
        assertEq(address(checker.registry()), address(stockRegistry), "Checker registry mismatch");
        assertEq(checker.quoteAsset(), addresses.getAddress(cfg.asset), "Checker quote asset mismatch");
        assertEq(
            address(checker.existingChecker()),
            addresses.getAddress(cfg.existingPriceChecker),
            "Checker existingChecker mismatch"
        );
        assertEq(
            checker.sequencerUptimeFeed(),
            addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"),
            "Checker sequencer feed mismatch"
        );
        assertEq(checker.sequencerGracePeriod(), SEQUENCER_GRACE_PERIOD, "Checker grace period mismatch");
    }

    function _validateGuardedSlots() internal view {
        assertTrue(_slotsSnapshotted, "Guarded slots were never snapshotted; run preBuildMock");

        MamoStrategyRegistry mamoRegistry = _mamoRegistry();
        for (uint256 id = 1; id <= GUARDED_SLOTS; id++) {
            assertEq(
                mamoRegistry.latestImplementationById(id),
                _implementationsBefore[id - 1],
                "An existing strategy type slot was overwritten"
            );
        }
        assertEq(mamoRegistry.latestImplementationById(RESERVED_SLOT), address(0), "Reserved slot 6 was written");
    }

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
        assertEq(stockRegistry.feeRecipient(), addresses.getAddress(cfg.feeRecipient), "Registry feeRecipient mismatch");
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
        assertEq(stockRegistry.maxOrderValue(), cfg.maxOrderValue, "Registry maxOrderValue mismatch");
        assertFalse(stockRegistry.paused(), "v2 registry should not be paused");

        assertTrue(
            stockRegistry.hasRole(stockRegistry.DEFAULT_ADMIN_ROLE(), addresses.getAddress(cfg.admin)),
            "Registry admin role mismatch"
        );
        assertTrue(
            stockRegistry.hasRole(stockRegistry.GUARDIAN_ROLE(), addresses.getAddress(cfg.guardian)),
            "Registry guardian role mismatch"
        );
    }

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

        assertTrue(
            factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), addresses.getAddress(cfg.admin)), "Factory admin mismatch"
        );
        assertTrue(
            factory.hasRole(factory.BACKEND_ROLE(), addresses.getAddress(cfg.backend)), "Factory backend mismatch"
        );
        assertTrue(
            factory.hasRole(factory.BACKEND_ROLE(), addresses.getAddress(QUEUES_KEY)),
            "Queues app should hold the factory's BACKEND_ROLE"
        );
        // The factory grant is all the queues app needs; the Mamo registry's role would make it backend on every strategy
        MamoStrategyRegistry mamoRegistry = _mamoRegistry();
        assertFalse(
            mamoRegistry.hasRole(mamoRegistry.BACKEND_ROLE(), addresses.getAddress(QUEUES_KEY)),
            "Queues app should not hold BACKEND_ROLE on the Mamo registry"
        );
    }

    function _validateTokenList() internal view {
        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList(TOKEN_LIST);
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));
        ISlippagePriceChecker checker = ISlippagePriceChecker(addresses.getAddress(PRICE_CHECKER_KEY));
        address asset = stockRegistry.asset();

        assertEq(stockRegistry.allTokens().length, entries.length, "Listed token count mismatch");

        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(
                keccak256(abi.encode(stockRegistry.tokenConfig(entries[i].token))),
                keccak256(abi.encode(_poolTwapConfig(entries[i].pool))),
                string.concat(entries[i].symbol, " should be Active PoolTwap on its configured pool")
            );
            assertGt(
                checker.getExpectedOut(10 ** entries[i].decimals, entries[i].token, asset),
                0,
                string.concat(entries[i].symbol, " should quote a non-zero price")
            );
        }
    }

    function _validateV1Retired() internal view {
        StockAccountRegistry v1Registry = StockAccountRegistry(addresses.getAddress(V1_REGISTRY_KEY));

        assertTrue(v1Registry.paused(), "v1 registry should be paused");
        assertEq(v1Registry.orderSigner(), DEAD_SIGNER, "v1 order signer should be dead");
    }

    function _poolTwapConfig(address pool) internal pure returns (IStockAccountRegistry.TokenConfig memory) {
        return IStockAccountRegistry.TokenConfig({
            status: IStockAccountRegistry.TokenStatus.Active,
            source: IStockAccountRegistry.PriceSource.PoolTwap,
            pool: pool,
            chainlinkFeed: address(0)
        });
    }

    function _mamoRegistry() internal view returns (MamoStrategyRegistry) {
        return MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
    }

    function _initializeAddresses() internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }
}
