// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroValuation} from "@contracts/leveraged-aero/LeveragedAeroValuation.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {Test} from "@forge-std/Test.sol";

/**
 * @title EXPLICIT-RANGE predicate (`LeveragedAeroValuation.checkExplicitRange`)
 * @notice The gate on `remintRange`'s caller-supplied `(tickLower, tickUpper)`. It is the counterpart of
 *         `checkRange` for the DERIVED `(width, skew)` pair, and every rejection shares the one
 *         `OutOfBounds` selector.
 *
 * @dev Pure — no venue mocks at all. The SKEW band is deliberately absent from the signature: explicit
 *      placement is the feature `remintRange` exists for, and a skew is only meaningful for a band derived
 *      from spot. The WIDTH band still binds, which is what keeps the proposer inside governance policy.
 */
contract LeveragedAeroExplicitRangeUnitTest is Test {
    int24 internal constant SPACING = 100;
    uint24 internal constant MIN_WIDTH = 200;
    uint24 internal constant MAX_WIDTH = 20_000;

    function _check(int24 lower, int24 upper) internal pure {
        LeveragedAeroValuation.checkExplicitRange(lower, upper, SPACING, MIN_WIDTH, MAX_WIDTH);
    }

    function _expectOutOfBounds() internal {
        vm.expectRevert(LeveragedAeroValuation.OutOfBounds.selector);
    }

    /// @dev The aligned domain edge the predicate clamps against, for `SPACING`.
    function _maxAligned() internal pure returns (int24) {
        return TickMath.MAX_TICK - (TickMath.MAX_TICK % SPACING);
    }

    // ==================== ACCEPTED ====================

    function testAcceptsAnOnGridBandInsideTheWidthBand() public pure {
        _check(-2000, 2000); // width 4000, brackets 0
        _check(69_000, 73_000); // a positive band, nowhere near spot — placement is free
        _check(-73_000, -69_000);
    }

    /// @dev BOTH width-band edges are reachable: the band is inclusive at both ends.
    function testAcceptsTheExactWidthBandBoundaries() public pure {
        _check(0, int24(uint24(MIN_WIDTH))); // exactly minWidth
        _check(0, int24(uint24(MAX_WIDTH))); // exactly maxWidth
    }

    /// @dev The aligned tick domain edges themselves are inside, not outside.
    function testAcceptsTheAlignedDomainEdges() public pure {
        int24 maxAligned = _maxAligned();
        _check(maxAligned - int24(uint24(MAX_WIDTH)), maxAligned);
        _check(-maxAligned, -maxAligned + int24(uint24(MAX_WIDTH)));
    }

    // ==================== REJECTED ====================

    function testRejectsOffGridTicks() public {
        _expectOutOfBounds();
        _check(-2050, 2000); // lower off grid
        _expectOutOfBounds();
        _check(-2000, 2050); // upper off grid
    }

    /// @dev Negative ticks are the easy place to get `%` wrong, so they get their own case.
    function testRejectsOffGridNegativeTicks() public {
        _expectOutOfBounds();
        _check(-2001, -1000);
    }

    function testRejectsAnInvertedOrDegenerateBand() public {
        _expectOutOfBounds();
        _check(2000, -2000); // inverted
        _expectOutOfBounds();
        _check(2000, 2000); // zero width
    }

    function testRejectsTicksOutsideTheAlignedDomain() public {
        // Widths kept legal (200) so it is the DOMAIN clamp being asserted, not the width band.
        int24 maxAligned = _maxAligned();
        _expectOutOfBounds();
        _check(maxAligned - SPACING, maxAligned + SPACING); // upper past the domain
        _expectOutOfBounds();
        _check(-maxAligned - SPACING, -maxAligned + SPACING); // lower past the domain
    }

    function testRejectsWidthsOutsideTheGovernanceBand() public {
        _expectOutOfBounds();
        _check(0, int24(uint24(MIN_WIDTH)) - SPACING); // one spacing under minWidth
        _expectOutOfBounds();
        _check(0, int24(uint24(MAX_WIDTH)) + SPACING); // one spacing over maxWidth
    }

    /// @dev A zero/negative spacing is unreachable through the strategy (init rejects it) but the predicate
    ///      fails closed rather than dividing by zero, mirroring `checkRange`.
    function testRejectsANonPositiveTickSpacing() public {
        _expectOutOfBounds();
        LeveragedAeroValuation.checkExplicitRange(-2000, 2000, 0, MIN_WIDTH, MAX_WIDTH);
    }
}
