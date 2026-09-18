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

    /// @notice A token to list on the stock registry, as read from config/stock-accounts/<chainId>.json
    struct TokenListEntry {
        string chainlinkFeed;
        string pool;
        string source;
        string symbol;
        address token;
    }

    Addresses internal addresses;
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
        config = new StockAccountsConfig(string.concat("./deploy/stock-accounts/", environment, ".json")).getConfig();

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
    function _listTokens(address stockRegistry) internal {
        string memory path = string.concat("./config/stock-accounts/", vm.toString(config.chainId), ".json");

        if (!vm.isFile(path)) {
            console.log("step 8: no token config at %s, nothing to list", path);
            return;
        }

        bytes memory raw = vm.parseJson(vm.readFile(path), ".tokens");
        TokenListEntry[] memory entries =
            raw.length == 0 ? new TokenListEntry[](0) : abi.decode(raw, (TokenListEntry[]));

        if (entries.length == 0) {
            console.log("step 8: no tokens to list");
            return;
        }

        for (uint256 i = 0; i < entries.length; i++) {
            IStockAccountRegistry.TokenStatus status =
                IStockAccountRegistry(stockRegistry).tokenConfig(entries[i].token).status;

            if (status != IStockAccountRegistry.TokenStatus.None) {
                console.log("step 8 skipped for %s, already listed", entries[i].symbol);
                continue;
            }

            IStockAccountRegistry.TokenConfig memory cfg = IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: keccak256(bytes(entries[i].source)) == keccak256(bytes("Chainlink"))
                    ? IStockAccountRegistry.PriceSource.Chainlink
                    : IStockAccountRegistry.PriceSource.PoolTwap,
                pool: _parseOptionalAddress(entries[i].pool),
                chainlinkFeed: _parseOptionalAddress(entries[i].chainlinkFeed)
            });

            bytes memory data = abi.encodeCall(StockAccountRegistry.listToken, (entries[i].token, cfg));
            _adminCall(stockRegistry, data, string.concat("listToken(", entries[i].symbol, ")"));
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

        if (calldataMode) {
            console.log("admin call %s", label);
            console.log("  from: %s", admin);
            console.log("  to: %s", target);
            console.log("  data: %s", vm.toString(data));
            return false;
        }

        vm.startBroadcast(admin);
        (bool success,) = target.call(data);
        vm.stopBroadcast();
        require(success, string.concat("Admin call failed: ", label));

        console.log("admin call %s executed by %s", label, admin);
        return true;
    }

    /// @notice Parses an address written as a hex string, treating an empty string as the zero address
    function _parseOptionalAddress(string memory value) internal pure returns (address) {
        return bytes(value).length == 0 ? address(0) : vm.parseAddress(value);
    }
}
