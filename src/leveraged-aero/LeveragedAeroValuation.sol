// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICToken} from "./sherwood/interfaces/ICToken.sol";
import {IMoonwellMarket} from "./sherwood/interfaces/IMoonwellMarket.sol";
import {ICLPool} from "./sherwood/interfaces/ISlipstream.sol";
import {ChainlinkReader} from "./sherwood/libraries/ChainlinkReader.sol";
import {LiquidityAmounts} from "./sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "./sherwood/libraries/TickMath.sol";

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

    /// @dev Chainlink USD feeds on Base are 8-decimal; assumed for the USD→USDC scaling.
    uint256 private constant USD_FEED_DECIMALS = 8;

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
        assets += _usdcValue(IERC20(c.cbBTC).balanceOf(strategy), c.cbBTCDecimals, pCbBTC, pUsdc);
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
        uint8 dec;
        (price, dec) = ChainlinkReader.readUsd(feed, c.sequencerFeed, c.maxDelay, c.gracePeriod);
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
    ///      Logic is unchanged — do NOT edit this function without also updating the
    ///      strategy's `_mintAndStake` caller.
    function _calmGate(Config memory c) public view {
        if (c.twapWindow == 0) revert InvalidConfig();
        (, int24 spotTick,,,,) = ICLPool(c.pool).slot0();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = c.twapWindow;
        secondsAgos[1] = 0;
        (int56[] memory cum,) = ICLPool(c.pool).observe(secondsAgos);

        int56 delta = cum[1] - cum[0];
        int24 twapTick = int24(delta / int56(uint56(c.twapWindow)));
        // Round toward negative infinity (Uniswap convention) when the cumulative delta is
        // negative and does not divide evenly, so the mean matches the TWAP oracle.
        if (delta < 0 && (delta % int56(uint56(c.twapWindow)) != 0)) twapTick--;

        int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        if (uint24(diff) > c.calmDeviationTicks) revert CalmGateBreached();
    }
}
