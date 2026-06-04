// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {LPAutoBalancerHarness} from "./harness/LPAutoBalancerHarness.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

import {LiquidityAmounts} from "@libraries/uniswap/LiquidityAmounts.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";

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
        // delta = cum[1] - cum[0] = 120000 - 0 = 120000; window = 60 -> twap = 2000
        pool.setObserve(0, int56(2000) * int56(uint56(60)));
        int24 result = harness.consultTwapTick(address(pool), 60);
        assertEq(result, 2000);
    }

    /// @dev Negative delta not evenly divisible: must round toward -inf (floor).
    ///      window=60, delta=-120001. truncated = -120001/60 = -2000 (toward zero).
    ///      Since delta<0 and delta%60 = -1 != 0, result must be -2001.
    function test_consultTwapTick_negativeRoundsTowardNegInf() public {
        MockCLPool pool = new MockCLPool();
        // cum[0]=0, cum[1]=-120001 -> delta = -120001
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

    // ─── _computeSwap tests (Task 11) ────────────────────────────────────────

    // Addresses used as token0 / token1 throughout these tests.
    address constant A = address(0xA0);
    address constant B = address(0xB0);

    /// @dev sqrtP at tick 0, symmetric range [-1000,1000], surplus token0.
    ///      With 2e18 token0 and 0 token1 the function should sell ~half token0.
    function test_computeSwap_sellsSurplusToken0() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        (bool zeroForOne, uint256 amountIn) = harness.computeSwap(sqrtP, -1000, 1000, 2e18, 0, 0, A, B, address(0));
        assertTrue(zeroForOne, "should sell token0");
        assertGt(amountIn, 0, "amountIn must be > 0");
        assertLt(amountIn, 2e18, "amountIn must be < full balance");
    }

    /// @dev sqrtP at tick 0, symmetric range [-1000,1000], surplus token1.
    function test_computeSwap_sellsSurplusToken1() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        (bool zeroForOne, uint256 amountIn) = harness.computeSwap(sqrtP, -1000, 1000, 0, 2e18, 0, A, B, address(0));
        assertFalse(zeroForOne, "should sell token1");
        assertGt(amountIn, 0, "amountIn must be > 0");
        assertLt(amountIn, 2e18, "amountIn must be < full balance");
    }

    /// @dev Balances already match the range ratio -> amountIn is near zero.
    ///      We derive the balanced amounts from getAmountsForLiquidity directly.
    function test_computeSwap_balancedNoSwap() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-1000);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(1000);
        // Use L=1e18 to get balanced amounts for the range at current price.
        (uint256 req0, uint256 req1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, 1e18);
        // Scale up to reasonable magnitudes (both req0, req1 > 0 for in-range symmetric).
        uint256 bal0 = req0 * 1e6;
        uint256 bal1 = req1 * 1e6;
        (, uint256 amountIn) = harness.computeSwap(sqrtP, -1000, 1000, bal0, bal1, 0, A, B, address(0));
        // Residual should be tiny relative to the input (within 1e-6 of bal0).
        assertLe(amountIn, bal0 / 1e6 + 1, "dust only - should be near zero");
    }

    /// @dev policy 1, protectedToken = A (token0), surplus token0 -> sell side is A -> blocked.
    function test_computeSwap_policy1_blocksSellingProtected() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        (, uint256 amountIn) = harness.computeSwap(sqrtP, -1000, 1000, 2e18, 0, 1, A, B, A);
        assertEq(amountIn, 0, "policy 1 must block selling protectedToken");
    }

    /// @dev policy 1, protectedToken = A (token0), surplus token1 -> sell side is B -> allowed.
    function test_computeSwap_policy1_allowsSellingCounter() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        (, uint256 amountIn) = harness.computeSwap(sqrtP, -1000, 1000, 0, 2e18, 1, A, B, A);
        assertGt(amountIn, 0, "policy 1 allows selling counter-asset");
    }

    /// @dev policy 2 (only sell protected), surplus token1 -> sell side is B != A -> blocked.
    function test_computeSwap_policy2_onlySellsProtected() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        // surplus token1 -> would sell B; protectedToken = A -> B != A -> amountIn=0
        (, uint256 amountIn) = harness.computeSwap(sqrtP, -1000, 1000, 0, 2e18, 2, A, B, A);
        assertEq(amountIn, 0, "policy 2 blocks selling non-protected token");
    }

    /// @dev Zero balances -> no swap.
    function test_computeSwap_zeroBalances() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        (, uint256 amountIn) = harness.computeSwap(sqrtP, -1000, 1000, 0, 0, 0, A, B, address(0));
        assertEq(amountIn, 0, "zero balances -> no swap");
    }

    /// @dev Range entirely BELOW spot ([-2000,-1000], spot tick 0).
    ///      Price is ABOVE the range so getAmountsForLiquidity returns (req0=0, req1>0).
    ///      denom = req0In1 + req1 = req1 > 0 (normal path, not denom==0 branch).
    ///      desired0In1 = total1 * 0 / req1 = 0 so sell all token0: zeroForOne=true, amountIn==bal0.
    function test_computeSwap_rangeAboveSpot() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0); // spot at tick 0
        // Range [-2000,-1000] is entirely below tick 0; price above range; wants all token1.
        uint256 bal0 = 1e18;
        (bool zeroForOne, uint256 amountIn) = harness.computeSwap(sqrtP, -2000, -1000, bal0, 0, 0, A, B, address(0));
        // Verify using LiquidityAmounts directly what the library returns.
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-2000);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(-1000);
        (uint256 req0, uint256 req1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, 1e18);
        // price above range: req0==0, req1>0; range wants all token1; should sell token0.
        assertEq(req0, 0, "sanity: price above range means req0==0");
        assertGt(req1, 0, "sanity: price above range means req1>0");
        assertTrue(zeroForOne, "should sell token0 (convert to token1 for range below spot)");
        assertEq(amountIn, bal0, "should sell entire token0 balance");
    }

    // ─── Fix B: new tests locking the safety invariant and denom==0 branch ─────

    /// @dev Fuzz: amountIn must never exceed the balance of the token being sold.
    ///      Range [-1000,1000] at sqrtP for tick 0 — always in-range (denom > 0 path).
    function testFuzz_computeSwap_amountInNeverExceedsBalance(uint128 bal0, uint128 bal1) public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        (bool zeroForOne, uint256 amountIn) =
            harness.computeSwap(sqrtP, -1000, 1000, uint256(bal0), uint256(bal1), 0, A, B, address(0));
        if (zeroForOne) {
            assertLe(amountIn, uint256(bal0), "amountIn must not exceed bal0 when selling token0");
        } else {
            assertLe(amountIn, uint256(bal1), "amountIn must not exceed bal1 when selling token1");
        }
    }

    /// @dev denom==0 branch: 1-tick-wide range near MAX_TICK forces sqrtP (tick 0) to be
    ///      entirely below the range, so getAmountsForLiquidity returns (req0>0, req1==0).
    ///      That means "range wants all token0 => sell token1" (zeroForOne=false).
    ///
    ///      Policy tests (Fix A): verify the swapPolicy guard now runs on the denom==0 path.
    ///        - policy 0  (no restriction): amountIn == bal1  (branch is hit, all token1 sold)
    ///        - policy 1  (never sell protected=B=token1): sell side IS B -> blocked -> amountIn==0
    ///        - policy 2  (only sell protected=A=token0):  sell side is B != A -> blocked -> amountIn==0
    function test_computeSwap_denom0_respectsPolicy() public view {
        // 1-tick range near MAX_TICK; sqrtP is at tick 0, far below this range.
        // getAmountsForLiquidity will return (req0 > 0, req1 == 0) -> denom == 0 branch.
        int24 tl = 887270;
        int24 tu = 887272; // MAX_TICK
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);

        // Sanity: verify we actually hit denom==0 by checking policy-0 returns nonzero amountIn.
        uint256 bal1 = 5e18;
        (, uint256 amountInPolicy0) = harness.computeSwap(sqrtP, tl, tu, 0, bal1, 0, A, B, address(0));
        assertEq(amountInPolicy0, bal1, "sanity: policy-0 denom==0 path must sell all bal1");

        // policy 1: protectedToken = B (token1). Sell side for denom==0 here is token1 (B) -> blocked.
        (, uint256 amountInP1) = harness.computeSwap(sqrtP, tl, tu, 0, bal1, 1, A, B, B);
        assertEq(amountInP1, 0, "policy 1 must block selling protectedToken on denom==0 path");

        // policy 2: protectedToken = A (token0). Sell side is token1 (B) != A -> blocked.
        (, uint256 amountInP2) = harness.computeSwap(sqrtP, tl, tu, 0, bal1, 2, A, B, A);
        assertEq(amountInP2, 0, "policy 2 must block selling non-protected token on denom==0 path");
    }

    /// @dev denom==0 branch behavior: documents that the full token1 balance is offered for
    ///      sale (policy 0) when the range is a tiny 2-tick window near MAX_TICK.
    ///      With sqrtP at tick 0, getAmountsForLiquidity returns (req0==0, req1==0) for that
    ///      extreme range (both round to zero at L=1e18), so denom==0. Since req1==0 the
    ///      first arm fires: zeroForOne=false, amountIn=bal1.
    ///
    ///      This test also verifies the boundary sub-cases:
    ///        - bal1==0  -> amountIn==0 (nothing to sell)
    ///        - bal1>0   -> amountIn==bal1 (sell all token1)
    ///        - bal0>0, bal1==0 -> amountIn==0 (direction is sell-token1 but there is none)
    function test_computeSwap_denom0_policy0_sellsAll() public view {
        int24 tlMax = 887270;
        int24 tuMax = 887272; // MAX_TICK
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);

        // Confirm this range truly yields denom==0 (both req0 and req1 round to 0 at L=1e18).
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tlMax);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tuMax);
        (uint256 req0check, uint256 req1check) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, 1e18);
        assertEq(req0check, 0, "sanity: both amounts zero -> denom==0 branch");
        assertEq(req1check, 0, "sanity: both amounts zero -> denom==0 branch");

        // Sub-case 1: no token1 to sell -> amountIn==0.
        (, uint256 amountIn0) = harness.computeSwap(sqrtP, tlMax, tuMax, 0, 0, 0, A, B, address(0));
        assertEq(amountIn0, 0, "no balance to sell gives amountIn==0");

        // Sub-case 2: bal1 > 0 -> direction=sell token1, amountIn==bal1 (sell all).
        uint256 bal1 = 7e18;
        (bool zeroForOneB, uint256 amountInB) = harness.computeSwap(sqrtP, tlMax, tuMax, 0, bal1, 0, A, B, address(0));
        assertFalse(zeroForOneB, "denom==0 req1==0 arm: zeroForOne must be false (sell token1)");
        assertEq(amountInB, bal1, "amountIn must equal full bal1 for denom==0 sell-all path");

        // Sub-case 3: bal0 > 0 only; range still signals sell-token1 but bal1==0 -> amountIn==0.
        uint256 bal0 = 3e18;
        (bool zeroForOneC, uint256 amountInC) = harness.computeSwap(sqrtP, tlMax, tuMax, bal0, 0, 0, A, B, address(0));
        assertFalse(zeroForOneC, "direction is still sell-token1 even when bal1==0");
        assertEq(amountInC, 0, "amountIn==0 when bal1==0 on the denom==0 sell-token1 path");
    }
}
