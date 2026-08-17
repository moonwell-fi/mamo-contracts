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

/// @dev The strategy selectors this library calls back into, declared here rather than imported so the
///      manager keeps no dependency on `LeveragedAerodromeCLStrategy` (which imports THIS file).
///      `redeemUnwindImpl` runs under DELEGATECALL, so its own reads/reverts are INTERNAL and a Solidity
///      `try` cannot catch them; routing through a call on `address(this)` gives them a catchable frame —
///      the same idiom the strategy's own `_proportionalRedeem` uses for `try this.nav()`.
interface IRedeemSweepFloors {
    function redeemSweepFloors(uint256 cbAmt, uint256 wethAmt) external view returns (uint256, uint256);
}

/// @dev See `IRedeemSweepFloors` for why this is a local interface and not an import.
///      `sellRedeemRewardSelf` is the strategy's `OnlySelf`-gated redeem-side reward sale: it sells the
///      tranche this redeem's own `gauge.withdraw` auto-claimed (best-effort — it holds the `try/catch`
///      itself) and returns the STAYERS' `(1−f)` share of the proceeds, which `redeemUnwindImpl` adds to
///      its `stayersIdle` reservation. Body and rationale live on the strategy: the manager is at the
///      EIP-170 cap, the same relocation `_settle`'s hedged-basis zeroing already makes.
interface IRewardSaleSelf {
    function sellRedeemRewardSelf(uint256 shares, uint256 supply) external returns (uint256 stayersShare);
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
///
///         ── TWO POOL SHAPES, ONE IMPLEMENTATION (no mode flag — the shape is EMERGENT FROM CONFIG) ──
///
///         `Layout.legBIsAsset` is DERIVED at init as `cbBTC == usdc` (see the strategy's
///         `_initialize`); the deployer passes no mode. It selects between:
///
///         1. TWO BORROWED LEGS (`legBIsAsset == false`, the original shape): supply the whole USDC
///            deposit as collateral → borrow BOTH legs 50/50 by USD at `targetLtvBps` → LP them
///            against each other → stake. Net-short both legs.
///         2. ASSET AS A LEG (`legBIsAsset == true`, e.g. a cbBTC/USDC pool): supply only part of the
///            deposit as collateral → borrow ONLY leg A → LP it against the REMAINING USDC → stake.
///            Delta-hedged by the single borrow. `_supplyAndBorrow` derives the collateral/LP split
///            closed-form via `LeveragedAeroValuation.assetModeSplit`.
///
///         SLOT ASYMMETRY IS DELIBERATE AND ENFORCED: only the LEG-B slot (`cbBTC*`) may be the unit
///         of account. Leg A (`weth*`) must always be a real volatile borrowed leg because it carries
///         the `wethDeliversNative` wrap path (`_wrapNativeEth`) and, in asset-mode, is the ONLY
///         borrow. `_initialize` rejects `weth == usdc` unconditionally.
///
///         ASSET-MODE INVARIANTS the venue paths rely on (all established at init):
///         - Leg B carries NO debt: nothing here ever calls `borrow()` on `mUsdc`, and init pins
///           `mCbBTC == mUsdc`, so every `borrowBalanceStored($.mCbBTC)` read is structurally 0. The
///           debt / health / repay / shortfall paths therefore need NO branch — they naturally see a
///           single-leg book.
///         - Every "swap leg B ↔ USDC" is the IDENTITY: `_sweepLegToUsdc` and
///           `_redeemCoverShortfall` early-return on the unit of account, so no zero-address swap-pool
///           lookup, no pointless router call, and no double-counted balance.
///         - `$.cbBTCFeed == $.usdcFeed` (init-enforced), so `_tokenToUsdc(x, 6, pUsdc, pUsdc) == x`:
///           leg B prices at FACE everywhere, with no special case in the arithmetic.
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
    // A lever-down would repay the ENTIRE debt, which removes 100% of the liquidity and orphans the
    // staked position NFT (see the guard in `_leverDown`). Route full unwinds through `flatten()`.
    error FullUnwindNotSupported();
    // NOTE: `InsufficientIdleForLeverUp` (asset-mode lever-up, see `_leverUp`) is NOT declared here — it
    // is raised by `LeveragedAeroValuation.assetModeLeverUpPair`, alongside the arithmetic that sizes the
    // draw, exactly as `DegenerateRange` is. Same convention: valuation-raised errors are not mirrored.

