// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";

import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";

/**
 * @title HardenStockPriceChecker
 * @notice Multisig proposal that points the stock registry at a StockAccountPriceChecker that refuses a pool
 *         TWAP whose window held zero in-range liquidity or strays from the 30 minutes before it (MOO-1164)
 * @dev The new checker copies every constructor argument from the live one except the two new guards. B20 stocks
 *      are stood in as in proposal 016; every listed stock is 8 decimals.
 */
contract HardenStockPriceChecker is MultisigProposal {
    string internal constant REGISTRY_KEY = "STOCK_ACCOUNT_REGISTRY";
    /// @dev The new checker takes over the live key, as in 019; the replaced one moves to this key
    string internal constant CHECKER_KEY = "STOCK_ACCOUNT_PRICE_CHECKER";
    string internal constant OLD_CHECKER_KEY = "STOCK_ACCOUNT_PRICE_CHECKER_PRE_023";

    /// @dev The TWAP window may stray at most 1,000 ticks (~10%) from the 30 minutes before it
    uint32 public constant BASELINE_WINDOW = 1800;
    uint24 public constant MAX_TWAP_DEVIATION_TICKS = 1000;
    uint8 internal constant STOCK_DECIMALS = 8;

    /// @dev Every registry parameter other than the price checker, and the token list, as they read before the batch
    bytes32 internal _parametersBefore;
    bool internal _snapshotted;

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
        return "023_HardenStockPriceChecker";
    }

    function description() public pure override returns (string memory) {
        return "Point the stock registry at a price checker that refuses a pool TWAP whose window held zero in-range liquidity or strays more than 1,000 ticks from the 30 minutes before it";
    }

    function deploy() public override {
        if (addresses.isAddressSet(OLD_CHECKER_KEY)) return;

        StockAccountPriceChecker old = StockAccountPriceChecker(addresses.getAddress(CHECKER_KEY));

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        StockAccountPriceChecker checker = new StockAccountPriceChecker(
            old.registry(),
            old.quoteAsset(),
            old.existingChecker(),
            old.sequencerUptimeFeed(),
            old.sequencerGracePeriod(),
            BASELINE_WINDOW,
            MAX_TWAP_DEVIATION_TICKS
        );
        vm.stopBroadcast();

        addresses.changeAddress(CHECKER_KEY, address(checker), true);
        addresses.addAddress(OLD_CHECKER_KEY, address(old), true);
    }

    function preBuildMock() public override {
        StockAccountRegistry stockRegistry = _registry();

        assertTrue(
            stockRegistry.hasRole(stockRegistry.DEFAULT_ADMIN_ROLE(), addresses.getAddress("MAMO_MULTISIG")),
            "MAMO_MULTISIG should hold DEFAULT_ADMIN_ROLE on the stock registry"
        );
        assertFalse(stockRegistry.paused(), "Stock registry is paused");
        assertEq(address(stockRegistry.priceChecker()), address(_oldChecker()), "Registry should use the live checker");

        address[] memory tokens = stockRegistry.allTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            bytes memory code = tokens[i].code;
            if (code.length != 1 || code[0] != 0xEF) continue;
            vm.etch(tokens[i], address(new MockERC20Decimals("stock", STOCK_DECIMALS)).code);
        }

        _parametersBefore = _parameters();
        _snapshotted = true;
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        _registry().setPriceChecker(ISlippagePriceChecker(addresses.getAddress(CHECKER_KEY)));
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("MAMO_MULTISIG"));
    }

    function validate() public view override {
        assertTrue(_snapshotted, "Registry was never snapshotted; run preBuildMock");

        StockAccountRegistry stockRegistry = _registry();
        StockAccountPriceChecker old = _oldChecker();
        StockAccountPriceChecker checker = StockAccountPriceChecker(addresses.getAddress(CHECKER_KEY));

        assertEq(address(stockRegistry.priceChecker()), address(checker), "Registry should use the new checker");
        assertEq(_parameters(), _parametersBefore, "A registry parameter changed");

        assertEq(address(checker.registry()), address(stockRegistry), "registry");
        assertEq(checker.quoteAsset(), old.quoteAsset(), "quote asset");
        assertEq(address(checker.existingChecker()), address(old.existingChecker()), "existing checker");
        assertEq(checker.sequencerUptimeFeed(), old.sequencerUptimeFeed(), "sequencer feed");
        assertEq(checker.sequencerGracePeriod(), old.sequencerGracePeriod(), "grace period");
        assertEq(checker.baselineWindow(), BASELINE_WINDOW, "baseline window");
        assertEq(checker.maxTwapDeviationTicks(), MAX_TWAP_DEVIATION_TICKS, "max deviation");

        // A clean window quotes exactly as before, in both directions
        address asset = stockRegistry.asset();
        address[] memory tokens = stockRegistry.allTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (stockRegistry.tokenConfig(tokens[i]).status == IStockAccountRegistry.TokenStatus.Halted) continue;
            uint256 oneToken = 10 ** STOCK_DECIMALS;
            assertEq(checker.getExpectedOut(oneToken, tokens[i], asset), old.getExpectedOut(oneToken, tokens[i], asset));
            assertEq(checker.getExpectedOut(1e6, asset, tokens[i]), old.getExpectedOut(1e6, asset, tokens[i]));
        }
    }

    /// @dev Every value the admin, guardian or a setter can change, other than the price checker
    function _parameters() internal view returns (bytes32) {
        StockAccountRegistry r = _registry();
        address[] memory tokens = r.allTokens();
        IStockAccountRegistry.TokenConfig[] memory configs = new IStockAccountRegistry.TokenConfig[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            configs[i] = r.tokenConfig(tokens[i]);
        }
        return keccak256(
            abi.encode(
                r.aerodromeRouter(),
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
                r.maxStrategyDeposit(),
                r.maxOrderValue(),
                tokens,
                configs
            )
        );
    }

    function _registry() internal view returns (StockAccountRegistry) {
        return StockAccountRegistry(addresses.getAddress(REGISTRY_KEY));
    }

    function _oldChecker() internal view returns (StockAccountPriceChecker) {
        return StockAccountPriceChecker(addresses.getAddress(OLD_CHECKER_KEY));
    }

    function _initializeAddresses() internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }
}
