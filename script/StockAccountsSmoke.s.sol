// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

/**
 * @title StockAccountsSmoke
 * @notice Creates one all-cash stock account against a deployed system, deposits USDC and checks the NAV
 * @dev Env: ADDRESSES_PATH (default ./addresses), TEST_USER (default DEPLOYER_EOA),
 *      SMOKE_DEPOSIT (default 1000e6), TENDERLY_VNET_RPC_URL (recorded in the manifest)
 */
contract StockAccountsSmoke is Script {
    string internal constant MANIFEST_PATH = "./script/stock-accounts/vnet-manifest.json";

    function run() external {
        string memory addressesPath = vm.envOr("ADDRESSES_PATH", string("./addresses"));

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        Addresses addresses = new Addresses(addressesPath, chainIds);

        address user = vm.envOr("TEST_USER", addresses.getAddress("DEPLOYER_EOA"));
        uint256 depositAmount = vm.envOr("SMOKE_DEPOSIT", uint256(1_000e6));

        StockAccountStrategyFactory factory =
            StockAccountStrategyFactory(addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY"));
        IERC20 asset = IERC20(factory.asset());

        address priceChecker = addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER");
        address wired = address(IStockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY")).priceChecker());
        require(wired == priceChecker, "Stock registry does not point at STOCK_ACCOUNT_PRICE_CHECKER");

        address account = factory.computeStrategyAddress(user);
        bool created = account.code.length == 0;

        if (created) {
            IStockAccountStrategy.BasketEntry[] memory entries = new IStockAccountStrategy.BasketEntry[](0);

            vm.startBroadcast(user);
            factory.createStrategyForUser(user, entries, 10_000);
            vm.stopBroadcast();

            console.log("account created at %s", account);
        } else {
            console.log("account already exists at %s", account);
        }

        require(asset.balanceOf(user) >= depositAmount, "Test user is short of the asset");

        uint256 navBefore = StockAccountStrategy(payable(account)).getNAV();

        vm.startBroadcast(user);
        asset.approve(account, depositAmount);
        StockAccountStrategy(payable(account)).deposit(depositAmount);
        vm.stopBroadcast();

        uint256 nav = StockAccountStrategy(payable(account)).getNAV();
        console.log("NAV: %s", nav);
        // A rerun against an existing account nets off the management fee accrued since the last one
        if (created) {
            require(nav == depositAmount, "Unexpected NAV after deposit");
        } else {
            require(nav > navBefore, "NAV did not grow after deposit");
        }

        _writeManifest(addresses, factory, user, account);
    }

    /// @notice Records the deployed addresses and the smoke account so the backend can pick the vnet up
    function _writeManifest(Addresses addresses, StockAccountStrategyFactory factory, address user, address account)
        internal
    {
        string memory json = "manifest";

        vm.serializeString(json, "rpc", vm.envOr("TENDERLY_VNET_RPC_URL", string("")));
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "STOCK_ACCOUNT_REGISTRY", addresses.getAddress("STOCK_ACCOUNT_REGISTRY"));
        vm.serializeAddress(json, "STOCK_ACCOUNT_PRICE_CHECKER", addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER"));
        vm.serializeAddress(json, "STOCK_ACCOUNT_STRATEGY_IMPL", addresses.getAddress("STOCK_ACCOUNT_STRATEGY_IMPL"));
        vm.serializeAddress(json, "STOCK_ACCOUNT_STRATEGY_FACTORY", address(factory));
        vm.serializeAddress(json, "AERODROME_STOCKS_CL_FACTORY", addresses.getAddress("AERODROME_STOCKS_CL_FACTORY"));
        vm.serializeAddress(json, "AERODROME_STOCKS_SWAP_ROUTER", addresses.getAddress("AERODROME_STOCKS_SWAP_ROUTER"));
        vm.serializeAddress(json, "AERODROME_STOCKS_QUOTER", addresses.getAddress("AERODROME_STOCKS_QUOTER"));
        vm.serializeAddress(
            json, "AERODROME_STOCKS_POSITION_MANAGER", addresses.getAddress("AERODROME_STOCKS_POSITION_MANAGER")
        );
        vm.serializeUint(json, "strategyTypeId", factory.strategyTypeId());
        vm.serializeAddress(json, "testUser", user);
        vm.serializeAddress(json, "testUserAccount", account);

        // The appData is per account: the backend uploads this document to the CoW API under its hash
        vm.serializeBytes32(json, "appDataHash", StockAccountStrategy(payable(account)).appDataHash());
        string memory out =
            vm.serializeString(json, "appDataDocument", StockAccountStrategy(payable(account)).appDataDocument());

        vm.writeJson(out, MANIFEST_PATH);
        console.log("manifest written to %s", MANIFEST_PATH);
    }
}
