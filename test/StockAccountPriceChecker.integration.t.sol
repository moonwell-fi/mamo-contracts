// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockCLPoolObserve} from "@test/mocks/MockCLPoolObserve.sol";
import {MockChainlinkAggregator} from "@test/mocks/MockChainlinkAggregator.sol";
import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";

/// @dev The swap entry point of the live Slipstream pool, kept out of ICLPool because production
///      code never swaps: the checker only reads prices.
interface ICLPoolSwap {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @dev The pool's fee tier, kept out of ICLPool for the same reason.
interface ICLPoolFee {
    function fee() external view returns (uint24);
}

/// @dev The permissionless observation-buffer grower, kept out of ICLPool for the same reason.
interface ICLPoolCardinality {
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/// @notice Live NVDAc/USDC Aerodrome Slipstream pool and live Chainlink feeds on a PINNED Base fork.
///         Self-forks in setUp (no --fork-url on the CLI, see the lp-auto-balancer-v2 Makefile note).
contract StockAccountPriceCheckerIntegrationTest is Test {
    uint256 internal constant PINNED_BLOCK = 51_181_271;
    uint32 internal constant WINDOW = 180;
    uint256 internal constant CBBTC_MAX_TIME_PRICE_VALID = 3600;
    uint256 internal constant BTC_USD_HEARTBEAT = 3600;
    uint16 internal constant MAX_BACKEND_SLIPPAGE_BPS = 100;
    uint256 internal constant MAX_STRATEGY_DEPOSIT = 25_000e6;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C; // 8 dec, pool token1
    address internal constant NVDAC_USDC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9; // tick spacing 10
    address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb; // 8 dec, pool token1
    address internal constant AAPLC_USDC_POOL = 0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0; // tick spacing 10
    address internal constant AERODROME_CL_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // 8 dec
    address internal constant CBBTC_USDC_POOL = 0x3F53aFD15909bF5B1c5963b5C0D28123668ce174; // cardinality 1 at the pin
    address internal constant CHAINLINK_BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant STRANGER = 0x000000000000000000000000000000000000dEaD;

    /// @dev Swap inputs large enough to run the pool to the sqrt-price limit the helpers set; the
    ///      limit, not the amount, is what decides how far the price moves.
    uint256 internal constant PUMP_USDC_IN = 2_000_000e6;
    uint256 internal constant DUMP_NVDAC_IN = 200_000e8;
    /// @dev NVDAc handed to the pool before a pump so it can pay the buy out of the etched stand-in.
    uint256 internal constant PUMP_NVDAC_RESERVE = 200_000e8;
    uint256 internal constant CBBTC_POOL_SWAP_USDC_IN = 100e6;
    /// @dev The largest pump the helpers take: sqrt price to 90% of where it started.
    uint256 internal constant MAX_PUMP_SQRT_BPS = 9_000;
    /// @dev Per-token weight of a ten-position basket, the widest `maxPositions` the registry allows.
    uint256 internal constant DIVERSIFIED_TARGET_BPS = 1_000;

    address internal admin = makeAddr("admin");
    StockAccountRegistry internal registry;
    StockAccountPriceChecker internal checker;
    SlippagePriceChecker internal existingChecker;
    address internal cbbtcVenue;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);
        // B20 tokens are node-native on Base (on-chain code is the single byte 0xef); revm cannot
        // execute them, so stand in an 8-decimal ERC20 for the only call the checker makes (decimals()).
        vm.etch(NVDAC, address(new MockERC20Decimals("NVDAc", 8)).code);
        vm.etch(AAPLC, address(new MockERC20Decimals("AAPLc", 8)).code);
        assertEq(MockERC20Decimals(NVDAC).decimals(), 8);
        assertEq(MockERC20Decimals(AAPLC).decimals(), 8);

        existingChecker = _deployExistingChecker();

        // The checker takes the registry as an immutable, so the registry is built first against a
        // code-bearing stand-in (this test contract) and repointed once the real checker exists.
        registry = _deployRegistry();
        checker = new StockAccountPriceChecker(registry, USDC, existingChecker);
        vm.prank(admin);
        registry.setPriceChecker(checker);
        assertEq(address(registry.priceChecker()), address(checker));

        vm.prank(admin);
        registry.listToken(NVDAC, _poolTwapConfig(NVDAC_USDC_POOL));
        vm.prank(admin);
        registry.listToken(AAPLC, _poolTwapConfig(AAPLC_USDC_POOL));

