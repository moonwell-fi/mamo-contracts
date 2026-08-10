// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, stdError} from "@forge-std/Test.sol";

import {MockERC20} from "./MockERC20.sol";
import {LPGeometryLib} from "@libraries/LPGeometryLib.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";

/// @dev Minimal ICLPool surface for calmGate/consultTwapTick: slot0 + observe. The observe
///      cumulatives are set directly so TWAP-tick flooring cases are exact, not simulated.
contract MiniCLPool {
    uint160 public sqrtP;
    int24 public tick;
    int56 public cum0; // cumulative at secondsAgo = window
    int56 public cum1; // cumulative at secondsAgo = 0

    function set(uint160 sqrtP_, int24 tick_, int56 cum0_, int56 cum1_) external {
        sqrtP = sqrtP_;
        tick = tick_;
        cum0 = cum0_;
        cum1 = cum1_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (sqrtP, tick, 0, 0, 0, true);
    }

    function observe(uint32[] calldata) external view returns (int56[] memory cum, uint160[] memory liq) {
        cum = new int56[](2);
        cum[0] = cum0;
        cum[1] = cum1;
        liq = new uint160[](2);
    }
}

/// @notice Standalone fuzz/unit suite for LPGeometryLib — the tick/range math previously only
///         reachable through the balancer's full position-manager mock.
contract LPGeometryLibUnitTest is Test {
    // Aerodrome/Uniswap CL tick domain (narrower than int24's full range).
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    MiniCLPool internal pool;
    address internal token0;
    address internal token1;

    function setUp() public {
        pool = new MiniCLPool();
        token0 = address(new MockERC20("Token0", "TK0"));
        token1 = address(new MockERC20("Token1", "TK1"));
    }

    // ─── floorAlign ──────────────────────────────────────────────────────────

    /// @dev Invariants: result is spacing-aligned, result <= tick, and tick - result < spacing
    ///      (i.e. it is the LARGEST aligned tick at or below `tick` — true flooring toward -inf,
    ///      including for negative unaligned ticks where naive int division truncates toward 0).
    function testFuzz_floorAlign_invariants(int24 tick, int24 spacing) public pure {
        tick = int24(bound(tick, MIN_TICK, MAX_TICK));
        spacing = int24(bound(spacing, 1, 20000));

        int24 aligned = LPGeometryLib.floorAlign(tick, spacing);

        assertEq(aligned % spacing, 0, "must be spacing-aligned");
        assertLe(aligned, tick, "must not exceed tick");
        assertLt(int256(tick) - int256(aligned), int256(spacing), "must be the largest aligned tick <= tick");
    }

    /// @dev The bug flooring protects against: -150 with spacing 200 must floor to -200, not
    ///      truncate to 0.
    function test_floorAlign_negativeUnaligned_floorsDown() public pure {
        assertEq(LPGeometryLib.floorAlign(-150, 200), -200);
        assertEq(LPGeometryLib.floorAlign(-200, 200), -200);
        assertEq(LPGeometryLib.floorAlign(-201, 200), -400);
        assertEq(LPGeometryLib.floorAlign(150, 200), 0);
    }

    // ─── alignedRange ────────────────────────────────────────────────────────

    /// @dev For any width >= 2*spacing (aligned) and reference == current, the range must strictly
    ///      straddle the current tick, be spacing-aligned on both bounds, and span exactly `width`.
    ///      This is the guarantee the balancer's balanced-main mint relies on.
    function testFuzz_alignedRange_straddlesForBalancedWidths(int24 currentTick, uint24 spacingSeed, uint24 widthMult)
        public
        pure
    {
        int24 spacing = int24(uint24(bound(spacingSeed, 1, 2000)));
        // width = k * spacing, k in [2, 40] — mirrors the config invariant minWidth >= 2*spacing.
        uint24 width = uint24(bound(widthMult, 2, 40)) * uint24(spacing);
        // keep the whole range inside the CL tick domain
        currentTick = int24(bound(currentTick, MIN_TICK + int24(width), MAX_TICK - int24(width)));

        (int24 tl, int24 tu) = LPGeometryLib.alignedRange(currentTick, width, spacing, currentTick);

        assertLt(tl, currentTick, "lower must be strictly below spot");
        assertGt(tu, currentTick, "upper must be strictly above spot");
        assertEq(tl % spacing, 0, "lower aligned");
        assertEq(tu % spacing, 0, "upper aligned");
        assertEq(int256(tu) - int256(tl), int256(uint256(width)), "span == width");
    }

    /// @dev MOO-727 follow-up. `LPAutoBalancerV2.rebuildAfterSwap`'s tick commitment names only the
    ///      MAIN bounds, yet `_mintAlt` anchors the alt on `floorAlign(spot)`. What makes the
    ///      commitment cover the alt too is that every legal width is an EVEN multiple of the
    ///      spacing: then `width/2` is a whole number of spacings, `floorAlign(spot - width/2) ==
    ///      floorAlign(spot) - width/2`, and the anchor is recoverable from the committed tickLower.
    ///      Fuzzed here so the invariant the contract now depends on is asserted, not assumed.
    function testFuzz_alignedRange_evenMultipleWidthPinsFloorAlign(
        int24 currentTick,
        uint24 spacingSeed,
        uint24 halfMult
    ) public pure {
        int24 spacing = int24(uint24(bound(spacingSeed, 1, 2000)));
        // width = 2k * spacing, k in [1, 20] — the even-multiple band validateRebalanceConfig admits.
        uint24 halfWidth = uint24(bound(halfMult, 1, 20)) * uint24(spacing);
        uint24 width = 2 * halfWidth;
        currentTick = int24(bound(currentTick, MIN_TICK + int24(width), MAX_TICK - int24(width)));

        (int24 tl,) = LPGeometryLib.alignedRange(currentTick, width, spacing, currentTick);

        assertEq(
            int256(tl) + int256(uint256(halfWidth)),
            int256(LPGeometryLib.floorAlign(currentTick, spacing)),
            "even-multiple width: alt anchor recoverable from the committed main lower bound"
        );
    }

    /// @dev The counterexample the even-multiple rule exists to exclude, at the DEPLOYED phase-1
    ///      shape (tickSpacing 100, width 300 = 3 * spacing — spacing-aligned but an ODD multiple).
    ///      Spot 150 and spot 249 produce the SAME main range, so the tick commitment cannot tell
    ///      them apart, while their alt anchors sit a full spacing apart.
    function test_alignedRange_oddMultipleWidthLeavesAltAnchorAmbiguous() public pure {
        int24 spacing = 100;

        (int24 tlA, int24 tuA) = LPGeometryLib.alignedRange(150, 300, spacing, 150);
        (int24 tlB, int24 tuB) = LPGeometryLib.alignedRange(249, 300, spacing, 249);

        assertEq(int256(tlA), int256(tlB), "odd multiple: same main lower for two distinct spots");
        assertEq(int256(tuA), int256(tuB), "odd multiple: same main upper for two distinct spots");
        assertEq(int256(LPGeometryLib.floorAlign(150, spacing)), 100, "anchor at spot 150");
        assertEq(int256(LPGeometryLib.floorAlign(249, spacing)), 200, "anchor at spot 249");
    }

    /// @dev A reference tick far from spot yields a range that cannot straddle — must revert with
    ///      the library's own require string.
    function test_alignedRange_revertsWhenNoStraddle() public {
        vm.expectRevert(bytes("no straddle"));
        LPGeometryLib.alignedRange(10_000, 400, 200, 0); // range around 10k, spot at 0
    }

    // ─── consultTwapTick ─────────────────────────────────────────────────────

    /// @dev Positive delta: plain division. window=1800, delta=3600 → tick 2.
    function test_consultTwapTick_positiveDelta() public {
        pool.set(0, 0, 0, 3600);
        assertEq(LPGeometryLib.consultTwapTick(address(pool), 1800), 2);
    }

    /// @dev Negative delta with remainder must floor toward -inf (the twapTick-- branch):
    ///      delta=-3601 over 1800s is -2.0005…, so the TWAP tick is -3, not -2.
    function test_consultTwapTick_negativeDelta_floorsTowardNegInf() public {
        pool.set(0, 0, 3601, 0); // cum[1]-cum[0] = -3601
        assertEq(LPGeometryLib.consultTwapTick(address(pool), 1800), -3);
    }

    /// @dev Negative delta WITHOUT remainder must not over-floor: exactly -2.
    function test_consultTwapTick_negativeDeltaExact_noExtraFloor() public {
        pool.set(0, 0, 3600, 0);
        assertEq(LPGeometryLib.consultTwapTick(address(pool), 1800), -2);
    }

    // ─── calmGate ────────────────────────────────────────────────────────────

    /// @dev Within deviation: returns slot0's sqrtP/tick and both token decimals.
    function test_calmGate_withinDeviation_returnsSpotAndDecimals() public {
        // spot tick 100, twap 0 (zero cumulatives), deviation 100 <= 200
        pool.set(TickMath.getSqrtRatioAtTick(100), 100, 0, 0);
        (uint160 sqrtP, int24 spotTick, uint8 dec0, uint8 dec1) =
            LPGeometryLib.calmGate(address(pool), 1800, 200, token0, token1);
        assertEq(sqrtP, TickMath.getSqrtRatioAtTick(100));
        assertEq(spotTick, 100);
        assertEq(dec0, 18);
        assertEq(dec1, 18);
    }

    /// @dev |spot - twap| > maxTickDeviation reverts TwapDeviation — in BOTH directions.
    function test_calmGate_revertsOnDeviation_bothDirections() public {
        pool.set(0, 301, 0, 0); // spot 301 vs twap 0, max 300
        vm.expectRevert(LPGeometryLib.TwapDeviation.selector);
        LPGeometryLib.calmGate(address(pool), 1800, 300, token0, token1);

        pool.set(0, -301, 0, 0); // symmetric: spot below twap
        vm.expectRevert(LPGeometryLib.TwapDeviation.selector);
        LPGeometryLib.calmGate(address(pool), 1800, 300, token0, token1);
    }

    /// @dev Boundary: deviation EXACTLY at maxTickDeviation passes (check is strict >).
    function test_calmGate_exactDeviationPasses() public {
        pool.set(0, 300, 0, 0);
        (, int24 spotTick,,) = LPGeometryLib.calmGate(address(pool), 1800, 300, token0, token1);
        assertEq(spotTick, 300);
    }

    /// @dev Edge documented for independent linkers: window == 0 hits a raw division-by-zero panic
    ///      (0x12). The balancer guards this upstream (`twapWindow == 0 → InvalidConfig` in both
    ///      config paths); any new caller must do the same.
    function test_consultTwapTick_zeroWindow_panicsDivByZero() public {
        pool.set(0, 0, 0, 3600);
        vm.expectRevert(stdError.divisionError);
        LPGeometryLib.consultTwapTick(address(pool), 0);
    }

    /// @dev Edge documented for independent linkers: a width that is NOT a spacing multiple yields
    ///      a misaligned tickUpper (tl is floor-aligned, tu = tl + width). The balancer guards this
    ///      upstream (`width % spacing != 0 → InvalidWidth` on every rebalance path); any new
    ///      caller must align the width itself.
    function test_alignedRange_misalignedWidth_producesMisalignedUpper() public pure {
        // spacing 200, width 300 (not a multiple), spot 150: tl = floorAlign(0) = 0, tu = 300.
        (int24 tl, int24 tu) = LPGeometryLib.alignedRange(150, 300, 200, 150);
        assertEq(tl, 0);
        assertEq(tu, 300);
        assertTrue(tu % 200 != 0, "upper bound is NOT spacing-aligned for misaligned widths");
    }

    // ─── amountsForLiquidityAtTicks ──────────────────────────────────────────

    /// @dev CL range orientation — the fact the single-sided main/alt logic builds on: spot below
    ///      the range holds only token0, above holds only token1, inside holds both.
    function test_amountsForLiquidity_rangeOrientation() public pure {
        uint128 liq = 1e18;
        int24 tl = 0;
        int24 tu = 400;

        // spot below range → all token0
        (uint256 a0, uint256 a1) =
            LPGeometryLib.amountsForLiquidityAtTicks(TickMath.getSqrtRatioAtTick(-200), tl, tu, liq);
        assertGt(a0, 0);
        assertEq(a1, 0);

        // spot above range → all token1
        (a0, a1) = LPGeometryLib.amountsForLiquidityAtTicks(TickMath.getSqrtRatioAtTick(600), tl, tu, liq);
        assertEq(a0, 0);
        assertGt(a1, 0);

        // spot inside → both legs funded
        (a0, a1) = LPGeometryLib.amountsForLiquidityAtTicks(TickMath.getSqrtRatioAtTick(200), tl, tu, liq);
        assertGt(a0, 0);
        assertGt(a1, 0);
    }
}
