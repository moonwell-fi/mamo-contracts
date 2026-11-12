// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";
import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";

/**
 * @title ListStockUniverse
 * @notice Multisig proposal that halts cbBTC on the live stock registry and lists every token in
 *         `config/stock-accounts/8453-018.json` the registry does not know yet, all as PoolTwap
 * @dev Built from the diff between the config and the registry, so it is idempotent. B20 stocks are
 *      stood in for exactly as in proposal 016, so their `decimals()` probes can execute in revm.
 */
contract ListStockUniverse is MultisigProposal {
    string internal constant REGISTRY_KEY = "STOCK_ACCOUNT_REGISTRY_DEPRECATED";

    /// @notice The list this proposal executed with, frozen so later list edits do not rewrite it
    string public constant TOKEN_LIST = "./config/stock-accounts/8453-018.json";

    StockAccountsConfig public immutable deployConfig;

    /// @dev Every registry parameter and the token list as they read before the batch
    bytes32 internal _parametersBefore;
    address[] internal _tokensBefore;
    IStockAccountRegistry.TokenConfig[] internal _configsBefore;
    uint256 internal _unlistedBefore;
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
        return "018_ListStockUniverse";
    }

    function description() public pure override returns (string memory) {
        return "Halt cbBTC on the stock registry and list every configured stock it does not list yet, priced from its Aerodrome CL pool TWAP against USDC";
    }

    function preBuildMock() public override {
        StockAccountRegistry stockRegistry = _registry();

        assertTrue(
            stockRegistry.hasRole(stockRegistry.DEFAULT_ADMIN_ROLE(), addresses.getAddress("MAMO_MULTISIG")),
            "MAMO_MULTISIG should hold DEFAULT_ADMIN_ROLE on the stock registry"
        );
        assertFalse(stockRegistry.paused(), "Stock registry is paused");

        _parametersBefore = _parameters();
        _tokensBefore = stockRegistry.allTokens();
        for (uint256 i = 0; i < _tokensBefore.length; i++) {
            _configsBefore.push(stockRegistry.tokenConfig(_tokensBefore[i]));
        }

        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList(TOKEN_LIST);
        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(entries[i].source, "PoolTwap", string.concat(entries[i].symbol, " should be PoolTwap"));
            if (stockRegistry.tokenConfig(entries[i].token).status == IStockAccountRegistry.TokenStatus.None) {
                _unlistedBefore++;
            }

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
        address cbBTC = addresses.getAddress("cbBTC");

        if (stockRegistry.tokenConfig(cbBTC).status != IStockAccountRegistry.TokenStatus.Halted) {
            stockRegistry.setTokenStatus(cbBTC, IStockAccountRegistry.TokenStatus.Halted);
        }

        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList(TOKEN_LIST);
        for (uint256 i = 0; i < entries.length; i++) {
            if (stockRegistry.tokenConfig(entries[i].token).status != IStockAccountRegistry.TokenStatus.None) continue;

            stockRegistry.listToken(entries[i].token, _poolTwapConfig(entries[i].pool));
        }
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("MAMO_MULTISIG"));
    }

    function validate() public view override {
        assertTrue(_snapshotted, "Registry was never snapshotted; run preBuildMock");

        StockAccountRegistry stockRegistry = _registry();
        address cbBTC = addresses.getAddress("cbBTC");
        address asset = stockRegistry.asset();

        assertEq(_parameters(), _parametersBefore, "A registry parameter changed");

        address[] memory tokens = stockRegistry.allTokens();
        assertEq(tokens.length, _tokensBefore.length + _unlistedBefore, "Listed token count mismatch");
        for (uint256 i = 0; i < _tokensBefore.length; i++) {
            assertEq(tokens[i], _tokensBefore[i], "An existing listing moved");

            IStockAccountRegistry.TokenConfig memory listed = stockRegistry.tokenConfig(tokens[i]);
            if (tokens[i] == cbBTC) listed.status = _configsBefore[i].status;
            assertEq(
                keccak256(abi.encode(listed)), keccak256(abi.encode(_configsBefore[i])), "An existing listing changed"
            );
        }
        assertEq(
            uint256(stockRegistry.tokenConfig(cbBTC).status),
            uint256(IStockAccountRegistry.TokenStatus.Halted),
            "cbBTC should be Halted"
        );

        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList(TOKEN_LIST);
        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(
                keccak256(abi.encode(stockRegistry.tokenConfig(entries[i].token))),
                keccak256(abi.encode(_poolTwapConfig(entries[i].pool))),
                string.concat(entries[i].symbol, " should be Active on its configured pool")
            );
            assertGt(
                stockRegistry.priceChecker().getExpectedOut(10 ** entries[i].decimals, entries[i].token, asset),
                0,
                string.concat(entries[i].symbol, " should quote a non-zero price")
            );
        }
    }

    /// @dev Every value the admin, guardian or a setter can change, other than the token list
    function _parameters() internal view returns (bytes32) {
        StockAccountRegistry r = _registry();
        return keccak256(
            abi.encode(
                r.priceChecker(),
                r.aerodromeRouter(),
                r.orderSigner(),
                r.paused(),
                r.maxPositions(),
                r.minTargetBps(),
                r.maxDeviationBps(),
                r.maxBackendSlippageBps(),
                r.maxWithdrawSlippageBps(),
                r.managementFeeBps(),
                r.twapWindow(),
                r.minStrategyDeposit(),
                r.maxStrategyDeposit()
            )
        );
    }

    function _poolTwapConfig(address pool) internal pure returns (IStockAccountRegistry.TokenConfig memory) {
        return IStockAccountRegistry.TokenConfig({
            status: IStockAccountRegistry.TokenStatus.Active,
            source: IStockAccountRegistry.PriceSource.PoolTwap,
            pool: pool,
            chainlinkFeed: address(0)
        });
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
