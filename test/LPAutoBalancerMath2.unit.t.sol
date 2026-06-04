// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {LPAutoBalancerHarness} from "./harness/LPAutoBalancerHarness.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

/// @notice Unit tests for _alignedRange / _floorAlign (Task 8) and
///         _consultTwapTick / _checkDeviation (Task 9).
contract LPAutoBalancerMath2UnitTest is Test {
    LPAutoBalancerHarness harness;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");
    address router = makeAddr("router");
    address quoter = makeAddr("quoter");
    address aero = makeAddr("aero");

    function setUp() public {
        MockPositionManager mockPM = new MockPositionManager(address(0));
        harness = new LPAutoBalancerHarness(admin, manager, rebalancer, guardian, address(mockPM), router, quoter, aero);
    }

    // ─── _alignedRange tests ─────────────────────────────────────────────────

    function test_alignedRange_centersAndAligns() public view {
        (int24 lo, int24 hi) = harness.alignedRange(0, 2000, 200, 0);
        assertEq(lo, -1000);
        assertEq(hi, 1000);
        assertEq(lo % 200, 0);
        assertEq(hi % 200, 0);
        assertTrue(lo < 0 && 0 < hi);
    }

    function test_alignedRange_negativeFloor() public view {
        (int24 lo, int24 hi) = harness.alignedRange(-150, 2000, 200, -150);
        assertEq(hi - lo, 2000);
        assertEq(lo % 200, 0);
        assertEq(hi % 200, 0);
        assertTrue(lo < -150 && -150 < hi);
    }

    function test_alignedRange_revertNoStraddle() public {
        // currentTick outside [lo,hi] must revert
        vm.expectRevert(bytes("no straddle"));
        harness.alignedRange(0, 2000, 200, 5000);
    }

    // ─── _consultTwapTick tests (Task 9) ─────────────────────────────────────

    /// @dev Positive delta: TWAP tick = 2000*60 / 60 = 2000.
    function test_consultTwapTick_positive() public {
        MockCLPool pool = new MockCLPool();
        // delta = cum[1] - cum[0] = 120000 - 0 = 120000; window = 60 → twap = 2000
        pool.setObserve(0, int56(2000) * int56(uint56(60)));
        int24 result = harness.consultTwapTick(address(pool), 60);
        assertEq(result, 2000);
    }

    /// @dev Negative delta not evenly divisible: must round toward -inf (floor).
    ///      window=60, delta=-120001. truncated = -120001/60 = -2000 (toward zero).
    ///      Since delta<0 and delta%60 = -1 != 0, result must be -2001.
    function test_consultTwapTick_negativeRoundsTowardNegInf() public {
        MockCLPool pool = new MockCLPool();
        // cum[0]=0, cum[1]=-120001 → delta = -120001
        pool.setObserve(0, -120001);
        int24 result = harness.consultTwapTick(address(pool), 60);
        assertEq(result, -2001);
    }

    // ─── _checkDeviation tests (Task 9) ──────────────────────────────────────

    /// @dev diff = |1000 - 950| = 50 <= 100: must not revert.
    function test_checkDeviation_passWithinBound() public view {
        harness.checkDeviation(1000, 950, 100); // no revert
    }

    /// @dev diff = |1000 - 800| = 200 > 100: must revert with TwapDeviation.
    function test_checkDeviation_revertBeyondBound() public {
        vm.expectRevert(LPAutoBalancer.TwapDeviation.selector);
        harness.checkDeviation(1000, 800, 100);
    }

    /// @dev Negative ticks: diff = |-1000 - (-1050)| = 50 <= 100: must not revert.
    function test_checkDeviation_negativeSpot() public view {
        harness.checkDeviation(-1000, -1050, 100); // no revert
    }

    // ─── _readFeed / _valueInUsd tests (Task 10) ─────────────────────────────

    uint256 constant T = 1_780_000_000; // sane base timestamp

    /// @dev MAMO/USD + cbBTC/USD valuation.
    ///      MAMO: 1000e18 tokens, price = 885800 (8-dec), token dec = 18
    ///        leg0 = mulDiv(1000e18, 885800, 1e18) * 1e8 / 1e8 = 885_800_000
    ///      cbBTC: 1e8 tokens, price = 6_500_000_000_000 (8-dec), token dec = 8
    ///        leg1 = mulDiv(1e8, 6_500_000_000_000, 1e8) * 1e8 / 1e8 = 6_500_000_000_000
    ///      total = 885_800_000 + 6_500_000_000_000 = 6_500_885_800_000
    function test_valueInUsd_mamoCbbtc() public {
        vm.warp(T);

        MockPriceFeed oracle0 = new MockPriceFeed(885_800, 8, T); // MAMO/USD
        MockPriceFeed oracle1 = new MockPriceFeed(6_500_000_000_000, 8, T); // cbBTC/USD

        uint256 amount0 = 1000e18; // 1000 MAMO (18-dec)
        uint256 amount1 = 1e8; // 1 cbBTC (8-dec)

        uint256 usd = harness.valueInUsd(amount0, amount1, address(oracle0), address(oracle1), 18, 8);

        // Expected: 6_500_885_800_000 (1e8-scaled USD)
        assertApproxEqAbs(usd, 6_500_885_800_000, 1e6);
    }

    /// @dev answer == 0 must revert StaleOracle.
    function test_readFeed_revertStaleAnswer_zero() public {
        vm.warp(T);
        MockPriceFeed feed = new MockPriceFeed(0, 8, T);
        vm.expectRevert(LPAutoBalancer.StaleOracle.selector);
        harness.readFeed(address(feed));
    }

    /// @dev answer == -1 (negative) must revert StaleOracle.
    function test_readFeed_revertStaleAnswer_negative() public {
        vm.warp(T);
        MockPriceFeed feed = new MockPriceFeed(-1, 8, T);
        vm.expectRevert(LPAutoBalancer.StaleOracle.selector);
        harness.readFeed(address(feed));
    }

    /// @dev updatedAt older than maxOracleDelay (26h) must revert StaleOracle.
    function test_readFeed_revertStaleTime() public {
        vm.warp(T);
        // updatedAt = T - 27 hours (exceeds 26h default)
        MockPriceFeed feed = new MockPriceFeed(1_000_000, 8, T - 27 hours);
        vm.expectRevert(LPAutoBalancer.StaleOracle.selector);
        harness.readFeed(address(feed));
    }

    /// @dev updatedAt = T - 1h (fresh within 26h window) must succeed.
    function test_readFeed_freshOk() public {
        vm.warp(T);
        int256 answer = 1_234_567;
        uint8 dec = 8;
        MockPriceFeed feed = new MockPriceFeed(answer, dec, T - 1 hours);
        (uint256 price, uint8 decimals) = harness.readFeed(address(feed));
        assertEq(price, uint256(answer));
        assertEq(decimals, dec);
    }

    /// @dev 18-decimal feed normalization: one token with 6 token decimals and
    ///      18-decimal price feed (like many on-chain aggregators).
    ///      amount = 1e6, price = 2e18 (i.e. $2 in 18-dec notation), token dec = 6.
    ///      leg = mulDiv(1e6, 2e18, 1e6) * 1e8 / 1e18
    ///          = 2e18 * 1e8 / 1e18 = 2e8 = 200_000_000 (= $2.00 in 1e8 USD)
    ///      second leg: amount1=0 so contributes 0.
    function test_valueInUsd_differentFeedDecimals() public {
        vm.warp(T);

        // 18-decimal oracle: price = 2e18 (represents $2.00)
        MockPriceFeed oracle0 = new MockPriceFeed(int256(2e18), 18, T);
        // second leg is zero (dummy oracle, not called via amount1=0 but must exist)
        MockPriceFeed oracle1 = new MockPriceFeed(int256(1e8), 8, T);

        // 1 USDC = 1e6 (6-dec token), price feed 18-dec
        uint256 usd = harness.valueInUsd(1e6, 0, address(oracle0), address(oracle1), 6, 6);

        // Expected: $2.00 in 1e8 scale = 200_000_000
        assertEq(usd, 200_000_000);
    }
}
