// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroFees} from "@contracts/leveraged-aero/LeveragedAeroFees.sol";

import {Test} from "@forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  LeveragedAeroFees: the protocol slice must be clamped at the GAIN
/// @notice `protocolFeeBps` is read LIVE from an owner-pointed ProtocolConfig, so `checkFeeParams` never
///         sees it and a value above `10_000` is representable; the old `min(., navPre)` ceiling let it
///         underflow `totalGainUsdc - protocolUsdc`. Every crystallise caller is best-effort, so that
///         Panic 0x11 surfaces as fees silently ceasing forever rather than as a revert.
contract LeveragedAeroFeesUnitTest is Test {
    /// @dev A $1.1M book against a $1.0M-equivalent high-water mark: a clean $100k gain.
    uint256 internal constant NAV_PRE = 1_100_000e6;
    uint256 internal constant SUPPLY = 1_000_000e12;
    /// @dev The unit-rate mark (`WAD / SHARES_VIRTUAL_OFFSET`), i.e. the level a fresh fund seeds at.
    uint256 internal constant HWM = 1e12;
    uint256 internal constant GAIN = 100_000e6;

    /// @dev The per-share level `NAV_PRE` implies, where the HWM must land after any of these.
    function _navPerShareX() internal pure returns (uint256) {
        return Math.mulDiv(NAV_PRE, 1e18, SUPPLY);
    }

    /// @dev The fixture really does present a $100k gain, a slice of NAV so the old ceiling never bound.
    function testTheFixturePresentsTheExpectedGain() public pure {
        assertEq(Math.mulDiv(_navPerShareX() - HWM, SUPPLY, 1e18), GAIN, "fixture gain");
        assertLt(GAIN, NAV_PRE, "the gain is a slice of the NAV, so the old navPre ceiling never bound");
    }

    /// @dev A 200% protocol rate clamps to the whole gain: the subtraction stays total, no panic, no perf shares.
    /// MUTATION: restore `if (protocolUsdc > navPre) protocolUsdc = navPre;` and this Panics 0x11.
    function testAnOverlargeProtocolRateIsClampedAtTheGainInsteadOfUnderflowing() public pure {
        (uint256 feeShares, uint256 newHwm, uint256 protocolUsdc) =
            LeveragedAeroFees.performanceFeeShares(NAV_PRE, SUPPLY, HWM, 1000, 20_000);

        assertEq(protocolUsdc, GAIN, "the slice is capped at the gain, never above it");
        assertEq(feeShares, 0, "nothing is left for the performance leg");
        assertEq(newHwm, _navPerShareX(), "the HWM still advances to the gross peak");
    }

    /// @dev The `performanceFeeBps == 0` early return — an ordinary config — takes the same gain ceiling.
    /// MUTATION: restore the `navPre` clamp and `protocolUsdc` is 2 x GAIN.
    function testTheProtocolOnlyPathIsAlsoBoundedByTheGain() public pure {
        (uint256 feeShares, uint256 newHwm, uint256 protocolUsdc) =
            LeveragedAeroFees.performanceFeeShares(NAV_PRE, SUPPLY, HWM, 0, 20_000);

        assertEq(protocolUsdc, GAIN, "bounded by the gain...");
        assertLt(protocolUsdc, NAV_PRE, "...which is strictly tighter than the old navPre ceiling");
        assertEq(feeShares, 0, "no perf rate, no shares");
        assertEq(newHwm, _navPerShareX(), "the HWM advances regardless of the rates");
    }

    /// @dev A sane rate is untouched by the clamp, so the fix is a bound and not a silent fee cut.
    function testASaneProtocolRateIsUnaffectedByTheClamp() public pure {
        (uint256 feeShares, uint256 newHwm, uint256 protocolUsdc) =
            LeveragedAeroFees.performanceFeeShares(NAV_PRE, SUPPLY, HWM, 1000, 2000);

        assertEq(protocolUsdc, (GAIN * 2000) / 10_000, "20% of the gross gain, exactly as documented");
        assertGt(feeShares, 0, "the performance leg still accrues on the net gain");
        assertEq(newHwm, _navPerShareX(), "HWM at the gross peak");
    }

    /// @dev The combined entrypoint: the management leg still crystallises on a malformed protocol rate.
    function testCrystallizeSurvivesAMalformedProtocolRate() public pure {
        (uint256 feeShares, uint256 newHwm, uint256 newLast, uint256 protocolUsdc) = LeveragedAeroFees.crystallize(
            NAV_PRE,
            SUPPLY,
            HWM,
            1_000_000, // lastAccrual
            1_000_000 + 365 days, // nowTs
            100, // 1%/yr management
            1000, // 10% performance
            20_000 // 200% protocol — malformed
        );

        assertEq(protocolUsdc, GAIN, "protocol slice bounded by the gain");
        assertEq(newLast, 1_000_000 + 365 days, "the clock advanced");
        assertEq(newHwm, _navPerShareX(), "the HWM advanced");
        // A full year of 1%/yr in dilution form (`supply x r / (1 - r)`), nothing from the performance leg.
        assertEq(feeShares, Math.mulDiv(SUPPLY, 1e16, 1e18 - 1e16), "management leg crystallised in full");
    }
}
