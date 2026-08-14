// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroValuation} from "@contracts/leveraged-aero/LeveragedAeroValuation.sol";
import {LiquidityAmounts} from "@contracts/leveraged-aero/sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {MockCLPool} from "../mocks/MockCLPool.sol";

import {Test} from "@forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ASSET-MODE deploy-sizing unit tests (`LeveragedAeroValuation.assetModeSplit`)
 * @notice The only genuinely NEW math in the asset-as-a-leg shape. Given a USDC `amount`, the split
 *         must produce a collateral portion `C` and an LP-side portion `U` such that the SINGLE leg-A
 *         amount borrowed against `C` at `targetLtvBps` pairs with `U` at exactly the ratio the target
 *         range needs at the current tick.
 *
 *         Every test asserts the three properties that define correctness:
 *           1. CONSERVATION      — `C + U == amount` (nothing invented, nothing dropped).
 *           2. BORROW FIDELITY   — the returned borrow is exactly `C × targetLtv` converted at the
 *                                 Chainlink price, i.e. post-op LTV lands on target.
 *           3. BALANCED AT TICK  — feeding `(U, A)` to the SAME `LiquidityAmounts` the production mint
 *                                 uses consumes (essentially) ALL of both sides. An unbalanced split
 *                                 would leave one side largely unconsumed; that is the property the
 *                                 closed form exists to guarantee.
 *
 * @dev No venue mocks beyond a settable-price CL pool: the split is a `view` over `(sqrtP, range,
 *      amount, ltv, decimals, ordering, price)`. Pool `sqrtP` and the Chainlink leg-A price are kept
 *      MUTUALLY CONSISTENT by DERIVING the price from `sqrtP` (`_legAPriceFromPool`), so property 3 is
 *      a clean statement about the sizing rather than about an oracle/pool divergence.
 *
 *      Fixture: leg A is an 8dp volatile token (cbBTC-shaped), the asset is 6dp USDC, USDC/USD = 1e8.
 */