    // ── Events (emitted from the STRATEGY's address via delegatecall; mirrored in its ABI) ──
    /// @notice `redeemUnwindImpl`'s closing leg sweeps ran with their Chainlink min-out floors at ZERO
    ///         because the floor derivation reverted. Deliberately fail-open — `emergencyRedeem` is the
    ///         deadman and must complete with the oracle down — but the `catch` cannot tell a stale feed
    ///         / down sequencer from an out-of-gas, so the degradation is marked here instead of being
    ///         silent. A monitor seeing this knows the redeem's swaps were UNBOUNDED for that call.
    ///
    ///         NAMING, shared by the three fail-opens this stack added: `…Degraded` means a GUARD fell
    ///         back (the op ran, with less protection); `…Deferred` means an optional ACTION was skipped
    ///         (`SettleRewardSaleDeferred`, `RedeemRewardSaleDeferred`, both on the strategy).
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
    ///         collateral → borrow → wrap → mint CL → stake gauge. Works in BOTH shapes; the split
    ///         between collateral and LP-side USDC is `_supplyAndBorrow`'s job (see the library head).
    /// @dev The calm-gate is hoisted HERE (it used to sit inside `_mintAndStake`) so the fresh range is
    ///      derived ONCE, off an already-validated tick, and then threaded through both the asset-mode
    ///      sizing and the mint. A shoved tick therefore reverts before any FUND-MOVING venue call —
    ///      before the supply, the borrow and the mint. The `enterMarkets` above it is the one venue
    ///      call that precedes the gate: it is idempotent market-entry bookkeeping that moves no value
    ///      and reads no tick, so gating it would buy nothing. (Do not restate this as "before any
    ///      venue call" — that was the previous wording and it was literally false.)
    ///
    ///      GATE ORDERING IS NOT UNIFORM ACROSS THE IMPLS, BY DESIGN. `rerangeImpl` gates FIRST, before
    ///      any venue call at all. `executeImpl` gates after `enterMarkets`, as above. `deployIdleImpl`
    ///      and `_leverUp` do NOT gate up front — they reach the gate inside `_addLiquidity`, i.e. after
    ///      the Moonwell supply/borrow has already executed. That is safe and deliberate: the gate is
    ///      still strictly BEFORE the pool is touched, a breach reverts the whole transaction atomically
    ///      (there is no partial-failure state in the EVM), and every one of those paths reaches
    ///      `_addLiquidity` unconditionally, so none of them can skip the gate. Hoisting a second
    ///      `calmGate` into `deployIdleImpl` would add a duplicate gate on the hot path and bytecode to a
    ///      library already at the EIP-170 margin, for no behavioural change. Asset-mode is the case that
    ///      LOOKS worst — `assetModeSplit` reads the live `sqrtP` for its sizing before any gate — but
    ///      the mint that consumes that sizing is gated, so a shoved tick still unwinds the whole op.
    ///
    ///      THE PATHS THAT REACH NO CALM GATE AT ALL — `_leverDown` (`adjustLeverage` down and the
    ///      permissionless `deleverage`), `settleImpl` and `redeemUnwindImpl` — are omitted from the list
    ///      above because they never mint. That is deliberate, not an oversight, and it is safe for three
    ///      independent reasons. (1) CONCAVITY: they BURN liquidity. A CL bundle removed at a shoved
    ///      price is worth strictly MORE at the true price than one removed at it, so shoving the pool
    ///      hands the protocol the better side of the trade — a gate would only let an attacker DENY an
    ///      exit, which is the wrong failure mode for a redeem valve. (2) THE UNWIND MINS CANNOT BIND:
    ///      they are derived from the SAME `slot0` the `decreaseLiquidity` executes at (see
    ///      `_unwindLiquidity`), so the comparison is a strict identity — gating would change nothing
    ///      about what those mins admit. (3) THE ENTRY HEALTH GATE IS ORACLE-PRICED: `_assertHealthy` and
    ///      `_readCollateralDebt` read Chainlink-priced Moonwell state, which a pool shove cannot move,
    ///      so `deleverage`'s "am I unhealthy" trigger is not shove-able either. The residual swaps on
    ///      those paths are bounded instead by oracle floors/ceilings (`_rebalanceCover`) or by the
    ///      redeemer's own budget — a slippage bound, not a tick bound.
    /// @param minLiquidity Caller's floor on the CL liquidity the genesis mint must produce, on top of
    ///                     the §8 two-sided `maxSlippageBps` mins the mint already enforces. Activation
    ///                     (`execute`) passes 0 — it runs ONCE, owner-driven, on a book that holds only
    ///                     the seed, and there is no prior state for a bad fill to dilute. `redeploy`
    ///                     passes the proposer's own value: it re-enters the WHOLE book, repeatedly,
    ///                     against live depositors, and the in-mint mins are derived from the same
    ///                     `slot0()` the mint executes at — self-referential, exactly the criticism
    ///                     `flattenImpl` levels at `settleImpl`'s unwind mins.
    function executeImpl(uint256 minLiquidity) public {
        Layout storage $ = _layout();
        // THE WHOLE FLAT-BOOK POT, raw or supplied. Activation reaches here holding the seed as a raw
        // balance; `redeploy` reaches here on a flat book the keeper may have swept into mUSDC with
        // `supplyIdle` — reading the raw balance alone would see 0 there and revert `ExecuteZeroBalance`
        // on a fund that is fully funded. Materialise the shortfall so `_supplyAndBorrow` gets the
        // raw USDC it splits (activation redeems nothing; a redeploy pays one round trip, on an op
        // that re-enters the entire book and runs at most once per flatten cycle). The full-pot
        // materialise leans on the `tokenId == 0 ⇒ debt == 0` invariant (a redeem-all against live
        // debt would fail Moonwell's collateral check): every writer of `tokenId = 0` — `settleImpl`,
        // `redeemUnwindImpl`'s full branch — clears both borrows first and proves it by redeeming the
        // collateral in the same breath, and `deleverageImpl` refuses full unwinds outright.
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
    /// @dev Sweeps the two LEG tokens ONLY. The `gauge.withdraw` inside `_unwindLiquidity` auto-claims
    ///      a final reward tranche, and selling THAT is the caller's job — deliberately, because the
    ///      two callers need opposite failure modes on the same sale: `LeveragedAeroVenue.flattenImpl`
    ///      sells it fail-closed under the proposer's floor (it is resumable), while the strategy's
    ///      terminal `_settle` sells it best-effort through a self-`try/catch` (it must not be
    ///      blockable). Doing it here would collapse the two and silently drop `flatten`'s floor.
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
        //
        //    THE READ IS UNCONDITIONAL, deliberately. A both-legs-empty short-circuit would be sound —
        //    `_sweepAtOracleFloor` no-ops on a zero balance either way — but it buys exactly ONE state
        //    and costs bytes this library does not have. Reaching here with both legs empty ALSO requires
        //    zero residual debt (`_settleRepayDebts`'s shortfall path prices independently, so a settle
        //    with debt outstanding has already read the feeds), and any real unwind of a levered book
        //    leaves one leg or the other behind — the CL position is two-sided or one-sided, never
        //    neither.
        //
        //    And the guard would only ever fire on an ALREADY-FLAT book, where nothing else needs an
        //    oracle either: `nav()` takes its `tokenId == 0` branch (face value of idle USDC, oracle-free),
        //    `fastRedeem` returns before pricing when idle covers the payout, the proportional-redeem
        //    valves are oracle-free by construction, a deferred owner `settle` is simply retried, and the
        //    migration gates read no feed — so there is no flatten to unblock. A stale feed here blocks a
        //    settle of a book that has nothing left to sell, which is a retry, not a lockout.
        //
        //    IF IT IS EVER REVISITED, THE GUARD MUST BE ASSET-MODE-AWARE. There `$.cbBTC == $.usdc`, so a
        //    naive `IERC20($.cbBTC).balanceOf(address(this)) == 0` tests the idle USDC step 4 has just
        //    created and can never be true — the guard would be dead code in exactly one of the two
        //    shapes. The correct predicate is
        //    `$.legBIsAsset ? 0 : IERC20($.cbBTC).balanceOf(address(this))`.
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
        // Snapshot the stayers' (1-f) share of any PRE-EXISTING idle leg. A `rerange` recenter
        // leaves a remainder of one borrowed leg (cbBTC or WETH) idle in the strategy — the leg
        // sweep at step C would otherwise hand a partial redeemer 100% of it, skimming the stayers'
        // share. Reserving (1-f) of it keeps redeem oracle-free (stayers' share stays as LEGS, not
        // oracle-valued). Both are ~0 (clean no-op) outside a post-rerange partial redeem.
        //
        // ASSET-MODE (`cbBTC == usdc`): leg B's "idle leg" balance IS the idle USDC that `stayersIdle`
        // above already reserves off the PRE-unwind snapshot. Deriving a second reservation from the
        // same balance would reserve it twice and under-pay the redeemer, so reserve 0 here — leg B
        // needs no leg-reservation at all in that shape: it carries no debt (so the repay budget below
        // never consults it) and its sweep is the identity (`_sweepLegToUsdc` early-returns on the unit
        // of account, leaving the whole USDC balance for the `stayersIdle` arithmetic at the end).
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
        //
        // `_unwindLiquidity` above calls `gauge.withdraw`, which auto-claims the WHOLE accrued reward
        // tranche into this wallet — on EVERY async redeem, because the redeem's own unwind is what
        // creates the balance. Step C sweeps only the two LEG tokens, so before this the redeemer was
        // paid `f × (assets − reward)` while 100% of the tranche stayed behind with the stayers. Since
        // `nav()` prices that reward (held balance AND `gauge.earned()`), that was a live nav-vs-payout
        // inconsistency on this path, not merely an unfairness.
        //
        // WHY THE SNAPSHOTS ABOVE DO NOT ALREADY HANDLE IT — this is the budget arithmetic, and it is
        // the reason the call returns a number instead of just selling. `idleUsdcBefore`/`stayersIdle`
        // are taken BEFORE the unwind, deliberately (see their comment: LP-shed USDC is 100% the
        // redeemer's). The sale lands AFTER that snapshot, so left alone the WHOLE tranche would flow to
        // the redeemer through `usdcFinal − stayersIdle` — over-correcting, not fixing. But the tranche
        // is not this redeem's own product: `gauge.withdraw` is all-or-nothing per NFT, so it claims the
        // reward the WHOLE book farmed, of which the redeemer owns exactly `f`. So the wrapper measures
        // the proceeds and returns the stayers' `(1−f)`, in the same `x − f·x` form `stayersIdle` itself
        // uses (dust rounds to the stayers), and it is ADDED to the reservation here. Net: redeemer
        // `+f·proceeds`, stayers `+(1−f)·proceeds` — the split `nav()` already prices, with neither
        // party double-credited. It also widens the redeemer's own cover budget below
        // (`bal − stayersIdle`) by their `f` share and not a wei more.
        //
        // FAIL-OPEN, held INSIDE the wrapper (which is why there is no `try` here). The sale itself fails
        // CLOSED in its own frame (stale reward feed → `StaleOracle`; a fill under the L9 oracle floor →
        // `BelowOracleFloor`), so a swallowed revert rolls the swap back entirely — the tranche is never
        // sold blind. Swallowing is what keeps `emergencyRedeem` — the deadman, built for the
        // oracle-down-AND-backend-dead state — able to complete, exactly as the sweep floors below do.
        // The residual when the sale fails is precisely today's behaviour: the tranche stays as reward
        // token and the stayers keep it — the one documented residual, marked on chain by the wrapper's
        // `RedeemRewardSaleDeferred`. STAYERS ARE NEVER WORSE OFF than before this change; the redeemer
        // is, at worst, no better off.
        stayersIdle += IRewardSaleSelf(address(this)).sellRedeemRewardSelf(shares, supply);

        // B — repay f of each debt from collected tokens; capture any IL shortfall. The repay is
        // capped at the REDEEMER's own per-leg budget (`legBal − stayersLeg`) so a severe IL
        // shortfall can never consume the stayers' reserved `(1-f)` idle-leg share to over-repay
        // the redeemer's debt. Passing `stayersCb`/`stayersWeth` keeps the genuine shortfall flowing
        // to `cbShort`/`wethShort` → covered from the redeemer's OWN collateral (step D), upholding
        // the §7 invariant ("stayers keep (1-f) of every leg, regardless of price").
        (uint256 cbShort, uint256 wethShort) = _redeemRepayFromCollected(shares, supply, stayersCb, stayersWeth);

        // C — SWEEP THE SURPLUS LEGS FIRST, SO THE DEFICIT BUY IS ORACLE-FREE. This block used to sit at
        // the very END of the function. Hoisting it here is what makes the covers below self-funding: an
        // IL shortfall is by construction ASYMMETRIC (one leg over-collected, the other short), so the
        // surplus leg is the natural funding source for the deficit leg's buy — and turning it into USDC
        // BEFORE Phase 1 lets Phase 1's exact-output cover spend it WITHOUT reaching Phase 2's Chainlink
        // reads. Ordering constraints, both satisfied: it must come AFTER the pro-rata repays above (or
        // it would sell the legs those repays need) and BEFORE the covers (that is the point).
        //
        // THIS HOIST REQUIRES the best-effort Phase 1 and the exact-output Phase 2. Best-effort, because
        // funding the covers from a swept balance puts them squarely in the `0 < budget < needed` band
        // that used to revert. Exact-output, because the old exact-INPUT Phase 2 over-bought by its 10%
        // buffer and relied on THIS sweep, running last, to convert the excess back to USDC — hoisted
        // above it, that excess would strand as leg tokens on a book that is about to go flat.
        //
        // Sweep residual cbBTC/WETH → USDC, LEAVING the stayers' reserved leg share un-swept. For a
        // full redeem (f=1) or no rerange remainder, stayers* == 0 → sweep all (identical to the prior
        // unconditional sweep). In the common partial case this hands the redeemer exactly
        // f*(idleLeg + LP_leg − debt_leg).
        //
        // ORACLE-FLOORED, DEADMAN-PRESERVING. These were the last zero-min-out swaps in the system: a
        // hostile router / sandwich could fill them at any price and the loss landed entirely on the
        // REDEEMER (the stayers' `keep` is reserved BEFORE the sweep and stays behind as legs). Each
        // floor is now `oracleValue(amount ACTUALLY SOLD) × (1 − maxSlippageBps)` — the `_rebalanceCover`
        // / `_sweepAtOracleFloor` idiom, priced off the sold amount and NOT the raw balance, or an
        // unreachable floor would revert every partial sweep.
        //
        // THE `try` IS THE LOAD-BEARING PART. `emergencyRedeem` routes through this exact path and
        // exists for the oracle-down-AND-backend-dead state (see the strategy's `FULFILL_WINDOW`
        // deadman note), so a fail-closed floor here would convert a value guard into a fund freeze.
        // The derivation therefore lives behind an external hop the manager can catch, and an
        // unreadable feed degrades to floor = 0 — exactly the pre-fix behaviour, in exactly the state
        // that behaviour exists for. A sandwicher cannot MAKE a feed stale, so the floor binds whenever
        // it can bind.
        {
            uint256 cbFloor;
            uint256 wethFloor;
            // `_sellable` mirrors `_sweepLegToUsdc`'s own gate (unit-of-account identity, `bal <= keep`)
            // so the floor is always priced on the amount that swap will actually sell.
            try IRedeemSweepFloors(address(this)).redeemSweepFloors(
                _sellable($.cbBTC, stayersCb), _sellable($.weth, stayersWeth)
            ) returns (uint256 f0, uint256 f1) {
                (cbFloor, wethFloor) = (f0, f1);
            } catch {
                // Oracle down / sequencer down: floors stay 0 so the deadman exit still completes.
                // MARKED, because this `catch` cannot distinguish a stale feed from an out-of-gas and
                // the swaps below then run UNBOUNDED. Silent fail-open leaves no on-chain trace at all.
                emit RedeemSweepFloorsDegraded();
            }
            _sweepLegToUsdc($.cbBTC, stayersCb, cbFloor);
            _sweepLegToUsdc($.weth, stayersWeth, wethFloor);
        }

        // D — clear whatever debt the pro-rata repay could not, then free the collateral.
        if (shares == supply) {
            // Full redemption — two-phase debt clearance before 100 % collateral redeem.
            //
            // Phase 1 (oracle-free): cover IL shortfall from the on-hand USDC via exact-output swap.
            //   BEST-EFFORT (`bestEffort == true`), and that is the whole point of the phase. With
            //   `usdcBal == 0` the call early-returns; with `0 < usdcBal < needed` the exact-output swap
            //   CANNOT partially fill and reverts in its own frame, so `swapExactOut` swallows it and
            //   reports `filled == false`. Without that, the whole band `0 < idle < needed` reverted the
            //   redeem — `emergencyRedeem` included. (The old comment here claimed the no-op came from
            //   `amountInMaximum = 0`; it never did — the guard is on the BALANCE.)
            //
            //   THE RAW FLOAT IS AN OPERATOR DIAL, AND THIS IS WHAT IT BUYS. Phase 1 spends the RAW
            //   USDC balance and reads no feed; Phase 2 below redeems collateral and prices the
            //   deficit off Chainlink. So the size of the raw float decides how much of a full
            //   redeem's IL shortfall can be covered WITHOUT an oracle — which matters most for the
            //   trustless `emergencyRedeem` deadman, the one exit that must not depend on our feeds.
            //   `supplyIdle` is deliberately a KEEPER op rather than something `deposit` does on
            //   arrival for exactly this reason: supplying every deposit as it landed would have
            //   driven this budget structurally to 0 and made every shortfall-carrying full redeem
            //   oracle-dependent. Leaving float un-supplied costs the supply APY on that slice; the
            //   keeper sizes the trade-off, the code does not make it for them.
            if (cbShort > 0) _redeemCoverShortfall($.cbBTC, $.mCbBTC, cbShort, type(uint256).max, true);
            if (wethShort > 0) _redeemCoverShortfall($.weth, $.mWeth, wethShort, type(uint256).max, true);
            // Phase 2 (self-fund fallback): if residual debt remains after step C's sweep and Phase 1,
            //   fund the buy out of mUSDC collateral, buy the deficit token at the Chainlink-priced
            //   budget, and repay. `_settleShortfall` returns immediately on a zero borrow balance, so
            //   it reads NO feed when the phases above it already cleared the book.
            //
            //   THAT EARLY RETURN IS ONLY NOW GENUINELY REACHABLE, and the fix is one word up in step B.
            //   `_repay` accrues the market before applying the payment, so a repay sized off the STORED
            //   index left `current − stored` of interest standing every single time. On a full redeem
            //   that dust was the ONLY thing keeping the balance nonzero — so every full redeem fell
            //   through to here and read Chainlink, `emergencyRedeem` included, which is precisely the
            //   exit that exists for the state where Chainlink is unavailable. Step B now reads CURRENT,
            //   so the ordinary full redeem lands on zero debt and stops here.
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

    // NOTE: `fastRedeemImpl` (body of the strategy's fast `redeem`) LIVES IN `LeveragedAeroVenue`,
    // relocated verbatim under EIP-170 pressure here — it reaches back through the public
    // `readCollateralDebtImpl` / `assertHealthyImpl` below, so the gate basis is still this library's.

    /// @notice Public view wrapper over `_readCollateralDebt` for the strategy's `previewRedeem`
    ///         (advisory fast-path gate prediction). Delegatecalled under staticcall — the oracle
    ///         reads inside `_readCollateralDebt` fail-closed (revert) on a down feed, which the
    ///         strategy's `previewRedeem` catches to return `(0,false)`.
    function readCollateralDebtImpl() public view returns (uint256 collateralUsdc, uint256 debtUsdc) {
        return _readCollateralDebt();
    }

    /// @notice Deploy `amount` of idle strategy USDC into the existing levered position
    ///         (body of the strategy's `deployIdle`): supply + borrow + increaseLiquidity.
    /// @dev Asset-mode sizes against the STORED range (`posTickLower`/`posTickUpper`) — the range
    ///      `_addLiquidity` will actually add into, NOT a freshly centred one. A stored range the price
    ///      has since left is one-sided, so the split fails closed (`DegenerateRange`). A `rerange`
    ///      unblocks it only while spot is still INSIDE the stored band (there it recentres); once spot
    ///      has left, the rerange reopens WHOLLY ON THE POPULATED SIDE and this path stays closed until
    ///      price enters the new band. The unconditional cure is `flatten` + `redeploy`.
    ///
    ///      NO UP-FRONT CALM-GATE HERE — the gate lives inside `_addLiquidity`, so it runs AFTER the
    ///      supply/borrow below and before the pool is touched. See the ordering note on `executeImpl`
    ///      for why that asymmetry is deliberate and why it is not a weakening.
    ///
    ///      `InsufficientIdle` HERE BOUNDS AGAINST `_usdcAvailable()` AS A BELT ONLY — THE BINDING
    ///      BOUND LIVES IN THE STRATEGY ENTRYPOINT. Idle USDC the keeper has parked with `supplyIdle`
    ///      lives in mUSDC, so the raw balance can be 0 on a fully-funded book and the old raw-balance
    ///      bound would have refused the call. But the widened basis MUST NOT include collateral that
    ///      is already backing debt: `_supplyAndBorrow` sizes its borrow off the GROSS `amount`, so a
    ///      call funded from levered collateral is a net debt-only increase (redeem → supply back →
    ///      borrow) that walks LTV from `targetLtvBps` toward `maxLtvBps` — the exact capability the
    ///      admin/proposer target split denies the keeper key. `LeveragedAerodromeCLStrategy.deployIdle`
    ///      therefore bounds `amount` by raw + UN-LEVERED collateral (`_unleveredCollateral`), which is
    ///      also what keeps the refusal typed (`InsufficientIdle`) instead of deferring to Moonwell's
    ///      free-collateral line (`MoonwellRedeemFailed`). `compound`'s harvest redeploy reaches this
    ///      function directly but arrives holding raw swap proceeds ≤ the raw balance, inside every
    ///      bound. `_materialiseUsdc` then redeems just the shortfall (a NO-OP for `compound`) and
    ///      `_supplyAndBorrow` supplies its collateral share straight back.
    ///
    ///      WORTH KNOWING, FOR THE ORDINARY PATH: this op is now largely REDUNDANT. A deposit already
    ///      grows the collateral base directly, and `adjustLeverage` alone levers that base to
    ///      `targetLtvBps` in both shapes — in asset-mode landing provably the same book this would
    ///      (see `LeveragedAeroValuation.assetModeLeverUpPair`'s fixed point). What still REQUIRES
    ///      `deployIdle` is `compound`'s harvest redeploy, which hands it genuinely raw swap proceeds
    ///      that are not yet collateral and must not wait for a separate lever step.
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
    ///         `minUsdcOut`) → skim up to `skimCap` of the realized USDC for the protocol fee →
    ///         redeploy the remainder at target leverage via `deployIdleImpl`. No-op when there's no
    ///         position or no AERO. Fee crystallisation + the external skim transfer live in the
    ///         strategy entrypoint, NOT here — this only sets aside `pay` so it isn't redeployed.
    /// @dev The redeploy is ATOMIC with the harvest: anything that fails the deploy path reverts the
    ///      whole call, claim and sale included. That is deliberate and it costs nothing — see the block
    ///      on step 6 for why, and for the recovery.
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
        //    THE PEG LEG IS PART OF THE FLOOR, not an assumed 1.00. The floor is post-checked against
        //    `usdcOut`, a USDC-FACE amount, so the USD value has to be divided by the USDC/USD price the
        //    same way `_sweepAtOracleFloor` and `nav()`'s own reward term already do. A bare `/1e20` is a
        //    USD-6dp quantity compared against a USDC-face fill: USDC BELOW peg makes the floor lax (the
        //    harvest can fill under fair value and still clear), USDC ABOVE peg makes it unclearable and
        //    bricks `compound` on `BelowOracleFloor`. `_tokenToUsdc` is the same conversion the debt,
        //    health and settle-sweep paths use, so all four now price on one basis.
        uint256 floor = _tokenToUsdc(aeroBal, 18, _readUsd8($.aeroUsdFeed), _readUsd8($.usdcFeed))
            * (10000 - uint256($.maxSlippageBps)) / 10000;
        //    DUST NO-OP, same branch (and same rationale) as `LeveragedAeroVenue._sellRewardBalance`: a
        //    balance worth under one micro-USD floors to 0 and the router fills it at 0, so the nonzero
        //    `minUsdcOut` this function already demands would revert every call. Without it a donation
        //    of reward-token dust to a gauge with no live emissions bricks `compound` outright.
        if (floor == 0) return 0;

        // 3. Swap ALL claimed AERO → USDC via the Aerodrome v2 volatile pool, passing the caller's
        //    minUsdcOut to the router. The measured-fill floor below is the robust guard (router-honesty
        //    independent); the effective bound is max(minUsdcOut, floor), enforced independently.
        //    The venue mechanics (Route[] + the v2 router interface) live in
        //    `LeveragedAeroValuation.swapAeroToUsdc` for EIP-170 headroom; it returns the MEASURED fill,
        //    so the post-check below is unchanged and still independent of what the router claims.
        uint256 usdcOut = LeveragedAeroValuation.swapAeroToUsdc(aero, $.usdc, aeroBal, minUsdcOut);
        if (usdcOut < floor) revert BelowOracleFloor(); // post-check on the measured fill (L9)
        if (usdcOut == 0) return 0; // unreachable when floor > 0 (aeroBal > 0), kept as defence

        // 4. Withhold up to `skimCap` of the realized yield for the protocol fee (the strategy pays
        //    it out); redeploy only the remainder.
        pay = skimCap < usdcOut ? skimCap : usdcOut;
        uint256 redeploy = usdcOut - pay;

        // 5. RE-HEDGE ACCRUED BORROW INTEREST out of the harvest, BEFORE the redeploy. Interest grows the
        //    debt leg without growing the LP leg, so without this step every harvest left the book a
        //    little more SHORT and nothing ever removed it (the fund is sold as delta-neutral on leg A).
        //    Buying that interest back and repaying it lands the financing cost as NAV DRAG — less
        //    harvest reinvested — instead of as accumulating exposure. Bounded by the harvest's own
        //    proceeds, so stayers' idle USDC and the collateral are never touched; a short budget hedges
        //    partially and carries the remainder to the next harvest rather than reverting.
        //    Ordering: ahead of the redeploy so `deployIdleImpl` sizes its NEW borrow off the corrected
        //    debt and the post-op `_assertHealthy` sees the final book.
        redeploy -= _hedgeInterestDrift(redeploy);

        // 6. Redeploy the net yield into the position at target leverage (supply → borrow →
        //    increaseLiquidity → restake → _assertHealthy). Any pre-existing idle USDC is left
        //    untouched — compound deploys the AERO yield, nothing else. Skip if all was skimmed.
        //
        //    THE REDEPLOY IS ATOMIC WITH THE HARVEST, DELIBERATELY. This call fails closed on everything
        //    the deploy path fails on — `DegenerateRange` (asset-mode, spot outside the stored range),
        //    the calm gate, `minLiquidity`, a Moonwell error code, the closing health assert — and ANY of
        //    them unwinds the WHOLE `compound`, including the `getReward` claim, the AERO sale and the
        //    interest hedge. That is the same resumable-op posture `flattenImpl` takes, and the opposite
        //    of the terminal `sellSettleRewardImpl`, which swallows because `settle()` must not be
        //    blockable.
        //
        //    IT COSTS NOTHING TO WAIT. An unclaimed tranche does not decay — it keeps accruing in the
        //    gauge — and an out-of-range position accrues NO new emissions anyway, so a blocked
        //    `compound` on the range-related failures forgoes nothing. The hedge measure is cumulative
        //    (`borrowBalanceStored − hedgedDebtA/B`), so the drift it did not buy back is simply carried
        //    to the next harvest. RECOVERY is `rerange` onto spot, or `flatten` + `redeploy` — which
        //    claims and sells the tranche and repays the legs on its way through.
        //
        //    DO NOT best-effort-catch this, and do not pre-check it. A catch would silently skip
        //    `minLiquidity`, the calm gate and the health assert — turning three real guards into
        //    no-ops on the one path that adds leverage. A pre-check could only relieve the least likely
        //    member of that set while leaving the rest to revert anyway.
        //
        //    RESIDUAL: none of substance for NAV. While the harvest is blocked the tranche stays
        //    unclaimed in the gauge, and `nav()`'s reward term prices `gauge.earned()` as well as the
        //    held balance (`LeveragedAeroValuation._rewardUsdc`), so it is still marked — the position
        //    is staked throughout, because the revert rolled the unstake back with everything else.
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
    ///         remove 100% liquidity + collect → size the collected legs → derive the new
    ///         tickSpacing-aligned range from them → re-add → restake → assert health. Debt + collateral
    ///         untouched.
    ///
    ///         TWO OUTCOMES, depending on where spot sits relative to the OLD band. Spot still INSIDE it
    ///         → the unwind collects both legs and the new range is the skewed band around spot: a true
    ///         recentre. Spot has LEFT it → the position was 100% one leg, and the new range is placed
    ///         WHOLLY ON THAT SIDE, abutting spot. That reopen is not a recentre: it starts out of range
    ///         and becomes two-sided only if price comes back. It is still the right op — the alternative
    ///         was reverting inside the pool, which made `rerange` unusable in the one state it exists
    ///         for. A true recentre of a departed book needs a swap, i.e. `flatten` + `redeploy`.
    ///
    ///         No swap → principal conserved; the collected ratio can't match the new range, so a
    ///         remainder of ONE borrowed leg is left idle (NAV-counted, stays redeployable). A new
    ///         tokenId is minted (Slipstream ticks are immutable); the old empty NFT is harmless dust.
    ///         No-op on a flat book.
    /// @dev TAKES NO RANGE PARAMS — which is exactly WHY the persist must precede this delegatecall. The
    ///      proposer's `width` / `skewBps` for this cycle were validated AND PERSISTED by the strategy
    ///      entrypoint (see the ordering note on `LeveragedAerodromeCLStrategy.rerange`), and step 4
    ///      below reads both straight out of storage: write after, and the re-range would land at the OLD
    ///      pair. The frame the two `sstore`s live in is a bytecode relocation for EIP-170 headroom, not a
    ///      semantic choice. The persists also sit ahead of the flat-book bail-out below — see the
    ///      entrypoint's note for what that does and does NOT buy on a terminal (fully-redeemed) book.
    ///
    ///      ASSET-MODE DEPLOY PATHS STAY CLOSED AFTER A ONE-SIDED REOPEN. `deployIdle`, an asset-mode
    ///      lever-up and `compound` all size through `_rangeRatio`, which needs a two-sided range against
    ///      spot; a band that abuts spot from one side is not one, so they keep reverting
    ///      `DegenerateRange` until price enters it. That is unchanged by this op and deliberate.
    /// @param minLiq0 Minimum token0 the re-add must consume. On a one-sided reopen the caller floors the
    ///        populated side and passes 0 for the other.
    /// @param minLiq1 Minimum token1 the re-add must consume (see `minLiq0`).
    function rerangeImpl(uint256 minLiq0, uint256 minLiq1) public {
        Layout storage $ = _layout();
        if ($.tokenId == 0) return; // flat book — nothing to re-range (width/skew already stored)

        // 1. Calm-gate BEFORE touching the pool — never recenter at a manipulated tick.
        LeveragedAeroValuation.calmGate($.pool, $.twapWindow, $.calmDeviationTicks);

        // 2. Unstake + remove 100% liquidity + collect (num==den → no restake). The old NFT is
        //    left empty + unstaked; a recenter needs a fresh range == fresh tokenId.
        //
        //    ASSET-MODE: snapshot leg B BEFORE the unwind, exactly as `redeemUnwindImpl` snapshots
        //    `idleUsdcBefore` and for the same reason (see its comment). Leg B IS the unit of account
        //    there, so its raw balance is idle deposits + the redeem cover budget — NOT what this op
        //    collected. Only the DELTA is this re-range's own principal; folding the rest in would let a
        //    re-range silently draw unlevered idle USDC into the LP, a capability no entrypoint declares
        //    (`deployIdle` is THE path that adds idle, and it levers it). Zero in the two-borrowed-legs
        //    shape, where the leg-B balance is a genuine rerange remainder and redeploying it IS intended.
        uint256 legBBefore = $.legBIsAsset ? IERC20($.cbBTC).balanceOf(address(this)) : 0;
        _unwindLiquidity(1, 1);

        // 3. SIZE FIRST. The legs THIS op collected — the full leg-A balance, and leg B net of the
        //    pre-unwind snapshot (0 outside asset-mode, so this is the full balance there). The range
        //    predicate below must read the POST-SNAPSHOT amounts: reading the raw balances instead would
        //    let unlevered idle USDC count as a populated side in asset-mode, i.e. reopen F05.
        (uint256 amt0, uint256 amt1) =
            _amounts01(IERC20($.cbBTC).balanceOf(address(this)) - legBBefore, IERC20($.weth).balanceOf(address(this)));

        // 4. Derive the range from the width/skew the entrypoint stored AND from what the unwind
        //    actually collected. Two-sided → the ordinary skewed band around spot (a recentre). ONE-SIDED
        //    → a band placed wholly on the populated side, which is the only range a swap-free re-add can
        //    fill once spot has left the old one; `skewedTickRange`'s straddling band would compute zero
        //    liquidity for the missing leg and revert inside the pool. Every later mint (deployIdle /
        //    compound) reuses whichever pair this produced.
        //
        //    No swap → principal conserved. `_mintPosition` enforces the two-sided `maxSlippageBps` mins
        //    (the §8 always-on floor) and approves the NPM; the caller's `minLiq0/minLiq1` add an
        //    explicit guard on the consumed amounts (proposer-tightenable, like compound's `minUsdcOut`)
        //    — on a one-sided reopen the caller floors the populated side and passes 0 for the other.
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

    /// @notice Retarget the position's LTV to `targetLtvBps_` (body of the strategy's `adjustLeverage`,
    ///         which passes the fund's STORED standing target — already bounded by `maxLtvBps` when the
    ///         admin wrote it via `setTargetLtv`, and non-zero). In the two-borrowed-legs shape
    ///         collateral is untouched, so LTV moves on the debt side: lever UP borrows the cbBTC/WETH
    ///         delta and adds it (`minLiq`); lever DOWN unwinds the matching CL fraction and repays
    ///         (per-leg residual rebalanced through USDC, bounded by `minOut`). Ends with
    ///         `_assertHealthy`.
    ///
    ///         ASSET-MODE: lever DOWN works unchanged (the leg-B residual IS USDC and flows straight
    ///         into the leg-A cover). Lever UP borrows ONLY leg A and pairs it with USDC DRAWN FROM THE
    ///         BOOK'S OWN USDC — raw balance first, then a `redeemUnderlying` off the mUSDC collateral,
    ///         which is where that USDC lives once the keeper has run `supplyIdle`. See `_leverUp` for
    ///         the derivation and for why own-funding (not swap-funding) is the only delta-preserving
    ///         choice. OPERATOR NOTE: an asset-mode lever-up therefore CONSUMES collateral into the LP.
    ///         That is value-conserving (a NAV component changing form, not a loss) and the sizing
    ///         corrects for it, so the book still lands at target. The typed
    ///         `InsufficientIdleForLeverUp` bound is provably unreachable from this op (the corrected
    ///         draw is strictly < collateral + raw; it is kept as defence in depth for direct library
    ///         callers), so the realistic funding failure is Moonwell refusing the mid-op redeem —
    ///         market cash short, or the draw crossing the free-collateral line — surfacing as
    ///         `MoonwellRedeemFailed(err)` with the whole op rolled back and nothing moved.
    ///
    ///         SIZE ASSET-MODE LEVER-UPS AWAY FROM RANGE EDGES. The USDC the pairing demands per unit
    ///         of new debt is the live range ratio: as the price approaches the leg-A-poor edge of the
    ///         STORED range the ratio diverges, and the corrected sizing — still landing exactly AT
    ///         target — draws up to the book's entire excess collateral into a nearly one-sided LP for
    ///         vanishing new debt. That composition shift is invisible to the LTV gates (the post-op
    ///         book IS at target). The op takes no amount parameter, so the operator control is
    ///         SEQUENCING, not sizing: `rerange` first when the price sits near an edge, then retarget.
    /// @param targetLtvBps_ Target LTV in bps. The caller passes the fund's STORED standing target
    ///                      (`$.targetLtvBps`), which the admin's `setTargetLtv` already validated as
    ///                      non-zero and `≤ maxLtvBps`; this function neither validates nor writes it.
    /// @param minLiq        Minimum CL liquidity on a lever-UP add (slippage guard).
    /// @param minOut        Minimum USDC out of a lever-DOWN residual swap (slippage guard).
    function adjustLeverageImpl(uint16 targetLtvBps_, uint256 minLiq, uint256 minOut) public {
        // NO PERSIST HERE — and none in the caller either. `targetLtvBps_` IS the stored standing
        // target: the admin/proposer split moved the write out of this op entirely, into the
        // admin-only `LeveragedAerodromeCLStrategy.setTargetLtv` (the proposer must be able to move the
        // book toward policy, not to change policy). Two consequences worth stating:
        //
        //   1. NOTHING ON THIS PATH READS `$.targetLtvBps` AGAIN. `_leverUp` / `_leverDown` /
        //      `_assertHealthy` size off the `targetDebt` computed below and off `maxLtvBps` /
        //      `minHealthBps`; `$.targetLtvBps`'s only other reader is `_supplyAndBorrow` (the deploy
        //      path). So this op is purely "move the book to where policy already says". THIS IS NOW
        //      LOAD-BEARING FOR THE ASSET-MODE SIZING: `_leverUp`'s fixed-point correction takes the
        //      target as a PARAMETER, threaded from the same `targetLtvBps_` the delta below is sized
        //      from — re-reading storage there instead would mis-size the correction (delta at one
        //      ltv, correction at another) for any future caller that passes a different target.
        //   2. THE NO-OP CASE IS NOW GENUINELY A NO-OP. When `targetDebt == debtUsdc` (already at
        //      target, or zero collateral pre-`execute`) both branches are skipped and nothing happens
        //      — previously this call still had to land the target write, which is what the ordering
        //      argument that used to live here was about. The per-cycle range knobs are unaffected and
        //      keep their own persistence: `rerange` writes BOTH `width` and `skewBps` in the STRATEGY
        //      frame (for EIP-170 headroom, ahead of `rerangeImpl`'s own flat-book bail-out, so
        //      `rerangeImpl` takes no range params at all) because those remain per-call proposer
        //      knobs. The leverage target is not one.
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
        // ERR DELIBERATELY DISCARDED HERE — it is checked on the AFTER read below, and that is strictly
        // stronger. Compound's `getAccountLiquidity` returns `(err, 0, 0)` on EVERY error branch, so a
        // failed read here leaves `shortfallBefore == 0` and the gate below becomes
        // `shortfallAfter >= 0` — always true — i.e. ANY residual shortfall reverts. Tighter, not looser.
        // And the conditions that raise `err` (a zero oracle price, a snapshot failure on an entered
        // market) cannot be cleared by this op — nothing here exits a market — so the after read errs
        // too and the call reverts anyway. Capturing it here could therefore only convert a
        // provably-healthy success into a revert of the PERMISSIONLESS health valve, at a cost in bytes
        // this library does not have.
        (,, uint256 shortfallBefore) = IComptroller($.comptroller).getAccountLiquidity(address(this));

        // Target debt that lands health at minHealthBps + the re-trigger buffer (collateral is
        // untouched, so health = c / d ⇒ targetDebt = c × 1e4 / targetHealth).
        uint256 targetHealth = (minHealth * (10000 + uint256(DELEVERAGE_BUFFER_BPS))) / 10000;
        uint256 targetDebt = (collateralBefore * 10000) / targetHealth;
        if (debtBefore > targetDebt) {
            // CLAMP, don't inherit the full-unwind rejection. In the collateral≈0 tail `targetDebt`
            // floors to 0, so the requested repay equals the whole debt and `_leverDown`'s
            // orphaned-NFT guard (`repayUsd >= debtUsd`) reverts `FullUnwindNotSupported` — turning the
            // PERMISSIONLESS health valve off in exactly the state it exists for. Leaving one unit of
            // debt keeps `num < den`, so `mulDiv` leaves ≥1 liquidity and the re-stake fires, and the
            // position NFT cannot be orphaned. The recovery gate below still has to pass, so this
            // widens what deleverage can attempt, never what it can leave behind. The guard itself is
            // untouched for `adjustLeverage`, where a full-unwind request is a caller error and
            // `flatten()` is the correct op.
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

    /// @dev Lever UP by `borrowDeltaUsd` (USDC face, 6dp) and add the proceeds to the existing position.
    ///      No new collateral — mirrors `deployIdleImpl`'s borrow→wrap→add→restake without the supply
    ///      step. THE ONE SHAPE BRANCH on the leverage path (the mirror of `_supplyAndBorrow`'s):
    ///
    ///      - TWO BORROWED LEGS: borrow the delta 50/50 by USD across both legs and LP them against each
    ///        other. Self-funding — the pair IS the two borrows. UNCHANGED.
    ///      - ASSET AS A LEG: the borrow is a SINGLE volatile leg (leg A), so the LP's USDC side has to
    ///        come from somewhere. It is DRAWN FROM THE BOOK'S IDLE USDC.
    ///
    ///      WHY IDLE-FUNDED AND NOT SWAP-FUNDED — this is the whole reason for the design. Two sourcings
    ///      were possible:
    ///
    ///        (a) Borrow ΔB leg A, pair it with `U′` USDC taken from idle, mint. The LP then holds ΔB of
    ///            leg A while the debt grew by exactly ΔB, so NET leg-A exposure = LP leg − debt leg = 0.
    ///            The delta-hedge is preserved, exactly as at genesis (where the collateral USDC is the
    ///            unhedged part and the borrowed leg is fully offset by the LP's leg).
    ///        (b) Borrow ΔB and swap part of it to USDC, then LP both sides. That leaves the book NET
    ///            SHORT the swapped amount — an op whose contract is "move leverage only" would silently
    ///            rewrite the fund's delta profile.
    ///
    ///      (a) is implemented. `U′` is DERIVED, never passed, so `adjustLeverage` needs no funding
    ///      parameter for it: collateral is untouched by this op, so the debt delta is fixed by
    ///      `targetLtvBps_ × collateral` (computed in `adjustLeverageImpl`) and `U′` is that delta's
    ///      leg-A borrow paired at the STORED range's required (legA : USDC) ratio —
    ///      `LeveragedAeroValuation.assetModeLeverUpPair`, which shares its ratio probe and its
    ///      USD→leg-A conversion with the genesis `assetModeSplit` so the two cannot drift.
    ///
    ///      FUNDING IS A HARD REQUIREMENT, CHECKED BEFORE THE BORROW — but know WHICH check binds.
    ///      The typed `InsufficientIdleForLeverUp(needed, available)` bound (`available` =
    ///      `_usdcAvailable()`, raw + redeemable mUSDC collateral) is PROVABLY UNREACHABLE from
    ///      `adjustLeverage`: the corrected draw is `b·(u0−R)/(b+ltv·u0) < b/ltv ≤ C`, strictly inside
    ///      `raw + C`. It is kept as defence in depth for direct `assetModeLeverUpPair` callers. The
    ///      binding constraint is Moonwell's: `_materialiseUsdc`'s mid-op redeem fails
    ///      (`MoonwellRedeemFailed(err)`, whole op rolled back, nothing moved) when the market is cash-
    ///      short or the draw crosses the free-collateral line `(C − draw)·CF ≥ D`. Still deliberately
    ///      NOT a partial fill and NOT a silent cap. The consumed USDC is
    ///      value-conserving — a NAV component moving from collateral into the LP — and the sizing
    ///      accounts for the collateral it consumes (see the fixed point above), so the op lands AT
    ///      target rather than past it. A stored range the price has since left is one-sided and fails
    ///      closed (`DegenerateRange`), same as `deployIdle` — and with the same caveat: a `rerange`
    ///      unblocks it only while spot is still inside the stored band; once spot has left, the rerange
    ///      reopens one-sided and only `flatten` + `redeploy` restores a two-sided range. Near
    ///      (but inside) an edge the op still succeeds and the draw grows without bound relative to the
    ///      new debt — see the OPERATOR NOTE on `adjustLeverageImpl`: rerange first near edges.
    function _leverUp(uint256 borrowDeltaUsd, uint256 targetLtvBps_, uint256 minLiq) private {
        Layout storage $ = _layout();
        uint256 cbBTCAmt;
        uint256 wethAmt;
        if (!$.legBIsAsset) {
            (cbBTCAmt, wethAmt) = _borrowHalfEach(borrowDeltaUsd);
        } else {
            // Size the single leg-A borrow and the USDC that must pair with it in the STORED range (the
            // range `_addLiquidity` will actually add into). Leg B IS the unit of account here, so that
            // USDC enters as the leg-B amount and `_amounts01` routes it with no further special-casing —
            // identical to `deployIdleImpl`'s asset-mode add. `assetModeLeverUpPair` also enforces the
            // funding bound (BEFORE the borrow below), reverting `InsufficientIdleForLeverUp`.
            //
            // TWO THINGS CHANGED WITH "NO IDLE USDC SITS DEAD", and they are one decision. The pairing
            // USDC can no longer be assumed to come from a raw balance (once the keeper has run
            // `supplyIdle` there may be none), so (1) the bound is taken against `_usdcAvailable()` —
            // raw plus redeemable
            // collateral — and (2) `raw` and `targetLtvBps` are passed so the sizing solves the FIXED
            // POINT `Δ = (borrowDeltaUsd + ltv·raw) / (1 + ltv·m)` rather than the naive delta: the
            // part of `U′` that has to be redeemed out of the collateral shrinks the very base the LTV
            // is measured against, and ignoring that lands the book ABOVE target — far enough to trip
            // `_assertHealthy`'s `maxLtvBps` on an aggressive one. A book still holding `raw ≥ U′`
            // clamps back to the naive delta, i.e. to this call's pre-change behaviour exactly. The
            // derivation, and the proof that it reproduces `assetModeSplit`'s genesis book, are on
            // `assetModeLeverUpPair`.
            //
            // ORDER IS LOAD-BEARING: size (which enforces the bound) → materialise → borrow. The
            // `_materialiseUsdc` sits between them so the redeem happens against the PRE-borrow book,
            // where Moonwell's own collateral check is at its most permissive; doing it after the
            // borrow would ask Moonwell to release collateral against a debt that just grew.
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
        // FULL-UNWIND GUARD (load-bearing, do not relax to a clamp).
        //
        // `repayUsd == debtUsd` drives `_unwindLiquidity` down its `num == den` branch, which removes
        // 100% of the liquidity and — because nothing remains to earn — SKIPS the re-stake. The two
        // callers that legitimately take that branch dispose of the position first (`settleImpl` zeroes
        // `tokenId`, `rerangeImpl` replaces it with a fresh mint); `_leverDown` does neither, so it
        // would leave a live `$.tokenId` pointing at an NFT the gauge no longer holds. Every later
        // venue op opens with `ICLGauge.withdraw($.tokenId)` — settle, flatten, rerange, deployIdle,
        // compound and BOTH async-redeem exits — so the book would be permanently bricked, including
        // the trustless `emergencyRedeem` deadman. (`migrateVenue` and `redeploy` are NOT in that list:
        // both require a flat book and never touch the gauge with a live `tokenId`. They are bricked
        // transitively — reaching them requires `flatten`, which is in the list.)
        //
        // Rejecting is the fix rather than retiring the position (`$.tokenId = 0`): clearing the id
        // would leave the same orphaned, gauge-less NFT behind, which is the whole problem above. (It
        // would no longer mis-price NAV — since `supplyIdle`, the `tokenId == 0` branch values mUSDC
        // collateral too — but the bricking argument never needed that second leg and does not rest on
        // it.) A genuine full unwind must dispose of the position and redeem the collateral: that is
        // `flatten()`.
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
    ///      `surplusTok` as that cover needs → USDC, then buying exactly the deficit from that USDC and
    ///      repaying it. Any leftover USDC stays idle (NAV-counted; recoverable via `deployIdle`/`redeem`).
    ///
    ///      **NEED-SIZED, NOT WHOLESALE** — the sell keeps `surplusBal − needed`. The surplus-leg BALANCE
    ///      is not the same thing as this op's surplus: it can also hold a PRE-EXISTING idle remainder (a
    ///      skewed-`rerange` leftover is the ordinary source) which is still matched 1:1 by that leg's
    ///      Moonwell debt and is therefore delta-NEUTRAL where it sits. Selling it would convert a hedged
    ///      holding into an unrecorded SHORT that no monitor surfaces: `hedgeBorrowInterest` measures
    ///      interest drift (`debt − hedgedDebt`) only, and `_repay`'s clamp re-anchors `hedgedDebt` to the
    ///      post-repay debt, so the missing leg leaves no trace in either. Same reasoning as the stayer
    ///      snapshots `redeemUnwindImpl` documents — a balance is not evidence of entitlement to it.
    ///      `needed` is the ORACLE conversion of `shortAmt` into surplus-leg units, grossed up by
    ///      `maxSlippageBps` on BOTH conversions (the buy ceiling and the sell floor) so a fill landing on
    ///      the floor still raises the ceiling-priced buy; short of that the exact-output cover would
    ///      revert on `amountInMax` rather than silently under-repay.
    ///
    ///      **Oracle-floor guard** — the minimum USDC out of the surplus-leg sell is enforced as
    ///      `max(callerMinUsdcOut, oracleFloor)` where
    ///      `oracleFloor = _tokenToUsdc(amount ACTUALLY sold) × (1 − maxSlippageBps)`.
    ///      This prevents a griefer from passing `minOut=0` to the permissionless `deleverage()`
    ///      and sandwiching the IL-residual swap.  If a Chainlink feed is stale the read reverts —
    ///      fail-safe and consistent with `_assertHealthy`. The floor tracks the SOLD amount, not the
    ///      balance: derived off the balance it would be unreachable whenever `keep > 0` and would brick
    ///      every need-sized sell. A caller `minUsdcOut` sized for the whole balance can still bind — it
    ///      is a per-call proposer guard, so size it against the shortfall, not the wallet.
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
        bool deficitIsCb = deficitTok == $.cbBTC;
        bool surplusIsCb = surplusTok == $.cbBTC;
        // ASSET-MODE: when the surplus leg IS the unit of account there is nothing to sell — the sweep
        // below no-ops, so pricing it would be dead arithmetic (and one more feed that could revert).
        // A zero balance short-circuits `coverBounds` to the deficit buy alone, which spends that
        // surplus USDC directly (bounded by the oracle ceiling).
        uint256 surplusBal = surplusTok == $.usdc ? 0 : IERC20(surplusTok).balanceOf(address(this));
        // The three oracle bounds (need-sized sell amount, its floor, the buy ceiling) are derived in
        // `LeveragedAeroValuation.coverBounds` — this library is at the EIP-170 cap.
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

    /// @dev Collateral + debt in USDC face (6dp) on the SAME hardened-Chainlink basis as
    ///      `_assertHealthy` (the LTV/health basis) — sizes the adjustLeverage / deleverage targets.
    ///      Returns `debtUsdc == 0` (skipping the price reads) when both borrows are clear.
    ///
    ///      STORED-INDEX STALENESS HERE IS A KNOWN, DELIBERATELY UNCHANGED RESIDUAL — do not "fix" it by
    ///      analogy with `LeveragedAeroValuation._measureLeg` (which reads `borrowBalanceCurrent`). The two
    ///      cases are not alike:
    ///
    ///        - The hedge MEASURES accrued interest, so a stale read makes its answer ~0 and the feature
    ///          simply does not work. Here the reads feed a RATIO, and BOTH sides are stale on the same
    ///          basis: `collateralUsdc` comes from `exchangeRateStored` (also last-accrued). The sign of
    ///          the error therefore depends on the relative accrual recency of THREE markets (mUSDC and the
    ///          two borrow markets), not on one, and is not monotonically unsafe.
    ///        - This function is `view`, and its public wrapper `readCollateralDebtImpl` is reached under
    ///          STATICCALL from the strategy's `previewRedeem`. It structurally cannot accrue. Accruing
    ///          would mean splitting it into view/mutating twins and accruing in each state-changing caller
    ///          (`fastRedeemImpl`, `adjustLeverageImpl`, `deleverageImpl`) — a behaviour change on the
    ///          permissionless `deleverage` valve (a stale, health-OVERSTATING read currently refuses
    ///          `HealthyNoDeleverage`; a fresh one would let it fire in states it presently rejects, and
    ///          would also make its before/after health comparison fresh-vs-fresh where today "before" is
    ///          stale and "after" is post-`repayBorrow`, i.e. accrued) and on the gate that runs after every
    ///          op. That needs its own review and test matrix, not a ride-along.
    ///        - The authoritative belt in `_assertHealthy` is Moonwell's own `getAccountLiquidity`, which is
    ///          computed on the SAME stored basis Moonwell's liquidation-eligibility check uses; a real
    ///          liquidation tx accrues both markets first, so the residual is a window, not a blind spot.
    ///
    ///      Bounded direction of the residual, for the record: understated debt ⇒ overstated health /
    ///      understated LTV ⇒ `adjustLeverage` may lever up marginally past target, `fastRedeem`'s LTV gate
    ///      is marginally loose, and `deleverage` may trigger marginally late. All are bps-scale over a live
    ///      market's short inter-accrual window; none is exploitable (nobody can hold the index still).
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
    ///      error-check. Used by the two "leave no dust" sites: `settleImpl` step 4 and
    ///      `_redeemCollateral`'s full-redeem branch.
    function _redeemCTokens(address cToken, uint256 tokens) private {
        uint256 err = ICToken(cToken).redeem(tokens);
        if (err != 0) revert MoonwellRedeemFailed(err);
    }

    /// @dev USDC the book can spend without touching the LP — raw balance + redeemable mUSDC
    ///      collateral. THE FUNDING BASIS every "do I have enough idle?" bound now uses; see
    ///      `LeveragedAeroValuation.usdcAvailable` for why the raw balance alone is no longer it.
    function _usdcAvailable() private view returns (uint256) {
        Layout storage $ = _layout();
        return LeveragedAeroValuation.usdcAvailable($.usdc, $.mUsdc, address(this));
    }

    /// @dev MATERIALISE `amt` of RAW USDC on demand: redeem only the SHORTFALL from mUSDC.
    ///
    ///      THE SHORTFALL FORM IS THE WHOLE POINT, not an optimisation. A blanket
    ///      `_redeemUnderlying($.mUsdc, amt)` would make every `deployIdle` a redeem→mint round trip,
    ///      and Compound's truncating divisions cost the position on the way back in (`mintTokens =
    ///      amt/rate` floors the credited cTokens; the redeem's own floor merely burns fewer cTokens
    ///      for the exact underlying, which favours the position) — so a wholesale
    ///      round trip burns up to ~1 unit of USDC per call for nothing. Redeeming only `amt − raw`
    ///      makes `compound`'s harvest redeploy — which arrives holding genuinely RAW swap proceeds —
    ///      a strict no-op: no redeem, no dust, no extra gas, byte-for-byte the old behaviour. The
    ///      proposer's ordinary `deployIdle` on supplied funds pays the round trip once, on the
    ///      portion `_supplyAndBorrow` puts straight back (all of it in the two-borrowed-legs shape,
    ///      only the collateral share `C` in asset-mode).
    ///
    ///      Fails closed through `_redeemUnderlying`: a Moonwell redeem the collateral (or the
    ///      market's cash) cannot cover surfaces as `MoonwellRedeemFailed(err)` with nothing moved.
    ///      Callers that want a typed pre-check bound themselves by `_usdcAvailable()` first.
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
        // ACCRUE, *THEN* MEASURE. These two reads decide `full repay` vs `partial repay`, and the repay
        // they gate pulls the ACCRUED debt while the approval above it is sized off the token BALANCE.
        // With the stored index, a book whose balance covers the stale debt but not the accrued debt
        // takes the `type(uint256).max` branch and Moonwell then tries to pull more than was approved —
        // the whole unwind reverts. That was tolerable while this ran only inside the terminal,
        // owner-driven `settle()`; `flatten` made it a routine proposer op AND the precondition for
        // `migrateVenue`, so a stale read here can block a migration. `borrowBalanceCurrent` is
        // non-view (it advances the market's index) and returns the balance, not an error code.
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
    ///
    ///      EXACT-OUTPUT, AND THE BUDGET IS THE CONFIGURED SLIPPAGE — not a hardcoded 10%. This used to
    ///      redeem `oracleCost × 110%` and spend all of it through an exact-INPUT swap floored at
    ///      `debtRem × (1 − maxSlippageBps)`. Those two bounds were INDEPENDENT, so a router filling
    ///      anywhere between them kept the whole gap: on a 100 bps clone the position could overpay by
    ///      ~11% of the shortfall with nothing on chain objecting, and the overpayment came out of the
    ///      collateral backing every other holder. Routing both legs through `_redeemCoverShortfall`
    ///      makes ONE number — `maxSlippageBps` — both the budget and the bound: the swap buys exactly
    ///      `debtRem` and reverts rather than spending past `oracleCost × (1 + maxSlippageBps)`.
    ///
    ///      FAIL-CLOSED (`bestEffort == false`) AT BOTH SITES, deliberately. This is the LAST thing
    ///      standing between a full unwind and `_redeemCollateral`'s `redeem(cBal)` / `settleImpl`'s
    ///      step-4 burn, and Moonwell refuses to release collateral while ANY debt is live. An
    ///      unaffordable cover must roll the whole op back, not leave dust for that burn to trip over.
    ///
    ///      ACCRUE, *THEN* MEASURE, for the reason `_settleRepayDebts` states and one more of its own:
    ///      `debtRem` is now the exact-OUTPUT amount, so a stale-low read under-buys by construction and
    ///      strands exactly the dust described above. `_settleRepayDebts` does accrue both markets ahead
    ///      of its call, but `redeemUnwindImpl`'s Phase-2 call site does NOT go through it — the old
    ///      "no fresh read is needed" note was only ever true for one of the two callers.
    function _settleShortfall() private {
        Layout storage $ = _layout();
        uint256 cbDebtRem = IMoonwellMarket($.mCbBTC).borrowBalanceCurrent(address(this));
        uint256 wethDebtRem = IMoonwellMarket($.mWeth).borrowBalanceCurrent(address(this));
        if (cbDebtRem == 0 && wethDebtRem == 0) return;
        // Read Chainlink prices (8dp each) — reached ONLY on a book that still owes after the direct
        // repays, i.e. genuine deep IL. See `redeemUnwindImpl`'s Phase-2 note for what that costs the
        // deadman, and why the phases above it exist to keep this unreached.
        (uint256 pBTC, uint256 pETH, uint256 pUsdc) = _readAllPrices();
        uint256 slip = uint256($.maxSlippageBps);
        // Per-leg USDC budget: the oracle cost grossed up by the CONFIGURED slippage. This same number
        // is the exact-output swap's `amountInMax` below, which is what collapses the two old bounds
        // into one.
        uint256 cbUsdcNeed = _tokenToUsdc(cbDebtRem, $.cbBTCDecimals, pBTC, pUsdc) * (10000 + slip) / 10000;
        uint256 wethUsdcNeed = _tokenToUsdc(wethDebtRem, $.wethDecimals, pETH, pUsdc) * (10000 + slip) / 10000;
        // Dust floor: nonzero debt but oracle cost rounds to 0 (e.g. 1 wei WETH) → fund enough
        // to acquire at least 1 unit of that token.
        if (cbDebtRem > 0 && cbUsdcNeed == 0) cbUsdcNeed = 1e5;
        if (wethDebtRem > 0 && wethUsdcNeed == 0) wethUsdcNeed = 1e5;
        // Fund the buys out of collateral, but only the part the raw balance does not already cover.
        _materialiseUsdc(cbUsdcNeed + wethUsdcNeed);
        // Cover each leg by buying EXACTLY the remaining debt, capped at its own oracle budget, and
        // repaying it. Asset-mode is a structural no-op on the leg-B line (leg B is the unit of account
        // and carries no debt, so `cbDebtRem` is 0 and `_redeemCoverShortfall` guards the identity too).
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
    ///      (`oracle value × (1 − maxSlippageBps)`). One definition for both settle legs; the asset-mode
    ///      identity is handled downstream (`_sweepLegToUsdc` early-returns on the unit of account, where
    ///      the floor is dead arithmetic anyway).
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

    /// @dev The amount `_sweepLegToUsdc(tokenIn, keep, …)` would ACTUALLY sell — the same two gates it
    ///      applies, in the same order (unit-of-account identity ⇒ no swap at all; `bal <= keep` ⇒
    ///      nothing above the stayers' reservation). Exists so the redeem-sweep oracle floor is priced
    ///      on the sold amount rather than the raw balance; keeping it as ONE expression is what stops
    ///      the floor and the swap from drifting apart.
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

        // ACCRUE, *THEN* MEASURE — and here that is what keeps the DEADMAN ORACLE-FREE, not merely what
        // makes the arithmetic exact. `_repay` → `repayBorrow` accrues the market BEFORE it applies the
        // payment, so a repay sized off the STORED index always leaves `current − stored` of interest
        // behind. On a full redeem (`shares == supply`) that dust is the only thing separating
        // `_settleShortfall` from its `cbDebtRem == 0 && wethDebtRem == 0` early return — so every full
        // redeem fell through into Phase 2 and read Chainlink, including `emergencyRedeem`, the exit
        // built for the state where Chainlink is exactly what is unavailable. Reading CURRENT makes the
        // full-redeem repay land on zero and Phase 2 a genuine no-op unless there is real IL.
        // It also fixes the partial case, where the redeemer was repaying `f` of a stale debt.
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

    /// @dev Cover a debt shortfall (IL-driven) by swapping idle USDC → `tokenOut` via
    ///      exactOutputSingle, then repaying the exact remaining amount. `amountInMax` caps the
    ///      USDC spent: the FULL-redeem path passes `type(uint256).max` (→ bounded only by idle USDC,
    ///      oracle-free — no stayers exist, Phase 2 `_settleShortfall` handles any residue); the
    ///      PARTIAL-redeem path passes the redeemer's own budget (`balance − stayersIdle`) so a cover
    ///      that would dip into stayer idle reverts. The permissionless deleverage path passes an
    ///      oracle+slippage ceiling so a sandwiched buy reverts instead of overpaying (H1).
    ///      ASSET-MODE IDENTITY: the unit of account is never bought with itself, and (leg B carrying no
    ///      debt there) never repaid either — return before the router AND before the repay, so a
    ///      would-be `mUsdc.repayBorrow` on the collateral market can never be reached.
    ///      `bestEffort` is the OPPORTUNISTIC-vs-MANDATORY switch (see `LeveragedAeroValuation.swapExactOut`):
    ///      only the full-redeem Phase 1 passes `true`, because only it has a documented next phase.
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
        // An unfilled BEST-EFFORT cover moved nothing (the swap reverted in its own frame and rolled
        // back), so there is nothing bought to repay. Fall through and leave `amountOut` outstanding —
        // that is precisely what the caller's next phase is for.
        if (!filled) return;
        uint256 tokenBal = IERC20(tokenOut).balanceOf(address(this));
        if (tokenBal > 0) {
            IERC20(tokenOut).forceApprove(market, tokenBal);
            _repay(market, tokenBal >= amountOut ? amountOut : tokenBal);
        }
    }

    /// @dev Redeem f = shares/supply of the mUSDC collateral, BY BURNING f OF THE cTOKEN BALANCE.
    ///
    ///      cTOKENS, NOT A STORED-RATE UNDERLYING ESTIMATE, IN BOTH BRANCHES. `redeemUnderlying(amt)`
    ///      accrues and THEN burns `amt / rateFresh`, while `amt` would have been sized off
    ///      `exchangeRateStored` — the last-accrued rate — so the two disagree by the rate gap every
    ///      time. At `f == 1` that gap was cTokens left behind on a zero-share fund, which `nav()`'s
    ///      flat branch prices above zero and gifts to the next depositor (fixed first here, then on the
    ///      fast path in `LeveragedAeroVenue.fastRedeemImpl`). At `f < 1` it is the redeemer's own slice
    ///      of the accrued-but-uncapitalised supply interest, silently retained by the stayers.
    ///
    ///      The old note justified the partial branch as "the payout was priced off the same stored
    ///      rate". That is true of the FAST path, whose draw really is `nav()`-derived — and it is the
    ///      reason `fastRedeemImpl` keeps `redeemUnderlying` for its non-full case. It is NOT true here:
    ///      `redeemUnwindImpl` is a PHYSICAL proportional unwind with no price stamped anywhere, so the
    ///      redeemer's fair share of the collateral is `f` of the cTOKENS, full stop. This form is also
    ///      strictly smaller bytecode — one balance read and one `mulDiv` instead of a rate read, a
    ///      multiply and a second division — which matters at this library's EIP-170 headroom.
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
        // ── Collateral + debt (both USDC face, 6dp) ──
        //
        // ONE definition, shared with `readCollateralDebtImpl` / `deleverageImpl` / `fastRedeemImpl`.
        // This function used to carry a VERBATIM second copy of `_readCollateralDebt`'s body — the
        // same mUSDC `balanceOf × exchangeRateStored`, the same two `borrowBalanceStored` reads, the
        // same `_readAllPrices` + two `_tokenToUsdc` conversions — so the post-op health gate and the
        // LTV the rest of the library steers on agreed only by inspection. They are now the same
        // function, which is also where the EIP-170 bytes for the venue-migration merge came from.
        //
        // The oracle-skip is preserved exactly: `_readCollateralDebt` returns `debt == 0` WITHOUT
        // reading any feed when both borrow balances are zero, so the no-debt case still never touches
        // Chainlink. The single `debtUsd == 0` guard below therefore covers both the original
        // early-returns — genuinely no debt, and dust-level debt that rounds to 0.
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
