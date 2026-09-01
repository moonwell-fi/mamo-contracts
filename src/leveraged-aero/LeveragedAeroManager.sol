// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {ICToken, IComptroller, IMoonwellMarket} from "./sherwood/interfaces/IMoonwellMarket.sol";
import {ICLGauge, ICLPool, INonfungiblePositionManager} from "./sherwood/interfaces/ISlipstream.sol";
import {LiquidityAmounts} from "./sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "./sherwood/libraries/TickMath.sol";

/// @dev Minimal WETH9 interface — wraps native ETH into ERC-20 WETH.
interface IWETH9 {
    function deposit() external payable;
}

/// @dev Locally declared rather than imported, so the manager keeps no dependency on the strategy (which
///      imports THIS file). Under DELEGATECALL only a call on `address(this)` gives reverts a `try`-able frame.
interface IRedeemSweepFloors {
    function redeemSweepFloors(uint256 cbAmt, uint256 wethAmt) external view returns (uint256, uint256);
}

/// @dev Local interface, as `IRedeemSweepFloors`. `sellRedeemRewardSelf` is the strategy's `OnlySelf`-gated
///      best-effort sale of the tranche this redeem's `gauge.withdraw` auto-claimed; returns stayers' `(1−f)`.
interface IRewardSaleSelf {
    function sellRedeemRewardSelf(uint256 shares, uint256 supply) external returns (uint256 stayersShare);
}

