// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroFees} from "@contracts/leveraged-aero/LeveragedAeroFees.sol";

import {Test} from "@forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title  LeveragedAeroFees: the protocol slice must be clamped at the GAIN
 * @notice `protocolFeeBps` is the one fee rate this library does NOT receive from validated init
 *         params. The strategy reads it LIVE, every crystallise, from an owner-pointed
 *         ProtocolConfig (`vault.factory().protocolConfig().protocolFeeBps()`) — an address the
 *         library cannot inspect and `checkFeeParams` never sees. A value above `10_000` is
 *         therefore representable, and the old `min(., navPre)` ceiling did not stop it turning
 *         `totalGainUsdc - protocolUsdc` into an underflow.
 *
 *         WHY THAT IS WORSE THAN A REVERT. Every crystallise caller is best-effort: `compound`,
 *         `deposit` and `redeem` wrap the call so a fee failure defers rather than bricks the op.
 *         A Panic 0x11 raised inside the library is swallowed by exactly that machinery, so the
 *         symptom is not a loud failure — it is fees silently ceasing, permanently, on a book that
 *         otherwise keeps trading.
 *
 * @dev A pure-library suite: no vault, no venues, no fixture. `performanceFeeShares` is `internal`,
 *      which is directly callable from an importing contract (it links inline), so the arithmetic
 *      can be pinned at the exact site of the clamp rather than inferred through a strategy.
 */
contract LeveragedAeroFeesUnitTest is Test {
    /// @dev A $1.1M book against a $1.0M-equivalent high-water mark: a clean $100k gain.
    uint256 internal constant NAV_PRE = 1_100_000e6;
    uint256 internal constant SUPPLY = 1_000_000e12;
    /// @dev The unit-rate mark (`WAD / SHARES_VIRTUAL_OFFSET`), i.e. the level a fresh fund seeds at.
    uint256 internal constant HWM = 1e12;
    uint256 internal constant GAIN = 100_000e6;

    /// @dev The per-share level `NAV_PRE` implies, which is where the HWM must land after any of these.
    function _navPerShareX() internal pure returns (uint256) {
        return Math.mulDiv(NAV_PRE, 1e18, SUPPLY);
    }

    /// @dev Precondition shared by every case below: the fixture really does present a $100k gain.
    function testTheFixturePresentsTheExpectedGain() public pure {
        assertEq(Math.mulDiv(_navPerShareX() - HWM, SUPPLY, 1e18), GAIN, "fixture gain");
        assertLt(GAIN, NAV_PRE, "the gain is a slice of the NAV, so the old navPre ceiling never bound");
    }

    /**
     * @dev (a) THE UNDERFLOW, closed. A 200% protocol rate is clamped to the WHOLE gain, the
     *      `totalGainUsdc - protocolUsdc` subtraction stays total, and the call RETURNS instead of
     *      panicking. Nothing is left for the performance leg — correct: the protocol already took
     *      everything the gain contained.
     *
     *      MUTATION: restore `if (protocolUsdc > navPre) protocolUsdc = navPre;` and this reverts
     *      with Panic 0x11 (2e11 > 1e11, and 2e11 is well under `navPre` so the old ceiling is inert).
     */
    function testAnOverlargeProtocolRateIsClampedAtTheGainInsteadOfUnderflowing() public pure {
        (uint256 feeShares, uint256 newHwm, uint256 protocolUsdc) =
            LeveragedAeroFees.performanceFeeShares(NAV_PRE, SUPPLY, HWM, 1000, 20_000);

        assertEq(protocolUsdc, GAIN, "the slice is capped at the gain, never above it");
        assertEq(feeShares, 0, "nothing is left for the performance leg");
        assertEq(newHwm, _navPerShareX(), "the HWM still advances to the gross peak");
    }

    /**
     * @dev (b) THE `performanceFeeBps == 0` EARLY RETURN takes the same ceiling. That branch skips
     *      the subtraction entirely, so it never panicked — it just accrued a liability bounded by
     *      the whole NAV rather than by the gain. A fund running the protocol fee alone is an
     *      ordinary configuration, so this is the reachable half.
     *
     *      MUTATION: restore the `navPre` clamp and `protocolUsdc` is 2 x GAIN.
     */
    function testTheProtocolOnlyPathIsAlsoBoundedByTheGain() public pure {
        (uint256 feeShares, uint256 newHwm, uint256 protocolUsdc) =
            LeveragedAeroFees.performanceFeeShares(NAV_PRE, SUPPLY, HWM, 0, 20_000);

        assertEq(protocolUsdc, GAIN, "bounded by the gain...");
        assertLt(protocolUsdc, NAV_PRE, "...which is strictly tighter than the old navPre ceiling");
        assertEq(feeShares, 0, "no perf rate, no shares");
        assertEq(newHwm, _navPerShareX(), "the HWM advances regardless of the rates");
    }

    /**
     * @dev (c) THE CLAMP IS NOT FREE-RUNNING. A sane rate must be untouched by it, or the fix would
     *      be a silent fee cut rather than a bound.
     */
    function testASaneProtocolRateIsUnaffectedByTheClamp() public pure {
        (uint256 feeShares, uint256 newHwm, uint256 protocolUsdc) =
            LeveragedAeroFees.performanceFeeShares(NAV_PRE, SUPPLY, HWM, 1000, 2000);

        assertEq(protocolUsdc, (GAIN * 2000) / 10_000, "20% of the gross gain, exactly as documented");
        assertGt(feeShares, 0, "the performance leg still accrues on the net gain");
        assertEq(newHwm, _navPerShareX(), "HWM at the gross peak");
    }

    /**
     * @dev (d) THE COMBINED ENTRYPOINT, which is what the strategy actually calls. The management leg
     *      must still crystallise its elapsed window even when the protocol rate is malformed — the
     *      whole point of keeping the subtraction total is that ONE bad config value does not take
     *      the price-free leg down with it.
     */
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
        // A full year of 1%/yr on this supply, and nothing from the (fully-consumed) performance leg.
        // The management mint is the dilution form — `supply x r / (1 - r)` at `r = 1%` — so that the
        // recipient ends up owning exactly 1% of the POST-mint supply.
        assertEq(feeShares, Math.mulDiv(SUPPLY, 1e16, 1e18 - 1e16), "management leg crystallised in full");
    }
}
