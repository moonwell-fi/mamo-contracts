// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {ICToken, IComptroller, IMoonwellMarket} from "./sherwood/interfaces/IMoonwellMarket.sol";
import {ICLGauge, ICLPool, ICLSwapRouter, INonfungiblePositionManager} from "./sherwood/interfaces/ISlipstream.sol";
import {ChainlinkReader} from "./sherwood/libraries/ChainlinkReader.sol";
import {LiquidityAmounts} from "./sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "./sherwood/libraries/TickMath.sol";

/// @dev Minimal WETH9 interface — wraps native ETH into ERC-20 WETH.
interface IWETH9 {
    function deposit() external payable;
}

/// @dev Minimal Aerodrome v2 (AMM) Router — used for the `compoundImpl` AERO→USDC reward swap
///      (see `AERO_V2_ROUTER`). The CL SwapRouter only serves Slipstream pools.
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

/// @title  LeveragedAeroManager
/// @notice DEPLOYED, delegatecalled venue library for `LeveragedAerodromeCLStrategy`. The clone is at
///         the EIP-170 margin, so the heavy on-venue sequences (supply / borrow / mint / stake /
///         unwind / repay / swap) live here. A `public` library call compiles to `DELEGATECALL`, so
///         this runs in the clone's context: `address(this)` is the clone and `_layout()` resolves to
///         the clone's diamond storage.
///
///         CORRUPTION-CRITICAL slot discipline: `Layout`, `STORAGE_SLOT`, and `_layout()` are
///         byte-identical to the strategy's — they MUST stay in lockstep or a delegatecall reads/
///         writes the wrong slots. Do not reorder `Layout` fields in one file without the other.
///
///         Never touches `vault()` / `proposer()` / shares / fees (those stay in the strategy
///         entrypoints); it only reads config + position state and performs venue calls.
library LeveragedAeroManager {
    using SafeERC20 for IERC20;

    // ── Errors (selectors match the strategy's 1:1, so a test's
    //    vm.expectRevert(LeveragedAerodromeCLStrategy.X.selector) matches a revert thrown here) ──
    error UnhealthyPosition(uint256 ltvBps, uint256 limitBps);
    error InvalidNpmReturn();
    error ExecuteZeroBalance();
    error MoonwellMintFailed(uint256 errCode);
    error MoonwellBorrowFailed(uint256 errCode);
    error NpmMintFailed();
    error NpmApproveFailed();
    error MoonwellRepayFailed(uint256 errCode);
    error MoonwellRedeemFailed(uint256 errCode);
    error InsufficientLiquidity();
    error InsufficientIdle();
    error HealthyNoDeleverage();
    error FeedDecimalsMismatch();
    error ZeroMinOut();
    error BelowOracleFloor(); // compound swap fill < AERO/USD oracle floor (L9)
    error FastRedeemExceedsLtv(uint256 ltvBps, uint256 maxLtvBps); // fast-path redeem would breach maxLtvBps
    error UnsupportedLeg(); // a swap was routed for a token that is neither configured leg

    // ── Constants (compile-time literals, duplicated from the strategy) ──
    /// @dev `deleverage()` repays down to `minHealthBps × (1 + this/1e4)` — a small buffer above the
    ///      minimum so a rescue doesn't land on the threshold and immediately re-trigger.
    uint16 private constant DELEVERAGE_BUFFER_BPS = 500; // +5% above minHealthBps

    /// @dev Aerodrome v2 (AMM) Router on Base — the `compoundImpl` AERO→USDC swap routes through its
    ///      volatile pool, the deepest AERO/USDC liquidity on Base (~$10.4M vs ~$1.2M for the deepest
    ///      Slipstream CL pool, fork-measured). Canonical immutable Base infra.
    address private constant AERO_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    /// @dev Aerodrome v2 PoolFactory on Base (`router.defaultFactory()`), required by the Route.
    address private constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    // ── Diamond storage — Layout/STORAGE_SLOT/_layout()/RedeemRequest byte-identical to
    //    LeveragedAerodromeCLStrategy (delegatecall slot discipline) ──

    /// @dev Escrowed async-redeem request (Lane-B-style, but NO price freeze — shares keep bearing
    ///      PnL until execution, so `cancelRedeem` is not a free look-back option).
    struct RedeemRequest {
        address owner; // request creator; the only address that can cancel / emergency-redeem it
        uint256 shares; // vault shares escrowed in the strategy at request time
        uint256 minAssetsOut; // slippage floor enforced at fulfill (fresh arg at emergencyRedeem)
        uint40 requestedAt; // request timestamp; FULFILL_WINDOW deadman clock anchor
        bool settled; // set once fulfilled / cancelled / emergency-redeemed (double-spend guard)
    }

    /// @dev LEG SLOTS, not token identities: the `weth`/`mWeth`/`wethFeed`/`weth*` members are leg A
    ///      (the natively-wrappable slot), the `cbBTC*` members are leg B. The names are historical —
    ///      neither implies a token. Ordering (`wethIsToken0`) and decimals are derived at init.
    /// @custom:storage-location erc7201:leveraged.aero.cl.storage
    struct Layout {
        // valuation config: token / venue / feed addresses
        address usdc;
        address mUsdc;
        address mCbBTC; // LeveragedAeroValuation.Config.cbBTCMarket
        address mWeth; // LeveragedAeroValuation.Config.wethMarket
        address cbBTC;
        address weth;
        address pool;
        address cbBTCFeed;
        address wethFeed;
        address usdcFeed;
        address sequencerFeed;
        uint256 maxDelay;
        uint256 gracePeriod;
        uint16 calmDeviationTicks;
        uint32 twapWindow;
        // venue / protocol addresses (not in Config)
        address comptroller;
        address npm;
        address gauge;
        address swapRouter;
        int24 tickSpacing;
        // risk params
        uint16 targetLtvBps;
        uint16 maxLtvBps;
        uint16 minHealthBps;
        uint16 maxSlippageBps;
        uint16 usdcCollateralFactorBps; // USDC collateral factor from Moonwell at init (8800 = 88%)
        // position state (all zero pre-deploy / post-settle)
        uint256 tokenId; // active CL position; 0 == flat book
        int24 posTickLower;
        int24 posTickUpper;
        // fee params + state
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        address feeRecipient;
        uint256 hwmPerShare; // HWM nav-per-share (1e18 WAD), 0 until first deposit
        uint256 lastFeeAccrualTimestamp;
        uint256 protocolFeeOwed; // accrued protocol-fee USDC liability (6dp); discharged in redeem/compound/settle
        // ── appended for the L9 compound oracle floor (keep byte-identical in the strategy) ──
        address aeroUsdFeed; // AERO/USD aggregator (8dp) — floors compound()'s AERO→USDC swap
        // ── appended for the escrowed async-redeem queue (keep byte-identical) ──
        uint256 nextRedeemRequestId; // monotonic id cursor for `redeemRequests`
        mapping(uint256 => RedeemRequest) redeemRequests; // id → escrowed async redeem
        // ── appended for any-pool generalization (keep byte-identical) ──
        uint8 cbBTCDecimals; // leg B decimals, read from the token at init
        uint8 wethDecimals; // leg A decimals, read from the token at init
        bool wethIsToken0; // leg A sorts as the pool's token0 (derived from pool.token0() at init)
        bool wethDeliversNative; // leg A's Moonwell market pays native ETH on borrow → wrap it
        int24 cbBTCSwapTickSpacing; // leg B↔USDC swap-pool tickSpacing (NOT the LP pool's)
        int24 wethSwapTickSpacing; // leg A↔USDC swap-pool tickSpacing (NOT the LP pool's)
        // ── LAST fields: appended for the per-cycle rerange width band (keep byte-identical) ──
        uint24 width; // current full range width in ticks (rerange spans width/2 each side)
        uint24 minWidth; // lower bound for a proposer-supplied rerange width
        uint24 maxWidth; // upper bound for a proposer-supplied rerange width
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /// @dev ERC-7201 diamond-storage accessor (byte-identical across strategy + manager).
    function _layout() private pure returns (Layout storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // ── PUBLIC IMPLS (delegatecalled by the strategy entrypoints) ──

    /// @notice Open the levered cbBTC/WETH CL position (body of the strategy's `_execute`).
    ///         supply USDC → enterMarkets → borrow cbBTC+WETH → wrap → mint CL → stake gauge.
    function executeImpl() public {
        uint256 usdcAmt = _supplyCollateral();
        (uint256 cbBTCAmt, uint256 wethAmt) = _computeAndBorrow(usdcAmt);
        _wrapNativeEth();
        _mintAndStake(cbBTCAmt, wethAmt);
        _assertHealthy();
    }

    /// @notice Full proportional unwind to the strategy (body of the strategy's `_settle`). The
    ///         strategy forwards the realized USDC to the vault afterward.
    /// @return realizedUsdc USDC held by the strategy after the unwind.
    function settleImpl() public returns (uint256 realizedUsdc) {
        Layout storage $ = _layout();
        // 1+2. Unstake + remove 100% liquidity + collect (num==den → no restake)
        _unwindLiquidity(1, 1);
        // 3. Repay both Moonwell borrows (handles shortfall)
        _settleRepayDebts();
        // 4. Redeem all remaining mUSDC collateral (debt = 0 now)
        uint256 mBal = ICToken($.mUsdc).balanceOf(address(this));
        if (mBal > 0) {
            uint256 err = ICToken($.mUsdc).redeem(mBal);
            if (err != 0) revert MoonwellRedeemFailed(err);
        }
        // 5. Sweep residual WETH + cbBTC → USDC (Chainlink-bounded min-out)
        {
            (uint256 pBTC, uint256 pETH, uint256 pUsdc) = _readAllPrices();
            uint256 slip = uint256($.maxSlippageBps);
            _swapTokenToUsdc(
                $.weth,
                _tokenToUsdc(IERC20($.weth).balanceOf(address(this)), $.wethDecimals, pETH, pUsdc) * (10000 - slip)
                    / 10000
            );
            _swapTokenToUsdc(
                $.cbBTC,
                _tokenToUsdc(IERC20($.cbBTC).balanceOf(address(this)), $.cbBTCDecimals, pBTC, pUsdc) * (10000 - slip)
                    / 10000
            );
        }
        // 6. Clear position state (flat-book invariant: nav() reads tokenId==0 branch)
        $.tokenId = 0;
        $.posTickLower = 0;
        $.posTickUpper = 0;
        realizedUsdc = IERC20($.usdc).balanceOf(address(this));
    }

    /// @notice Oracle-free proportional unwind: remove f = shares/supply of every leg (body of the
    ///         strategy's `redeem`). Returns the redeemer's USDC.
    /// @dev Idle USDC: the strategy may hold idle USDC from undeployed deposits — the redeemer gets f
    ///      of it, stayers keep (1-f). We snapshot `idleUsdcBefore` and subtract `stayersIdle` at the end.
    function redeemUnwindImpl(uint256 shares, uint256 supply) public returns (uint256) {
        Layout storage $ = _layout();
        // Snapshot idle USDC — stayers keep (1-f) of it.
        uint256 idleUsdcBefore = IERC20($.usdc).balanceOf(address(this));
        uint256 stayersIdle = idleUsdcBefore - Math.mulDiv(idleUsdcBefore, shares, supply);
        // Snapshot the stayers' (1-f) share of any PRE-EXISTING idle leg. A `rerange` recenter
        // leaves a remainder of one borrowed leg (cbBTC or WETH) idle in the strategy — the leg
        // sweep at step E would otherwise hand a partial redeemer 100% of it, skimming the stayers'
        // share. Reserving (1-f) of it keeps redeem oracle-free (stayers' share stays as LEGS, not
        // oracle-valued). Both are ~0 (clean no-op) outside a post-rerange partial redeem.
        uint256 stayersCb = _stayerLeg($.cbBTC, shares, supply);
        uint256 stayersWeth = _stayerLeg($.weth, shares, supply);

        // A — partial CL unwind (pool-based mins, oracle-free).
        _unwindLiquidity(shares, supply);

        // B — repay f of each debt from collected tokens; capture any IL shortfall. The repay is
        // capped at the REDEEMER's own per-leg budget (`legBal − stayersLeg`) so a severe IL
        // shortfall can never consume the stayers' reserved `(1-f)` idle-leg share to over-repay
        // the redeemer's debt. Passing `stayersCb`/`stayersWeth` keeps the genuine shortfall flowing
        // to `cbShort`/`wethShort` → covered from the redeemer's OWN collateral (step C), upholding
        // the §7 invariant ("stayers keep (1-f) of every leg, regardless of price").
        (uint256 cbShort, uint256 wethShort) = _redeemRepayFromCollected(shares, supply, stayersCb, stayersWeth);

        if (shares == supply) {
            // Full redemption — two-phase debt clearance before 100 % collateral redeem.
            //
            // Phase 1 (oracle-free): cover IL shortfall from idle USDC via exact-output swap.
            //   When idle == 0 the calls are safe no-ops (amountInMaximum = 0 → early return).
            if (cbShort > 0) _redeemCoverShortfall($.cbBTC, $.mCbBTC, cbShort, type(uint256).max);
            if (wethShort > 0) _redeemCoverShortfall($.weth, $.mWeth, wethShort, type(uint256).max);
            // Phase 2 (self-fund fallback): if residual debt remains after Phase 1 (idle == 0 case),
            //   redeem mUSDC collateral → swap to deficit token → repay (settle-shortfall pattern).
            //   _settleShortfall reads the oracle only when borrowBalance > 0, so it is a no-op
            //   (oracle-free) when Phase 1 fully covered the shortfall.
            _settleShortfall();
            // Phase 3: all debt cleared — Moonwell now permits 100 % collateral redemption.
            _redeemCollateral(shares, supply);
            // Clear position state (flat-book invariant: no stayers remain after a full redeem).
            $.tokenId = 0;
            $.posTickLower = 0;
            $.posTickUpper = 0;
        } else {
            // Partial redemption: redeem f*collateral first (Finding 1 fix). Each cover buy is
            // capped at the redeemer's OWN budget (`balance − stayersIdle`), recomputed before each
            // call since the first spends USDC. A shortfall (or sandwiched buy) that would need more
            // than the redeemer's slice reverts the whole redeem — fail-safe, never touches stayer idle.
            _redeemCollateral(shares, supply);
            IERC20 usdc = IERC20($.usdc);
            if (cbShort > 0) {
                uint256 bal = usdc.balanceOf(address(this));
                _redeemCoverShortfall($.cbBTC, $.mCbBTC, cbShort, bal > stayersIdle ? bal - stayersIdle : 0);
            }
            if (wethShort > 0) {
                uint256 bal = usdc.balanceOf(address(this));
                _redeemCoverShortfall($.weth, $.mWeth, wethShort, bal > stayersIdle ? bal - stayersIdle : 0);
            }
        }

        // E — sweep residual cbBTC/WETH → USDC, LEAVING the stayers' reserved leg share un-swept
        // (min-out=0; aggregate guard applies). For a full redeem (f=1) or no rerange remainder,
        // stayers* == 0 → sweep all (identical to the prior unconditional sweep). In the common
        // partial case this hands the redeemer exactly f*(idleLeg + LP_leg − debt_leg).
        _sweepLegToUsdc($.cbBTC, stayersCb, 0);
        _sweepLegToUsdc($.weth, stayersWeth, 0);

        // assetsOut = total USDC minus the (1-f) idle-USDC portion that stays for stayers (the
        // stayers' idle-leg share already stayed un-swept above, as legs).
        uint256 usdcFinal = IERC20($.usdc).balanceOf(address(this));
        return usdcFinal > stayersIdle ? usdcFinal - stayersIdle : 0;
    }

    /// @notice Oracle-priced fast-redeem funding (body of the strategy's `redeem`): source `assetsOut`
    ///         USDC from the redeemer's pro-rata idle share FIRST, then free only the remainder from the
    ///         Moonwell mUSDC collateral — no LP touch, no debt repay. `idleShare = f×idle` (f =
    ///         shares/supply, computed by the strategy) caps the idle draw so a partial redeem never
    ///         dips into a stayer's `(1-f)×idle` (the same reservation `redeemUnwindImpl` makes). The
    ///         LTV gate is computed BEFORE the withdraw on the same `_readCollateralDebt` basis as
    ///         `_assertHealthy`, but against the collateral-funded REMAINDER only: a redeem that would
    ///         push post-withdraw LTV above `maxLtvBps` reverts `FastRedeemExceedsLtv` (a typed,
    ///         frontend-routable error — send the user to `requestRedeem`), and `_assertHealthy()` runs
    ///         after as belt. When idle alone covers `assetsOut` (e.g. a flat book), no collateral is
    ///         touched and the LTV gate is skipped. The strategy pays the redeemer + burns shares; the
    ///         idle already held plus the freed collateral cover the payout.
    function fastRedeemImpl(uint256 assetsOut, uint256 idleShare) public {
        Layout storage $ = _layout();
        // Idle-first: draw at most the redeemer's `f×idle` share (also clamped to the live balance);
        // the strategy's payout transfer consumes it implicitly, leaving `(1-f)×idle` for stayers.
        uint256 idle = IERC20($.usdc).balanceOf(address(this));
        uint256 fromIdle = assetsOut < idleShare ? assetsOut : idleShare;
        if (fromIdle > idle) fromIdle = idle;
        uint256 fromCollateral = assetsOut - fromIdle;
        if (fromCollateral == 0) return; // idle fully funds the redeem — collateral + LTV gate untouched

        (uint256 collateralUsdc, uint256 debtUsdc) = _readCollateralDebt();
        uint256 maxLtv = uint256($.maxLtvBps);
        // Predict the post-withdraw LTV on the pre-withdraw prices (collateral shrinks by the collateral-
        // funded remainder, debt unchanged). `>= collateralUsdc` would zero/negate the denominator.
        if (fromCollateral >= collateralUsdc) revert FastRedeemExceedsLtv(type(uint256).max, maxLtv);
        if (debtUsdc > 0) {
            uint256 postLtv = (debtUsdc * 10_000) / (collateralUsdc - fromCollateral);
            if (postLtv > maxLtv) revert FastRedeemExceedsLtv(postLtv, maxLtv);
        }
        _redeemUnderlying($.mUsdc, fromCollateral);
        _assertHealthy(); // authoritative post-op gate (belt over the pre-withdraw prediction)
    }

    /// @notice Public view wrapper over `_readCollateralDebt` for the strategy's `previewRedeem`
    ///         (advisory fast-path gate prediction). Delegatecalled under staticcall — the oracle
    ///         reads inside `_readCollateralDebt` fail-closed (revert) on a down feed, which the
    ///         strategy's `previewRedeem` catches to return `(0,false)`.
    function readCollateralDebtImpl() public view returns (uint256 collateralUsdc, uint256 debtUsdc) {
        return _readCollateralDebt();
    }

    /// @notice Deploy `amount` of idle strategy USDC into the existing levered position
    ///         (body of the strategy's `deployIdle`): supply + borrow + increaseLiquidity.
    function deployIdleImpl(uint256 amount, uint256 minLiquidity) public {
        Layout storage $ = _layout();
        if (amount > IERC20($.usdc).balanceOf(address(this))) revert InsufficientIdle();
        _supplyAmount(amount);
        (uint256 cbBTCAmt, uint256 wethAmt) = _computeAndBorrow(amount);
        _wrapAddRestake(cbBTCAmt, wethAmt, minLiquidity);
        _assertHealthy();
    }

    /// @notice Compound AERO rewards (body of the strategy's `compound`): claim AERO → swap ALL to
    ///         USDC via the Aerodrome v2 volatile pool (deepest AERO/USDC on Base, bounded by
    ///         `minUsdcOut`) → skim up to `skimCap` of the realized USDC for the protocol fee →
    ///         redeploy the remainder at target leverage via `deployIdleImpl`. No-op when there's no
    ///         position or no AERO. Fee crystallisation + the external skim transfer live in the
    ///         strategy entrypoint, NOT here — this only sets aside `pay` so it isn't redeployed.
    /// @param minUsdcOut   Minimum USDC out of the AERO→USDC swap (slippage guard, on GROSS usdcOut).
    /// @param minLiquidity Minimum CL liquidity on the redeploy (slippage guard).
    /// @param skimCap      Max USDC to withhold from redeploy for the protocol fee (owed, or 0).
    /// @return pay         USDC withheld = `min(skimCap, usdcOut)` (0 when no yield). The strategy
    ///                     transfers this to the protocol-fee recipient and decrements owed.
    function compoundImpl(uint256 minUsdcOut, uint256 minLiquidity, uint256 skimCap) public returns (uint256 pay) {
        Layout storage $ = _layout();
        uint256 tokenId_ = $.tokenId;
        if (tokenId_ == 0) return 0; // flat book — nothing staked, nothing to compound
        if (minUsdcOut == 0) revert ZeroMinOut(); // belt: caller must pass a nonzero floor (see BelowOracleFloor)

        // 1. Claim AERO for the staked NFT. The reward token is read from the gauge
        //    (definitionally AERO on this pool — fork-confirmed `rewardToken() == AERO`).
        address gauge_ = $.gauge;
        address aero = ICLGauge(gauge_).rewardToken();
        ICLGauge(gauge_).getReward(tokenId_);
        uint256 aeroBal = IERC20(aero).balanceOf(address(this));
        if (aeroBal == 0) return 0; // no rewards accrued — clean no-op

        // 2. Derive the on-chain oracle floor from a hardened AERO/USD read (8dp, fail-closed): a
        //    stale/broken feed reverts the whole compound (defer the harvest, intended posture).
        //    fair6 = aeroBal(18dp) × price(8dp) / 1e20 → USDC 6dp; floor haircuts by maxSlippageBps.
        uint256 floor =
            Math.mulDiv(aeroBal, _readUsd8($.aeroUsdFeed), 1e20) * (10000 - uint256($.maxSlippageBps)) / 10000;

        // 3. Swap ALL claimed AERO → USDC via the Aerodrome v2 volatile pool, passing the caller's
        //    minUsdcOut to the router. The measured-fill floor below is the robust guard (router-honesty
        //    independent); the effective bound is max(minUsdcOut, floor), enforced independently.
        uint256 usdcBefore = IERC20($.usdc).balanceOf(address(this));
        IERC20(aero).forceApprove(AERO_V2_ROUTER, aeroBal);
        IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
        routes[0] = IAeroRouter.Route({from: aero, to: $.usdc, stable: false, factory: AERO_V2_FACTORY});
        IAeroRouter(AERO_V2_ROUTER).swapExactTokensForTokens(
            aeroBal, minUsdcOut, routes, address(this), block.timestamp + 600
        );
        uint256 usdcOut = IERC20($.usdc).balanceOf(address(this)) - usdcBefore;
        if (usdcOut < floor) revert BelowOracleFloor(); // post-check on the measured fill (L9)
        if (usdcOut == 0) return 0; // unreachable when floor > 0 (aeroBal > 0), kept as defence

        // 4. Withhold up to `skimCap` of the realized yield for the protocol fee (the strategy pays
        //    it out); redeploy only the remainder.
        pay = skimCap < usdcOut ? skimCap : usdcOut;
        uint256 redeploy = usdcOut - pay;

        // 5. Redeploy the net yield into the position at target leverage (supply → borrow →
        //    increaseLiquidity → restake → _assertHealthy). Any pre-existing idle USDC is left
        //    untouched — compound deploys the AERO yield, nothing else. Skip if all was skimmed.
        if (redeploy > 0) deployIdleImpl(redeploy, minLiquidity);
    }

    /// @notice Recenter the CL position on the current tick WITHOUT swapping (body of the strategy's
    ///         `rerange`): calm-gate → remove 100% liquidity + collect → new tickSpacing-aligned range
    ///         → re-add the collected legs → restake → assert health. Debt + collateral untouched.
    ///
    ///         No swap → principal conserved; the collected ratio can't match the new range, so a
    ///         remainder of ONE borrowed leg is left idle (NAV-counted, stays redeployable). A new
    ///         tokenId is minted (Slipstream ticks are immutable); the old empty NFT is harmless dust.
    ///         No-op on a flat book.
    /// @param width_  Full range width in ticks for this cycle (validated against the stored band by
    ///                the strategy entrypoint, then persisted here as the new `width`).
    /// @param minLiq0 Minimum token0 the re-add must consume (two-sided slippage guard).
    /// @param minLiq1 Minimum token1 the re-add must consume (two-sided slippage guard).
    function rerangeImpl(uint24 width_, uint256 minLiq0, uint256 minLiq1) public {
        Layout storage $ = _layout();
        // Persist the (already band-validated) width BEFORE the flat-book bail-out. `deployIdle` /
        // `compound` mint at the STORED width, so a rerange on a flat book must still take effect —
        // otherwise the proposer's width choice is silently dropped and the next redeploy reopens at
        // the stale one.
        $.width = width_;
        if ($.tokenId == 0) return; // flat book — nothing to recenter (width above already stored)

        // 1. Calm-gate BEFORE touching the pool — never recenter at a manipulated tick.
        LeveragedAeroValuation._calmGate(_config());

        // 2. Unstake + remove 100% liquidity + collect (num==den → no restake). The old NFT is
        //    left empty + unstaked; a recenter needs a fresh range == fresh tokenId.
        _unwindLiquidity(1, 1);

        // 3. Derive the tickSpacing-aligned range centered on the current (calm) tick from the width
        //    stored above. Every later mint (deployIdle / compound) reuses that stored width.
        (int24 tickLower, int24 tickUpper) = _computeTickRange();

        // 4. Re-add the collected legs (full balances as desired) into the new range. No swap →
        //    principal conserved. `_mintPosition` enforces the two-sided `maxSlippageBps` mins
        //    (the §8 always-on floor) and approves the NPM; the caller's `minLiq0/minLiq1` add an
        //    explicit two-sided guard on the consumed amounts (proposer-tightenable, like
        //    compound's `minUsdcOut`).
        (uint256 amt0, uint256 amt1) =
            _amounts01(IERC20($.cbBTC).balanceOf(address(this)), IERC20($.weth).balanceOf(address(this)));
        (uint256 newTokenId, uint256 used0, uint256 used1) = _mintPosition(amt0, amt1, tickLower, tickUpper);
        if (used0 < minLiq0 || used1 < minLiq1) revert InsufficientLiquidity();

        // 5. Restake the new NFT to resume AERO gauge rewards (mirrors _mintAndStake).
        _approveAndStake($.gauge, newTokenId);

        // 6. Persist the recentered position (nav()/positions() now read the new NFT).
        $.tokenId = newTokenId;
        $.posTickLower = tickLower;
        $.posTickUpper = tickUpper;

        // 7. Debt + collateral untouched by rerange → health preserved; assert as a belt.
        _assertHealthy();
    }

    /// @notice Retarget the position's LTV to `targetLtvBps_` (body of the strategy's `adjustLeverage`;
    ///         the entrypoint already enforced `targetLtvBps_ ≤ maxLtvBps`). Collateral is untouched,
    ///         so LTV moves on the debt side: lever UP borrows the cbBTC/WETH delta and adds it
    ///         (`minLiq`); lever DOWN unwinds the matching CL fraction and repays (per-leg residual
    ///         rebalanced through USDC, bounded by `minOut`). Ends with `_assertHealthy`.
    /// @param targetLtvBps_ Target LTV in bps (≤ `maxLtvBps`).
    /// @param minLiq        Minimum CL liquidity on a lever-UP add (slippage guard).
    /// @param minOut        Minimum USDC out of a lever-DOWN residual swap (slippage guard).
    function adjustLeverageImpl(uint16 targetLtvBps_, uint256 minLiq, uint256 minOut) public {
        (uint256 collateralUsdc, uint256 debtUsdc) = _readCollateralDebt();
        uint256 targetDebt = (uint256(targetLtvBps_) * collateralUsdc) / 10000;
        if (targetDebt > debtUsdc) {
            _leverUp(targetDebt - debtUsdc, minLiq);
        } else if (debtUsdc > targetDebt) {
            _leverDown(debtUsdc - targetDebt, debtUsdc, minOut);
        }
        _assertHealthy();
    }

    /// @notice Permissionless safety valve (body of the strategy's `deleverage`): when health falls
    ///         below `minHealthBps`, anyone may unwind CL liquidity and repay debt to restore the
    ///         buffer. Health basis mirrors `_assertHealthy` (`collateralUsdc × 1e4 / debtUsdc`, same
    ///         hardened Chainlink reads); at/above `minHealthBps` or zero debt → `HealthyNoDeleverage`.
    ///         Repays down to `minHealthBps × (1 + DELEVERAGE_BUFFER_BPS/1e4)` (a recovery op, not the
    ///         full LTV-≤-max gate): asserts health strictly improved + the shortfall cleared/reduced.
    ///
    ///         Oracle-staleness (accepted residual, §13): a stale our-feed reverts (fail-safe —
    ///         deleveraging at a stale/manipulated price is worse than waiting); Moonwell liquidation
    ///         uses Moonwell's OWN oracle, so a window where our feed is stale but theirs is fresh is
    ///         an accepted residual.
    /// @param minOut Minimum USDC out of any residual rebalancing swap (slippage guard).
    function deleverageImpl(uint256 minOut) public {
        Layout storage $ = _layout();
        (uint256 collateralBefore, uint256 debtBefore) = _readCollateralDebt();
        if (debtBefore == 0) revert HealthyNoDeleverage(); // no debt ⇒ infinitely healthy
        uint256 healthBefore = (collateralBefore * 10000) / debtBefore;
        uint256 minHealth = uint256($.minHealthBps);
        if (healthBefore >= minHealth) revert HealthyNoDeleverage();
        (,, uint256 shortfallBefore) = IComptroller($.comptroller).getAccountLiquidity(address(this));

        // Target debt that lands health at minHealthBps + the re-trigger buffer (collateral is
        // untouched, so health = c / d ⇒ targetDebt = c × 1e4 / targetHealth).
        uint256 targetHealth = (minHealth * (10000 + uint256(DELEVERAGE_BUFFER_BPS))) / 10000;
        uint256 targetDebt = (collateralBefore * 10000) / targetHealth;
        if (debtBefore > targetDebt) _leverDown(debtBefore - targetDebt, debtBefore, minOut);

        // Recovery gate: health strictly improved AND the Moonwell shortfall cleared or reduced.
        (uint256 collateralAfter, uint256 debtAfter) = _readCollateralDebt();
        uint256 healthAfter = debtAfter == 0 ? type(uint256).max : (collateralAfter * 10000) / debtAfter;
        if (healthAfter <= healthBefore) revert UnhealthyPosition(healthAfter, minHealth);
        (uint256 err,, uint256 shortfallAfter) = IComptroller($.comptroller).getAccountLiquidity(address(this));
        if (err != 0 || (shortfallAfter != 0 && shortfallAfter >= shortfallBefore)) {
            revert UnhealthyPosition(healthAfter, minHealth);
        }
    }

    // ── Leverage helpers (adjustLeverage / deleverage) ──

    /// @dev Lever UP by `borrowDeltaUsd` (USDC face, 6dp): borrow the cbBTC/WETH delta (50/50) and
    ///      add it to the existing position. No new collateral — mirrors `deployIdleImpl`'s
    ///      borrow→wrap→add→restake without the supply step.
    function _leverUp(uint256 borrowDeltaUsd, uint256 minLiq) private {
        (uint256 cbBTCAmt, uint256 wethAmt) = _borrowHalfEach(borrowDeltaUsd);
        _wrapAddRestake(cbBTCAmt, wethAmt, minLiq);
    }

    /// @dev Lever DOWN by `repayUsd` (USDC face, 6dp) of the current `debtUsd`: unwind the matching
    ///      fraction `f = repayUsd/debtUsd` of CL liquidity, repay `f` of each debt from the
    ///      collected legs (oracle-free direct repay), then cover any per-leg IL residual by selling
    ///      the over-collected sibling leg → USDC (caller `minOut` bounds it) and buying the deficit.
    ///      Balanced legs (the common case) leave no residual → no swap → `minOut` unused.
    function _leverDown(uint256 repayUsd, uint256 debtUsd, uint256 minOut) private {
        Layout storage $ = _layout();
        _unwindLiquidity(repayUsd, debtUsd);
        (uint256 cbShort, uint256 wethShort) = _redeemRepayFromCollected(repayUsd, debtUsd, 0, 0);
        // Two independent `if`s (NOT else-if): a dual-leg IL shortfall covers BOTH legs (L6), mirroring
        // the redeem path. An `else if` would silently skip the WETH leg when both are short.
        if (cbShort > 0) {
            _rebalanceCover($.weth, $.cbBTC, $.mCbBTC, cbShort, minOut);
        }
        if (wethShort > 0) {
            _rebalanceCover($.cbBTC, $.weth, $.mWeth, wethShort, minOut);
        }
    }

    /// @dev Cover an IL-driven debt shortfall on `deficitTok` by selling the over-collected
    ///      `surplusTok` → USDC, then buying exactly the deficit from that USDC and repaying it.
    ///      Any leftover USDC stays idle (NAV-counted; recoverable via `deployIdle`/`redeem`).
    ///
    ///      **Oracle-floor guard** — the minimum USDC out of the surplus-leg sell is enforced as
    ///      `max(callerMinUsdcOut, oracleFloor)` where
    ///      `oracleFloor = _tokenToUsdc(surplusBal) × (1 − maxSlippageBps)`.
    ///      This prevents a griefer from passing `minOut=0` to the permissionless `deleverage()`
    ///      and sandwiching the IL-residual swap.  If a Chainlink feed is stale the read reverts —
    ///      fail-safe and consistent with `_assertHealthy`.
    ///
    ///      **Redeem path unaffected** — redeem calls `_sweepLegToUsdc` directly with a
    ///      stayers' `keep > 0`; it never routes through `_rebalanceCover`.
    function _rebalanceCover(
        address surplusTok,
        address deficitTok,
        address deficitMkt,
        uint256 shortAmt,
        uint256 minUsdcOut
    ) private {
        Layout storage $ = _layout();
        uint256 pUsdc = _readUsd8($.usdcFeed); // hoisted: floors the surplus sell AND ceils the deficit buy
        uint256 surplusBal = IERC20(surplusTok).balanceOf(address(this));
        if (surplusBal > 0) {
            bool isCbBTC = surplusTok == $.cbBTC;
            uint8 dec = isCbBTC ? $.cbBTCDecimals : $.wethDecimals;
            uint256 pSurplus = _readUsd8(isCbBTC ? $.cbBTCFeed : $.wethFeed);
            uint256 oracleFloor =
                _tokenToUsdc(surplusBal, dec, pSurplus, pUsdc) * (10000 - uint256($.maxSlippageBps)) / 10000;
            if (oracleFloor > minUsdcOut) minUsdcOut = oracleFloor;
        }
        _sweepLegToUsdc(surplusTok, 0, minUsdcOut);
        // Oracle-ceiling the deficit BUY (H1): a sandwiched/manipulated permissionless `deleverage`
        // can't overpay past the oracle+slippage bound. The redeem path passes max (oracle-free).
        bool deficitIsCb = deficitTok == $.cbBTC;
        uint256 pDeficit = _readUsd8(deficitIsCb ? $.cbBTCFeed : $.wethFeed);
        uint256 buyMax = _tokenToUsdc(shortAmt, deficitIsCb ? $.cbBTCDecimals : $.wethDecimals, pDeficit, pUsdc)
            * (10000 + uint256($.maxSlippageBps)) / 10000;
        _redeemCoverShortfall(deficitTok, deficitMkt, shortAmt, buyMax);
    }

    /// @dev Collateral + debt in USDC face (6dp) on the SAME hardened-Chainlink basis as
    ///      `_assertHealthy` (the LTV/health basis) — sizes the adjustLeverage / deleverage targets.
    ///      Returns `debtUsdc == 0` (skipping the price reads) when both borrows are clear.
    function _readCollateralDebt() private view returns (uint256 collateralUsdc, uint256 debtUsdc) {
        Layout storage $ = _layout();
        uint256 cBal = ICToken($.mUsdc).balanceOf(address(this));
        uint256 rate = ICToken($.mUsdc).exchangeRateStored();
        collateralUsdc = (cBal * rate) / 1e18;
        uint256 cbDebt = IMoonwellMarket($.mCbBTC).borrowBalanceStored(address(this));
        uint256 wethDebt = IMoonwellMarket($.mWeth).borrowBalanceStored(address(this));
        if (cbDebt == 0 && wethDebt == 0) return (collateralUsdc, 0);
        (uint256 pBTC, uint256 pETH, uint256 pUsdc) = _readAllPrices();
        debtUsdc =
            _tokenToUsdc(cbDebt, $.cbBTCDecimals, pBTC, pUsdc) + _tokenToUsdc(wethDebt, $.wethDecimals, pETH, pUsdc);
    }

    // ── Moonwell call+check helpers (bytecode offset: 7 repay sites, 3 redeem sites) ──

    /// @dev `market.repayBorrow(amt)` with the uniform error-check. Approve the underlying first.
    function _repay(address market, uint256 amt) private {
        uint256 err = IMoonwellMarket(market).repayBorrow(amt);
        if (err != 0) revert MoonwellRepayFailed(err);
    }

    /// @dev `mUsdc.redeemUnderlying(amt)` with the uniform error-check.
    function _redeemUnderlying(address cToken, uint256 amt) private {
        uint256 err = ICToken(cToken).redeemUnderlying(amt);
        if (err != 0) revert MoonwellRedeemFailed(err);
    }

    // ── Execute helpers ──

    /// @dev Supply all strategy USDC to Moonwell and enter the mUSDC market.
    function _supplyCollateral() private returns (uint256 usdcAmt) {
        Layout storage $ = _layout();
        address usdc_ = $.usdc;
        address mUsdc_ = $.mUsdc;
        usdcAmt = IERC20(usdc_).balanceOf(address(this));
        if (usdcAmt == 0) revert ExecuteZeroBalance();
        IERC20(usdc_).forceApprove(mUsdc_, usdcAmt);
        uint256 err = ICToken(mUsdc_).mint(usdcAmt);
        if (err != 0) revert MoonwellMintFailed(err);
        address[] memory markets = new address[](1);
        markets[0] = mUsdc_;
        IComptroller($.comptroller).enterMarkets(markets);
    }

    /// @dev Borrow against `usdcAmt` of fresh collateral at `targetLtvBps` (execute / deployIdle).
    ///      The borrow USD = `usdcAmt × targetLtvBps / 1e4`, split 50/50 across cbBTC/WETH.
    function _computeAndBorrow(uint256 usdcAmt) private returns (uint256 cbBTCAmt, uint256 wethAmt) {
        return _borrowHalfEach((usdcAmt * uint256(_layout().targetLtvBps)) / 10000);
    }

    /// @dev Borrow `borrowUsd6` of debt (USDC face, 6dp) split 50/50 by USD across cbBTC + WETH, at
    ///      hardened-Chainlink prices, and execute both borrows. Used by `_computeAndBorrow` (fresh
    ///      collateral at target) and by `_leverUp` (a target-LTV debt delta with no new collateral).
    function _borrowHalfEach(uint256 borrowUsd6) private returns (uint256 cbBTCAmt, uint256 wethAmt) {
        Layout storage $ = _layout();
        uint256 pBTC = _readUsd8($.cbBTCFeed);
        uint256 pETH = _readUsd8($.wethFeed);
        // halfBorrowUsd8: borrowUsd6 (6dp) → 8dp via ×100, then halve for the per-leg USD value.
        // The `10 ** legDecimals` factors rescale that USD amount into each leg's own units.
        uint256 halfBorrowUsd8 = (borrowUsd6 * 100) / 2;
        cbBTCAmt = (halfBorrowUsd8 * (10 ** uint256($.cbBTCDecimals))) / pBTC;
        wethAmt = (halfBorrowUsd8 * (10 ** uint256($.wethDecimals))) / pETH;
        uint256 cbErr = IMoonwellMarket($.mCbBTC).borrow(cbBTCAmt);
        if (cbErr != 0) revert MoonwellBorrowFailed(cbErr);
        uint256 wethErr = IMoonwellMarket($.mWeth).borrow(wethAmt);
        if (wethErr != 0) revert MoonwellBorrowFailed(wethErr);
    }

    /// @dev Wrap all native ETH held by the strategy into the leg-A wrapper token. No-op unless the
    ///      leg-A Moonwell market delivers native on `borrow()` (`wethDeliversNative`, set at init) —
    ///      a plain ERC-20 leg has nothing to wrap and its token has no `deposit()`.
    ///
    ///      The wrap is BEST-EFFORT on purpose. `wethDeliversNative` is an init input, and the leg-A
    ///      token is not required to be a WETH9 (no `deposit()` payable fallback): a flag set on a
    ///      plain ERC-20 leg turns every forced-ETH arrival — `selfdestruct`, a coinbase payout, or
    ///      any other push a `receive()` cannot refuse — into a permanent revert on this line, which
    ///      would brick `executeImpl` / `deployIdleImpl` / `compoundImpl` / `_leverUp` on a LIVE
    ///      levered book for 1 wei. Swallowing the failure leaves the ETH idle, exactly as the
    ///      flag-false path does, and the venue op proceeds. Stray ETH under a false flag (or a
    ///      failed wrap) is NOT recoverable — `rescueToVault` is ERC-20 only and there is no native
    ///      sweep — an accepted, bounded loss versus a bricked position.
    function _wrapNativeEth() private {
        Layout storage $ = _layout();
        if (!$.wethDeliversNative) return;
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            try IWETH9($.weth).deposit{value: ethBal}() {} catch {}
        }
    }

    /// @dev Compute a tickSpacing-aligned range centred on the current pool tick, spanning
    ///      `width/2` ticks each side (the stored per-cycle width, validated by the entrypoint).
    ///
    ///      "Centred" is grid-approximate, not exact. Both bounds round DOWN onto the grid, so the
    ///      realised centre can sit up to one `tickSpacing` below the calm tick and the realised
    ///      width can differ from `width` by up to one spacing; when `width / tickSpacing` is ODD the
    ///      half-span is itself off-grid, which is where the skew is largest. Accepted: the band is
    ///      orders of magnitude wider than one spacing, and re-centring exactly would need an
    ///      align-up on one side, silently widening the range past the validated band.
    ///
    ///      Both bounds are clamped into the aligned tick domain: `width` is capped at `2 × MAX_TICK`
    ///      at init so the arithmetic cannot wrap int24, but a wide band near either end of the
    ///      domain still pushes a bound past ±MAX_TICK, where `getSqrtRatioAtTick` would revert
    ///      unhelpfully deep inside TickMath. `maxAligned` sits ON the spacing grid by construction,
    ///      so clamping keeps the range mintable rather than merely non-panicking.
    function _computeTickRange() private view returns (int24 tickLower, int24 tickUpper) {
        Layout storage $ = _layout();
        (, int24 currentTick,,,,) = ICLPool($.pool).slot0();
        int24 tickSpacing_ = $.tickSpacing;
        int24 span = int24($.width / 2);
        tickLower = _alignTick(currentTick - span, tickSpacing_);
        tickUpper = _alignTick(currentTick + span, tickSpacing_);
        int24 maxAligned = _alignTick(TickMath.MAX_TICK, tickSpacing_);
        if (tickLower < -maxAligned) tickLower = -maxAligned;
        if (tickUpper > maxAligned) tickUpper = maxAligned;
        if (tickUpper <= tickLower) tickUpper = tickLower + tickSpacing_;
    }

    /// @dev The pool's (token0, token1) resolved from the leg ordering derived at init.
    function _tokens01() private view returns (address t0, address t1) {
        Layout storage $ = _layout();
        return $.wethIsToken0 ? ($.weth, $.cbBTC) : ($.cbBTC, $.weth);
    }

    /// @dev Map a (leg B, leg A) amount pair onto the pool's (amount0, amount1) ordering.
    function _amounts01(uint256 cbBTCAmt, uint256 wethAmt) private view returns (uint256 amt0, uint256 amt1) {
        return _layout().wethIsToken0 ? (wethAmt, cbBTCAmt) : (cbBTCAmt, wethAmt);
    }

    /// @dev Mint the Slipstream CL position and return its tokenId + the amounts actually
    ///      consumed. `amt0`/`amt1` are POSITIONAL (pool token0/token1) — callers map their leg
    ///      amounts through `_amounts01`. Two-sided slippage mins are derived from the
    ///      expected-actual deposit amounts at the calm-gated sqrtP (the §8 always-on floor);
    ///      `rerange` layers an additional caller-supplied two-sided guard on `used0`/`used1`.
    function _mintPosition(uint256 amt0, uint256 amt1, int24 tickLower, int24 tickUpper)
        private
        returns (uint256 tokenId_, uint256 used0, uint256 used1)
    {
        Layout storage $ = _layout();
        address npm_ = $.npm;
        (address tok0, address tok1) = _tokens01();

        // Compute expected actual deposits at the calm-gated sqrtP.
        (uint160 sqrtP,,,,,) = ICLPool($.pool).slot0();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 L = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, amt0, amt1);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, L);
        uint256 slip = uint256($.maxSlippageBps);
        uint256 amt0Min = exp0 * (10000 - slip) / 10000;
        uint256 amt1Min = exp1 * (10000 - slip) / 10000;

        IERC20(tok0).forceApprove(npm_, amt0);
        IERC20(tok1).forceApprove(npm_, amt1);
        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: tok0,
            token1: tok1,
            tickSpacing: $.tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amt0,
            amount1Desired: amt1,
            amount0Min: amt0Min,
            amount1Min: amt1Min,
            recipient: address(this),
            deadline: block.timestamp + 600,
            sqrtPriceX96: 0
        });
        (tokenId_,, used0, used1) = INonfungiblePositionManager(npm_).mint(mp);
        if (tokenId_ == 0) revert NpmMintFailed();
    }

    /// @dev Mint the CL position, stake in gauge, and persist state.
    function _mintAndStake(uint256 cbBTCAmt, uint256 wethAmt) private {
        // Calm-gate before reading spot tick / anchoring slippage mins.
        Layout storage $ = _layout();
        LeveragedAeroValuation._calmGate(_config());
        (int24 tickLower, int24 tickUpper) = _computeTickRange();
        (uint256 amt0, uint256 amt1) = _amounts01(cbBTCAmt, wethAmt);
        (uint256 tokenId_,,) = _mintPosition(amt0, amt1, tickLower, tickUpper);
        _approveAndStake($.gauge, tokenId_);
        // Persist position state (so nav()/positions() see the live position)
        $.tokenId = tokenId_;
        $.posTickLower = tickLower;
        $.posTickUpper = tickUpper;
    }

    /// @dev ERC-721 approve `tokenId_` to `gauge_` (low-level `approve(address,uint256)`), then stake
    ///      it in the gauge. Shared by every mint/restake site (`_mintAndStake`, `rerangeImpl`,
    ///      `_unwindLiquidity`, `_wrapAddRestake`).
    function _approveAndStake(address gauge_, uint256 tokenId_) private {
        (bool ok,) = _layout().npm.call(abi.encodeWithSignature("approve(address,uint256)", gauge_, tokenId_));
        if (!ok) revert NpmApproveFailed();
        ICLGauge(gauge_).deposit(tokenId_);
    }

    /// @dev Align `tick` down to the nearest multiple of `spacing` (handles negatives).
    function _alignTick(int24 tick, int24 spacing) private pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }

    // ── Settle helpers ──

    /// @dev Unstake NFT, remove num/den fraction of liquidity, collect both tokens.
    ///      When num==den (full settle), no restake. When num<den (partial redeem),
    ///      restakes if remaining liq > 0.
    function _unwindLiquidity(uint256 num, uint256 den) private {
        Layout storage $ = _layout();
        uint256 tokenId_ = $.tokenId;
        if (tokenId_ == 0) return; // flat book — no LP to unwind

        (int24 tickLower, int24 tickUpper, uint128 liq) = _npmPositionData();

        // Unstake so NPM can modify the position
        address gauge_ = $.gauge;
        address npm_ = $.npm;
        ICLGauge(gauge_).withdraw(tokenId_);

        uint128 liqToRemove = (num == den) ? liq : uint128(Math.mulDiv(uint256(liq), num, den));

        if (liqToRemove > 0) {
            (uint160 sqrtP,,,,,) = ICLPool($.pool).slot0();
            uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
            (uint256 exp0, uint256 exp1) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, liqToRemove);
            uint256 slip = uint256($.maxSlippageBps);
            INonfungiblePositionManager(npm_).decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId_,
                    liquidity: liqToRemove,
                    amount0Min: exp0 * (10000 - slip) / 10000,
                    amount1Min: exp1 * (10000 - slip) / 10000,
                    deadline: block.timestamp + 600
                })
            );
            INonfungiblePositionManager(npm_).collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId_,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        }

        // Re-stake only when remaining liquidity is non-zero.
        (,, uint128 remainingLiq) = _npmPositionData();
        if (remainingLiq > 0) _approveAndStake(gauge_, tokenId_);
    }

    /// @dev Repay as much of both Moonwell borrows as current balances allow, then cover
    ///      any remaining debt via _settleShortfall().
    function _settleRepayDebts() private {
        Layout storage $ = _layout();
        address mCbBTC_ = $.mCbBTC;
        address mWeth_ = $.mWeth;
        address cbBTC_ = $.cbBTC;
        address weth_ = $.weth;
        uint256 cbDebt = IMoonwellMarket(mCbBTC_).borrowBalanceStored(address(this));
        uint256 wethDebt = IMoonwellMarket(mWeth_).borrowBalanceStored(address(this));
        // Repay cbBTC
        uint256 cbBal = IERC20(cbBTC_).balanceOf(address(this));
        if (cbBal > 0 && cbDebt > 0) {
            IERC20(cbBTC_).forceApprove(mCbBTC_, cbBal);
            _repay(mCbBTC_, cbBal >= cbDebt ? type(uint256).max : cbBal);
        }
        // Repay WETH (ERC-20 — no unwrap; mWETH accepts WETH ERC-20 for repay)
        uint256 wethBal = IERC20(weth_).balanceOf(address(this));
        if (wethBal > 0 && wethDebt > 0) {
            IERC20(weth_).forceApprove(mWeth_, wethBal);
            _repay(mWeth_, wethBal >= wethDebt ? type(uint256).max : wethBal);
        }
        // Handle any remaining shortfall (IL or fees ate into LP value)
        _settleShortfall();
    }

    /// @dev If any borrow balance remains after the direct repay attempt, redeem USDC from
    ///      mUSDC collateral and swap to cover it. Chainlink prices + 10% buffer; dust floor.
    function _settleShortfall() private {
        Layout storage $ = _layout();
        uint256 cbDebtRem = IMoonwellMarket($.mCbBTC).borrowBalanceStored(address(this));
        uint256 wethDebtRem = IMoonwellMarket($.mWeth).borrowBalanceStored(address(this));
        if (cbDebtRem == 0 && wethDebtRem == 0) return;
        // Read Chainlink prices (8dp each)
        (uint256 pBTC, uint256 pETH, uint256 pUsdc) = _readAllPrices();
        // USDC needed for each shortfall leg (+10% buffer)
        uint256 cbUsdcNeed = _tokenToUsdc(cbDebtRem, $.cbBTCDecimals, pBTC, pUsdc) * 11000 / 10000;
        uint256 wethUsdcNeed = _tokenToUsdc(wethDebtRem, $.wethDecimals, pETH, pUsdc) * 11000 / 10000;
        // Dust floor: nonzero debt but oracle cost rounds to 0 (e.g. 1 wei WETH) → redeem enough
        // to acquire at least 1 unit of that token.
        if (cbDebtRem > 0 && cbUsdcNeed == 0) cbUsdcNeed = 1e5;
        if (wethDebtRem > 0 && wethUsdcNeed == 0) wethUsdcNeed = 1e5;
        uint256 totalNeed = cbUsdcNeed + wethUsdcNeed;
        // Redeem USDC collateral to fund the swaps (health elevated after partial repays)
        if (totalNeed > 0) _redeemUnderlying($.mUsdc, totalNeed);
        uint256 slip = uint256($.maxSlippageBps);
        // Cover cbBTC shortfall
        if (cbDebtRem > 0) {
            _swapUsdcExactIn($.cbBTC, cbUsdcNeed, cbDebtRem * (10000 - slip) / 10000);
            uint256 cbBal2 = IERC20($.cbBTC).balanceOf(address(this));
            if (cbBal2 > 0) {
                IERC20($.cbBTC).forceApprove($.mCbBTC, cbBal2);
                _repay($.mCbBTC, type(uint256).max);
            }
        }
        // Cover WETH shortfall (bounded by its own oracle budget, not the full idle balance — M1;
        // `_swapUsdcExactIn` still caps at the live USDC balance).
        if (wethDebtRem > 0) {
            _swapUsdcExactIn($.weth, wethUsdcNeed, wethDebtRem * (10000 - slip) / 10000);
            uint256 wBal2 = IERC20($.weth).balanceOf(address(this));
            if (wBal2 > 0) {
                IERC20($.weth).forceApprove($.mWeth, wBal2);
                _repay($.mWeth, type(uint256).max);
            }
        }
    }

    /// @dev tickSpacing of the `leg`↔USDC SWAP pool — a different venue from the LP pool, so it
    ///      carries its own spacing (both are init inputs, neither is derivable from the other).
    ///      Only the two legs have a configured swap pool; anything else reverts rather than silently
    ///      borrowing leg A's spacing and routing at an unrelated (or nonexistent) venue.
    function _legSwapSpacing(address leg) private view returns (int24) {
        Layout storage $ = _layout();
        if (leg == $.cbBTC) return $.cbBTCSwapTickSpacing;
        if (leg == $.weth) return $.wethSwapTickSpacing;
        revert UnsupportedLeg();
    }

    /// @dev Swap a fixed USDC amount in for `tokenOut` via Slipstream exactInputSingle.
    ///      Caps actualIn at the current USDC balance.
    function _swapUsdcExactIn(address tokenOut, uint256 amountIn, uint256 minAmtOut) private {
        Layout storage $ = _layout();
        uint256 usdcBal = IERC20($.usdc).balanceOf(address(this));
        uint256 actualIn = usdcBal < amountIn ? usdcBal : amountIn;
        if (actualIn == 0) return;
        IERC20($.usdc).forceApprove($.swapRouter, actualIn);
        ICLSwapRouter($.swapRouter).exactInputSingle(
            ICLSwapRouter.ExactInputSingleParams({
                tokenIn: $.usdc,
                tokenOut: tokenOut,
                tickSpacing: _legSwapSpacing(tokenOut),
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: actualIn,
                amountOutMinimum: minAmtOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Sweep the full balance of `tokenIn` to USDC via exactInputSingle (minOut may be 0).
    function _swapTokenToUsdc(address tokenIn, uint256 minOut) private {
        _sweepLegToUsdc(tokenIn, 0, minOut);
    }

    /// @dev Sweep (balance − `keep`) of `tokenIn` → USDC via exactInputSingle. `keep` reserves a
    ///      stayers' idle-leg share on the redeem path; settle / full-sweep callers pass keep == 0.
    function _sweepLegToUsdc(address tokenIn, uint256 keep, uint256 minOut) private {
        Layout storage $ = _layout();
        uint256 bal = IERC20(tokenIn).balanceOf(address(this));
        if (bal <= keep) return;
        uint256 amt = bal - keep;
        IERC20(tokenIn).forceApprove($.swapRouter, amt);
        ICLSwapRouter($.swapRouter).exactInputSingle(
            ICLSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: $.usdc,
                tickSpacing: _legSwapSpacing(tokenIn),
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: amt,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev (1-f) of the strategy's current `token` balance, f = shares/supply. Used by redeem to
    ///      reserve the stayers' share of a pre-existing idle leg (a rerange remainder) before the
    ///      residual sweep — keeping the partial-redeem path oracle-free and stayer-fair.
    function _stayerLeg(address token, uint256 shares, uint256 supply) private view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal - Math.mulDiv(bal, shares, supply);
    }

    /// @dev Convert `amt` (in `dec`-decimal token units) to USDC (6dp) using Chainlink prices.
    ///      pToken and pUsdc are both 8dp.
    function _tokenToUsdc(uint256 amt, uint8 dec, uint256 pToken, uint256 pUsdc) private pure returns (uint256) {
        return (amt * pToken * 1e6) / ((10 ** uint256(dec)) * pUsdc);
    }

    /// @dev Hardened USD read that also asserts the feed is 8-decimal (the scaling assumption),
    ///      mirroring `LeveragedAeroValuation._readUsd8`. The execution-path price reads previously
    ///      trusted `decimals()` implicitly; consolidating them here closes that gap (L1) — a
    ///      redeployed feed at a different precision fail-closes instead of mis-scaling the term.
    function _readUsd8(address feed) private view returns (uint256 price) {
        Layout storage $ = _layout();
        (uint256 p, uint8 dec) = ChainlinkReader.readUsd(feed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        if (dec != 8) revert FeedDecimalsMismatch();
        return p;
    }

    /// @dev The 3-price bundle (cbBTC / WETH / USDC, all 8dp) read on the debt/health/sweep basis.
    ///      Hoisted so the four debt-sizing sites (settle sweep, _readCollateralDebt, _settleShortfall,
    ///      _assertHealthy) share one call instead of inlining three `_readUsd8`s each (bytecode offset
    ///      for the L9 floor).
    function _readAllPrices() private view returns (uint256 pBTC, uint256 pETH, uint256 pUsdc) {
        Layout storage $ = _layout();
        pBTC = _readUsd8($.cbBTCFeed);
        pETH = _readUsd8($.wethFeed);
        pUsdc = _readUsd8($.usdcFeed);
    }

    // ── deployIdle helpers ──

    /// @dev Supply a specific USDC amount to Moonwell mUSDC (no enterMarkets — already entered).
    function _supplyAmount(uint256 amt) private {
        Layout storage $ = _layout();
        IERC20($.usdc).forceApprove($.mUsdc, amt);
        uint256 err = ICToken($.mUsdc).mint(amt);
        if (err != 0) revert MoonwellMintFailed(err);
    }

    /// @dev Add liquidity to the existing tokenId position via NPM.increaseLiquidity.
    ///      Caller must own the NFT (position unstaked from the gauge). `amt0`/`amt1` are
    ///      POSITIONAL (pool token0/token1) — callers map their leg amounts through `_amounts01`.
    function _addLiquidity(uint256 amt0, uint256 amt1, uint256 minLiquidity) private {
        Layout storage $ = _layout();
        LeveragedAeroValuation._calmGate(_config());
        uint256 tokenId_ = $.tokenId;
        address npm_ = $.npm;
        (uint160 sqrtP,,,,,) = ICLPool($.pool).slot0();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick($.posTickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick($.posTickUpper);
        uint128 L = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, amt0, amt1);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, L);
        uint256 slip = uint256($.maxSlippageBps);
        (address tok0, address tok1) = _tokens01();
        IERC20(tok0).forceApprove(npm_, amt0);
        IERC20(tok1).forceApprove(npm_, amt1);
        (uint128 liq,,) = INonfungiblePositionManager(npm_).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId_,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: exp0 * (10000 - slip) / 10000,
                amount1Min: exp1 * (10000 - slip) / 10000,
                deadline: block.timestamp + 600
            })
        );
        if (uint256(liq) < minLiquidity) revert InsufficientLiquidity();
    }

    /// @dev Wrap native ETH from a borrow → WETH, unstake the NFT so the NPM can modify it,
    ///      `increaseLiquidity` the borrowed legs into the existing position (`minLiquidity`
    ///      slippage), then restake for AERO rewards. Shared by `deployIdleImpl` and `_leverUp`.
    function _wrapAddRestake(uint256 cbBTCAmt, uint256 wethAmt, uint256 minLiquidity) private {
        Layout storage $ = _layout();
        _wrapNativeEth();
        uint256 tokenId_ = $.tokenId;
        address gauge_ = $.gauge;
        ICLGauge(gauge_).withdraw(tokenId_);
        (uint256 amt0, uint256 amt1) = _amounts01(cbBTCAmt, wethAmt);
        _addLiquidity(amt0, amt1, minLiquidity);
        _approveAndStake(gauge_, tokenId_);
    }

    // ── redeem helpers ──

    /// @dev Repay f = shares/supply of each Moonwell borrow from currently-held tokens, capping
    ///      each leg's repay at the REDEEMER's own budget = `legBal − stayersLeg`. `stayersLeg`
    ///      is the stayers' reserved `(1-f)` share of a PRE-EXISTING idle leg (a rerange
    ///      remainder), snapshotted before the unwind. Subtracting it makes the budget exactly
    ///      `f·idleLeg + collectedLeg` — the redeemer's fair share — so an IL over-repay can never
    ///      eat the stayers' reserve; the genuine shortfall instead flows to `cbShort`/`wethShort`
    ///      and is covered from the redeemer's own freed collateral. With `stayersLeg == 0` (full
    ///      redeem f=1, or no rerange remainder) the cap is the full balance — behaviour unchanged.
    ///      Returns the shortfall amounts (0 if fully covered).
    function _redeemRepayFromCollected(uint256 shares, uint256 supply, uint256 stayersCb, uint256 stayersWeth)
        private
        returns (uint256 cbShort, uint256 wethShort)
    {
        Layout storage $ = _layout();
        address mCbBTC_ = $.mCbBTC;
        address mWeth_ = $.mWeth;
        address cbBTC_ = $.cbBTC;
        address weth_ = $.weth;

        uint256 cbDebtRepay = Math.mulDiv(IMoonwellMarket(mCbBTC_).borrowBalanceStored(address(this)), shares, supply);
        uint256 wethDebtRepay = Math.mulDiv(IMoonwellMarket(mWeth_).borrowBalanceStored(address(this)), shares, supply);

        // ── cbBTC leg ── (budget = balance minus the stayers' reserved idle-leg share)
        if (cbDebtRepay > 0) {
            uint256 cbBal = IERC20(cbBTC_).balanceOf(address(this));
            uint256 cbBudget = cbBal > stayersCb ? cbBal - stayersCb : 0;
            uint256 cbRepay = cbBudget >= cbDebtRepay ? cbDebtRepay : cbBudget;
            if (cbRepay > 0) {
                IERC20(cbBTC_).forceApprove(mCbBTC_, cbRepay);
                _repay(mCbBTC_, cbRepay);
            }
            cbShort = cbDebtRepay > cbBudget ? cbDebtRepay - cbBudget : 0;
        }

        // ── WETH leg ── (budget = balance minus the stayers' reserved idle-leg share)
        if (wethDebtRepay > 0) {
            uint256 wethBal = IERC20(weth_).balanceOf(address(this));
            uint256 wethBudget = wethBal > stayersWeth ? wethBal - stayersWeth : 0;
            uint256 wethRepay = wethBudget >= wethDebtRepay ? wethDebtRepay : wethBudget;
            if (wethRepay > 0) {
                IERC20(weth_).forceApprove(mWeth_, wethRepay);
                _repay(mWeth_, wethRepay);
            }
            wethShort = wethDebtRepay > wethBudget ? wethDebtRepay - wethBudget : 0;
        }
    }

    /// @dev Cover a debt shortfall (IL-driven) by swapping idle USDC → `tokenOut` via
    ///      exactOutputSingle, then repaying the exact remaining amount. `amountInMax` caps the
    ///      USDC spent: the FULL-redeem path passes `type(uint256).max` (→ bounded only by idle USDC,
    ///      oracle-free — no stayers exist, Phase 2 `_settleShortfall` handles any residue); the
    ///      PARTIAL-redeem path passes the redeemer's own budget (`balance − stayersIdle`) so a cover
    ///      that would dip into stayer idle reverts. The permissionless deleverage path passes an
    ///      oracle+slippage ceiling so a sandwiched buy reverts instead of overpaying (H1).
    function _redeemCoverShortfall(address tokenOut, address market, uint256 amountOut, uint256 amountInMax) private {
        Layout storage $ = _layout();
        uint256 usdcBal = IERC20($.usdc).balanceOf(address(this));
        if (usdcBal == 0 || amountOut == 0) return;
        uint256 maxIn = usdcBal < amountInMax ? usdcBal : amountInMax;
        IERC20($.usdc).forceApprove($.swapRouter, maxIn);
        ICLSwapRouter($.swapRouter).exactOutputSingle(
            ICLSwapRouter.ExactOutputSingleParams({
                tokenIn: $.usdc,
                tokenOut: tokenOut,
                tickSpacing: _legSwapSpacing(tokenOut),
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountOut: amountOut,
                amountInMaximum: maxIn,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20($.usdc).forceApprove($.swapRouter, 0);
        uint256 tokenBal = IERC20(tokenOut).balanceOf(address(this));
        if (tokenBal > 0) {
            IERC20(tokenOut).forceApprove(market, tokenBal);
            _repay(market, tokenBal >= amountOut ? amountOut : tokenBal);
        }
    }

    /// @dev Redeem f = shares/supply of the mUSDC underlying collateral.
    function _redeemCollateral(uint256 shares, uint256 supply) private {
        address mUsdc_ = _layout().mUsdc;
        uint256 cBal = ICToken(mUsdc_).balanceOf(address(this));
        if (cBal == 0) return;
        uint256 rate = ICToken(mUsdc_).exchangeRateStored();
        uint256 totalUnderlying = (cBal * rate) / 1e18;
        uint256 toRedeem = Math.mulDiv(totalUnderlying, shares, supply);
        if (toRedeem == 0) return;
        _redeemUnderlying(mUsdc_, toRedeem);
    }

    // ── Shared helpers (health, NPM read, config build) ──

    /// @notice Delegatecall entrypoint that runs `_assertHealthy` in the caller's context.
    ///         `executeImpl` / `deployIdleImpl` call the private `_assertHealthy` directly;
    ///         this public wrapper exists so the post-op health invariant can be exercised in
    ///         isolation (offline `HealthHarness` unit tests).
    function assertHealthyImpl() public view {
        _assertHealthy();
    }

    /// @notice Post-operation LTV + Moonwell-liquidity invariant.
    ///         Reverts `UnhealthyPosition` if Chainlink-priced LTV exceeds `maxLtvBps` or
    ///         Moonwell reports a shortfall. Scaling mirrors `LeveragedAeroValuation`.
    function _assertHealthy() private view {
        Layout storage $ = _layout();
        // ── Collateral (USDC face, 6dp) ──
        address mUsdc_ = $.mUsdc;
        uint256 cBal = ICToken(mUsdc_).balanceOf(address(this));
        uint256 rate = ICToken(mUsdc_).exchangeRateStored();
        uint256 collateralUsd = (cBal * rate) / 1e18;

        // ── Raw borrow balances ──
        uint256 cbDebt = IMoonwellMarket($.mCbBTC).borrowBalanceStored(address(this));
        uint256 wethDebt = IMoonwellMarket($.mWeth).borrowBalanceStored(address(this));
        if (cbDebt == 0 && wethDebt == 0) return; // no debt → trivially healthy (skip oracle)

        // ── Price via hardened Chainlink (same feeds + staleness guards as nav()) ──
        (uint256 pBTC, uint256 pETH, uint256 pUsdc) = _readAllPrices();

        // ── Debt (USDC face, 6dp) ──
        uint256 debtUsd =
            _tokenToUsdc(cbDebt, $.cbBTCDecimals, pBTC, pUsdc) + _tokenToUsdc(wethDebt, $.wethDecimals, pETH, pUsdc);
        if (debtUsd == 0) return; // dust-level debt rounds to 0 → trivially healthy

        // ── LTV check — binding post-op gate ──
        uint16 maxLtv = $.maxLtvBps;
        if (collateralUsd == 0) revert UnhealthyPosition(type(uint256).max, uint256(maxLtv));
        uint256 ltvBps_ = (debtUsd * 10_000) / collateralUsd;
        if (ltvBps_ > uint256(maxLtv)) revert UnhealthyPosition(ltvBps_, uint256(maxLtv));

        // ── Moonwell belt: authoritative no-liquidation check ──
        (uint256 err,, uint256 shortfall) = IComptroller($.comptroller).getAccountLiquidity(address(this));
        if (err != 0 || shortfall != 0) revert UnhealthyPosition(ltvBps_, uint256(maxLtv));
    }

    /// @dev Reads only the 3 fields we need from the NPM positions() 12-tuple via a
    ///      low-level staticcall + assembly (avoids placing all 12 returns on the stack).
    function _npmPositionData() private view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address npm_ = _layout().npm;
        uint256 tokenId_ = _layout().tokenId;
        bool ok;
        bytes memory ret;
        (ok, ret) = npm_.staticcall(abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_));
        if (!ok) revert InvalidNpmReturn();
        if (ret.length < 0x120) revert InvalidNpmReturn();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // ret + 0x20 = start of returndata; field 5 (tickLower) = +0xC0
            tickLower := mload(add(ret, 0xC0))
            tickUpper := mload(add(ret, 0xE0))
            liquidity := mload(add(ret, 0x100))
        }
    }

    /// @dev CALM-GATE-ONLY, PARTIAL `LeveragedAeroValuation.Config`: populates exactly the three
    ///      fields `_calmGate` reads (`pool`, `twapWindow`, `calmDeviationTicks`) and leaves every
    ///      other member at its zero default. The manager never prices — all three call sites
    ///      (`rerangeImpl`, `_mintAndStake`, `_addLiquidity`) pass this straight to `_calmGate`.
    ///
    ///      DO NOT hand the result to `netEquityUsdc` (or anything else that reads the feed /
    ///      market / decimals members) — it would silently value against address(0). If `_calmGate`
    ///      ever grows a new field read, populate it HERE too. The strategy keeps its own FULL
    ///      `_config()` builder, which is the one valuation genuinely consumes.
    function _config() private view returns (LeveragedAeroValuation.Config memory c) {
        Layout storage $ = _layout();
        c.pool = $.pool;
        c.calmDeviationTicks = $.calmDeviationTicks;
        c.twapWindow = $.twapWindow;
    }
}
