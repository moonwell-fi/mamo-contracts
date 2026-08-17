// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeeConstants} from "./sherwood/FeeConstants.sol";
import {ICToken} from "./sherwood/interfaces/ICToken.sol";
import {IMoonwellMarket} from "./sherwood/interfaces/IMoonwellMarket.sol";
import {ICLGauge, ICLPool, ICLSwapRouter} from "./sherwood/interfaces/ISlipstream.sol";
import {ChainlinkReader} from "./sherwood/libraries/ChainlinkReader.sol";
import {LiquidityAmounts} from "./sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "./sherwood/libraries/TickMath.sol";

/// @dev Minimal Aerodrome v2 (AMM) Router — used for the `compound` AERO→USDC reward swap (see
///      `swapAeroToUsdc`). The Slipstream CL SwapRouter only serves CL pools, so the reward leg needs
///      its own venue interface.
interface IAeroRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @dev Aerodrome v2 (AMM) PoolFactory — the registry the Route above names, used to PROVE a
///      reward→USDC route exists before a venue is adopted. Note the arity difference from
///      Slipstream's `ICLFactory.getPool(address,address,int24)`: v2 pools are keyed by a
///      stable/volatile flag, not a tick spacing.
interface IAeroV2Factory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address pool);
}

/// @title  LeveragedAeroValuation
/// @notice Net-equity **oracle** NAV for the leveraged Aerodrome CL strategy. This is
///         the single safety-critical computation — it prices DEPOSITS, so a wrong
///         sign / decimal / overflow silently mis-mints shares. Everything here is
///         fail-closed: any oracle staleness, sequencer outage, grace window, or a
///         spot/TWAP deviation reverts, and a non-positive net equity reverts — a
///         manipulated price can only *deny* a deposit, never mint cheap shares.
///
///         ```
///         NAV = idleStrategy + collateral + clLegs + idleLegs + reward − debt  (USDC, 6dp)
///         ```
///
///         The strategy prices/redeems against strategy-controlled value only; any vault float
///         (normally 0 — `execute` sends the vault's USDC to the strategy, so float is reachable
///         only via a direct donation) is EXCLUDED from NAV and distributed to all shares at
///         settle. This keeps deposit pricing and redeem consistent: both see the same
///         strategy-controlled book (M2).
///
///         - `idleStrategy`  = `USDC.balanceOf(strategy)`     (face, 6dp)
///         - `collateral`    = Moonwell USDC supply, `mUSDC.balanceOf(strategy) *
///                             exchangeRateStored / 1e18`     (face, 6dp; scaling copied
///                             verbatim from `MoonwellSupplyAdapter`)
///         - `debt`          = `borrowBalanceStored(cbBTC) * P_cbBTC +
///                             borrowBalanceStored(WETH) * P_WETH`, each priced via
///                             Chainlink and converted USD→USDC.
///         - `clLegs`        = the CL position's token0/token1 amounts at an
///                             **oracle-implied `sqrtP`** (derived from the two Chainlink
///                             prices, NOT the manipulable pool tick), each leg priced via
///                             Chainlink.
///         - `idleLegs`      = out-of-position cbBTC/WETH held by the strategy (e.g. the
///                             remainder a no-swap `rerange` recenter leaves), each priced via
///                             Chainlink on the SAME basis as `debt` — so a borrowed leg is
///                             never uncounted and a single-position recenter is NAV-neutral.
///         - `reward`        = the WHOLE gauge-reward claim: the reward token ALREADY CLAIMED into
///                             the strategy wallet (every `_unwindLiquidity` auto-claims one via
///                             `gauge.withdraw`) PLUS the still-unclaimed `gauge.earned()` on the
///                             staked tokenId, both priced via the venue's reward feed. See
///                             `_rewardUsdc` for the try/catch, the gating and the fee-timing
///                             consequence.
///
///         The CL-leg split uses the oracle sqrtP (the Gamma/Arrakis technique) so the
///         mint mark cannot be tick-shoved; the same two feeds price the debt, so the
///         whole net-short book nets on a single Chainlink basis.
library LeveragedAeroValuation {
    using SafeERC20 for IERC20;

    /// @notice Spot tick deviated from the pool TWAP beyond `calmDeviationTicks`.
    error CalmGateBreached();
    /// @notice Net equity is ≤ 0 — minting is fail-closed (no shares at/under water).
    error NonPositiveEquity();
    /// @notice The oracle-implied sqrtP fell below the valid pool sqrtP range (`< MIN_SQRT_RATIO`)
    ///         — fail-closed rather than feed a sub-range price into the leg split. The upper end
    ///         of the range needs no explicit check: `Math.mulDiv` overflow-reverts before an
    ///         above-range sqrtP can be produced (see `oracleSqrtPriceX96`).
    error OracleSqrtPriceOutOfRange();
    /// @notice A Config value is invalid (e.g. `twapWindow == 0` would divide-by-zero the
    ///         calm-gate) — fail-closed with a named error instead of an opaque arithmetic panic.
    error InvalidConfig();
    /// @notice A Chainlink feed reported decimals != the assumed 8 — fail-closed rather than
    ///         silently mis-scale the USD→USDC conversion (a redeployed/misconfigured feed).
    error FeedDecimalsMismatch();
    /// @notice ASSET-MODE sizing could not produce a two-sided split (see `_rangeRatio`, shared by
    ///         `assetModeSplit` and `assetModeLeverUpPair`): the current tick sits entirely outside the
    ///         target range (one leg's required amount is 0), or the solved collateral portion collapsed
    ///         to 0 / the whole deposit. Fail-closed — opening an unhedged or unlevered leg would
    ///         silently break the delta-hedge premise.
    error DegenerateRange();
    /// @notice ASSET-MODE lever-up needs `needed` USDC from idle to pair with the borrowed leg A, but the
    ///         book only holds `available` (see `assetModeLeverUpPair`). Fail-closed and LOUD: a partial
    ///         fill or a silent cap would leave the position under-levered and, worse, mis-hedged. The
    ///         selector matches the same-signature declarations in `LeveragedAeroManager` /
    ///         `LeveragedAerodromeCLStrategy`, so a test may expect it off any of the three.
    error InsufficientIdleForLeverUp(uint256 needed, uint256 available);
    /// @notice A Moonwell `repayBorrow` returned a non-zero Compound error code. Declared here because
    ///         `hedgeBorrowInterest` repays inside this library; the selector matches the
    ///         same-signature declarations in `LeveragedAeroManager` / `LeveragedAerodromeCLStrategy`,
    ///         so a test may expect it off any of the three.
    error MoonwellRepayFailed(uint256 errCode);
    /// @notice A range pair failed `checkRange`: a width off the tickSpacing grid / outside
    ///         `[minWidth, maxWidth]`, OR a skew outside `(0, 1e4)` / outside the governance band
    ///         `[minSkewBps, maxSkewBps]` / one that starves either side of the range below a single
    ///         tickSpacing. ONE error for both knobs: they are validated together, by the same two
    ///         callers (`_initialize` and `rerange`), and a caller that has to fix its range params does
    ///         not branch on which half was wrong. The selector matches the same-signature declaration
    ///         in `LeveragedAerodromeCLStrategy`, so a test may expect it off either.
    error OutOfBounds();
    /// @notice An oracle / calm-gate config value is outside the band a guard needs to stay meaningful.
    ///         Declared here because `checkRiskParams` runs the ladder; the selector matches the
    ///         same-signature declaration in `LeveragedAerodromeCLStrategy`.
    error OracleParamOutOfRange();
    /// @notice `targetLtvBps > maxLtvBps` at init. Selector shared with the strategy.
    error TargetLtvExceedsMax();
    /// @notice `minHealthBps` below the 10500 floor. Selector shared with the strategy.
    error MinHealthTooLow();
    /// @notice `maxLtvBps` at or above the Moonwell USDC collateral factor. Selector shared.
    error MaxLtvExceedsCF();
    /// @notice `minHealthBps × maxLtvBps >= 1e8` — the permissionless-deleverage trigger LTV would sit
    ///         at or below `maxLtvBps`, opening an in-band grief window (L4). Selector shared.
    error MinHealthMaxLtvConflict();
    /// @notice A non-zero fee rate with a zero recipient. Selector shared with the strategy.
    error FeeRecipientRequired();
    /// @notice Performance fee above the protocol-wide cap. Selector shared with the strategy.
    error PerformanceFeeTooHigh();
    /// @notice Management fee above the factory's cap. Selector shared with the strategy.
    error ManagementFeeTooHigh();
    /// @notice `Comptroller.markets()` failed, returned short, or reported a zero collateral factor.
    ///         Selector shared with the strategy.
    error ComptrollerCallFailed();

    // ── Events (this library's `public` functions are DELEGATECALLED, so they log from the STRATEGY's
    //    address and the declaration is mirrored in `LeveragedAerodromeCLStrategy`'s ABI) ──

    /// @notice `_measureLeg` could not read `market`'s accrued debt — the Moonwell accrual reverted — so
    ///         that leg's drift was taken as ZERO for this harvest and the leg went UNHEDGED.
    /// @dev The fourth of this stack's deliberate fail-opens, and it follows the same naming: `…Degraded`
    ///      means a GUARD fell back and the op ran on with less protection (the interest hedge is the
    ///      guard against accumulating short exposure; `compound` itself completes). Exactly like
    ///      `RedeemSweepFloorsDegraded`, a degraded INPUT (here the measured debt, there the min-out
    ///      floors) is substituted with a zero and the surrounding code path runs unchanged — which is
    ///      why this is not a `…Deferred`, even though the effect on that one leg is a skipped buy.
    ///
    ///      WHY A LOG IS MANDATORY HERE. The unhedged remainder stays in `debt − hedged` and the next
    ///      healthy harvest closes it, so nothing is lost — but a leg whose market never recovers accrues
    ///      an unbounded, unintended SHORT with a perfectly successful `compound` in every block, i.e. the
    ///      precise failure the hedge exists to prevent, returning invisibly. `market` identifies the leg.
    event HedgeLegMeasureDegraded(address market);

    /// @dev Chainlink USD feeds on Base are 8-decimal; assumed for the USD→USDC scaling.
    uint256 private constant USD_FEED_DECIMALS = 8;

    /// @dev Annual management-fee ceiling (bps) enforced by `checkFeeParams`; mirrors
    ///      `SyndicateFactory.MAX_MANAGEMENT_FEE_BPS` (5%/yr). Lives here with the ladder that reads it.
    uint16 private constant MAX_MANAGEMENT_FEE_BPS = 500;

    /// @dev Reference liquidity for the `assetModeSplit` ratio probe. Only the RATIO of the two
    ///      required amounts matters (both are linear in L for a fixed range + sqrtP, so L cancels),
    ///      and `2^96` is the natural choice: it makes the token1 term exactly `sqrtP − sqrtLower`,
    ///      keeping both probe amounts large enough that integer rounding is negligible (relative
    ///      error ~1/needX, i.e. ≲1e-20 for real pools) while staying inside `uint128`.
    uint128 private constant REF_LIQUIDITY = uint128(1) << 96;

    /// @notice Everything `netEquityUsdc` needs — no per-call magic numbers. The caller
    ///         (`strategy.nav()`, a later task) reads `NPM.positions(tokenId)` and passes
    ///         the ticks + liquidity; this library never touches the NPM.
    /// @dev `cbBTCFeed`/`wethFeed` are mapped onto the pool's token0/token1 at call time by
    ///      reading `pool.token0()`/`token1()`, so leg pricing is robust to pool ordering.
    struct Config {
        address usdc; // USDC (6dp) — the NAV unit of account
        address vault; // SyndicateVault (set by the strategy/manager Config builders; NAV excludes vault float — M2)
        address mUsdc; // Moonwell USDC market (collateral)
        address cbBTCMarket; // Moonwell cbBTC borrow market
        address wethMarket; // Moonwell WETH borrow market
        address cbBTC; // cbBTC underlying token
        address weth; // WETH underlying token
        uint8 cbBTCDecimals; // cbBTC decimals (8 on Base)
        uint8 wethDecimals; // WETH decimals (18)
        address pool; // Aerodrome Slipstream CL pool (cbBTC/WETH)
        address gauge; // Slipstream CL gauge — read for `rewardToken()` + `earned()` (the reward term)
        uint256 tokenId; // `Layout.tokenId` — the staked CL NFT `earned()` is asked about; 0 ⇒ flat book
        address cbBTCFeed; // Chainlink BTC/USD feed (8dp)
        address wethFeed; // Chainlink ETH/USD feed (8dp)
        address usdcFeed; // Chainlink USDC/USD feed (8dp)
        address rewardFeed; // Chainlink reward/USD feed (8dp) — `Layout.aeroUsdFeed`, the venue-migrated one
        address sequencerFeed; // Chainlink L2 sequencer-uptime feed
        uint256 maxDelay; // per-feed max staleness (seconds)
        uint256 gracePeriod; // sequencer grace period (seconds)
        uint16 calmDeviationTicks; // max |spotTick − twapTick| before fail-closed
        uint32 twapWindow; // calm-gate TWAP lookback (seconds)
    }

    /// @notice The net-equity oracle NAV of the whole levered book, in USDC (6dp).
    /// @param c          Valuation config.
    /// @param strategy   The strategy clone (holds collateral, debt, idle USDC).
    /// @param tickLower  Lower tick of the CL position (from `NPM.positions`).
    /// @param tickUpper  Upper tick of the CL position.
    /// @param liquidity  CL liquidity (from `NPM.positions`); 0 ⇒ no CL legs.
    /// @return navUsdc   USDC value of `idle + collateral + clLegs + idleLegs + reward − debt`
    ///                   (vault float excluded — M2 deposit/redeem symmetry; strategy-controlled
    ///                   terms only).
    /// @dev Fail-closed: reverts on any oracle/calm failure (via `ChainlinkReader` and the
    ///      calm-gate) and on non-positive equity. Used to price deposits only. The reward feed is
    ///      read ONLY when there is reward value (held balance OR `earned()`) — see `_rewardUsdc`.
    function netEquityUsdc(Config memory c, address strategy, int24 tickLower, int24 tickUpper, uint128 liquidity)
        public
        view
        returns (uint256 navUsdc)
    {
        // Calm-gate first: if the pool is being shoved, fail closed before pricing anything.
        _calmGate(c);

        // USDC peg price (8dp) — read once; reused to convert every USD term to USDC face.
        uint256 pUsdc = _readUsd8(c, c.usdcFeed);

        // --- positive face terms (strategy-controlled only; vault float excluded — M2) ---
        uint256 assets = IERC20(c.usdc).balanceOf(strategy); // idleStrategy (6dp)
        assets += _collateralUsdc(c, strategy); // Moonwell USDC collateral (6dp)

        // --- CL legs (oracle-implied sqrtP) ---
        (uint256 pCbBTC, uint256 pWeth) = _legPrices(c);
        assets += _clLegsUsdc(c, tickLower, tickUpper, liquidity, pCbBTC, pWeth, pUsdc);

        // --- idle (out-of-position) borrowed legs ---
        // A no-swap `rerange` recenter leaves a remainder of ONE borrowed leg in the strategy
        // wallet (the collected token ratio cannot match the new range's required ratio and
        // swapping is forbidden). Price that remainder on the SAME Chainlink basis as the CL legs
        // and the debt (fail-closed via `_legPrices`/`_readUsd8`, behind the calm-gate already run
        // above) so a borrowed token is never uncounted: this makes a single-position recenter
        // NAV-neutral (the remainder is redeployable and swept on the next exit, not leaked). In
        // steady state these balances are ~dust (execute/deploy/compound/settle/redeem leave ~0),
        // and `_usdcValue` returns 0 for a 0 amount, so this is a clean no-op outside a rerange.
        //
        // ASSET-MODE (`c.cbBTC == c.usdc`, i.e. the leg-B slot IS the unit of account — a legA/USDC
        // pool): the leg-B idle term would RE-ADD the idle USDC already counted as `idleStrategy`
        // above, double-counting it into NAV and mis-minting deposit shares. Skip it — in asset-mode
        // the LP-side USDC that is not yet in the position is exactly `idleStrategy`, counted once.
        // (Leg A is never the unit of account: `_initialize` rejects `weth == usdc`, so its term is
        // unconditional.) See `assetModeSplit` for the shape itself.
        if (c.cbBTC != c.usdc) {
            assets += _usdcValue(IERC20(c.cbBTC).balanceOf(strategy), c.cbBTCDecimals, pCbBTC, pUsdc);
        }
        assets += _usdcValue(IERC20(c.weth).balanceOf(strategy), c.wethDecimals, pWeth, pUsdc);

        // --- gauge reward: claimed-but-unsold balance + still-unclaimed `earned()` ---
        assets += _rewardUsdc(c, strategy, pUsdc);

        // --- debt (same Chainlink basis) ---
        uint256 debt = _debtUsdc(c, strategy, pCbBTC, pWeth, pUsdc);

        if (assets <= debt) revert NonPositiveEquity();
        navUsdc = assets - debt;
    }

    /// @notice Oracle-implied `sqrtPriceX96` from two USD prices + token decimals — the
    ///         absolute mark used to split the CL position (NOT the manipulable pool tick).
    /// @param p0 USD price of token0 (feed answer, any decimals — they cancel against p1).
    /// @param d0 token0 decimals.
    /// @param p1 USD price of token1.
    /// @param d1 token1 decimals.
    /// @return sqrtPriceX96 `sqrt(rawPrice1per0) * 2^96`, where the raw (smallest-unit) price
    ///         `token1/token0 = p0 * 10^d1 / (p1 * 10^d0)`.
    /// @dev Overflow / range (fail-closed): `Math.mulDiv` carries the 512-bit
    ///      `p0*10^d1 * 2^192` intermediate. Only ONE bound is load-bearing — the LOW one —
    ///      because the HIGH bound is unreachable by construction (a wrong sqrtP would let
    ///      `getAmountsForLiquidity`, which is itself unbounded, mis-split the legs — a fail-OPEN
    ///      mis-mint, so the reachable bound must still fail closed):
    ///        - HIGH bound is UNREACHABLE, so there is no high-side guard: `Math.mulDiv(num, 2^192,
    ///          den)` itself reverts (panic 0x11) once `raw = num/den ≳ 2^64`, since `raw * 2^192`
    ///          then exceeds `type(uint256).max`. The largest representable `ratioX192 ≈ 2^256`
    ///          therefore yields `s = sqrt(ratioX192) ≤ 2^128`, far below `MAX_SQRT_RATIO (~2^160)`
    ///          — `s >= MAX_SQRT_RATIO` can never hold, so a high-side check would be dead code.
    ///        - LOW bound is LOAD-BEARING: a tiny-but-nonzero `raw` yields a small `sqrt(ratioX192)`
    ///          that is `< MIN_SQRT_RATIO` yet nonzero — `uint160(...)` does NOT truncate it,
    ///          so without the explicit check below it would slip through as a valid-looking
    ///          out-of-range price. The bound catches it.
    ///      For all real cbBTC/WETH 8dp prices the result lands well inside the range; this
    ///      guard only fires for the degenerate/hostile decimal+price combinations a generic
    ///      caller could pass.
    function oracleSqrtPriceX96(uint256 p0, uint8 d0, uint256 p1, uint8 d1)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        uint256 num = p0 * (10 ** uint256(d1));
        uint256 den = p1 * (10 ** uint256(d0));
        uint256 ratioX192 = Math.mulDiv(num, 1 << 192, den);
        uint256 s = Math.sqrt(ratioX192);
        // LOW-bound guard only — the HIGH bound is unreachable (mulDiv overflow-reverts first; see
        // @dev). Revert rather than pass a nonzero sub-range price that `uint160(...)` won't truncate.
        if (s < TickMath.MIN_SQRT_RATIO) revert OracleSqrtPriceOutOfRange();
        sqrtPriceX96 = uint160(s);
    }

    // ---------------------------------------------------------------------------
    // Range geometry + ASSET-MODE deploy sizing
    // ---------------------------------------------------------------------------

    /// @notice The Moonwell USDC collateral factor in bps, read from `Comptroller.markets(mUsdc_)` at
    ///         init. Fail-closed: a failed/short call or a zero factor reverts `ComptrollerCallFailed`.
    /// @dev The ABI is `(bool isListed, uint256 collateralFactorMantissa, ...)` — read the 2nd word
    ///      (1e18-scaled). Relocated out of `LeveragedAerodromeCLStrategy` for EIP-170 headroom; the
    ///      `staticcall` is context-free (no storage, no msg.sender dependence), so running it in the
    ///      caller's frame under delegatecall is identical. Selector shared with the strategy.
    function readCollateralFactor(address comptroller_, address mUsdc_) public view returns (uint16 cfBps) {
        (bool ok, bytes memory ret) = comptroller_.staticcall(abi.encodeWithSignature("markets(address)", mUsdc_));
        if (!ok || ret.length < 64) revert ComptrollerCallFailed();
        uint256 cfMantissa;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            cfMantissa := mload(add(ret, 0x40))
        }
        cfBps = uint16(cfMantissa / 1e14); // 0.88e18 / 1e14 = 8800
        if (cfBps == 0) revert ComptrollerCallFailed();
    }

    /// @notice The INIT-ONLY shape check on the two governance bands themselves — the bounds every later
    ///         `checkRange` is measured against, fixed for the clone's life.
    /// @dev WIDTH BAND: both bounds on the `tickSpacing_` grid, `minWidth_ >= 2 × spacing` (so an aligned
    ///      range is never empty), `minWidth_ <= maxWidth_`, and `maxWidth_` inside the tick domain —
    ///      `skewedTickRange` spans up to `width` ticks on ONE side of the pool tick (the skew limit), so
    ///      a wider band could only ever produce out-of-domain bounds (and, at the uint24 extreme, an
    ///      int24 wrap in the `currentTick ± span` arithmetic).
    ///
    ///      SKEW BAND: `0 < minSkewBps_ <= maxSkewBps_ < 10000` — the band can only ever TIGHTEN the open
    ///      `(0, 1e4)` interval `checkRange` enforces, never widen it.
    ///
    ///      Lives here, beside `checkRange`, for the same EIP-170 reason: the strategy is at the cap.
    function checkBands(int24 tickSpacing_, uint24 minWidth_, uint24 maxWidth_, uint16 minSkewBps_, uint16 maxSkewBps_)
        public
        pure
    {
        if (tickSpacing_ <= 0) revert OutOfBounds();
        uint24 spacing = uint24(tickSpacing_);
        if (minWidth_ % spacing != 0 || maxWidth_ % spacing != 0) revert OutOfBounds();
        if (uint256(minWidth_) < 2 * uint256(spacing)) revert OutOfBounds();
        if (minWidth_ > maxWidth_) revert OutOfBounds();
        if (uint256(maxWidth_) > 2 * uint256(uint24(TickMath.MAX_TICK))) revert OutOfBounds();
        if (minSkewBps_ == 0 || minSkewBps_ > maxSkewBps_ || maxSkewBps_ >= 10000) revert OutOfBounds();
    }

    /// @notice The four VENUE-SCOPED risk invariants, in one place: the LTV band's own shape and its
    ///         relationship to the destination market's collateral factor. Shared by `checkRiskParams`
    ///         (the init ladder) and `LeveragedAeroVenue.applyVenue` (which re-runs them at every
    ///         `migrateVenue` against the NEW markets' live CF) — the two cannot drift.
    /// @dev L4 (the `minHealthBps × maxLtvBps` rung): the permissionless deleverage triggers at
    ///      `LTV = 1e8 / minHealthBps`; that trigger LTV MUST sit strictly above `maxLtvBps`, else there
    ///      is an in-band range anyone can grief-deleverage. Cross-multiplied to stay overflow-free.
    /// @param cfBps The Moonwell USDC collateral factor (bps) the caller read for the target markets.
    function checkLtvBand(uint16 targetLtvBps, uint16 maxLtvBps, uint16 minHealthBps, uint16 cfBps) public pure {
        if (targetLtvBps > maxLtvBps) revert TargetLtvExceedsMax();
        if (minHealthBps < 10500) revert MinHealthTooLow();
        if (maxLtvBps >= cfBps) revert MaxLtvExceedsCF();
        if (uint256(minHealthBps) * uint256(maxLtvBps) >= 1e8) revert MinHealthMaxLtvConflict();
    }

    /// @notice The INIT-ONLY numeric ladder over the risk, oracle and fee params, in the order the
    ///         strategy used to run it inline (the order is observable — each rung has its own typed
    ///         error, and the init suite pins which one fires).
    /// @dev Relocated out of `LeveragedAerodromeCLStrategy._initialize` for EIP-170 headroom, unchanged
    ///      rung for rung. Every error is re-declared in this library with the SAME signature, so the
    ///      selectors a caller sees are identical to the strategy's own declarations.
    ///
    ///      L4 (the `minHealthBps × maxLtvBps` rung): the permissionless deleverage triggers at
    ///      `LTV = 1e8 / minHealthBps`; that trigger LTV MUST sit strictly above `maxLtvBps`, else there
    ///      is an in-band range anyone can grief-deleverage. Cross-multiplied to stay overflow-free.
    ///
    ///      L3 (+L5), the oracle rungs — bound each knob so a misconfig cannot silently disable a guard.
    ///      The bounds admit the confirmed config yet block degenerate values:
    ///        maxDelay           ∈ (0, 7 days] — a huge value disables staleness detection
    ///        gracePeriod        ∈ [0, 1 days] — sequencer-restart grace
    ///        twapWindow         ∈ (0, 1 days] — 0 disables the TWAP / calm-gate
    ///        calmDeviationTicks ∈ (0, 5000]   — a huge value disables the calm-gate
    ///        maxSlippageBps     ∈ (0, 1000]   — 0 or huge disables swap-slippage protection (10% cap)
    ///
    ///      The FEE rungs are a separate call (`checkFeeParams`) rather than three more parameters here:
    ///      a 12-argument version of this function put the caller's frame one slot too deep for the Yul
    ///      stack allocator. Order across the two calls is the original order.
    /// @param cfBps The Moonwell USDC collateral factor (bps) the caller read at init.
    function checkRiskParams(
        uint16 targetLtvBps,
        uint16 maxLtvBps,
        uint16 minHealthBps,
        uint16 cfBps,
        uint256 maxDelay,
        uint256 gracePeriod,
        uint32 twapWindow,
        uint16 calmDeviationTicks,
        uint16 maxSlippageBps
    ) public pure {
        checkLtvBand(targetLtvBps, maxLtvBps, minHealthBps, cfBps);
        if (maxDelay == 0 || maxDelay > 7 days) revert OracleParamOutOfRange();
        if (gracePeriod > 1 days) revert OracleParamOutOfRange();
        if (twapWindow == 0 || twapWindow > 1 days) revert OracleParamOutOfRange();
        if (calmDeviationTicks == 0 || calmDeviationTicks > 5000) revert OracleParamOutOfRange();
        if (maxSlippageBps == 0 || maxSlippageBps > 1000) revert OracleParamOutOfRange();
    }

    /// @notice The INIT-ONLY fee rungs: a non-zero rate needs a recipient, and M3 puts a hard ceiling on
    ///         both rates (performance mirrors the protocol-wide cap, management the factory's 5%/yr —
    ///         `SyndicateFactory.MAX_MANAGEMENT_FEE_BPS`).
    /// @dev The tail of `checkRiskParams`' ladder, split off only to keep the caller's stack inside the
    ///      Yul allocator's reach. Selectors match the strategy's own declarations.
    function checkFeeParams(uint16 managementFeeBps, uint16 performanceFeeBps, address feeRecipient) public pure {
        if ((managementFeeBps != 0 || performanceFeeBps != 0) && feeRecipient == address(0)) {
            revert FeeRecipientRequired();
        }
        if (performanceFeeBps > FeeConstants.MAX_PERFORMANCE_FEE_BPS) revert PerformanceFeeTooHigh();
        if (managementFeeBps > 500) revert ManagementFeeTooHigh();
    }

    /// @notice THE ONE PREDICATE that validates a `(width, skewBps)` pair before `skewedTickRange`
    ///         consumes it — shared by `LeveragedAerodromeCLStrategy._initialize` (the genesis pair) and
    ///         `LeveragedAerodromeCLStrategy.rerange` (each per-cycle pair), so the two entrypoints
    ///         cannot drift. Lives HERE rather than in the strategy purely for EIP-170 headroom: the
    ///         strategy is at the cap and this library has room.
    ///
    /// @dev WIDTH: on the `tickSpacing_` grid and inside `[minWidth_, maxWidth_]`. The band itself is
    ///      validated once at init (multiples, `minWidth_ >= 2 × spacing`, min ≤ max, `maxWidth_` inside
    ///      the tick domain).
    ///
    ///      SKEW: `skewBps_` is the fraction of `width_` placed BELOW the pool tick on a 1e4 scale, so
    ///      5000 is centred; the complement goes above. It must be inside the OPEN `(0, 10000)` interval,
    ///      inside the governance band `[minSkewBps_, maxSkewBps_]` (validated at init as
    ///      `0 < minSkewBps_ <= maxSkewBps_ < 10000`, so the band can only ever tighten the open
    ///      interval, never widen it), and leave both spans at least one spacing.
    ///
    ///      THE SPAN GUARD IS SPAN-BASED, NOT A FLAT bps BAND, ON PURPOSE: a flat band cannot protect
    ///      small widths (at `width == 2 × tickSpacing` even a mild 2500 skew starves the lower side to
    ///      half a spacing, while at `width == 200 × tickSpacing` a 100-bps skew is perfectly safe). BOTH
    ///      sides must span at least one `tickSpacing`, or the DOWN-aligned range stops STRICTLY
    ///      BRACKETING the pool tick (`tickLower <= tick < tickUpper`) — the invariant `assetModeSplit`
    ///      relies on to size a fresh range two-sided, and the reason a one-sided range is a fail-closed
    ///      `DegenerateRange`.
    ///
    ///      QUANTIZATION CLIFF, the operator-facing consequence: the USABLE skew set widens with
    ///      `width_ / tickSpacing_`. At the floor (`width_ == 2 × tickSpacing_`) the only geometry
    ///      satisfying both spans is the centred one, so skew is effectively pinned to ~5000 there;
    ///      meaningful skew needs `width_ >= 3 × tickSpacing_`, and a governance band whose whole
    ///      interior is unreachable at the configured width will simply refuse every rerange.
    function checkRange(
        uint24 width_,
        uint16 skewBps_,
        int24 tickSpacing_,
        uint24 minWidth_,
        uint24 maxWidth_,
        uint16 minSkewBps_,
        uint16 maxSkewBps_
    ) public pure {
        if (tickSpacing_ <= 0) revert OutOfBounds();
        if (width_ % uint24(tickSpacing_) != 0) revert OutOfBounds();
        if (width_ < minWidth_ || width_ > maxWidth_) revert OutOfBounds();
        if (skewBps_ == 0 || skewBps_ >= 10000) revert OutOfBounds();
        if (skewBps_ < minSkewBps_ || skewBps_ > maxSkewBps_) revert OutOfBounds();
        uint256 lowerSpan = (uint256(width_) * uint256(skewBps_)) / 10000;
        uint256 upperSpan = uint256(width_) - lowerSpan; // exact complement, matching `skewedTickRange`
        uint256 spacing = uint256(uint24(tickSpacing_));
        if (lowerSpan < spacing || upperSpan < spacing) revert OutOfBounds();
    }

    /// @notice The tickSpacing-aligned range around `pool`'s current tick, SKEWED by `skewBps`: that
    ///         fraction of `width` (1e4 scale) is placed BELOW the current tick and the exact complement
    ///         above. `skewBps == 5000` is the centred range (and reproduces the old `centeredTickRange`
    ///         bit-for-bit whenever `width` is even); `3500` puts 35% of the width below spot and 65%
    ///         above. Lives here (rather than in `LeveragedAeroManager`, which is at the EIP-170 margin)
    ///         alongside `assetModeSplit`, the sizing math that consumes it.
    ///
    /// @dev The two spans are EXACT COMPLEMENTS — `upperSpan = width − lowerSpan` — so the nominal range
    ///      is always exactly `width` ticks wide before alignment, with no double rounding.
    ///
    ///      Placement is grid-approximate, not exact. Both bounds round DOWN onto the grid, so the
    ///      realised split can sit up to one `tickSpacing` below the requested one and the realised
    ///      width can differ from `width` by up to one spacing; when a span is not itself a multiple of
    ///      the spacing that is where the drift is largest. Accepted: the band is orders of magnitude
    ///      wider than one spacing, and placing exactly would need an align-up on one side, silently
    ///      widening the range past the band validated at init.
    ///
    ///      Both bounds are clamped into the aligned tick domain: `width` is capped at `2 × MAX_TICK` at
    ///      init, so with the whole width now landing on ONE side in the limit the arithmetic is
    ///      `currentTick ± width` (not `± width/2`) — worst case `|tc| + width <= MAX_TICK + 2 ×
    ///      MAX_TICK ≈ 2.66e6`, still far inside int24's ±8.39e6, so it cannot wrap. A wide band near
    ///      either end of the domain still pushes a bound past ±MAX_TICK, where `getSqrtRatioAtTick`
    ///      would revert unhelpfully deep inside TickMath. `maxAligned` sits ON the spacing grid by
    ///      construction, so clamping keeps the range mintable rather than merely non-panicking.
    ///
    ///      The returned range STRICTLY BRACKETS the current tick (`tickLower <= tick < tickUpper`)
    ///      whenever BOTH spans are at least one `tickSpacing` — which is exactly what the caller's
    ///      `checkRange` enforces (the old, skew-free guarantee was the `width >= 2 × tickSpacing`
    ///      special case of it). That is what makes a freshly ranged position two-sided, and therefore
    ///      always sizeable by `assetModeSplit`.
    ///
    ///      Callers must calm-gate BEFORE this: it reads the manipulable spot tick.
    function skewedTickRange(address pool, int24 tickSpacing, uint24 width, uint16 skewBps)
        public
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        (, int24 currentTick,,,,) = ICLPool(pool).slot0();
        uint256 lowerSpan = (uint256(width) * uint256(skewBps)) / 10000;
        uint256 upperSpan = uint256(width) - lowerSpan; // exact complement — no double rounding
        tickLower = _alignTick(currentTick - int24(uint24(lowerSpan)), tickSpacing);
        tickUpper = _alignTick(currentTick + int24(uint24(upperSpan)), tickSpacing);
        int24 maxAligned = _alignTick(TickMath.MAX_TICK, tickSpacing);
        if (tickLower < -maxAligned) tickLower = -maxAligned;
        if (tickUpper > maxAligned) tickUpper = maxAligned;
        if (tickUpper <= tickLower) tickUpper = tickLower + tickSpacing;
    }

    /// @dev Align `tick` down to the nearest multiple of `spacing` (handles negatives).
    function _alignTick(int24 tick, int24 spacing) private pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }

    /// @notice THE §8 ALWAYS-ON TWO-SIDED SLIPPAGE FLOOR for a CL mint / increaseLiquidity, defined in
    ///         exactly one place. Given the desired deposit `(amt0, amt1)` at the calm-gated `sqrtP`,
    ///         returns the amounts the position would ACTUALLY consume, haircut by `slippageBps`.
    ///
    /// @dev Logic is verbatim what `LeveragedAeroManager._mintPosition` and `_addLiquidity` each had
    ///      inline; extracted so the floor has ONE definition (the two copies could drift) and so the
    ///      manager — at the EIP-170 margin — stops inlining `LiquidityAmounts` twice over. Callers must
    ///      calm-gate before sourcing `sqrtP`; a caller may layer an ADDITIONAL explicit guard on the
    ///      consumed amounts on top of this (as `rerange` does with `minLiq0`/`minLiq1`).
    /// @param sqrtP       Current pool sqrt price (Q64.96), read behind the calm-gate.
    /// @param tickLower   Lower tick of the target range.
    /// @param tickUpper   Upper tick of the target range.
    /// @param amt0        Desired token0 deposit (POSITIONAL — pool ordering).
    /// @param amt1        Desired token1 deposit (POSITIONAL).
    /// @param slippageBps `maxSlippageBps`; bounded to (0, 1000] at init so `10000 - slippageBps`
    ///                    cannot underflow.
    function depositMins(
        uint160 sqrtP,
        int24 tickLower,
        int24 tickUpper,
        uint256 amt0,
        uint256 amt1,
        uint256 slippageBps
    ) public pure returns (uint256 amt0Min, uint256 amt1Min) {
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, amt0, amt1);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, liquidity);
        amt0Min = exp0 * (10000 - slippageBps) / 10000;
        amt1Min = exp1 * (10000 - slippageBps) / 10000;
    }

    /// @notice ASSET-MODE deploy sizing, closed form. Splits an incoming USDC `amount` into the
    ///         collateral portion `C` (supplied to Moonwell) and the LP-side portion `U` (kept for the
    ///         mint), such that the leg-A amount borrowed against `C` at `targetLtvBps` pairs with `U`
    ///         at EXACTLY the ratio the range `[tickLower, tickUpper]` requires at the pool's current
    ///         `sqrtP`. `C + U == amount` by construction.
    ///
    ///         Only reachable in asset-mode (leg-B slot == USDC — a legA/USDC pool). The two-borrowed-
    ///         legs shape does not call this: it splits the borrow 50/50 by USD and supplies the whole
    ///         deposit as collateral.
    ///
    /// @dev DERIVATION. Let `needA : needU` be the (leg A : USDC) token-amount ratio the range
    ///      requires at the current `sqrtP` — obtained by probing `getAmountsForLiquidity` at a
    ///      reference liquidity and mapping token0/token1 onto the legs (both amounts are linear in L
    ///      for a fixed range + sqrtP, so the reference cancels out of the ratio).
    ///
    ///      The borrow is sized off `C` exactly as `LeveragedAeroManager._borrowLegA` executes it
    ///      (the two MUST agree or the mint is left with a residual):
    ///
    ///        borrowUsd6 = C · targetLtvBps / 1e4                                     (USDC face, 6dp)
    ///        A          = borrowUsd6 · 100 · 10^dA / pA = C · targetLtvBps · 10^dA / (100 · pA)
    ///
    ///      (`× 100` lifts 6dp USDC face to the feed's 8dp USD; USDC face is taken as USD 1:1 here,
    ///      matching `_borrowHalfEach`.) Requiring the pair to land on the range ratio:
    ///
    ///        A / U = needA / needU     and     U = amount − C
    ///
    ///        ⇒ C · targetLtvBps · 10^dA · needU = (amount − C) · needA · 100 · pA
    ///        ⇒ C · [targetLtvBps·10^dA·needU + 100·pA·needA] = amount · 100·pA·needA
    ///        ⇒ C = amount · w / (w + x),   w = 100·pA·needA,   x = targetLtvBps·10^dA·needU
    ///
    ///      Worked check (cbBTC/USDC, pA = 1e13 i.e. $100k, dA = 8, targetLtvBps = 5000, a range whose
    ///      required amounts are 50/50 by value ⇒ needU = 1000·needA): w = 1e15·needA,
    ///      x = 5e14·needA ⇒ C = ⅔·amount, U = ⅓·amount, borrowUsd6 = ⅓·amount. LP legs are ⅓/⅓ by
    ///      value (balanced ✓) and LTV = (⅓)/(⅔) = 50% = target ✓.
    ///
    ///      OVERFLOW. `needA`/`needU` are bounded by `MAX_SQRT_RATIO` (~1.5e48) at the reference
    ///      liquidity, so `w ≲ 1e2 · pA · 1.5e48` and `x ≲ 1e4 · 1e18 · 1.5e48 ≈ 1.5e70`; both and
    ///      their sum stay inside uint256 for any Chainlink 8dp price below ~1e22 ($1e14/token). The
    ///      `Math.mulDiv` carries the `amount · w` product in 512 bits. An out-of-band price would
    ///      revert (panic 0x11) rather than wrap — fail-closed.
    ///
    ///      RATIO BASIS. `needA:needU` comes from the POOL's live `sqrtP` (what the NPM will actually
    ///      consume) while the borrow converts at the CHAINLINK price `pA`. A pool/oracle divergence
    ///      therefore leaves a small residual of one side idle after the mint — NAV-counted and
    ///      redeployable, never a solvency issue. Callers run the calm-gate before this so `sqrtP`
    ///      cannot be a shoved tick.
    ///
    /// @param pool           The Slipstream CL pool (read for the live `sqrtP`).
    /// @param tickLower      Lower tick of the range the mint/add will target.
    /// @param tickUpper      Upper tick of that range.
    /// @param amount         Total USDC (6dp) to split.
    /// @param targetLtvBps   Target LTV in bps that sizes the borrow against `C`.
    /// @param legADecimals   Leg-A token decimals.
    /// @param legAIsToken0   True when leg A sorts as the pool's token0 (`Layout.wethIsToken0`).
    /// @param legAPrice8     Leg-A USD price, 8dp, from a hardened Chainlink read.
    /// @return collateralUsdc `C` — USDC to supply as Moonwell collateral.
    /// @return lpUsdc         `U` — USDC to hold back for the LP mint (`amount − C`).
    /// @return legABorrow     `A` — leg-A units to borrow. Returned from HERE, not recomputed by the
    ///                        caller, so the borrow can never drift from the derivation that sized `U`.
    function assetModeSplit(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount,
        uint256 targetLtvBps,
        uint8 legADecimals,
        bool legAIsToken0,
        uint256 legAPrice8
    ) public view returns (uint256 collateralUsdc, uint256 lpUsdc, uint256 legABorrow) {
        (uint256 needA, uint256 needU) = _rangeRatio(pool, tickLower, tickUpper, legAIsToken0);

        uint256 unit = 10 ** uint256(legADecimals);
        uint256 w = 100 * legAPrice8 * needA;
        uint256 x = targetLtvBps * unit * needU;
        collateralUsdc = Math.mulDiv(amount, w, w + x);
        // `C == 0` (dust `amount`, or a range so USDC-heavy the borrow rounds away) would supply no
        // collateral and borrow nothing; `C >= amount` would leave no USDC for the pair. Neither can
        // produce the intended delta-hedged position.
        if (collateralUsdc == 0 || collateralUsdc >= amount) revert DegenerateRange();
        lpUsdc = amount - collateralUsdc;
        // The borrow, in leg-A units — the SAME `borrowUsd6 · 100 · 10^dA / pA` conversion
        // `_borrowHalfEach` applies per leg, un-halved. Computed here (not in the manager) so the two
        // sides of `A / U = needA / needU` are produced by one expression and cannot diverge.
        legABorrow = _legABorrow(collateralUsdc * targetLtvBps / 10000, unit, legAPrice8);
    }

    /// @notice ASSET-MODE **lever-up** sizing, closed form. Given a debt delta `borrowUsd6` (USDC face,
    ///         6dp) that a `adjustLeverage` retarget wants to add against UNCHANGED collateral, returns
    ///         the leg-A units to borrow and the USDC that must pair with them in the range
    ///         `[tickLower, tickUpper]` — reverting `InsufficientIdleForLeverUp` if the book's idle USDC
    ///         (`idleUsdc`, passed by the caller) cannot fund that pairing.
    ///
    /// @dev THE PAIRING RELATION IS THE SAME ONE `assetModeSplit` SOLVES — only the unknown differs.
    ///      `assetModeSplit` is handed a total `amount` and solves for the split point `C` such that the
    ///      borrow against `C` pairs with `amount − C`. A lever-up has NO new deposit to split: the debt
    ///      delta is already fixed by `targetLtvBps_ × collateral` (collateral is untouched by contract),
    ///      so `A` is determined outright and `U′` is simply read off the same range ratio:
    ///
    ///        A  = borrowUsd6 · 100 · 10^dA / pA                (the un-halved `_borrowHalfEach` convert)
    ///        U′ = A · needU / needA                            (the range's required (legA : USDC) ratio)
    ///
    ///      Both `needA:needU` and the `A` conversion come from the SAME helpers `assetModeSplit` uses
    ///      (`_rangeRatio`, `_legABorrow`), so the two entrypoints cannot drift apart. Substituting
    ///      `A(C·ltv)` into `U′` reproduces `assetModeSplit`'s `U = amount − C` exactly, which is the
    ///      algebraic statement that a lever-up to `targetLtvBps` lands the same leg ratio genesis does.
    ///
    ///      `U′` IS DRAWN FROM IDLE USDC, and this is where that requirement is ENFORCED (the bound lives
    ///      with the arithmetic that produced `U′`, and the manager calls this BEFORE its borrow, so a
    ///      short book reverts with nothing touched). See `LeveragedAeroManager._leverUp` for WHY the
    ///      pairing must be idle-funded rather than funded by swapping part of the borrow, and for the
    ///      operator consequence (idle moves into the LP, shrinking the redeem cover budget).
    ///      Deliberately NOT a partial fill and NOT a silent cap — a quietly under-levered position is
    ///      worse for a rebalancer than a loud, diagnosable `(needed, available)` refusal. (Through the
    ///      manager the corrected draw is provably < raw + collateral, so this bound is defence in
    ///      depth for DIRECT library callers; the manager's realistic funding failure is Moonwell
    ///      refusing the mid-op redeem — see `_leverUp`.)
    ///
    ///      Ratio basis / overflow / one-sided-range behaviour are exactly `assetModeSplit`'s (shared
    ///      `_rangeRatio`): the pool's live `sqrtP` (calm-gate is the caller's job), `Math.mulDiv` for
    ///      the 512-bit intermediate, and `DegenerateRange` when the stored range is one-sided.
    ///      ── THE COLLATERAL-FUNDED CORRECTION (`targetLtvBps`) ──
    ///
    ///      The relation above is exact only while `U′` comes from a NAV component that is NOT
    ///      collateral. That was true when idle USDC could only sit as a raw ERC-20 balance. It is no
    ///      longer: the proposer's `supplyIdle` parks idle USDC in Moonwell, so on a book the keeper
    ///      has swept there is no raw balance and the ONLY place `U′` can come from is a
    ///      `redeemUnderlying` off the mUSDC collateral — and that SHRINKS the
    ///      collateral the LTV is measured against. Sizing the naive `Δ = ltv·C − D` and then pulling
    ///      `U′` out of `C` lands the book at `Δ / (C − U′) > ltv` — for a roughly centred range
    ///      `U′ ≈ Δ`, so the overshoot is order `ltv·Δ/C`, big enough to trip `_assertHealthy`'s
    ///      `maxLtvBps` on an aggressive target. So the delta is solved as a FIXED POINT instead.
    ///
    ///      Write `U′ = m·Δ` (both legs of the pairing are linear in `Δ`, so `m` is the constant
    ///      `u0/borrowUsd6` read off the naive probe). Requiring the POST-op book to sit at target,
    ///
    ///        Δ + D = ltv · (C − U′)  with  D = ltv·C − borrowUsd6   ⇒   Δ = borrowUsd6 / (1 + ltv·m)
    ///
    ///      (stated here for a book with no raw USDC; the general form credits whatever raw balance is
    ///      there and is derived in the next paragraph — it is what the code actually computes)
    ///
    ///      which is what the two `mulDiv`s below compute (`1e4` carries the bps scale). Both `A` and
    ///      `U′` are scaled by the same factor, so the range ratio `A : U′` is untouched — the
    ///      correction only decides HOW MUCH to lever, never the shape of the pair.
    ///
    ///      IT AGREES WITH GENESIS, EXACTLY. Substituting a flat book (`D = 0`, `borrowUsd6 = ltv·C`)
    ///      gives post-op collateral `C − m·Δ = C/(1 + ltv·m)` and debt `ltv·C/(1 + ltv·m)` — i.e. the
    ///      SAME split point `assetModeSplit` produces for `amount = C`, and post-op LTV exactly `ltv`.
    ///      So `deposit` + `adjustLeverage` and `deposit` + `deployIdle` land the same book, and
    ///      `_assertHealthy` sees a book at target rather than one the sizing overshot.
    ///
    ///      RAW IDLE IS CREDITED, so the correction is EXACT IN BOTH REGIMES rather than a blanket
    ///      pessimism. Only the part of `U′` the raw balance cannot cover comes out of collateral, so
    ///      with a raw balance `R` the requirement is `Δ + D = ltv·(C − (U′ − R))`, whose solution
    ///      carries `ltv·R` in the numerator: `Δ = (borrowUsd6 + ltv·R) / (1 + ltv·m)`. Two consequences
    ///      worth stating, because they are what makes this a pure EXTENSION of the old contract:
    ///        - `R ≥ U′` (the pre-supply world, and any book still holding a rerange remainder or an
    ///          IL-cover leftover) drives the scale factor to ≥ 1, where it is CLAMPED to 1 — the
    ///          uncorrected `Δ = borrowUsd6`, collateral untouched, post-op LTV exactly `ltv`. Byte-for-
    ///          byte the behaviour this function had before the correction existed.
    ///        - `R = 0` (a book the keeper has fully swept into mUSDC) is the pure collateral-funded
    ///          case above.
    ///      The clamp is not a safety valve, it is the boundary of the piecewise solution: past `R = U′`
    ///      the collateral draw is zero and cannot go negative, so scaling UP would over-pair.
    /// @param pool           The Slipstream CL pool (read for the live `sqrtP`).
    /// @param tickLower      Lower tick of the STORED range the add will target.
    /// @param tickUpper      Upper tick of that range.
    /// @param borrowUsd6     The NAIVE debt delta (`ltv·C − D`, USDC face 6dp) the caller wants to add;
    ///                       corrected below for the collateral `U′` will consume.
    /// @param availableUsdc  USDC the strategy can fund `U′` from — raw balance PLUS the mUSDC
    ///                       collateral it can redeem (`usdcAvailable`). The caller materialises the
    ///                       raw shortfall AFTER this returns and BEFORE the borrow.
    /// @param rawUsdc        The raw ERC-20 USDC balance alone — the part of `U′` that costs no
    ///                       collateral. `≤ availableUsdc` by construction.
    /// @param targetLtvBps   The fund's standing target LTV (bps) — the fixed-point coefficient above.
    /// @param legADecimals   Leg-A token decimals.
    /// @param legAIsToken0   True when leg A sorts as the pool's token0 (`Layout.wethIsToken0`).
    /// @param legAPrice8     Leg-A USD price, 8dp, from a hardened Chainlink read.
    /// @return legABorrow    `A` — leg-A units to borrow.
    /// @return lpUsdc        `U′` — USDC that must pair with `A` in the range (≤ `availableUsdc`).
    function assetModeLeverUpPair(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 borrowUsd6,
        uint256 availableUsdc,
        uint256 rawUsdc,
        uint256 targetLtvBps,
        uint8 legADecimals,
        bool legAIsToken0,
        uint256 legAPrice8
    ) public view returns (uint256 legABorrow, uint256 lpUsdc) {
        (uint256 needA, uint256 needU) = _rangeRatio(pool, tickLower, tickUpper, legAIsToken0);
        // The naive probe: `A0` for the un-corrected delta, and the `U′0` the range demands beside it.
        uint256 a0 = _legABorrow(borrowUsd6, 10 ** uint256(legADecimals), legAPrice8);
        uint256 u0 = Math.mulDiv(a0, needU, needA);
        // Fixed-point rescale by `(b + ltv·R) / (b + ltv·u0)` (see the @dev derivation; `10_000` carries
        // the bps scale on both sides). `den > 0`: the manager only levers UP when the delta is strictly
        // positive, so `borrowUsd6 > 0`. The clamp is the `R ≥ U′` branch of the piecewise solution.
        uint256 den = 10_000 * borrowUsd6 + targetLtvBps * u0;
        uint256 num = 10_000 * borrowUsd6 + targetLtvBps * rawUsdc;
        if (num > den) num = den;
        legABorrow = Math.mulDiv(a0, num, den);
        lpUsdc = Math.mulDiv(u0, num, den);
        if (lpUsdc > availableUsdc) revert InsufficientIdleForLeverUp(lpUsdc, availableUsdc);
    }

    /// @notice USDC the strategy can spend RIGHT NOW without touching the LP: its raw ERC-20 balance
    ///         PLUS what its Moonwell mUSDC collateral is worth (both 6dp face).
    /// @dev THE FUNDING BASIS FOR "NO IDLE USDC SITS DEAD". The proposer's `supplyIdle` can put any
    ///      or all of the raw balance into Moonwell, so the raw balance is no longer a reliable measure
    ///      of what the book can spend, and every site that used to bound itself by
    ///      `IERC20(usdc).balanceOf(this)` — `deployIdle`'s `InsufficientIdle`,
    ///      `execute`/`redeploy`'s `ExecuteZeroBalance`, the asset-mode lever-up
    ///      pairing — must bound itself by THIS instead, then materialise the raw shortfall via
    ///      `redeemUnderlying`. Oracle-free by construction: USDC is the unit of account and the
    ///      collateral term is the same `balanceOf × exchangeRateStored / 1e18` the NAV and the health
    ///      basis already use, so nothing here can fail closed on a down feed.
    ///
    ///      ALSO THE FLAT-BOOK NAV TERM. `LeveragedAerodromeCLStrategy.nav()` prices a `tokenId == 0`
    ///      book off this function rather than off the raw balance alone. That is not an enhancement,
    ///      it is REQUIRED: `supplyIdle` works on a flat book (post-`flatten`, post-full-redeem) — the
    ///      state holding the most dead USDC — and the old raw-balance branch would then have priced
    ///      the whole fund at 0, minting the next depositor an unbacked claim and reverting every
    ///      one after that on `NavUnpriceable`. Debt is deliberately NOT subtracted here: it is not
    ///      subtracted by the branch this replaces either, and a flat book has none (both `flatten`
    ///      and `settleImpl` clear every borrow before releasing the collateral).
    /// @param usdc  The unit of account.
    /// @param mUsdc Moonwell USDC market.
    /// @param who   Account to read (always the strategy clone).
    function usdcAvailable(address usdc, address mUsdc, address who) public view returns (uint256) {
        return IERC20(usdc).balanceOf(who) + _collateralUnderlying(mUsdc, who);
    }

    // ── Slipstream swap plumbing ──

    /// @notice Slipstream `exactInputSingle` (plus the approval), as ONE definition.
    /// @dev VENUE PLUMBING ONLY — every decision stays with the caller: which token, how much (and the
    ///      caps that bound it), and what `minOut` bound applies. `LeveragedAeroManager` calls this from
    ///      `_sweepLegToUsdc` AFTER its identity guard / balance cap, and `_spendLeg` below calls it for
    ///      the interest-drift buy, so the `ExactInputSingleParams`
    ///      construction exists once instead of twice. Relocated out of the manager for EIP-170
    ///      headroom; a 6-argument flat surface is why it is a net saving there.
    /// @param router      Slipstream CL SwapRouter.
    /// @param tokenIn     Token sold. Never equal to `tokenOut` — callers guard the identity case.
    /// @param tokenOut    Token bought.
    /// @param tickSpacing tickSpacing of the `tokenIn`↔`tokenOut` SWAP pool (NOT any LP pool's).
    /// @param amountIn    Exact input (callers have already capped this against a live balance).
    /// @param minOut      Minimum output; 0 only where an aggregate guard covers the caller.
    function swapExactIn(
        address router,
        address tokenIn,
        address tokenOut,
        int24 tickSpacing,
        uint256 amountIn,
        uint256 minOut
    ) public {
        IERC20(tokenIn).forceApprove(router, amountIn);
        ICLSwapRouter(router).exactInputSingle(
            ICLSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Slipstream `exactOutputSingle` (approve, swap, then RESET the approval to 0).
    /// @dev The mirror of `swapExactIn`, same division of labour: this is plumbing, and the caller owns
    ///      the decisions — `LeveragedAeroManager._redeemCoverShortfall` derives `amountInMax` (the
    ///      redeemer's own budget, an oracle+slippage ceiling, or unbounded on a full redeem) and does the
    ///      repay. The trailing `forceApprove(router, 0)` is load-bearing and part of the primitive: an
    ///      exact-output swap generally spends LESS than `amountInMax`, so the residue would otherwise be
    ///      left standing as an allowance to the router — and it must run on BOTH branches below, or a
    ///      swallowed failure would leave the whole `amountInMax` standing as an allowance.
    ///
    ///      `bestEffort` EXISTS BECAUSE AN EXACT-OUTPUT SWAP HAS NO PARTIAL FILL. When the budget
    ///      (`amountInMax`, already clamped to the live balance by the caller) cannot buy `amountOut` the
    ///      router REVERTS — it does not buy what it can. On the covers that are OPPORTUNISTIC —
    ///      `redeemUnwindImpl`'s full-redeem Phase 1, which spends whatever oracle-free USDC happens to be
    ///      on hand and hands the residue to the oracle-priced Phase 2 — that revert bricked the entire
    ///      redeem, `emergencyRedeem` deadman included, across the whole band `0 < budget < needed`. That
    ///      band is NOT covered by the caller's `usdcBal == 0` guard, which is why the bug was invisible.
    ///      `bestEffort` turns the revert into `filled == false` and the caller falls through. Callers
    ///      whose cover is MANDATORY — a partial redeem's stayer-bounded budget, `_rebalanceCover`'s
    ///      oracle ceiling, `_settleShortfall`'s fail-closed cover — pass `false` and keep the revert.
    ///
    ///      THE `try` LIVES HERE, NOT AT THE CALL SITE. `LeveragedAeroManager` runs under DELEGATECALL, so
    ///      a `try` there cannot catch this library's internal frames; the ROUTER call is external from
    ///      THIS frame and is catchable. Hosting it here also keeps the bytes off the manager, which has
    ///      under 400 B of EIP-170 headroom. Same relocation rationale as `sweepFloors` / `coverBounds`.
    /// @param router      Slipstream CL SwapRouter.
    /// @param tokenIn     Token sold (the unit of account, at every current call site).
    /// @param tokenOut    Token bought. Never equal to `tokenIn` — callers guard the identity case.
    /// @param tickSpacing tickSpacing of the `tokenIn`↔`tokenOut` SWAP pool.
    /// @param amountOut   Exact output required.
    /// @param amountInMax Ceiling on the input; the swap reverts rather than exceeding it.
    /// @param bestEffort  When true an unfillable swap returns `false` instead of reverting.
    /// @return filled     True iff `amountOut` was bought (always true when `bestEffort` is false).
    function swapExactOut(
        address router,
        address tokenIn,
        address tokenOut,
        int24 tickSpacing,
        uint256 amountOut,
        uint256 amountInMax,
        bool bestEffort
    ) public returns (bool filled) {
        IERC20(tokenIn).forceApprove(router, amountInMax);
        ICLSwapRouter.ExactOutputSingleParams memory p = ICLSwapRouter.ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tickSpacing: tickSpacing,
            recipient: address(this),
            deadline: block.timestamp + 600,
            amountOut: amountOut,
            amountInMaximum: amountInMax,
            sqrtPriceLimitX96: 0
        });
        if (bestEffort) {
            try ICLSwapRouter(router).exactOutputSingle(p) returns (uint256) {
                filled = true;
            } catch {}
        } else {
            ICLSwapRouter(router).exactOutputSingle(p);
            filled = true;
        }
        IERC20(tokenIn).forceApprove(router, 0);
    }

    // ── Reward harvest (compound) ──

    /// @dev Aerodrome v2 (AMM) Router on Base — `compound`'s AERO→USDC swap routes through its volatile
    ///      pool, the deepest AERO/USDC liquidity on Base (~$10.4M vs ~$1.2M for the deepest Slipstream CL
    ///      pool, fork-measured). Canonical immutable Base infra. Lives HERE rather than in the manager
    ///      only because `swapAeroToUsdc` does, and that moved for the manager's EIP-170 budget.
    address private constant AERO_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    /// @dev Aerodrome v2 PoolFactory on Base (`router.defaultFactory()`), required by the Route.
    address private constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @notice The Aerodrome v2 VOLATILE pool `swapAeroToUsdc` would route `reward → usdc` through,
    ///         or `address(0)` when no such pool is registered.
    /// @dev Exists so venue validation can probe the reward leg the same way it probes the two
    ///      leg↔USDC CL swap pools. The route below is byte-for-byte the one `swapAeroToUsdc`
    ///      constructs (same factory, `stable == false`), so a nonzero answer here is exactly the
    ///      condition under which that swap can resolve a pool at all. Reads the factory rather than
    ///      the router's `poolFor` helper: the helper is a deterministic CREATE2 predictor and
    ///      returns a nonzero address for pairs that were never deployed.
    function aeroV2VolatilePool(address tokenA, address tokenB) public view returns (address) {
        return IAeroV2Factory(AERO_V2_FACTORY).getPool(tokenA, tokenB, false);
    }

    /// @notice Swap `amountIn` AERO to USDC through the Aerodrome v2 volatile pool and report the
    ///         MEASURED fill (balance delta, not the router's own return value).
    /// @dev Only the VENUE MECHANICS live here. The safety-critical parts of the harvest stay in
    ///      `LeveragedAeroManager.compoundImpl`: it derives the AERO/USD oracle floor, passes the
    ///      caller's `minUsdcOut` down as `minOut`, and post-checks the returned fill against
    ///      `max(minUsdcOut, floor)` — so a dishonest router return cannot widen the bound. Relocated out
    ///      of the manager (which is at the EIP-170 cap) because the `Route[]` construction plus this
    ///      venue interface is pure plumbing with a 4-argument surface, i.e. the cheapest possible move.
    /// @param aero     The gauge reward token (read from the gauge by the caller).
    /// @param usdc     The unit of account.
    /// @param amountIn AERO to sell (the whole claimed balance).
    /// @param minOut   Router-enforced minimum USDC out.
    /// @return usdcOut USDC actually received, measured as this call's own balance delta.
    function swapAeroToUsdc(address aero, address usdc, uint256 amountIn, uint256 minOut)
        public
        returns (uint256 usdcOut)
    {
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        IERC20(aero).forceApprove(AERO_V2_ROUTER, amountIn);
        IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
        routes[0] = IAeroRouter.Route({from: aero, to: usdc, stable: false, factory: AERO_V2_FACTORY});
        IAeroRouter(AERO_V2_ROUTER).swapExactTokensForTokens(
            amountIn, minOut, routes, address(this), block.timestamp + 600
        );
        usdcOut = IERC20(usdc).balanceOf(address(this)) - usdcBefore;
    }

    // ── Borrow-interest hedge (compound) ──

    /// @notice Everything `hedgeBorrowInterest` needs to neutralise interest drift on a WHOLE book.
    /// @dev ONE struct covering BOTH legs, and the library does its own hardened price reads off the
    ///      feeds, so the manager's call site is a single struct build plus a single cross-library call.
    ///      That shape is deliberate: the reason this body lives here at all is the manager's EIP-170
    ///      budget, and a per-leg entrypoint would have put the marshalling cost back where the budget is.
    ///      `marketB == address(0)` selects the asset-mode single-leg book (see the ASSET-MODE note on
    ///      `hedgeBorrowInterest`).
    struct HedgeBook {
        address usdc; // the unit of account, and the only funding source
        address swapRouter; // Slipstream CL SwapRouter for the USDC→leg buys
        address usdcFeed; // Chainlink USDC/USD (8dp)
        address sequencerFeed; // L2 sequencer-uptime feed
        uint256 maxDelay; // per-feed max staleness (seconds)
        uint256 gracePeriod; // sequencer grace period (seconds)
        uint256 maxSlippageBps; // floors each buy's min-out against the oracle
        uint256 budgetUsdc; // harvest proceeds available (6dp) — a HARD ceiling across BOTH legs
        address marketA; // leg A's Moonwell borrow market (always borrowed, both shapes)
        address legA; // leg A token
        address feedA; // leg A Chainlink USD feed (8dp)
        int24 spacingA; // leg A↔USDC SWAP pool tickSpacing (NOT the LP pool's)
        uint8 decimalsA; // leg A token decimals
        uint256 hedgedA; // `Layout.hedgedDebtA`
        address marketB; // leg B's borrow market, or address(0) in asset-mode (leg B carries no debt)
        address legB; // leg B token
        address feedB; // leg B Chainlink USD feed (8dp)
        int24 spacingB; // leg B↔USDC SWAP pool tickSpacing
        uint8 decimalsB; // leg B token decimals
        uint256 hedgedB; // `Layout.hedgedDebtB`
    }

    /// @notice Neutralise the ACCRUED BORROW INTEREST on one borrowed leg by buying exactly that much of
    ///         the leg with harvest proceeds and repaying it to Moonwell — turning a financing cost that
    ///         would otherwise accumulate as unintended SHORT exposure into plain NAV drag.
    ///
    /// @dev WHY THE MEASURE IS `debt − hedged` AND NOT `debt − lpLeg`.
    ///      A concentrated-liquidity position's leg composition MOVES WITH PRICE BY DESIGN: as the leg
    ///      appreciates the LP sells into the rise and `lpLeg` falls, while `debt` is roughly constant.
    ///      So `debt − lpLeg` is the SUM of two unrelated things — (a) accrued borrow interest, which is
    ///      an unintended short we want gone, and (b) a price-driven component that is the LP mechanism
    ///      working as intended. Closing the whole of `debt − lpLeg` on every harvest would make
    ///      `compound` a momentum-chasing delta rebalancer (buying the leg precisely as the leg rises),
    ///      fighting the LP's own mechanics and bleeding fees. It would also mis-handle a post-`rerange`
    ///      book, where part of the hedge sits as an IDLE leg remainder rather than inside `lpLeg`.
    ///
    ///      `Layout.hedgedDebtA/B` is instead a pure ACCOUNTING quantity — the borrowed principal the LP
    ///      side was funded with — maintained at the two chokepoints that can change it
    ///      (`LeveragedAeroManager._borrowLegA`/`_borrowHalfEach` add the borrow; `_repay` clamps it down
    ///      to the post-repay debt; `redeemUnwindImpl` scales it pro-rata). It is PRICE-INDEPENDENT by
    ///      construction, so `debt − hedged` isolates component (a) exactly and contains none of (b).
    ///      Every borrow of `x` grows the debt by `x` and the LP leg by `x` simultaneously, so the
    ///      difference can only be moved by interest.
    ///
    ///      EXACTNESS vs. Moonwell's own accounting. Compound-fork markets CAPITALISE interest into the
    ///      account's `principal` on every `borrow`/`repayBorrow` (`principal = borrowBalanceStored ± amt;
    ///      interestIndex = borrowIndex`), so the market's `principal` is NOT an interest-free basis and
    ///      the per-account `interestIndex` has no public getter. `borrowBalanceStored` immediately after
    ///      a borrow/repay IS that capitalised principal, which is exactly what the manager's chokepoints
    ///      track — making `debt − hedged` the market's own "interest accrued since our last touch",
    ///      obtained with no `borrowIndex()` read and no extra Layout field per leg beyond the basis
    ///      itself. The `debt` side of that subtraction is read with `borrowBalanceCurrent`, i.e. AFTER
    ///      accruing the market — see `_measureLeg` for why the stored index is not good enough here.
    ///
    ///      WHY REPAY RATHER THAN BUY-AND-ADD. Adding the interest amount into the LP would keep leverage
    ///      constant, but a CL add needs PAIRED USDC at the live range ratio, so it re-levers the book and
    ///      needs the asset-mode pairing solve — more moving parts on a path whose only job is to remove
    ///      an unintended exposure. Repaying uses plumbing that already exists, moves the DEBT side back
    ///      onto the LP instead of the other way round, and lands the cost exactly where it belongs: less
    ///      harvest reinvested, i.e. clean NAV drag, with leverage dipping slightly (the safe direction).
    ///
    ///      BOUNDED AND GRACEFUL. `budgetUsdc` is a hard ceiling and is the HARVEST's own USDC — never
    ///      stayers' idle USDC and never collateral (funding a hedge from either would be the same class
    ///      of mistake as a swap-funded lever-up: it would silently rewrite the book's delta profile).
    ///      A budget too small to cover the whole drift buys and repays what it can and the remainder
    ///      STAYS in `debt − hedged`, so the next harvest resumes exactly where this one stopped — the
    ///      call never reverts the harvest for insufficiency. Only the leg BALANCE DELTA of this call's
    ///      own swap is repaid, so a pre-existing idle leg remainder (which is already hedging the debt)
    ///      is never consumed.
    ///
    ///      ASSET-MODE. The manager calls this for leg A only when `legBIsAsset` (leg B is the unit of
    ///      account there and structurally carries no debt), so `h.leg != h.usdc` always holds and the
    ///      identity swap that `_sweepLegToUsdc` guards against is unreachable from here.
    ///      PRO-RATA ACROSS THE LEGS — MEASURE BOTH, *THEN* SPEND. The budget is one shared ceiling over
    ///      two independent drifts, so how it is divided is a real decision and it used to be made
    ///      implicitly: leg A was handed the WHOLE budget and leg B got `budget − spentA`. Whenever leg A's
    ///      drift priced at or above the harvest — the normal state for the larger/faster-accruing leg on a
    ///      thin harvest — leg B received exactly 0 and was never even MEASURED (the spend path returned on
    ///      `budget == 0` before reading the market), so every harvest in that band closed leg A and left
    ///      leg B's short untouched. Nothing was LOST (the remainder persists in `debt − hedged` and is
    ///      hedged once the budget allows), but the residual short CONCENTRATED 100% on one leg, which is
    ///      the opposite of what a leg-neutral book wants: a partial hedge should shrink the book's net
    ///      exposure evenly, not rotate it onto whichever leg the code happens to serve second.
    ///
    ///      So both drifts are measured first, then the budget is split `budget × costᵢ / (costA + costB)`.
    ///      Leg A takes its allocation and leg B takes the EXACT COMPLEMENT (`budget − allocationA`), so
    ///      integer division strands no dust. When the budget covers everything the split is a no-op — each
    ///      leg's spend is capped at its own cost, so both are neutralised exactly as before.
    ///
    ///      THE ACCRUE-THEN-MEASURE DISCIPLINE IS PRESERVED, and it is the thing this refactor most had to
    ///      not break: `borrowBalanceCurrent` is still called exactly ONCE per leg, in the measure phase,
    ///      and the number it returns is what BOTH the allocation and the spend are computed from. There is
    ///      no second read that could see a different (post-repay, re-capitalised) index. The one behaviour
    ///      change is that leg B is now accrued even when it will receive no budget — that is inherent to
    ///      measuring before allocating, it costs one market touch, and it leaves the leg market fresh for
    ///      the rest of the transaction (the same benefit the accrual note above already claims). Because
    ///      that touch would otherwise make a sick leg market able to revert the WHOLE harvest, the measure
    ///      is fail-open per leg and marks itself — see `_measureLeg` and `HedgeLegMeasureDegraded`.
    /// @param b       The whole book's inputs; see `HedgeBook`.
    /// @return spent  Total USDC spent across both legs (0 when there is no drift or no budget); never
    ///                more than `b.budgetUsdc`.
    function hedgeBorrowInterest(HedgeBook memory b) public returns (uint256 spent) {
        if (b.budgetUsdc == 0) return 0;
        uint256 pUsdc = readUsd8(b.usdcFeed, b.sequencerFeed, b.maxDelay, b.gracePeriod);

        // ── MEASURE (both legs, before a single USDC is committed) ──
        LegDrift memory dA = _measureLeg(b, b.marketA, b.feedA, b.decimalsA, b.hedgedA, pUsdc);
        // Leg B drifts too whenever it is BORROWED — the two-borrowed-legs shape LPs both borrows against
        // each other, so both accrue interest the LP never grows to match. `marketB == 0` is the
        // asset-mode book, where leg B IS the unit of account, is never borrowed, and cannot drift: the
        // gate keeps that shape on exactly its old single-leg path (`dB` stays zero ⇒ leg A is allocated
        // the whole budget ⇒ byte-identical behaviour).
        LegDrift memory dB;
        if (b.marketB != address(0)) {
            dB = _measureLeg(b, b.marketB, b.feedB, b.decimalsB, b.hedgedB, pUsdc);
        }

        uint256 total = dA.costUsdc + dB.costUsdc;
        if (total == 0) return 0; // no drift on either leg, or both priced below 1 USDC unit

        // ── ALLOCATE (pro-rata by USD cost) ──
        // No branch for the "budget covers everything" case: each leg's spend is capped at its own cost
        // inside `_spendLeg`, so an over-allocation simply goes unused and both legs neutralise fully.
        uint256 budgetA = Math.mulDiv(b.budgetUsdc, dA.costUsdc, total);

        // ── SPEND ──
        spent = _spendLeg(b, b.marketA, b.legA, b.spacingA, dA, budgetA);
        if (b.marketB != address(0)) {
            // The EXACT complement, not a second `mulDiv`: whatever leg A's share rounded away lands here
            // rather than being stranded by the division.
            spent += _spendLeg(b, b.marketB, b.legB, b.spacingB, dB, b.budgetUsdc - budgetA);
        }
    }

    /// @dev One leg's MEASURED state, carried from the measure phase of `hedgeBorrowInterest` into its
    ///      spend phase. Exists so `borrowBalanceCurrent` is read once per leg and that single accrued
    ///      number feeds both the pro-rata allocation and the buy/repay — the accrue-then-measure
    ///      discipline the whole interest hedge was built around (see `_measureLeg`).
    struct LegDrift {
        uint256 amount; // unhedged accrued interest in LEG units (`debt − hedged`); the repay cap
        uint256 costUsdc; // what closing ALL of `amount` would cost (USDC 6dp); the allocation weight
        uint256 num; // `price8 × 1e6` — the `_tokenToUsdc` numerator, kept as a factor
        uint256 den; // `10^decimals × pUsdc` — ...and its denominator, so the INVERSE is the same numbers
    }

    /// @dev THE MEASURE PHASE for one leg of `hedgeBorrowInterest` — no USDC is committed here, nothing
    ///      is swapped, and the result is the ONLY view of this leg the spend phase gets. See that
    ///      function's header for the measure itself, the repay-vs-add decision, the budget bound, the
    ///      pro-rata allocation and the graceful-degradation contract.
    ///
    ///      ACCRUE, *THEN* MEASURE — `borrowBalanceCurrent`, never `borrowBalanceStored`.
    ///      `borrowBalanceStored` is `principal × borrowIndex / interestIndex` on the market's LAST-ACCRUED
    ///      `borrowIndex`, and nothing earlier in a `compound` transaction accrues a borrow leg: `nav()` is
    ///      a view, the gauge `getReward` and the AERO→USDC swap never touch Moonwell. So the interest
    ///      accrued since the market's last accrual is un-capitalised and INVISIBLE to a stored read — and
    ///      it gets capitalised moments later, by this function's own `repayBorrow` and by
    ///      `deployIdleImpl`'s borrow, i.e. strictly AFTER the point where it needed to be measured.
    ///
    ///      Measured on a live fork run (7-day warp, single-borrower book, then pre-`compound` reads on the
    ///      leg market): `borrowBalanceStored` 76,853,210 vs `borrowBalanceCurrent` 76,868,617 — a TRUE
    ///      drift of 15,412 sats of which only 5 were visible to the stored read. That harvest hedged 4
    ///      sats. The residual was bounded (harvest #2 saw the by-then-capitalised interest and hedged it
    ///      exactly, so it did not accumulate without bound) but the intended "drift ≈ 0 after a harvest"
    ///      did not hold, and the first harvest after any quiet period hedged essentially nothing.
    ///
    ///      The MAGNITUDE above is fork-amplified: on a fork nobody else transacts, so `borrowIndex` sits
    ///      frozen for the whole warp, whereas a live Moonwell market is accrued by other borrowers'
    ///      supply/borrow/repay/liquidate txs constantly and the stale window is short. That is exactly why
    ///      the stored read must not be relied on: correctness of our own hedge cannot be a function of
    ///      third-party transaction flow.
    ///
    ///      COST is not an extra call — it is the SAME single call, promoted from a staticcall to a
    ///      state-changing one, on a path that is already state-changing (it swaps and repays). The accrual
    ///      also leaves the leg market fresh for everything later in the same tx. `borrowBalanceCurrent`
    ///      rather than a bare `accrueInterest()` for a correctness reason, not a gas one: `accrueInterest`
    ///      RETURNS a Compound MATH_ERROR code on its failure branches *without* writing the new index, so a
    ///      caller that dropped the code would carry on reading the stale index — the very failure being
    ///      fixed. Moonwell wraps it in `require(... == NO_ERROR)`, so using their wrapper makes the
    ///      fail-closed behaviour structural and un-droppable (see `IMoonwellMarket`).
    ///
    ///      NO EARLY BUDGET GATE HERE ANY MORE. The previous shape returned on `budgetUsdc == 0` BEFORE
    ///      touching the market, which is precisely what let a budget-starved leg go unmeasured and
    ///      therefore unhedged for as long as the other leg's drift exceeded the harvest. Measuring is
    ///      unconditional now; the budget only decides how much of what was measured gets SPENT.
    ///
    ///      A leg with no drift still reads no feed: the `debt <= hedged` return happens before the
    ///      `readUsd8`, so a quiet book adds no oracle-liveness dependency to the harvest.
    ///
    ///      ...AND THE MARKET TOUCH IS THEREFORE FAIL-OPEN (`HedgeLegMeasureDegraded`). Unconditional
    ///      measuring is what makes the pro-rata split correct, but it also makes `borrowBalanceCurrent`
    ///      — a STATE-CHANGING Moonwell call that reverts whenever `accrueInterest` fails, e.g. a paused
    ///      or arithmetically-broken market — a hard liveness dependency of `compound` on BOTH legs. In
    ///      the two-borrowed-legs shape with fee + hedge consuming the whole harvest, `deployIdleImpl` is
    ///      skipped and this is the ONLY touch of the leg's market in the transaction, so one sick market
    ///      would revert the entire harvest: the AERO sale, the fee crystallisation and the OTHER leg's
    ///      hedge included. That contradicts this hedge's founding contract — a hedge that cannot be
    ///      completed carries its remainder to the next harvest, it never reverts the harvest.
    ///
    ///      So the read is `try`/`catch`ed and a failure degrades THIS leg's drift to zero: the leg goes
    ///      unhedged for this harvest, the other leg still gets the whole budget (its `costUsdc` is then
    ///      the whole of `total`), and `compound` completes. BOTH legs are wrapped, not just leg B: the
    ///      invariant is about the harvest surviving a hedge problem, not about which leg had it, and
    ///      `_measureLeg` is one function serving both — a leg-B-only fail-open would need an extra
    ///      parameter to make the behaviour WORSE. Degrading is never silent (see the event) and never
    ///      loses value: the unmeasured interest stays in `debt − hedged` for the next harvest, exactly
    ///      as a budget shortfall does.
    ///
    ///      The `catch` cannot distinguish the expected causes from an out-of-gas — the same caveat the
    ///      stack's other fail-opens carry, and the same reason the degradation is marked on-chain.
    function _measureLeg(
        HedgeBook memory b,
        address market,
        address feed,
        uint8 legDecimals,
        uint256 hedged,
        uint256 pUsdc
    ) private returns (LegDrift memory d) {
        uint256 debt;
        try IMoonwellMarket(market).borrowBalanceCurrent(address(this)) returns (uint256 accrued) {
            debt = accrued;
        } catch {
            emit HedgeLegMeasureDegraded(market);
            return d; // zero drift ⇒ zero allocation ⇒ `_spendLeg` no-ops on this leg
        }
        if (debt <= hedged) return d;
        d.amount = debt - hedged;

        // `num/den` is the manager's `_tokenToUsdc` basis, kept as its two factors so the INVERSE
        // (USDC→leg, for the min-out) is the same numbers read the other way and the two cannot drift.
        d.num = readUsd8(feed, b.sequencerFeed, b.maxDelay, b.gracePeriod) * 1e6;
        d.den = (10 ** uint256(legDecimals)) * pUsdc;
        d.costUsdc = Math.mulDiv(d.amount, d.num, d.den);
    }

    /// @dev THE SPEND PHASE for one leg: buy `min(cost, budget)` USDC worth of the leg and repay it.
    ///      Consumes ONLY the `LegDrift` the measure phase produced — it never re-reads the market, so
    ///      the accrued balance the allocation was computed from is the same one the repay is capped
    ///      against.
    ///
    ///      GRACEFUL BY CONTRACT, per leg: a budget short of this leg's cost buys and repays what it can
    ///      and the remainder STAYS in `debt − hedged`, so the next harvest resumes exactly here. It never
    ///      reverts the harvest for insufficiency, and that is now true of BOTH legs rather than only of
    ///      whichever leg the budget happened to reach.
    function _spendLeg(
        HedgeBook memory b,
        address market,
        address leg,
        int24 spacing,
        LegDrift memory d,
        uint256 budgetUsdc
    ) private returns (uint256 spentUsdc) {
        uint256 spend = d.costUsdc > budgetUsdc ? budgetUsdc : d.costUsdc;
        if (spend == 0) return 0; // no drift, no allocation, or drift priced below 1 USDC unit

        // Oracle-floored exact-IN buy (the `_settleShortfall` posture, not the exact-OUT one): exact-out
        // would REVERT the whole harvest the moment `budgetUsdc` could not cover the drift, and this path
        // must degrade instead. The min-out is the oracle-implied leg amount for `spend`, haircut by
        // `maxSlippageBps`, so a sandwiched buy reverts rather than overpaying.
        uint256 minOut = (Math.mulDiv(spend, d.den, d.num) * (10000 - b.maxSlippageBps)) / 10000;
        uint256 legBefore = IERC20(leg).balanceOf(address(this));
        swapExactIn(b.swapRouter, b.usdc, leg, spacing, spend, minOut);
        spentUsdc = spend;

        // Repay ONLY this swap's own proceeds, capped at the measured drift. Capping at `d.amount` is what
        // keeps `Layout.hedgedDebtA/B` untouched by this repay: post-repay debt is `hedged + (drift −
        // repaid) >= hedged`, so the manager's `_repay` clamp is provably a no-op here and the basis
        // discipline stays single-sited. Any tiny overshoot of the buy stays as an idle leg balance,
        // which is NAV-counted and redeployable.
        uint256 got = IERC20(leg).balanceOf(address(this)) - legBefore;
        uint256 repaid = got < d.amount ? got : d.amount;
        if (repaid > 0) {
            IERC20(leg).forceApprove(market, repaid);
            uint256 err = IMoonwellMarket(market).repayBorrow(repaid);
            if (err != 0) revert MoonwellRepayFailed(err);
        }
    }

    /// @dev THE SHARED RATIO PROBE for both asset-mode sizing entrypoints: the (leg A : USDC)
    ///      token-amount ratio the range `[tickLower, tickUpper]` requires at the pool's live `sqrtP`.
    ///      Probed at `REF_LIQUIDITY` — both amounts are linear in L for a fixed range + `sqrtP`, so the
    ///      reference cancels out of the ratio.
    ///
    ///      One-sided range (`sqrtP` at or outside a bound) ⇒ one required amount is 0 and the ratio
    ///      degenerates: a 0 `needU` would demand a borrow with no USDC to pair, a 0 `needA` would demand
    ///      no borrow at all (an unhedged USDC-only add). Both fail closed — `rerange` recentres on the
    ///      current tick, which is always two-sided.
    function _rangeRatio(address pool, int24 tickLower, int24 tickUpper, bool legAIsToken0)
        private
        view
        returns (uint256 needA, uint256 needU)
    {
        (uint160 sqrtP,,,,,) = ICLPool(pool).slot0();
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), REF_LIQUIDITY
        );
        (needA, needU) = legAIsToken0 ? (amt0, amt1) : (amt1, amt0);
        if (needA == 0 || needU == 0) revert DegenerateRange();
    }

    /// @dev `borrowUsd6` (USDC face, 6dp) → leg-A token units at the 8dp Chainlink price `legAPrice8`.
    ///      ONE definition of the conversion `LeveragedAeroManager._borrowHalfEach` applies per leg
    ///      (un-halved): `× 100` lifts 6dp USDC face to the feed's 8dp USD (USDC face taken as USD 1:1),
    ///      `× 10^dA / pA` rescales into leg-A units. Shared by `assetModeSplit` and
    ///      `assetModeLeverUpPair` so a genesis borrow and a lever-up borrow convert identically.
    function _legABorrow(uint256 borrowUsd6, uint256 legAUnit, uint256 legAPrice8) private pure returns (uint256) {
        return (borrowUsd6 * 100 * legAUnit) / legAPrice8;
    }

    // ---------------------------------------------------------------------------
    // Internal terms
    // ---------------------------------------------------------------------------

    /// @dev Moonwell USDC collateral in USDC face (6dp). Scaling copied verbatim from
    ///      `MoonwellSupplyAdapter.value`: `underlying = cBal * exchangeRateStored / 1e18`.
    ///      `exchangeRateStored` (last-accrued, view) is used — never the mutating
    ///      `balanceOfUnderlying`. USDC is the unit, so the result is already face-valued.
    function _collateralUsdc(Config memory c, address strategy) private view returns (uint256) {
        return _collateralUnderlying(c.mUsdc, strategy);
    }

    /// @dev The `Config`-free form of the above, so the NAV term and the `usdcAvailable` funding basis
    ///      are ONE expression rather than two copies that agree only by inspection.
    function _collateralUnderlying(address mUsdc, address who) private view returns (uint256) {
        uint256 cBal = ICToken(mUsdc).balanceOf(who);
        if (cBal == 0) return 0;
        return (cBal * ICToken(mUsdc).exchangeRateStored()) / 1e18;
    }

    /// @dev THE WHOLE GAUGE-REWARD CLAIM, in USDC face (6dp) — BOTH halves of it:
    ///
    ///        1. the balance ALREADY CLAIMED into the strategy wallet. Every `_unwindLiquidity` calls
    ///           `gauge.withdraw`, which auto-claims the accrued tranche whether or not anyone asked, so a
    ///           non-zero reward balance is a normal, reachable state (post-`rerange`, post-partial-redeem,
    ///           post-`adjustLeverage`), not an anomaly; and
    ///        2. `gauge.earned(strategy, tokenId)` — the still-UNCLAIMED accrual on the staked NFT.
    ///
    ///      BOTH ARE LOAD-BEARING, and (2) is the bigger one. The held balance only closes the narrow
    ///      post-unwind window; a harvest spends MOST of its life sitting in the gauge as `earned()`, so
    ///      pricing (1) alone still left the ordinary deposit-before-`compound` capture wide open — a
    ///      depositor buys in at a NAV that excludes the pending harvest and then takes a pro-rata slice of
    ///      it the moment `compound` claims and sells (measured at ~4.5% of a 100k deposit, post-fee, in a
    ///      single block). Pricing the reward wherever it currently sits is what actually closes it.
    ///
    ///      THE `try/catch` IS THE MECHANISM, AND THE CATCH-TO-0 IS CORRECT **FOR THE ONE STATE IT WAS
    ///      WRITTEN FOR** — not, in general, an understatement. Slipstream's gauge reverts `"NA"` on
    ///      `earned()` for a tokenId it does not have staked. The gauge is a DIFFERENT contract, so that
    ///      revert is a plain external failure a Solidity `try` catches (the same idiom `LPAutoBalancerV2`
    ///      already uses for its `earned()` reads) — `nav()` gains no revert path. And the state where
    ///      `earned()` reverts `"NA"` is EXACTLY the state where the tokenId is unstaked, which is exactly
    ///      when the gauge has just auto-claimed the tranche into the held balance that (1) prices. So the
    ///      two terms hand off cleanly: whatever leaves `earned()` arrives in the balance in the same
    ///      transaction, and the sum is continuous across the unstake. `c.tokenId == 0` (flat book /
    ///      pre-genesis) skips the call entirely.
    ///
    ///      WHAT THE CATCH DOES **NOT** COVER — STATED PLAINLY, BECAUSE THE CONTINUITY ARGUMENT ABOVE IS
    ///      ABOUT `"NA"` AND ONLY ABOUT `"NA"`. `catch {}` is indiscriminate: it equally swallows an
    ///      out-of-gas in the subcall (63/64 forwarding), a selector/ABI change across a gauge upgrade or
    ///      a venue migration onto a non-Slipstream gauge, and any future Aerodrome revert. In every one
    ///      of those states the earned term silently drops to zero — and a zero there is NOT "the accrual
    ///      is zero, priced correctly"; it is the PRE-FIX MIS-PRICING this term exists to close, restored
    ///      in full and running on every deposit, every block, with nothing in any transaction to show
    ///      for it. The trade is deliberate and it is NOT revisited here: `nav()` must stay revert-free on
    ///      this read (see the deadman rationale on `sweepFloors` — a hard revert on a reward probe would
    ///      brick pricing over a term that is a small fraction of a levered book). What is added is
    ///      OBSERVABILITY, not a revert: `_earnedRead` reports whether the read answered, and
    ///      `rewardReadOk` publishes exactly that for a keeper to poll. Silent stays silent onchain;
    ///      it does not stay invisible. The read itself — including the `code.length` precheck, which a
    ///      `try` cannot substitute for because solc's `extcodesize` guard on the call target reverts
    ///      UNCATCHABLY — now lives in `_earnedRead`, as ONE definition shared by the priced term and the
    ///      marker; its three states are documented there.
    ///
    ///      GATED ON THE SUM, NOT ON THE BALANCE: `earned()` can be non-zero while the balance is zero
    ///      (the steady state, in fact — emissions accrue every second between harvests), so the feed read
    ///      must happen when EITHER is non-zero. The genuinely reward-free book (no emissions, nothing
    ///      held) still reads no feed at all and pays only the two staticcalls that establish that.
    ///
    ///      FAIL-CLOSED on a stale reward feed while there IS reward value, matching the posture the held
    ///      term shipped with: the read goes through the same hardened `_readUsd8` every other term uses,
    ///      so an unreadable feed reverts `nav()` rather than valuing the reward at 0. That is this file's
    ///      whole stance — a NAV that cannot be computed honestly must deny deposits, not mint against an
    ///      understated book (valuing at 0 would RE-CREATE the very mis-pricing this term closes, and hand
    ///      it to whoever can stale the feed). NOTE the scope change this widens: with `earned()` priced,
    ///      a live gauge means reward value is essentially ALWAYS present, so a stale reward feed now
    ///      fail-closes `nav()` — deposits and the priced fast redeem — for as long as it is stale, not
    ///      just inside a post-unwind window. `compound` is still the cure (it zeroes both halves), and
    ///      the async redeem queue is unaffected: `fulfillRedeem`'s proportional unwind never reads
    ///      `nav()`. Accepted deliberately; documented in the rebalancer guide.
    ///
    ///      FEE-TIMING CONSEQUENCE, ACCEPTED DELIBERATELY — this is the real trade-off. Fee
    ///      crystallisation reads NAV, so the performance fee now accrues against UNREALISED, UNCLAIMED
    ///      reward value continuously, instead of only against harvest proceeds at `compound`. A fee can
    ///      therefore be crystallised on reward value that a later adverse event (a gauge killed by
    ///      governance, a reward-route failure, a sale under the mark) means the fund never fully
    ///      realises. That is the price of removing the free option above, and it is the correct side to
    ///      err on: the alternative mis-prices every deposit, every block, in an attacker's favour.
    ///
    ///      THE MARK IS TICK-INFLUENCED, second-order and accepted. Slipstream accrues emissions on
    ///      `rewardGrowthInside`, so `earned()` depends on where the tick has been relative to the
    ///      position's range — a pool shove can nudge it. It cannot be shoved far: `netEquityUsdc` runs
    ///      `_calmGate` before pricing anything, so a spot/TWAP deviation beyond `calmDeviationTicks`
    ///      fail-closes the whole NAV first, and the term is a small fraction of a levered book.
    ///
    ///      DECIMALS are pinned at 18, matching the reward-token scaling already hardcoded in
    ///      `LeveragedAeroManager.compoundImpl` / `LeveragedAeroVenue._sellRewardBalance` (the `1e20`
    ///      divisor). `LeveragedAeroVenue.applyVenue` enforces it (`IERC20Metadata(rewardTok).decimals()
    ///      != 18 → UnexpectedFeedDecimals`) at init AND at every venue migration, and likewise rejects a
    ///      reward token equal to either leg (`UnsupportedLeg`), so this term can never double-count an
    ///      idle-leg balance.
    ///
    ///      `c.rewardFeed` is `Layout.aeroUsdFeed` — the SAME field `_sellRewardBalance` derives its sale
    ///      floor from and the SAME field `applyVenue` rewrites on a migration, so the mark and the
    ///      realisation basis cannot drift and a venue migration can never orphan a second pinned copy.
    function _rewardUsdc(Config memory c, address strategy, uint256 pUsdc) private view returns (uint256) {
        uint256 amt = IERC20(ICLGauge(c.gauge).rewardToken()).balanceOf(strategy);
        (uint256 e,) = _earnedRead(c.gauge, strategy, c.tokenId);
        amt += e;
        if (amt == 0) return 0;
        return _usdcValue(amt, 18, _readUsd8(c, c.rewardFeed), pUsdc);
    }

    /// @dev THE gauge-side `earned()` read — the amount AND whether the read actually answered. ONE
    ///      definition, deliberately: `_rewardUsdc` takes the amount and ignores the flag, `rewardReadOk`
    ///      takes the flag and ignores the amount, so the monitoring signal and the priced term CANNOT
    ///      drift apart the way two hand-kept copies of the same predicate would.
    ///
    ///      THE THREE STATES, and why each maps where it does:
    ///
    ///        - `tokenId == 0` → `(0, true)`. A flat / pre-genesis book has NOTHING to read, and the call
    ///          is never made (that is what keeps `nav()`'s flat-book branch call-free). "OK" is the
    ///          honest answer: there is no failing read to report, and reporting `false` here would make
    ///          the marker scream through every `settle`→`execute` gap.
    ///
    ///        - `gauge.code.length == 0` → `(0, false)`, WITHOUT making the call. THIS BRANCH IS
    ///          LOAD-BEARING, NOT COSMETIC — a `try` DOES NOT CATCH THIS. Solidity guards a high-level
    ///          call to a typed contract with an `extcodesize` check emitted OUTSIDE the try's protected
    ///          region, so against an empty-code gauge the `try` reverts uncatchably ("call to
    ///          non-contract address") and the revert propagates straight through `catch {}` to the
    ///          caller. Verified by deleting this line: `testRewardReadOkIsFalseWhenTheGaugeHasNoCode`
    ///          fails with exactly that revert. So the precheck is the ONLY thing standing between
    ///          `rewardReadOk` and a revert path, and a marker that reverts precisely when the venue is
    ///          gone is worse than no marker. It also, secondarily, keeps "the venue is gone" from being
    ///          reported as OK — it is not an "accrual is zero" state.
    ///
    ///          FOR `nav()` this changes nothing OBSERVABLE, but not for the tempting reason: the bare
    ///          `try` would have REVERTED here, not caught to 0. `nav()` is unaffected because it cannot
    ///          reach this probe in that state at all — `_rewardUsdc`'s `rewardToken()` read, two lines
    ///          before the call to this function, already fail-closes the whole of `nav()` against an
    ///          empty-code gauge (empty revert data; asserted in the same test). Both paths deny an
    ///          answer; only this one has a caller that must not revert.
    ///
    ///        - otherwise → the `try`. Success is `(e, true)`; any revert is `(0, false)` — `"NA"`
    ///          (benign, the hand-off documented on `_rewardUsdc`) and every non-`"NA"` failure alike.
    ///          The flag does not distinguish them: a caller CANNOT reliably tell them apart onchain
    ///          (`"NA"` is a plain string revert any upgrade could also emit), and conflating them errs
    ///          the safe way — a keeper investigates a benign unstake instead of missing a real outage.
    ///          A benign `"NA"` is transient by construction (it lasts from the unstake to the next
    ///          `_execute`), so a marker that STAYS false is the actionable signal.
    function _earnedRead(address gauge, address strategy, uint256 tokenId) private view returns (uint256 e, bool ok) {
        if (tokenId == 0) return (0, true);
        if (gauge.code.length == 0) return (0, false);
        try ICLGauge(gauge).earned(strategy, tokenId) returns (uint256 e_) {
            return (e_, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice MONITORING MARKER for the single fail-open on the NAV path: `false` while the gauge-side
    ///         `earned()` read that `nav()` prices is FAILING, `true` when it answers or when there is
    ///         nothing to read. Poll it; `false` means `nav()` is understating the book by the unclaimed
    ///         reward accrual.
    ///
    /// @dev WHY STATE AND NOT AN EVENT. Every other fail-open in this system is transaction-scoped and
    ///      instruments itself with an event from the transaction that took it (`FeeCrystallizeDeferred`,
    ///      the redeem-floor and reward-sale degradation events). This one is not: `nav()` is `view`, it
    ///      cannot emit, and its fail-open is not an incident but a CONDITION — once `earned()` starts
    ///      reverting for a non-`"NA"` reason it reverts on every deposit and every block until someone
    ///      intervenes, understating NAV identically each time and leaving no trace anywhere. Readable
    ///      state is the only instrumentation a `view` admits, so this is it.
    ///
    ///      STRICTLY BEHAVIOUR-NEUTRAL. Nothing in the pricing path reads this: it does not change
    ///      `nav()`'s result, does not add a revert path to it, and is not itself allowed to revert (a
    ///      marker a monitor cannot read is not a marker). It is a marker, not a gate — the deliberate
    ///      choice is that a failing reward read degrades NAV and is REPORTED, rather than blocking
    ///      deposits and the priced redeem.
    ///
    ///      LEAN SIGNATURE, on purpose — the same reason `calmGate` exists alongside `_calmGate` and
    ///      `readUsd8` alongside `_readUsd8`. Two scalars, not a `Config`: the caller
    ///      (`LeveragedAerodromeCLStrategy.rewardReadOk`) has ~230 BYTES of EIP-170 headroom in total, and
    ///      building + ABI-encoding a 21-field `Config` to deliver two fields this predicate actually
    ///      touches would not fit. Both inputs come from the SAME `Layout` slots `_config()` reads
    ///      (`$.gauge`, `$.tokenId`), so the marker and the priced term cannot be pointed at different
    ///      venues.
    ///
    ///      DELEGATECALL CONTEXT REQUIRED — the ONE way this differs from the pricing functions, which
    ///      all take `strategy` explicitly. The subject is `address(this)`, which under the strategy's
    ///      (or the delegatecalled manager's) call into this linked library IS the strategy clone — the
    ///      same identity `netEquityUsdc` is passed. That drops the third calldata word, and at this
    ///      caller's headroom those bytes are the difference between fitting and not. Consequence, stated
    ///      so nobody is surprised: called on the DEPLOYED LIBRARY ADDRESS directly, the subject is the
    ///      LIBRARY, which stakes nothing — so the answer is about the wrong account. It is `false` for
    ///      any non-zero `tokenId` (the library has none staked) and a meaningless `true` for
    ///      `tokenId == 0`, which is the arm that never reads anything. Neither is an answer about the
    ///      fund. Reach it through `strategy.rewardReadOk()` — the only call site, and the only entry a
    ///      keeper should use.
    /// @param gauge    Slipstream CL gauge (`Layout.gauge` — the venue-migrated one).
    /// @param tokenId  `Layout.tokenId`; 0 ⇒ flat book, nothing to read ⇒ `true`.
    /// @return ok      `false` iff there IS a staked tokenId and the `earned()` read cannot be made or
    ///                 reverts (gauge without code, `"NA"`, or any other failure).
    function rewardReadOk(address gauge, uint256 tokenId) public view returns (bool ok) {
        (, ok) = _earnedRead(gauge, address(this), tokenId);
    }

    /// @dev cbBTC + WETH debt at the same Chainlink basis, converted to USDC face.
    ///      Both this term (`borrowBalanceStored`) and the collateral (`exchangeRateStored`) use
    ///      Moonwell's LAST-ACCRUED, view-safe values — `nav()` is `view` and cannot
    ///      `accrueInterest`. The inter-accrual staleness is bounded (bps over hours) and
    ///      conservative-leaning: if the supply market is more current than the borrow markets,
    ///      debt is the staler/lower term → NAV slightly OVER-stated → a deposit mints FEWER
    ///      shares (depositor over-pays), which PROTECTS stayers rather than diluting them. A
    ///      consumer wanting exactness can `accrueInterest` all three markets before a deposit
    ///      (off the view path).
    function _debtUsdc(Config memory c, address strategy, uint256 pCbBTC, uint256 pWeth, uint256 pUsdc)
        private
        view
        returns (uint256 debt)
    {
        uint256 cbDebt = IMoonwellMarket(c.cbBTCMarket).borrowBalanceStored(strategy);
        uint256 wethDebt = IMoonwellMarket(c.wethMarket).borrowBalanceStored(strategy);
        debt = _usdcValue(cbDebt, c.cbBTCDecimals, pCbBTC, pUsdc);
        debt += _usdcValue(wethDebt, c.wethDecimals, pWeth, pUsdc);
    }

    /// @dev Prices the CL position's two legs at the oracle-implied `sqrtP` and converts to
    ///      USDC face. token0/token1 are mapped to (cbBTC, WETH) prices by reading the pool
    ///      ordering, so this is robust regardless of which token sorts lower.
    function _clLegsUsdc(
        Config memory c,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 pCbBTC,
        uint256 pWeth,
        uint256 pUsdc
    ) private view returns (uint256 legsUsdc) {
        if (liquidity == 0) return 0;

        address t0 = ICLPool(c.pool).token0();
        // Map (price, decimals) to the pool's token0/token1 ordering.
        (uint256 p0, uint8 d0, uint256 p1, uint8 d1) = (t0 == c.cbBTC)
            ? (pCbBTC, c.cbBTCDecimals, pWeth, c.wethDecimals)
            : (pWeth, c.wethDecimals, pCbBTC, c.cbBTCDecimals);

        uint160 sqrtP = oracleSqrtPriceX96(p0, d0, p1, d1);
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );

        legsUsdc = _usdcValue(amt0, d0, p0, pUsdc);
        legsUsdc += _usdcValue(amt1, d1, p1, pUsdc);
    }

    /// @dev Hardened USD read that also asserts the feed is 8-decimal (the scaling assumption,
    ///      §5). `readUsd` already fetches `feed.decimals()`, so validating it costs no extra call;
    ///      a redeployed feed at a different precision fail-closes with `FeedDecimalsMismatch`
    ///      instead of silently inflating the term by 10^(d-8).
    function _readUsd8(Config memory c, address feed) private view returns (uint256 price) {
        return readUsd8(feed, c.sequencerFeed, c.maxDelay, c.gracePeriod);
    }

    /// @notice The same hardened 8-decimal USD read, with the sequencer/staleness inputs passed flat
    ///         instead of inside a `Config`.
    /// @dev EXISTS FOR THE MANAGER'S EIP-170 BUDGET. `ChainlinkReader` is an `internal` library, so every
    ///      contract that calls it inlines the whole sequencer + round + staleness ladder. The manager was
    ///      carrying its own copy for a `_readUsd8` identical to this one; routing it here (one
    ///      DELEGATECALL per price read, on paths that already make several venue calls) removes that copy
    ///      from a library sitting at the cap. Callers get the identical fail-closed semantics — this IS
    ///      the definition `netEquityUsdc` prices with, so the execution basis and the NAV basis cannot
    ///      drift apart, which was previously only true by inspection of two copies.
    function readUsd8(address feed, address sequencerFeed, uint256 maxDelay, uint256 gracePeriod)
        public
        view
        returns (uint256 price)
    {
        uint8 dec;
        (price, dec) = ChainlinkReader.readUsd(feed, sequencerFeed, maxDelay, gracePeriod);
        if (dec != USD_FEED_DECIMALS) revert FeedDecimalsMismatch();
    }

    /// @dev Reads cbBTC + WETH USD prices through the hardened reader (fail-closed).
    function _legPrices(Config memory c) private view returns (uint256 pCbBTC, uint256 pWeth) {
        pCbBTC = _readUsd8(c, c.cbBTCFeed);
        pWeth = _readUsd8(c, c.wethFeed);
    }

    /// @dev Converts a token `amount` (in `tokenDecimals`) at USD price `pToken` (8dp feed)
    ///      to USDC face (6dp), honoring the USDC peg via the USDC/USD feed `pUsdc` (8dp).
    ///
    ///        usdValue (8dp) = amount * pToken / 10^tokenDecimals
    ///        usdcFace (6dp) = usdValue * 10^6 / pUsdc          (USD-1e8 / USDC-price-1e8)
    ///
    ///      Both feeds are 8-decimal, so the 1e8 scales cancel; `pUsdc ≈ 1e8` for a healthy
    ///      peg. `Math.mulDiv` carries the intermediate so there is no precision loss / overflow
    ///      for realistic amounts.
    function _usdcValue(uint256 amount, uint8 tokenDecimals, uint256 pToken, uint256 pUsdc)
        private
        pure
        returns (uint256)
    {
        if (amount == 0) return 0;
        // usdValue at the feed's 8dp: amount * pToken / 10^tokenDecimals
        uint256 usdValue = Math.mulDiv(amount, pToken, 10 ** uint256(tokenDecimals));
        // → USDC face (6dp): divide by the USDC price (8dp) and rescale 1e8 → 1e6.
        return Math.mulDiv(usdValue, 1e6, pUsdc);
    }

    /// @notice The three oracle bounds an IL-residual cover needs (`LeveragedAeroManager._rebalanceCover`):
    ///         how much USDC the deficit buy may spend, how much of the surplus leg to sell for it, and
    ///         the floor that sell must clear. Pure — the caller supplies the hardened prices.
    ///
    /// @dev Lives here rather than inline in the manager, which is at the EIP-170 cap.
    ///
    ///      `buyMax` is the oracle CEILING on the exact-output cover: a sandwiched/manipulated
    ///      permissionless `deleverage` cannot overpay past oracle + `slipBps` (H1).
    ///
    ///      `sellAmt` is NEED-SIZED, never the whole balance: `buyMax` converted into surplus-leg units
    ///      and grossed up by `slipBps` a SECOND time, so a sell that fills exactly on `sellFloor` still
    ///      raises the ceiling-priced buy. Capped at `surplusBal`. Selling more than this would liquidate
    ///      a delta-neutral idle remainder into an unrecorded short — see the manager's call site.
    ///
    ///      `sellFloor` is derived from `sellAmt`, NOT from `surplusBal`: a floor priced off a balance
    ///      larger than what is sold is unreachable and would revert every need-sized sell.
    ///
    ///      `surplusBal == 0` (nothing to sell, or the surplus leg IS the unit of account) returns
    ///      `(buyMax, 0, 0)` without touching `pSurplus` — which the caller may then pass as 0.
    /// @param slipBps `maxSlippageBps`, bounded to (0, 1000] at init so neither gross-up can underflow.
    function coverBounds(
        uint256 shortAmt,
        uint8 deficitDec,
        uint256 pDeficit,
        uint256 surplusBal,
        uint8 surplusDec,
        uint256 pSurplus,
        uint256 pUsdc,
        uint256 slipBps
    ) public pure returns (uint256 buyMax, uint256 sellAmt, uint256 sellFloor) {
        buyMax = _usdcValue(shortAmt, deficitDec, pDeficit, pUsdc) * (10000 + slipBps) / 10000;
        if (surplusBal == 0) return (buyMax, 0, 0);
        uint256 needed =
            Math.mulDiv(buyMax * 10000 / (10000 - slipBps), (10 ** uint256(surplusDec)) * pUsdc, pSurplus * 1e6);
        sellAmt = surplusBal > needed ? needed : surplusBal;
        sellFloor = _usdcValue(sellAmt, surplusDec, pSurplus, pUsdc) * (10000 - slipBps) / 10000;
    }

    /// @notice The Chainlink min-out floors for the two residual leg sweeps at the END of a proportional
    ///         redeem (`LeveragedAeroManager.redeemUnwindImpl` step E) — the same
    ///         `oracleValue(amountSold) × (1 − maxSlippageBps)` idiom `settleImpl`'s `_sweepAtOracleFloor`
    ///         and `_rebalanceCover`'s `sellFloor` already use, applied to the last two zero-floor swaps
    ///         in the system.
    ///
    /// @dev FAIL-CLOSED HERE, DEADMAN-SAFE AT THE CALL SITE. This function reverts on a stale feed / down
    ///      sequencer exactly like every other priced path (it goes through `readUsd8`, so there is ONE
    ///      hardened ladder, not a second non-reverting copy of it). The caller reaches it through a
    ///      try-able EXTERNAL hop — `LeveragedAerodromeCLStrategy.redeemSweepFloors`, invoked as
    ///      `this.`-style call from the delegatecalled manager, the same idiom `_proportionalRedeem`
    ///      already uses for `try this.nav()` — and treats a revert as "floors = 0".
    ///
    ///      WHY THAT SPLIT IS THE WHOLE POINT. `emergencyRedeem` routes through step E and exists
    ///      precisely for the ORACLE-DOWN-AND-BACKEND-DEAD state (see `FULFILL_WINDOW`): a hard revert
    ///      here would brick the trustless exit — turning a value-protection guard into a fund-freeze.
    ///      Conversely a sandwicher cannot MAKE a feed stale, so whenever the feeds are readable the
    ///      floor binds and the hostile fill reverts. Fail-open only in the state where there is nothing
    ///      to price against and the alternative is no exit at all.
    ///
    ///      COARSE BY DESIGN: one unreadable feed drops BOTH floors, not just its own leg's. The
    ///      direction is safe (it can only ever fall back to the pre-existing behaviour, never block the
    ///      deadman) and the alternative — two independently try-able hops — costs the manager bytes it
    ///      does not have. Each leg's feed is only read when that leg has something to sell, so a book
    ///      with a single residual leg is unaffected by the other feed's health.
    ///
    ///      LOSS INCIDENCE, unchanged: slippage on these sweeps is borne by the REDEEMER (the stayers'
    ///      reservation `keep` is snapshot BEFORE the sweep and stays behind as legs). The floor protects
    ///      the redeemer from a hostile fill; it does not move value between the two parties.
    ///
    ///      TAKES THE EXISTING `Config` rather than a bespoke input struct: every field it needs
    ///      (leg decimals, the two leg feeds, the USDC feed, and the whole sequencer/staleness triple)
    ///      is already there, and the strategy already builds exactly one `Config` for `nav()`. Reusing
    ///      it means no second config builder to keep in sync — and none of the strategy's precious
    ///      EIP-170 headroom spent on one. Only `slipBps` is passed separately (it is not a valuation
    ///      input, so it is not, and should not be, a `Config` member).
    /// @param c         The valuation config (`LeveragedAerodromeCLStrategy._config()`).
    /// @param cbAmt     Leg-B units ACTUALLY being sold (0 in asset-mode — that sweep is the identity).
    /// @param wethAmt   Leg-A units ACTUALLY being sold.
    /// @param slipBps   `maxSlippageBps`; bounded to (0, 1000] at init so `10000 - slipBps` can't underflow.
    /// @return cbFloor   Min USDC out for the leg-B sweep (0 when nothing is being sold).
    /// @return wethFloor Min USDC out for the leg-A sweep (0 when nothing is being sold).
    function sweepFloors(Config memory c, uint256 cbAmt, uint256 wethAmt, uint256 slipBps)
        public
        view
        returns (uint256 cbFloor, uint256 wethFloor)
    {
        if (cbAmt == 0 && wethAmt == 0) return (0, 0);
        uint256 pUsdc = _readUsd8(c, c.usdcFeed);
        if (cbAmt > 0) {
            cbFloor = _usdcValue(cbAmt, c.cbBTCDecimals, _readUsd8(c, c.cbBTCFeed), pUsdc) * (10000 - slipBps) / 10000;
        }
        if (wethAmt > 0) {
            wethFloor = _usdcValue(wethAmt, c.wethDecimals, _readUsd8(c, c.wethFeed), pUsdc) * (10000 - slipBps) / 10000;
        }
    }

    /// @dev Spot-vs-TWAP calm-gate (fail-closed). Reverts `CalmGateBreached` when the pool
    ///      spot tick deviates from the `twapWindow` arithmetic-mean tick beyond
    ///      `calmDeviationTicks`. Pattern: `AerodromeLPAdapter` deviation gate; mechanism:
    ///      Mamo `LPAutoBalancerV2.reset()` calm-gate.
    ///
    ///      Visibility is `public` so `LeveragedAerodromeCLStrategy` can call it before
    ///      minting to guard tick-band placement and slippage-min computation (delegatecall
    ///      via the deployed library).
    ///
    ///      This is now a thin `Config`-shaped forwarder onto `calmGate` — the logic lives there and is
    ///      UNCHANGED. `netEquityUsdc` and any `Config`-holding caller keep using this entrypoint; the
    ///      manager uses the lean one. Do NOT edit the logic without re-reading both.
    function _calmGate(Config memory c) public view {
        calmGate(c.pool, c.twapWindow, c.calmDeviationTicks);
    }

    /// @notice Lean, struct-free twin of `_calmGate`: identical logic, three scalars instead of the
    ///         18-field `Config`.
    /// @dev `LeveragedAeroManager` is at the EIP-170 margin and gates on every mint/add (4 sites).
    ///      Building + ABI-encoding a mostly-zero `Config` per site to deliver exactly these three
    ///      fields cost it hundreds of bytes of encode logic, so the manager calls this instead and
    ///      holds no partial-`Config` builder at all (which also removes the standing footgun that
    ///      builder carried: a partial `Config` must never reach a pricing function).
    /// @param pool               Slipstream CL pool to gate on.
    /// @param twapWindow         TWAP lookback in seconds; 0 is rejected (`InvalidConfig`).
    /// @param calmDeviationTicks Max |spotTick − twapTick| before `CalmGateBreached`.
    function calmGate(address pool, uint32 twapWindow, uint16 calmDeviationTicks) public view {
        if (twapWindow == 0) revert InvalidConfig();
        (, int24 spotTick,,,,) = ICLPool(pool).slot0();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
        (int56[] memory cum,) = ICLPool(pool).observe(secondsAgos);

        int56 delta = cum[1] - cum[0];
        int24 twapTick = int24(delta / int56(uint56(twapWindow)));
        // Round toward negative infinity (Uniswap convention) when the cumulative delta is
        // negative and does not divide evenly, so the mean matches the TWAP oracle.
        if (delta < 0 && (delta % int56(uint56(twapWindow)) != 0)) twapTick--;

        int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        if (uint24(diff) > calmDeviationTicks) revert CalmGateBreached();
    }
}
