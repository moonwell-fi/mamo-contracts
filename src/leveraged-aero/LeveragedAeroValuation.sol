// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICToken} from "./interfaces/ICToken.sol";
import {IMoonwellMarket} from "./interfaces/IMoonwellMarket.sol";
import {ICLGauge, ICLPool, ICLSwapRouter} from "./interfaces/ISlipstream.sol";
import {ChainlinkReader} from "./libraries/ChainlinkReader.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "./libraries/TickMath.sol";

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

/// @dev Aerodrome v2 (AMM) PoolFactory — proves a reward→USDC route exists before a venue is adopted.
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
///         - `reward`        = the reward already claimed into the strategy wallet PLUS the unclaimed
///                             `gauge.earned()`, both priced via the venue's reward feed and marked
///                             NET of the `compoundFeeBps` harvest skim (`_rewardUsdc`).
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
    /// @notice `rerangeTickRange` was asked to place a range for a position holding NEITHER leg.
    error NothingToRerange();
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
    /// @notice A range pair failed `checkRange`: an off-grid or out-of-band width, or a skew outside
    ///         `(0, 1e4)` / the governance band / one that starves a side below a single tickSpacing.
    error OutOfBounds();
    /// @notice An oracle / calm-gate config value is outside the band a guard needs to stay meaningful.
    error OracleParamOutOfRange();
    // The selectors below match same-signature declarations in `LeveragedAerodromeCLStrategy`.
    /// @notice `targetLtvBps > maxLtvBps` at init.
    error TargetLtvExceedsMax();
    /// @notice `minHealthBps` below the 10500 floor.
    error MinHealthTooLow();
    /// @notice `maxLtvBps` at or above the Moonwell USDC collateral factor.
    error MaxLtvExceedsCF();
    /// @notice `minHealthBps × maxLtvBps >= 1e8` — the deleverage trigger LTV would sit inside the band (L4).
    error MinHealthMaxLtvConflict();
    /// @notice `minHealthBps × cfBps <= 1e8` — the deleverage trigger LTV would sit at or above the CF (L4).
    error DeleverageTriggerAboveCF();
    /// @notice A non-zero fee rate with a zero recipient.
    error FeeRecipientRequired();
    /// @notice Harvest skim above `MAX_COMPOUND_FEE_BPS`.
    error CompoundFeeTooHigh();
    /// @notice `feeRecipient` is the clone itself — the skim would be a self-transfer, i.e. a silent
    ///         no-op on an init-only field with no setter to fix it.
    error FeeRecipientIsStrategy();
    /// @notice `Comptroller.markets()` failed, returned short, or reported a zero collateral factor.
    error ComptrollerCallFailed();

    // ── Events (DELEGATECALLED, so they log from the STRATEGY's address; mirrored in its ABI) ──

    /// @notice `_measureLeg` could not read `market`'s accrued debt — the Moonwell accrual reverted — so
    ///         that leg's drift was taken as ZERO and the leg went UNHEDGED until the next harvest.
    event HedgeLegMeasureDegraded(address market);

    /// @dev Chainlink USD feeds on Base are 8-decimal; assumed for the USD→USDC scaling.
    uint256 private constant USD_FEED_DECIMALS = 8;

    /// @notice Ceiling on the in-kind harvest skim, in bps (10%) — mirrors `MamoMultiMarketStrategy`'s
    ///         `MAX_COMPOUND_FEE`, the same shape this fee copies. Enforced at init by `checkFeeParams`.
    uint16 internal constant MAX_COMPOUND_FEE_BPS = 1000;

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
        uint16 compoundFeeBps; // `Layout.compoundFeeBps` — haircuts the reward term (see `_rewardUsdc`)
    }

    /// @notice The net-equity oracle NAV of the whole levered book, in USDC (6dp).
    /// @param c          Valuation config.
    /// @param strategy   The strategy clone (holds collateral, debt, idle USDC).
    /// @param tickLower  Lower tick of the CL position (from `NPM.positions`).
    /// @param tickUpper  Upper tick of the CL position.
    /// @param liquidity  CL liquidity (from `NPM.positions`); 0 ⇒ no CL legs.
    /// @return navUsdc   `idle + collateral + clLegs + idleLegs + reward − debt` in USDC 6dp (vault float
    ///                   excluded — M2 deposit/redeem symmetry).
    /// @dev Fail-closed: reverts on any oracle/calm failure and on non-positive equity. Prices deposits
    ///      only; the reward feed is read only when there IS reward value (`_rewardUsdc`).
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

    /// @notice The Moonwell USDC collateral factor in bps, read from `Comptroller.markets(mUsdc_)` at init.
    /// @dev Fail-closed on a failed/short call or a zero factor; the 2nd returned word is 1e18-scaled.
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

    /// @notice The INIT-ONLY shape check on the two governance bands every later `checkRange` is measured
    ///         against, fixed for the clone's life.
    /// @dev Width bounds on the `tickSpacing_` grid, `minWidth_ >= 2 × spacing` (an aligned range is never
    ///      empty), `min <= max`, `maxWidth_` inside the tick domain (`skewedTickRange` can put the whole
    ///      width on ONE side). Skew `0 < min <= max < 10000`, so the band can only TIGHTEN `checkRange`'s
    ///      open `(0, 1e4)` interval.
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

    /// @notice The five VENUE-SCOPED risk invariants: the LTV band's own shape and its relationship to the
    ///         destination market's collateral factor (bps). Shared by `checkRiskParams` and
    ///         `LeveragedAeroVenue.applyVenue`, which re-runs them at every `migrateVenue`.
    /// @dev L4: permissionless deleverage triggers at `LTV = 1e8 / minHealthBps`; the last two rungs bracket
    ///      it above `maxLtvBps` (grief-deleverage) and below `cfBps` (liquidation precedes the rescue), so
    ///      the ordering is `target ≤ maxLtv < 1e8/minHealth < cf`. CONFIG-TIME ONLY: a CF that Moonwell
    ///      cuts post-init reopens that window until the next `migrateVenue` re-reads it.
    function checkLtvBand(uint16 targetLtvBps, uint16 maxLtvBps, uint16 minHealthBps, uint16 cfBps) public pure {
        if (targetLtvBps > maxLtvBps) revert TargetLtvExceedsMax();
        if (minHealthBps < 10500) revert MinHealthTooLow();
        if (maxLtvBps >= cfBps) revert MaxLtvExceedsCF();
        if (uint256(minHealthBps) * uint256(maxLtvBps) >= 1e8) revert MinHealthMaxLtvConflict();
        if (uint256(minHealthBps) * uint256(cfBps) <= 1e8) revert DeleverageTriggerAboveCF();
    }

    /// @notice The INIT-ONLY numeric ladder over the risk and oracle params, in the strategy's original
    ///         rung order — observable, since each rung has its own typed error.
    /// @dev The oracle rungs bound each knob so a misconfig cannot silently disable a guard: `maxDelay ∈
    ///      (0, 7 days]`, `gracePeriod ∈ [0, 1 days]`, `twapWindow ∈ (0, 1 days]` (0 disables the
    ///      calm-gate), `calmDeviationTicks ∈ (0, 5000]`, `maxSlippageBps ∈ (0, 1000]`. The fee rungs are a
    ///      separate call because a 12-argument version overflowed the Yul stack allocator's reach.
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

    /// @notice The INIT-ONLY fee rung: a non-zero skim needs a recipient, the skim is capped, and the
    ///         recipient is not the clone itself.
    /// @dev A zero skim with a zero recipient stays legal (a fee-free clone). This runs under
    ///      `initialize`'s DELEGATECALL, so `address(this)` IS the clone: a recipient equal to it would
    ///      make every skim a self-transfer — the fee silently never leaves, on a field with no setter.
    ///      `view`, not `pure`, only because of that `address(this)` read.
    function checkFeeParams(uint16 compoundFeeBps, address feeRecipient) public view {
        if (compoundFeeBps != 0 && feeRecipient == address(0)) revert FeeRecipientRequired();
        if (compoundFeeBps > MAX_COMPOUND_FEE_BPS) revert CompoundFeeTooHigh();
        if (feeRecipient == address(this)) revert FeeRecipientIsStrategy();
    }

    /// @notice THE ONE PREDICATE validating a `(width, skewBps)` pair before `skewedTickRange` consumes it
    ///         — shared by `_initialize` (genesis) and `rerange` (per-cycle), so the two cannot drift.
    /// @dev `skewBps_` is the fraction of `width_` placed BELOW the pool tick on a 1e4 scale (5000 =
    ///      centred). Width on the `tickSpacing_` grid and inside `[minWidth_, maxWidth_]`; skew inside the
    ///      OPEN `(0, 10000)` and the governance band. The span guard (BOTH sides at least one
    ///      `tickSpacing`) is span-based, not a flat bps band, because it is what keeps the DOWN-aligned
    ///      range STRICTLY BRACKETING the pool tick — the invariant `assetModeSplit` needs to size a fresh
    ///      range two-sided. So at the `2 × tickSpacing_` floor only the centred geometry passes.
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
    ///         fraction of `width` (1e4 scale) is placed BELOW the current tick and the EXACT COMPLEMENT
    ///         above, so 5000 is centred and 3500 puts 35% of the width below spot.
    /// @dev Placement is grid-approximate: both bounds round DOWN, so the realised split and width can each
    ///      drift up to one `tickSpacing` (aligning up would silently widen past the init band). Both are
    ///      clamped into the aligned tick domain — `width` is capped at `2 × MAX_TICK` at init so
    ///      `currentTick ± width` cannot wrap int24, and `maxAligned` is on the grid so a clamped range
    ///      stays mintable. The result STRICTLY BRACKETS the current tick whenever both spans are at least
    ///      one `tickSpacing`, which is what `checkRange` enforces.
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

    /// @notice The range a RE-RANGE should open, given the legs the unwind actually collected: two-sided
    ///         input → exactly `skewedTickRange`; one-sided input → a band of the full `width` placed
    ///         wholly on the side the surviving leg can fill (token0-only strictly ABOVE spot, token1-only
    ///         AT/BELOW it), so the mint cannot demand a leg the book does not hold and `skewBps` has no
    ///         meaning there. NOT a recentre — the band abuts spot and only becomes two-sided if price
    ///         returns; recentring a departed book needs `flatten` + `redeploy`.
    /// @dev Reads the manipulable spot tick — the caller calm-gates first, as for `skewedTickRange`.
    function rerangeTickRange(address pool, int24 tickSpacing, uint24 width, uint16 skewBps, uint256 amt0, uint256 amt1)
        public
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        if (amt0 != 0 && amt1 != 0) return skewedTickRange(pool, tickSpacing, width, skewBps);
        if (amt0 == 0 && amt1 == 0) revert NothingToRerange();
        (, int24 currentTick,,,,) = ICLPool(pool).slot0();
        int24 anchor = _alignTick(currentTick, tickSpacing);
        int24 maxAligned = _alignTick(TickMath.MAX_TICK, tickSpacing);
        if (amt1 == 0) {
            // token0 only → strictly ABOVE spot.
            tickLower = anchor + tickSpacing;
            if (tickLower > maxAligned) tickLower = maxAligned;
            tickUpper = tickLower + int24(uint24(width));
            if (tickUpper > maxAligned) tickUpper = maxAligned;
            if (tickUpper <= tickLower) tickLower = tickUpper - tickSpacing;
        } else {
            // token1 only → AT/BELOW spot.
            tickUpper = anchor;
            if (tickUpper < -maxAligned) tickUpper = -maxAligned;
            tickLower = tickUpper - int24(uint24(width));
            if (tickLower < -maxAligned) tickLower = -maxAligned;
            if (tickUpper <= tickLower) tickUpper = tickLower + tickSpacing;
        }
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

    /// @notice ASSET-MODE **lever-up** sizing, closed form. Given the NAIVE debt delta `borrowUsd6` (USDC
    ///         face, 6dp) an `adjustLeverage` retarget wants to add against unchanged collateral, returns the
    ///         leg-A units to borrow and the USDC that must pair with them in the stored range — reverting
    ///         `InsufficientIdleForLeverUp(needed, available)` when the book cannot fund that pairing.
    /// @dev The pairing relation is `assetModeSplit`'s, with `A` fixed instead of the split point:
    ///      `A = borrowUsd6 · 100 · 10^dA / pA` and `U′ = A · needU / needA`, through the SAME
    ///      `_rangeRatio` / `_legABorrow` helpers, so genesis and lever-up cannot drift.
    ///      `U′` may have to come out of COLLATERAL (`supplyIdle` parks idle USDC in Moonwell), which
    ///      shrinks the base the LTV is measured against: the naive delta lands the book at
    ///      `Δ / (C − U′) > ltv` and can trip `maxLtvBps`. So the delta is a FIXED POINT — with `U′ = m·Δ`
    ///      and a raw balance `R` that costs no collateral, `Δ = (borrowUsd6 + ltv·R) / (1 + ltv·m)`, which
    ///      the two `mulDiv`s below compute. `A` and `U′` scale by the same factor, so the range ratio is
    ///      untouched, and `R ≥ U′` clamps the factor to 1 — the uncorrected, pre-correction behaviour.
    /// @param borrowUsd6     The NAIVE debt delta (`ltv·C − D`, USDC face 6dp), corrected below.
    /// @param availableUsdc  USDC `U′` may be funded from — raw balance PLUS redeemable mUSDC collateral
    ///                       (`usdcAvailable`); the caller materialises the raw shortfall before borrowing.
    /// @param rawUsdc        The raw ERC-20 balance alone — the part of `U′` that costs no collateral.
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
        // Fixed-point rescale by `(b + ltv·R) / (b + ltv·u0)` (see the @dev; `10_000` carries the bps
        // scale). `den > 0` — the manager only levers UP on a positive delta; the clamp is the `R ≥ U′` arm.
        uint256 den = 10_000 * borrowUsd6 + targetLtvBps * u0;
        uint256 num = 10_000 * borrowUsd6 + targetLtvBps * rawUsdc;
        if (num > den) num = den;
        legABorrow = Math.mulDiv(a0, num, den);
        lpUsdc = Math.mulDiv(u0, num, den);
        if (lpUsdc > availableUsdc) revert InsufficientIdleForLeverUp(lpUsdc, availableUsdc);
    }

    /// @notice USDC the strategy can spend RIGHT NOW without touching the LP: its raw ERC-20 balance PLUS
    ///         what its Moonwell mUSDC collateral is worth (both 6dp face).
    /// @dev THE FUNDING BASIS every site that used to bound itself by `balanceOf(this)` must use, since
    ///      `supplyIdle` can park the whole raw balance in Moonwell; the caller then materialises the raw
    ///      shortfall via `redeemUnderlying`. Oracle-free by construction. ALSO the flat-book NAV term —
    ///      pricing a `tokenId == 0` book off the raw balance alone would value the fund at 0. Debt is
    ///      deliberately NOT subtracted: a flat book has none.
    function usdcAvailable(address usdc, address mUsdc, address who) public view returns (uint256) {
        return IERC20(usdc).balanceOf(who) + _collateralUnderlying(mUsdc, who);
    }

    // ── Slipstream swap plumbing ──

    /// @notice Slipstream `exactInputSingle` (plus the approval), as ONE definition.
    /// @dev VENUE PLUMBING ONLY — every decision stays with the caller: which token, how much, and what
    ///      `minOut` bound applies.
    /// @param tokenIn     Token sold. Never equal to `tokenOut` — callers guard the identity case.
    /// @param tickSpacing tickSpacing of the `tokenIn`↔`tokenOut` SWAP pool (NOT any LP pool's).
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
    /// @dev The mirror of `swapExactIn`: the caller derives `amountInMax` and does the repay. The trailing
    ///      `forceApprove(router, 0)` is load-bearing and must run on BOTH branches — an exact-output swap
    ///      generally spends LESS than `amountInMax` (a swallowed failure, none of it), so the residue
    ///      would otherwise stand as an allowance to the router.
    ///      `bestEffort` exists because an exact-output swap has NO partial fill: an unaffordable
    ///      `amountOut` REVERTS rather than buying what it can, which on the OPPORTUNISTIC full-redeem
    ///      Phase 1 cover bricked the whole redeem (`emergencyRedeem` included) across the band
    ///      `0 < budget < needed`. Callers whose cover is MANDATORY pass `false` and keep the revert. The
    ///      `try` lives HERE because the delegatecalled manager cannot catch this library's frames.
    /// @param tokenOut    Token bought. Never equal to `tokenIn` — callers guard the identity case.
    /// @param tickSpacing tickSpacing of the `tokenIn`↔`tokenOut` SWAP pool.
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

    /// @notice The Aerodrome v2 VOLATILE pool `swapAeroToUsdc` would route `reward → usdc` through, or
    ///         `address(0)` when no such pool is registered — the venue-validation probe for the reward leg.
    /// @dev Byte-for-byte the route `swapAeroToUsdc` builds. Reads the factory, not the router's CREATE2
    ///      predictor, which answers nonzero for pairs that were never deployed.
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

    /// @notice Neutralise the ACCRUED BORROW INTEREST on the borrowed legs by buying exactly that much of
    ///         each leg with harvest proceeds and repaying it to Moonwell — turning a financing cost that
    ///         would otherwise accumulate as unintended SHORT exposure into plain NAV drag.
    /// @dev THE MEASURE IS `debt − hedged`, NOT `debt − lpLeg`: a CL position's leg composition moves with
    ///      price by design, so `debt − lpLeg` mixes interest with the LP mechanism working as intended and
    ///      closing all of it every harvest would make `compound` a momentum-chasing delta rebalancer.
    ///      `Layout.hedgedDebtA/B` is instead a pure ACCOUNTING quantity — the borrowed principal the LP
    ///      side was funded with, maintained at the chokepoints that change it (`_borrowLegA`/
    ///      `_borrowHalfEach` add, `_repay` clamps down, `redeemUnwindImpl` scales pro-rata) — and is
    ///      PRICE-INDEPENDENT, so the difference isolates interest exactly. Compound-fork markets capitalise
    ///      interest into `principal` on every borrow/repay, so `borrowBalanceStored` right after one IS
    ///      that basis; `debt` is read AFTER accruing — see `_measureLeg`. Repaying rather than
    ///      buying-and-adding avoids re-levering the book and lands the cost as NAV drag.
    ///      BOUNDED AND GRACEFUL: `budgetUsdc` is a hard ceiling and is the HARVEST's own USDC — never
    ///      stayers' idle, never collateral. A short budget hedges what it can, the remainder stays in
    ///      `debt − hedged` for the next harvest, and this never reverts the harvest for insufficiency.
    ///      Only this call's own swap delta is repaid, so an existing idle leg remainder is never consumed.
    ///      In asset-mode (`marketB == 0`) leg B is the unit of account, carries no debt, and is not hedged.
    ///      PRO-RATA: both drifts are MEASURED first, then the budget is split `budget × costᵢ / total` with
    ///      leg B taking the exact complement. Measuring first is what stops a leg going unhedged, and its
    ///      residual short concentrating, whenever the other leg's drift exceeded the whole harvest — a
    ///      touch that is fail-open per leg, see `_measureLeg`.
    function hedgeBorrowInterest(HedgeBook memory b) public returns (uint256 spent) {
        if (b.budgetUsdc == 0) return 0;
        uint256 pUsdc = readUsd8(b.usdcFeed, b.sequencerFeed, b.maxDelay, b.gracePeriod);

        // ── MEASURE (both legs, before a single USDC is committed) ──
        LegDrift memory dA = _measureLeg(b, b.marketA, b.feedA, b.decimalsA, b.hedgedA, pUsdc);
        // Leg B drifts too whenever it is BORROWED — the two-borrowed-legs shape LPs both borrows against
        // each other. `marketB == 0` is the asset-mode book, where leg B IS the unit of account, is never
        // borrowed, and cannot drift: `dB` stays zero ⇒ leg A is allocated the whole budget.
        LegDrift memory dB;
        if (b.marketB != address(0)) {
            dB = _measureLeg(b, b.marketB, b.feedB, b.decimalsB, b.hedgedB, pUsdc);
        }

        uint256 total = dA.costUsdc + dB.costUsdc;
        if (total == 0) return 0; // no drift on either leg, or both priced below 1 USDC unit

        // ── ALLOCATE pro-rata by USD cost (`_spendLeg` caps each leg at its own cost) ──
        uint256 budgetA = Math.mulDiv(b.budgetUsdc, dA.costUsdc, total);

        // ── SPEND ──
        spent = _spendLeg(b, b.marketA, b.legA, b.spacingA, dA, budgetA);
        if (b.marketB != address(0)) {
            // The EXACT complement, not a second `mulDiv`: leg A's rounding lands here, not stranded.
            spent += _spendLeg(b, b.marketB, b.legB, b.spacingB, dB, b.budgetUsdc - budgetA);
        }
    }

    /// @dev One leg's MEASURED state, carried into `hedgeBorrowInterest`'s spend phase, so
    ///      `borrowBalanceCurrent` is read once per leg and feeds both the allocation and the buy/repay.
    struct LegDrift {
        uint256 amount; // unhedged accrued interest in LEG units (`debt − hedged`); the repay cap
        uint256 costUsdc; // what closing ALL of `amount` would cost (USDC 6dp); the allocation weight
        uint256 num; // `price8 × 1e6` — the `_tokenToUsdc` numerator, kept as a factor
        uint256 den; // `10^decimals × pUsdc` — ...and its denominator, so the INVERSE is the same numbers
    }

    /// @dev THE MEASURE PHASE for one leg of `hedgeBorrowInterest`: no USDC is committed, and the result is
    ///      the ONLY view of this leg the spend phase gets.
    ///      ACCRUE, *THEN* MEASURE — `borrowBalanceCurrent`, never `borrowBalanceStored`. Nothing earlier in
    ///      a `compound` accrues a borrow leg, so interest since the market's last accrual is un-capitalised
    ///      and INVISIBLE to a stored read, then capitalised moments later by this function's own repay: on
    ///      a 7-day fork warp a true 15,412-sat drift showed as 5 sats stored, so the harvest hedged 4. It
    ///      costs no extra call, and Moonwell's `require(... == NO_ERROR)` wrapper makes the fail-closed
    ///      behaviour structural where a bare `accrueInterest()` returns a code without writing the index.
    ///      Measuring is UNCONDITIONAL — an early budget gate is what let a starved leg go unmeasured and
    ///      therefore unhedged — which makes this state-changing touch a liveness dependency of `compound`
    ///      on BOTH legs, so it is `try`/`catch`ed: a failure degrades THIS leg's drift to zero, the other
    ///      leg gets the whole budget, `compound` completes, and the unmeasured interest stays in
    ///      `debt − hedged` exactly as a budget shortfall does. Never silent
    ///      (`HedgeLegMeasureDegraded`), though the `catch` cannot tell the expected causes from an
    ///      out-of-gas. A leg with no drift reads no feed, so a quiet book adds no oracle dependency.
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

        // The `_tokenToUsdc` basis kept as its two factors, so the INVERSE (USDC→leg, for the min-out) is
        // the same numbers read the other way.
        d.num = readUsd8(feed, b.sequencerFeed, b.maxDelay, b.gracePeriod) * 1e6;
        d.den = (10 ** uint256(legDecimals)) * pUsdc;
        d.costUsdc = Math.mulDiv(d.amount, d.num, d.den);
    }

    /// @dev THE SPEND PHASE for one leg: buy `min(cost, budget)` USDC worth of the leg and repay it. Uses
    ///      only the `LegDrift` the measure phase produced — never a second market read — and a short
    ///      budget hedges what it can, leaving the remainder in `debt − hedged` for the next harvest.
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
    ///      degenerates: a 0 `needU` would demand a borrow with no USDC to pair, a 0 `needA` no borrow at
    ///      all (an unhedged USDC-only add). Both fail closed. A rerange only unblocks this while spot is
    ///      still INSIDE the stored band; once it has left, the cure is `flatten` + `redeploy`.
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

    /// @dev The `Config`-free form of the above, so the NAV term and `usdcAvailable` share ONE expression.
    function _collateralUnderlying(address mUsdc, address who) private view returns (uint256) {
        uint256 cBal = ICToken(mUsdc).balanceOf(who);
        if (cBal == 0) return 0;
        return (cBal * ICToken(mUsdc).exchangeRateStored()) / 1e18;
    }

    /// @dev THE WHOLE GAUGE-REWARD CLAIM, in USDC face (6dp): the balance ALREADY CLAIMED into the strategy
    ///      wallet (every `_unwindLiquidity` auto-claims a tranche via `gauge.withdraw`) PLUS the
    ///      still-UNCLAIMED `gauge.earned(strategy, tokenId)`. The unclaimed half is the bigger one — a
    ///      harvest spends MOST of its life in the gauge, so pricing only the held balance left the
    ///      deposit-before-`compound` capture open (~4.5% of a 100k deposit, post-fee, in one block).
    ///      The two terms hand off cleanly: Slipstream reverts `"NA"` on `earned()` for an unstaked tokenId,
    ///      which is exactly when the tranche has just landed in the held balance. But `catch {}` is
    ///      indiscriminate — an out-of-gas, a gauge upgrade or a non-Slipstream migration silently drops the
    ///      earned term to zero, restoring the pre-fix mis-pricing; that trade stands (`nav()` must not
    ///      revert on a reward probe) and `_earnedRead` / `rewardReadOk` make it observable.
    ///      Gated on the SUM, since `earned()` is non-zero with a zero balance in the steady state.
    ///      FAIL-CLOSED on a stale reward feed while there IS reward value — valuing it at 0 would re-create
    ///      the mis-pricing this term closes. Accepted consequence: a stale reward feed blocks deposits and
    ///      the priced fast redeem until `compound` clears both halves (the async queue never reads `nav()`).
    ///      DECIMALS are pinned at 18, matching the `1e18` divisor `compoundImpl` / `_sellRewardBalance`
    ///      apply; `applyVenue` enforces that at init and at every migration and rejects a reward token
    ///      equal to either leg. `c.rewardFeed` is the SAME `Layout.aeroUsdFeed` the sale floor uses.
    ///
    ///      MARKED NET OF `compoundFeeBps` (floored, as `compoundImpl`'s own skim rounds): every path that
    ///      realizes a tranche skims in kind first, so only that fraction can reach the book.
    ///      Gross made navPerShare step DOWN at each harvest — an exit timed just before one dodged its
    ///      share of the fee onto the stayers.
    ///      THE MARK MATCHES REALIZATION ON EVERY LIVE PATH: `compound`, `flatten` and the async redeem all
    ///      skim (`LeveragedAeroVenue._sellRewardBalance`), so an understated navPre can no longer over-mint
    ///      a depositor against a gross realization. The only residual asymmetry is the TERMINAL settle,
    ///      which realizes gross — holder-favourable, and the fund is ending.
    function _rewardUsdc(Config memory c, address strategy, uint256 pUsdc) private view returns (uint256) {
        uint256 amt = IERC20(ICLGauge(c.gauge).rewardToken()).balanceOf(strategy);
        (uint256 e,) = _earnedRead(c.gauge, strategy, c.tokenId);
        amt += e;
        if (amt == 0) return 0;
        amt = Math.mulDiv(amt, 10_000 - uint256(c.compoundFeeBps), 10_000);
        return _usdcValue(amt, 18, _readUsd8(c, c.rewardFeed), pUsdc);
    }

    /// @dev THE gauge-side `earned()` read — the amount AND whether it answered — as ONE definition, so
    ///      the priced term (`_rewardUsdc`) and the monitoring flag (`rewardReadOk`) cannot drift apart.
    ///      `tokenId == 0` → `(0, true)`: a flat book has nothing to read, and `false` would make the
    ///      marker scream through every `settle`→`execute` gap. `gauge.code.length == 0` → `(0, false)`
    ///      WITHOUT the call, and that branch is LOAD-BEARING because a `try` does NOT catch it: solc emits
    ///      its `extcodesize` guard OUTSIDE the protected region, so an empty-code gauge reverts
    ///      UNCATCHABLY (`nav()` is unaffected — `_rewardUsdc`'s `rewardToken()` read fail-closes first).
    ///      Otherwise the `try`: any revert is `(0, false)`, benign `"NA"` and real outages alike, since
    ///      they are indistinguishable onchain and `"NA"` is transient.
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
    ///         `earned()` read that `nav()` prices is FAILING, `true` when it answers or there is nothing
    ///         to read. `false` means `nav()` understates the book by the unclaimed reward accrual.
    /// @dev State, not an event: `nav()` is `view` and cannot emit, and this fail-open is a CONDITION that
    ///      recurs on every deposit until someone intervenes. Strictly behaviour-neutral — nothing in the
    ///      pricing path reads it, and it must not revert. Two scalars rather than a `Config` for the
    ///      caller's ~230 bytes of EIP-170 headroom, read from the same `Layout` slots `_config()` uses.
    ///      The subject is `address(this)`, i.e. the strategy clone under delegatecall — called on the
    ///      deployed LIBRARY the answer is about the wrong account, so use `strategy.rewardReadOk()`.
    /// @param tokenId  `Layout.tokenId`; 0 ⇒ flat book, nothing to read ⇒ `true`.
    /// @return ok      `false` iff there IS a staked tokenId and the `earned()` read fails or cannot be made.
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
    ///         how much USDC the deficit buy may spend, how much of the surplus leg to sell for it, and the
    ///         floor that sell must clear. Pure — the caller supplies the hardened prices.
    /// @dev `buyMax` is the oracle CEILING on the exact-output cover, so a sandwiched permissionless
    ///      `deleverage` cannot overpay past oracle + `slipBps` (H1). `sellAmt` is NEED-SIZED and capped at
    ///      `surplusBal` — grossed up by `slipBps` a SECOND time so a sell filling on `sellFloor` still
    ///      raises the ceiling-priced buy — because selling more would liquidate a delta-neutral remainder
    ///      into an unrecorded short. `sellFloor` derives from `sellAmt`, not `surplusBal`, or it would be
    ///      unreachable. `surplusBal == 0` returns `(buyMax, 0, 0)` without touching `pSurplus`.
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
    ///         `oracleValue(amountSold) × (1 − maxSlippageBps)` idiom the other priced sweeps use.
    /// @dev FAIL-CLOSED HERE, DEADMAN-SAFE AT THE CALL SITE: this reverts on a stale feed / down sequencer
    ///      like every other priced path, and the caller reaches it through a try-able external hop
    ///      (`LeveragedAerodromeCLStrategy.redeemSweepFloors`) that treats a revert as "floors = 0" — which
    ///      is the point, since `emergencyRedeem` routes through step E and a hard revert there would turn a
    ///      value guard into a fund-freeze, while a sandwicher cannot MAKE a feed stale. Coarse by design:
    ///      one unreadable feed drops BOTH floors, and each leg's feed is read only when that leg sells.
    ///      Slippage is borne by the REDEEMER — the stayers' `keep` is snapshot BEFORE the sweep.
    /// @param cbAmt     Leg-B units ACTUALLY being sold (0 in asset-mode — that sweep is the identity).
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
