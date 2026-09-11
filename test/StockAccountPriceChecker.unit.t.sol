// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockCLPoolObserve} from "@test/mocks/MockCLPoolObserve.sol";
import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";
import {MockStockAccountRegistry} from "@test/mocks/MockStockAccountRegistry.sol";

contract StockAccountPriceCheckerUnitTest is Test {
    uint32 internal constant WINDOW = 180;
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant EXPECTED_ALT_TICK_500000 = 5171760815372400971558161892130124037985;

    address internal owner = makeAddr("owner");
    MockStockAccountRegistry internal registry;
    StockAccountPriceChecker internal checker;

    MockERC20Decimals internal usdc; // 6 dec
    MockERC20Decimals internal stock; // 8 dec, pool token1 (USDC is token0) — same layout as live NVDAc/USDC
    MockERC20Decimals internal alt; // 18 dec, pool token0 (USDC is token1)
    MockERC20Decimals internal feedToken; // Chainlink-sourced
    MockERC20Decimals internal orphan; // pool not against USDC

    MockCLPoolObserve internal stockPool;
    MockCLPoolObserve internal altPool;
    MockCLPoolObserve internal orphanPool;

    function setUp() public {
        usdc = new MockERC20Decimals("USDC", 6);
        stock = new MockERC20Decimals("STOCK", 8);
        alt = new MockERC20Decimals("ALT", 18);
        feedToken = new MockERC20Decimals("FEED", 8);
        orphan = new MockERC20Decimals("ORPHAN", 8);

        stockPool = new MockCLPoolObserve(address(usdc), address(stock));
        altPool = new MockCLPoolObserve(address(alt), address(usdc));
        orphanPool = new MockCLPoolObserve(address(orphan), address(stock));

        registry = new MockStockAccountRegistry();
        registry.setTwapWindow(WINDOW);
        _list(address(stock), address(stockPool), IStockAccountRegistry.PriceSource.PoolTwap);
        _list(address(alt), address(altPool), IStockAccountRegistry.PriceSource.PoolTwap);
        _list(address(orphan), address(orphanPool), IStockAccountRegistry.PriceSource.PoolTwap);
        _list(address(feedToken), address(stockPool), IStockAccountRegistry.PriceSource.Chainlink);

        StockAccountPriceChecker impl = new StockAccountPriceChecker();
        bytes memory init = abi.encodeCall(StockAccountPriceChecker.initialize, (owner, registry, address(usdc)));
        checker = StockAccountPriceChecker(address(new ERC1967Proxy(address(impl), init)));

        stockPool.setMeanTick(0, WINDOW);
        altPool.setMeanTick(0, WINDOW);
    }

    function _list(address token, address pool, IStockAccountRegistry.PriceSource source) internal {
        registry.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: source,
                pool: pool,
                chainlinkFeed: address(0)
            })
        );
    }

    /// @dev Independent reference: quote raw per `baseAmount` raw at `tick`, OracleLibrary-style.
    function _quoteAtTick(int24 tick, uint256 baseAmount, bool baseIsToken0) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        uint256 ratioX192 = uint256(sqrtP) * sqrtP;
        return
            baseIsToken0 ? Math.mulDiv(ratioX192, baseAmount, 1 << 192) : Math.mulDiv(1 << 192, baseAmount, ratioX192);
    }

    // ==================== initialize ====================

    function test_initialize_setsRegistryQuoteAssetAndOwner() public view {
        assertEq(address(checker.registry()), address(registry));
        assertEq(checker.quoteAsset(), address(usdc));
        assertEq(checker.owner(), owner);
    }

    function test_initialize_revertsOnZeroAddresses() public {
        StockAccountPriceChecker impl = new StockAccountPriceChecker();
        vm.expectRevert(StockAccountPriceChecker.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                StockAccountPriceChecker.initialize, (owner, IStockAccountRegistry(address(0)), address(usdc))
            )
        );
        vm.expectRevert(StockAccountPriceChecker.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(StockAccountPriceChecker.initialize, (owner, registry, address(0)))
        );
    }

    function test_initialize_cannotRunTwice() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        checker.initialize(owner, registry, address(usdc));
    }

    // ==================== TWAP reference ====================

    function test_getExpectedOut_tickZero_stockToUsdc() public view {
        // tick 0: 1 raw stock == 1 raw USDC, so 1 whole stock (1e8) == 1e8 raw USDC ($100)
        assertEq(checker.getExpectedOut(1e8, address(stock), address(usdc)), 1e8);
    }

    function test_getExpectedOut_tickZero_usdcToStock() public view {
        assertEq(checker.getExpectedOut(1e8, address(usdc), address(stock)), 1e8);
    }

    function test_getExpectedOut_liveLikeTick_matchesOracleLibraryQuote() public {
        // NVDAc/USDC pool layout (USDC token0, stock token1), live tick around -7880
        int24 tick = -7880;
        stockPool.setMeanTick(tick, WINDOW);
        uint256 amountIn = 3e8;
        uint256 expected = _quoteAtTick(tick, amountIn, false);
        assertGt(expected, 0);
        assertApproxEqRel(checker.getExpectedOut(amountIn, address(stock), address(usdc)), expected, 1e12);
        // ~$219.9 per share at that tick
        assertApproxEqRel(checker.getExpectedOut(1e8, address(stock), address(usdc)), 219.9e6, 1e15);
    }

    function test_getExpectedOut_tokenIsToken0_invertsCorrectly() public {
        // alt is token0, USDC token1: raw USDC per raw alt = 1.0001^tick
        int24 tick = 5000;
        altPool.setMeanTick(tick, WINDOW);
        uint256 expected = _quoteAtTick(tick, 1e18, true);
        assertGt(expected, 0);
        assertApproxEqRel(checker.getExpectedOut(1e18, address(alt), address(usdc)), expected, 1e12);
    }

    function test_getExpectedOut_negativeRemainderFloorsTowardNegativeInfinity() public {
        // delta -1 over 180s: floor is tick -1, truncation would be tick 0
        stockPool.setCumulatives(0, -1);
        uint256 out = checker.getExpectedOut(1e8, address(stock), address(usdc));
        uint256 atMinusOne = _quoteAtTick(-1, 1e8, false);
        assertGt(out, 1e8);
        assertApproxEqRel(out, atMinusOne, 1e12);
    }

    function test_getExpectedOut_negativeExactMultipleDoesNotOverFloor() public {
        stockPool.setCumulatives(0, -int56(uint56(WINDOW)) * 3);
        uint256 out = checker.getExpectedOut(1e8, address(stock), address(usdc));
        assertApproxEqRel(out, _quoteAtTick(-3, 1e8, false), 1e12);
    }

    function test_getExpectedOut_windowReadLiveFromRegistry() public {
        // cumulatives encode mean tick 100 over 180s; with a 300s window the same delta reads as tick 60
        stockPool.setMeanTick(100, WINDOW);
        uint256 at180 = checker.getExpectedOut(1e8, address(stock), address(usdc));
        registry.setTwapWindow(300);
        uint256 at300 = checker.getExpectedOut(1e8, address(stock), address(usdc));
        assertApproxEqRel(at180, _quoteAtTick(100, 1e8, false), 1e12);
        assertApproxEqRel(at300, _quoteAtTick(60, 1e8, false), 1e12);
    }

    // ==================== bidirectional / token-to-token ====================

    function test_getExpectedOut_usdcToUsdcIsIdentity() public view {
        assertEq(checker.getExpectedOut(123_456_789, address(usdc), address(usdc)), 123_456_789);
    }

    function test_getExpectedOut_tokenToToken_composesThroughUsdc() public {
        stockPool.setMeanTick(-7880, WINDOW); // ~$219.9 per stock
        altPool.setMeanTick(-276324, WINDOW); // 18-dec alt vs 6-dec USDC, ~$1 per whole alt
        uint256 stockToUsdc = checker.getExpectedOut(1e8, address(stock), address(usdc));
        uint256 usdcToAlt = checker.getExpectedOut(stockToUsdc, address(usdc), address(alt));
        uint256 direct = checker.getExpectedOut(1e8, address(stock), address(alt));
        assertGt(direct, 0);
        assertApproxEqRel(direct, usdcToAlt, 1e12);
        assertApproxEqRel(direct, 219.9e18, 1e14);
    }

    function test_getExpectedOut_roundTripsWithinRounding() public {
        stockPool.setMeanTick(-7880, WINDOW);
        altPool.setMeanTick(-276324, WINDOW);
        uint256 forward = checker.getExpectedOut(5e8, address(stock), address(alt));
        uint256 back = checker.getExpectedOut(forward, address(alt), address(stock));
        assertApproxEqAbs(back, 5e8, 2);
    }

    function test_getExpectedOut_mixedDecimals_18to6And8to6() public {
        altPool.setMeanTick(-276324, WINDOW);
        assertApproxEqRel(checker.getExpectedOut(1e18, address(alt), address(usdc)), 1e6, 1e14);
        stockPool.setMeanTick(0, WINDOW);
        assertEq(checker.getExpectedOut(1e8, address(stock), address(usdc)), 1e8);
    }

    // ==================== gates ====================

    function test_getExpectedOut_revertsForUnlistedToken() public {
        address stranger = address(new MockERC20Decimals("X", 8));
        vm.expectRevert(abi.encodeWithSelector(StockAccountPriceChecker.TokenNotListed.selector, stranger));
        checker.getExpectedOut(1e8, stranger, address(usdc));
        vm.expectRevert(abi.encodeWithSelector(StockAccountPriceChecker.TokenNotListed.selector, stranger));
        checker.getExpectedOut(1e8, address(usdc), stranger);
    }

    function test_getExpectedOut_pricesSellOnlyAndHaltedTokens() public {
        IStockAccountRegistry.TokenConfig memory cfg = registry.tokenConfig(address(stock));
        cfg.status = IStockAccountRegistry.TokenStatus.SellOnly;
        registry.setTokenConfig(address(stock), cfg);
        assertEq(checker.getExpectedOut(1e8, address(stock), address(usdc)), 1e8);
        cfg.status = IStockAccountRegistry.TokenStatus.Halted;
        registry.setTokenConfig(address(stock), cfg);
        assertEq(checker.getExpectedOut(1e8, address(stock), address(usdc)), 1e8);
    }

    function test_getExpectedOut_highTick_ratioX128Branch() public {
        // sqrtP exceeds uint128 above tick ~443,614; 1.0001^500000 * 1e18 computed off-chain with 60-digit Decimal
        altPool.setMeanTick(500_000, WINDOW);
        uint256 out = checker.getExpectedOut(1e18, address(alt), address(usdc));
        assertGt(out, 0);
        assertApproxEqRel(out, EXPECTED_ALT_TICK_500000, 1e12);
        // and the reverse direction lands back within rounding
        assertApproxEqAbs(checker.getExpectedOut(out, address(usdc), address(alt)), 1e18, 1e6);
    }

    function test_getExpectedOut_singleFloor_liveLikeTrade() public {
        // 3 NVDAc at tick -7880: exact value is 659,672,221.31 raw USDC; a pre-scale floor gives ...220
        stockPool.setMeanTick(-7880, WINDOW);
        assertEq(checker.getExpectedOut(3e8, address(stock), address(usdc)), 659_672_221);
    }

    function test_getExpectedOut_revertsForChainlinkSource() public {
        vm.expectRevert(
            abi.encodeWithSelector(StockAccountPriceChecker.UnsupportedPriceSource.selector, address(feedToken))
        );
        checker.getExpectedOut(1e8, address(feedToken), address(usdc));
    }

    function test_getExpectedOut_revertsWhenPoolNotAgainstQuoteAsset() public {
        vm.expectRevert(
            abi.encodeWithSelector(StockAccountPriceChecker.PoolNotAgainstQuoteAsset.selector, address(orphanPool))
        );
        checker.getExpectedOut(1e8, address(orphan), address(usdc));
    }

    function test_getExpectedOut_revertsOnInsufficientObservations() public {
        stockPool.setRevertOld(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockAccountPriceChecker.InsufficientObservations.selector, address(stockPool), WINDOW
            )
        );
        checker.getExpectedOut(1e8, address(stock), address(usdc));
        vm.expectRevert(
            abi.encodeWithSelector(
                StockAccountPriceChecker.InsufficientObservations.selector, address(stockPool), WINDOW
            )
        );
        checker.checkPrice(1e8, address(stock), address(usdc), 1, 100);
    }

    // ==================== checkPrice ====================

    function test_checkPrice_exactToleranceBoundaryIsInclusive() public {
        stockPool.setMeanTick(-7880, WINDOW);
        uint256 expected = checker.getExpectedOut(7e8, address(stock), address(usdc));
        uint256 floor = (expected * (MAX_BPS - 100)) / MAX_BPS;
        assertTrue(checker.checkPrice(7e8, address(stock), address(usdc), floor, 100));
        assertFalse(checker.checkPrice(7e8, address(stock), address(usdc), floor - 1, 100));
        assertTrue(checker.checkPrice(7e8, address(stock), address(usdc), expected + 1, 100));
    }

    function test_checkPrice_zeroSlippageRequiresFullExpected() public view {
        assertTrue(checker.checkPrice(1e8, address(stock), address(usdc), 1e8, 0));
        assertFalse(checker.checkPrice(1e8, address(stock), address(usdc), 1e8 - 1, 0));
    }

    function test_checkPrice_zeroExpectedOutNeverPasses() public view {
        assertEq(checker.getExpectedOut(0, address(stock), address(usdc)), 0);
        assertFalse(checker.checkPrice(0, address(stock), address(usdc), 0, MAX_BPS));
        assertFalse(checker.checkPrice(0, address(stock), address(usdc), 1, 100));
    }

    function test_checkPrice_revertsAboveMaxBps() public {
        vm.expectRevert(abi.encodeWithSelector(StockAccountPriceChecker.InvalidSlippage.selector, MAX_BPS + 1));
        checker.checkPrice(1e8, address(stock), address(usdc), 1, MAX_BPS + 1);
    }

    // ==================== legacy ISlippagePriceChecker surface ====================

    function test_legacyMutators_revertNotSupported() public {
        ISlippagePriceChecker.TokenFeedConfiguration[] memory cfgs;
        vm.startPrank(owner);
        vm.expectRevert(StockAccountPriceChecker.NotSupported.selector);
        checker.addTokenConfiguration(address(stock), address(usdc), cfgs);
        vm.expectRevert(StockAccountPriceChecker.NotSupported.selector);
        checker.removeTokenConfiguration(address(stock), address(usdc));
        vm.expectRevert(StockAccountPriceChecker.NotSupported.selector);
        checker.setMaxTimePriceValid(address(stock), 1);
        vm.stopPrank();
    }

    function test_legacyViews_answerFromRegistry() public {
        assertEq(checker.tokenPairOracleInformation(address(stock), address(usdc)).length, 0);
        assertFalse(checker.isRewardToken(address(stock)));
        assertEq(checker.maxTimePriceValid(address(stock)), WINDOW);
        assertTrue(checker.isTokenPairConfigured(address(stock), address(usdc)));
        assertTrue(checker.isTokenPairConfigured(address(usdc), address(alt)));
        assertTrue(checker.isTokenPairConfigured(address(stock), address(alt)));
        assertFalse(checker.isTokenPairConfigured(address(feedToken), address(usdc)));
        assertFalse(checker.isTokenPairConfigured(address(stock), makeAddr("nobody")));
    }

    function test_isTokenPairConfigured_tracksNewListing() public {
        MockERC20Decimals fresh = new MockERC20Decimals("FRESH", 8);
        assertFalse(checker.isTokenPairConfigured(address(fresh), address(usdc)));
        MockCLPoolObserve pool = new MockCLPoolObserve(address(usdc), address(fresh));
        pool.setMeanTick(0, WINDOW);
        _list(address(fresh), address(pool), IStockAccountRegistry.PriceSource.PoolTwap);
        assertTrue(checker.isTokenPairConfigured(address(fresh), address(usdc)));
        assertEq(checker.getExpectedOut(1e8, address(fresh), address(usdc)), 1e8);
    }

    // ==================== upgrade ====================

    function test_upgrade_onlyOwner() public {
        StockAccountPriceChecker next = new StockAccountPriceChecker();
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        checker.upgradeToAndCall(address(next), "");

        vm.prank(owner);
        checker.upgradeToAndCall(address(next), "");
        assertEq(checker.quoteAsset(), address(usdc));
        assertEq(address(checker.registry()), address(registry));
    }
}
