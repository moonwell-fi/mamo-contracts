// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeveragedAeroManager} from "./LeveragedAeroManager.sol";
import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {LeveragedAerodromeCLStrategy} from "./LeveragedAerodromeCLStrategy.sol";
import {IAggregatorV3} from "./sherwood/interfaces/IAggregatorV3.sol";
import {ICToken, IComptroller, IMoonwellMarket} from "./sherwood/interfaces/IMoonwellMarket.sol";
import {ICLFactory, ICLGauge, ICLPool} from "./sherwood/interfaces/ISlipstream.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
///         frees the strategy bytes the three new entry-point stubs cost. Two later relocations ride
///         the same rationale and sit at the bottom of this file — `layoutView` (the body of the
///         strategy's `layout()`) and `applyVenueFromInit` (the strategy's `_venueParamsOf`
///         marshalling). Neither is venue logic; both are here because this is where the bytes are.
///
///         IMPORT CYCLE, DELIBERATE AND TYPES-ONLY: those two carry `LeveragedAerodromeCLStrategy`'s
///         `LayoutView` / `InitParams` in their signatures, so this file imports the strategy that
///         imports it. Solidity permits import cycles (only inheritance cycles are illegal), and
///         nothing here calls, inherits from, or links against the strategy — the import buys two
///         struct declarations. Leaving those structs declared in the strategy is what keeps the
///         relocations ABI- AND SOURCE-compatible: `layout()` still returns
///         `LeveragedAerodromeCLStrategy.LayoutView`, so no caller and no test changed.
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
    using SafeERC20 for IERC20;

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
    error MoonwellMintFailed(uint256 errCode); // selector mirrors the strategy's / the manager's
    error MoonwellRedeemFailed(uint256 errCode); // selector mirrors the manager's
    error InsufficientIdle(); // selector mirrors the strategy's / the manager's
    error FastRedeemExceedsLtv(uint256 ltvBps, uint256 maxLtvBps); // selector mirrors the strategy's
    error ComptrollerCallFailed(); // selector mirrors the strategy's / the valuation's

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

    /// @notice `withdrawIdle` could not read the hardened oracle its POLICY bound is normally priced
    ///         in, so the SAME target-LTV bound was re-derived from Moonwell's own account snapshot
    ///         (`_unleveredAtVenueOracle`) for that call. The op still happened, inside a bound — what
    ///         degraded is the PRICE BASIS (the venue's un-gated oracle rather than our
    ///         staleness/sequencer-hardened reader), not the line itself. A monitor should treat a
    ///         burst of these as "the proposer moved collateral while the feeds were down" and
    ///         reconcile LTV once they recover. Same posture, and the same marker discipline, as
    ///         `RedeemSweepFloorsDegraded`.
    event WithdrawIdleBoundDegraded();

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

    // ── Idle supply ("no idle USDC sits dead") ──

    /// @notice Supply `amount` of the strategy's raw USDC to Moonwell as collateral — the body of the
    ///         proposer's `LeveragedAerodromeCLStrategy.supplyIdle`.
    /// @dev THE "NO IDLE USDC SITS DEAD" ENTRYPOINT. Idle USDC used to sit as a raw ERC-20 balance
    ///      earning nothing until a proposer levered it; the keeper can now park it in mUSDC, where it
    ///      earns supply interest whether or not it is levered. The move is value-neutral to `nav()` —
    ///      the amount leaves the raw-balance term and enters the collateral term at
    ///      `exchangeRateStored`, and BOTH branches of `nav()` count both terms (the flat branch counts
    ///      the collateral one precisely because this op can run on a flat book).
    ///
    ///      SUPPLIED-BUT-UNLEVERED COLLATERAL IS LEVERAGEABLE, BY POLICY. There is no buffer/book
    ///      distinction in `Layout` and `LeveragedAeroManager._readCollateralDebt` is untouched, so
    ///      `adjustLeverage` sees the grown collateral base and levers the WHOLE book to
    ///      `targetLtvBps`. That is the intended behaviour, not a leak.
    ///
    ///      FAIL-CLOSED, and cheap to be: a Moonwell mint that errors (market paused, supply cap
    ///      reached) reverts with the market's own code and moves nothing. On a KEEPER op that is a
    ///      retry, not a user-facing failure — which is the whole reason this is not part of `deposit`.
    ///      Putting it there would have let Moonwell's supply cap decide whether the fund can take
    ///      money at all, and would have needed a `try/catch` to be safe; here it needs neither. See
    ///      the entrypoint's docs for the second reason (the raw redeem-cover float).
    ///
    ///      No `enterMarkets` here: `LeveragedAeroManager.executeImpl` entered mUSDC at activation and
    ///      market entry is permanent, and the entrypoint is gated on `State.Executed`, so it has
    ///      provably run. This lives in THIS library, not the manager, purely for EIP-170 headroom —
    ///      the manager is the one at the cap, and this is a two-call venue op with no manager-private
    ///      dependency.
    function supplyIdleImpl(uint256 amount) public {
        if (amount == 0) return;
        Layout storage $ = _layout();
        // The bound lives HERE, next to the mint it protects (the entrypoint carries only auth + the
        // lifecycle gate — EIP-170 pressure on the strategy, same rationale as the rest of this file).
        if (amount > IERC20($.usdc).balanceOf(address(this))) revert InsufficientIdle();
        IERC20($.usdc).forceApprove($.mUsdc, amount);
        uint256 err = ICToken($.mUsdc).mint(amount);
        if (err != 0) revert MoonwellMintFailed(err);
    }

    /// @notice Redeem `amount` of raw USDC out of the strategy's mUSDC collateral — the body of the
    ///         proposer's `LeveragedAerodromeCLStrategy.withdrawIdle`, the exact inverse of
    ///         `supplyIdleImpl`.
    /// @dev THE DIAL TURNS BOTH WAYS. `supplyIdle`'s trade-off — supplied USDC earns, raw USDC is the
    ///      oracle-free IL-cover budget `redeemUnwindImpl` Phase 1 (and so the `emergencyRedeem`
    ///      deadman) spends — is only an operator POLICY if the operator can move it in both
    ///      directions. Without this op a keeper who over-parked could restore the raw float only by
    ///      levering the book (`deployIdle`) or exiting the venue entirely (`flatten`); with it,
    ///      re-sizing the float is the same class of keeper action as parking it.
    ///
    ///      AUTH LIVES IN THE STRATEGY ENTRYPOINT; THE BOUND LIVES HERE: `amount` is restricted to
    ///      the UN-LEVERED collateral (`_unleveredCollateral`), so the op can never push LTV above
    ///      the standing target — the same discipline `checkDeployableIdle` enforces on the way
    ///      in. FAIL-CLOSED on the venue: a redeem the market's cash (or Moonwell's own collateral
    ///      check) cannot cover reverts `MoonwellRedeemFailed(err)` with nothing moved.
    ///
    ///      TWO BELTS, AND THEY ARE NOT THE SAME BELT — which is why the oracle-dependent one degrades
    ///      instead of blocking. The bound above is the STRATEGY'S POLICY (post-op LTV stays at the
    ///      admin-set `targetLtvBps`) and it is priced in Chainlink. Underneath it, Moonwell runs its
    ///      OWN check on every redeem out of an entered market with live borrows — the account's
    ///      hypothetical liquidity — and refuses at its collateral factor, which `_redeemUnderlying`
    ///      surfaces as `MoonwellRedeemFailed`. Solvency therefore never depends on our feed; only the
    ///      tighter policy line does.
    ///
    ///      SO A DOWN FEED DEGRADES THIS OP, IT DOES NOT JAM IT. `_unleveredCollateral` reads three
    ///      Chainlink feeds whenever there IS debt (a zero-debt book short-circuits and reads none), and
    ///      each read fail-closes. That made the RESTORE direction of the `supplyIdle` dial — the one
    ///      that rebuilds the oracle-free raw float `redeemUnwindImpl` Phase 1 and the `emergencyRedeem`
    ///      deadman spend from — unavailable in exactly the outage where an operator most wants raw
    ///      USDC on hand, while the PARK direction (`supplyIdle`, raw balance only) stayed available.
    ///      The read is now try-able through the strategy's `previewCollateralDebt` self-view: readable
    ///      feeds enforce the policy bound exactly as before; an unreadable one emits
    ///      `WithdrawIdleBoundDegraded` and leans on Moonwell's own check for that call.
    ///
    ///      WHAT THE DEGRADED PATH GIVES UP — the ORACLE BASIS, not the bound. An earlier revision
    ///      dropped the policy bound entirely on the catch path and leaned on Moonwell's collateral
    ///      factor alone; that line (CF, live 8800 bps) sits ABOVE `maxLtvBps`, so during an outage the
    ///      `onlyProposer` key could walk the book from target to the CF edge in one call — a book with
    ///      ZERO price cushion (the first adverse leg tick is a Moonwell shortfall, and liquidation at
    ///      the 10% incentive is the loss vector), sitting where it also ARMS the permissionless
    ///      `deleverage` valve — exactly the risk-escalation capability the admin-only target split
    ///      denies that key, and the reason `checkDeployableIdle` is not degraded. The catch path now
    ///      re-derives THE SAME target-LTV bound from the venue's own books instead
    ///      (`_unleveredAtVenueOracle`): Moonwell's plain ChainlinkOracle carries no heartbeat or
    ///      sequencer gate, so it keeps answering through exactly the staleness outages that make our
    ///      hardened reader refuse. The residual is honest and small: during the outage the line is
    ///      held at the venue's (possibly stale) prices — the same prices its liquidation engine uses —
    ///      rather than at truth.
    ///
    ///      NOT APPLIED TO `checkDeployableIdle`, deliberately: that bound gates `deployIdle`, which
    ///      LEVERS UP. Degrading a lever-up bound during an oracle outage would let the keeper add debt
    ///      blind. Availability is only the right trade on the direction that cannot add debt.
    function withdrawIdleImpl(uint256 amount) public {
        if (amount == 0) return;
        try LeveragedAerodromeCLStrategy(payable(address(this))).previewCollateralDebt() returns (
            uint256 collateralUsdc, uint256 debtUsdc
        ) {
            if (amount > _unleveredFrom(collateralUsdc, debtUsdc)) revert InsufficientIdle();
        } catch {
            // Policy unpriceable at OUR oracle → hold the SAME line at the venue's. Marked, not
            // silent: a `view` cannot emit, but this op is a transaction and can. (The marker fires
            // only when the degraded call PROCEEDS — a refusal rolls the log back with the state.)
            if (amount > _unleveredAtVenueOracle()) revert InsufficientIdle();
            emit WithdrawIdleBoundDegraded();
        }
        _redeemUnderlying(_layout().mUsdc, amount);
    }

    /// @dev THE DEGRADED BOUND'S BASIS: the un-levered collateral re-derived from Moonwell's own
    ///      account snapshot, no hardened-Chainlink read anywhere on the path.
    ///
    ///      With USDC the sole collateral, `getAccountLiquidity` returns (18dp USD, venue oracle)
    ///        liquidity = C·CF − D   (or shortfall = D − C·CF when negative)
    ///      so the venue-priced debt is `D = C·CF − liquidity + shortfall`, with `C` read oracle-free
    ///      off the cToken books (`balanceOf × exchangeRateStored`, the same stored basis the
    ///      comptroller snapshot uses) and USDC taken at face. The USDC term is the one approximation:
    ///      Moonwell prices USDC at its real feed (≈ $1), so a DEpeg overstates `D` here — a TIGHTER
    ///      bound, the safe direction; the loose direction needs USDC > $1, bounded by bps of drift.
    ///
    ///      CF IS READ LIVE (`readCollateralFactor`), NOT from `Layout.usdcCollateralFactorBps`: the
    ///      stored copy is written once at init and consumed nowhere at runtime, and a governance CF
    ///      RAISE after init would make a stored-CF bound quietly looser than policy. Both reads fail
    ///      closed (`ComptrollerCallFailed`) — if even the venue cannot answer, the op reverts, which
    ///      is the pre-degrade behaviour and the right answer when nothing can price the book.
    function _unleveredAtVenueOracle() private view returns (uint256) {
        Layout storage $ = _layout();
        uint256 c = (ICToken($.mUsdc).balanceOf(address(this)) * ICToken($.mUsdc).exchangeRateStored()) / 1e18;
        uint256 cf = uint256(LeveragedAeroValuation.readCollateralFactor($.comptroller, $.mUsdc));
        (uint256 err, uint256 liquidity, uint256 shortfall) =
            IComptroller($.comptroller).getAccountLiquidity(address(this));
        if (err != 0) revert ComptrollerCallFailed();
        uint256 dVenue = (c * cf) / 10_000 + shortfall / 1e12;
        uint256 liqFace = liquidity / 1e12; // 18dp USD → 6dp USDC face at $1
        dVenue = dVenue > liqFace ? dVenue - liqFace : 0;
        return _unleveredFrom(c, dVenue);
    }

    /// @notice Oracle-priced fast-redeem funding (body of the strategy's `redeem`): source `assetsOut`
    ///         USDC from the redeemer's pro-rata idle share FIRST, then free only the remainder from the
    ///         Moonwell mUSDC collateral — no LP touch, no debt repay. `idleShare = f×idle` (f =
    ///         shares/supply, computed by the strategy) caps the idle draw so a partial redeem never
    ///         dips into a stayer's `(1-f)×idle` (the same reservation `redeemUnwindImpl` makes). The
    ///         LTV gate is computed BEFORE the withdraw on the same `_readCollateralDebt` basis as
    ///         `_assertHealthy`, but against the collateral-funded REMAINDER only: a redeem that would
    ///         push post-withdraw LTV above `maxLtvBps` reverts `FastRedeemExceedsLtv` (a typed,
    ///         frontend-routable error — send the user to `requestRedeem`), and `assertHealthyImpl()`
    ///         runs after as belt. When idle alone covers `assetsOut` (e.g. a flat book), no collateral
    ///         is touched and the LTV gate is skipped. The strategy pays the redeemer + burns shares;
    ///         the idle already held plus the freed collateral cover the payout.
    /// @dev RELOCATED from `LeveragedAeroManager` verbatim (manager at the EIP-170 cap — same rationale
    ///      as everything else in this file); the two manager-private dependencies became the public
    ///      `readCollateralDebtImpl` / `assertHealthyImpl`, both delegatecalled against the same
    ///      strategy storage, so behaviour is unchanged.
    function fastRedeemImpl(uint256 assetsOut, uint256 idleShare, bool isFullRedeem) public returns (uint256 payout) {
        Layout storage $ = _layout();
        payout = assetsOut;
        // A FULL fast redeem is ONLY served on a FLAT book, and the refusal is explicit rather than a
        // property hoped for from the gates below. With live DEBT the LTV gate refuses anyway (the
        // draw is the whole book, the denominator collapses). But with a live LP and ZERO debt —
        // reachable under our feet, since `repayBorrowBehalf` is permissionless — a large enough
        // `protocolFeeOwed` shrinks `fromCollateral` back inside the collateral and the gate PASSES,
        // burning the last shares while the LP NFT stays live: a fund with assets and no shares, a
        // state no exit may create. The async path (`requestRedeem` → full unwind) is the exit that
        // disposes of the position; the sentinel error is the documented "route to requestRedeem"
        // signal the frontend already handles.
        if (isFullRedeem && $.tokenId != 0) revert FastRedeemExceedsLtv(type(uint256).max, uint256($.maxLtvBps));
        // Idle-first: draw at most the redeemer's `f×idle` share (also clamped to the live balance);
        // the strategy's payout transfer consumes it implicitly, leaving `(1-f)×idle` for stayers.
        uint256 fromCollateral = _fromCollateral(assetsOut, idleShare, IERC20($.usdc).balanceOf(address(this)));
        // Idle alone covers it → no collateral touched, NO collateral/debt read at all. Keeping this
        // early-return ahead of `readCollateralDebtImpl` is what keeps an idle-funded redeem free of
        // any oracle dependency; moving it into `_fastGate` would silently add one.
        //
        // EXCEPT for a FULL redeem while parked cTokens remain. `fromCollateral == 0` on a full
        // redeem means the raw balance covers the whole FEE-NETTED payout — i.e. `owed ≥ collateral`
        // — and returning here would burn the last shares with 100% of the cToken balance stranded,
        // a strictly larger residue than the rate-gap dust the burn branch below exists to close.
        // Falling through costs no oracle read: the book is flat (guard above) so
        // `readCollateralDebtImpl` short-circuits before any feed. Full redeems of a book with
        // NOTHING parked keep the early out — there is nothing to strand.
        if (fromCollateral == 0 && !(isFullRedeem && ICToken($.mUsdc).balanceOf(address(this)) > 0)) {
            return payout;
        }

        (uint256 collateralUsdc, uint256 debtUsdc) = LeveragedAeroManager.readCollateralDebtImpl();
        uint256 maxLtv = uint256($.maxLtvBps);
        (bool ok, uint256 postLtv) = _fastGate(fromCollateral, collateralUsdc, debtUsdc, maxLtv);
        // THE TYPED ERROR IS FOR LTV BREACHES, and only those. A zero-debt over-draw is not an LTV
        // breach — there is no LTV — it is "the collateral cannot cover this", and Moonwell is the
        // authority on that: the draw falls through to `_redeemUnderlying`, which fails closed with
        // `MoonwellRedeemFailed(err)`. That is the pre-existing behaviour of this path and the reason
        // the revert selector for that state is unchanged by the gate extraction.
        if (!ok && debtUsdc > 0) revert FastRedeemExceedsLtv(postLtv, maxLtv);

        // THE FULL-REDEEM BURN, and why sizing in UNDERLYING strands value. `redeemUnderlying(amt)`
        // ACCRUES first and then burns `amt / freshRate` cTokens, while `amt` was sized off `nav()`'s
        // `exchangeRateStored` — the LAST-ACCRUED rate. Every full fast redeem therefore left
        // `cBal x (1 - stored/fresh)` cTokens behind. With `supply` now 0 that residue is a fund with
        // assets and no shares: `nav() > 0` at `totalSupply() == 0`, so the next depositor of 1 USDC
        // mints against a book that already holds it. `_redeemCollateral` fixed exactly this on the
        // ASYNC path (`shares == supply` burns the cTOKEN balance); the fast path never got it, and
        // making the parked-flat-book fast full redeem reachable is what put it in reach.
        //
        // Burn the whole cToken balance instead, and hand the redeemer the fresh-rate surplus: on a full
        // redeem there are no stayers to share it with, and leaving it behind is the bug.
        //
        // THE SURPLUS IS MEASURED AGAINST `collateralUsdc`, NOT `fromCollateral`, AND THAT CHOICE IS THE
        // PROTOCOL FEE. `fromCollateral` is already NET OF `protocolFeeOwed`: on a full redeem
        // `assetsOut == navNet == raw + C − owed` and the idle draw is the whole raw balance, so
        // `fromCollateral == C − owed`. Baselining the surplus there would make it
        // `(C_fresh − C) + owed` — the rate gap PLUS the accrued fee — and the redeemer would walk off
        // with a liability that has nothing behind it, leaving `protocolFeeOwed` pointing at an empty
        // book for the next depositor's capital to settle. `collateralUsdc` is the pre-burn collateral
        // GROSS of the fee, so the difference is exactly the rate gap and the fee stays funded in raw
        // USDC for its recipient. The two baselines coincide when `owed == 0`, which is why this is a
        // no-op on the common path and why a test with no fee accrued cannot tell them apart.
        //
        // GATED ON A FLAT BOOK (`tokenId == 0`) AND ZERO DEBT: that is the state where mUSDC collateral
        // is the whole non-idle book, so burning all of it is exactly "pay out everything". A full
        // redeem of a NON-flat book was refused at the top of this function; with live debt the LTV
        // gate refuses. (The `tokenId` conjunct is therefore a belt over the top guard, kept because
        // this branch moves the whole collateral and cheap redundancy is the right posture there.)
        if (isFullRedeem && debtUsdc == 0 && $.tokenId == 0) {
            uint256 before = IERC20($.usdc).balanceOf(address(this));
            _redeemCTokens($.mUsdc, ICToken($.mUsdc).balanceOf(address(this)));
            uint256 realised = IERC20($.usdc).balanceOf(address(this)) - before;
            // `realised >= collateralUsdc` whenever the rate has not gone BACKWARDS (it cannot in
            // Compound); the guard keeps the arithmetic total either way, and a shortfall simply pays
            // the quote, which the payout transfer then fails closed on if the raw balance cannot cover.
            if (realised > collateralUsdc) payout = assetsOut + (realised - collateralUsdc);
        } else {
            _redeemUnderlying($.mUsdc, fromCollateral);
        }
        LeveragedAeroManager.assertHealthyImpl(); // authoritative post-op gate (belt over the prediction)
    }

    /// @dev `mUsdc.redeem(cTokens)` with the uniform error-check — the cTOKEN-denominated form, which is
    ///      the only one that provably leaves NO dust: it burns a balance, not an amount derived from a
    ///      rate the call itself is about to move. This library's copy of the manager's helper (same
    ///      reason `_redeemUnderlying` is duplicated here).
    function _redeemCTokens(address cToken, uint256 tokens) private {
        uint256 err = ICToken(cToken).redeem(tokens);
        if (err != 0) revert MoonwellRedeemFailed(err);
    }

    /// @dev The idle-first split, shared by `fastRedeemImpl` and `previewRedeemImpl`: how much of
    ///      `assetsOut` the collateral has to fund once the redeemer's pro-rata idle share is spent.
    ///      `idleShare` is `f×idle` (computed by the strategy from the same `f` it prices with); the
    ///      clamp to the LIVE balance is belt — `idleShare ≤ idle` holds by construction.
    function _fromCollateral(uint256 assetsOut, uint256 idleShare, uint256 idle) private pure returns (uint256) {
        uint256 fromIdle = assetsOut < idleShare ? assetsOut : idleShare;
        if (fromIdle > idle) fromIdle = idle;
        return assetsOut - fromIdle;
    }

    /// @dev THE FAST-PATH GATE — ONE DEFINITION, consumed by BOTH the executed `fastRedeemImpl` (which
    ///      reverts on `!ok`) and the advisory `previewRedeemImpl` (which returns it as `fastOk`). The
    ///      mirror between preview and execution is now STRUCTURAL rather than two hand-kept copies of
    ///      the same conditional — which is exactly how it drifted before: `416d9b4` moved the executed
    ///      copy's `>= collateralUsdc` check inside the debt branch and the preview's copy did not
    ///      follow.
    ///
    ///      THE THREE STATES, on the pre-withdraw basis (collateral shrinks by the collateral-funded
    ///      remainder, debt unchanged):
    ///
    ///        - `fromCollateral == 0` → OK. Idle funds the whole payout; no collateral moves.
    ///
    ///        - `debtUsdc == 0` → OK iff `fromCollateral <= collateralUsdc`. There is no LTV to breach,
    ///          so the only question is whether the collateral can COVER the draw. EXACT COVER MUST STAY
    ///          OK: that is the parked-flat-book full redeem (`supplyIdle` parked the whole pot, the
    ///          sole holder exits, `fromCollateral == collateralUsdc`), which the fast path serves and
    ///          which answering `false` would strand behind `requestRedeem` + the deadman. Only a STRICT
    ///          over-draw is refused — reachable with a live LP position and no debt (a zero-debt book
    ///          is not necessarily flat: `repayBorrowBehalf` is permissionless, so anyone can retire the
    ///          fund's debt while the LP stays open), where `nav()` prices LP equity the collateral
    ///          alone cannot fund.
    ///
    ///        - `debtUsdc > 0` → the LTV prediction. `>= collateralUsdc` would zero or negate the
    ///          denominator, so it is refused as the `type(uint256).max` sentinel; otherwise
    ///          `postLtv = debt × 1e4 / (collateral − fromCollateral)` must be within `maxLtvBps`.
    ///
    ///      `postLtv` is meaningful ONLY in the third state; the callers use it solely for the typed
    ///      `FastRedeemExceedsLtv(postLtv, maxLtv)` they raise there.
    function _fastGate(uint256 fromCollateral, uint256 collateralUsdc, uint256 debtUsdc, uint256 maxLtv)
        private
        pure
        returns (bool ok, uint256 postLtv)
    {
        if (fromCollateral == 0) return (true, 0);
        if (debtUsdc == 0) return (fromCollateral <= collateralUsdc, 0);
        if (fromCollateral >= collateralUsdc) return (false, type(uint256).max);
        postLtv = (debtUsdc * 10_000) / (collateralUsdc - fromCollateral);
        ok = postLtv <= maxLtv;
    }

    /// @dev `mUsdc.redeemUnderlying(amt)` with the uniform error-check (this library's copy of the
    ///      manager's helper — shared by `withdrawIdleImpl` and `fastRedeemImpl`).
    function _redeemUnderlying(address cToken, uint256 amt) private {
        uint256 err = ICToken(cToken).redeemUnderlying(amt);
        if (err != 0) revert MoonwellRedeemFailed(err);
    }

    /// @notice Advisory preview of the fast-path exit — the body of the strategy's `previewRedeem`,
    ///         relocated here verbatim under EIP-170 pressure on the strategy (same rationale as
    ///         `layoutView`). See the strategy entrypoint's docs for the full quote/`fastOk` contract.
    /// @dev BEHAVIOUR-IDENTICAL RELOCATION: the fail-closed hops still go through the STRATEGY's own
    ///      external self-views (`nav`, `simulateCrystallizeSelf`, `previewCollateralDebt`) so a down
    ///      oracle or a reverting config read degrades to `(0,false)`/`(assetsOut,false)` exactly as
    ///      before. Under delegatecall `address(this)` IS the strategy, so the `OnlySelf` guards on
    ///      those hooks see the same self-call they always did.
    function previewRedeemImpl(uint256 shares) public view returns (uint256 assetsOut, bool fastOk) {
        LeveragedAerodromeCLStrategy self = LeveragedAerodromeCLStrategy(payable(address(this)));
        uint256 supply = IERC20(self.vault()).totalSupply();
        if (supply == 0) return (0, false);
        uint256 navPre;
        try self.nav() returns (uint256 n) {
            navPre = n;
        } catch {
            return (0, false);
        }
        // Simulate the pending crystallise the executed `redeem` performs — the SAME arg-marshalling as
        // `_crystallizeFees` (via `_simulateCrystallize`, F4 dedup). Wrapped in a try/catch so a reverting
        // ProtocolConfig read inside `_protocolFeeBps()` degrades to `(0, false)` symmetrically with the other
        // preview failure modes (executed `redeem` swallows the same via its own crystallise try/catch).
        uint256 navNet;
        uint256 supplyPost;
        try self.simulateCrystallizeSelf(navPre, supply) returns (uint256 nn, uint256 sp) {
            navNet = nn;
            supplyPost = sp;
        } catch {
            return (0, false);
        }
        assetsOut = Math.mulDiv(shares, navNet, supplyPost);
        // Mirror `redeem`'s `ZeroAssetsOut` guard: never quote a payout the executed path would revert on.
        if (assetsOut == 0) return (0, false);
        // Mirror the executed path's full-redeem flat-book guard: a FULL fast redeem of a book with a
        // live LP position is always refused (see `fastRedeemImpl`'s top guard), so advise async.
        // `shares == supplyPost` is the same full-redeem predicate the strategy computes post-
        // crystallise — a simulated fee mint makes both sides non-full together.
        if (shares == supplyPost && _layout().tokenId != 0) return (assetsOut, false);
        // Idle-first (mirror `fastRedeemImpl`): the redeemer's `f×idle` share funds part of `assetsOut`,
        // so the LTV gate only sees the collateral-funded remainder.
        uint256 idle = IERC20(_layout().usdc).balanceOf(address(this));
        uint256 idleShare = Math.mulDiv(idle, shares, supplyPost);
        uint256 fromCollateral = _fromCollateral(assetsOut, idleShare, idle);
        if (fromCollateral == 0) return (assetsOut, true); // idle alone covers it — no LTV constraint
        // Predict the executed gate by RUNNING THE EXECUTED GATE: `_fastGate` is the same function
        // `fastRedeemImpl` decides with, so the preview cannot disagree with the path it exists to
        // predict. (It did: this copy of the conditional was hand-kept and drifted from the executed
        // one — see the note on `_fastGate`.)
        try self.previewCollateralDebt() returns (uint256 collateralUsdc, uint256 debtUsdc) {
            (fastOk,) = _fastGate(fromCollateral, collateralUsdc, debtUsdc, uint256(_layout().maxLtvBps));
        } catch {
            return (assetsOut, false); // collateral/debt oracle read failed → advise the async path
        }
    }

    /// @notice Revert `InsufficientIdle` unless `amount` ≤ raw USDC + UN-LEVERED collateral — the
    ///         funding bound of the proposer's `deployIdle` (the manager's own `_usdcAvailable()`
    ///         check stays as a belt).
    /// @dev WHY NOT RAW + ALL COLLATERAL: `_supplyAndBorrow` sizes its borrow off the GROSS amount on
    ///      the assumption that the amount is fresh, not-yet-levered NAV. Funded from collateral that
    ///      already backs debt, a `deployIdle` is redeem → supply-straight-back → borrow — a net
    ///      debt-only increase that re-levers the same USDC twice and walks LTV from `targetLtvBps`
    ///      toward `maxLtvBps` with no admin action, the exact capability the admin-only target split
    ///      denies the `onlyProposer` key. Bounding by the un-levered slice refuses that with a typed
    ///      error instead of deferring to Moonwell's free-collateral line (`MoonwellRedeemFailed`).
    function checkDeployableIdle(uint256 amount) public view {
        Layout storage $ = _layout();
        if (amount > IERC20($.usdc).balanceOf(address(this)) + _unleveredCollateral()) {
            revert InsufficientIdle();
        }
    }

    /// @dev mUSDC collateral NOT already backing debt at the standing target:
    ///      `C − ceil(D·1e4/targetLtvBps)`, floored at 0. THE PROPOSER'S SPENDABLE-COLLATERAL BASIS —
    ///      `deployIdle` may fund itself from raw + this, `withdrawIdle` from this alone. Both bounds
    ///      exist for the same reason: collateral backing debt at target is NOT idle, and either
    ///      spending it (deploy) or removing it (withdraw) moves LTV above the admin-set target with
    ///      no admin action. Zero-debt books take `_readCollateralDebt`'s fast path (no feed reads),
    ///      so the bound stays oracle-free exactly where `supplyIdle`'s flat-book use case needs it;
    ///      with live debt the feeds are read — the same fail-closed posture as every levered op.
    function _unleveredCollateral() private view returns (uint256) {
        (uint256 collateralUsdc, uint256 debtUsdc) = LeveragedAeroManager.readCollateralDebtImpl();
        return _unleveredFrom(collateralUsdc, debtUsdc);
    }

    /// @dev The bound's ARITHMETIC, split out from the read so `withdrawIdleImpl` can apply the same
    ///      formula to a collateral/debt pair it obtained through a try-able hop. One definition; the
    ///      two entry points cannot compute a different spendable slice.
    function _unleveredFrom(uint256 collateralUsdc, uint256 debtUsdc) private view returns (uint256) {
        if (debtUsdc == 0) return collateralUsdc;
        uint256 t = uint256(_layout().targetLtvBps);
        uint256 backing = (debtUsdc * 10_000 + t - 1) / t;
        return collateralUsdc > backing ? collateralUsdc - backing : 0;
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
        // book keeps a balance that is invisible to `nav()` (the `tokenId == 0` branch prices USDC —
        // raw and mUSDC-parked — and the reward token is neither), unsellable (`compound`
        // early-returns on a flat book) and un-rescuable
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
        // exceed it, so this branch only skips balances the priced check would also have skipped.
        // The priced floor now carries a USDC/USD peg divisor as well, which widens its own dust band
        // whenever USDC reads above peg and narrows it below — the $10,000 ceiling is ~10,000x the
        // live AERO price, which absorbs any peg factor a Chainlink USDC/USD read could plausibly
        // produce, so the containment holds with room to spare rather than exactly.
        //
        // PARTIAL BY CONSTRUCTION, deliberately: this covers only the band that is dust at the
        // CEILING price, so the priced `floor == 0` skip below still carries the rest of the band and
        // still runs after the oracle. Closing the remainder needs the actual price, i.e. a
        // non-reverting `tryReadUsd8` variant — a rewrite of a safety-critical oracle path, which is
        // not worth it for a sub-micro-USD balance.
        if (bal < 1e20 / REWARD_PRICE_CEILING_USD8) return;
        // PEG LEG, not `/1e20` — see the identical fix in `LeveragedAeroManager.compoundImpl`. The floor
        // is post-checked against `usdcOut`, a USDC-FACE fill, so the USD value must be divided by the
        // USDC/USD price rather than by an assumed 1.00. Bidirectional: USDC below peg = a lax floor;
        // USDC above peg = an UNCLEARABLE floor, which reverts `BelowOracleFloor` on every attempt and so
        // bricks `flatten` — and `flatten` is `migrateVenue`'s own precondition. The nested `mulDiv`
        // mirrors `LeveragedAeroValuation._usdcValue` (18dp token → 8dp USD → 6dp USDC face); it is
        // written out rather than reused because that helper is `private` to the valuation library.
        uint256 pUsdc8 = LeveragedAeroValuation.readUsd8($.usdcFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        uint256 floor = Math.mulDiv(
            Math.mulDiv(
                bal, LeveragedAeroValuation.readUsd8($.aeroUsdFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod), 1e18
            ),
            1e6,
            pUsdc8
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
        // L9: the reward-token floor scales an 8dp price (`bal x price8 / 1e18`, then the USDC peg
        // divisor takes it to a 6dp face amount); a non-8dp
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

    /// @notice The strategy's full `LayoutView` read out of diamond storage — the BODY of
    ///         `LeveragedAerodromeCLStrategy.layout()`, hosted here.
    /// @dev PURE RELOCATION, FOR THE STRATEGY'S EIP-170 BUDGET — the reason this library exists (see
    ///      "WHY A THIRD LIBRARY" above), applied to the single biggest block of strategy bytecode that
    ///      is not on a value path. Same field-by-field copy, same order, same `_layout()` (this
    ///      library's copy is parity-tested byte-identical to the strategy's), same struct type — the
    ///      strategy's `layout()` selector and ABI are untouched, it now just forwards.
    ///
    ///      Field-by-field, not a struct-literal, for the same Yul-IR reason the strategy's copy was:
    ///      a 52-field literal overflows the 16-live-variable stack window under via_ir.
    ///
    ///      DIRECT-CALL NOTE: this is a `view`, and solc's library call-protection guard (the
    ///      `address(this) == self` check that makes the state-mutating entrypoints here revert on a
    ///      direct CALL) is not emitted for view/pure functions — so `layoutView()` IS callable on the
    ///      deployed library address. It then reads the LIBRARY'S own all-zero diamond slot and returns
    ///      a zeroed struct: meaningless, not the fund's state, and it can write nothing. Reach it via
    ///      `strategy.layout()`.
    function layoutView() public view returns (LeveragedAerodromeCLStrategy.LayoutView memory v) {
        Layout storage $ = _layout();
        v.usdc = $.usdc;
        v.mUsdc = $.mUsdc;
        v.mCbBTC = $.mCbBTC;
        v.mWeth = $.mWeth;
        v.cbBTC = $.cbBTC;
        v.weth = $.weth;
        v.pool = $.pool;
        v.cbBTCFeed = $.cbBTCFeed;
        v.wethFeed = $.wethFeed;
        v.usdcFeed = $.usdcFeed;
        v.sequencerFeed = $.sequencerFeed;
        v.maxDelay = $.maxDelay;
        v.gracePeriod = $.gracePeriod;
        v.calmDeviationTicks = $.calmDeviationTicks;
        v.twapWindow = $.twapWindow;
        v.comptroller = $.comptroller;
        v.npm = $.npm;
        v.gauge = $.gauge;
        v.swapRouter = $.swapRouter;
        v.tickSpacing = $.tickSpacing;
        v.targetLtvBps = $.targetLtvBps;
        v.maxLtvBps = $.maxLtvBps;
        v.minHealthBps = $.minHealthBps;
        v.maxSlippageBps = $.maxSlippageBps;
        v.usdcCollateralFactorBps = $.usdcCollateralFactorBps;
        v.tokenId = $.tokenId;
        v.posTickLower = $.posTickLower;
        v.posTickUpper = $.posTickUpper;
        v.managementFeeBps = $.managementFeeBps;
        v.performanceFeeBps = $.performanceFeeBps;
        v.feeRecipient = $.feeRecipient;
        v.hwmPerShare = $.hwmPerShare;
        v.lastFeeAccrualTimestamp = $.lastFeeAccrualTimestamp;
        v.protocolFeeOwed = $.protocolFeeOwed;
        v.aeroUsdFeed = $.aeroUsdFeed;
        v.nextRedeemRequestId = $.nextRedeemRequestId;
        v.cbBTCDecimals = $.cbBTCDecimals;
        v.wethDecimals = $.wethDecimals;
        v.wethIsToken0 = $.wethIsToken0;
        v.wethDeliversNative = $.wethDeliversNative;
        v.cbBTCSwapTickSpacing = $.cbBTCSwapTickSpacing;
        v.wethSwapTickSpacing = $.wethSwapTickSpacing;
        v.width = $.width;
        v.minWidth = $.minWidth;
        v.maxWidth = $.maxWidth;
        v.legBIsAsset = $.legBIsAsset;
        v.skewBps = $.skewBps;
        v.minSkewBps = $.minSkewBps;
        v.maxSkewBps = $.maxSkewBps;
        v.hedgedDebtA = $.hedgedDebtA;
        v.hedgedDebtB = $.hedgedDebtB;
        v.stagedVenueHash = $.stagedVenueHash;
    }

    /// @notice `applyVenue` reached straight from the strategy's `InitParams` — the venue subset is
    ///         marshalled HERE instead of in the strategy.
    /// @dev PURE RELOCATION, FOR THE STRATEGY'S EIP-170 BUDGET, same as `layoutView` and the same reason
    ///      this library exists. The 19 field copies are `_venueParamsOf`'s, verbatim and in order; the
    ///      validation and the stores are `applyVenue`'s, untouched — this is an internal jump into it,
    ///      not a second copy of the ladder. `migrateVenue` still calls `applyVenue` directly with its own
    ///      calldata `VenueParams`, so the two entries share one validation path exactly as before.
    ///
    ///      Field-by-field, not a struct-literal, for the Yul-IR stack reason the strategy's copy carried.
    function applyVenueFromInit(LeveragedAerodromeCLStrategy.InitParams memory p) public {
        VenueParams memory v;
        v.mCbBTC = p.mCbBTC;
        v.mWeth = p.mWeth;
        v.cbBTC = p.cbBTC;
        v.weth = p.weth;
        v.pool = p.pool;
        v.gauge = p.gauge;
        v.cbBTCFeed = p.cbBTCFeed;
        v.wethFeed = p.wethFeed;
        v.aeroUsdFeed = p.aeroUsdFeed;
        v.tickSpacing = p.tickSpacing;
        v.cbBTCSwapTickSpacing = p.cbBTCSwapTickSpacing;
        v.wethSwapTickSpacing = p.wethSwapTickSpacing;
        v.wethDeliversNative = p.wethDeliversNative;
        v.width = p.width;
        v.minWidth = p.minWidth;
        v.maxWidth = p.maxWidth;
        v.targetLtvBps = p.targetLtvBps;
        v.maxLtvBps = p.maxLtvBps;
        v.minHealthBps = p.minHealthBps;
        applyVenue(v);
    }
}