contract LeveragedAeroAssetModeSizingUnitTest is Test {
    MockCLPool internal pool;

    /// @dev Leg-A decimals for the fixture (cbBTC-shaped).
    uint8 internal constant LEG_A_DECIMALS = 8;
    /// @dev USDC/USD, 8dp — a perfect peg, so `_tokenToUsdc(x, 6, pUsdc, pUsdc) == x`.
    uint256 internal constant P_USDC = 1e8;
    uint256 internal constant Q96 = 1 << 96;

    int24 internal constant SPACING = 100;
    /// @dev ~$100k/BTC for an 8dp/6dp pair sits near this tick; any in-domain tick works.
    int24 internal constant TICK = 69_000;

    /// @dev $1M — large enough that 6dp integer rounding is negligible against the tolerances below.
    uint256 internal constant AMOUNT = 1_000_000e6;

    function setUp() public {
        pool = new MockCLPool(address(0xA11), address(0xB22), SPACING);
    }

    // ==================== HELPERS ====================

    /// @dev Put the pool at `tick` with a `sqrtP` that matches it exactly.
    function _setPoolTick(int24 tick) internal returns (uint160 sqrtP) {
        sqrtP = TickMath.getSqrtRatioAtTick(tick);
        pool.setSqrtPriceX96(sqrtP);
        pool.setTick(tick);
    }

    /**
     * @dev The Chainlink leg-A price (8dp) IMPLIED by the pool's `sqrtP`, i.e. the inverse of
     *      `LeveragedAeroValuation.oracleSqrtPriceX96`. Deriving it (rather than picking a round
     *      number) makes oracle and pool agree to the wei, so a "balanced at tick" assertion is a
     *      statement about the split and not about a price divergence.
     *
     *      With `raw = (sqrtP / 2^96)^2` the smallest-unit token1/token0 price and
     *      `raw = p0·10^d1 / (p1·10^d0)`:
     *        - leg A is token0 (asset is token1, 6dp): `pA = raw · 1e8 · 10^dA / 1e6 = raw · 100 · 10^dA`
     *        - leg A is token1 (asset is token0, 6dp): `pA = 1e8 · 10^dA / (raw · 1e6) = 100 · 10^dA / raw`
     */
    function _legAPriceFromPool(uint160 sqrtP, bool legAIsToken0) internal pure returns (uint256) {
        uint256 rawQ96 = Math.mulDiv(sqrtP, sqrtP, Q96); // raw · 2^96
        uint256 scaled = 100 * (10 ** uint256(LEG_A_DECIMALS));
        return legAIsToken0 ? Math.mulDiv(rawQ96, scaled, Q96) : Math.mulDiv(scaled, Q96, rawQ96);
    }

    /// @dev USDC face (6dp) value of `legAAmt` at `pA`, on the manager's `_tokenToUsdc` basis.
    function _legAValueUsdc(uint256 legAAmt, uint256 pA) internal pure returns (uint256) {
        return (legAAmt * pA * 1e6) / ((10 ** uint256(LEG_A_DECIMALS)) * P_USDC);
    }

    /**
     * @dev "This side of the pair was (essentially) fully consumed": `got` within 0.1% of `want`, or
     *      within 2 RAW UNITS, whichever is looser — i.e. at least 99.9% of the intended side went in.
     *
     *      Neither bound is slack; both are resolution limits. The pair is two integer unit counts, and
     *      `getLiquidityForAmounts` takes the MIN over the two sides, so ONE unit of truncation in the
     *      binding side leaves the OTHER side short by that unit's worth of value. In this fixture a
     *      single leg-A unit is ~$0.001 (8dp token at ~$100k), which against the smallest LP sides in
     *      the fuzz envelope is ~1e-4 relative. No formulation of the split can do better.
     *
     *      What the assertion still pins razor-sharp is the only failure that matters: a MIS-SIZED pair
     *      leaves one side unconsumed by a large FRACTION — tens of percent, not fractions of a bp —
     *      which 0.1% catches immediately. (Deleting the closed form and splitting 50/50 by value, for
     *      instance, fails this by ~25% on the asymmetric ranges above.)
     */
    function _assertConsumed(uint256 got, uint256 want, string memory what) internal pure {
        uint256 diff = got > want ? got - want : want - got;
        uint256 allowed = want / 1000;
        if (allowed < 2) allowed = 2;
        assertLe(diff, allowed, what);
    }

    /**
     * @dev Run the split for `amount` over `[tickLower, tickUpper]` at the pool's current price and
     *      assert all three correctness properties. Returns `(C, U, A)` for further per-test checks.
     */
    function _splitAndAssert(uint256 amount, int24 tickLower, int24 tickUpper, uint16 ltvBps, bool legAIsToken0)
        internal
        view
        returns (uint256 c, uint256 u, uint256 a)
    {
        uint160 sqrtP = pool.sqrtPriceX96();
        uint256 pA = _legAPriceFromPool(sqrtP, legAIsToken0);

        (c, u, a) = LeveragedAeroValuation.assetModeSplit(
            address(pool), tickLower, tickUpper, amount, uint256(ltvBps), LEG_A_DECIMALS, legAIsToken0, pA
        );

        // 1. CONSERVATION.
        assertEq(c + u, amount, "C + U must equal the deposited amount exactly");
        assertGt(c, 0, "collateral portion must be nonzero");
        assertGt(u, 0, "LP-side USDC portion must be nonzero");

        // 2. BORROW FIDELITY — the borrow is worth C x targetLtv, so post-op LTV lands on target.
        //    Tolerance is 0.1% relative, and that floor is PHYSICAL, not slack: the borrow is an integer
        //    count of leg-A units, and one unit of an 8dp token worth ~$100k is already ~$0.001, which
        //    against the smallest borrows in the fuzz envelope is ~1e-4 relative. No formulation can
        //    avoid it. The bps restatement below is re-derived by integer division here, which alone can
        //    shed a whole bps, so it gets an ABSOLUTE 1-bps tolerance.
        assertApproxEqRel(_legAValueUsdc(a, pA), (c * ltvBps) / 10_000, 1e15, "borrow value must equal C x targetLtv");
        assertApproxEqAbs(
            (_legAValueUsdc(a, pA) * 10_000) / c, uint256(ltvBps), 1, "resulting LTV must equal target (+/-1bps)"
        );

        // 3. BALANCED AT TICK — the production mint path's own math must consume essentially all of
        //    BOTH sides. `getLiquidityForAmounts` takes the MIN over the two sides, so a mis-sized pair
        //    shows up as one side's `exp` falling well short of its `desired`.
        (uint256 amt0, uint256 amt1) = legAIsToken0 ? (a, u) : (u, a);
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, amt0, amt1);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, liquidity);
        _assertConsumed(exp0, amt0, "token0 side must be (essentially) fully consumed");
        _assertConsumed(exp1, amt1, "token1 side must be (essentially) fully consumed");
    }

    // ==================== TICK IN RANGE (the operating case) ====================

    function testSplitBalancesInRangeLegAIsToken1() public {
        _setPoolTick(TICK);
        _splitAndAssert(AMOUNT, TICK - 2000, TICK + 2000, 5000, false);
    }

    function testSplitBalancesInRangeLegAIsToken0() public {
        _setPoolTick(TICK);
        _splitAndAssert(AMOUNT, TICK - 2000, TICK + 2000, 5000, true);
    }

    /// @dev A range's shape drives the split: a range whose upper half is much wider needs relatively
    ///      more of one token, so `C` must move. Both orderings, several widths and offsets.
    function testSplitBalancesAcrossRangeShapes() public {
        _setPoolTick(TICK);
        int24[4] memory lowerOffsets = [int24(-200), -2000, -20_000, -1000];
        int24[4] memory upperOffsets = [int24(20_000), 2000, 200, 30_000];
        for (uint256 i; i < 4; ++i) {
            _splitAndAssert(AMOUNT, TICK + lowerOffsets[i], TICK + upperOffsets[i], 5000, false);
            _splitAndAssert(AMOUNT, TICK + lowerOffsets[i], TICK + upperOffsets[i], 5000, true);
        }
    }

    /// @dev The LTV target is a free parameter of the split: a higher target borrows more against less
    ///      collateral, so `C` must FALL monotonically as the target rises (the same LP pair is funded
    ///      by a larger borrow off a smaller collateral base).
    function testSplitCollateralFallsAsTargetLtvRises() public {
        _setPoolTick(TICK);
        uint16[4] memory ltvs = [uint16(1000), 2500, 5000, 6500];
        uint256 prevC = type(uint256).max;
        for (uint256 i; i < 4; ++i) {
            (uint256 c,,) = _splitAndAssert(AMOUNT, TICK - 2000, TICK + 2000, ltvs[i], false);
            assertLt(c, prevC, "collateral portion must fall as the LTV target rises");
            prevC = c;
        }
    }

    /// @dev Worked example from the derivation docstring: at a range whose required amounts are 50/50 BY
    ///      VALUE and `targetLtvBps == 5000`, the split must be C = 2/3, U = 1/3 of the deposit. A
    ///      symmetric-in-sqrt-price range centred on the tick is that 50/50 case.
    function testSplitMatchesTheWorkedExampleAtFiftyFiftyByValue() public {
        uint160 sqrtP = _setPoolTick(TICK);
        // Pick bounds symmetric in sqrt-price around sqrtP so the two required amounts are equal in
        // value; assert that first, then assert the 2/3 : 1/3 split the docstring predicts.
        int24 lower = TICK - 2000;
        int24 upper = TICK + 2000;
        uint256 pA = _legAPriceFromPool(sqrtP, false);
        (uint256 c, uint256 u, uint256 a) = _splitAndAssert(AMOUNT, lower, upper, 5000, false);

        uint256 legAValue = _legAValueUsdc(a, pA);
        assertApproxEqRel(legAValue, u, 3e16, "fixture range is ~50/50 by value (within 3%)");
        assertApproxEqRel(c, (AMOUNT * 2) / 3, 3e16, "C ~ 2/3 of the deposit");
        assertApproxEqRel(u, AMOUNT / 3, 3e16, "U ~ 1/3 of the deposit");
    }

    /**
     * @dev NEGATIVE CONTROL — proof the BALANCED-AT-TICK assertion has teeth rather than passing on
     *      tolerance. On an asymmetric range, the two-borrowed-legs rule (split 50/50 BY VALUE) is the
     *      most plausible wrong answer for asset-mode. Fed to the same geometry it must leave one side
     *      of the pair massively unconsumed — here by tens of percent, against a 0.1% tolerance.
     */
    function testNaiveFiftyFiftyByValueSplitFailsTheBalanceCheck() public {
        uint160 sqrtP = _setPoolTick(TICK);
        int24 lower = TICK - 200; // tick sits near the LOWER bound ⇒ the range wants almost all token0
        int24 upper = TICK + 40_000;
        uint256 pA = _legAPriceFromPool(sqrtP, false);

        // The closed form balances here (asserted inside).
        (, uint256 u, uint256 a) = _splitAndAssert(AMOUNT, lower, upper, 5000, false);

        // Now the naive alternative: same total value, but half in each side.
        uint256 halfValue = (u + _legAValueUsdc(a, pA)) / 2;
        uint256 naiveU = halfValue;
        uint256 naiveA = (halfValue * 100 * (10 ** uint256(LEG_A_DECIMALS))) / pA;

        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(upper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, naiveU, naiveA);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, liq);

        // At least one side is short by >10% — two orders of magnitude past the tolerance.
        bool side0Short = exp0 * 10 < naiveU * 9;
        bool side1Short = exp1 * 10 < naiveA * 9;
        assertTrue(side0Short || side1Short, "a 50/50-by-value split must strand a side (assertion has teeth)");
    }

    // ==================== TICK OUT OF RANGE (degenerate, fail-closed) ====================

    /// @dev Tick BELOW the range: the range needs only token0, so one required amount is 0 and the
    ///      ratio degenerates. Fail closed rather than open an unhedged or unlevered leg.
    function testSplitRevertsWhenTickIsBelowRange() public {
        _setPoolTick(TICK);
        for (uint256 i; i < 2; ++i) {
            bool legAIsToken0 = i == 1;
            uint256 pA = _legAPriceFromPool(pool.sqrtPriceX96(), legAIsToken0);
            vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
            LeveragedAeroValuation.assetModeSplit(
                address(pool), TICK + 1000, TICK + 5000, AMOUNT, 5000, LEG_A_DECIMALS, legAIsToken0, pA
            );
        }
    }

    /// @dev Tick ABOVE the range: mirror image — only token1 is required.
    function testSplitRevertsWhenTickIsAboveRange() public {
        _setPoolTick(TICK);
        for (uint256 i; i < 2; ++i) {
            bool legAIsToken0 = i == 1;
            uint256 pA = _legAPriceFromPool(pool.sqrtPriceX96(), legAIsToken0);
            vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
            LeveragedAeroValuation.assetModeSplit(
                address(pool), TICK - 5000, TICK - 1000, AMOUNT, 5000, LEG_A_DECIMALS, legAIsToken0, pA
            );
        }
    }

    /// @dev Exactly AT a bound counts as out of range (`sqrtP <= sqrtLower` / `>= sqrtUpper` in
    ///      `getAmountsForLiquidity`), so the boundary is fail-closed too — no off-by-one window where
    ///      a one-sided range slips through as "in range".
    function testSplitRevertsWhenTickSitsExactlyOnABound() public {
        _setPoolTick(TICK);
        uint256 pA = _legAPriceFromPool(pool.sqrtPriceX96(), false);

        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        LeveragedAeroValuation.assetModeSplit(address(pool), TICK, TICK + 5000, AMOUNT, 5000, LEG_A_DECIMALS, false, pA);

        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        LeveragedAeroValuation.assetModeSplit(address(pool), TICK - 5000, TICK, AMOUNT, 5000, LEG_A_DECIMALS, false, pA);
    }

    // ==================== DEGENERATE SOLVED SPLIT ====================

    /// @dev `C` rounding to 0 (dust `amount`) must fail closed: supplying no collateral and borrowing
    ///      nothing is not the intended position, and `U == amount` would silently be an unlevered
    ///      USDC-only add.
    function testSplitRevertsWhenSolvedCollateralRoundsToZero() public {
        _setPoolTick(TICK);
        uint256 pA = _legAPriceFromPool(pool.sqrtPriceX96(), false);
        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        LeveragedAeroValuation.assetModeSplit(
            address(pool), TICK - 2000, TICK + 2000, 1, 5000, LEG_A_DECIMALS, false, pA
        );
    }

    /// @dev A zero LTV target makes the borrow term vanish, so the solve returns `C == amount` with no
    ///      USDC left to pair — the other degenerate edge. (`targetLtvBps == 0` is a legal init value,
    ///      so this edge is reachable by config, not just by arithmetic.)
    function testSplitRevertsWhenTargetLtvIsZero() public {
        _setPoolTick(TICK);
        uint256 pA = _legAPriceFromPool(pool.sqrtPriceX96(), false);
        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        LeveragedAeroValuation.assetModeSplit(
            address(pool), TICK - 2000, TICK + 2000, AMOUNT, 0, LEG_A_DECIMALS, false, pA
        );
    }

    // ==================== LEG DECIMALS / PRICE ROBUSTNESS ====================

    /// @dev Leg-A decimals and price are inputs, not assumptions: the split must balance across the
    ///      whole init-permitted decimals band [2, 18] at a price derived for each.
    function testSplitBalancesAcrossLegDecimals() public {
        uint160 sqrtP = _setPoolTick(TICK);
        uint8[4] memory decs = [uint8(2), 6, 8, 18];
        for (uint256 i; i < decs.length; ++i) {
            uint8 dA = decs[i];
            // Re-derive the implied price for THIS decimals choice (leg A as token1).
            uint256 rawQ96 = Math.mulDiv(sqrtP, sqrtP, Q96);
            uint256 pA = Math.mulDiv(100 * (10 ** uint256(dA)), Q96, rawQ96);
            if (pA == 0) continue; // unrepresentable price at this decimals/tick pair — not a real config

            (uint256 c, uint256 u, uint256 a) = LeveragedAeroValuation.assetModeSplit(
                address(pool), TICK - 2000, TICK + 2000, AMOUNT, 5000, dA, false, pA
            );
            assertEq(c + u, AMOUNT, "conservation holds at every leg-decimals");

            uint160 sqrtLower = TickMath.getSqrtRatioAtTick(TICK - 2000);
            uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(TICK + 2000);
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, u, a);
            (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, liq);
            _assertConsumed(exp0, u, "USDC side consumed");
            _assertConsumed(exp1, a, "leg-A side consumed");
        }
    }

    /// @dev Fuzz the operating envelope: any in-range tick offset, range width, deposit size and LTV
    ///      target must conserve and balance. Bounds stay inside what init permits.
    function testFuzzSplitConservesAndBalances(
        uint256 amount,
        int24 lowerOff,
        int24 upperOff,
        uint16 ltvBps,
        bool legAIsToken0
    ) public {
        amount = bound(amount, 1_000e6, 100_000_000e6);
        lowerOff = int24(int256(bound(int256(lowerOff), 200, 60_000)));
        upperOff = int24(int256(bound(int256(upperOff), 200, 60_000)));
        ltvBps = uint16(bound(uint256(ltvBps), 100, 8000));

        _setPoolTick(TICK);
        _splitAndAssert(amount, TICK - lowerOff, TICK + upperOff, ltvBps, legAIsToken0);
    }

    // ==================== RANGE GEOMETRY (why genesis is always two-sided) ====================

    /**
     * @dev `skewedTickRange` must STRICTLY BRACKET the current tick at the CENTRED skew for every width
     *      init permits (`width >= 2 x tickSpacing`). This is load-bearing for asset-mode: it is what
     *      guarantees a FRESH range is never one-sided, so `executeImpl` can always size. Only a STORED
     *      range the price has since left can degenerate — hence `deployIdle`'s documented
     *      `rerange`-first remedy. (The skewed generalisation is the fuzz two tests below.)
     */
    function testFuzzCenteredRangeStrictlyBracketsTheTick(int24 tick, uint24 width) public {
        tick = int24(int256(bound(int256(tick), -600_000, 600_000)));
        width = uint24(bound(uint256(width), 2, 4000)) * uint24(SPACING);
        _setPoolTick(int24(tick / SPACING * SPACING)); // an on-grid tick, as a real pool reports

        (int24 lower, int24 upper) = LeveragedAeroValuation.skewedTickRange(address(pool), SPACING, width, 5000);
        int24 current = pool.tick();
        assertLe(lower, current, "lower bound must not sit above the current tick");
        assertGt(upper, current, "upper bound must sit strictly above the current tick");
        assertEq(lower % SPACING, 0, "lower bound on the spacing grid");
        assertEq(upper % SPACING, 0, "upper bound on the spacing grid");
    }

    // ==================== RANGE GEOMETRY: THE SKEW ====================

    /// @dev `LeveragedAeroValuation._alignTick`, restated so the equalities below compare against an
    ///      INDEPENDENT expression rather than against the code under test.
    function _alignDown(int24 tick) internal pure returns (int24) {
        int24 rem = tick % SPACING;
        if (rem < 0) rem += SPACING;
        return tick - rem;
    }

    /**
     * @dev SKEW 5000 IS THE OLD CENTRED FORMULA, BIT FOR BIT — the compatibility pin for every live
     *      clone and every existing test fixture. The pre-skew math was `span = width / 2` each side; the
     *      skewed form computes `lowerSpan = width x 5000 / 1e4` and `upperSpan = width - lowerSpan`,
     *      which coincide exactly whenever `width` is even (and every width on an even spacing grid is).
     *      Asserted against the OLD expression verbatim, at on- AND off-grid ticks and both signs, so it
     *      is a real regression pin and not a restatement of the new code.
     */
    function testSkewedRangeReproducesCenteredAtHalf() public {
        uint24[4] memory widths = [uint24(200), 1000, 4000, 40_000];
        int24[4] memory ticks = [int24(0), TICK, TICK + 37, -TICK - 37]; // two of them deliberately off-grid
        for (uint256 t; t < ticks.length; ++t) {
            int24 current = ticks[t];
            _setPoolTick(current);
            for (uint256 i; i < widths.length; ++i) {
                (int24 lower, int24 upper) =
                    LeveragedAeroValuation.skewedTickRange(address(pool), SPACING, widths[i], 5000);
                int24 span = int24(widths[i] / 2); // the pre-skew expression, verbatim
                assertEq(lower, _alignDown(current - span), "lower == the OLD centred lower bound");
                assertEq(upper, _alignDown(current + span), "upper == the OLD centred upper bound");
            }
        }
    }

    /**
     * @dev THE GENERALISED BRACKETING INVARIANT. Over the whole `_checkSkew`-LEGAL set — any in-domain
     *      tick, any aligned width in the init band, and any skew whose two spans each reach at least one
     *      `tickSpacing` — the range must still strictly bracket the tick, sit on the grid, and measure
     *      `width` to within one spacing. This is what licenses the skew at all: `assetModeSplit` can only
     *      size a range that brackets the price, so if ANY legal skew produced a one-sided range the
     *      feature would brick the deploy path.
     *
     *      The legal skew floor is derived, not guessed: `lowerSpan >= spacing` means
     *      `skew >= ceil(spacing x 1e4 / width)`, and the same bound mirrored from the top caps the upper
     *      side (`upperSpan = width - lowerSpan >= spacing` follows algebraically).
     */
    function testFuzzSkewedRangeStrictlyBracketsTheTick(int24 tick, uint24 width, uint16 skewBps) public {
        tick = int24(int256(bound(int256(tick), -600_000, 600_000)));
        width = uint24(bound(uint256(width), 2, 4000)) * uint24(SPACING);
        uint256 spacing = uint256(uint24(SPACING));
        uint256 minSkew = (spacing * 10_000 + uint256(width) - 1) / uint256(width); // ceil
        skewBps = uint16(bound(uint256(skewBps), minSkew, 10_000 - minSkew));

        _setPoolTick(int24(tick / SPACING * SPACING)); // an on-grid tick, as a real pool reports
        int24 current = pool.tick();

        (int24 lower, int24 upper) = LeveragedAeroValuation.skewedTickRange(address(pool), SPACING, width, skewBps);

        int24 maxAligned = (TickMath.MAX_TICK / SPACING) * SPACING;
        assertLe(lower, current, "lower bound must not sit above the current tick");
        assertGt(upper, current, "upper bound must sit STRICTLY above the current tick");
        assertEq(lower % SPACING, 0, "lower bound on the spacing grid");
        assertEq(upper % SPACING, 0, "upper bound on the spacing grid");
        assertGe(lower, -maxAligned, "lower bound stays inside the aligned tick domain");
        assertLe(upper, maxAligned, "upper bound stays inside the aligned tick domain");

        // The realised width claim holds only when NEITHER domain clamp fired: a clamped range is
        // deliberately TRUNCATED (that is the clamp's whole job), so measuring it against `width` would
        // be asserting the opposite of the intended behaviour. Reconstruct the pre-clamp bounds from the
        // same align-down rule to tell the two cases apart — the clamped ones are covered by
        // `testSkewedRangeClampsAtTickDomainEdges`, which asserts they stay mintable.
        uint256 lowerSpan = (uint256(width) * uint256(skewBps)) / 10_000;
        int24 nominalLower = _alignDown(int24(int256(current) - int256(lowerSpan)));
        int24 nominalUpper = _alignDown(int24(int256(current) + int256(uint256(width) - lowerSpan)));
        if (nominalLower >= -maxAligned && nominalUpper <= maxAligned) {
            // Each bound aligns DOWN independently, so the realised width can differ from `width` by at
            // most the two alignment remainders' difference — strictly less than one spacing.
            assertApproxEqAbs(
                uint256(int256(upper - lower)), uint256(width), spacing, "realised span == width (+/- one spacing)"
            );
        } else {
            assertLt(
                uint256(int256(upper - lower)), uint256(width) + spacing, "a clamped range is never WIDER than asked"
            );
        }
    }

    /**
     * @dev THE SEMANTIC CLAIM: `skewBps` really is the fraction of the width placed BELOW the tick.
     *      Asserted at a large width, where the one-spacing alignment drift is 0.025% of the span, and
     *      stated first as an ABSOLUTE tick tolerance of one spacing (not a loose ratio) so it cannot
     *      pass on slack — then restated as the ratio a rebalancer actually reasons about.
     */
    function testSkewedRangeSpanRatioMatchesSkew() public {
        uint24 width = 400_000; // 4000 spacings
        _setPoolTick(TICK);
        int24 current = pool.tick();
        uint256 spacing = uint256(uint24(SPACING));
        uint16[5] memory skews = [uint16(1000), 2500, 5000, 7500, 9000];

        for (uint256 i; i < skews.length; ++i) {
            (int24 lower, int24 upper) = LeveragedAeroValuation.skewedTickRange(address(pool), SPACING, width, skews[i]);
            uint256 below = uint256(int256(current - lower));
            uint256 total = uint256(int256(upper - lower));

            assertApproxEqAbs(
                below, (uint256(width) * uint256(skews[i])) / 10_000, spacing, "below-span == skew x width"
            );
            assertApproxEqAbs(total, uint256(width), spacing, "total span == width");
            assertApproxEqRel(
                (below * 10_000) / total, uint256(skews[i]), 1e15, "realised fraction below spot == skewBps"
            );
        }
    }

    /**
     * @dev THE DOMAIN EDGES, which the skew makes reachable in a way centring never did: at the extreme
     *      legal skews essentially the WHOLE width lands on ONE side of the tick, so a bound near
     *      ±MAX_TICK leaves the tick domain outright. The `±_alignTick(MAX_TICK)` clamps must leave both
     *      bounds ON the spacing grid, inside the domain and strictly ordered — i.e. MINTABLE, not merely
     *      non-panicking. `getSqrtRatioAtTick` is called on both as the proof (it reverts out of domain,
     *      which is the unhelpful deep-in-TickMath failure the clamps exist to prevent).
     */
    function testSkewedRangeClampsAtTickDomainEdges() public {
        int24 maxAligned = (TickMath.MAX_TICK / SPACING) * SPACING;
        uint24 width = 1_774_400; // ~2 x MAX_TICK: the init ceiling on `maxWidth`, aligned to SPACING
        int24[2] memory ticks = [maxAligned, -maxAligned];
        uint16[2] memory skews = [uint16(1), 9999]; // the extreme legal skews at this width

        for (uint256 t; t < ticks.length; ++t) {
            _setPoolTick(ticks[t]);
            for (uint256 i; i < skews.length; ++i) {
                (int24 lower, int24 upper) =
                    LeveragedAeroValuation.skewedTickRange(address(pool), SPACING, width, skews[i]);
                assertEq(lower % SPACING, 0, "clamped lower is still on the spacing grid");
                assertEq(upper % SPACING, 0, "clamped upper is still on the spacing grid");
                assertGe(lower, -maxAligned, "lower stays inside the aligned tick domain");
                assertLe(upper, maxAligned, "upper stays inside the aligned tick domain");
                assertLt(lower, upper, "the clamped range is still non-empty");
                TickMath.getSqrtRatioAtTick(lower); // reverts if the clamp left the domain
                TickMath.getSqrtRatioAtTick(upper);
            }
        }
    }

    // ==================== LEVER-UP SIZING (`assetModeLeverUpPair`) ====================

    /**
     * @dev THE "CANNOT DRIFT" IDENTITY. `assetModeSplit` and `assetModeLeverUpPair` solve the SAME
     *      pairing relation `A / U = needA / needU` with different unknowns: the split is handed a total
     *      and solves for the split point `C`, the lever-up is handed a debt delta and solves the fixed
     *      point that accounts for the collateral its `U′` will consume.
     *
     *      THE INPUT IS THE WHOLE BOOK'S TARGET DEBT, NOT THE SPLIT'S OWN BORROW BUDGET — and that is
     *      the change "no idle USDC sits dead" makes to this identity, not a fudge to keep it passing.
     *      `deposit` now supplies every incoming USDC to Moonwell, so a book holding `AMOUNT` holds it
     *      ENTIRELY as collateral: `adjustLeverage` reads `collateral == AMOUNT`, sizes the naive delta
     *      `AMOUNT × ltv / 1e4`, and `assetModeLeverUpPair` rescales it by `1/(1 + ltv·m)` because the
     *      pairing USDC has to be redeemed back out of that same collateral. The rescale is EXACTLY the
     *      split's `w/(w+x)`, so the corrected `(A, U′)` equals the split's `(A, U)` to the same
     *      tolerances as before. What this now asserts is the operator-visible statement:
     *      **deposit → `adjustLeverage` lands the identical book to deposit → `deployIdle`.**
     *      Asserted across both orderings and several range shapes.
     *
     *      BOTH sides now match only to a RELATIVE tolerance. `A` used to match to the wei because the
     *      lever-up applied `_legABorrow` and stopped; it now applies one further `mulDiv` rescale, and
     *      that floor is exactly the split's `mulDiv(amount, w, w+x)` reached from the other direction —
     *      algebraically identical, but the two orders of truncation differ in the last unit (measured:
     *      220/3.3e14 = 6.7e-13 relative). `U` matched relatively before and for the same reason: the
     *      floor is physical, not slack. The split derives `U` by
     *      SUBTRACTION from an exact-arithmetic `C` (`amount − C`), whereas the lever-up derives it by
     *      MULTIPLICATION off two already-FLOORED integers — `borrowUsd6 = floor(C·ltv/1e4)` and
     *      `A = floor(borrowUsd6·100·10^dA/pA)`. Each lost unit is magnified into `U′` by its own scale
     *      factor (`U/borrowUsd6` and `needU/needA` respectively), so the error is
     *      `O(1/borrowUsd6 + 1/A)` RELATIVE — ~1e-8 at the sizes here, and it shrinks with position size.
     *      1e-6 is two orders above the worst observed case (measured: 933/3.3e11 = 2.8e-9 for the
     *      expensive-leg ordering, 15/9.7e11 = 1.5e-11 for the cheap-leg one) and still orders of
     *      magnitude below any mis-sizing a wrong formula would produce.
     */
    function testLeverUpPairReproducesTheSplitPairAtTheSameLtv() public {
        _setPoolTick(TICK);
        int24[3] memory lowerOffsets = [int24(-2000), -200, -20_000];
        int24[3] memory upperOffsets = [int24(2000), 20_000, 200];
        uint16 ltv = 5000;

        for (uint256 i; i < 3; ++i) {
            int24 lower = TICK + lowerOffsets[i];
            int24 upper = TICK + upperOffsets[i];
            for (uint256 j; j < 2; ++j) {
                bool legAIsToken0 = j == 1;
                uint256 pA = _legAPriceFromPool(pool.sqrtPriceX96(), legAIsToken0);
                (uint256 c, uint256 u, uint256 a) = _splitAndAssert(AMOUNT, lower, upper, ltv, legAIsToken0);

                (uint256 aUp, uint256 uUp) = LeveragedAeroValuation.assetModeLeverUpPair(
                    address(pool),
                    lower,
                    upper,
                    (AMOUNT * ltv) / 10_000, // the WHOLE book's target debt (see @dev)
                    type(uint256).max, // funding bound not under test here
                    0, // no raw USDC: the deposit is entirely collateral (see @dev)
                    uint256(ltv),
                    LEG_A_DECIMALS,
                    legAIsToken0,
                    pA
                );
                assertApproxEqRel(
                    aUp, a, 1e12, "the two entrypoints must convert the borrow identically (to integer resolution)"
                );
                assertApproxEqRel(
                    uUp, u, 1e12, "the two entrypoints must pair at the same ratio (to integer resolution)"
                );
            }
        }
    }

    /// @dev The lever-up pair scales LINEARLY in the debt delta (it is a ratio, not a solve), which is
    ///      what makes "borrow ΔB, pair with U′" hedge-neutral for ANY ΔB the retarget asks for.
    function testFuzzLeverUpPairScalesLinearlyInTheDebtDelta(uint256 borrowUsd6, bool legAIsToken0) public {
        borrowUsd6 = bound(borrowUsd6, 1_000e6, 10_000_000e6);
        _setPoolTick(TICK);
        uint256 pA = _legAPriceFromPool(pool.sqrtPriceX96(), legAIsToken0);
        int24 lower = TICK - 2000;
        int24 upper = TICK + 2000;

        (uint256 a1, uint256 u1) = LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), lower, upper, borrowUsd6, type(uint256).max, 0, 5000, LEG_A_DECIMALS, legAIsToken0, pA
        );
        (uint256 a2, uint256 u2) = LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), lower, upper, borrowUsd6 * 3, type(uint256).max, 0, 5000, LEG_A_DECIMALS, legAIsToken0, pA
        );
        // Tolerance is INTEGER RESOLUTION, derived: each output passes through at most three floor
        // divisions (`a0`, the fixed-point rescale, the pairing mulDiv), so `a1`/`a2` each sit within
        // ~2 units of the real line and the ×3 comparison within ~8 — on the smallest bound-permitted
        // delta (`a1 ≈ 2e6` units) that is ~4e-6 relative. 1e13 (1e-5) covers it with 2.5× headroom;
        // the previous 1e12 sat BELOW the floor noise and flaked on fuzz seeds hitting small deltas
        // (observed: `borrowUsd6 = 1022244657` → 3 units = 1.46e-6 relative).
        assertApproxEqRel(a2, a1 * 3, 1e13, "borrow scales linearly in the delta");
        assertApproxEqRel(u2, u1 * 3, 1e13, "the pairing USDC scales linearly in the delta");

        // The pair is balanced at the tick — the same property the split has, so the LP consumes both.
        (uint256 amt0, uint256 amt1) = legAIsToken0 ? (a1, u1) : (u1, a1);
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(upper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(pool.sqrtPriceX96(), sqrtLower, sqrtUpper, amt0, amt1);
        (uint256 exp0, uint256 exp1) =
            LiquidityAmounts.getAmountsForLiquidity(pool.sqrtPriceX96(), sqrtLower, sqrtUpper, liq);
        _assertConsumed(exp0, amt0, "token0 side of the lever-up pair consumed");
        _assertConsumed(exp1, amt1, "token1 side of the lever-up pair consumed");
    }

    /// @dev The FUNDING BOUND, pinned to the wei: `U′ - 1` of idle reverts with the exact
    ///      `(needed, available)` pair, `U′` passes. No partial fill, no silent cap.
    function testLeverUpPairEnforcesTheIdleBoundToTheWei() public {
        _setPoolTick(TICK);
        uint256 pA = _legAPriceFromPool(pool.sqrtPriceX96(), false);
        int24 lower = TICK - 2000;
        int24 upper = TICK + 2000;
        uint256 delta = 250_000e6;

        (, uint256 needed) = LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), lower, upper, delta, type(uint256).max, 0, 5000, LEG_A_DECIMALS, false, pA
        );
        assertGt(needed, 0, "the pairing draw must be nonzero, or the bound is vacuous");

        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAeroValuation.InsufficientIdleForLeverUp.selector, needed, needed - 1)
        );
        LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), lower, upper, delta, needed - 1, 0, 5000, LEG_A_DECIMALS, false, pA
        );

        (, uint256 u) = LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), lower, upper, delta, needed, 0, 5000, LEG_A_DECIMALS, false, pA
        );
        assertEq(u, needed, "exactly U' of idle clears the bound");
    }

    /// @dev A one-sided range fails closed on the lever-up path too (shared `_rangeRatio`), rather than
    ///      pairing the borrow against nothing — the unhedged add the shape must never make.
    function testLeverUpPairFailsClosedOnAOneSidedRange() public {
        _setPoolTick(TICK);
        uint256 pA = _legAPriceFromPool(pool.sqrtPriceX96(), false);

        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), TICK + 2000, TICK + 6000, 250_000e6, type(uint256).max, 0, 5000, LEG_A_DECIMALS, false, pA
        );
        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), TICK - 6000, TICK - 2000, 250_000e6, type(uint256).max, 0, 5000, LEG_A_DECIMALS, false, pA
        );
    }
}
