// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICToken} from "./sherwood/interfaces/ICToken.sol";
import {IMoonwellMarket} from "./sherwood/interfaces/IMoonwellMarket.sol";
import {ICLPool, ICLSwapRouter} from "./sherwood/interfaces/ISlipstream.sol";
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

/// @title  LeveragedAeroValuation
/// @notice Net-equity **oracle** NAV for the leveraged Aerodrome CL strategy. This is
///         the single safety-critical computation — it prices DEPOSITS, so a wrong
///         sign / decimal / overflow silently mis-mints shares. Everything here is
///         fail-closed: any oracle staleness, sequencer outage, grace window, or a
///         spot/TWAP deviation reverts, and a non-positive net equity reverts — a
///         manipulated price can only *deny* a deposit, never mint cheap shares.
///
///         ```
///         NAV = idleStrategy + collateral + clLegs + idleLegs − debt  (USDC, 6dp)
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

    /// @dev Chainlink USD feeds on Base are 8-decimal; assumed for the USD→USDC scaling.
    uint256 private constant USD_FEED_DECIMALS = 8;

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
        address cbBTCFeed; // Chainlink BTC/USD feed (8dp)
        address wethFeed; // Chainlink ETH/USD feed (8dp)
        address usdcFeed; // Chainlink USDC/USD feed (8dp)
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
    /// @return navUsdc   USDC value of `idle + collateral + clLegs + idleLegs − debt` (vault float
    ///                   excluded — M2 deposit/redeem symmetry; strategy-controlled terms only).
    /// @dev Fail-closed: reverts on any oracle/calm failure (via `ChainlinkReader` and the
    ///      calm-gate) and on non-positive equity. Used to price deposits only.
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

    /// @notice The tickSpacing-aligned range centred on `pool`'s current tick, spanning `width/2` ticks
    ///         each side. Lives here (rather than in `LeveragedAeroManager`, which is at the EIP-170
    ///         margin) alongside `assetModeSplit`, the sizing math that consumes it.
    ///
    /// @dev "Centred" is grid-approximate, not exact. Both bounds round DOWN onto the grid, so the
    ///      realised centre can sit up to one `tickSpacing` below the current tick and the realised
    ///      width can differ from `width` by up to one spacing; when `width / tickSpacing` is ODD the
    ///      half-span is itself off-grid, which is where the skew is largest. Accepted: the band is
    ///      orders of magnitude wider than one spacing, and re-centring exactly would need an align-up
    ///      on one side, silently widening the range past the band validated at init.
    ///
    ///      Both bounds are clamped into the aligned tick domain: `width` is capped at `2 × MAX_TICK` at
    ///      init so the arithmetic cannot wrap int24, but a wide band near either end of the domain
    ///      still pushes a bound past ±MAX_TICK, where `getSqrtRatioAtTick` would revert unhelpfully
    ///      deep inside TickMath. `maxAligned` sits ON the spacing grid by construction, so clamping
    ///      keeps the range mintable rather than merely non-panicking.
    ///
    ///      The returned range always STRICTLY BRACKETS the current tick (`tickLower <= tick <
    ///      tickUpper`) whenever `width >= 2 × tickSpacing`, which init enforces — this is what makes a
    ///      freshly centred range two-sided, and therefore always sizeable by `assetModeSplit`.
    ///
    ///      Callers must calm-gate BEFORE this: it reads the manipulable spot tick.
    function centeredTickRange(address pool, int24 tickSpacing, uint24 width)
        public
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        (, int24 currentTick,,,,) = ICLPool(pool).slot0();
        int24 span = int24(width / 2);
        tickLower = _alignTick(currentTick - span, tickSpacing);
        tickUpper = _alignTick(currentTick + span, tickSpacing);
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
    ///      worse for a rebalancer than a loud, diagnosable `(needed, available)` refusal.
    ///
    ///      Ratio basis / overflow / one-sided-range behaviour are exactly `assetModeSplit`'s (shared
    ///      `_rangeRatio`): the pool's live `sqrtP` (calm-gate is the caller's job), `Math.mulDiv` for
    ///      the 512-bit intermediate, and `DegenerateRange` when the stored range is one-sided.
    /// @param pool         The Slipstream CL pool (read for the live `sqrtP`).
    /// @param tickLower    Lower tick of the STORED range the add will target.
    /// @param tickUpper    Upper tick of that range.
    /// @param borrowUsd6   The debt delta to add, USDC face (6dp).
    /// @param idleUsdc     The strategy's live idle USDC balance — the only funding source for `U′`.
    /// @param legADecimals Leg-A token decimals.
    /// @param legAIsToken0 True when leg A sorts as the pool's token0 (`Layout.wethIsToken0`).
    /// @param legAPrice8   Leg-A USD price, 8dp, from a hardened Chainlink read.
    /// @return legABorrow  `A` — leg-A units to borrow.
    /// @return lpUsdc      `U′` — USDC that must pair with `A` in the range (≤ `idleUsdc`).
    function assetModeLeverUpPair(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 borrowUsd6,
        uint256 idleUsdc,
        uint8 legADecimals,
        bool legAIsToken0,
        uint256 legAPrice8
    ) public view returns (uint256 legABorrow, uint256 lpUsdc) {
        (uint256 needA, uint256 needU) = _rangeRatio(pool, tickLower, tickUpper, legAIsToken0);
        legABorrow = _legABorrow(borrowUsd6, 10 ** uint256(legADecimals), legAPrice8);
        lpUsdc = Math.mulDiv(legABorrow, needU, needA);
        if (lpUsdc > idleUsdc) revert InsufficientIdleForLeverUp(lpUsdc, idleUsdc);
    }

    // ── Slipstream swap plumbing ──

    /// @notice Slipstream `exactInputSingle` (plus the approval), as ONE definition.
    /// @dev VENUE PLUMBING ONLY — every decision stays with the caller: which token, how much (and the
    ///      caps that bound it), and what `minOut` bound applies. `LeveragedAeroManager` calls this from
    ///      `_swapUsdcExactIn` and `_sweepLegToUsdc` AFTER their identity guards / balance caps, and
    ///      `_hedgeLeg` below calls it for the interest-drift buy, so the `ExactInputSingleParams`
    ///      construction exists once instead of three times. Relocated out of the manager for EIP-170
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
    ///      left standing as an allowance to the router.
    /// @param router      Slipstream CL SwapRouter.
    /// @param tokenIn     Token sold (the unit of account, at every current call site).
    /// @param tokenOut    Token bought. Never equal to `tokenIn` — callers guard the identity case.
    /// @param tickSpacing tickSpacing of the `tokenIn`↔`tokenOut` SWAP pool.
    /// @param amountOut   Exact output required.
    /// @param amountInMax Ceiling on the input; the swap reverts rather than exceeding it.
    function swapExactOut(
        address router,
        address tokenIn,
        address tokenOut,
        int24 tickSpacing,
        uint256 amountOut,
        uint256 amountInMax
    ) public {
        IERC20(tokenIn).forceApprove(router, amountInMax);
        ICLSwapRouter(router).exactOutputSingle(
            ICLSwapRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                sqrtPriceLimitX96: 0
            })
        );
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
    ///      accruing the market — see `_hedgeLeg` for why the stored index is not good enough here.
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
    ///      identity swap that `_swapUsdcExactIn` guards against is unreachable from here.
    /// @param b       The whole book's inputs; see `HedgeBook`.
    /// @return spent  Total USDC spent across both legs (0 when there is no drift or no budget).
    function hedgeBorrowInterest(HedgeBook memory b) public returns (uint256 spent) {
        if (b.budgetUsdc == 0) return 0;
        uint256 pUsdc = readUsd8(b.usdcFeed, b.sequencerFeed, b.maxDelay, b.gracePeriod);
        spent = _hedgeLeg(b, b.marketA, b.legA, b.feedA, b.spacingA, b.decimalsA, b.hedgedA, b.budgetUsdc, pUsdc);
        // Leg B drifts too whenever it is BORROWED — the two-borrowed-legs shape LPs both borrows against
        // each other, so both accrue interest the LP never grows to match. `marketB == 0` is the
        // asset-mode book, where leg B IS the unit of account, is never borrowed, and cannot drift.
        if (b.marketB != address(0)) {
            // `budgetUsdc - spent`: leg A already committed its share of the one shared ceiling.
            spent += _hedgeLeg(
                b, b.marketB, b.legB, b.feedB, b.spacingB, b.decimalsB, b.hedgedB, b.budgetUsdc - spent, pUsdc
            );
        }
    }

    /// @dev One leg of `hedgeBorrowInterest`. See that function's header for the measure, the
    ///      repay-vs-add decision, the budget bound and the graceful-degradation contract.
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
    ///      `budgetUsdc == 0` is checked BEFORE the call so a leg whose share of the shared ceiling was
    ///      already spent by the other leg does not pay for an accrual it cannot act on.
    function _hedgeLeg(
        HedgeBook memory b,
        address market,
        address leg,
        address feed,
        int24 spacing,
        uint8 legDecimals,
        uint256 hedged,
        uint256 budgetUsdc,
        uint256 pUsdc
    ) private returns (uint256 spentUsdc) {
        if (budgetUsdc == 0) return 0;
        uint256 debt = IMoonwellMarket(market).borrowBalanceCurrent(address(this));
        if (debt <= hedged) return 0;
        uint256 drift = debt - hedged;

        // `num/den` is the manager's `_tokenToUsdc` basis, kept as its two factors so the INVERSE
        // (USDC→leg, for the min-out) is the same numbers read the other way and the two cannot drift.
        uint256 num = readUsd8(feed, b.sequencerFeed, b.maxDelay, b.gracePeriod) * 1e6;
        uint256 den = (10 ** uint256(legDecimals)) * pUsdc;
        uint256 spend = Math.mulDiv(drift, num, den);
        if (spend > budgetUsdc) spend = budgetUsdc; // graceful: partial hedge, remainder carries
        if (spend == 0) return 0; // drift priced below 1 USDC unit — leave it to accumulate

        // Oracle-floored exact-IN buy (the `_settleShortfall` posture, not the exact-OUT one): exact-out
        // would REVERT the whole harvest the moment `budgetUsdc` could not cover the drift, and this path
        // must degrade instead. The min-out is the oracle-implied leg amount for `spend`, haircut by
        // `maxSlippageBps`, so a sandwiched buy reverts rather than overpaying.
        uint256 minOut = (Math.mulDiv(spend, den, num) * (10000 - b.maxSlippageBps)) / 10000;
        uint256 legBefore = IERC20(leg).balanceOf(address(this));
        swapExactIn(b.swapRouter, b.usdc, leg, spacing, spend, minOut);
        spentUsdc = spend;

        // Repay ONLY this swap's own proceeds, capped at the measured drift. Capping at `drift` is what
        // keeps `Layout.hedgedDebtA/B` untouched by this repay: post-repay debt is `hedged + (drift −
        // repaid) >= hedged`, so the manager's `_repay` clamp is provably a no-op here and the basis
        // discipline stays single-sited. Any tiny overshoot of the buy stays as an idle leg balance,
        // which is NAV-counted and redeployable.
        uint256 got = IERC20(leg).balanceOf(address(this)) - legBefore;
        uint256 repaid = got < drift ? got : drift;
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
        uint256 cBal = ICToken(c.mUsdc).balanceOf(strategy);
        if (cBal == 0) return 0;
        uint256 rate = ICToken(c.mUsdc).exchangeRateStored();
        return (cBal * rate) / 1e18;
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
