// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {MockStockAccountRegistry} from "@test/mocks/MockStockAccountRegistry.sol";

contract StockAccountRegistryUnitTest is Test {
    ISwapRouter internal router;
    ISlippagePriceChecker internal checker;

    function setUp() public {
        router = ISwapRouter(makeAddr("router"));
        checker = ISlippagePriceChecker(makeAddr("priceChecker"));
    }

    function defaultConfig() internal view returns (StockAccountRegistry.Config memory config) {
        config = StockAccountRegistry.Config({
            aerodromeRouter: router,
            maxBackendSlippageBps: 100,
            maxDeviationBps: 500,
            maxPositions: 10,
            maxStrategyDeposit: 1_000_000e6,
            maxWithdrawSlippageBps: 200,
            minTargetBps: 250,
            priceChecker: checker,
            requiredAppDataHash: keccak256("appData"),
            twapWindow: 1800
        });
    }

    function testConstructorStoresConfig() public {
        StockAccountRegistry registry = new StockAccountRegistry(defaultConfig());

        assertEq(address(registry.aerodromeRouter()), address(router), "router mismatch");
        assertEq(address(registry.priceChecker()), address(checker), "price checker mismatch");
        assertEq(registry.maxPositions(), 10, "max positions mismatch");
        assertEq(registry.minTargetBps(), 250, "min target mismatch");
        assertEq(registry.maxDeviationBps(), 500, "max deviation mismatch");
        assertEq(registry.maxBackendSlippageBps(), 100, "backend slippage mismatch");
        assertEq(registry.maxWithdrawSlippageBps(), 200, "withdraw slippage mismatch");
        assertEq(registry.twapWindow(), 1800, "twap window mismatch");
        assertEq(registry.maxStrategyDeposit(), 1_000_000e6, "max deposit mismatch");
        assertEq(registry.requiredAppDataHash(), keccak256("appData"), "app data hash mismatch");
        assertEq(registry.allTokens().length, 0, "token list should start empty");
    }

    function testConstructorRevertsOnZeroRouter() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.aerodromeRouter = ISwapRouter(address(0));

        vm.expectRevert("Invalid router address");
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroPriceChecker() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.priceChecker = ISlippagePriceChecker(address(0));

        vm.expectRevert("Invalid price checker address");
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroMaxPositions() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.maxPositions = 0;

        vm.expectRevert("Invalid max positions");
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroMinTarget() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.minTargetBps = 0;

        vm.expectRevert("Invalid min target");
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnMinTargetAboveMax() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.minTargetBps = 10_001;

        vm.expectRevert("Invalid min target");
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnMaxDeviationTooHigh() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.maxDeviationBps = 10_001;

        vm.expectRevert("Invalid max deviation");
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnBackendSlippageTooHigh() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.maxBackendSlippageBps = 10_001;

        vm.expectRevert("Invalid slippage cap");
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnWithdrawSlippageTooHigh() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.maxWithdrawSlippageBps = 10_001;

        vm.expectRevert("Invalid slippage cap");
        new StockAccountRegistry(config);
    }

    function testConstructorRevertsOnZeroTwapWindow() public {
        StockAccountRegistry.Config memory config = defaultConfig();
        config.twapWindow = 0;

        vm.expectRevert("Invalid twap window");
        new StockAccountRegistry(config);
    }

    function testMockSetTokenConfigStoresAndLists() public {
        MockStockAccountRegistry mock = new MockStockAccountRegistry();
        address token = makeAddr("token");
        address pool = makeAddr("pool");
        address feed = makeAddr("feed");

        mock.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: pool,
                chainlinkFeed: feed
            })
        );

        IStockAccountRegistry.TokenConfig memory stored = mock.tokenConfig(token);
        assertEq(uint256(stored.status), uint256(IStockAccountRegistry.TokenStatus.Active), "status mismatch");
        assertEq(uint256(stored.source), uint256(IStockAccountRegistry.PriceSource.PoolTwap), "source mismatch");
        assertEq(stored.pool, pool, "pool mismatch");
        assertEq(stored.chainlinkFeed, feed, "feed mismatch");

        address[] memory tokens = mock.allTokens();
        assertEq(tokens.length, 1, "token list length mismatch");
        assertEq(tokens[0], token, "listed token mismatch");
    }

    function testMockSetTokenConfigTwiceKeepsSingleEntry() public {
        MockStockAccountRegistry mock = new MockStockAccountRegistry();
        address token = makeAddr("token");

        IStockAccountRegistry.TokenConfig memory cfg = IStockAccountRegistry.TokenConfig({
            status: IStockAccountRegistry.TokenStatus.Active,
            source: IStockAccountRegistry.PriceSource.Chainlink,
            pool: address(0),
            chainlinkFeed: makeAddr("feed")
        });
        mock.setTokenConfig(token, cfg);

        cfg.status = IStockAccountRegistry.TokenStatus.SellOnly;
        mock.setTokenConfig(token, cfg);

        assertEq(mock.allTokens().length, 1, "token list length mismatch");
        assertEq(
            uint256(mock.tokenConfig(token).status),
            uint256(IStockAccountRegistry.TokenStatus.SellOnly),
            "status not updated"
        );
    }

    function testMockScalarSettersRoundTrip() public {
        MockStockAccountRegistry mock = new MockStockAccountRegistry();

        mock.setMaxPositions(7);
        mock.setMinTargetBps(300);
        mock.setMaxDeviationBps(400);
        mock.setMaxStrategyDeposit(500e6);
        mock.setTwapWindow(600);
        mock.setMaxBackendSlippageBps(50);
        mock.setMaxWithdrawSlippageBps(75);
        mock.setRequiredAppDataHash(keccak256("mockAppData"));
        mock.setAerodromeRouter(router);
        mock.setPriceChecker(checker);

        assertEq(mock.maxPositions(), 7, "max positions mismatch");
        assertEq(mock.minTargetBps(), 300, "min target mismatch");
        assertEq(mock.maxDeviationBps(), 400, "max deviation mismatch");
        assertEq(mock.maxStrategyDeposit(), 500e6, "max deposit mismatch");
        assertEq(mock.twapWindow(), 600, "twap window mismatch");
        assertEq(mock.maxBackendSlippageBps(), 50, "backend slippage mismatch");
        assertEq(mock.maxWithdrawSlippageBps(), 75, "withdraw slippage mismatch");
        assertEq(mock.requiredAppDataHash(), keccak256("mockAppData"), "app data hash mismatch");
        assertEq(address(mock.aerodromeRouter()), address(router), "router mismatch");
        assertEq(address(mock.priceChecker()), address(checker), "price checker mismatch");
    }
}
