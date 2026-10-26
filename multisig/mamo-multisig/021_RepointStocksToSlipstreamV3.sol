// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";
import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";

/**
 * @title RepointStocksToSlipstreamV3
 * @notice Multisig proposal that moves the V2 stock registry onto Aerodrome Slipstream V3: the swap router
 *         becomes the V3 router, and every stock whose listed pool differs from `config/stock-accounts/8453.json`
 *         is halted, repointed to its configured V3 pool and reactivated
 * @dev Built from the diff between the config and the registry, so it is idempotent. The router goes first, since
 *      `setTokenPool` requires the pool to come from the router's factory, and reactivation re-runs the registry's
 *      priceability check on the new pool. B20 stocks are stood in for exactly as in proposal 016.
 */
contract RepointStocksToSlipstreamV3 is MultisigProposal {
    string internal constant REGISTRY_KEY = "STOCK_ACCOUNT_REGISTRY";
    string internal constant ROUTER_KEY = "AERODROME_SLIPSTREAM_V3_SWAP_ROUTER";
    string internal constant FACTORY_KEY = "AERODROME_SLIPSTREAM_V3_CL_FACTORY";

    StockAccountsConfig public immutable deployConfig;

    /// @dev Every registry parameter other than the router, and the token list, as they read before the batch
    bytes32 internal _parametersBefore;
    address[] internal _tokensBefore;
    bool internal _snapshotted;

    constructor() {
        deployConfig = new StockAccountsConfig("./deploy/stock-accounts/8453_PROD.json");
        vm.makePersistent(address(deployConfig));
    }

    function run() public override {
        _initializeAddresses();

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
    }

    function name() public pure override returns (string memory) {
        return "021_RepointStocksToSlipstreamV3";
    }

    function description() public pure override returns (string memory) {
        return "Point the stock registry at the Aerodrome Slipstream V3 router and move every stock to its V3 USDC pool";
    }

    function preBuildMock() public override {
        StockAccountRegistry stockRegistry = _registry();
        address factory = addresses.getAddress(FACTORY_KEY);

        assertTrue(
            stockRegistry.hasRole(stockRegistry.DEFAULT_ADMIN_ROLE(), addresses.getAddress("MAMO_MULTISIG")),
            "MAMO_MULTISIG should hold DEFAULT_ADMIN_ROLE on the stock registry"
        );
        assertFalse(stockRegistry.paused(), "Stock registry is paused");
        assertEq(ISwapRouter(addresses.getAddress(ROUTER_KEY)).factory(), factory, "V3 router should use V3 factory");

        _parametersBefore = _parameters();
        _tokensBefore = stockRegistry.allTokens();

        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList();
        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(
                uint256(stockRegistry.tokenConfig(entries[i].token).status),
                uint256(IStockAccountRegistry.TokenStatus.Active),
                string.concat(entries[i].symbol, " should be listed and Active")
            );
            assertEq(ICLPool(entries[i].pool).factory(), factory, string.concat(entries[i].symbol, " pool not V3"));

            bytes memory code = entries[i].token.code;
            if (code.length != 1 || code[0] != 0xEF) continue;

            vm.etch(entries[i].token, address(new MockERC20Decimals(entries[i].symbol, entries[i].decimals)).code);
            assertEq(
                IERC20Metadata(entries[i].token).decimals(),
                entries[i].decimals,
                "Stand-in should report the configured decimals"
            );
        }
        _snapshotted = true;
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        StockAccountRegistry stockRegistry = _registry();
        ISwapRouter router = ISwapRouter(addresses.getAddress(ROUTER_KEY));

        if (stockRegistry.aerodromeRouter() != router) stockRegistry.setAerodromeRouter(router);

        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList();
        for (uint256 i = 0; i < entries.length; i++) {
            if (stockRegistry.tokenConfig(entries[i].token).pool == entries[i].pool) continue;

            stockRegistry.setTokenStatus(entries[i].token, IStockAccountRegistry.TokenStatus.Halted);
            stockRegistry.setTokenPool(entries[i].token, entries[i].pool);
            stockRegistry.setTokenStatus(entries[i].token, IStockAccountRegistry.TokenStatus.Active);
        }
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("MAMO_MULTISIG"));
    }

    function validate() public view override {
        assertTrue(_snapshotted, "Registry was never snapshotted; run preBuildMock");

        StockAccountRegistry stockRegistry = _registry();
        address asset = stockRegistry.asset();

        assertEq(_parameters(), _parametersBefore, "A registry parameter changed");
        assertEq(address(stockRegistry.aerodromeRouter()), addresses.getAddress(ROUTER_KEY), "Router should be V3");
        assertEq(keccak256(abi.encode(stockRegistry.allTokens())), keccak256(abi.encode(_tokensBefore)), "List moved");

        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList();
        assertEq(entries.length, _tokensBefore.length, "Config should cover every listing");
        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(
                keccak256(abi.encode(stockRegistry.tokenConfig(entries[i].token))),
                keccak256(
                    abi.encode(
                        IStockAccountRegistry.TokenConfig({
                            status: IStockAccountRegistry.TokenStatus.Active,
                            source: IStockAccountRegistry.PriceSource.PoolTwap,
                            pool: entries[i].pool,
                            chainlinkFeed: address(0)
                        })
                    )
                ),
                string.concat(entries[i].symbol, " should be Active on its V3 pool")
            );
            assertGt(
                stockRegistry.priceChecker().getExpectedOut(10 ** entries[i].decimals, entries[i].token, asset),
                0,
                string.concat(entries[i].symbol, " should quote a non-zero price")
            );
        }
    }

    /// @dev Every value the admin, guardian or a setter can change, other than the router and the token list
    function _parameters() internal view returns (bytes32) {
        StockAccountRegistry r = _registry();
        return keccak256(
            abi.encode(
                r.priceChecker(),
                r.orderSigner(),
                r.paused(),
                r.maxPositions(),
                r.minTargetBps(),
                r.maxDeviationBps(),
                r.maxBackendSlippageBps(),
                r.maxWithdrawSlippageBps(),
                r.managementFeeBps(),
                r.feeRecipient(),
                r.twapWindow(),
                r.minStrategyDeposit(),
                r.maxStrategyDeposit()
            )
        );
    }

    function _registry() internal view returns (StockAccountRegistry) {
        return StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));
    }

    function _initializeAddresses() internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }
}