/// @title  LeveragedAeroManager
/// @notice DEPLOYED, delegatecalled venue library for `LeveragedAerodromeCLStrategy` — the heavy on-venue
///         sequences, run in the clone's context, never touching `vault()`/`proposer()`/shares/fees.
///         CORRUPTION-CRITICAL: `Layout`, `STORAGE_SLOT` and `_layout()` must stay byte-identical to the
///         strategy's or a delegatecall reads the wrong slots. TWO SHAPES, no mode flag — `legBIsAsset` is
///         DERIVED at init as `cbBTC == usdc`: false ⇒ BOTH legs borrowed 50/50 by USD against the whole
///         deposit; true ⇒ only leg A is borrowed and LP'd against the rest, and leg B (the only slot that
///         may be the unit of account) carries NO debt, swaps as the IDENTITY and prices at FACE.
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
    // NOTE: raised by `LeveragedAeroValuation.readUsd8`, which `_readUsd8` now forwards to. Kept declared
    // here (same signature, same selector) under this library's mirroring convention, so a test may
    // expect it off the manager, the strategy or the valuation library interchangeably.
    error FeedDecimalsMismatch();
    error ZeroMinOut();
    error BelowOracleFloor(); // compound swap fill < AERO/USD oracle floor (L9)
    error UnsupportedLeg(); // a swap was routed for a token that is neither configured leg
    // A lever-down repaying the ENTIRE debt removes all liquidity and orphans the staked position NFT (see
    // the guard in `_leverDown`); route full unwinds through `flatten()`.
    error FullUnwindNotSupported();
    // NOTE: `InsufficientIdleForLeverUp` (asset-mode lever-up, see `_leverUp`) is NOT declared here — it
    // is raised by `LeveragedAeroValuation.assetModeLeverUpPair`, alongside the arithmetic that sizes the
    // draw, exactly as `DegenerateRange` is. Same convention: valuation-raised errors are not mirrored.

    // ── Events (emitted from the STRATEGY's address via delegatecall; mirrored in its ABI) ──
    /// @notice `redeemUnwindImpl`'s closing leg sweeps ran with their min-out floors at ZERO because the
    ///         Chainlink derivation reverted: fail-open so the `emergencyRedeem` deadman completes with the
    ///         oracle down, marked because those swaps were then UNBOUNDED. Naming, for this stack's three
    ///         fail-opens: `…Degraded` = a GUARD fell back, `…Deferred` = an optional ACTION was skipped.
    event RedeemSweepFloorsDegraded();

    // ── Constants (compile-time literals, duplicated from the strategy) ──
    /// @dev `deleverage()` repays down to `minHealthBps × (1 + this/1e4)` — a small buffer above the
    ///      minimum so a rescue doesn't land on the threshold and immediately re-trigger.
    uint16 private constant DELEVERAGE_BUFFER_BPS = 500; // +5% above minHealthBps

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
        address recipient; // `fulfillRedeem` payee, fixed at request time; defaults to `owner`
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
        // ── appended for the per-cycle rerange width band (keep byte-identical) ──
        uint24 width; // current full range width in ticks (split across the tick by `skewBps`)
        uint24 minWidth; // lower bound for a proposer-supplied rerange width
        uint24 maxWidth; // upper bound for a proposer-supplied rerange width
        // ── appended for the config-emergent pool shape (keep byte-identical) ──
        bool legBIsAsset; // DERIVED at init: leg-B slot == usdc → asset-as-a-leg shape (packs above)
        // ── appended for the rerange SKEW and its governance band (keep byte-identical). Placed HERE,
        //    not after the hedged principals, so all three free-pack into the existing tail slot
        //    (20 bytes used → 26) and `hedgedDebtA`/`hedgedDebtB` keep a byte-identical slot AND offset:
        //    26 + 16 > 32, so `hedgedDebtA` still starts the NEXT slot at offset 0. ──
        uint16 skewBps; // fraction of `width` placed BELOW the pool tick (1e4 scale; 5000 == centred)
        uint16 minSkewBps; // lower bound for a proposer-supplied rerange skew
        uint16 maxSkewBps; // upper bound for a proposer-supplied rerange skew
        // ── appended for the borrow-interest hedge (keep byte-identical) ──
        uint128 hedgedDebtA; // leg-A borrowed PRINCIPAL the LP hedges (packs with hedgedDebtB below)
        uint128 hedgedDebtB; // leg-B borrowed principal the LP hedges (0 in asset-mode: leg B never borrows)
        // ── LAST field: appended for the owner-staged venue migration (keep byte-identical) ──
        bytes32 stagedVenueHash; // keccak256(abi.encode(VenueParams)) staged by the vault owner; 0 == none
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

    /// @notice Open the levered CL position (body of the strategy's `_execute`): enterMarkets → supply
    ///         collateral → borrow → wrap → mint CL → stake gauge. Works in BOTH shapes.
    /// @dev The calm-gate is hoisted here so the range is derived ONCE off a validated tick and threaded
    ///      through both the asset-mode sizing and the mint; a shoved tick reverts before any FUND-MOVING
    ///      venue call. GATE ORDERING IS NON-UNIFORM BY DESIGN: `deployIdleImpl`/`_leverUp` reach it only
    ///      inside `_addLiquidity`, still before the pool is touched and unskippable, and the burn-only
    ///      paths reach none (concave, so a gate could only let an attacker DENY an exit).
    /// @param minLiquidity Floor on the CL liquidity the genesis mint must produce, on top of the §8
    ///                     two-sided `maxSlippageBps` mins. `execute` passes 0; `redeploy` the proposer's.
    function executeImpl(uint256 minLiquidity) public {
        Layout storage $ = _layout();
        // THE WHOLE FLAT-BOOK POT, raw or supplied: `redeploy` may reach here on a book the keeper swept
        // into mUSDC, where the raw balance reads 0. Leans on the `tokenId == 0 ⇒ debt == 0` invariant.
        uint256 usdcAmt = _usdcAvailable();
        if (usdcAmt == 0) revert ExecuteZeroBalance();
        _materialiseUsdc(usdcAmt);
        address[] memory markets = new address[](1);
        markets[0] = $.mUsdc;
        IComptroller($.comptroller).enterMarkets(markets);
        LeveragedAeroValuation.calmGate($.pool, $.twapWindow, $.calmDeviationTicks);
        (int24 tickLower, int24 tickUpper) =
            LeveragedAeroValuation.skewedTickRange($.pool, $.tickSpacing, $.width, $.skewBps);
        (uint256 cbBTCAmt, uint256 wethAmt) = _supplyAndBorrow(usdcAmt, tickLower, tickUpper);
        _wrapNativeEth();
        _mintAndStake(cbBTCAmt, wethAmt, tickLower, tickUpper, minLiquidity);
        _assertHealthy();
    }

    /// @notice Full proportional unwind to the strategy (body of the strategy's `_settle`). The
    ///         strategy forwards the realized USDC to the vault afterward.
    /// @dev Sweeps the two LEG tokens ONLY; selling the tranche `gauge.withdraw` auto-claims is the
    ///      caller's job, since `flattenImpl` needs it fail-closed and terminal `_settle` best-effort.
    /// @return realizedUsdc USDC held by the strategy after the unwind.
    function settleImpl() public returns (uint256 realizedUsdc) {
        Layout storage $ = _layout();
        // 1+2. Unstake + remove 100% liquidity + collect (num==den → no restake)
        _unwindLiquidity(1, 1);
        // 3. Repay both Moonwell borrows (handles shortfall)
        _settleRepayDebts();
        // 4. Redeem all remaining mUSDC collateral (debt = 0 now)
        uint256 mBal = ICToken($.mUsdc).balanceOf(address(this));
        if (mBal > 0) _redeemCTokens($.mUsdc, mBal);
        // 5. Sweep residual WETH + cbBTC → USDC (Chainlink-bounded min-out)
        //    The read is unconditional: the short-circuit would fire only on an already-flat book, where
        //    nothing else needs an oracle either, and would have to be asset-mode-aware to work at all.
        {
            (uint256 pBTC, uint256 pETH, uint256 pUsdc) = _readAllPrices();
            _sweepAtOracleFloor($.weth, $.wethDecimals, pETH, pUsdc);
            _sweepAtOracleFloor($.cbBTC, $.cbBTCDecimals, pBTC, pUsdc);
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
        //
        // THE SNAPSHOT MUST STAY PRE-`_unwindLiquidity` (load-bearing in BOTH shapes, and the crux of
        // the asset-as-a-leg shape): the unwind sheds `f` of the LP, which in asset-mode delivers real
        // USDC into this same balance. That LP-shed USDC is 100% the REDEEMER's (only their `f` of the
        // liquidity was removed), so it must NOT enter the stayers' `(1-f)` reservation. Reading the
        // balance after the unwind would reserve `(1-f)` of it for stayers too and silently under-pay
        // the redeemer; conversely the redeemer's cover budget below (`bal − stayersIdle`) correctly
        // INCLUDES it. This is what the old `UnsupportedLeg` ban on `cbBTC == usdc` was protecting.
        uint256 idleUsdcBefore = IERC20($.usdc).balanceOf(address(this));
        uint256 stayersIdle = idleUsdcBefore - Math.mulDiv(idleUsdcBefore, shares, supply);
        // Snapshot the stayers' (1-f) share of any PRE-EXISTING idle leg (a `rerange` remainder), which the
        // step-C sweep would otherwise hand a partial redeemer in full; reserving it keeps redeem
        // oracle-free. ASSET-MODE: that balance IS the idle USDC `stayersIdle` reserved, so reserve 0.
        uint256 stayersCb = $.legBIsAsset ? 0 : _stayerLeg($.cbBTC, shares, supply);
        uint256 stayersWeth = _stayerLeg($.weth, shares, supply);

        // SCALE the hedged-principal basis pro-rata, BEFORE any repay reaches `_repay`'s clamp. A partial
        // redeem sheds `f` of the LP AND repays `f` of the debt, so the interest drift that SURVIVES is
        // `(1−f)·drift` — the exposure is scaled, not cleared. Scaling the basis by `(1−f)` keeps
        // `debt − hedged` equal to that survivor so the next harvest still removes it; letting `_repay`'s
        // clamp re-anchor the basis to the post-repay debt instead would silently FORGIVE the survivor,
        // leaving a real (if slower) accumulating short — the very bug this basis exists to close.
        // f == 1 (full redeem) drives both to 0, matching the flat book this branch leaves behind.
        $.hedgedDebtA -= uint128(Math.mulDiv(uint256($.hedgedDebtA), shares, supply));
        $.hedgedDebtB -= uint128(Math.mulDiv(uint256($.hedgedDebtB), shares, supply));

        // A — partial CL unwind (pool-based mins, oracle-free).
        _unwindLiquidity(shares, supply);

        // A2 — SELL THE REWARD TRANCHE THIS REDEEM'S OWN UNWIND JUST AUTO-CLAIMED, AND SPLIT IT.
        // `gauge.withdraw` is all-or-nothing per NFT, so it claims what the WHOLE book farmed, of which the
        // redeemer owns `f`; the wrapper returns the stayers' `(1−f)` to add here. FAIL-OPEN inside the
        // wrapper (hence no `try`) so `emergencyRedeem` completes, while the sale fails CLOSED in its own
        // frame — the tranche is never sold blind, and a swallowed revert leaves it with the stayers.
        stayersIdle += IRewardSaleSelf(address(this)).sellRedeemRewardSelf(shares, supply);

        // B — repay f of each debt from collected tokens; capture any IL shortfall. Each repay is capped at
        // the REDEEMER's own per-leg budget (`legBal − stayersLeg`), so a severe shortfall flows to
        // `cbShort`/`wethShort` instead of eating the stayers' reserved `(1-f)` share (§7).
        (uint256 cbShort, uint256 wethShort) = _redeemRepayFromCollected(shares, supply, stayersCb, stayersWeth);

        // C — SWEEP THE SURPLUS LEGS FIRST, SO THE DEFICIT BUY IS ORACLE-FREE. An IL shortfall is
        // ASYMMETRIC, so the surplus leg funds the deficit buy without reaching Phase 2's Chainlink reads;
        // this must sit AFTER the pro-rata repays and BEFORE the covers, which is what requires Phase 1
        // best-effort and Phase 2 exact-output. Each floor prices the amount ACTUALLY SOLD, and the `try` is
        // load-bearing: `emergencyRedeem` routes through here, so a fail-closed floor would freeze funds.
        {
            uint256 cbFloor;
            uint256 wethFloor;
            // `_sellable` mirrors `_sweepLegToUsdc`'s own gates, so the floor prices what will really sell.
            try IRedeemSweepFloors(address(this)).redeemSweepFloors(
                _sellable($.cbBTC, stayersCb), _sellable($.weth, stayersWeth)
            ) returns (uint256 f0, uint256 f1) {
                (cbFloor, wethFloor) = (f0, f1);
            } catch {
                // Oracle / sequencer down: floors stay 0 so the deadman exit still completes, MARKED
                // because the swaps below then run UNBOUNDED and this `catch` cannot tell that from OOG.
                emit RedeemSweepFloorsDegraded();
            }
            _sweepLegToUsdc($.cbBTC, stayersCb, cbFloor);
            _sweepLegToUsdc($.weth, stayersWeth, wethFloor);
        }

        // D — clear whatever debt the pro-rata repay could not, then free the collateral.
        if (shares == supply) {
            // Full redemption — two-phase debt clearance before 100 % collateral redeem.
            // Phase 1 (oracle-free): cover IL shortfall from on-hand USDC via exact-output swap. BEST-EFFORT
            //   is the point — `0 < usdcBal < needed` cannot partially fill, so `swapExactOut` swallows the
            //   revert and reports `filled == false`; that band used to revert the redeem, `emergencyRedeem`
            //   included, which is why the raw float `supplyIdle` leaves un-supplied is an operator dial.
            if (cbShort > 0) _redeemCoverShortfall($.cbBTC, $.mCbBTC, cbShort, type(uint256).max, true);
            if (wethShort > 0) _redeemCoverShortfall($.weth, $.mWeth, wethShort, type(uint256).max, true);
            // Phase 2 (self-fund fallback): if debt remains after step C and Phase 1, fund the buy out of
            //   mUSDC collateral at the Chainlink-priced budget and repay. `_settleShortfall` reads NO feed
            //   on a zero borrow balance — reachable only because step B repays off `borrowBalanceCurrent`.
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
                _redeemCoverShortfall($.cbBTC, $.mCbBTC, cbShort, bal > stayersIdle ? bal - stayersIdle : 0, false);
            }
            if (wethShort > 0) {
                uint256 bal = usdc.balanceOf(address(this));
                _redeemCoverShortfall($.weth, $.mWeth, wethShort, bal > stayersIdle ? bal - stayersIdle : 0, false);
            }
        }

        // assetsOut = total USDC minus the (1-f) idle-USDC portion that stays for stayers (the
        // stayers' idle-leg share already stayed un-swept above, as legs).
        uint256 usdcFinal = IERC20($.usdc).balanceOf(address(this));
        return usdcFinal > stayersIdle ? usdcFinal - stayersIdle : 0;
    }

    // NOTE: `fastRedeemImpl` lives in `LeveragedAeroVenue`; it reaches back through the public
    // `readCollateralDebtImpl` / `assertHealthyImpl`, so the gate basis is still this library's.

    /// @notice Public view wrapper over `_readCollateralDebt` for the strategy's `previewRedeem`
    ///         (advisory fast-path gate prediction). Delegatecalled under staticcall — the oracle
    ///         reads inside `_readCollateralDebt` fail-closed (revert) on a down feed, which the
    ///         strategy's `previewRedeem` catches to return `(0,false)`.
    function readCollateralDebtImpl() public view returns (uint256 collateralUsdc, uint256 debtUsdc) {
        return _readCollateralDebt();
    }

    /// @notice Deploy `amount` of idle strategy USDC into the existing levered position
    ///         (body of the strategy's `deployIdle`): supply + borrow + increaseLiquidity.
    /// @dev Asset-mode sizes against the STORED range, so a range the price has left is one-sided and fails
    ///      closed (`DegenerateRange`); a `rerange` unblocks it only while spot is still INSIDE that band.
    ///      No up-front calm-gate — it lives inside `_addLiquidity`. `InsufficientIdle` here bounds
    ///      `_usdcAvailable()` AS A BELT ONLY: the binding bound is the strategy entrypoint's raw +
    ///      UN-LEVERED collateral, since `_supplyAndBorrow` borrows off the GROSS `amount` and a call funded
    ///      from levered collateral would walk LTV toward `maxLtvBps`.
    function deployIdleImpl(uint256 amount, uint256 minLiquidity) public {
        Layout storage $ = _layout();
        if (amount > _usdcAvailable()) revert InsufficientIdle();
        _materialiseUsdc(amount);
        (uint256 cbBTCAmt, uint256 wethAmt) = _supplyAndBorrow(amount, $.posTickLower, $.posTickUpper);
        _wrapAddRestake(cbBTCAmt, wethAmt, minLiquidity);
        _assertHealthy();
    }

    /// @notice Compound AERO rewards (body of the strategy's `compound`): claim AERO → swap ALL to
    ///         USDC via the Aerodrome v2 volatile pool (deepest AERO/USDC on Base, bounded by
    ///         `minUsdcOut`) → redeploy the proceeds at target leverage via `deployIdleImpl`. No-op
    ///         when there's no position or no AERO. Fee crystallisation lives in the strategy
    ///         entrypoint, NOT here.
    /// @dev The redeploy is ATOMIC with the harvest: anything that fails the deploy path reverts the whole
    ///      call, claim and sale included — see step 5 for why that costs nothing, and for the recovery.
    /// @param minUsdcOut   Minimum USDC out of the AERO→USDC swap (slippage guard, on GROSS usdcOut).
    /// @param minLiquidity Minimum CL liquidity on the redeploy (slippage guard).
    function compoundImpl(uint256 minUsdcOut, uint256 minLiquidity) public {
        Layout storage $ = _layout();
        uint256 tokenId_ = $.tokenId;
        if (tokenId_ == 0) return; // flat book — nothing staked, nothing to compound
        if (minUsdcOut == 0) revert ZeroMinOut(); // belt: caller must pass a nonzero floor (see BelowOracleFloor)

        // 1. Claim AERO for the staked NFT. The reward token is read from the gauge
        //    (definitionally AERO on this pool — fork-confirmed `rewardToken() == AERO`).
        address gauge_ = $.gauge;
        address aero = ICLGauge(gauge_).rewardToken();
        ICLGauge(gauge_).getReward(tokenId_);
        uint256 aeroBal = IERC20(aero).balanceOf(address(this));
        if (aeroBal == 0) return; // no rewards accrued — clean no-op

        // 2. Derive the on-chain oracle floor from a hardened AERO/USD read (8dp, fail-closed): a
        //    stale/broken feed reverts the whole compound (defer the harvest, intended posture).
        //    THE PEG LEG IS PART OF THE FLOOR, not an assumed 1.00: the floor is post-checked against
        //    `usdcOut`, a USDC-FACE amount, so a bare `/1e20` goes lax below peg and bricks `compound`
        //    above it. `_tokenToUsdc` is the basis the debt, health and settle-sweep paths already use.
        uint256 floor = _tokenToUsdc(aeroBal, 18, _readUsd8($.aeroUsdFeed), _readUsd8($.usdcFeed))
            * (10000 - uint256($.maxSlippageBps)) / 10000;
        //    DUST NO-OP, as `LeveragedAeroVenue._sellRewardBalance`: a balance worth under one micro-USD
        //    floors to 0 and the router fills it at 0, which the nonzero `minUsdcOut` would then revert —
        //    so reward-token dust donated to a gauge with no live emissions would brick `compound`.
        if (floor == 0) return;

        // 3. Swap ALL claimed AERO → USDC via the Aerodrome v2 volatile pool, passing the caller's
        //    minUsdcOut to the router. The measured-fill floor below is the robust guard (router-honesty
        //    independent); the effective bound is max(minUsdcOut, floor), enforced independently.
        //    The venue mechanics (Route[] + the v2 router interface) live in
        //    `LeveragedAeroValuation.swapAeroToUsdc` for EIP-170 headroom; it returns the MEASURED fill,
        //    so the post-check below is unchanged and still independent of what the router claims.
        uint256 usdcOut = LeveragedAeroValuation.swapAeroToUsdc(aero, $.usdc, aeroBal, minUsdcOut);
        if (usdcOut < floor) revert BelowOracleFloor(); // post-check on the measured fill (L9)
        if (usdcOut == 0) return; // unreachable when floor > 0 (aeroBal > 0), kept as defence

        uint256 redeploy = usdcOut;

        // 4. RE-HEDGE ACCRUED BORROW INTEREST out of the harvest, BEFORE the redeploy. Interest grows the
        //    debt leg without growing the LP leg, so without this step every harvest left the book a
        //    little more SHORT and nothing ever removed it (the fund is sold as delta-neutral on leg A).
        //    Buying that interest back and repaying it lands the financing cost as NAV DRAG — less
        //    harvest reinvested — instead of as accumulating exposure. Bounded by the harvest's own
        //    proceeds, so stayers' idle USDC and the collateral are never touched; a short budget hedges
        //    partially and carries the remainder to the next harvest rather than reverting.
        //    Ordering: ahead of the redeploy so `deployIdleImpl` sizes its NEW borrow off the corrected
        //    debt and the post-op `_assertHealthy` sees the final book.
        redeploy -= _hedgeInterestDrift(redeploy);

        // 5. Redeploy the net yield into the position at target leverage (supply → borrow →
        //    increaseLiquidity → restake → _assertHealthy). Any pre-existing idle USDC is left
        //    untouched — compound deploys the AERO yield, nothing else.
        //    THE REDEPLOY IS ATOMIC WITH THE HARVEST, DELIBERATELY: `DegenerateRange`, the calm gate,
        //    `minLiquidity`, a Moonwell error code or the closing health assert each unwind the WHOLE
        //    `compound`, claim and AERO sale included. Waiting costs nothing (the tranche keeps accruing,
        //    an out-of-range position earns no emissions), and catching it would no-op three real guards.
        if (redeploy > 0) deployIdleImpl(redeploy, minLiquidity);
    }

    /// @dev Marshal the Layout reads for `LeveragedAeroValuation.hedgeBorrowInterest` and drive it over
    ///      whichever legs actually carry debt. THE MEASURE, the repay-vs-add reasoning, the budget bound
    ///      and the graceful-degradation contract all live in that function's header — this is only the
    ///      call site, and it is deliberately thin: the body sits in the valuation library because the
    ///      manager is at the EIP-170 cap (the same relief valve `assetModeSplit` / `calmGate` /
    ///      `depositMins` already use).
    /// @param budget Harvest proceeds available (6dp). A hard ceiling on total USDC spent.
    /// @return spent USDC consumed across both legs.
    function _hedgeInterestDrift(uint256 budget) private returns (uint256 spent) {
        if (budget == 0) return 0;
        Layout storage $ = _layout();
        LeveragedAeroValuation.HedgeBook memory b;
        b.usdc = $.usdc;
        b.swapRouter = $.swapRouter;
        b.usdcFeed = $.usdcFeed;
        b.sequencerFeed = $.sequencerFeed;
        b.maxDelay = $.maxDelay;
        b.gracePeriod = $.gracePeriod;
        b.maxSlippageBps = uint256($.maxSlippageBps);
        b.budgetUsdc = budget;
        // Leg A — the always-borrowed volatile leg, in BOTH shapes.
        b.marketA = $.mWeth;
        b.legA = $.weth;
        b.feedA = $.wethFeed;
        b.spacingA = $.wethSwapTickSpacing;
        b.decimalsA = $.wethDecimals;
        b.hedgedA = uint256($.hedgedDebtA);
        // Leg B — borrowed, and therefore drifting, ONLY in the two-borrowed-legs shape. In asset-mode
        // leg B IS the unit of account, init pins `mCbBTC == mUsdc`, and nothing ever borrows it, so its
        // drift is structurally zero; leaving `marketB` at 0 is how that is signalled.
        if (!$.legBIsAsset) {
            b.marketB = $.mCbBTC;
            b.legB = $.cbBTC;
            b.feedB = $.cbBTCFeed;
            b.spacingB = $.cbBTCSwapTickSpacing;
            b.decimalsB = $.cbBTCDecimals;
            b.hedgedB = uint256($.hedgedDebtB);
        }
        return LeveragedAeroValuation.hedgeBorrowInterest(b);
    }

    /// @notice Re-range the CL position WITHOUT swapping (body of the strategy's `rerange`): calm-gate →
    ///         remove 100% liquidity + collect → size the collected legs → derive the new aligned range →
    ///         re-add → restake → assert health. Debt + collateral untouched, principal conserved; the
    ///         collected ratio can't match the new range, so a remainder of ONE borrowed leg is left idle
    ///         (NAV-counted), and a fresh tokenId is minted (Slipstream ticks are immutable). No-op on a
    ///         flat book. Once spot has LEFT the old band the new one is placed WHOLLY on the populated
    ///         side, abutting spot and starting out of range; a true recentre needs `flatten` + `redeploy`.
    /// @dev TAKES NO RANGE PARAMS: `width`/`skewBps` were validated AND PERSISTED by the strategy
    ///      entrypoint, ahead of the flat-book bail-out below, and step 4 reads both from storage.
    /// @param minLiq0 Minimum token0 the re-add must consume. On a one-sided reopen the caller floors the
    ///        populated side and passes 0 for the other.
    /// @param minLiq1 Minimum token1 the re-add must consume (see `minLiq0`).
    function rerangeImpl(uint256 minLiq0, uint256 minLiq1) public {
        Layout storage $ = _layout();
        if ($.tokenId == 0) return; // flat book — nothing to re-range (width/skew already stored)

        // 1-3. Calm-gate, snapshot leg B, unwind 100% + collect, size — shared with `remintRangeImpl`.
        (, uint256 cbAmt, uint256 wethAmt) = _calmUnwindAll();
        (uint256 amt0, uint256 amt1) = _amounts01(cbAmt, wethAmt);

        // 4. Derive the range from the stored width/skew AND what the unwind collected: two-sided → the
        //    ordinary skewed band around spot; ONE-SIDED → a band wholly on the populated side, the only
        //    range a swap-free re-add can fill. `minLiq0`/`minLiq1` guard the consumed amounts.
        (int24 tickLower, int24 tickUpper) =
            LeveragedAeroValuation.rerangeTickRange($.pool, $.tickSpacing, $.width, $.skewBps, amt0, amt1);
        (uint256 newTokenId,, uint256 used0, uint256 used1) = _mintPosition(amt0, amt1, tickLower, tickUpper);
        if (used0 < minLiq0 || used1 < minLiq1) revert InsufficientLiquidity();

        // 5. Restake the new NFT to resume AERO gauge rewards (mirrors _mintAndStake).
        _approveAndStake($.gauge, newTokenId);

        // 6. Persist the new position (nav()/positions() now read the new NFT).
        $.tokenId = newTokenId;
        $.posTickLower = tickLower;
        $.posTickUpper = tickUpper;

        // 7. Debt + collateral untouched by rerange → health preserved; assert as a belt.
        _assertHealthy();
    }

    /// @notice Body of the strategy's `remintRange`: the shared re-range prologue → an optional `swapBps`
    ///         swap between the legs → mint at `[tickLower, tickUpper]` → restake → assert health. At
    ///         `swapBps == 0` this IS `rerangeImpl` at a caller-chosen band. Params: see `remintRange`.
    function remintRangeImpl(
        int24 tickLower,
        int24 tickUpper,
        bool zeroForOne,
        uint16 swapBps,
        uint256 minSwapOut,
        uint256 minLiquidity
    ) public {
        Layout storage $ = _layout();
        // DELIBERATE DEVIATION from `rerangeImpl`'s silent flat-book return: that exists to persist
        // width/skew, and here there is nothing to persist — a silent success would mislead the keeper.
        if ($.tokenId == 0) revert LeveragedAeroValuation.NothingToRerange();

        (uint256 legBBefore, uint256 cbAmt, uint256 wethAmt) = _calmUnwindAll();

        // `zeroForOne` is POOL order, so the input is leg A exactly when it agrees with `wethIsToken0`.
        if (swapBps != 0) {
            bool inIsLegA = zeroForOne == $.wethIsToken0;
            _remintSwap(zeroForOne, inIsLegA, (inIsLegA ? wethAmt : cbAmt) * uint256(swapBps) / 10000, minSwapOut);
            // The output landed in the balance and IS this op's inventory, so the same snapshot rule
            // re-derives both legs — this is how the swap feeds the mint.
            (cbAmt, wethAmt) = _collectedLegs(legBBefore);
        }

        _mintAndStake(cbAmt, wethAmt, tickLower, tickUpper, minLiquidity);

        // `width` IS rewritten — `setWidthBounds` / venue migration re-check the STORED width, and the span
        // was validated in-band. `skewBps` stays UNTOUCHED: explicit ticks carry no skew, and the stored
        // value remains inside its init-frozen band for later `checkRange` calls.
        $.width = uint24(uint256(int256(tickUpper - tickLower)));
        _assertHealthy(); // debt + collateral untouched ⇒ health preserved; belt only
    }

    /// @dev Sell `amountIn` of one LP leg into the other at `max(minOut, oracle cross rate − slippage)`.
    ///      The swap venue's tickSpacing is the LP POOL's — the legA/legB pair IS that pool — NOT
    ///      `_legSwapSpacing`, which serves the leg↔USDC pools. Prices come off the SHARED
    ///      `_readAllPrices` bundle, so this fails closed on a stale feed exactly as the debt/health/sweep
    ///      paths do. `amountIn == 0` is a clean no-op.
    function _remintSwap(bool zeroForOne, bool inIsLegA, uint256 amountIn, uint256 minOut) private {
        if (amountIn == 0) return;
        Layout storage $ = _layout();
        (uint256 pB, uint256 pA,) = _readAllPrices();
        (uint256 pIn, uint256 pOut) = inIsLegA ? (pA, pB) : (pB, pA);
        (uint8 decIn, uint8 decOut) = inIsLegA ? ($.wethDecimals, $.cbBTCDecimals) : ($.cbBTCDecimals, $.wethDecimals);
        uint256 floor =
            LeveragedAeroValuation.legSwapFloor(amountIn, decIn, pIn, decOut, pOut, uint256($.maxSlippageBps), minOut);
        (address tok0, address tok1) = _tokens01();
        (address tokenIn, address tokenOut) = zeroForOne ? (tok0, tok1) : (tok1, tok0);
        LeveragedAeroValuation.swapExactIn($.swapRouter, tokenIn, tokenOut, $.tickSpacing, amountIn, floor);
    }

    /// @dev The shared re-range prologue: calm-gate BEFORE touching the pool (never recenter, or swap, at a
    ///      manipulated tick) → snapshot leg B → unstake + remove 100% liquidity + collect (num==den ⇒ no
    ///      restake; a fresh range needs a fresh tokenId) → size. `legBBefore` is returned so
    ///      `remintRangeImpl` can re-derive the legs against the same snapshot after its swap.
    function _calmUnwindAll() private returns (uint256 legBBefore, uint256 cbAmt, uint256 wethAmt) {
        Layout storage $ = _layout();
        LeveragedAeroValuation.calmGate($.pool, $.twapWindow, $.calmDeviationTicks);
        // ASSET-MODE (F05): leg B IS the unit of account, so its raw balance is idle deposits and the
        // redeem-cover float — only the DELTA across the unwind is this op's own principal (as
        // `redeemUnwindImpl` does with `idleUsdcBefore`). Zero in the two-borrowed-legs shape.
        legBBefore = $.legBIsAsset ? IERC20($.cbBTC).balanceOf(address(this)) : 0;
        _unwindLiquidity(1, 1);
        (cbAmt, wethAmt) = _collectedLegs(legBBefore);
    }

    /// @dev What the unwind collected, in LEG order: leg B NET of the snapshot, and the FULL leg A balance —
    ///      a pre-existing idle leg A is a previous rerange's remainder, deliberately folded back in.
    function _collectedLegs(uint256 legBBefore) private view returns (uint256 cbAmt, uint256 wethAmt) {
        Layout storage $ = _layout();
        return (IERC20($.cbBTC).balanceOf(address(this)) - legBBefore, IERC20($.weth).balanceOf(address(this)));
    }

    /// @notice Retarget the position's LTV to `targetLtvBps_` (body of the strategy's `adjustLeverage`,
    ///         which passes the fund's STORED standing target, already validated by `setTargetLtv`).
    ///         Collateral is untouched, so LTV moves on the debt side: lever UP borrows the delta and adds
    ///         it (`minLiq`), lever DOWN unwinds the matching CL fraction and repays (residual rebalanced
    ///         through USDC, bounded by `minOut`). Ends with `_assertHealthy`. ASSET-MODE lever UP borrows
    ///         ONLY leg A and pairs it with the book's own USDC, so it CONSUMES collateral into the LP —
    ///         value-conserving, and the sizing corrects for it. SIZE THESE AWAY FROM RANGE EDGES: the USDC
    ///         demanded per unit of new debt is the live range ratio, which diverges near the leg-A-poor
    ///         edge, so the sizing can draw the whole excess collateral into a nearly one-sided LP for
    ///         vanishing new debt, invisibly to the LTV gates. The control is SEQUENCING: rerange first.
    /// @param minLiq        Minimum CL liquidity on a lever-UP add (slippage guard).
    /// @param minOut        Minimum USDC out of a lever-DOWN residual swap (slippage guard).
    function adjustLeverageImpl(uint16 targetLtvBps_, uint256 minLiq, uint256 minOut) public {
        // NO PERSIST HERE, or in the caller: `targetLtvBps_` IS the stored standing target, written only by
        // the admin-only `setTargetLtv` (the proposer moves the book toward policy, not policy). Nothing on
        // this path reads `$.targetLtvBps` again, which is what lets `_leverUp` take the target as a param.
        (uint256 collateralUsdc, uint256 debtUsdc) = _readCollateralDebt();
        uint256 targetDebt = (uint256(targetLtvBps_) * collateralUsdc) / 10000;
        if (targetDebt > debtUsdc) {
            _leverUp(targetDebt - debtUsdc, uint256(targetLtvBps_), minLiq);
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
        // ERR DELIBERATELY DISCARDED HERE — it is checked on the AFTER read below, which is strictly
        // stronger: `getAccountLiquidity` returns `(err, 0, 0)` on every error branch, so a failed read
        // leaves `shortfallBefore == 0` and the gate becomes "ANY residual shortfall reverts".
        (,, uint256 shortfallBefore) = IComptroller($.comptroller).getAccountLiquidity(address(this));

        // Target debt that lands health at minHealthBps + the re-trigger buffer (collateral is
        // untouched, so health = c / d ⇒ targetDebt = c × 1e4 / targetHealth).
        uint256 targetHealth = (minHealth * (10000 + uint256(DELEVERAGE_BUFFER_BPS))) / 10000;
        uint256 targetDebt = (collateralBefore * 10000) / targetHealth;
        if (debtBefore > targetDebt) {
            // CLAMP, don't inherit the full-unwind rejection: in the collateral≈0 tail `targetDebt` floors
            // to 0 and `_leverDown`'s orphaned-NFT guard would turn the PERMISSIONLESS valve off in the
            // state it exists for. Leaving one unit of debt keeps `num < den`; the recovery gate still binds.
            uint256 repayUsd = debtBefore - targetDebt;
            if (repayUsd >= debtBefore) repayUsd = debtBefore - 1;
            _leverDown(repayUsd, debtBefore, minOut);
        }

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

    /// @dev Lever UP by `borrowDeltaUsd` (USDC face, 6dp) and add the proceeds to the existing position —
    ///      `deployIdleImpl`'s borrow→wrap→add→restake without the supply step. THE ONE SHAPE BRANCH on the
    ///      leverage path: two borrowed legs takes the delta 50/50 by USD and LPs them against each other
    ///      (self-funding); asset-mode borrows a SINGLE leg and draws the LP's USDC side FROM THE BOOK'S OWN
    ///      IDLE USDC. Idle-funded, not swap-funded, is what preserves the delta — the LP then holds ΔB of
    ///      leg A while the debt grew by exactly ΔB, whereas swapping part of the borrow would leave an op
    ///      contracted to "move leverage only" net SHORT. `U′` is DERIVED, never passed: it pairs the
    ///      delta's leg-A borrow at the STORED range's (legA : USDC) ratio via `assetModeLeverUpPair`, which
    ///      shares its ratio probe with the genesis `assetModeSplit`. The binding funding constraint is
    ///      Moonwell's — `_materialiseUsdc`'s mid-op redeem fails on a cash-short market or a draw crossing
    ///      `(C − draw)·CF ≥ D`, nothing moved, never a partial fill.
    function _leverUp(uint256 borrowDeltaUsd, uint256 targetLtvBps_, uint256 minLiq) private {
        Layout storage $ = _layout();
        uint256 cbBTCAmt;
        uint256 wethAmt;
        if (!$.legBIsAsset) {
            (cbBTCAmt, wethAmt) = _borrowHalfEach(borrowDeltaUsd);
        } else {
            // Size the single leg-A borrow and the USDC pairing with it in the STORED range; leg B IS the
            // unit of account, so that USDC enters as the leg-B amount. `assetModeLeverUpPair` enforces the
            // funding bound BEFORE the borrow against `_usdcAvailable()`, and `raw`/`targetLtvBps` let it
            // solve the FIXED POINT `Δ = (borrowDeltaUsd + ltv·raw) / (1 + ltv·m)` — redeeming part of `U′`
            // shrinks the LTV base, so the naive delta lands ABOVE target. ORDER: size → materialise → borrow.
            uint256 raw = IERC20($.usdc).balanceOf(address(this));
            (wethAmt, cbBTCAmt) = LeveragedAeroValuation.assetModeLeverUpPair(
                $.pool,
                $.posTickLower,
                $.posTickUpper,
                borrowDeltaUsd,
                _usdcAvailable(),
                raw,
                targetLtvBps_,
                $.wethDecimals,
                $.wethIsToken0,
                _readUsd8($.wethFeed)
            );
            _materialiseUsdc(cbBTCAmt);
            _borrowLegA(wethAmt);
        }
        _wrapAddRestake(cbBTCAmt, wethAmt, minLiq);
    }

    /// @dev Lever DOWN by `repayUsd` (USDC face, 6dp) of the current `debtUsd`: unwind the matching
    ///      fraction `f = repayUsd/debtUsd` of CL liquidity, repay `f` of each debt from the
    ///      collected legs (oracle-free direct repay), then cover any per-leg IL residual by selling
    ///      the over-collected sibling leg → USDC (caller `minOut` bounds it) and buying the deficit.
    ///      Balanced legs (the common case) leave no residual → no swap → `minOut` unused.
    function _leverDown(uint256 repayUsd, uint256 debtUsd, uint256 minOut) private {
        Layout storage $ = _layout();
        // FULL-UNWIND GUARD (load-bearing, do not relax to a clamp). `repayUsd == debtUsd` takes
        // `_unwindLiquidity`'s `num == den` branch, which removes 100% of the liquidity and SKIPS the
        // re-stake; `_leverDown` disposes of nothing, so `$.tokenId` would point at an NFT the gauge no
        // longer holds and every later venue op would brick on `ICLGauge.withdraw`, `emergencyRedeem`
        // included. A genuine full unwind is `flatten()`.
        if (repayUsd >= debtUsd) revert FullUnwindNotSupported();
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

    /// @dev Cover an IL-driven debt shortfall on `deficitTok` by selling ONLY AS MUCH of the over-collected
    ///      `surplusTok` as the cover needs → USDC, then buying exactly the deficit and repaying it.
    ///      Leftover USDC stays idle (NAV-counted). NEED-SIZED, NOT WHOLESALE — the surplus BALANCE can also
    ///      hold a pre-existing idle remainder still matched 1:1 by that leg's Moonwell debt, hence
    ///      delta-neutral where it sits; selling it would create an unrecorded SHORT that neither the drift
    ///      measure nor `_repay`'s clamp would surface. `needed` grosses both oracle conversions up by
    ///      `maxSlippageBps` so a fill on the sell floor still clears the ceiling-priced buy, and the sell's
    ///      min-out is `max(callerMinUsdcOut, oracleValue(amount ACTUALLY sold) × (1 − maxSlippageBps))` —
    ///      priced off the sold amount, or it would be unreachable whenever `keep > 0`.
    function _rebalanceCover(
        address surplusTok,
        address deficitTok,
        address deficitMkt,
        uint256 shortAmt,
        uint256 minUsdcOut
    ) private {
        Layout storage $ = _layout();
        bool deficitIsCb = deficitTok == $.cbBTC;
        bool surplusIsCb = surplusTok == $.cbBTC;
        // ASSET-MODE: when the surplus leg IS the unit of account there is nothing to sell, so pricing it
        // would be dead arithmetic; a zero balance short-circuits `coverBounds` to the deficit buy alone.
        uint256 surplusBal = surplusTok == $.usdc ? 0 : IERC20(surplusTok).balanceOf(address(this));
        // Need-sized sell amount, its floor and the buy ceiling all derive in `coverBounds`.
        (uint256 buyMax, uint256 sellAmt, uint256 sellFloor) = LeveragedAeroValuation.coverBounds(
            shortAmt,
            deficitIsCb ? $.cbBTCDecimals : $.wethDecimals,
            _readUsd8(deficitIsCb ? $.cbBTCFeed : $.wethFeed),
            surplusBal,
            surplusIsCb ? $.cbBTCDecimals : $.wethDecimals,
            surplusBal == 0 ? 0 : _readUsd8(surplusIsCb ? $.cbBTCFeed : $.wethFeed),
            _readUsd8($.usdcFeed),
            uint256($.maxSlippageBps)
        );
        if (sellFloor > minUsdcOut) minUsdcOut = sellFloor;
        _sweepLegToUsdc(surplusTok, surplusBal - sellAmt, minUsdcOut);
        _redeemCoverShortfall(deficitTok, deficitMkt, shortAmt, buyMax, false);
    }

    /// @dev Collateral + debt in USDC face (6dp) on the SAME hardened-Chainlink basis as `_assertHealthy` —
    ///      sizes the adjustLeverage / deleverage targets. Returns `debtUsdc == 0`, skipping the price
    ///      reads, when both borrows are clear. STORED-INDEX STALENESS IS A KNOWN, DELIBERATELY UNCHANGED
    ///      RESIDUAL — do not "fix" it by analogy with `LeveragedAeroValuation._measureLeg`: these reads
    ///      feed a RATIO whose both sides are stale on the same basis, this function is `view` and reached
    ///      under STATICCALL so it structurally cannot accrue, and the belt is Moonwell's
    ///      `getAccountLiquidity` on the same stored basis its liquidation check uses. Understated debt ⇒
    ///      marginally loose LTV gates and a late `deleverage`, over one inter-accrual window.
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
    ///
    ///      ALSO THE ONE PLACE THE HEDGED-PRINCIPAL BASIS IS CLAMPED DOWN (7 repay sites, one rule).
    ///      `Layout.hedgedDebtA/B` is the borrowed principal the LP side hedges; the unhedged accrued
    ///      interest that `compound` neutralises is `borrowBalanceStored − hedged`, so the basis must
    ///      NEVER exceed the live debt or that subtraction underflows. Clamping DOWN to the post-repay
    ///      debt is exact in both directions, which is why this is a `min` and not a `-=`:
    ///        - repay ≤ accrued interest (the `compound` drift repay): post-repay debt still ≥ hedged,
    ///          the clamp is a NO-OP, and the un-repaid remainder correctly stays measured as drift.
    ///        - repay > accrued interest (lever-down, settle, IL cover): the excess is principal coming
    ///          off, and the clamp reduces the basis by exactly that excess, leaving drift at 0.
    ///      A `-=` by the repaid amount would instead cancel the drift repay against its own basis and
    ///      leave the gap permanently open. The PRO-RATA case (partial redeem) needs the basis scaled by
    ///      `(1−f)` rather than re-anchored, so `redeemUnwindImpl` scales it before its repays land here.
    function _repay(address market, uint256 amt) private {
        uint256 err = IMoonwellMarket(market).repayBorrow(amt);
        if (err != 0) revert MoonwellRepayFailed(err);
        Layout storage $ = _layout();
        uint256 debtAfter = IMoonwellMarket(market).borrowBalanceStored(address(this));
        if (market == $.mWeth) {
            if (uint256($.hedgedDebtA) > debtAfter) $.hedgedDebtA = uint128(debtAfter);
        } else if (uint256($.hedgedDebtB) > debtAfter) {
            // Leg B. Reached with `market == $.mCbBTC` at every call site; and in ASSET-MODE, where init
            // pins `mCbBTC == mUsdc`, `hedgedDebtB` is structurally 0, so the guard above is already
            // false and no write can land on the collateral market's behalf.
            $.hedgedDebtB = uint128(debtAfter);
        }
    }

    /// @dev `mUsdc.redeemUnderlying(amt)` with the uniform error-check.
    function _redeemUnderlying(address cToken, uint256 amt) private {
        uint256 err = ICToken(cToken).redeemUnderlying(amt);
        if (err != 0) revert MoonwellRedeemFailed(err);
    }

    /// @dev `cToken.redeem(tokens)` — cTOKEN-denominated, the burn-it-all form — with the uniform
    ///      error-check. Used by the two "leave no dust" sites.
    function _redeemCTokens(address cToken, uint256 tokens) private {
        uint256 err = ICToken(cToken).redeem(tokens);
        if (err != 0) revert MoonwellRedeemFailed(err);
    }

    /// @dev USDC the book can spend without touching the LP — raw balance + redeemable mUSDC collateral.
    ///      THE FUNDING BASIS every "do I have enough idle?" bound now uses.
    function _usdcAvailable() private view returns (uint256) {
        Layout storage $ = _layout();
        return LeveragedAeroValuation.usdcAvailable($.usdc, $.mUsdc, address(this));
    }

    /// @dev MATERIALISE `amt` of RAW USDC on demand by redeeming only the SHORTFALL from mUSDC. The
    ///      shortfall form is the point: a blanket redeem would make every `deployIdle` a redeem→mint round
    ///      trip, and Compound's truncating `mintTokens = amt/rate` burns ~1 unit of USDC per call for
    ///      nothing. Fails closed through `_redeemUnderlying`.
    function _materialiseUsdc(uint256 amt) private {
        Layout storage $ = _layout();
        uint256 raw = IERC20($.usdc).balanceOf(address(this));
        if (amt > raw) _redeemUnderlying($.mUsdc, amt - raw);
    }

    // ── Execute helpers ──

    /// @dev THE ONE SHAPE BRANCH on the deploy path. Supply the collateral portion of `amount` and
    ///      borrow the matching leg amounts, sized for whichever shape the config implies:
    ///
    ///      - TWO BORROWED LEGS (`legBIsAsset == false`): the WHOLE `amount` is collateral and the
    ///        borrow is `amount × targetLtv` split 50/50 by USD across both legs. `tickLower`/
    ///        `tickUpper` are UNUSED — that pair is balanced by value, not against a range.
    ///      - ASSET AS A LEG (`legBIsAsset == true`): `LeveragedAeroValuation.assetModeSplit` solves
    ///        the collateral portion `C` closed-form so the SINGLE leg-A borrow against `C` pairs with
    ///        `U = amount − C` at exactly the ratio `[tickLower, tickUpper]` needs at the current tick.
    ///        Only `C` is supplied to Moonwell; `U` stays as idle USDC and is handed to the mint/add as
    ///        the leg-B amount (`$.cbBTC == $.usdc`, so `_amounts01` / `_mintPosition` route it with no
    ///        further special-casing). A one-sided range fails closed there.
    ///
    /// @param amount    USDC (6dp) to deploy. Must already be held by the strategy.
    /// @return cbBTCAmt Leg-B amount for the mint/add: the borrowed leg B, or (asset-mode) `U` USDC.
    /// @return wethAmt  Leg-A amount borrowed.
    function _supplyAndBorrow(uint256 amount, int24 tickLower, int24 tickUpper)
        private
        returns (uint256 cbBTCAmt, uint256 wethAmt)
    {
        Layout storage $ = _layout();
        uint256 ltv = uint256($.targetLtvBps);
        if (!$.legBIsAsset) {
            _supplyAmount(amount);
            return _borrowHalfEach((amount * ltv) / 10000);
        }
        uint256 collateral;
        (collateral, cbBTCAmt, wethAmt) = LeveragedAeroValuation.assetModeSplit(
            $.pool, tickLower, tickUpper, amount, ltv, $.wethDecimals, $.wethIsToken0, _readUsd8($.wethFeed)
        );
        _supplyAmount(collateral);
        _borrowLegA(wethAmt);
    }

    /// @dev The SINGLE leg-A borrow of the asset-mode shape, with the uniform Moonwell error-check.
    ///      Shared by the two sites that make it — `_supplyAndBorrow` (fresh collateral at target) and
    ///      `_leverUp` (a debt delta against unchanged collateral) — so the venue call and its error
    ///      handling have one definition (the two copies were also a bytecode cost at the EIP-170 margin).
    function _borrowLegA(uint256 amt) private {
        uint256 err = IMoonwellMarket(_layout().mWeth).borrow(amt);
        if (err != 0) revert MoonwellBorrowFailed(err);
        // Every borrowed unit goes straight into the LP side (the caller adds it in the same tx), so the
        // hedged principal grows by exactly `amt` — see `_repay` for the rest of the basis discipline.
        _layout().hedgedDebtA += SafeCast.toUint128(amt);
    }

    /// @dev Borrow `borrowUsd6` of debt (USDC face, 6dp) split 50/50 by USD across cbBTC + WETH, at
    ///      hardened-Chainlink prices, and execute both borrows. TWO-BORROWED-LEGS SHAPE ONLY — used by
    ///      `_supplyAndBorrow` (fresh collateral at target) and by `_leverUp` (a target-LTV debt delta
    ///      with no new collateral), both of which gate on `!legBIsAsset` first.
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
        // TWO-LEG DRIFT IS THE SAME DRIFT. Both legs are borrowed and both are LP'd against each other,
        // so both accrue interest the LP never grows to match — this shape drifts on BOTH legs, and both
        // bases are tracked so `compound` can neutralise both. (See `_borrowLegA` for the single-leg
        // shape and `LeveragedAeroValuation.hedgeBorrowInterest` for the measure.)
        $.hedgedDebtB += SafeCast.toUint128(cbBTCAmt);
        $.hedgedDebtA += SafeCast.toUint128(wethAmt);
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
        returns (uint256 tokenId_, uint128 liq, uint256 used0, uint256 used1)
    {
        Layout storage $ = _layout();
        address npm_ = $.npm;
        (address tok0, address tok1) = _tokens01();

        // Expected actual deposits at the calm-gated sqrtP, haircut by maxSlippageBps (the §8
        // always-on floor — single definition in `LeveragedAeroValuation.depositMins`).
        (uint160 sqrtP,,,,,) = ICLPool($.pool).slot0();
        (uint256 amt0Min, uint256 amt1Min) =
            LeveragedAeroValuation.depositMins(sqrtP, tickLower, tickUpper, amt0, amt1, uint256($.maxSlippageBps));

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
        (tokenId_, liq, used0, used1) = INonfungiblePositionManager(npm_).mint(mp);
        if (tokenId_ == 0) revert NpmMintFailed();
    }

    /// @dev Mint the CL position, stake in gauge, and persist state. The range is supplied by the caller
    ///      (`executeImpl`), which calm-gates and derives it once — so the asset-mode sizing and this
    ///      mint provably target the SAME range rather than re-deriving it.
    function _mintAndStake(uint256 cbBTCAmt, uint256 wethAmt, int24 tickLower, int24 tickUpper, uint256 minLiquidity)
        private
    {
        Layout storage $ = _layout();
        (uint256 amt0, uint256 amt1) = _amounts01(cbBTCAmt, wethAmt);
        (uint256 tokenId_, uint128 liq,,) = _mintPosition(amt0, amt1, tickLower, tickUpper);
        // Caller's floor on the minted liquidity, mirroring `_addLiquidity`'s guard on the add path.
        if (uint256(liq) < minLiquidity) revert InsufficientLiquidity();
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
        // ACCRUE, *THEN* MEASURE. These reads decide full-vs-partial repay, and the repay they gate pulls
        // the ACCRUED debt while the approval above is sized off the token BALANCE — so with the stored
        // index a book covering the stale but not the accrued debt takes the `type(uint256).max` branch and
        // Moonwell pulls more than was approved, reverting the whole unwind.
        uint256 cbDebt = IMoonwellMarket(mCbBTC_).borrowBalanceCurrent(address(this));
        uint256 wethDebt = IMoonwellMarket(mWeth_).borrowBalanceCurrent(address(this));
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

    /// @dev If any borrow balance remains after the direct repay attempt, fund the residue out of mUSDC
    ///      collateral and BUY EXACTLY THE DEBT to clear it. Chainlink-priced budget; dust floor.
    ///      EXACT-OUTPUT, with `maxSlippageBps` as both budget and bound: the old form's two INDEPENDENT
    ///      bounds let a router keep the whole gap out of the collateral backing every other holder.
    ///      FAIL-CLOSED at both sites, since Moonwell releases no collateral while ANY debt is live. The
    ///      accruing reads are belt, not the fix: both reachable callers already accrued both markets this
    ///      tx (`_settleRepayDebts`, and Phase 2 via `_redeemRepayFromCollected`), so F23 is what closed
    ///      F12. Kept so a future caller that has not accrued cannot under-buy off a stale-low `debtRem`.
    function _settleShortfall() private {
        Layout storage $ = _layout();
        uint256 cbDebtRem = IMoonwellMarket($.mCbBTC).borrowBalanceCurrent(address(this));
        uint256 wethDebtRem = IMoonwellMarket($.mWeth).borrowBalanceCurrent(address(this));
        if (cbDebtRem == 0 && wethDebtRem == 0) return;
        // Chainlink prices (8dp) — reached ONLY on a book that still owes after the direct repays, i.e.
        // genuine deep IL; the phases above exist to keep this unreached (see `redeemUnwindImpl` Phase 2).
        (uint256 pBTC, uint256 pETH, uint256 pUsdc) = _readAllPrices();
        uint256 slip = uint256($.maxSlippageBps);
        // Per-leg USDC budget: the oracle cost grossed up by the CONFIGURED slippage — the same number the
        // exact-output swap takes as `amountInMax`, which is what collapses the two old bounds into one.
        uint256 cbUsdcNeed = _tokenToUsdc(cbDebtRem, $.cbBTCDecimals, pBTC, pUsdc) * (10000 + slip) / 10000;
        uint256 wethUsdcNeed = _tokenToUsdc(wethDebtRem, $.wethDecimals, pETH, pUsdc) * (10000 + slip) / 10000;
        // Dust floor: nonzero debt but oracle cost rounds to 0 (e.g. 1 wei WETH) → fund at least 1 unit.
        if (cbDebtRem > 0 && cbUsdcNeed == 0) cbUsdcNeed = 1e5;
        if (wethDebtRem > 0 && wethUsdcNeed == 0) wethUsdcNeed = 1e5;
        // Fund the buys out of collateral, but only the part the raw balance does not already cover.
        _materialiseUsdc(cbUsdcNeed + wethUsdcNeed);
        // Cover each leg by buying EXACTLY the remaining debt, capped at its own oracle budget, and repay.
        // Asset-mode is a structural no-op on the leg-B line (leg B is the unit of account, carries no debt).
        if (cbDebtRem > 0) _redeemCoverShortfall($.cbBTC, $.mCbBTC, cbDebtRem, cbUsdcNeed, false);
        if (wethDebtRem > 0) _redeemCoverShortfall($.weth, $.mWeth, wethDebtRem, wethUsdcNeed, false);
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

    /// @dev Sweep the WHOLE `tokenIn` balance → USDC at a Chainlink-derived floor
    ///      (`oracle value × (1 − maxSlippageBps)`). One definition for both settle legs.
    function _sweepAtOracleFloor(address tokenIn, uint8 dec, uint256 price, uint256 pUsdc) private {
        uint256 floor = _tokenToUsdc(IERC20(tokenIn).balanceOf(address(this)), dec, price, pUsdc)
            * (10000 - uint256(_layout().maxSlippageBps)) / 10000;
        _sweepLegToUsdc(tokenIn, 0, floor);
    }

    /// @dev Sweep (balance − `keep`) of `tokenIn` → USDC via exactInputSingle. `keep` reserves a
    ///      stayers' idle-leg share on the redeem path; settle / full-sweep callers pass keep == 0.
    ///      ASSET-MODE IDENTITY: when `tokenIn` IS the unit of account the "sweep" is a no-op by
    ///      definition — the balance is already USDC. Returning here (rather than branching at the four
    ///      call sites) is what keeps every leg-B sweep off the router: no `_legSwapSpacing` lookup for
    ///      a USDC/USDC pool that does not exist, and no `keep` reservation double-counting the idle
    ///      USDC that `redeemUnwindImpl` already reserves as `stayersIdle`.
    function _sweepLegToUsdc(address tokenIn, uint256 keep, uint256 minOut) private {
        Layout storage $ = _layout();
        if (tokenIn == $.usdc) return;
        uint256 bal = IERC20(tokenIn).balanceOf(address(this));
        if (bal <= keep) return;
        uint256 amt = bal - keep;
        LeveragedAeroValuation.swapExactIn($.swapRouter, tokenIn, $.usdc, _legSwapSpacing(tokenIn), amt, minOut);
    }

    /// @dev The amount `_sweepLegToUsdc(tokenIn, keep, …)` would ACTUALLY sell — the same two gates in the
    ///      same order, as ONE expression, so the redeem-sweep oracle floor cannot drift from the swap.
    function _sellable(address tokenIn, uint256 keep) private view returns (uint256) {
        if (tokenIn == _layout().usdc) return 0;
        uint256 bal = IERC20(tokenIn).balanceOf(address(this));
        return bal > keep ? bal - keep : 0;
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

    /// @dev Hardened USD read that also asserts the feed is 8-decimal (the scaling assumption). Now a
    ///      thin forward to `LeveragedAeroValuation.readUsd8` — the SAME definition `netEquityUsdc`
    ///      prices with, so the execution basis and the NAV basis are one function rather than two
    ///      copies that agreed only by inspection. Relocated for EIP-170 headroom: `ChainlinkReader` is
    ///      an `internal` library, so keeping the call here inlined its whole staleness ladder into this
    ///      library, which is at the cap. Same fail-closed behaviour, one DELEGATECALL per read.
    function _readUsd8(address feed) private view returns (uint256 price) {
        Layout storage $ = _layout();
        return LeveragedAeroValuation.readUsd8(feed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
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
        LeveragedAeroValuation.calmGate($.pool, $.twapWindow, $.calmDeviationTicks);
        uint256 tokenId_ = $.tokenId;
        address npm_ = $.npm;
        (uint160 sqrtP,,,,,) = ICLPool($.pool).slot0();
        // Same §8 always-on two-sided floor as `_mintPosition`, from the one shared definition.
        (uint256 amt0Min, uint256 amt1Min) = LeveragedAeroValuation.depositMins(
            sqrtP, $.posTickLower, $.posTickUpper, amt0, amt1, uint256($.maxSlippageBps)
        );
        (address tok0, address tok1) = _tokens01();
        IERC20(tok0).forceApprove(npm_, amt0);
        IERC20(tok1).forceApprove(npm_, amt1);
        (uint128 liq,,) = INonfungiblePositionManager(npm_).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId_,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: amt0Min,
                amount1Min: amt1Min,
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

        // ACCRUE, *THEN* MEASURE — here that is what keeps the DEADMAN ORACLE-FREE. `repayBorrow` accrues
        // before applying the payment, so a repay sized off the STORED index leaves `current − stored` of
        // interest behind — on a full redeem the only thing keeping `_settleShortfall` off its zero-debt
        // early return, so every full redeem read Chainlink, `emergencyRedeem` included.
        uint256 cbDebtRepay = Math.mulDiv(IMoonwellMarket(mCbBTC_).borrowBalanceCurrent(address(this)), shares, supply);
        uint256 wethDebtRepay = Math.mulDiv(IMoonwellMarket(mWeth_).borrowBalanceCurrent(address(this)), shares, supply);

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

    /// @dev Cover a debt shortfall (IL-driven) by swapping idle USDC → `tokenOut` via exactOutputSingle,
    ///      then repaying the exact remaining amount. `amountInMax` caps the USDC spent: full redeem passes
    ///      `type(uint256).max` (oracle-free, bounded by idle USDC), the partial path the redeemer's own
    ///      budget (`balance − stayersIdle`) so a cover dipping into stayer idle reverts, and permissionless
    ///      deleverage an oracle+slippage ceiling so a sandwiched buy reverts (H1). ASSET-MODE IDENTITY:
    ///      return before the router AND the repay, so `mUsdc.repayBorrow` is unreachable.
    function _redeemCoverShortfall(
        address tokenOut,
        address market,
        uint256 amountOut,
        uint256 amountInMax,
        bool bestEffort
    ) private {
        Layout storage $ = _layout();
        if (tokenOut == $.usdc) return;
        uint256 usdcBal = IERC20($.usdc).balanceOf(address(this));
        if (usdcBal == 0 || amountOut == 0) return;
        uint256 maxIn = usdcBal < amountInMax ? usdcBal : amountInMax;
        bool filled = LeveragedAeroValuation.swapExactOut(
            $.swapRouter, $.usdc, tokenOut, _legSwapSpacing(tokenOut), amountOut, maxIn, bestEffort
        );
        // An unfilled BEST-EFFORT cover moved nothing (the swap reverted in its own frame and rolled back),
        // so there is nothing bought to repay — fall through and leave `amountOut` for the next phase.
        if (!filled) return;
        uint256 tokenBal = IERC20(tokenOut).balanceOf(address(this));
        if (tokenBal > 0) {
            IERC20(tokenOut).forceApprove(market, tokenBal);
            _repay(market, tokenBal >= amountOut ? amountOut : tokenBal);
        }
    }

    /// @dev Redeem f = shares/supply of the mUSDC collateral BY BURNING f OF THE cTOKEN BALANCE, in both
    ///      branches. Sizing the underlying off `exchangeRateStored` instead disagrees with
    ///      `redeemUnderlying`'s fresh-rate burn by the rate gap — at `f == 1` cTokens left on a zero-share
    ///      fund for the next depositor, at `f < 1` the redeemer's slice of accrued supply interest. This
    ///      unwind stamps no price, so the fair share is `f` of the cTOKENS (unlike `fastRedeemImpl`).
    function _redeemCollateral(uint256 shares, uint256 supply) private {
        address mUsdc_ = _layout().mUsdc;
        uint256 cBal = ICToken(mUsdc_).balanceOf(address(this));
        if (cBal == 0) return;
        uint256 toBurn = shares == supply ? cBal : Math.mulDiv(cBal, shares, supply);
        if (toBurn == 0) return;
        _redeemCTokens(mUsdc_, toBurn);
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
        // Collateral + debt (6dp), ONE definition shared with `readCollateralDebtImpl` / `deleverageImpl` /
        // `fastRedeemImpl` — this used to be a verbatim second copy. The oracle-skip is preserved:
        // `_readCollateralDebt` reads no feed when both borrows are zero, so one guard covers both cases.
        (uint256 collateralUsd, uint256 debtUsd) = _readCollateralDebt();
        if (debtUsd == 0) return; // no debt (oracle untouched) or dust rounding to 0 → trivially healthy

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

    // NOTE: the manager holds NO `LeveragedAeroValuation.Config` builder. It never prices, and its four
    // gate sites call the lean `LeveragedAeroValuation.calmGate(pool, twapWindow, calmDeviationTicks)`
    // directly. The partial-`Config` builder this replaced was both a bytecode cost at the EIP-170
    // margin and a standing footgun (a mostly-zero `Config` must never reach a pricing function). The
    // strategy keeps the FULL `_config()` builder, which is the one valuation genuinely consumes.
}
