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
                guardian: admin,
                maxBackendSlippageBps: MAX_BACKEND_SLIPPAGE_BPS,
                maxDeviationBps: 1000,
                maxPositions: 10,
                maxStrategyDeposit: MAX_STRATEGY_DEPOSIT,
                maxWithdrawSlippageBps: 500,
                minStrategyDeposit: 100e6,
                minTargetBps: 100,
                priceChecker: ISlippagePriceChecker(address(this)),
                requiredAppDataHash: bytes32(0),
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

    function test_fork_windowLongerThanHistoryReverts() public {
        vm.prank(admin);
        registry.setTwapWindow(type(uint32).max);
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

    /// @dev Buys NVDAc until the pool's sqrt price is 10% lower, i.e. NVDAc ~23% more expensive.
    ///      The pool is minted the NVDAc it pays out: the real reserve lives in node-native state
    ///      that the etch in `setUp` replaced.
    function _pumpNvdac() internal {
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        deal(USDC, address(this), PUMP_USDC_IN);
        MockERC20Decimals(NVDAC).mint(NVDAC_USDC_POOL, PUMP_NVDAC_RESERVE);
        ICLPoolSwap(NVDAC_USDC_POOL).swap(
            address(this), true, int256(PUMP_USDC_IN), uint160((uint256(sqrtP) * 90) / 100), ""
        );
    }

    /// @dev Sells NVDAc until the pool's sqrt price is 10% higher, i.e. NVDAc ~17% cheaper. That single
    ///      swap takes ~98% of the pool's USDC at the pin, so the limit cannot be widened much further.
    function _dumpNvdac() internal {
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        MockERC20Decimals(NVDAC).mint(address(this), DUMP_NVDAC_IN);
        ICLPoolSwap(NVDAC_USDC_POOL).swap(
            address(this), false, int256(DUMP_NVDAC_IN), uint160((uint256(sqrtP) * 110) / 100), ""
        );
    }

    /// @dev Drift of the NVDAc reference, in bps, `holdSeconds` after one pump that nothing trades back.
    ///      Measured on a state snapshot so a caller can sweep hold times from one starting state.
    function _driftBpsAfterHold(uint32 holdSeconds) internal returns (uint256) {
        uint256 baseline = checker.getExpectedOut(1e8, NVDAC, USDC);
        uint256 snap = vm.snapshotState();
        _pumpNvdac();
        vm.warp(vm.getBlockTimestamp() + holdSeconds);
        uint256 drifted = checker.getExpectedOut(1e8, NVDAC, USDC);
        vm.revertToState(snap);
        return ((drifted - baseline) * 10_000) / baseline;
    }

    /// @dev Smallest whole-second hold at which the pump's drift exceeds the backend's slippage budget,
    ///      or 0 if a full-window hold never does. Drift rises with hold time, so a bisection is exact.
    function _holdToOpenBudget(uint32 window) internal returns (uint32) {
        if (_driftBpsAfterHold(window) <= MAX_BACKEND_SLIPPAGE_BPS) return 0;
        uint32 lo = 1;
        uint32 hi = window;
        while (lo < hi) {
            uint32 mid = lo + (hi - lo) / 2;
            if (_driftBpsAfterHold(mid) > MAX_BACKEND_SLIPPAGE_BPS) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    /// @dev Pumps to the helper's limit and immediately sells the whole position back, returning the USDC
    ///      the pump committed and the USDC the round trip destroyed. Runs on a snapshot: the pool is
    ///      left exactly as it was found.
    function _roundTripCost() internal returns (uint256 committed, uint256 lost) {
        uint256 snap = vm.snapshotState();
        _pumpNvdac();
        uint256 usdcAfterPump = IERC20(USDC).balanceOf(address(this));
        committed = PUMP_USDC_IN - usdcAfterPump;
        uint256 held = MockERC20Decimals(NVDAC).balanceOf(address(this));
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        ICLPoolSwap(NVDAC_USDC_POOL).swap(address(this), false, int256(held), uint160((uint256(sqrtP) * 130) / 100), "");
        assertEq(MockERC20Decimals(NVDAC).balanceOf(address(this)), 0, "unwind left the position open");
        lost = committed - (IERC20(USDC).balanceOf(address(this)) - usdcAfterPump);
        vm.revertToState(snap);
    }

    function _setWindow(uint32 window) internal {
        if (registry.twapWindow() == window) return;
        vm.prank(admin);
        registry.setTwapWindow(window);
    }

    /// @notice A same-block manipulation moves the pool's live price and not the checker's quote.
    function test_fork_twapIgnoresSameBlockPoolManipulation() public {
        uint256 twapBefore = checker.getExpectedOut(1e8, NVDAC, USDC);
        uint256 spotBefore = _spotUsdcPerStock(NVDAC_USDC_POOL);

        _pumpNvdac();

        assertGt(_spotUsdcPerStock(NVDAC_USDC_POOL), (spotBefore * 110) / 100, "vacuous: spot moved less than 10%");
        assertEq(checker.getExpectedOut(1e8, NVDAC, USDC), twapBefore, "twap moved within the same block");
    }

    /// @notice Non-vacuity control for the test above: the TWAP converges on the held tick linearly in
    ///         hold time, so a full-window hold is the upper bound on the attack, not its threshold.
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

    /// @notice Holding a manipulated tick moves the reference in proportion to the fraction of the window
    ///         it occupies: an attacker buys drift by the second, not by clearing a threshold.
    function test_fork_twapDriftIsLinearInHoldTime() public {
        uint32[6] memory holds = [uint32(12), 30, 60, 90, 150, 180];
        uint256 full = _driftBpsAfterHold(WINDOW);
        assertGt(full, 2_000, "vacuous: a full-window hold barely moved the reference");

        emit log_string("drift vs hold, window 180s");
        for (uint256 i = 0; i < holds.length; i++) {
            uint256 measured = _driftBpsAfterHold(holds[i]);
            uint256 predicted = (full * holds[i]) / WINDOW;
            emit log_string(
                string.concat(
                    "  hold ",
                    vm.toString(holds[i]),
                    "s  drift ",
                    vm.toString(measured),
                    " bps  linear ",
                    vm.toString(predicted),
                    " bps"
                )
            );
            assertApproxEqRel(measured, predicted, 0.1e18, "drift is not linear in hold time");
        }
    }

    /// @notice Moving the pool and putting it straight back costs the attacker only swap fees, so the
    ///         manipulation is cheap relative to the float it moves.
    function test_fork_manipulationRoundTripCostsOnlyFees() public {
        (uint256 committed, uint256 lost) = _roundTripCost();
        uint256 costBps = (lost * 10_000) / committed;
        emit log_string(
            string.concat(
                "round trip: committed ",
                vm.toString(committed),
                " raw USDC, lost ",
                vm.toString(lost),
                " raw USDC, ",
                vm.toString(costBps),
                " bps"
            )
        );
        assertGt(lost, 0, "vacuous: the round trip was free");
        assertLt(costBps, 25, "round trip cost more than swap fees");
    }

    /// @notice How long the attacker has to hold the manipulated tick before the drift covers the whole
    ///         backend slippage budget, per candidate window. The cash cost does not depend on the window.
    function test_fork_twapWindowSensitivity() public {
        uint32[3] memory windows = [uint32(60), 180, 300];
        emit log_string("window sensitivity (budget = 100 bps)");
        for (uint256 i = 0; i < windows.length; i++) {
            _setWindow(windows[i]);
            uint256 full = _driftBpsAfterHold(windows[i]);
            uint32 openAt = _holdToOpenBudget(windows[i]);
            (uint256 committed, uint256 lost) = _roundTripCost();
            emit log_string(
                string.concat(
                    "  window ",
                    vm.toString(windows[i]),
                    "s  full-hold drift ",
                    vm.toString(full),
                    " bps  budget opens at ",
                    vm.toString(uint256(openAt)),
                    "s  round trip ",
                    vm.toString(lost),
                    " of ",
                    vm.toString(committed),
                    " raw USDC"
                )
            );
            assertGt(openAt, 0, "budget never opens inside the window");
            assertLt(openAt, windows[i], "budget only opens at a full-window hold");
            assertGt(lost, 0, "vacuous: the round trip was free");
        }
    }

    /// @notice Attacker cost against attacker gain. Gain per filled order is the deposit cap times the
    ///         mispricing the drift opens, capped at the backend's slippage budget because the checker
    ///         refuses anything worse: gain = maxStrategyDeposit * min(drift, budget) / 10_000.
    function test_fork_manipulationBreakEvenGrid() public {
        uint32[3] memory windows = [uint32(60), 180, 300];
        uint32[3] memory holds = [uint32(30), 90, 180];
        (, uint256 cost) = _roundTripCost();

        emit log_string(
            string.concat(
                "break-even grid: cost ",
                vm.toString(cost),
                " raw USDC per round trip, deposit cap ",
                vm.toString(MAX_STRATEGY_DEPOSIT),
                " raw USDC, budget ",
                vm.toString(uint256(MAX_BACKEND_SLIPPAGE_BPS)),
                " bps"
            )
        );
        for (uint256 i = 0; i < windows.length; i++) {
            _setWindow(windows[i]);
            for (uint256 j = 0; j < holds.length; j++) {
                uint256 drift = _driftBpsAfterHold(holds[j]);
                uint256 usable = drift > MAX_BACKEND_SLIPPAGE_BPS ? MAX_BACKEND_SLIPPAGE_BPS : drift;
                uint256 gain = (MAX_STRATEGY_DEPOSIT * usable) / 10_000;
                uint256 orders = gain == 0 ? 0 : (cost + gain - 1) / gain;
                emit log_string(
                    string.concat(
                        "  window ",
                        vm.toString(windows[i]),
                        "s hold ",
                        vm.toString(holds[j]),
                        "s  drift ",
                        vm.toString(drift),
                        " bps  usable ",
                        vm.toString(usable),
                        " bps  gain/order ",
                        vm.toString(gain),
                        " raw USDC  orders to break even ",
                        vm.toString(orders)
                    )
                );
                assertGt(gain, 0, "vacuous: no gain at all");
            }
        }
    }

    /// @dev A small USDC -> cbBTC swap on the shallow spacing-10 pool: enough to cross a tick, which is
    ///      what makes the pool write an observation.
    function _swapUsdcForCbbtc() internal {
        (uint160 sqrtP,,,,,) = ICLPool(CBBTC_USDC_POOL).slot0();
        deal(USDC, address(this), CBBTC_POOL_SWAP_USDC_IN);
        ICLPoolSwap(CBBTC_USDC_POOL).swap(
            address(this), true, int256(CBBTC_POOL_SWAP_USDC_IN), uint160((uint256(sqrtP) * 90) / 100), ""
        );
    }

    /// @notice A live pool that keeps a single observation cannot be quoted at all until someone pays to
    ///         grow its buffer and a window of history accumulates.
    function test_fork_freshPoolHasNoUsableObservations() public {
        (,,, uint16 cardinality,,) = ICLPool(CBBTC_USDC_POOL).slot0();
        assertEq(cardinality, 1, "vacuous: the pool already keeps history");

        StockAccountRegistry poolRegistry = _deployRegistry();
        StockAccountPriceChecker poolChecker = new StockAccountPriceChecker(poolRegistry, USDC, existingChecker);
        vm.startPrank(admin);
        poolRegistry.setPriceChecker(poolChecker);
        poolRegistry.listToken(CBBTC, _poolTwapConfig(CBBTC_USDC_POOL));
        vm.stopPrank();

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
        assertGt(poolChecker.getExpectedOut(1e8, CBBTC, USDC), 0, "pool still unquotable");
    }
}
