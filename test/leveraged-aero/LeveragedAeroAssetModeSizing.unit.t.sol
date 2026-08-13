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
     * @dev `centeredTickRange` must STRICTLY BRACKET the current tick for every width init permits
     *      (`width >= 2 x tickSpacing`). This is load-bearing for asset-mode: it is what guarantees a
     *      FRESH range is never one-sided, so `executeImpl` can always size. Only a STORED range the
     *      price has since left can degenerate — hence `deployIdle`'s documented `rerange`-first
     *      remedy.
     */
    function testFuzzCenteredRangeStrictlyBracketsTheTick(int24 tick, uint24 width) public {
        tick = int24(int256(bound(int256(tick), -600_000, 600_000)));
        width = uint24(bound(uint256(width), 2, 4000)) * uint24(SPACING);
        _setPoolTick(int24(tick / SPACING * SPACING)); // an on-grid tick, as a real pool reports

        (int24 lower, int24 upper) = LeveragedAeroValuation.centeredTickRange(address(pool), SPACING, width);
        int24 current = pool.tick();
        assertLe(lower, current, "lower bound must not sit above the current tick");
        assertGt(upper, current, "upper bound must sit strictly above the current tick");
        assertEq(lower % SPACING, 0, "lower bound on the spacing grid");
        assertEq(upper % SPACING, 0, "upper bound on the spacing grid");
    }

    // ==================== LEVER-UP SIZING (`assetModeLeverUpPair`) ====================

    /**
     * @dev THE "CANNOT DRIFT" IDENTITY. `assetModeSplit` and `assetModeLeverUpPair` solve the SAME
     *      pairing relation `A / U = needA / needU` with different unknowns: the split is handed a total
     *      and solves for the split point `C`, the lever-up is handed the debt delta outright. So feeding
     *      the split's OWN borrow budget (`C × targetLtv / 1e4`) into the lever-up must reproduce the
     *      split's `(A, U)` — the algebraic statement that a lever-up to `targetLtvBps` lands the same
     *      leg ratio genesis does. Asserted across both orderings and several range shapes.
     *
     *      `A` must match TO THE WEI — both go through the same `_legABorrow`. `U` matches only to a
     *      RELATIVE tolerance, and that floor is physical, not slack: the split derives `U` by
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
                    (c * ltv) / 10_000, // the split's OWN borrow budget
                    type(uint256).max, // funding bound not under test here
                    LEG_A_DECIMALS,
                    legAIsToken0,
                    pA
                );
                assertEq(aUp, a, "the two entrypoints must convert the borrow identically (to the wei)");
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
            address(pool), lower, upper, borrowUsd6, type(uint256).max, LEG_A_DECIMALS, legAIsToken0, pA
        );
        (uint256 a2, uint256 u2) = LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), lower, upper, borrowUsd6 * 3, type(uint256).max, LEG_A_DECIMALS, legAIsToken0, pA
        );
        assertApproxEqRel(a2, a1 * 3, 1e12, "borrow scales linearly in the delta");
        assertApproxEqRel(u2, u1 * 3, 1e12, "the pairing USDC scales linearly in the delta");

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
            address(pool), lower, upper, delta, type(uint256).max, LEG_A_DECIMALS, false, pA
        );
        assertGt(needed, 0, "the pairing draw must be nonzero, or the bound is vacuous");

        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAeroValuation.InsufficientIdleForLeverUp.selector, needed, needed - 1)
        );
        LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), lower, upper, delta, needed - 1, LEG_A_DECIMALS, false, pA
        );

        (, uint256 u) = LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), lower, upper, delta, needed, LEG_A_DECIMALS, false, pA
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
            address(pool), TICK + 2000, TICK + 6000, 250_000e6, type(uint256).max, LEG_A_DECIMALS, false, pA
        );
        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool), TICK - 6000, TICK - 2000, 250_000e6, type(uint256).max, LEG_A_DECIMALS, false, pA
        );
    }
}
