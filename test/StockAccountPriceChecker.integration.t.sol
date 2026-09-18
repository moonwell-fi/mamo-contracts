// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockCLPoolObserve} from "@test/mocks/MockCLPoolObserve.sol";
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

/// @notice Live NVDAc/USDC Aerodrome Slipstream pool and live Chainlink feeds on a PINNED Base fork.
///         Self-forks in setUp (no --fork-url on the CLI, see the lp-auto-balancer-v2 Makefile note).
contract StockAccountPriceCheckerIntegrationTest is Test {
    uint256 internal constant PINNED_BLOCK = 51_181_271;
    uint32 internal constant WINDOW = 180;
    uint256 internal constant CBBTC_MAX_TIME_PRICE_VALID = 3600;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C; // 8 dec, pool token1
    address internal constant NVDAC_USDC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9; // tick spacing 10
    address internal constant AERODROME_CL_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // 8 dec
    address internal constant CHAINLINK_BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant STRANGER = 0x000000000000000000000000000000000000dEaD;

    /// @dev Swap inputs large enough to run the pool to the sqrt-price limit the helpers set; the
    ///      limit, not the amount, is what decides how far the price moves.
    uint256 internal constant PUMP_USDC_IN = 2_000_000e6;
    uint256 internal constant DUMP_NVDAC_IN = 200_000e8;

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
        assertEq(MockERC20Decimals(NVDAC).decimals(), 8);

        existingChecker = _deployExistingChecker();

        // The checker takes the registry as an immutable, so the registry is built first against a
        // code-bearing stand-in (this test contract) and repointed once the real checker exists.
        registry = new StockAccountRegistry(
            StockAccountRegistry.Config({
                admin: admin,
                aerodromeRouter: ISwapRouter(AERODROME_CL_ROUTER),
                guardian: admin,
                maxBackendSlippageBps: 100,
                maxDeviationBps: 1000,
                maxPositions: 10,
                maxStrategyDeposit: 25_000e6,
                maxWithdrawSlippageBps: 500,
                minStrategyDeposit: 100e6,
                minTargetBps: 100,
                priceChecker: ISlippagePriceChecker(address(this)),
                requiredAppDataHash: bytes32(0),
                twapWindow: WINDOW
            })
        );
        checker = new StockAccountPriceChecker(registry, USDC, existingChecker);
        vm.prank(admin);
        registry.setPriceChecker(checker);
        assertEq(address(registry.priceChecker()), address(checker));

        vm.prank(admin);
        registry.listToken(
            NVDAC,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: NVDAC_USDC_POOL,
                chainlinkFeed: address(0)
            })
        );

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

    /// @dev A fresh SlippagePriceChecker proxy owned by this test, configured cbBTC -> USDC in the
    ///      house two-hop shape (token/USD forward, USDC/USD reverse) from config/strategies/*.json.
    function _deployExistingChecker() internal returns (SlippagePriceChecker) {
        address impl = address(new SlippagePriceChecker());
        bytes memory init = abi.encodeWithSelector(SlippagePriceChecker.initialize.selector, address(this));
        SlippagePriceChecker proxy = SlippagePriceChecker(address(new ERC1967Proxy(impl, init)));

        ISlippagePriceChecker.TokenFeedConfiguration[] memory cfgs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](2);
        cfgs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: CHAINLINK_BTC_USD, reverse: false, heartbeat: 3600
        });
        cfgs[1] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: CHAINLINK_USDC_USD, reverse: true, heartbeat: 86_400
        });
        proxy.addTokenConfiguration(CBBTC, USDC, cfgs);
        proxy.setMaxTimePriceValid(CBBTC, CBBTC_MAX_TIME_PRICE_VALID);
        return proxy;
    }

    /// @dev USDC raw per 1 NVDAc from the pool's current sqrt price (token1 -> token0).
    function _spotUsdcPerNvdac() internal view returns (uint256) {
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        uint256 ratioX192 = uint256(sqrtP) * sqrtP;
        return Math.mulDiv(1 << 192, 1e8, ratioX192);
    }

    function test_fork_referenceTracksLiveSpot() public view {
        uint256 twapOut = checker.getExpectedOut(1e8, NVDAC, USDC);
        uint256 spot = _spotUsdcPerNvdac();
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
        uint256 usdcPerNvdac = _spotUsdcPerNvdac();
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

    // ==================== Live pool manipulation ====================

    /// @dev Settles a swap this test initiated; NVDAc is the etched stand-in, USDC is the real token.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        assertEq(msg.sender, NVDAC_USDC_POOL, "callback from an unexpected pool");
        if (amount0Delta > 0) IERC20(USDC).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) MockERC20Decimals(NVDAC).transfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev Buys NVDAc until the pool's sqrt price is 10% lower, i.e. NVDAc ~23% more expensive.
    ///      The pool is minted the NVDAc it pays out: the real reserve lives in node-native state
    ///      that the etch in `setUp` replaced.
    function _pumpNvdac() internal {
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        deal(USDC, address(this), PUMP_USDC_IN);
        MockERC20Decimals(NVDAC).mint(NVDAC_USDC_POOL, DUMP_NVDAC_IN);
        ICLPoolSwap(NVDAC_USDC_POOL)
            .swap(address(this), true, int256(PUMP_USDC_IN), uint160((uint256(sqrtP) * 90) / 100), "");
    }

    /// @dev Sells NVDAc until the pool's sqrt price is 10% higher, i.e. NVDAc ~17% cheaper.
    function _dumpNvdac() internal {
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        MockERC20Decimals(NVDAC).mint(address(this), DUMP_NVDAC_IN);
        ICLPoolSwap(NVDAC_USDC_POOL)
            .swap(address(this), false, int256(DUMP_NVDAC_IN), uint160((uint256(sqrtP) * 110) / 100), "");
    }

    /// @notice A same-block manipulation moves the pool's live price and not the checker's quote.
    function test_fork_twapIgnoresSameBlockPoolManipulation() public {
        uint256 twapBefore = checker.getExpectedOut(1e8, NVDAC, USDC);
        uint256 spotBefore = _spotUsdcPerNvdac();

        _pumpNvdac();

        assertGt(_spotUsdcPerNvdac(), (spotBefore * 110) / 100, "vacuous: spot moved less than 10%");
        assertEq(checker.getExpectedOut(1e8, NVDAC, USDC), twapBefore, "twap moved within the same block");
    }

    /// @notice Non-vacuity control for the test above: holding the manipulated tick for the whole
    ///         window does move the quote, so the window length is what bounds the attack.
    function test_fork_manipulationHeldForTheWholeWindowMovesTheTwap() public {
        uint256 twapBefore = checker.getExpectedOut(1e8, NVDAC, USDC);

        _pumpNvdac();
        uint256 spotAfter = _spotUsdcPerNvdac();
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);

        uint256 twapAfter = checker.getExpectedOut(1e8, NVDAC, USDC);
        assertGt(twapAfter, (twapBefore * 110) / 100, "vacuous: twap did not follow the held tick");
        assertApproxEqRel(twapAfter, spotAfter, 0.01e18, "held tick should price at the manipulated spot");
    }

    /// @notice A crashed spot cannot serve as the slippage floor: the TWAP still prices NVDAc high,
    ///         so a sell quoted off the manipulated pool is rejected.
    function test_fork_checkPriceRejectsFloorDerivedFromCrashedSpot() public {
        uint256 spotBefore = _spotUsdcPerNvdac();
        uint256 fairFloor = (checker.getExpectedOut(1e8, NVDAC, USDC) * 9_900) / 10_000;
        assertTrue(checker.checkPrice(1e8, NVDAC, USDC, fairFloor, 100), "control: fair floor rejected");

        _dumpNvdac();

        uint256 crashedSpot = _spotUsdcPerNvdac();
        assertLt(crashedSpot, (spotBefore * 90) / 100, "vacuous: spot did not crash 10%");
        assertFalse(checker.checkPrice(1e8, NVDAC, USDC, crashedSpot, 100), "crashed-spot floor accepted");
    }

    /// @notice The Chainlink leg keeps exact parity with the existing checker across a pool attack.
    function test_fork_chainlinkParitySurvivesPoolManipulation() public {
        _pumpNvdac();
        assertEq(checker.getExpectedOut(1e8, CBBTC, USDC), existingChecker.getExpectedOut(1e8, CBBTC, USDC));
        assertEq(checker.getExpectedOut(100e8, CBBTC, USDC), existingChecker.getExpectedOut(100e8, CBBTC, USDC));
    }
}
