// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";

/// @notice Replays the ANTc pool on 2026-11-19, when an in-range liquidity gap let two buys sweep it to
///         MIN_TICK, against the live checker (bad quote) and the hardened one (refuses to quote).
contract StockAccountPriceCheckerWindowIntegrationTest is Test {
    /// @dev Window clean (control), 2 zero-liquidity seconds (TWAP 287 USDC), 103 seconds (TWAP 6e22 USDC).
    uint256 internal constant CLEAN_BLOCK = 59_591_200;
    uint256 internal constant MILD_BLOCK = 59_591_500;
    uint256 internal constant SWEPT_BLOCK = 59_592_800;
    /// @dev Floored mean ticks over the 180 s window at those blocks, from `observe([180, 0])`.
    int24 internal constant CLEAN_TICK = -650;
    int24 internal constant MILD_TICK = -10_573;
    int24 internal constant SWEPT_TICK = -478_551;

    address internal constant REGISTRY = 0xE5312013c603Fe0F73eB3DD56a41964F6756eEDc;
    address internal constant LIVE_CHECKER = 0x0f34Fbab256D24d20928F036685635c3f9130289;
    address internal constant MAMO_MULTISIG = 0x26c158A4CD56d148c554190A95A921d90F00C160;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant ANTC = 0xb20000000000000000000016e38FD364d271Ba28; // 8 dec, pool token1
    address internal constant ANTC_POOL = 0x599C4225FE90214795a0be228D20d7680f8CED15;
    uint32 internal constant WINDOW = 180;
    /// @dev The TWAP window may stray at most 2,000 ticks (~22%) from the 30 minutes before it; the largest genuine 14-day move was 1,371
    uint32 internal constant BASELINE_WINDOW = 1800;
    uint24 internal constant MAX_TWAP_DEVIATION_TICKS = 2000;
    /// @dev Below every listed pool's 14-day low (1.37e11) and above every full-range floor (at most 4.4e9)
    uint128 internal constant MIN_HARMONIC_LIQUIDITY = 1e11;

    StockAccountRegistry internal registry = StockAccountRegistry(REGISTRY);
    StockAccountPriceChecker internal live = StockAccountPriceChecker(LIVE_CHECKER);
    StockAccountPriceChecker internal hardened;

    function _forkAt(uint256 blockNumber) internal {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), blockNumber);
        vm.fee(0);
        // B20 tokens are node-native (code 0xef) and revm cannot run them: every listed stock is 8 decimals
        vm.etch(ANTC, address(new MockERC20Decimals("ANTc", 8)).code);
        address[] memory tokens = registry.allTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            vm.etch(tokens[i], address(new MockERC20Decimals("stock", 8)).code);
        }

        hardened = new StockAccountPriceChecker(
            IStockAccountRegistry(REGISTRY),
            USDC,
            live.existingChecker(),
            live.sequencerUptimeFeed(),
            live.sequencerGracePeriod(),
            BASELINE_WINDOW,
            MAX_TWAP_DEVIATION_TICKS,
            MIN_HARMONIC_LIQUIDITY
        );
        assertEq(registry.twapWindow(), WINDOW);
    }

    /// @dev ANTc was not listed until block 59,618,114, so its config is mocked in for the quote-only replays.
    function _mockAntcListed() internal {
        vm.mockCall(
            REGISTRY,
            abi.encodeCall(IStockAccountRegistry.tokenConfig, (ANTC)),
            abi.encode(
                IStockAccountRegistry.TokenConfig({
                    status: IStockAccountRegistry.TokenStatus.Active,
                    source: IStockAccountRegistry.PriceSource.PoolTwap,
                    pool: ANTC_POOL,
                    chainlinkFeed: address(0)
                })
            )
        );
    }

    /// @dev Raw USDC for 1 ANTc at `tick` (ANTc is token1), through the checker's 36-decimal intermediate.
    function _usdcPerAntcAt(int24 tick) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        uint256 perWhole36 = Math.mulDiv(1 << 192, 1e38, uint256(sqrtP) * sqrtP);
        return perWhole36 / 1e30;
    }

    function _expectZeroLiquidity() internal {
        vm.expectRevert(
            abi.encodeWithSelector(StockAccountPriceChecker.ZeroLiquidityInWindow.selector, ANTC_POOL, WINDOW)
        );
    }

    function test_cleanWindow_hardenedMatchesLive() public {
        _forkAt(CLEAN_BLOCK);
        _mockAntcListed();
        uint256 expected = _usdcPerAntcAt(CLEAN_TICK);
        assertEq(live.getExpectedOut(1e8, ANTC, USDC), expected);
        assertEq(hardened.getExpectedOut(1e8, ANTC, USDC), expected);
        assertEq(hardened.getExpectedOut(1e6, USDC, ANTC), live.getExpectedOut(1e6, USDC, ANTC));
    }

    function test_mildWindow_liveQuotes287_hardenedRefuses() public {
        _forkAt(MILD_BLOCK);
        _mockAntcListed();
        uint256 bad = live.getExpectedOut(1e8, ANTC, USDC);
        assertEq(bad, _usdcPerAntcAt(MILD_TICK));
        assertEq(bad / 1e6, 287, "the live checker quotes 287 USDC per ANTc");

        _expectZeroLiquidity();
        hardened.getExpectedOut(1e8, ANTC, USDC);
        _expectZeroLiquidity();
        hardened.getExpectedOut(1e6, USDC, ANTC);
    }

    function test_sweptWindow_liveQuotes6e22_hardenedRefuses() public {
        _forkAt(SWEPT_BLOCK);
        _mockAntcListed();
        uint256 bad = live.getExpectedOut(1e8, ANTC, USDC);
        assertEq(bad, _usdcPerAntcAt(SWEPT_TICK));
        assertEq(bad / 1e6 / 1e22, 6, "the live checker quotes ~6e22 USDC per ANTc");

        _expectZeroLiquidity();
        hardened.getExpectedOut(1e8, ANTC, USDC);
        _expectZeroLiquidity();
        hardened.checkPrice(1e8, ANTC, USDC, 1, 100);
    }

    /// @notice NVDAc's genuine ~14% move at block 61,262,205 (deep liquidity) quotes at 2,000 ticks and would be
    ///         refused at 1,000.
    function test_genuineNvdacMove_quotesWithinTheDeviationBound() public {
        _forkAt(61_262_205);
        address nvdac = 0xb20000000000000000000078ee7ce2fE4908108C;
        address nvdacPool = 0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC;
        assertGt(hardened.getExpectedOut(1e8, nvdac, USDC), 0);

        StockAccountPriceChecker tight = new StockAccountPriceChecker(
            IStockAccountRegistry(REGISTRY),
            USDC,
            live.existingChecker(),
            live.sequencerUptimeFeed(),
            live.sequencerGracePeriod(),
            BASELINE_WINDOW,
            1000,
            MIN_HARMONIC_LIQUIDITY
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                StockAccountPriceChecker.TwapDeviatesFromBaseline.selector, nvdacPool, int24(-4834), int24(-3463)
            )
        );
        tight.getExpectedOut(1e8, nvdac, USDC);
    }

    /// @notice The live checker lets the registry list ANTc in the mild window; the hardened one does not.
    function test_mildWindow_registryRefusesListingOnlyWithHardenedChecker() public {
        _forkAt(MILD_BLOCK);
        IStockAccountRegistry.TokenConfig memory cfg = IStockAccountRegistry.TokenConfig({
            status: IStockAccountRegistry.TokenStatus.Active,
            source: IStockAccountRegistry.PriceSource.PoolTwap,
            pool: ANTC_POOL,
            chainlinkFeed: address(0)
        });

        uint256 snap = vm.snapshotState();
        vm.prank(MAMO_MULTISIG);
        registry.listToken(ANTC, cfg);
        assertEq(uint8(registry.tokenConfig(ANTC).status), uint8(IStockAccountRegistry.TokenStatus.Active));
        vm.revertToState(snap);

        vm.startPrank(MAMO_MULTISIG);
        registry.setPriceChecker(ISlippagePriceChecker(address(hardened)));
        vm.expectRevert(abi.encodeWithSelector(IStockAccountRegistry.TokenNotPriceable.selector, ANTC));
        registry.listToken(ANTC, cfg);
        vm.stopPrank();
    }
}