        // `listToken` requires a code-bearing trade venue for every token; the checker never reads it
        // for a Chainlink token, so a stand-in keeps this test from asserting anything about cbBTC pools.
        cbbtcVenue = address(new MockCLPoolObserve(USDC, CBBTC));
        vm.prank(admin);
        registry.listToken(
            CBBTC,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: IStockAccountRegistry.PriceSource.Chainlink,
                pool: cbbtcVenue,
                chainlinkFeed: CHAINLINK_BTC_USD
            })
        );
    }

    function _deployRegistry() internal returns (StockAccountRegistry) {
        return new StockAccountRegistry(
            StockAccountRegistry.Config({
                admin: admin,
                aerodromeRouter: ISwapRouter(AERODROME_CL_ROUTER),
                asset: USDC,
                guardian: admin,
                managementFeeBps: 100,
                maxBackendSlippageBps: MAX_BACKEND_SLIPPAGE_BPS,
                maxDeviationBps: 1000,
                maxPositions: 10,
                maxStrategyDeposit: MAX_STRATEGY_DEPOSIT,
                maxWithdrawSlippageBps: 500,
                minStrategyDeposit: 100e6,
                minTargetBps: 100,
                orderSigner: admin,
                priceChecker: ISlippagePriceChecker(address(this)),
                twapWindow: WINDOW
            })
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

    /// @dev A fresh SlippagePriceChecker proxy owned by this test, configured cbBTC -> USDC in the
    ///      house two-hop shape (token/USD forward, USDC/USD reverse) from config/strategies/*.json.
    function _deployExistingChecker() internal returns (SlippagePriceChecker) {
        address impl = address(new SlippagePriceChecker());
        bytes memory init = abi.encodeWithSelector(SlippagePriceChecker.initialize.selector, address(this));
        SlippagePriceChecker proxy = SlippagePriceChecker(address(new ERC1967Proxy(impl, init)));

        ISlippagePriceChecker.TokenFeedConfiguration[] memory cfgs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](2);
        cfgs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: CHAINLINK_BTC_USD,
            reverse: false,
            heartbeat: BTC_USD_HEARTBEAT
        });
        cfgs[1] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: CHAINLINK_USDC_USD,
            reverse: true,
            heartbeat: 86_400
        });
        proxy.addTokenConfiguration(CBBTC, USDC, cfgs);
        proxy.setMaxTimePriceValid(CBBTC, CBBTC_MAX_TIME_PRICE_VALID);
        return proxy;
    }

    /// @dev USDC raw per 1 whole stock token from a pool's current sqrt price; every stocks pool used
    ///      here holds USDC as token0 and the stock as token1.
    function _spotUsdcPerStock(address pool) internal view returns (uint256) {
        (uint160 sqrtP,,,,,) = ICLPool(pool).slot0();
        uint256 ratioX192 = uint256(sqrtP) * sqrtP;
        return Math.mulDiv(1 << 192, 1e8, ratioX192);
    }

    function test_fork_referenceTracksLiveSpot() public view {
        uint256 twapOut = checker.getExpectedOut(1e8, NVDAC, USDC);
        uint256 spot = _spotUsdcPerStock(NVDAC_USDC_POOL);
        assertGt(twapOut, 0, "vacuous: zero quote");
        assertGt(spot, 100e6, "vacuous: spot below $100");
        assertApproxEqRel(twapOut, spot, 0.05e18, "twap vs spot > 5%");
    }

    function test_fork_bothDirectionsRoundTrip() public view {
        uint256 usdcOut = checker.getExpectedOut(10e8, NVDAC, USDC);
        uint256 back = checker.getExpectedOut(usdcOut, USDC, NVDAC);
        assertGt(usdcOut, 1_000e6);
        assertApproxEqAbs(back, 10e8, 10);
    }

    function test_fork_checkPriceAcceptsFairAndRejectsBelowTolerance() public view {
        uint256 amountIn = 3e8;
        uint256 expected = checker.getExpectedOut(amountIn, NVDAC, USDC);
        uint256 floor = (expected * 9_900) / 10_000;
        assertTrue(checker.checkPrice(amountIn, NVDAC, USDC, floor, 100));
        assertFalse(checker.checkPrice(amountIn, NVDAC, USDC, floor - 1, 100));
    }

    /// @dev The registry refuses a window the live pool cannot serve, so the token is halted first to
    ///      reach the checker's own behaviour behind that guard.
    function test_fork_windowLongerThanHistoryReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.TokenNotPriceable.selector, NVDAC));
        vm.prank(admin);
        registry.setTwapWindow(type(uint32).max);

        vm.startPrank(admin);
        registry.setTokenStatus(NVDAC, IStockAccountRegistry.TokenStatus.Halted);
        registry.setTokenStatus(AAPLC, IStockAccountRegistry.TokenStatus.Halted);
        registry.setTwapWindow(type(uint32).max);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                StockAccountPriceChecker.InsufficientObservations.selector, NVDAC_USDC_POOL, type(uint32).max
            )
        );
        checker.getExpectedOut(1e8, NVDAC, USDC);
    }

    /// @notice Two pool-priced tokens compose through USDC at their spot ratio and round-trip cleanly.
    function test_fork_poolTwapToPoolTwapComposes() public view {
        uint256 usdcPerNvdac = _spotUsdcPerStock(NVDAC_USDC_POOL);
        uint256 usdcPerAaplc = _spotUsdcPerStock(AAPLC_USDC_POOL);
        assertGt(usdcPerNvdac, 100e6, "vacuous: NVDAc spot below $100");
        assertGt(usdcPerAaplc, 100e6, "vacuous: AAPLc spot below $100");

        uint256 out = checker.getExpectedOut(1e8, NVDAC, AAPLC);
        assertGt(out, 0, "vacuous: zero quote");
        assertApproxEqRel(out, Math.mulDiv(usdcPerNvdac, 1e8, usdcPerAaplc), 0.01e18, "nvdac/aaplc off spot ratio");

        uint256 back = checker.getExpectedOut(out, AAPLC, NVDAC);
        assertApproxEqAbs(back, 1e8, 1, "nvdac -> aaplc -> nvdac lost more than the floor");
    }

    // ==================== Chainlink source ====================

    /// @notice A pure `chainlinkToken -> USDC` quote is byte-for-byte the existing checker's own answer.
    /// @dev 100 cbBTC is the amount that separates delegation from a one-whole-token probe: the probe's
    ///      floor at raw USDC is multiplied by 100, so the two paths differ by tens of raw units there.
    function test_fork_chainlinkLegIsExactParity() public view {
        assertEq(checker.getExpectedOut(1e8, CBBTC, USDC), existingChecker.getExpectedOut(1e8, CBBTC, USDC));
        assertEq(
            checker.getExpectedOut(12_345_678, CBBTC, USDC), existingChecker.getExpectedOut(12_345_678, CBBTC, USDC)
        );
        assertEq(checker.getExpectedOut(100e8, CBBTC, USDC), existingChecker.getExpectedOut(100e8, CBBTC, USDC));
        assertGt(checker.getExpectedOut(1e8, CBBTC, USDC), 10_000e6, "vacuous: cbBTC below $10k");
    }

    /// @notice Pool-priced NVDAc against feed-priced cbBTC composes as spot / spot, both directions.
    function test_fork_nvdacToCbbtcTracksSpotRatio() public view {
        uint256 usdcPerNvdac = _spotUsdcPerStock(NVDAC_USDC_POOL);
        uint256 usdcPerCbbtc = existingChecker.getExpectedOut(1e8, CBBTC, USDC);
        assertGt(usdcPerNvdac, 100e6, "vacuous: NVDAc spot below $100");
        assertGt(usdcPerCbbtc, 10_000e6, "vacuous: cbBTC below $10k");

        uint256 out = checker.getExpectedOut(1e8, NVDAC, CBBTC);
        assertGt(out, 0, "vacuous: zero quote");
        assertApproxEqRel(out, Math.mulDiv(usdcPerNvdac, 1e8, usdcPerCbbtc), 0.05e18, "nvdac/cbbtc off spot ratio");

        uint256 backOut = checker.getExpectedOut(1e8, CBBTC, NVDAC);
        assertApproxEqRel(backOut, Math.mulDiv(usdcPerCbbtc, 1e8, usdcPerNvdac), 0.05e18, "cbbtc/nvdac off spot ratio");
    }

    /// @dev USDC -> cbBTC floors at one satoshi (~$0.001 at these prices), so the round trip is
    ///      bounded in raw USDC by one satoshi of value, not by a handful of units.
    function test_fork_usdcToCbbtcRoundTrip() public view {
        uint256 amountIn = 50_000e6;
        uint256 cbbtcOut = checker.getExpectedOut(amountIn, USDC, CBBTC);
        assertGt(cbbtcOut, 0, "vacuous: zero cbBTC");
        uint256 back = checker.getExpectedOut(cbbtcOut, CBBTC, USDC);
        assertApproxEqAbs(back, amountIn, 2_000);
    }

    function test_fork_maxTimePriceValidDelegatesForChainlinkOnly() public view {
        assertEq(checker.maxTimePriceValid(CBBTC), CBBTC_MAX_TIME_PRICE_VALID);
        assertEq(checker.maxTimePriceValid(NVDAC), WINDOW);
        assertEq(checker.maxTimePriceValid(USDC), WINDOW);
    }

    function test_fork_isTokenPairConfiguredAcrossSources() public view {
        assertTrue(checker.isTokenPairConfigured(NVDAC, CBBTC));
        assertTrue(checker.isTokenPairConfigured(CBBTC, USDC));
        assertFalse(checker.isTokenPairConfigured(CBBTC, STRANGER));
    }

    function test_fork_unlistedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(StockAccountPriceChecker.TokenNotListed.selector, STRANGER));
        checker.getExpectedOut(1e8, STRANGER, CBBTC);
        vm.expectRevert(abi.encodeWithSelector(StockAccountPriceChecker.TokenNotListed.selector, STRANGER));
        checker.getExpectedOut(1e8, CBBTC, STRANGER);
    }

    /// @dev Replaces the live BTC/USD feed with a settable stand-in, seeded from the round the fork
    ///      pins so only the field under test differs from a healthy feed.
    function _etchBtcUsdFeed() internal returns (MockChainlinkAggregator feed) {
        uint8 feedDecimals = IPriceFeed(CHAINLINK_BTC_USD).decimals();
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt,) =
            IPriceFeed(CHAINLINK_BTC_USD).latestRoundData();
        vm.etch(CHAINLINK_BTC_USD, address(new MockChainlinkAggregator()).code);
        feed = MockChainlinkAggregator(CHAINLINK_BTC_USD);
        feed.setDecimals(feedDecimals);
        feed.setRoundData(roundId, answer, startedAt, updatedAt, roundId);
        assertEq(checker.getExpectedOut(1e8, CBBTC, USDC), existingChecker.getExpectedOut(1e8, CBBTC, USDC));
    }

    /// @dev Both checkers must refuse a cbBTC quote with byte-identical data, and the healthy NVDAc pool
    ///      leg of a composed quote must not launder the broken feed into an answer.
    function _assertCbbtcRevertParity(string memory label) internal {
        bytes memory direct = abi.encodeCall(ISlippagePriceChecker.getExpectedOut, (uint256(1e8), CBBTC, USDC));
        (bool okChecker, bytes memory checkerData) = address(checker).staticcall(direct);
        (bool okExisting, bytes memory existingData) = address(existingChecker).staticcall(direct);
        assertFalse(okChecker, string.concat(label, ": stock checker did not revert"));
        assertFalse(okExisting, string.concat(label, ": existing checker did not revert"));
        assertEq(checkerData, existingData, string.concat(label, ": direct revert data differs"));
        emit log_named_string(string.concat(label, " revert"), string(_errorReason(existingData)));

        (bool okComposed, bytes memory composedData) = address(checker).staticcall(
            abi.encodeCall(ISlippagePriceChecker.getExpectedOut, (uint256(1e8), NVDAC, CBBTC))
        );
        assertFalse(okComposed, string.concat(label, ": composed quote did not revert"));
        assertEq(composedData, existingData, string.concat(label, ": composed revert data differs"));
    }

    /// @dev The string payload of an `Error(string)` revert, for logging.
    function _errorReason(bytes memory revertData) internal pure returns (bytes memory) {
        return abi.encodePacked(abi.decode(_slice(revertData, 4), (string)));
    }

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory out) {
        out = new bytes(data.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[start + i];
        }
    }

    /// @notice A stale, zero or negative BTC/USD answer fails both checkers with the same bytes, and the
    ///         NVDAc pool leg cannot launder it; `maxTimePriceValid` keeps delegating throughout.
    function test_fork_chainlinkStaleZeroAndNegativeParity() public {
        MockChainlinkAggregator feed = _etchBtcUsdFeed();
        (uint80 roundId, int256 answer,,,) = IPriceFeed(CHAINLINK_BTC_USD).latestRoundData();

        uint256 stale = vm.getBlockTimestamp() - BTC_USD_HEARTBEAT - 1;
        feed.setRoundData(roundId, answer, stale, stale, roundId);
        _assertCbbtcRevertParity("stale");

        feed.setRoundData(roundId, 0, vm.getBlockTimestamp(), vm.getBlockTimestamp(), roundId);
        _assertCbbtcRevertParity("zero");

        feed.setRoundData(roundId, -1, vm.getBlockTimestamp(), vm.getBlockTimestamp(), roundId);
        _assertCbbtcRevertParity("negative");

        assertEq(checker.maxTimePriceValid(CBBTC), CBBTC_MAX_TIME_PRICE_VALID);
    }

    // ==================== Live pool manipulation ====================

    /// @dev Settles a swap this test initiated; NVDAc is the etched stand-in, USDC and cbBTC are real.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        assertTrue(msg.sender == NVDAC_USDC_POOL || msg.sender == CBBTC_USDC_POOL, "callback from an unexpected pool");
        if (amount0Delta > 0) IERC20(ICLPool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(ICLPool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev Buys NVDAc until the pool's sqrt price is `sqrtFactorBps / 10_000` of where it started, so a
    ///      smaller factor is a larger pump. The pool is minted the NVDAc it pays out: the real reserve
    ///      lives in node-native state that the etch in `setUp` replaced.
    function _pumpNvdacTo(uint256 sqrtFactorBps) internal {
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        deal(USDC, address(this), PUMP_USDC_IN);
        MockERC20Decimals(NVDAC).mint(NVDAC_USDC_POOL, PUMP_NVDAC_RESERVE);
        ICLPoolSwap(NVDAC_USDC_POOL).swap(
            address(this), true, int256(PUMP_USDC_IN), uint160((uint256(sqrtP) * sqrtFactorBps) / 10_000), ""
        );
    }

    function _pumpNvdac() internal {
        _pumpNvdacTo(MAX_PUMP_SQRT_BPS);
    }

    /// @dev Sells NVDAc until the pool's sqrt price is `sqrtFactorBps / 10_000` of where it started.
    function _dumpNvdacTo(uint256 sqrtFactorBps) internal {
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        MockERC20Decimals(NVDAC).mint(address(this), DUMP_NVDAC_IN);
        ICLPoolSwap(NVDAC_USDC_POOL).swap(
            address(this), false, int256(DUMP_NVDAC_IN), uint160((uint256(sqrtP) * sqrtFactorBps) / 10_000), ""
        );
    }

    function _dumpNvdac() internal {
        _dumpNvdacTo(11_000);
    }

    /// @dev Drift of the NVDAc reference, in bps, `holdSeconds` after one pump that nothing trades back.
    ///      Measured on a state snapshot so a caller can sweep pump sizes and hold times from one state.
    function _driftBpsAfterHold(uint256 sqrtFactorBps, uint32 holdSeconds) internal returns (uint256) {
        uint256 baseline = checker.getExpectedOut(1e8, NVDAC, USDC);
        uint256 snap = vm.snapshotState();
        _pumpNvdacTo(sqrtFactorBps);
        vm.warp(vm.getBlockTimestamp() + holdSeconds);
        uint256 drifted = checker.getExpectedOut(1e8, NVDAC, USDC);
        vm.revertToState(snap);
        return ((drifted - baseline) * 10_000) / baseline;
    }

    /// @dev Smallest whole-second hold at which a full-limit pump's drift exceeds the backend's slippage
    ///      budget, or 0 if a full-window hold never does. Drift rises with hold time, so bisection is exact.
    function _holdToOpenBudget(uint32 window) internal returns (uint32) {
        if (_driftBpsAfterHold(MAX_PUMP_SQRT_BPS, window) <= MAX_BACKEND_SLIPPAGE_BPS) return 0;
        uint32 lo = 1;
        uint32 hi = window;
        while (lo < hi) {
            uint32 mid = lo + (hi - lo) / 2;
            if (_driftBpsAfterHold(MAX_PUMP_SQRT_BPS, mid) > MAX_BACKEND_SLIPPAGE_BPS) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    /// @dev Largest sqrt-price factor — that is, the cheapest pump — whose drift after `holdSeconds` still
    ///      clears the backend budget, or 0 when even a full-limit pump cannot. Drift falls as the factor rises.
    function _cheapestPumpToOpenBudget(uint32 holdSeconds) internal returns (uint256) {
        if (_driftBpsAfterHold(MAX_PUMP_SQRT_BPS, holdSeconds) <= MAX_BACKEND_SLIPPAGE_BPS) return 0;
        uint256 lo = MAX_PUMP_SQRT_BPS;
        uint256 hi = 10_000;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (_driftBpsAfterHold(mid, holdSeconds) > MAX_BACKEND_SLIPPAGE_BPS) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    /// @dev Pumps to `sqrtFactorBps` and immediately sells the whole position back, returning the USDC the
    ///      pump committed and the USDC the round trip destroyed. Runs on a snapshot: the pool is restored.
    function _roundTripCost(uint256 sqrtFactorBps) internal returns (uint256 committed, uint256 lost) {
        uint256 snap = vm.snapshotState();
        _pumpNvdacTo(sqrtFactorBps);
        uint256 usdcAfterPump = IERC20(USDC).balanceOf(address(this));
        committed = PUMP_USDC_IN - usdcAfterPump;
        uint256 held = MockERC20Decimals(NVDAC).balanceOf(address(this));
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        ICLPoolSwap(NVDAC_USDC_POOL).swap(address(this), false, int256(held), uint160((uint256(sqrtP) * 130) / 100), "");
        assertEq(MockERC20Decimals(NVDAC).balanceOf(address(this)), 0, "unwind left the position open");
        lost = committed - (IERC20(USDC).balanceOf(address(this)) - usdcAfterPump);
        vm.revertToState(snap);
    }

    /// @dev The dump mirror of `_roundTripCost`, with both figures valued in USDC at the pre-attack
    ///      reference so the two directions are directly comparable.
    function _dumpRoundTripCost(uint256 sqrtFactorBps) internal returns (uint256 committed, uint256 lost) {
        uint256 usdcPerNvdac = checker.getExpectedOut(1e8, NVDAC, USDC);
        uint256 snap = vm.snapshotState();
        deal(USDC, address(this), 0);
        MockERC20Decimals(NVDAC).mint(NVDAC_USDC_POOL, PUMP_NVDAC_RESERVE);
        uint256 before = MockERC20Decimals(NVDAC).balanceOf(address(this));
        _dumpNvdacTo(sqrtFactorBps);
        uint256 afterDump = MockERC20Decimals(NVDAC).balanceOf(address(this));
        uint256 sold = before + DUMP_NVDAC_IN - afterDump;
        uint256 usdcOut = IERC20(USDC).balanceOf(address(this));
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        ICLPoolSwap(NVDAC_USDC_POOL).swap(
            address(this), true, int256(usdcOut), uint160((uint256(sqrtP) * 30) / 100), ""
        );
        uint256 bought = MockERC20Decimals(NVDAC).balanceOf(address(this)) - afterDump;
        committed = Math.mulDiv(sold, usdcPerNvdac, 1e8);
        lost = Math.mulDiv(sold - bought, usdcPerNvdac, 1e8);
        vm.revertToState(snap);
    }

    /// @dev Price ratio of a `tickDelta`-tick move, minus one, in bps: 1.0001^tickDelta - 1.
    function _driftBpsForTickDelta(uint256 tickDelta) internal pure returns (uint256) {
        uint160 sqrtRatio = TickMath.getSqrtRatioAtTick(int24(int256(tickDelta)));
        return Math.mulDiv(uint256(sqrtRatio) * sqrtRatio, 10_000, 1 << 192) - 10_000;
    }

    /// @dev The tick move a measured drift corresponds to: the inverse of `_driftBpsForTickDelta`.
    function _tickDeltaForDriftBps(uint256 driftBps) internal pure returns (uint256) {
        uint256 lo;
        uint256 hi = 10_000;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (_driftBpsForTickDelta(mid) <= driftBps) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    /// @dev Smallest whole-second hold whose mean tick — moved linearly by `tickDelta` over `window` —
    ///      prices above the backend budget. The closed form h* = W ln(1 + budget) / ln(1 + drift), on
    ///      the tick lattice the checker actually rounds to.
    function _predictedHoldToOpenBudget(uint32 window, uint256 tickDelta) internal pure returns (uint32) {
        for (uint32 h = 1; h <= window; h++) {
            if (_driftBpsForTickDelta((tickDelta * h) / window) > MAX_BACKEND_SLIPPAGE_BPS) return h;
        }
        return 0;
    }

    /// @dev (1 + budget)^exponent - 1 in bps: the manipulation an attacker needs when the window is
    ///      `exponent` times the hold they can sustain.
    function _requiredDriftBps(uint256 exponent) internal pure returns (uint256) {
        uint256 acc = 1e18;
        for (uint256 i = 0; i < exponent; i++) {
            acc = (acc * (10_000 + MAX_BACKEND_SLIPPAGE_BPS)) / 10_000;
        }
        return (acc - 1e18) / 1e14;
    }

    /// @dev Price drift a pump to `sqrtFactorBps` commands: the sqrt-price move, squared, minus one.
    function _sqrtMoveDriftBps(uint256 sqrtFactorBps) internal pure returns (uint256) {
        return (100_000_000 / ((sqrtFactorBps * sqrtFactorBps) / 10_000)) - 10_000;
    }

    /// @dev The attacker's edge on one filled order: the manipulated reference and the slippage budget
    ///      compound, so it is 1 - (1 - drift)(1 - budget), not the smaller of the two.
    function _edgeBps(uint256 driftBps) internal pure returns (uint256) {
        uint256 kept = ((10_000 - driftBps) * (10_000 - MAX_BACKEND_SLIPPAGE_BPS)) / 10_000;
        return 10_000 - kept;
    }

    function _setWindow(uint32 window) internal {
        if (registry.twapWindow() == window) return;
        vm.prank(admin);
        registry.setTwapWindow(window);
    }

    function _bps(uint256 value, uint256 base) internal pure returns (uint256) {
        return value > base ? ((value - base) * 10_000) / base : ((base - value) * 10_000) / base;
    }

    /// @notice The pool every manipulation number below is measured against, at the pinned block.
    function test_fork_poolStateAtThePin() public {
        (, int24 tickBefore,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        uint256 poolUsdc = IERC20(USDC).balanceOf(NVDAC_USDC_POOL);
        uint128 liquidityBefore = ICLPool(NVDAC_USDC_POOL).liquidity();

        uint256 snap = vm.snapshotState();
        _pumpNvdac();
        (, int24 tickAfter,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        uint128 liquidityAfter = ICLPool(NVDAC_USDC_POOL).liquidity();
        uint256 committed = PUMP_USDC_IN - IERC20(USDC).balanceOf(address(this));
        uint256 bought = MockERC20Decimals(NVDAC).balanceOf(address(this));
        vm.revertToState(snap);

        emit log_string(
            string.concat(
                "pool: ",
                vm.toString(poolUsdc),
                " raw USDC, tick ",
                vm.toString(int256(tickBefore)),
                ", liquidity ",
                vm.toString(uint256(liquidityBefore)),
                "; a maximal pump commits ",
                vm.toString(committed),
                " raw USDC for ",
                vm.toString(bought),
                " raw NVDAc, tick ",
                vm.toString(int256(tickAfter)),
                ", liquidity ",
                vm.toString(uint256(liquidityAfter))
            )
        );
        assertEq(ICLPool(NVDAC_USDC_POOL).token0(), USDC, "USDC is not token0");
        assertEq(ICLPool(NVDAC_USDC_POOL).token1(), NVDAC, "NVDAc is not token1");
        assertEq(ICLPool(NVDAC_USDC_POOL).tickSpacing(), 10, "tick spacing moved");
        assertGt(poolUsdc, 0, "vacuous: the pool holds no USDC");
        assertGt(committed, poolUsdc, "a maximal pump committed less than the pool's own float");
        assertLt(tickAfter, tickBefore, "the pump did not move the tick");
        assertLt(liquidityAfter, liquidityBefore, "the pump did not thin in-range liquidity");
    }

    /// @notice A same-block manipulation moves the pool's live price and not the checker's quote.
    function test_fork_twapIgnoresSameBlockPoolManipulation() public {
        uint256 twapBefore = checker.getExpectedOut(1e8, NVDAC, USDC);
        uint256 spotBefore = _spotUsdcPerStock(NVDAC_USDC_POOL);

        _pumpNvdac();

        assertGt(_spotUsdcPerStock(NVDAC_USDC_POOL), (spotBefore * 110) / 100, "vacuous: spot moved less than 10%");
        assertEq(checker.getExpectedOut(1e8, NVDAC, USDC), twapBefore, "twap moved within the same block");
    }

    /// @notice Non-vacuity control for the test above: the TWAP converges on the held tick, so a
    ///         full-window hold is the upper bound on the attack, not its threshold.
    function test_fork_manipulationHeldForTheWholeWindowMovesTheTwap() public {
        uint256 twapBefore = checker.getExpectedOut(1e8, NVDAC, USDC);

        _pumpNvdac();
        uint256 spotAfter = _spotUsdcPerStock(NVDAC_USDC_POOL);
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);

        uint256 twapAfter = checker.getExpectedOut(1e8, NVDAC, USDC);
        assertGt(twapAfter, (twapBefore * 110) / 100, "vacuous: twap did not follow the held tick");
        assertApproxEqRel(twapAfter, spotAfter, 0.01e18, "held tick should price at the manipulated spot");
    }

    /// @notice A crashed spot cannot serve as the slippage floor: the TWAP still prices NVDAc high,
    ///         so a sell quoted off the manipulated pool is rejected.
    function test_fork_checkPriceRejectsFloorDerivedFromCrashedSpot() public {
        uint256 spotBefore = _spotUsdcPerStock(NVDAC_USDC_POOL);
        uint256 fairFloor = (checker.getExpectedOut(1e8, NVDAC, USDC) * 9_900) / 10_000;
        assertTrue(checker.checkPrice(1e8, NVDAC, USDC, fairFloor, 100), "control: fair floor rejected");

        _dumpNvdac();

        uint256 crashedSpot = _spotUsdcPerStock(NVDAC_USDC_POOL);
        assertLt(crashedSpot, (spotBefore * 90) / 100, "vacuous: spot did not crash 10%");
        assertFalse(checker.checkPrice(1e8, NVDAC, USDC, crashedSpot, 100), "crashed-spot floor accepted");
    }

    /// @notice The Chainlink leg keeps exact parity with the existing checker across a pool attack.
    function test_fork_chainlinkParitySurvivesPoolManipulation() public {
        _pumpNvdac();
        assertEq(checker.getExpectedOut(1e8, CBBTC, USDC), existingChecker.getExpectedOut(1e8, CBBTC, USDC));
        assertEq(checker.getExpectedOut(100e8, CBBTC, USDC), existingChecker.getExpectedOut(100e8, CBBTC, USDC));
    }

    /// @notice Drift follows the closed form drift(h) = (1 + D)^(h/W) - 1 exactly: the mean tick is linear
    ///         in hold time and price is exponential in tick. An attacker buys drift by the second.
    function test_fork_twapDriftFollowsTheClosedForm() public {
        uint32[7] memory holds = [uint32(3), 12, 30, 60, 90, 150, 180];
        uint256 full = _driftBpsAfterHold(MAX_PUMP_SQRT_BPS, WINDOW);
        uint256 fullTicks = _tickDeltaForDriftBps(full);
        assertGt(full, 2_000, "vacuous: a full-window hold barely moved the reference");

        emit log_string(string.concat("drift vs hold, window 180s, full-hold drift ", vm.toString(full), " bps"));
        for (uint256 i = 0; i < holds.length; i++) {
            uint256 measured = _driftBpsAfterHold(MAX_PUMP_SQRT_BPS, holds[i]);
            uint256 predicted = _driftBpsForTickDelta((fullTicks * holds[i]) / WINDOW);
            uint256 linear = (full * holds[i]) / WINDOW;
            emit log_string(
                string.concat(
                    "  hold ",
                    vm.toString(holds[i]),
                    "s  drift ",
                    vm.toString(measured),
                    " bps  closed form ",
                    vm.toString(predicted),
                    " bps  linear ",
                    vm.toString(linear),
                    " bps"
                )
            );
            assertApproxEqAbs(measured, predicted, 3, "drift does not follow (1 + D)^(h/W) - 1");
        }
    }

    /// @notice Moving the pool and putting it straight back costs the attacker two crossings of the fee
    ///         tier and nothing else.
    function test_fork_manipulationRoundTripCostsOnlyFees() public {
        uint24 fee = ICLPoolFee(NVDAC_USDC_POOL).fee();
        (uint256 committed, uint256 lost) = _roundTripCost(MAX_PUMP_SQRT_BPS);
        uint256 costTenthBps = (lost * 100_000) / committed;
        emit log_string(
            string.concat(
                "round trip: committed ",
                vm.toString(committed),
                " raw USDC, lost ",
                vm.toString(lost),
                " raw USDC, ",
                vm.toString(costTenthBps / 10),
                ".",
                vm.toString(costTenthBps % 10),
                " bps at a fee tier of ",
                vm.toString(uint256(fee))
            )
        );
        assertEq(fee, 500, "fee tier moved");
        assertGt(lost, 0, "vacuous: the round trip was free");
        assertLe(costTenthBps, (2 * uint256(fee)) / 10, "round trip cost more than two crossings of the fee");
        assertGt(costTenthBps, (19 * uint256(fee)) / 100, "round trip cost less than two crossings of the fee");
    }

    /// @notice The attacker buys exactly the drift they can use, and a usable drift is far cheaper than a
    ///         maximal one: cost against sqrt-price factor at the pinned block.
    function test_fork_manipulationCostCurve() public {
        uint256[6] memory factors = [uint256(9_995), 9_975, 9_950, 9_900, 9_800, MAX_PUMP_SQRT_BPS];
        uint256 previousDrift;
        uint256 previousLost;
        uint256 budgetOpeningCost;

        emit log_string("cost curve: pump, hold the full 180s window, unwind");
        for (uint256 i = 0; i < factors.length; i++) {
            uint256 drift = _driftBpsAfterHold(factors[i], WINDOW);
            (uint256 committed, uint256 lost) = _roundTripCost(factors[i]);
            emit log_string(
                string.concat(
                    "  sqrtP x0.",
                    vm.toString(factors[i]),
                    "  full-hold drift ",
                    vm.toString(drift),
                    " bps  committed ",
                    vm.toString(committed),
                    " raw USDC  round trip ",
                    vm.toString(lost),
                    " raw USDC"
                )
            );
            assertGt(drift, previousDrift, "a larger pump did not drift further");
            assertGt(lost, previousLost, "a larger pump did not cost more");
            previousDrift = drift;
            previousLost = lost;
            if (drift > MAX_BACKEND_SLIPPAGE_BPS && budgetOpeningCost == 0) budgetOpeningCost = lost;
        }

        assertGt(budgetOpeningCost, 0, "no pump on the curve opened the budget");
        assertLt(budgetOpeningCost * 4, previousLost, "opening the budget costs within 4x of a maximal pump");
    }

    /// @notice Attacker cost against attacker gain, sized per pump. The edge compounds the manipulated
    ///         reference with the slippage budget, and exposure is what one order can move under
    ///         `StockAccountStrategy._checkRange`, not automatically the whole deposit cap.
    function test_fork_manipulationBreakEvenGrid() public {
        uint256[6] memory factors = [uint256(9_995), 9_975, 9_950, 9_900, 9_800, MAX_PUMP_SQRT_BPS];
        uint256 concentrated = MAX_STRATEGY_DEPOSIT;
        uint256 diversified = (MAX_STRATEGY_DEPOSIT * (DIVERSIFIED_TARGET_BPS + registry.maxDeviationBps())) / 10_000;
        uint256 minOrders = type(uint256).max;
        uint256 maxOrders;

        assertEq(registry.maxDeviationBps(), 1_000, "grid assumes the deployed deviation band");
        emit log_string(
            string.concat(
                "break-even grid: window 180s, budget 100 bps, exposure ",
                vm.toString(concentrated),
                " raw USDC concentrated / ",
                vm.toString(diversified),
                " raw USDC diversified"
            )
        );
        for (uint256 i = 0; i < factors.length; i++) {
            uint256 drift = _driftBpsAfterHold(factors[i], WINDOW);
            (, uint256 cost) = _roundTripCost(factors[i]);
            uint256 edge = _edgeBps(drift);
            uint256 gain = (concentrated * edge) / 10_000;
            uint256 gainDiversified = (diversified * edge) / 10_000;
            uint256 orders = (cost + gainDiversified - 1) / gainDiversified;
            emit log_string(
                string.concat(
                    "  sqrtP x0.",
                    vm.toString(factors[i]),
                    "  drift ",
                    vm.toString(drift),
                    " bps  edge ",
                    vm.toString(edge),
                    " bps  cost ",
                    vm.toString(cost),
                    " raw USDC  gain/order ",
                    vm.toString(gain),
                    " concentrated / ",
                    vm.toString(gainDiversified),
                    " diversified raw USDC  orders to break even 1 concentrated / ",
                    vm.toString(orders),
                    " diversified"
                )
            );
            assertGt(edge, drift, "edge did not compound the slippage budget");
            assertGt(edge, MAX_BACKEND_SLIPPAGE_BPS, "edge fell below the slippage budget alone");
            assertGt(gain, cost, "a concentrated basket did not pay for the manipulation on the first order");
            assertApproxEqAbs(
                drift, _sqrtMoveDriftBps(factors[i]), 2, "full-hold drift is not the commanded sqrt-price move"
            );
            assertEq(_driftBpsAfterHold(factors[i], 0), 0, "the manipulation paid off without being held");
            assertApproxEqAbs(
                _driftBpsAfterHold(factors[i], WINDOW / 2),
                _driftBpsForTickDelta(_tickDeltaForDriftBps(drift) / 2),
                2,
                "a half-window hold does not price at (1 + D)^(1/2) - 1"
            );
            if (orders < minOrders) minOrders = orders;
            if (orders > maxOrders) maxOrders = orders;
        }
        assertEq(minOrders, 1, "no pump on the grid paid for itself in one diversified order");
        assertGt(maxOrders, minOrders, "the grid is flat in orders to break even");
    }

    /// @notice How long the attacker must hold before the drift covers the whole backend budget, per
    ///         candidate window, against the closed form the linear mean tick implies.
    function test_fork_twapWindowSensitivity() public {
        uint32[3] memory windows = [uint32(60), 180, 300];
        emit log_string("window sensitivity (budget = 100 bps)");
        for (uint256 i = 0; i < windows.length; i++) {
            _setWindow(windows[i]);
            uint256 full = _driftBpsAfterHold(MAX_PUMP_SQRT_BPS, windows[i]);
            uint256 fullTicks = _tickDeltaForDriftBps(full);
            uint32 openAt = _holdToOpenBudget(windows[i]);
            uint32 predicted = _predictedHoldToOpenBudget(windows[i], fullTicks);
            emit log_string(
                string.concat(
                    "  window ",
                    vm.toString(windows[i]),
                    "s  full-hold drift ",
                    vm.toString(full),
                    " bps (",
                    vm.toString(fullTicks),
                    " ticks)  budget opens at ",
                    vm.toString(uint256(openAt)),
                    "s  closed form ",
                    vm.toString(uint256(predicted)),
                    "s"
                )
            );
            assertApproxEqAbs(full, 2_346, 5, "the pool's sqrt-price limit no longer bounds drift at ~2346 bps");
            assertEq(openAt, predicted, "budget did not open when the closed form says it should");
        }
    }

    /// @notice What the window actually buys: an attacker who can only hold the tick for `hold` seconds
    ///         needs a manipulation of (1 + budget)^(W/hold) - 1, which the pool's sqrt-price limit
    ///         eventually cannot reach.
    function test_fork_windowRaisesTheCostOfAShortAttack() public {
        uint32[2] memory holds = [uint32(30), 12];
        uint32[3] memory windows = [uint32(60), 180, 300];
        uint256 thirtySecondCostAtSixty;
        uint256 thirtySecondCostAtOneEighty;

        emit log_string("cheapest attack that opens a 100 bps budget within a bounded hold");
        for (uint256 i = 0; i < holds.length; i++) {
            for (uint256 j = 0; j < windows.length; j++) {
                _setWindow(windows[j]);
                uint256 required = _requiredDriftBps(windows[j] / holds[i]);
                uint256 factor = _cheapestPumpToOpenBudget(holds[i]);
                if (factor == 0) {
                    emit log_string(
                        string.concat(
                            "  window ",
                            vm.toString(windows[j]),
                            "s hold ",
                            vm.toString(holds[i]),
                            "s  needs ",
                            vm.toString(required),
                            " bps  UNREACHABLE at this pool's sqrt-price limit"
                        )
                    );
                    assertGt(required, 2_400, "an unreachable cell needed less drift than the pool can supply");
                    continue;
                }
                uint256 achieved = _driftBpsAfterHold(factor, windows[j]);
                (, uint256 cost) = _roundTripCost(factor);
                emit log_string(
                    string.concat(
                        "  window ",
                        vm.toString(windows[j]),
                        "s hold ",
                        vm.toString(holds[i]),
                        "s  needs ",
                        vm.toString(required),
                        " bps  cheapest pump reaches ",
                        vm.toString(achieved),
                        " bps  costing ",
                        vm.toString(cost),
                        " raw USDC"
                    )
                );
                assertApproxEqRel(achieved, required, 0.02e18, "measured manipulation is off the exponent law");
                if (holds[i] == 30 && windows[j] == 60) thirtySecondCostAtSixty = cost;
                if (holds[i] == 30 && windows[j] == 180) thirtySecondCostAtOneEighty = cost;
            }
        }

        assertGt(thirtySecondCostAtSixty, 0, "control: no 60s/30s measurement");
        assertGt(
            thirtySecondCostAtOneEighty, (thirtySecondCostAtSixty * 150) / 100, "tripling the window barely cost more"
        );
    }

    /// @notice The deflation direction is not bounded by the pool's USDC float: past the liquidity range
    ///         the price moves almost for free.
    function test_fork_dumpDirectionIsEffectivelyUnbounded() public {
        uint256 snap = vm.snapshotState();
        deal(USDC, address(this), 0);
        MockERC20Decimals(NVDAC).mint(NVDAC_USDC_POOL, PUMP_NVDAC_RESERVE);
        (, int24 tickBefore,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        uint256 poolUsdcBefore = IERC20(USDC).balanceOf(NVDAC_USDC_POOL);

        _dumpNvdacTo(11_000);
        uint256 nearSold = DUMP_NVDAC_IN - MockERC20Decimals(NVDAC).balanceOf(address(this));
        (, int24 tickNear,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        uint256 drained = IERC20(USDC).balanceOf(address(this));
        vm.revertToState(snap);

        snap = vm.snapshotState();
        deal(USDC, address(this), 0);
        MockERC20Decimals(NVDAC).mint(NVDAC_USDC_POOL, PUMP_NVDAC_RESERVE);
        _dumpNvdacTo(20_000);
        uint256 farSold = DUMP_NVDAC_IN - MockERC20Decimals(NVDAC).balanceOf(address(this));
        (, int24 tickFar,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        vm.revertToState(snap);

        emit log_string(
            string.concat(
                "dump: sqrtP x1.1 moves ",
                vm.toString(uint256(int256(tickNear - tickBefore))),
                " ticks for ",
                vm.toString(nearSold),
                " raw NVDAc and drains ",
                vm.toString((drained * 10_000) / poolUsdcBefore),
                " bps of the pool's USDC; sqrtP x2.0 moves ",
                vm.toString(uint256(int256(tickFar - tickBefore))),
                " ticks for ",
                vm.toString(farSold),
                " raw NVDAc"
            )
        );
        assertGt(drained * 10_000 / poolUsdcBefore, 9_000, "vacuous: the near dump left most of the USDC");
        assertGt(tickFar - tickBefore, 13_000, "the x2.0 dump did not move the price far");
        assertLt(farSold, (nearSold * 102) / 100, "the far dump cost materially more than the near one");
    }

    /// @notice The pump is not uniformly a conservative proxy for the dump: it understates the cost of an
    ///         operative manipulation and overstates the cost of a maximal one.
    function test_fork_pumpAndDumpCostsCross() public {
        (, uint256 pumpOperative) = _roundTripCost(9_950);
        (, uint256 dumpOperative) = _dumpRoundTripCost(10_050);
        (, uint256 pumpMaximal) = _roundTripCost(MAX_PUMP_SQRT_BPS);
        (, uint256 dumpMaximal) = _dumpRoundTripCost(11_000);

        emit log_string(
            string.concat(
                "operative (sqrtP 0.5%): pump ",
                vm.toString(pumpOperative),
                " vs dump ",
                vm.toString(dumpOperative),
                " raw USDC; maximal (sqrtP 10%): pump ",
                vm.toString(pumpMaximal),
                " vs dump ",
                vm.toString(dumpMaximal),
                " raw USDC"
            )
        );
        assertLt(pumpOperative, dumpOperative, "the pump no longer understates an operative dump");
        assertGt(pumpMaximal, dumpMaximal, "the pump no longer overstates a maximal dump");
    }

    /// @dev A USDC -> cbBTC swap on the near-dead spacing-10 pool, run to a 10% sqrt-price limit. The
    ///      amount is irrelevant: the pool is thin enough that the limit, not the size, decides the move.
    function _swapUsdcForCbbtc() internal {
        (uint160 sqrtP,,,,,) = ICLPool(CBBTC_USDC_POOL).slot0();
        deal(USDC, address(this), CBBTC_POOL_SWAP_USDC_IN);
        ICLPoolSwap(CBBTC_USDC_POOL).swap(
            address(this), true, int256(CBBTC_POOL_SWAP_USDC_IN), uint160((uint256(sqrtP) * 90) / 100), ""
        );
    }

    /// @notice A pool that keeps a single observation cannot be quoted at all, and growing its buffer is
    ///         necessary but not sufficient: until an observation lands inside the window the reference is
    ///         spot, with no manipulation resistance at all.
    function test_fork_freshPoolQuotesSpotUntilHistoryLandsInsideTheWindow() public {
        (,,, uint16 cardinality,,) = ICLPool(CBBTC_USDC_POOL).slot0();
        assertEq(cardinality, 1, "vacuous: the pool already keeps history");

        StockAccountRegistry poolRegistry = _deployRegistry();
        StockAccountPriceChecker poolChecker = new StockAccountPriceChecker(poolRegistry, USDC, existingChecker);
        vm.startPrank(admin);
        poolRegistry.setPriceChecker(poolChecker);
        poolRegistry.listToken(CBBTC, _poolTwapConfig(CBBTC_USDC_POOL));
        vm.stopPrank();

        uint256 feedPrice = existingChecker.getExpectedOut(1e8, CBBTC, USDC);
        uint256 spotBefore = _spotUsdcPerStock(CBBTC_USDC_POOL);
        assertLt(_bps(spotBefore, feedPrice), 500, "control: the pool starts off the feed");

        _swapUsdcForCbbtc();
        vm.expectRevert(
            abi.encodeWithSelector(StockAccountPriceChecker.InsufficientObservations.selector, CBBTC_USDC_POOL, WINDOW)
        );
        poolChecker.getExpectedOut(1e8, CBBTC, USDC);

        ICLPoolCardinality(CBBTC_USDC_POOL).increaseObservationCardinalityNext(200);
        vm.warp(vm.getBlockTimestamp() + 12);
        _swapUsdcForCbbtc();
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);

        (,,, uint16 grown,,) = ICLPool(CBBTC_USDC_POOL).slot0();
        assertEq(grown, 200, "buffer did not grow");

        uint256 quoted = poolChecker.getExpectedOut(1e8, CBBTC, USDC);
        uint256 manipulatedSpot = _spotUsdcPerStock(CBBTC_USDC_POOL);
        emit log_string(
            string.concat(
                "fresh pool: feed ",
                vm.toString(feedPrice),
                " raw USDC, quote ",
                vm.toString(quoted),
                " raw USDC (",
                vm.toString(_bps(quoted, feedPrice)),
                " bps off the feed, ",
                vm.toString(_bps(quoted, manipulatedSpot)),
                " bps off the manipulated spot)"
            )
        );
        assertEq(_bps(quoted, manipulatedSpot), 0, "the quote is not the manipulated spot");
        assertGt(_bps(quoted, feedPrice), 5_000, "the quote is not far off the feed");

        vm.warp(vm.getBlockTimestamp() + WINDOW - 20);
        _swapUsdcForCbbtc();
        vm.warp(vm.getBlockTimestamp() + 10);

        uint256 mixed = poolChecker.getExpectedOut(1e8, CBBTC, USDC);
        emit log_string(
            string.concat(
                "  with one observation inside the window: quote ",
                vm.toString(mixed),
                " raw USDC, ",
                vm.toString(_bps(mixed, _spotUsdcPerStock(CBBTC_USDC_POOL))),
                " bps off spot"
            )
        );
        assertGt(_bps(mixed, _spotUsdcPerStock(CBBTC_USDC_POOL)), 100, "the quote is still exactly spot");
    }
}
