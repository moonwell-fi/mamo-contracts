// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  LeveragedAeroFees
/// @notice Streaming management fee + high-water-mark (HWM) performance fee for the
///         leveraged Aerodrome CL strategy, both crystallised by minting fee-shares.
///
///         All functions are **pure** — the strategy passes state in and applies the
///         returned deltas (`newHwmPerShareX`, `newLastAccrual`); it then calls
///         `vault.strategyMint(feeRecipient, feeShares)`.  No storage is touched here.
///
///         ## Decimal context
///         - `navPre`        USDC, 6 dp.
///         - `totalSupply`   vault shares, 12 dp (`_decimalsOffset() = 6` on USDC 6 dp).
///         - `hwmPerShareX`  = `navPre × 1e18 / totalSupply` — dimensionless, 1e18-scaled.
///         - Fee rates (`managementFeeBps`, `performanceFeeBps`) are bps; 1% = 100.
///
///         ## Ordering
///         `crystallize` computes management and performance fees against the **same**
///         pre-action `navPre` / `totalSupply`.  Management shares are NOT applied before
///         the performance computation — LP-favourable: avoids double-counting that
///         dilution in the HWM basis.
///
///         The **protocol** slice is taken off the GROSS gain above the HWM *first*
///         (`protocol = gain × protocolFeeBps / 10 000`), then the performance fee accrues
///         on the reduced `gain − protocol` (protocol-before-performance ordering).
///         The protocol slice is a USDC LIABILITY the strategy
///         discharges where USDC flows (redeem / compound / settle), NOT a fee-share mint.
///         The **HWM still advances to the gross-peak `navPerShareX`** (computed on `navPre`),
///         so no gain is ever charged twice and the next cycle measures from the gross peak
///         (LP-favourable, consistent with the dilution approximation).
///
///         ## [1] review fix (phantom-fee guard)
///         `crystallize` must be called with the *pre-deposit* NAV, before the vault
///         pulls any USDC.  Calling it on the post-deposit NAV would let idle incoming
///         USDC look like a profit above the HWM, silently over-charging existing LPs.
///         The library enforces nothing about call ordering — that invariant is owned by
///         the strategy (Tasks 3.6 / 3.7).  `test_noPhantomFee_whenIdleJustLanded`
///         anchors the regression: given the correct pre-deposit input, this library
///         produces zero performance fee.
///
///         ## Sampling — the HWM is sampled, not continuous (KNOWN AND ACCEPTED)
///         The HWM only ever moves at a `crystallize` call, so the total performance fee a
///         cohort pays telescopes to `perfBps × (max SAMPLED navPerShare − seed navPerShare)`,
///         not `perfBps × (max ATTAINED navPerShare − seed)`. Denser sampling therefore weakly
///         increases the fee, and the strategy crystallises before every deposit / redeem /
///         compound — so while `LeveragedAeroVault.openDeposits` is on, an outsider can add a
///         sampling point at a peak with a dust deposit. That is deliberate, on four grounds:
///
///         - **Crystallising before every issuance and burn is the fairness invariant.** Fees
///           must settle against the state that produced them before the share count moves, or
///           an entering LP buys into an unaccrued liability and an exiting one escapes it. Any
///           scheme that skips a crystallise to deny a sampling point breaks that first.
///         - **Interval-gating the perf leg does not work here.** The only clock available is
///           `lastFeeAccrualTimestamp`, and EVERY op advances it for the price-free management
///           leg (D6). A perf-leg gate measured off it would be reset by ordinary traffic and so
///           would disable the performance fee outright rather than smooth it; a second,
///           perf-only clock is a new storage slot plus a second dormancy-reset problem.
///         - **A window that suppresses sampling is a real fee escape.** Redemptions inside an
///           un-sampled window exit above an un-ratcheted HWM, paying nothing on the gain they
///           realise. That loss is certain; the sampling over-charge is bounded.
///         - **The caller profits nothing and cannot manufacture the peak.** Fee shares dilute to
///           `feeRecipient`, never to the caller, and the dust depositor is diluted along with
///           everyone else. `navPre` is Chainlink-priced behind the calm / TWAP-deviation gate, so
///           a peak can be SELECTED but not MANUFACTURED, and each peak is charged once — the HWM
///           ratchets, so the effect is one-shot per new high, not repeatable.
///
///         The operational lever, if a fund ever wants sampling closed to outsiders, is
///         `LeveragedAeroVault.setOpenDeposits(false)`: deposits become whitelist-only and every
///         sampling point is fund-controlled again.
library LeveragedAeroFees {
    /// @dev 1e18 fixed-point scale for per-share HWM and the management fee rate.
    uint256 private constant WAD = 1e18;

    /// @dev 365-day year in seconds (365 × 24 × 60 × 60 = 31 536 000).
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    // =========================================================================
    // Management fee
    // =========================================================================

    /// @notice Streaming management fee shares for an elapsed window `dt`.
    ///
    ///         `feeRate = managementFeeBps × dt / (10 000 × SECONDS_PER_YEAR)`
    ///
    ///         Minting `feeShares = totalSupply × feeRate / (1 − feeRate)` ensures the
    ///         recipient owns exactly `feeRate` of the **post-mint** supply, i.e. the
    ///         annualised dilution equals the bps fraction of AUM.
    ///
    ///         Rounds **down** (LP-favourable).
    ///
    /// @param totalSupply      Current vault share supply (12 dp).
    /// @param managementFeeBps Annual management fee in bps (e.g. 100 = 1 %/yr).
    /// @param dt               Seconds elapsed since last accrual.
    /// @return feeShares       Shares to mint to the fee recipient.
    function managementFeeShares(uint256 totalSupply, uint256 managementFeeBps, uint256 dt)
        internal
        pure
        returns (uint256 feeShares)
    {
        if (totalSupply == 0 || managementFeeBps == 0 || dt == 0) return 0;

        // feeRateX = managementFeeBps × dt × WAD / (10 000 × SECONDS_PER_YEAR).
        // Math.mulDiv carries the 512-bit intermediate: the pre-multiply
        // (managementFeeBps × dt) fits easily in uint256 for any realistic timestamp.
        uint256 feeRateX = Math.mulDiv(managementFeeBps * dt, WAD, 10_000 * SECONDS_PER_YEAR);

        // Absurd-dt guard: if feeRate ≥ 100 % the denominator (WAD − feeRateX) would
        // underflow.  Return 0 (LP-favourable) rather than reverting — stale accruals
        // must not brick the contract (e.g. extreme bps × impossible dt).
        if (feeRateX >= WAD) return 0;

        // feeShares = totalSupply × feeRateX / (WAD − feeRateX), rounded down.
        // Post-mint invariant: feeShares / (totalSupply + feeShares) = feeRateX / WAD.
        feeShares = Math.mulDiv(totalSupply, feeRateX, WAD - feeRateX);
    }

    // =========================================================================
    // Performance fee
    // =========================================================================

    /// @notice HWM performance fee shares.
    ///
    ///         `navPerShareX = navPre × 1e18 / totalSupply`  (1e18-scaled ratio)
    ///
    ///         - If `hwmPerShareX == 0` (never set): seed the HWM to the current level,
    ///           **no fee charged** — avoids a phantom fee on the first cycle after deploy.
    ///         - If `navPerShareX ≤ hwmPerShareX`: no fee, HWM unchanged.
    ///         - Else:
    ///
    ///             gain      = (navPerShareX − hwmPerShareX) × totalSupply / 1e18  (USDC 6 dp)
    ///             protocol  = gain × protocolFeeBps / 10 000                       (off GROSS gain first)
    ///             fee       = (gain − protocol) × performanceFeeBps / 10 000       (USDC 6 dp)
    ///             feeShares = fee × totalSupply / (navPre − fee)                   (12 dp shares)
    ///
    ///           After mint the recipient holds value ≈ `fee` USDC; the HWM resets to the
    ///           GROSS-peak `navPerShareX` (protocol slice NOT deducted from the basis) so future
    ///           fees accrue only on NEW gains. The protocol slice is returned as a USDC LIABILITY
    ///           the strategy discharges where USDC flows — never minted as shares.
    ///
    ///         If both fee rates are 0 but there is a gain, the HWM still advances
    ///         (no retroactive back-charge when a rate is later set non-zero).
    ///
    ///         Rounds **down** (LP-favourable) on both slices.
    ///
    /// @param navPre            Pre-action strategy NAV (USDC, 6 dp).
    /// @param totalSupply       Current vault share supply (12 dp).
    /// @param hwmPerShareX      Stored HWM per share (1e18-scaled); 0 ⇒ first cycle.
    /// @param performanceFeeBps Performance fee in bps (e.g. 1000 = 10 %).
    /// @param protocolFeeBps    Protocol fee in bps, taken off the gross gain FIRST.
    /// @return feeShares        Perf-fee shares to mint (0 if at/below HWM or unset).
    /// @return newHwmPerShareX  Updated HWM (unchanged if no gain).
    /// @return protocolUsdc     Protocol slice in USDC (6 dp) to accrue as a liability.
    function performanceFeeShares(
        uint256 navPre,
        uint256 totalSupply,
        uint256 hwmPerShareX,
        uint256 performanceFeeBps,
        uint256 protocolFeeBps
    ) internal pure returns (uint256 feeShares, uint256 newHwmPerShareX, uint256 protocolUsdc) {
        // No capital — nothing to charge or update.
        if (totalSupply == 0 || navPre == 0) return (0, hwmPerShareX, 0);

        uint256 navPerShareX = Math.mulDiv(navPre, WAD, totalSupply);

        // First-time seeding: HWM was 0 (unset). Record current level, no fee charged —
        // avoids a phantom performance fee on the first crystallize after deployment.
        if (hwmPerShareX == 0) return (0, navPerShareX, 0);

        // At or below the high-water mark → no fee, mark unchanged.
        if (navPerShareX <= hwmPerShareX) return (0, hwmPerShareX, 0);

        // Gain above the HWM is recognised; HWM always advances to the GROSS peak, even if both
        // rates are zero, so future non-zero rates don't back-charge this gain.
        // Gain in USDC 6 dp: (navPerShareX − hwmPerShareX) × totalSupply / WAD.
        uint256 gainPerShareX = navPerShareX - hwmPerShareX;
        uint256 totalGainUsdc = Math.mulDiv(gainPerShareX, totalSupply, WAD);

        // Protocol slice off the GROSS gain FIRST (rounds down, LP-favourable). USDC liability, never
        // minted.
        //
        // CLAMP AT THE GAIN, not at `navPre`. `protocolFeeBps` is read LIVE from an owner-pointed
        // ProtocolConfig this library cannot validate and nothing else bounds, so a `> 10_000`
        // value is representable. Clamping only at `navPre` let such a value produce
        // `protocolUsdc > totalGainUsdc`, and the `totalGainUsdc - protocolUsdc` subtraction below
        // then panics 0x11 — swallowed by every best-effort crystallise caller, i.e. fees stop
        // permanently and silently. `min(., totalGainUsdc)` keeps that subtraction total, bounds the
        // liability accrued on the `performanceFeeBps == 0` early return by the gain rather than by
        // the whole NAV, and subsumes the old `navPre` ceiling (the gain is a slice of `navPre` by
        // construction, so `totalGainUsdc ≤ navPre`).
        protocolUsdc = Math.mulDiv(totalGainUsdc, protocolFeeBps, 10_000);
        if (protocolUsdc > totalGainUsdc) protocolUsdc = totalGainUsdc;

        // HWM advances to the gross peak regardless of the perf rate.
        if (performanceFeeBps == 0) return (0, navPerShareX, protocolUsdc);

        // Perf fee accrues on the gain NET of the protocol slice.
        uint256 feeValueUsdc = Math.mulDiv(totalGainUsdc - protocolUsdc, performanceFeeBps, 10_000);

        // Degenerate guard: fee must be strictly less than NAV (else denominator ≤ 0).
        // This can only trigger for extreme/malformed fee rates — fail safe, LP-favourable.
        if (feeValueUsdc >= navPre) return (0, navPerShareX, protocolUsdc);

        // Dilution: mint enough shares so the recipient's value ≈ feeValueUsdc.
        // feeShares × navPre / (totalSupply + feeShares) = feeValueUsdc  (exact by algebra).
        feeShares = Math.mulDiv(feeValueUsdc, totalSupply, navPre - feeValueUsdc);
        newHwmPerShareX = navPerShareX;
    }

    // =========================================================================
    // Combined entrypoint
    // =========================================================================

    /// @notice Crystallise management + performance fees before a user action.
    ///
    ///         **Call with the pre-action NAV** (before USDC is pulled in or shares are
    ///         burned) so that no incoming deposit inflates the HWM basis ([1] fix).
    ///
    ///         The strategy:
    ///         1. Calls `crystallize(nav(), vault.totalSupply(), ...)`.
    ///         2. Calls `vault.strategyMint(feeRecipient, feeShares)` if `feeShares > 0`.
    ///         3. Stores `hwmPerShareX = newHwmPerShareX` and `lastAccrual = newLastAccrual`.
    ///         4. Proceeds with the user action (deposit / redeem).
    ///
    /// @param navPre            Strategy NAV before any user action (USDC, 6 dp).
    /// @param totalSupply       Current vault share supply (12 dp).
    /// @param hwmPerShareX      Stored HWM per share (1e18-scaled); 0 ⇒ first cycle.
    /// @param lastAccrual       Timestamp of the previous crystallization.
    /// @param nowTs             Current `block.timestamp`.
    /// @param managementFeeBps  Annual management fee in bps.
    /// @param performanceFeeBps Performance fee in bps.
    /// @param protocolFeeBps    Protocol fee in bps, taken off the gross gain FIRST (before perf).
    /// @return feeShares        Total shares to mint (management + performance).
    /// @return newHwmPerShareX  Updated HWM to store.
    /// @return newLastAccrual   Updated accrual timestamp (= `nowTs`).
    /// @return protocolUsdc     Protocol slice in USDC (6 dp) to accrue as a liability.
    function crystallize(
        uint256 navPre,
        uint256 totalSupply,
        uint256 hwmPerShareX,
        uint256 lastAccrual,
        uint256 nowTs,
        uint256 managementFeeBps,
        uint256 performanceFeeBps,
        uint256 protocolFeeBps
    ) public pure returns (uint256 feeShares, uint256 newHwmPerShareX, uint256 newLastAccrual, uint256 protocolUsdc) {
        // Always advance the accrual timestamp so management fees do not accumulate
        // over periods when the vault held no capital.
        newLastAccrual = nowTs;

        // No capital: zero fees, HWM unchanged. `navPre == 0` (oracle down / calm-gate
        // shut) is NOT short-circuited here — the management leg is price-free (D6): it
        // still crystallises the elapsed `dt`, and `performanceFeeShares` defers on
        // `navPre == 0` by returning the HWM unchanged, so no gain escapes the perf fee
        // (the next priced cycle still measures gain vs the same HWM).
        if (totalSupply == 0) {
            newHwmPerShareX = hwmPerShareX;
            return (0, newHwmPerShareX, newLastAccrual, 0);
        }

        // dt is 0 when called in the same block as the last accrual (e.g. two deposits).
        uint256 dt = nowTs > lastAccrual ? nowTs - lastAccrual : 0;

        // Management fee is price-free (supply × rate × dt) — accrues regardless of navPre.
        uint256 mShares = managementFeeShares(totalSupply, managementFeeBps, dt);
        // Performance + protocol need a price: navPre == 0 ⇒ (0 shares, HWM unchanged, 0 protocol) ⇒ defers.
        (uint256 pShares, uint256 newHwm, uint256 protoUsdc) =
            performanceFeeShares(navPre, totalSupply, hwmPerShareX, performanceFeeBps, protocolFeeBps);

        // feeShares = mShares + pShares; overflow impossible (both << totalSupply).
        feeShares = mShares + pShares;
        newHwmPerShareX = newHwm;
        protocolUsdc = protoUsdc;
    }
}
