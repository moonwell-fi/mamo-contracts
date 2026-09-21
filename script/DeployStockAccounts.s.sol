// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountsConfig} from "./StockAccountsConfig.sol";

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

/**
 * @title DeployStockAccounts
 * @notice Deploys the stock accounts system and wires it into the MamoStrategyRegistry
 * @dev The registry constructor needs a price checker with code, and the price checker needs the
 *      registry, so the registry is deployed with the configured placeholder and pointed at the real
 *      StockAccountPriceChecker right after
 * @dev Env: DEPLOY_ENV (default 8453_TESTING), ADDRESSES_PATH (default ./addresses),
 *      ADMIN_MODE (impersonate | calldata)
 */
contract DeployStockAccounts is Script {
    string internal constant REGISTRY_NAME = "STOCK_ACCOUNT_REGISTRY";
    string internal constant PRICE_CHECKER_NAME = "STOCK_ACCOUNT_PRICE_CHECKER";
    string internal constant IMPL_NAME = "STOCK_ACCOUNT_STRATEGY_IMPL";
    string internal constant FACTORY_NAME = "STOCK_ACCOUNT_STRATEGY_FACTORY";

    /// @notice Staleness bound of the USDC/USD hop every Chainlink entry is quoted through
    /// @dev Deliberately above the feed's nominal 86,400 heartbeat. Walking the live Base aggregator
    ///      over 31.8 days, 31 of its 32 round gaps ran past 86,400 (median 86,418, longest 86,490):
    ///      the node fires tens of seconds late almost every cycle. The checker enforces the bound
    ///      strictly and valuation has no try/catch, so at 86,400 the quote reverts for a minute or so
    ///      each day, taking account value, weights, deposits, withdrawals and order validation with
    ///      it. Do not tighten this back to the nominal heartbeat
    uint256 internal constant USDC_USD_HEARTBEAT = 90_000;

    Addresses internal addresses;
    StockAccountsConfig internal configLoader;
    StockAccountsConfig.DeploymentConfig internal config;
    bool internal calldataMode;

    function run() external {
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_TESTING"));
        string memory addressesPath = vm.envOr("ADDRESSES_PATH", string("./addresses"));
        string memory adminMode = vm.envOr("ADMIN_MODE", string("impersonate"));

        calldataMode = keccak256(bytes(adminMode)) == keccak256(bytes("calldata"));
        require(calldataMode || keccak256(bytes(adminMode)) == keccak256(bytes("impersonate")), "Unknown ADMIN_MODE");

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesPath, chainIds);
        configLoader = new StockAccountsConfig(string.concat("./deploy/stock-accounts/", environment, ".json"));
        config = configLoader.getConfig();

        console.log("environment: %s", environment);
        console.log("admin mode: %s", adminMode);

        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        address stockRegistry = _deployStockRegistry();
        address priceChecker = _deployPriceChecker(stockRegistry);
        _setPriceChecker(stockRegistry, priceChecker);
        address implementation = _deployImplementation();
        uint256 strategyTypeId = _whitelistImplementation(mamoRegistry, implementation);
        address factory = _deployFactory(stockRegistry, implementation, strategyTypeId);
        _grantBackendRole(mamoRegistry, factory);
        _listTokens(stockRegistry);

        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("STOCK_ACCOUNT_REGISTRY: %s", stockRegistry);
        console.log("STOCK_ACCOUNT_PRICE_CHECKER: %s", priceChecker);
        console.log("STOCK_ACCOUNT_STRATEGY_IMPL: %s", implementation);
        console.log("STOCK_ACCOUNT_STRATEGY_FACTORY: %s", factory);
        console.log("strategyTypeId: %s", strategyTypeId);
    }

    /// @notice Deploys the StockAccountRegistry, or returns the one already recorded in addresses
    function _deployStockRegistry() internal returns (address) {
        if (addresses.isAddressSet(REGISTRY_NAME)) {
            address existing = addresses.getAddress(REGISTRY_NAME);
            console.log("step 1 skipped, %s already deployed at %s", REGISTRY_NAME, existing);
            return existing;
        }

        StockAccountRegistry.Config memory registryConfig = StockAccountRegistry.Config({
            admin: addresses.getAddress(config.admin),
            aerodromeRouter: ISwapRouter(addresses.getAddress(config.aerodromeRouter)),
            asset: addresses.getAddress(config.asset),
            guardian: addresses.getAddress(config.guardian),
            managementFeeBps: config.managementFeeBps,
            maxBackendSlippageBps: config.maxBackendSlippageBps,
            maxDeviationBps: config.maxDeviationBps,
            maxPositions: config.maxPositions,
            maxStrategyDeposit: config.maxStrategyDeposit,
            maxWithdrawSlippageBps: config.maxWithdrawSlippageBps,
            minStrategyDeposit: config.minStrategyDeposit,
            minTargetBps: config.minTargetBps,
            orderSigner: addresses.getAddress(config.orderSigner),
            priceChecker: ISlippagePriceChecker(addresses.getAddress(config.placeholderPriceChecker)),
            twapWindow: config.twapWindow
        });

        vm.startBroadcast();
        StockAccountRegistry registry = new StockAccountRegistry(registryConfig);
        vm.stopBroadcast();

        addresses.addAddress(REGISTRY_NAME, address(registry), true);
        console.log("step 1: StockAccountRegistry deployed at %s", address(registry));

        return address(registry);
    }

    /// @notice Deploys the StockAccountPriceChecker for the stock registry, or returns the recorded one
    function _deployPriceChecker(address stockRegistry) internal returns (address) {
        if (addresses.isAddressSet(PRICE_CHECKER_NAME)) {
            address existing = addresses.getAddress(PRICE_CHECKER_NAME);
            console.log("step 2 skipped, %s already deployed at %s", PRICE_CHECKER_NAME, existing);
            return existing;
        }

        vm.startBroadcast();
        StockAccountPriceChecker priceChecker = new StockAccountPriceChecker(
            IStockAccountRegistry(stockRegistry),
            addresses.getAddress(config.asset),
            ISlippagePriceChecker(addresses.getAddress(config.existingPriceChecker))
        );
        vm.stopBroadcast();

        addresses.addAddress(PRICE_CHECKER_NAME, address(priceChecker), true);
        console.log("step 2: StockAccountPriceChecker deployed at %s", address(priceChecker));

        return address(priceChecker);
    }

    /// @notice Points the stock registry at the deployed price checker, replacing the config placeholder
    function _setPriceChecker(address stockRegistry, address priceChecker) internal {
        if (address(IStockAccountRegistry(stockRegistry).priceChecker()) == priceChecker) {
            console.log("step 3 skipped, the stock registry already points at %s", priceChecker);
            return;
        }

        console.log("step 3: setting the stock registry price checker");

        bytes memory data = abi.encodeCall(StockAccountRegistry.setPriceChecker, (ISlippagePriceChecker(priceChecker)));
        _adminCall(stockRegistry, data, "setPriceChecker");
    }

    /// @notice Deploys the StockAccountStrategy implementation, or returns the recorded one
    function _deployImplementation() internal returns (address) {
        if (addresses.isAddressSet(IMPL_NAME)) {
            address existing = addresses.getAddress(IMPL_NAME);
            console.log("step 4 skipped, %s already deployed at %s", IMPL_NAME, existing);
            return existing;
        }

        vm.startBroadcast();
        StockAccountStrategy implementation = new StockAccountStrategy();
        vm.stopBroadcast();

        addresses.addAddress(IMPL_NAME, address(implementation), true);
        console.log("step 4: StockAccountStrategy implementation deployed at %s", address(implementation));

        return address(implementation);
    }

    /// @notice Whitelists the implementation on the MamoStrategyRegistry and returns its strategy type id
    function _whitelistImplementation(MamoStrategyRegistry mamoRegistry, address implementation)
        internal
        returns (uint256 strategyTypeId)
    {
        if (mamoRegistry.whitelistedImplementations(implementation)) {
            strategyTypeId = mamoRegistry.implementationToId(implementation);
            console.log("step 5 skipped, implementation already whitelisted with type id %s", strategyTypeId);
            return strategyTypeId;
        }

        strategyTypeId = mamoRegistry.nextStrategyTypeId();

        console.log("step 5: whitelisting the implementation");

        bytes memory data = abi.encodeCall(MamoStrategyRegistry.whitelistImplementation, (implementation, 0));
        if (_adminCall(address(mamoRegistry), data, "whitelistImplementation")) {
            require(mamoRegistry.implementationToId(implementation) == strategyTypeId, "Unexpected strategy type id");
        }

        console.log("step 5: strategy type id is %s", strategyTypeId);
    }

    /// @notice Deploys the StockAccountStrategyFactory, or returns the one already recorded in addresses
    function _deployFactory(address stockRegistry, address implementation, uint256 strategyTypeId)
        internal
        returns (address)
    {
        if (addresses.isAddressSet(FACTORY_NAME)) {
            address existing = addresses.getAddress(FACTORY_NAME);
            console.log("step 6 skipped, %s already deployed at %s", FACTORY_NAME, existing);
            return existing;
        }

        vm.startBroadcast();
        StockAccountStrategyFactory factory = new StockAccountStrategyFactory(
            addresses.getAddress(config.admin),
            addresses.getAddress(config.backend),
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            stockRegistry,
            addresses.getAddress(config.asset),
            addresses.getAddress(config.cowSettlement),
            implementation,
            strategyTypeId,
            addresses.getAddress(config.feeRecipient)
        );
        vm.stopBroadcast();

        addresses.addAddress(FACTORY_NAME, address(factory), true);
        console.log("step 6: StockAccountStrategyFactory deployed at %s", address(factory));

        return address(factory);
    }

    /// @notice Grants the MamoStrategyRegistry backend role to the factory so it can register accounts
    function _grantBackendRole(MamoStrategyRegistry mamoRegistry, address factory) internal {
        bytes32 backendRole = mamoRegistry.BACKEND_ROLE();

        if (mamoRegistry.hasRole(backendRole, factory)) {
            console.log("step 7 skipped, factory already holds BACKEND_ROLE");
            return;
        }

        console.log("step 7: granting BACKEND_ROLE to the factory");

        bytes memory data = abi.encodeCall(IAccessControl.grantRole, (backendRole, factory));
        _adminCall(address(mamoRegistry), data, "grantRole(BACKEND_ROLE, factory)");
    }

    /// @notice Lists every token of config/stock-accounts/<chainId>.json that the stock registry does not hold yet
    /// @dev A Chainlink entry is configured on the existing price checker first: the listing is probed
    ///      through it, so an unconfigured pair would be refused with TokenNotPriceable
    function _listTokens(address stockRegistry) internal {
        StockAccountsConfig.TokenListEntry[] memory entries = configLoader.loadTokenList();

        if (entries.length == 0) {
            console.log("step 8: no tokens to list");
            return;
        }

        for (uint256 i = 0; i < entries.length; i++) {
            bool isChainlink = keccak256(bytes(entries[i].source)) == keccak256(bytes("Chainlink"));

            IStockAccountRegistry.TokenStatus status =
                IStockAccountRegistry(stockRegistry).tokenConfig(entries[i].token).status;

            if (status != IStockAccountRegistry.TokenStatus.None) {
                console.log("step 8 skipped for %s, already listed", entries[i].symbol);
                continue;
            }

            if (isChainlink) _configureExistingChecker(entries[i]);

            IStockAccountRegistry.TokenConfig memory cfg = IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: isChainlink
                    ? IStockAccountRegistry.PriceSource.Chainlink
                    : IStockAccountRegistry.PriceSource.PoolTwap,
                pool: entries[i].pool,
                chainlinkFeed: entries[i].chainlinkFeed
            });

            bytes memory data = abi.encodeCall(StockAccountRegistry.listToken, (entries[i].token, cfg));
            string memory label = string.concat("listToken(", entries[i].symbol, ")");

            if (!calldataMode && _isNodePrecompile(entries[i].token)) {
                console.log("step 8: %s is a node precompile, send this listing with cast", entries[i].symbol);
                _printCall(stockRegistry, addresses.getAddress(config.admin), data, label);
                continue;
            }

            _adminCall(stockRegistry, data, label);
        }
    }

    /// @notice Configures a Chainlink entry's token -> asset pair on the existing price checker
    /// @dev Two hops, feed -> USD -> asset, the shape every other Mamo config uses; the calls go to the
    ///      checker's own owner, which is not the stock registry admin
    function _configureExistingChecker(StockAccountsConfig.TokenListEntry memory entry) internal {
        require(entry.heartbeat > 0, string.concat("Chainlink entry needs a heartbeat: ", entry.symbol));

        ISlippagePriceChecker existing = ISlippagePriceChecker(addresses.getAddress(config.existingPriceChecker));
        address owner = IERC5313(address(existing)).owner();
        address asset = addresses.getAddress(config.asset);

        if (existing.tokenPairOracleInformation(entry.token, asset).length == 0) {
            ISlippagePriceChecker.TokenFeedConfiguration[] memory cfgs =
                new ISlippagePriceChecker.TokenFeedConfiguration[](2);
            cfgs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
                chainlinkFeed: entry.chainlinkFeed,
                reverse: false,
                heartbeat: entry.heartbeat
            });
            cfgs[1] = ISlippagePriceChecker.TokenFeedConfiguration({
                chainlinkFeed: addresses.getAddress("CHAINLINK_USDC_USD"),
                reverse: true,
                heartbeat: USDC_USD_HEARTBEAT
            });

            _adminCall(
                address(existing),
                owner,
                abi.encodeCall(ISlippagePriceChecker.addTokenConfiguration, (entry.token, asset, cfgs)),
                string.concat("addTokenConfiguration(", entry.symbol, ")")
            );
        } else {
            console.log("step 8: %s already configured on the existing price checker", entry.symbol);
        }

        if (existing.maxTimePriceValid(entry.token) == 0) {
            _adminCall(
                address(existing),
                owner,
                abi.encodeCall(ISlippagePriceChecker.setMaxTimePriceValid, (entry.token, entry.heartbeat)),
                string.concat("setMaxTimePriceValid(", entry.symbol, ")")
            );
        } else {
            console.log("step 8: %s already has a max time price valid", entry.symbol);
        }
    }

    /**
     * @notice Executes an admin call as the holder of the admin role, or prints it for the Safe
     * @param target The contract the admin call is made on
     * @param data The calldata of the admin call
     * @param label A short name of the call, used in the logs
     * @return executed True when the call was executed, false when only its calldata was printed
     */
    function _adminCall(address target, bytes memory data, string memory label) internal returns (bool executed) {
        address admin = target == addresses.getAddress("MAMO_STRATEGY_REGISTRY")
            ? addresses.getAddress("MAMO_MULTISIG")
            : addresses.getAddress(config.admin);

        return _adminCall(target, admin, data, label);
    }

    /**
     * @notice Executes an admin call as a named holder, or prints it for the Safe
     * @param target The contract the admin call is made on
     * @param admin The account holding the rights the call needs
     * @param data The calldata of the admin call
     * @param label A short name of the call, used in the logs
     * @return executed True when the call was executed, false when only its calldata was printed
     */
    function _adminCall(address target, address admin, bytes memory data, string memory label)
        internal
        returns (bool executed)
    {
        if (calldataMode) {
            _printCall(target, admin, data, label);
            return false;
        }

        vm.startBroadcast(admin);
        (bool success,) = target.call(data);
        vm.stopBroadcast();
        require(success, string.concat("Admin call failed: ", label));

        console.log("admin call %s executed by %s", label, admin);
        return true;
    }

    /// @notice Prints an admin call for whoever executes it out of band
    function _printCall(address target, address admin, bytes memory data, string memory label) internal pure {
        console.log("admin call %s", label);
        console.log("  from: %s", admin);
        console.log("  to: %s", target);
        console.log("  data: %s", vm.toString(data));
    }

    /**
     * @notice Whether a token is a node-native precompile, whose code is the single reserved byte 0xEF
     * @dev revm refuses to execute that byte, so any call into such a token reverts in a forge
     *      simulation even when the script is broadcasting to a node that serves it. The listing probe
     *      reads decimals(), so those listings have to be sent straight to the node with cast
     */
    function _isNodePrecompile(address token) internal view returns (bool) {
        bytes memory code = token.code;
        return code.length == 1 && code[0] == 0xEF;
    }
}
