// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeveragedAeroManager} from "./LeveragedAeroManager.sol";
import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {IAggregatorV3} from "./sherwood/interfaces/IAggregatorV3.sol";
import {IMoonwellMarket} from "./sherwood/interfaces/IMoonwellMarket.sol";
import {ICLFactory, ICLGauge, ICLPool} from "./sherwood/interfaces/ISlipstream.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LeveragedAeroVenue
/// @notice Venue-migration companion to `LeveragedAerodromeCLStrategy` (delegatecalled, like
///         `LeveragedAeroManager`): the venue-validation block shared by `_initialize` and the
///         owner-staged venue migration, plus the three migration ops — `stageImpl` (owner commits a
///         hash of the destination venue), `flattenImpl` (proposer unwinds the whole book to idle
///         USDC without settling), and `migrateImpl` (proposer executes the staged venue rewrite on a
///         flat book).
///
///         WHY A THIRD LIBRARY: the strategy and the manager both sit within ~350 bytes of the
///         EIP-170 cap, so neither can host new logic. Extracting the init venue block here is what
///         frees the strategy bytes the three new entry-point stubs cost.
///
///         TRUST SPLIT (see the strategy's `stageVenue`/`migrateVenue` docs): the VAULT OWNER alone
///         picks the destination venue (hash-committed, byte-exact); the PROPOSER alone sequences
///         execution. `applyVenue` re-runs every init-grade venue check against live storage, so a
///         staged config that no longer validates (market delisted, feed swapped) reverts rather
///         than migrating into a broken venue.
///
/// @dev CORRUPTION-CRITICAL slot discipline: `Layout`, `RedeemRequest`, `STORAGE_SLOT` and
///      `_layout()` are byte-identical to the strategy's and the manager's copies — see the
///      CORRUPTION-CRITICAL note in `LeveragedAerodromeCLStrategy` and `layout_parity.sh`. Do not
///      touch any of the three copies without the others.
library LeveragedAeroVenue {
    // ── Errors (shared selectors with the strategy / BaseStrategy where names collide) ──
    error ZeroAddress();
    error VenueMismatch(); // pool/gauge/market wiring does not match the declared legs or tickSpacing
    error UnsupportedLeg(); // leg A is the unit of account, or a leg is the gauge reward token
    error UnexpectedFeedDecimals();
    error LegDecimalsOutOfRange(); // a leg token reports decimals outside [2, 18]
    // The RANGE and LTV-band errors (`OutOfBounds`, `TargetLtvExceedsMax`, `MinHealthTooLow`,
    // `MaxLtvExceedsCF`, `MinHealthMaxLtvConflict`) and `ComptrollerCallFailed` are NOT re-declared
    // here: `applyVenue` raises them through `LeveragedAeroValuation`'s copies, which already carry
    // the strategy's selectors. Re-declaring would be a second definition of the same ladder.
    //
    // `TargetLtvZero` IS declared here, and deliberately so: it is not part of that mirrored four-rung
    // band (`checkLtvBand` / `checkRiskParams` carry the same four rungs on both the venue and init
    // routes, and neither carries this one). It is a lower bound `applyVenue` alone enforces — see the
    // rung itself, below the band call.
    error TargetLtvZero(); // targetLtvBps == 0 — a standing target of zero can never lever
    error VenueNotStaged(); // migrate without a staged hash, or params that do not match it
    error BookNotFlat(); // migrate while a CL position, hedged basis, or leg debt is still live
    error PositionAlreadyOpen(); // redeploy on a book that already has a CL position (use deployIdle)
    error ZeroMinOut(); // flatten with a reward balance to sell but no caller floor
    error BelowOracleFloor(); // flatten's reward-swap fill < the AERO/USD oracle floor (L9)
    error InsufficientIdleAfterFlatten(uint256 idle, uint256 minIdle); // caller's aggregate unwind floor

    // ── Events (emitted from the strategy's address via delegatecall) ──
    /// @notice A destination venue hash was staged (or cleared, when `venueHash == 0`) by the vault owner.
    event VenueStaged(bytes32 venueHash);
    /// @notice The whole book was unwound to idle USDC without settling (strategy stays Executed).
    event Flattened(uint256 idleUsdc);
    /// @notice The staged venue rewrite executed on a flat book.
    event VenueMigrated(address indexed oldPool, address indexed newPool);
    /// @notice The fund's STANDING target LTV changed as a side effect of writing a venue — at init, and
    ///         on every `migrateVenue` whose staged params carry a different `targetLtvBps`.
    /// @dev RE-DECLARED, not imported: this is the SAME event `LeveragedAerodromeCLStrategy` declares for
    ///      `setTargetLtv` / `lowerTargetLtv`, with the same signature and therefore the same `topic0`,
    ///      and (like every event above) it is emitted from the STRATEGY's address because this library
    ///      is linked and delegatecalled. A monitor filtering `TargetLtvUpdated` on the clone sees the
    ///      migration-time change in the same stream as the setter-driven ones, with no ABI change on the
    ///      strategy — it already declares this event. Importing the strategy here purely to qualify the
    ///      name would make the strategy↔library import cycle two-way for zero behavioural difference;
    ///      duplicate declaration is already this library's convention (`VenueStaged` et al. are declared
    ///      here and consumed off the strategy ABI).
    ///
    ///      WHY IT MATTERS (review finding): `applyVenue` persists `p.targetLtvBps` unconditionally, and
    ///      `migrateVenue` emits only `VenueMigrated`. Without this, an owner-staged migration could
    ///      silently RESTORE a target the proposer had just ratcheted down with `lowerTargetLtv` —
    ///      authorised (the params are hash-committed by the owner) but invisible to a monitor built on
    ///      `lowerTargetLtv`'s "every step emits `TargetLtvUpdated`" contract.
    event TargetLtvUpdated(uint16 previousBps, uint16 newBps);

    /// @notice The venue subset of the strategy's config — everything a pool/pair change touches.
    ///         Field semantics are LEG SLOTS exactly as in `InitParams` (names historical): `weth*`
    ///         is leg A (the natively-wrappable, always-borrowed slot), `cbBTC*` is leg B (the slot
    ///         that may be the unit of account — that IS asset-mode). The non-migratable core (usdc,
    ///         mUsdc, comptroller, npm, swapRouter, usdcFeed, sequencerFeed, oracle/calm params,
    ///         maxSlippageBps, fee params) is read from live storage, never from here.
    ///
    ///         `aeroUsdFeed` IS part of the venue, deliberately. The gauge is migratable, so
    ///         `gauge.rewardToken()` can change; a feed pinned to its init value would let a migration
    ///         silently price reward token X with AERO's price — mis-scaling the L9 harvest floor (too
    ///         low disables the sandwich guard, too high bricks every `compound`). Carrying it in the
    ///         SAME owner-committed hash as the gauge is what keeps the pair attested together.
    struct VenueParams {
        address mCbBTC; // Moonwell market for leg B (must be mUsdc in asset-mode)
        address mWeth; // Moonwell market for leg A
        address cbBTC; // leg B underlying (== usdc selects asset-mode)
        address weth; // leg A underlying
        address pool; // Aerodrome Slipstream CL pool for the leg A/B pair
        address gauge; // Gauge for the pool (AERO rewards); must report `pool()` == pool
        address cbBTCFeed; // leg B/USD aggregator (must be the USDC/USD feed in asset-mode)
        address wethFeed; // leg A/USD aggregator
        address aeroUsdFeed; // gauge-reward/USD aggregator (8dp) — floors the reward swap (L9)
        int24 tickSpacing; // LP pool tickSpacing (asserted against `pool.tickSpacing()`)
        int24 cbBTCSwapTickSpacing; // leg B↔USDC swap-pool tickSpacing (0 in asset-mode)
        int24 wethSwapTickSpacing; // leg A↔USDC swap-pool tickSpacing
        bool wethDeliversNative; // leg A's Moonwell market pays native ETH on borrow
        uint24 width; // full range width in ticks for the next deploy
        uint24 minWidth; // lower bound for a proposer-supplied rerange width
        uint24 maxWidth; // upper bound for a proposer-supplied rerange width
        uint16 targetLtvBps; // standing target LTV against the new markets
        uint16 maxLtvBps; // LTV cap against the new markets
        uint16 minHealthBps; // health floor against the new markets
    }

    // ── Diamond storage — Layout/STORAGE_SLOT/_layout()/RedeemRequest byte-identical to
    //    `LeveragedAerodromeCLStrategy` and `LeveragedAeroManager` (see the CORRUPTION-CRITICAL
    //    note there and layout_parity.sh). ──

    /// @dev Byte-identical to the strategy's / manager's `RedeemRequest`.
    struct RedeemRequest {
        address owner; // request creator; the only address that can cancel / emergency-redeem it
        uint256 shares; // vault shares escrowed in the strategy at request time
        uint256 minAssetsOut; // slippage floor enforced at fulfill (fresh arg at emergencyRedeem)
        uint40 requestedAt; // request timestamp; FULFILL_WINDOW deadman clock anchor
        bool settled; // set once fulfilled / cancelled / emergency-redeemed (double-spend guard)
    }

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
        // ── appended for the L9 compound oracle floor (keep byte-identical in the strategy/manager) ──
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

    /// @dev The canonical Aerodrome Slipstream CLFactory on Base — the ONE registry allowed to vouch
    ///      for a destination pool. Hardcoded rather than read from `pool.factory()` for the same
    ///      reason `swapAeroToUsdc` hardcodes `AERO_V2_FACTORY`: a self-nominated registry vouches for
    ///      nothing. Canonical immutable Base infra (`AERODROME_CL_FACTORY` in `addresses/8453.json`).
    address private constant AERODROME_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    /// @dev An 8dp reward-token price nothing could plausibly exceed ($10,000 against a ~$1 token),
    ///      used ONLY to derive an oracle-free dust bound in `_sellRewardBalance`. Raising it makes
    ///      that bound narrower (more conservative), never wider — the safe direction.
    uint256 private constant REWARD_PRICE_CEILING_USD8 = 1e12;

    /// @dev ERC-7201 diamond-storage accessor (byte-identical across strategy + manager).
    function _layout() private pure returns (Layout storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // ── Migration ops (auth + state gates live in the strategy's entry points) ──

    /// @notice Stage `venueHash` as the committed destination venue (0 clears). Auth (vault owner)
    ///         is enforced by the strategy's `stageVenue`; staging is inert — no live venue state,
    ///         position, or share pricing changes until `migrateImpl` consumes it.
    function stageImpl(bytes32 venueHash) public {
        _layout().stagedVenueHash = venueHash;
        emit VenueStaged(venueHash);
    }

    /// @notice Unwind the WHOLE book to idle USDC without settling: exit gauge + CL position, repay
    ///         both leg debts (self-funding any shortfall), redeem all mUSDC collateral, sweep
    ///         residual legs to USDC — `LeveragedAeroManager.settleImpl`'s exact unwind — then zero
    ///         the hedged-principal bases the way `_settle` does. UNLIKE `_settle`: no protocol-fee
    ///         discharge (the liability persists, `nav()` stays net of it), no push-to-vault, and no
    ///         state transition — the strategy stays `Executed`, so deposits/redeems keep working
    ///         against the flat book (NAV == idle USDC, no oracle).
    /// @dev Slippage on the unwind swaps is Chainlink-floored inside `settleImpl` via
    ///      `maxSlippageBps` (same guard as a real settle); a down oracle fail-closes the flatten.
    ///      Idempotent on an already-flat book (the unwind and repays are no-ops).
    function flattenImpl(uint256 minRewardUsdcOut, uint256 minIdleUsdcOut) public {
        Layout storage $ = _layout();
        // CALM GATE FIRST — never unwind at a manipulated tick. `settleImpl` has none of its own: it
        // was written for the TERMINAL, owner-driven `settle()`, and `_unwindLiquidity`'s
        // `amount0Min`/`amount1Min` are derived from the same `slot0()` it burns at, so they bind
        // nothing against a shoved pool. `flatten` is proposer-callable and REPEATABLE (redeploy →
        // flatten → …), which is exactly the shape `rerangeImpl` gates against; match it.
        LeveragedAeroValuation.calmGate($.pool, $.twapWindow, $.calmDeviationTicks);
        LeveragedAeroManager.settleImpl();
        // Sell the reward tranche the unwind's `gauge.withdraw` just auto-claimed. WITHOUT this the
        // book keeps a balance that is invisible to `nav()` (the `tokenId == 0` branch prices idle
        // USDC only), unsellable (`compound` early-returns on a flat book) and un-rescuable
        // (`rescueToVault` denies the reward token while Executed) — so every deposit and redeem in
        // the flat window would price against an understated NAV.
        _sellRewardBalance(minRewardUsdcOut, true);
        // Same pathological-case belt as `_settle`: repays drive the bases to 0 through `_repay`'s
        // clamp except when residual debt could not be covered at all — zero them explicitly so a
        // flat book never carries a stale hedge basis into the next venue.
        $.hedgedDebtA = 0;
        $.hedgedDebtB = 0;
        // Caller's aggregate floor on the WHOLE unwind (LP exit + leg sweeps + reward sale). The
        // per-swap oracle floors bound each leg at `maxSlippageBps`, which init permits as wide as
        // 10%; this is the proposer's own bound on the realised total, and the reason `flatten` is no
        // longer the one value-moving entry point on this contract with no caller-supplied guard.
        uint256 idle = IERC20($.usdc).balanceOf(address(this));
        if (idle < minIdleUsdcOut) revert InsufficientIdleAfterFlatten(idle, minIdleUsdcOut);
        emit Flattened(idle);
    }

    /// @notice Sell a reward tranche an unwind auto-claimed, floored by the L9 oracle read ALONE — no
    ///         caller `minOut` is required, so the oracle floor is the whole guard (post-checked against
    ///         the measured fill, exactly as in `flattenImpl`).
    /// @dev TWO CALLERS, ONE CONTRACT. Named neutrally (not `sellSettleReward…`) because both the
    ///      TERMINAL settle and the ASYNC redeem reach it:
    ///
    ///        - `LeveragedAerodromeCLStrategy._settle` — the final tranche, which would otherwise strand
    ///          on a `Settled` strategy instead of reaching the USDC pot `redeemSettled` pays from; and
    ///        - `LeveragedAeroManager.redeemUnwindImpl` — the tranche the redeem's OWN `gauge.withdraw`
    ///          auto-claims mid-flight, which would otherwise be excluded from the redeemer's payout
    ///          while `nav()` prices it.
    ///
    ///      BEST-EFFORT BY CONTRACT — both callers MUST reach this through the self-`try/catch` wrapper
    ///      (`LeveragedAerodromeCLStrategy.sellRewardSelf`), never directly. This function still FAILS
    ///      CLOSED on its own (stale reward feed → `StaleOracle`; a fill under the floor →
    ///      `BelowOracleFloor`), which is what makes the catch safe: the revert unwinds the whole
    ///      sub-call including the swap, so the reward balance is left untouched rather than sold blind.
    ///
    ///      WHY THE ASYMMETRY WITH `flattenImpl`, which calls the same helper fail-closed: `flatten`
    ///      is RESUMABLE — a reverted flatten leaves an `Executed` book the proposer simply retries
    ///      once the feed recovers, so failing closed costs nothing and preserves the caller's floor.
    ///      The two callers here have no such retry. `settle` is TERMINAL and owner-driven (`Executed →
    ///      Settled`, one-way, no argument to widen): a hard revert would let a stale reward feed or a
    ///      reverting router BLOCK the fund's only exit. The async redeem is the DEADMAN path
    ///      (`emergencyRedeem` routes through it precisely for the oracle-down state): a hard revert
    ///      there would convert a value guard into a fund freeze. Both degrade to "leave the tranche
    ///      in place" — the pre-fix behaviour — which is the strictly better failure mode.
    function sellRewardImpl() public {
        _sellRewardBalance(0, false);
    }

    /// @dev Sell the gauge-reward balance to USDC, floored exactly as `compoundImpl`'s harvest is:
    ///      `max(caller minOut, oracle floor)`, where the floor comes from a hardened 8dp read of the
    ///      venue's `aeroUsdFeed` haircut by `maxSlippageBps`, post-checked against the MEASURED fill
    ///      so a dishonest router cannot widen the bound. A stale feed fail-closes the flatten, which
    ///      is the same posture `compound` takes (defer rather than sell blind).
    ///
    ///      No-op when the book holds no reward token — that keeps `flatten` idempotent on an
    ///      already-flat book, and is why `minRewardUsdcOut` is only required to be nonzero when there
    ///      is actually something to sell.
    ///
    ///      DUST NO-OP (and the reason the floor is derived BEFORE the `ZeroMinOut` belt): a balance
    ///      worth less than one micro-USD prices to a ZERO oracle floor, and the router fills it at 0
    ///      USDC. Without this branch every argument reverts — `0` on `ZeroMinOut`, anything nonzero on
    ///      the router's own min-out check — so a 1e6-wei donation to a live book would brick `flatten`
    ///      permanently: `compound` cannot clear it (it early-returns on a flat book and hits this same
    ///      revert on a live one), `rescueToVault` denies the reward token while `Executed`, and
    ///      `migrateVenue`'s flat-book gate then becomes unreachable, leaving terminal `settle()` as the
    ///      only exit. Skipping is safe precisely where the floor rounds to 0: the mandatory-sale
    ///      rationale is that an unsold balance is invisible to `nav()`, and a sub-micro-USD balance
    ///      rounds out of a 6dp NAV by construction.
    /// @param minRewardUsdcOut Caller's own floor on the fill (the oracle floor applies on top).
    /// @param callerFloorRequired Whether a zero `minRewardUsdcOut` is a caller error. TRUE for
    ///        `flatten`, whose proposer supplies one; FALSE for the terminal settle, which has no
    ///        argument to supply and is bounded by the oracle floor alone (see `sellRewardImpl`).
    function _sellRewardBalance(uint256 minRewardUsdcOut, bool callerFloorRequired) private {
        Layout storage $ = _layout();
        address rewardTok = ICLGauge($.gauge).rewardToken();
        uint256 bal = IERC20(rewardTok).balanceOf(address(this));
        if (bal == 0) return;
        // ORACLE-FREE DUST BAND, checked BEFORE the priced one below. The `floor == 0` skip is
        // correct but sits AFTER `readUsd8`, so a dust donation still gates `flatten` on reward-feed
        // staleness / sequencer grace for zero economic benefit — and `flatten` is `migrateVenue`'s
        // own precondition, so a feed outage plus one wei of donated dust stalls a migration.
        // `bal * price8 < 1e20` is what makes the floor round to 0; `REWARD_PRICE_CEILING_USD8`
        // substitutes a price so absurd (`$10,000` against a ~$1 token) that no live read could
        // exceed it, which makes this branch strictly narrower than the priced one — it can only
        // skip balances the priced check would also have skipped.
        //
        // PARTIAL BY CONSTRUCTION, deliberately: this covers only the band that is dust at the
        // CEILING price, so the priced `floor == 0` skip below still carries the rest of the band and
        // still runs after the oracle. Closing the remainder needs the actual price, i.e. a
        // non-reverting `tryReadUsd8` variant — a rewrite of a safety-critical oracle path, which is
        // not worth it for a sub-micro-USD balance.
        if (bal < 1e20 / REWARD_PRICE_CEILING_USD8) return;
        uint256 floor = Math.mulDiv(
            bal, LeveragedAeroValuation.readUsd8($.aeroUsdFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod), 1e20
        ) * (10000 - uint256($.maxSlippageBps)) / 10000;
        if (floor == 0) return; // dust: unsellable, and worth strictly less than one NAV unit
        if (callerFloorRequired && minRewardUsdcOut == 0) revert ZeroMinOut();
        uint256 usdcOut = LeveragedAeroValuation.swapAeroToUsdc(rewardTok, $.usdc, bal, minRewardUsdcOut);
        if (usdcOut < floor) revert BelowOracleFloor();
    }

    /// @notice Execute the staged venue rewrite: verify `p` byte-matches the owner-staged hash,
    ///         verify the book is FLAT (no CL position, no hedged basis, no live debt on either
    ///         current leg market), re-run the full init-grade venue validation against `p`, rewrite
    ///         the venue subset of storage, and consume the staged hash. Value-neutral by
    ///         construction: on a flat book NAV is the idle USDC balance, which no venue field
    ///         touches — share pricing is continuous across the rewrite.
    /// @dev The flat-book gate reads only strategy-internal state and the two CURRENT leg markets'
    ///      `borrowBalanceStored` (exact after a full repay: zero principal reads zero at any index).
    ///      Deliberately NOT gated on residual collateral or token balances — those are rescuable /
    ///      re-deployable and a 1-wei donation must not brick a migration.
    function migrateImpl(VenueParams memory p) public {
        Layout storage $ = _layout();
        bytes32 staged = $.stagedVenueHash;
        if (staged == bytes32(0) || keccak256(abi.encode(p)) != staged) revert VenueNotStaged();
        if ($.tokenId != 0 || $.hedgedDebtA != 0 || $.hedgedDebtB != 0) revert BookNotFlat();
        if (IMoonwellMarket($.mCbBTC).borrowBalanceStored(address(this)) != 0) revert BookNotFlat();
        if (IMoonwellMarket($.mWeth).borrowBalanceStored(address(this)) != 0) revert BookNotFlat();
        address oldPool = $.pool;
        applyVenue(p);
        $.stagedVenueHash = bytes32(0);
        emit VenueMigrated(oldPool, p.pool);
    }

    /// @notice Open a FRESH position from a flat `Executed` book (the migration's last leg, and the
    ///         recovery from any flatten): `LeveragedAeroManager.executeImpl`'s exact genesis
    ///         sequence — enterMarkets (idempotent), calm-gate, centred range at the stored width,
    ///         supply + borrow at the stored target LTV, mint + stake, health assert — deploying the
    ///         strategy's ENTIRE idle USDC balance.
    /// @dev `deployIdle` cannot serve this state: it `increaseLiquidity`s the stored `tokenId`,
    ///      which is 0 on a flat book (a real gauge/NPM reverts on it). Conversely this path is
    ///      fresh-mint ONLY — with a live position it would double-open, so it reverts
    ///      `PositionAlreadyOpen` and the caller routes to `deployIdle`. Slippage posture matches
    ///      the activation genesis: calm-gate up front plus the §8 two-sided `maxSlippageBps` floor
    ///      inside the mint, PLUS the caller's `minLiquidity` — which `execute` does not take. The
    ///      asymmetry is deliberate: `execute` runs once at activation on a seed-only book, whereas
    ///      this re-enters the WHOLE book repeatedly against live depositors, and the in-mint mins are
    ///      derived from the same `slot0()` the mint executes at (self-referential, the exact
    ///      criticism `flattenImpl`'s own comment makes of `settleImpl`'s unwind mins).
    ///
    ///      CONSUMES ANY STAGED HASH. A `flatten → redeploy` round trip is the documented ROLLBACK of
    ///      an aborted migration, and leaving the destination hash armed afterwards would let the
    ///      proposer fire an owner authorization months later into conditions nobody re-evaluated —
    ///      the same replay the migrate path closes by clearing on consume. Re-staging is one owner
    ///      call, so the cost of being wrong here is asymmetric in the safe direction.
    /// @param minLiquidity Minimum CL liquidity the fresh mint must produce (slippage guard).
    function redeployImpl(uint256 minLiquidity) public {
        Layout storage $ = _layout();
        if ($.tokenId != 0) revert PositionAlreadyOpen();
        if ($.stagedVenueHash != bytes32(0)) {
            $.stagedVenueHash = bytes32(0);
            emit VenueStaged(bytes32(0));
        }
        LeveragedAeroManager.executeImpl(minLiquidity);
    }

    // ── Shared venue validation + store (init AND migrate) ──

    /// @notice Validate `p` to the exact standard `_initialize` enforced in-line before this block
    ///         was extracted, then persist the venue subset of `Layout`. Reads the non-migratable
    ///         core (usdc, mUsdc, usdcFeed, comptroller) from live storage — at init the strategy
    ///         stores those BEFORE calling here; at migrate they are the live values by definition.
    ///         Check order mirrors the original `_initialize` so the same input reverts with the
    ///         same error; the one ADDITION is the `gauge.pool() == pool` binding check (absent at
    ///         the original init, where the deployer was trusted on gauge wiring — load-bearing once
    ///         a runtime migration can point at a fresh gauge, and it hardens init for free).
    function applyVenue(VenueParams memory p) public {
        Layout storage $ = _layout();
        address usdc = $.usdc;
        address mUsdc = $.mUsdc;

        if (p.mCbBTC == address(0)) revert ZeroAddress();
        if (p.mWeth == address(0)) revert ZeroAddress();
        if (p.cbBTC == address(0)) revert ZeroAddress();
        if (p.weth == address(0)) revert ZeroAddress();
        if (p.pool == address(0)) revert ZeroAddress();
        if (p.gauge == address(0)) revert ZeroAddress();
        if (p.cbBTCFeed == address(0)) revert ZeroAddress();
        if (p.wethFeed == address(0)) revert ZeroAddress();
        if (p.aeroUsdFeed == address(0)) revert ZeroAddress();
        // L9: the reward-token floor scales an 8dp price (`mulDiv(bal, price8, 1e20)`); a non-8dp
        // aggregator would silently mis-scale it by orders of magnitude. Checked here (not at read
        // time like the leg feeds) because the floor consumes the raw answer.
        if (IAggregatorV3(p.aeroUsdFeed).decimals() != 8) revert UnexpectedFeedDecimals();
        // The LEG feeds, checked here for the same reason and not only at read time. `readUsd8` does
        // reject a non-8dp answer (`FeedDecimalsMismatch`), so this is fail-closed either way — but it
        // fails at the wrong MOMENT: an 18dp leg feed migrates cleanly and then bricks `redeploy` and
        // every priced op on the new venue, recoverable only by re-staging. Rejecting a bad parameter
        // set at validation time is strictly better than adopting it and discovering it later.
        if (IAggregatorV3(p.wethFeed).decimals() != 8) revert UnexpectedFeedDecimals();
        if (IAggregatorV3(p.cbBTCFeed).decimals() != 8) revert UnexpectedFeedDecimals();

        // ── SHAPE DERIVATION — the ONE line that selects the pool shape (see `_initialize`) ──
        bool legBIsAsset_ = p.cbBTC == usdc;

        // Venue identity: the pool must BE the declared leg pair at the declared spacing, and each
        // Moonwell borrow market must wrap its declared leg. Ordering is DERIVED here, never assumed.
        if (ICLPool(p.pool).tickSpacing() != p.tickSpacing) revert VenueMismatch();
        address t0 = ICLPool(p.pool).token0();
        bool wethIsToken0_ = t0 == p.weth;
        if (!wethIsToken0_ && t0 != p.cbBTC) revert VenueMismatch();
        if (ICLPool(p.pool).token1() != (wethIsToken0_ ? p.cbBTC : p.weth)) revert VenueMismatch();
        if (IMoonwellMarket(p.mCbBTC).underlying() != p.cbBTC) revert VenueMismatch();
        if (IMoonwellMarket(p.mWeth).underlying() != p.weth) revert VenueMismatch();
        // Symmetric with the two borrow legs: the collateral market must wrap the unit of account.
        if (IMoonwellMarket(mUsdc).underlying() != usdc) revert VenueMismatch();
        // CANONICAL FACTORY BINDING. The pool no longer gets to nominate the registry that vouches
        // for it. `pool.factory()` is SELF-ATTESTED — exactly the seam the `gauge.pool()` reciprocal
        // below closes for the gauge — so a hostile pool paired with a hostile "factory" satisfies
        // every probe below for free: the factory answers with whatever the attacker wants for the
        // two leg↔USDC lookups, and nothing else here re-derives the LP pool's provenance. Pinning
        // the real Slipstream CLFactory and requiring it to REGISTER `p.pool` at the declared pair +
        // spacing means the attacker must control the canonical factory, not merely deploy a pool.
        // Mirrors the treatment `swapAeroToUsdc`'s reward route already gets (hardcoded
        // `AERO_V2_FACTORY`), removing the asymmetry between the two.
        if (ICLPool(p.pool).factory() != AERODROME_CL_FACTORY) revert VenueMismatch();
        if (ICLFactory(AERODROME_CL_FACTORY).getPool(p.weth, p.cbBTC, p.tickSpacing) != p.pool) {
            revert VenueMismatch();
        }
        address clFactory = AERODROME_CL_FACTORY;
        if (legBIsAsset_) {
            // ── ASSET-MODE: the three leg-B slots that only make sense for a BORROWED leg ──
            // (see the numbered rationale in `_initialize`'s original block)
            if (p.mCbBTC != mUsdc) revert VenueMismatch();
            if (p.cbBTCSwapTickSpacing != 0) revert VenueMismatch();
            if (p.cbBTCFeed != $.usdcFeed) revert VenueMismatch();
        } else {
            if (p.cbBTCSwapTickSpacing <= 0) revert VenueMismatch();
            if (ICLFactory(clFactory).getPool(usdc, p.cbBTC, p.cbBTCSwapTickSpacing) == address(0)) {
                revert VenueMismatch();
            }
        }
        // Leg A is a real borrowed leg in BOTH shapes, so its swap venue is checked unconditionally.
        if (p.wethSwapTickSpacing <= 0) revert VenueMismatch();
        if (ICLFactory(clFactory).getPool(usdc, p.weth, p.wethSwapTickSpacing) == address(0)) {
            revert VenueMismatch();
        }

        // Gauge↔pool binding (the ADDED check): a gauge that is not the pool's gauge would strand
        // the staked NFT (`gauge.withdraw` on a gauge that never held it) or burn every reward.
        //
        // BOTH DIRECTIONS, and the second one is the load-bearing one. `gauge.pool()` is SELF-ATTESTED
        // by the staged contract: a hostile gauge returns the real pool's address for free, passes this
        // check, and then receives the freshly minted position NFT at `redeploy`. The pool's own
        // `gauge()` is not forgeable the same way — on a real Slipstream pool it is written by the
        // Aerodrome Voter at gauge creation, so requiring the pair to agree means an attacker must
        // already control the pool, not merely the gauge. That is a strictly smaller residual, and it
        // is the reciprocal check the vendored `ISlipstream.ICLPool` already declares.
        if (ICLGauge(p.gauge).pool() != p.pool) revert VenueMismatch();
        if (ICLPool(p.pool).gauge() != p.gauge) revert VenueMismatch();

        // TWAP AVAILABILITY. `calmGate` reads `pool.observe([twapWindow, 0])`, and a Slipstream pool
        // whose oracle cardinality does not yet span `twapWindow` REVERTS that read. Every gated path
        // on the destination — `redeploy`, `rerange`, and `flatten` itself — would then revert, i.e. a
        // pool younger than the window is adoptable but neither usable nor exitable. Probe it here so
        // that becomes a rejected MIGRATE instead of a stuck fund. `twapWindow` is non-migratable
        // core, so the value probed is the one the gate will use.
        //
        // WHEN, precisely: `stageVenue` stores a hash and validates NOTHING — every check in this
        // function runs at `migrateVenue`, on a book the proposer has already flattened. So a bad
        // parameter set is caught after the flatten, not before it. Say so plainly: an operator who
        // reads "rejected at stage time" will flatten first and then eat the revert.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = $.twapWindow;
        try ICLPool(p.pool).observe(secondsAgos) returns (int56[] memory, uint160[] memory) {}
        catch {
            revert VenueMismatch();
        }

        // Reject legs that break an accounting invariant (see `_initialize`'s original block).
        address rewardTok = ICLGauge(p.gauge).rewardToken();
        if (p.weth == usdc || p.weth == rewardTok || p.cbBTC == rewardTok) {
            revert UnsupportedLeg();
        }
        // `compoundImpl`'s oracle floor hardcodes an 18dp reward token against an 8dp feed.
        if (IERC20Metadata(rewardTok).decimals() != 18) revert UnexpectedFeedDecimals();
        // The reward leg is a THIRD swap venue, distinct from the LP pool and the two leg↔USDC CL
        // pools probed above, and `swapAeroToUsdc` hardcodes its route (Aerodrome v2, volatile).
        // Probe it for the same reason: a gauge whose reward token has no v2/USDC pool passes every
        // other check here and then reverts inside BOTH `compound` and `flatten` the moment a tranche
        // accrues — and `flatten` is the migration's own precondition, so the fund would be stuck on a
        // venue it cannot unwind. Rejecting at MIGRATE time turns that into a rejected parameter set
        // (see the timing note on the observe probe above — nothing is validated at stage time).
        if (LeveragedAeroValuation.aeroV2VolatilePool(rewardTok, usdc) == address(0)) revert VenueMismatch();

        // Leg decimals drive every token↔USDC conversion — read them, never assume.
        uint8 cbDec = IERC20Metadata(p.cbBTC).decimals();
        uint8 wethDec = IERC20Metadata(p.weth).decimals();
        if (cbDec < 2 || cbDec > 18 || wethDec < 2 || wethDec > 18) revert LegDecimalsOutOfRange();

        // ── RANGE LADDER — ONE copy, in `LeveragedAeroValuation`, shared with the strategy's per-cycle
        // `rerange`. `checkBands` is the destination band's own shape (both bounds on the new grid,
        // floor ≥ two spacings, ceiling inside the tick domain, and `0 < minSkew <= maxSkew < 1e4`);
        // `checkRange` is the pair that will actually be minted at `redeploy`.
        //
        // THE SKEW COMES FROM STORAGE, not from `p`: the skew band is venue-independent governance
        // config (non-migratable core, like `maxSlippageBps` and the fee params), so a migration never
        // rewrites it. It still has to be RE-VALIDATED here, because `checkRange`'s one-spacing-per-side
        // span guard couples the live skew to `(width, tickSpacing)` and a migration rewrites both: a
        // destination whose grid or width would starve one side is rejected HERE, rather than adopted
        // and then discovered as a `DegenerateRange` inside `redeploy`, with the book already flat on a
        // venue it cannot re-enter. At init the strategy writes the triple ahead of this call for
        // exactly this reason. Raises `OutOfBounds` (the renamed `WidthOutOfBounds`, now covering both
        // knobs) — same selector a `rerange` would raise for the same pair.
        LeveragedAeroValuation.checkBands(p.tickSpacing, p.minWidth, p.maxWidth, $.minSkewBps, $.maxSkewBps);
        LeveragedAeroValuation.checkRange(
            p.width, $.skewBps, p.tickSpacing, p.minWidth, p.maxWidth, $.minSkewBps, $.maxSkewBps
        );

        // Risk invariants against the LIVE collateral factor (re-read here — fresher than init's).
        // Both the read and the four rungs are the Valuation copies, shared with the init ladder.
        uint16 cfBps = LeveragedAeroValuation.readCollateralFactor($.comptroller, mUsdc);
        // Lower bound as well as upper, and the ONLY rung of the band that is not mirrored in the init
        // ladder. `applyVenue` is the SHARED route for both `_initialize` and `migrateVenue`, so this
        // one check closes every path to a stored zero target that does not go through `setTargetLtv`.
        // A zero standing target is not a brick (a zero target borrows nothing, so `debtUsdc == 0` and
        // the full-unwind branch is unreachable — and `_leverDown` guards it anyway via
        // `FullUnwindNotSupported`) but it IS a fund that can silently never lever. It stays HERE rather
        // than inside `checkLtvBand` so the venue and init copies of that band remain the same four
        // rungs in the same order.
        if (p.targetLtvBps == 0) revert TargetLtvZero();
        LeveragedAeroValuation.checkLtvBand(p.targetLtvBps, p.maxLtvBps, p.minHealthBps, cfBps);

        // ── Persist the venue subset (every field a pool/pair change touches, nothing else) ──
        $.mCbBTC = p.mCbBTC;
        $.mWeth = p.mWeth;
        $.cbBTC = p.cbBTC;
        $.weth = p.weth;
        $.pool = p.pool;
        $.gauge = p.gauge;
        $.cbBTCFeed = p.cbBTCFeed;
        $.wethFeed = p.wethFeed;
        $.aeroUsdFeed = p.aeroUsdFeed;
        $.tickSpacing = p.tickSpacing;
        $.cbBTCSwapTickSpacing = p.cbBTCSwapTickSpacing;
        $.wethSwapTickSpacing = p.wethSwapTickSpacing;
        $.wethDeliversNative = p.wethDeliversNative;
        $.width = p.width;
        $.minWidth = p.minWidth;
        $.maxWidth = p.maxWidth;
        // The target LTV is the one venue field that is also POLICY — the strategy exposes two setters
        // for it and documents them as loud. Announce it here too, or a migration becomes the one route
        // that moves the fund's leverage policy in silence (see `TargetLtvUpdated` above). Guarded on
        // inequality: a migration that carries the SAME target stays quiet, so the event means "policy
        // moved", never "a migration happened" (`VenueMigrated` already says that). At init the guard is
        // trivially true (previous is 0), so a clone's opening policy is announced as well — a monitor
        // can bootstrap the target from the log stream alone, with no init-time special case.
        if ($.targetLtvBps != p.targetLtvBps) emit TargetLtvUpdated($.targetLtvBps, p.targetLtvBps);
        $.targetLtvBps = p.targetLtvBps;
        $.maxLtvBps = p.maxLtvBps;
        $.minHealthBps = p.minHealthBps;
        $.usdcCollateralFactorBps = cfBps;
        $.cbBTCDecimals = cbDec;
        $.wethDecimals = wethDec;
        $.wethIsToken0 = wethIsToken0_;
        $.legBIsAsset = legBIsAsset_;
    }
}
