// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeveragedAeroManager} from "./LeveragedAeroManager.sol";
import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {LeveragedAerodromeCLStrategy} from "./LeveragedAerodromeCLStrategy.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ICToken, IComptroller, IMoonwellMarket, IMoonwellPriceOracle} from "./interfaces/IMoonwellMarket.sol";
import {ICLFactory, ICLGauge, ICLPool} from "./interfaces/ISlipstream.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LeveragedAeroVenue
/// @notice Venue-migration companion to `LeveragedAerodromeCLStrategy`, delegatecalled like
///         `LeveragedAeroManager` (shares the strategy's storage; events emit from its address): the
///         venue validation shared by `_initialize` and the owner-staged migration, plus `stageImpl` /
///         `flattenImpl` / `migrateImpl`, and the `layoutView` / `applyVenueFromInit` relocations that
///         buy the strategy EIP-170 headroom. The vault OWNER commits the destination venue hash
///         byte-exact; the PROPOSER sequences execution.
/// @dev CORRUPTION-CRITICAL: `Layout`, `RedeemRequest`, `STORAGE_SLOT` and `_layout()` are
///      byte-identical to the strategy's and manager's copies (`layout_parity.sh`) — never edit one alone.
library LeveragedAeroVenue {
    using SafeERC20 for IERC20;

    // ── Errors (shared selectors with the strategy / BaseStrategy where names collide) ──
    error ZeroAddress();
    error VenueMismatch(); // pool/gauge/market wiring does not match the declared legs or tickSpacing
    error UnsupportedLeg(); // leg A is the unit of account, or a leg is the gauge reward token
    error UnexpectedFeedDecimals();
    error LegDecimalsOutOfRange(); // a leg token reports decimals outside [2, 18]
    // The range and LTV-band errors are raised through `LeveragedAeroValuation`'s copies (already the
    // strategy's selectors), so they are not re-declared; `TargetLtvZero` is a lower bound `applyVenue`
    // alone enforces and so lives here.
    error TargetLtvZero(); // targetLtvBps == 0 — a standing target of zero can never lever
    error TargetLtvExceedsMax(); // selector mirrors the strategy's / the valuation's
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
    /// @notice `aeroAmount` of a realized reward tranche was skimmed to `recipient`, in AERO (18dp).
    ///         Re-declared with `LeveragedAeroManager`'s signature (same `topic0`): ONE fee, ONE address.
    event RewardFeePaid(address indexed recipient, uint256 aeroAmount);
    /// @notice The staged venue rewrite executed on a flat book.
    event VenueMigrated(address indexed oldPool, address indexed newPool);
    /// @notice The fund's STANDING target LTV changed as a side effect of writing a venue — at init, and
    ///         on every `migrateVenue` whose staged params carry a different `targetLtvBps`.
    /// @dev Re-declared with the strategy's signature (so the same `topic0`): without it an owner-staged
    ///      migration could silently restore a target the proposer had just ratcheted down.
    event TargetLtvUpdated(uint16 previousBps, uint16 newBps);
    /// @notice The ceiling / width band moved — through the admin's standalone setters, or through
    ///         `applyVenue`, which emits the same pair inequality-guarded. Re-declared with the strategy's
    ///         signatures (same `topic0`), since both routes log from the strategy's address.
    event MaxLtvUpdated(uint16 previousBps, uint16 newBps);
    event WidthBoundsUpdated(uint24 previousMinWidth, uint24 previousMaxWidth, uint24 newMinWidth, uint24 newMaxWidth);
    /// @notice The permissionless-deleverage trigger moved: it sits at `LTV = 1e8 / minHealthBps`.
    event MinHealthUpdated(uint16 previousBps, uint16 newBps);

    /// @notice An async-redeem request was escrowed. Re-declared with the strategy's signature (same `topic0`).
    event RedeemRequested(uint256 indexed id, address indexed owner, address indexed recipient, uint256 shares);

    /// @notice `withdrawIdle` could not read the hardened oracle, so the SAME target-LTV bound was
    ///         re-derived from Moonwell's own account snapshot: the PRICE BASIS degraded, not the bound.
    event WithdrawIdleBoundDegraded();

    /// @notice The venue subset of the strategy's config — everything a pool/pair change touches. Field
    ///         names are historical LEG SLOTS as in `InitParams`: `weth*` is leg A (always borrowed),
    ///         `cbBTC*` is leg B (the slot that may be the unit of account — that IS asset-mode). The
    ///         non-migratable core is read from live storage, never from here.
    /// @dev `aeroUsdFeed` is part of the venue because the gauge is migratable: a feed pinned at init
    ///      would let a migration price a new reward token at AERO's, mis-scaling the L9 harvest floor.
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
        uint16 targetLtvBps;
        uint16 maxLtvBps;
        uint16 minHealthBps;
    }

    // ── Diamond storage — byte-identical to the strategy's and manager's copies (layout_parity.sh) ──

    /// @dev Byte-identical to the strategy's / manager's `RedeemRequest`.
    struct RedeemRequest {
        address owner; // request creator; the only address that can cancel / emergency-redeem it
        uint256 shares; // vault shares escrowed in the strategy at request time
        uint256 minAssetsOut; // slippage floor enforced at fulfill (fresh arg at emergencyRedeem)
        uint40 requestedAt; // request timestamp; FULFILL_WINDOW deadman clock anchor
        bool settled; // set once fulfilled / cancelled / emergency-redeemed (double-spend guard)
        address recipient; // `fulfillRedeem` payee, fixed at request time; defaults to `owner`
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
        // fee params
        uint16 compoundFeeBps; // in-kind skim of each harvested AERO tranche, bps
        address feeRecipient;
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
        bytes32 stagedVenueHash; // keccak256(abi.encode(paramsHash, stagingOwner)); 0 == none; owner move suspends
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /// @dev The canonical Slipstream CLFactory on Base — the ONE registry allowed to vouch for a
    ///      destination pool. Hardcoded, not read from `pool.factory()`: a self-nominated registry
    ///      vouches for nothing.
    address private constant AERODROME_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    /// @dev An 8dp reward-token price nothing could plausibly exceed ($10,000 against a ~$1 token), used
    ///      only to derive the oracle-free dust bound in `_sellRewardBalance`; raising it only narrows it.
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
    /// @dev Value-neutral to `nav()` (the amount moves from the raw-balance term to the collateral term,
    ///      both counted on both branches), and the supplied collateral stays leverageable by policy.
    function supplyIdleImpl(uint256 amount) public {
        if (amount == 0) return;
        Layout storage $ = _layout();
        if (amount > IERC20($.usdc).balanceOf(address(this))) revert InsufficientIdle();
        IERC20($.usdc).forceApprove($.mUsdc, amount);
        uint256 err = ICToken($.mUsdc).mint(amount);
        if (err != 0) revert MoonwellMintFailed(err);
    }

    /// @notice Redeem `amount` of raw USDC out of the strategy's mUSDC collateral — the body of the
    ///         proposer's `withdrawIdle`, the exact inverse of `supplyIdleImpl`.
    /// @dev `amount` is bounded by the UN-LEVERED collateral, so the op can never push LTV above the
    ///      standing target; when the hardened oracle cannot price that bound the SAME bound is re-derived
    ///      at the venue's oracle and `WithdrawIdleBoundDegraded` is emitted. Deliberately NOT done for
    ///      `checkDeployableIdle`: degrading a bound that gates levering UP would let a keeper add debt blind.
    function withdrawIdleImpl(uint256 amount) public {
        if (amount == 0) return;
        try LeveragedAerodromeCLStrategy(payable(address(this))).previewCollateralDebt() returns (
            uint256 collateralUsdc, uint256 debtUsdc
        ) {
            if (amount > _unleveredFrom(collateralUsdc, debtUsdc)) revert InsufficientIdle();
        } catch {
            // Policy unpriceable at OUR oracle → hold the SAME line at the venue's, marked not silent.
            if (amount > _unleveredAtVenueOracle()) revert InsufficientIdle();
            emit WithdrawIdleBoundDegraded();
        }
        _redeemUnderlying(_layout().mUsdc, amount);
    }

    /// @dev With USDC the sole collateral, `getAccountLiquidity` returns 18dp `C·CF − D` (or a shortfall), so
    ///      `D = C·CF − liquidity + shortfall` — but in USDC FACE, the basis `targetLtvBps` is measured on, so
    ///      the 18dp USD terms are divided by the SAME USDC price the venue just priced them with and the peg
    ///      factor cancels exactly. CF is read LIVE; the comptroller reads fail closed
    ///      `ComptrollerCallFailed`, and a zero oracle price panics on the division.
    function _unleveredAtVenueOracle() private view returns (uint256) {
        Layout storage $ = _layout();
        uint256 c = (ICToken($.mUsdc).balanceOf(address(this)) * ICToken($.mUsdc).exchangeRateStored()) / 1e18;
        uint256 cf = uint256(LeveragedAeroValuation.readCollateralFactor($.comptroller, $.mUsdc));
        (uint256 err, uint256 liquidity, uint256 shortfall) =
            IComptroller($.comptroller).getAccountLiquidity(address(this));
        if (err != 0) revert ComptrollerCallFailed();
        // `1e(36−decimals)`-scaled, so `usd18 × 1e18 / p` is USDC face for any underlying decimals.
        uint256 p = IMoonwellPriceOracle(IComptroller($.comptroller).oracle()).getUnderlyingPrice($.mUsdc);
        uint256 dVenue = (c * cf) / 10_000 + (shortfall * 1e18) / p;
        uint256 liqFace = (liquidity * 1e18) / p;
        dVenue = dVenue > liqFace ? dVenue - liqFace : 0;
        return _unleveredFrom(c, dVenue);
    }

    /// @notice Oracle-priced fast-redeem funding (body of the strategy's `redeem`): source `assetsOut` from
    ///         the redeemer's `f×idle` share (so a partial redeem never dips into a stayer's `(1-f)×idle`)
    ///         FIRST, then free only the remainder from the mUSDC collateral — no LP touch, no debt repay.
    ///         The LTV gate runs BEFORE the withdraw against that remainder only, reverting
    ///         `FastRedeemExceedsLtv` above `maxLtvBps` (route the user to `requestRedeem`), and
    ///         `assertHealthyImpl()` runs after as belt. Idle alone covering it skips collateral and gate.
    function fastRedeemImpl(uint256 assetsOut, uint256 idleShare, bool isFullRedeem) public returns (uint256 payout) {
        Layout storage $ = _layout();
        payout = assetsOut;
        // A FULL fast redeem is ONLY served on a FLAT book: the fast path never touches the LP, so on a
        // live position with ZERO debt (reachable — `repayBorrowBehalf` is permissionless) a payout that
        // under-states the LP passes the gate below and burns the last shares with the NFT still live.
        if (isFullRedeem && $.tokenId != 0) revert FastRedeemExceedsLtv(type(uint256).max, uint256($.maxLtvBps));
        // Idle-first: at most the redeemer's `f×idle` share, clamped to the live balance.
        uint256 fromCollateral = _fromCollateral(assetsOut, idleShare, IERC20($.usdc).balanceOf(address(this)));
        // Idle alone covers it → no collateral/debt read at all, which keeps an idle-funded redeem free of
        // any oracle dependency. EXCEPT a FULL redeem with parked cTokens left, which would burn the last
        // shares with the whole balance stranded; the fall-through is flat-book, so it costs no oracle read.
        if (fromCollateral == 0 && !(isFullRedeem && ICToken($.mUsdc).balanceOf(address(this)) > 0)) {
            return payout;
        }

        (uint256 collateralUsdc, uint256 debtUsdc) = LeveragedAeroManager.readCollateralDebtImpl();
        uint256 maxLtv = uint256($.maxLtvBps);
        (bool ok, uint256 postLtv) = _fastGate(fromCollateral, collateralUsdc, debtUsdc, maxLtv);
        // The typed error is for LTV breaches only: a zero-debt over-draw has no LTV, so it falls through
        // to `_redeemUnderlying` and Moonwell fails it closed with `MoonwellRedeemFailed(err)`.
        if (!ok && debtUsdc > 0) revert FastRedeemExceedsLtv(postLtv, maxLtv);

        // THE FULL-REDEEM BURN: `redeemUnderlying(amt)` accrues then burns `amt / freshRate`, while `amt`
        // was sized off `exchangeRateStored`, leaving `cBal x (1 - stored/fresh)` behind — assets with no
        // shares. Burn the whole cToken balance instead and pay the redeemer the surplus, measured against
        // `collateralUsdc`. Gated on a flat, zero-debt book — the state where mUSDC collateral is the whole
        // non-idle book.
        if (isFullRedeem && debtUsdc == 0 && $.tokenId == 0) {
            uint256 before = IERC20($.usdc).balanceOf(address(this));
            _redeemCTokens($.mUsdc, ICToken($.mUsdc).balanceOf(address(this)));
            uint256 realised = IERC20($.usdc).balanceOf(address(this)) - before;
            // The rate cannot go backwards in Compound; the guard keeps the arithmetic total either way,
            // and a shortfall pays the quote, which the payout transfer then fails closed on.
            if (realised > collateralUsdc) payout = assetsOut + (realised - collateralUsdc);
        } else {
            _redeemUnderlying($.mUsdc, fromCollateral);
        }
        LeveragedAeroManager.assertHealthyImpl(); // authoritative post-op gate (belt over the prediction)
    }

    /// @dev `mUsdc.redeem(cTokens)` with the uniform error-check — the cTOKEN-denominated form, the only
    ///      one that provably leaves NO dust: it burns a balance, not an amount off a rate it is moving.
    function _redeemCTokens(address cToken, uint256 tokens) private {
        uint256 err = ICToken(cToken).redeem(tokens);
        if (err != 0) revert MoonwellRedeemFailed(err);
    }

    /// @dev The idle-first split shared by `fastRedeemImpl` and `previewRedeemImpl`: how much of
    ///      `assetsOut` the collateral must fund once the redeemer's `f×idle` share is spent. The clamp to
    ///      the LIVE balance is belt — `idleShare ≤ idle` holds by construction.
    function _fromCollateral(uint256 assetsOut, uint256 idleShare, uint256 idle) private pure returns (uint256) {
        uint256 fromIdle = assetsOut < idleShare ? assetsOut : idleShare;
        if (fromIdle > idle) fromIdle = idle;
        return assetsOut - fromIdle;
    }

    /// @dev ONE definition of the fast-path gate, for the executed `fastRedeemImpl` and the advisory
    ///      `previewRedeemImpl` alike — which drifted while they were two hand-kept copies. Pre-withdraw
    ///      basis: no draw is OK; zero debt is OK iff the draw is COVERED, exact cover included (the
    ///      parked-flat-book full redeem); otherwise `postLtv = debt × 1e4 / (collateral − draw)` must be
    ///      within `maxLtvBps`, a `>= collateralUsdc` draw being refused as the `type(uint256).max`
    ///      sentinel. `postLtv` is meaningful only in that last state.
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

    /// @dev `mUsdc.redeemUnderlying(amt)` with the uniform error-check (this library's copy of the manager's).
    function _redeemUnderlying(address cToken, uint256 amt) private {
        uint256 err = ICToken(cToken).redeemUnderlying(amt);
        if (err != 0) revert MoonwellRedeemFailed(err);
    }

    /// @notice Advisory preview of the fast-path exit — the body of the strategy's `previewRedeem`. See
    ///         that entrypoint's docs for the full quote/`fastOk` contract.
    /// @dev The fail-closed hops go through the STRATEGY's own external self-views, so a down oracle or a
    ///      degrades to `(0,false)`/`(assetsOut,false)`.
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
        assetsOut = Math.mulDiv(shares, navPre, supply);
        // Mirror `redeem`'s `ZeroAssetsOut` guard: never quote a payout the executed path would revert on.
        if (assetsOut == 0) return (0, false);
        // Mirror the executed full-redeem flat-book guard: a full fast redeem of a book with a live LP is
        // always refused, so advise async.
        if (shares == supply && _layout().tokenId != 0) return (assetsOut, false);
        // Idle-first (mirror `fastRedeemImpl`): the gate only sees the collateral-funded remainder.
        uint256 idle = IERC20(_layout().usdc).balanceOf(address(this));
        uint256 idleShare = Math.mulDiv(idle, shares, supply);
        uint256 fromCollateral = _fromCollateral(assetsOut, idleShare, idle);
        if (fromCollateral == 0) return (assetsOut, true); // idle alone covers it — no LTV constraint
        // Predict the executed gate by RUNNING it: `_fastGate` is the same function `fastRedeemImpl`
        // decides with, so the preview cannot disagree with the path it exists to predict.
        try self.previewCollateralDebt() returns (uint256 collateralUsdc, uint256 debtUsdc) {
            (fastOk,) = _fastGate(fromCollateral, collateralUsdc, debtUsdc, uint256(_layout().maxLtvBps));
        } catch {
            return (assetsOut, false); // collateral/debt oracle read failed → advise the async path
        }
    }

    /// @notice Escrow `shares` for an async proportional redeem — the body of the strategy's `requestRedeem`,
    ///         whose entrypoint keeps the `State.Executed` gate and `nonReentrant`. Here for EIP-170 headroom.
    /// @dev The `address(0)` → `msg.sender` substitution keeps the stored `recipient` never zero.
    function requestRedeemImpl(uint256 shares, uint256 minAssetsOut, address recipient) public returns (uint256 id) {
        if (recipient == address(0)) recipient = msg.sender;
        IERC20(LeveragedAerodromeCLStrategy(payable(address(this))).vault()).safeTransferFrom(
            msg.sender, address(this), shares
        );
        Layout storage $ = _layout();
        id = $.nextRedeemRequestId++;
        $.redeemRequests[id] = RedeemRequest({
            owner: msg.sender,
            shares: shares,
            minAssetsOut: minAssetsOut,
            requestedAt: uint40(block.timestamp),
            settled: false,
            recipient: recipient
        });
        emit RedeemRequested(id, msg.sender, recipient, shares);
    }

    /// @notice Revert `InsufficientIdle` unless `amount` ≤ raw USDC + UN-LEVERED collateral — the funding
    ///         bound of the proposer's `deployIdle` (the manager's `_usdcAvailable()` stays as a belt).
    /// @dev Not raw + ALL collateral: `_supplyAndBorrow` sizes its borrow assuming fresh, not-yet-levered
    ///      NAV, so funding from collateral that already backs debt re-levers the same USDC twice and walks
    ///      LTV toward `maxLtvBps` with no admin action.
    function checkDeployableIdle(uint256 amount) public view {
        Layout storage $ = _layout();
        if (amount > IERC20($.usdc).balanceOf(address(this)) + _unleveredCollateral()) {
            revert InsufficientIdle();
        }
    }

    /// @dev mUSDC collateral NOT already backing debt at the standing target, `C − ceil(D·1e4/target)`
    ///      floored at 0 — the spendable basis for `deployIdle` (raw + this) and `withdrawIdle` (this
    ///      alone). Zero-debt books read no feeds, so the bound stays oracle-free on a flat book.
    function _unleveredCollateral() private view returns (uint256) {
        (uint256 collateralUsdc, uint256 debtUsdc) = LeveragedAeroManager.readCollateralDebtImpl();
        return _unleveredFrom(collateralUsdc, debtUsdc);
    }

    /// @dev The bound's arithmetic, split out from the read so `withdrawIdleImpl` can apply it to a pair
    ///      obtained through a try-able hop. One definition; the two entry points cannot disagree.
    function _unleveredFrom(uint256 collateralUsdc, uint256 debtUsdc) private view returns (uint256) {
        if (debtUsdc == 0) return collateralUsdc;
        uint256 t = uint256(_layout().targetLtvBps);
        uint256 backing = (debtUsdc * 10_000 + t - 1) / t;
        return collateralUsdc > backing ? collateralUsdc - backing : 0;
    }

    // ── Migration ops (auth + state gates live in the strategy's entry points) ──

    /// @notice Stage `venueHash` as the committed destination venue (0 clears), BOUND to `stagingOwner`
    ///         so a vault-owner rotation SUSPENDS it (re-arms if ownership returns — `stageVenue(0)`
    ///         before a handover). Inert: no venue state, position or pricing change until `migrateImpl`.
    /// @dev `0` must stay the "nothing staged" sentinel, so the clear path is NOT bound. The event
    ///      carries the RAW hash: off-chain, recompute the stored value with the live vault owner.
    function stageImpl(bytes32 venueHash, address stagingOwner) public {
        _layout().stagedVenueHash =
            venueHash == bytes32(0) ? bytes32(0) : keccak256(abi.encode(venueHash, stagingOwner));
        emit VenueStaged(venueHash);
    }

    /// @notice Unwind the WHOLE book to idle USDC without settling — `LeveragedAeroManager.settleImpl`'s
    ///         exact unwind, then zero the hedged-principal bases the way `_settle` does. UNLIKE `_settle`:
    ///         no push-to-vault and no state transition — the strategy stays `Executed`, so deposits/redeems keep working
    ///         against the flat book (NAV == idle USDC, no oracle).
    /// @dev Unwind-swap slippage is Chainlink-floored inside `settleImpl` via `maxSlippageBps`, so a down
    ///      oracle fail-closes the flatten. Idempotent on a flat book whose reward balance is empty or
    ///      inside the dust band; a balance ABOVE that band is a real tranche (a donation included), so
    ///      always quote a nonzero `minRewardUsdcOut` — `flatten(1, …)` clears it, and the post-checked
    ///      oracle floor is the real guard.
    function flattenImpl(uint256 minRewardUsdcOut, uint256 minIdleUsdcOut) public {
        Layout storage $ = _layout();
        // CALM GATE FIRST — never unwind at a manipulated tick. `settleImpl` has none of its own (it was
        // written for the terminal owner-driven `settle()`, and its unwind mins come off the same `slot0()`
        // it burns at); `flatten` is proposer-callable and REPEATABLE, the shape `rerangeImpl` gates.
        LeveragedAeroValuation.calmGate($.pool, $.twapWindow, $.calmDeviationTicks);
        LeveragedAeroManager.settleImpl();
        // Sell the tranche the unwind's `gauge.withdraw` auto-claimed: on a flat book it is invisible to
        // `nav()`, unsellable (`compound` early-returns) and un-rescuable while Executed, so every deposit
        // and redeem in the flat window would price against an understated NAV.
        _sellRewardBalance(minRewardUsdcOut, true, true);
        // Same belt as `_settle`: `_repay`'s clamp drives the bases to 0 unless residual debt could not be
        // covered at all — zero them explicitly so no stale hedge basis reaches the next venue.
        $.hedgedDebtA = 0;
        $.hedgedDebtB = 0;
        // The proposer's own floor on the WHOLE realised unwind; the per-swap oracle floors only bound
        // each leg at `maxSlippageBps`, which init permits as wide as 10%.
        uint256 idle = IERC20($.usdc).balanceOf(address(this));
        if (idle < minIdleUsdcOut) revert InsufficientIdleAfterFlatten(idle, minIdleUsdcOut);
        emit Flattened(idle);
    }

    /// @notice Sell a reward tranche an unwind auto-claimed, floored by the L9 oracle read ALONE — no
    ///         caller `minOut`, so that floor (post-checked against the fill) is the whole guard.
    /// @dev Reached by the TERMINAL `_settle` and by `LeveragedAeroManager.redeemUnwindImpl`, whose tranches
    ///      would otherwise strand or be excluded from a payout `nav()` already prices. BEST-EFFORT BY
    ///      CONTRACT — both MUST come through `LeveragedAerodromeCLStrategy.sellRewardSelf`'s try/catch;
    ///      this still fails closed itself, which is what makes the catch safe (the revert unwinds the swap,
    ///      leaving the balance unsold rather than sold blind). `flattenImpl` takes it fail-closed instead
    ///      because it is RESUMABLE, whereas a hard revert on a terminal settle or the deadman redeem would
    ///      turn a value guard into a fund freeze.
    /// @param skim Pay the fund's fee: TRUE for the async redeem, FALSE for the terminal settle.
    function sellRewardImpl(bool skim) public {
        _sellRewardBalance(0, false, skim);
    }

    /// @dev Floored exactly as `compoundImpl`'s harvest is: `max(caller minOut, oracle floor)`, the floor a
    ///      hardened 8dp `aeroUsdFeed` read haircut by `maxSlippageBps` and post-checked against the
    ///      MEASURED fill so a dishonest router cannot widen it. No-op on an empty balance and on dust
    ///      whose floor rounds to 0 — without that a 1e6-wei donation would brick `flatten`, and so
    ///      `migrateVenue`, permanently. Above that band a zero `minRewardUsdcOut` reverts `ZeroMinOut`,
    ///      so only the empty/dust cases make `flatten` idempotent.
    /// @param minRewardUsdcOut Caller's own floor on the fill (the oracle floor applies on top).
    /// @param callerFloorRequired Whether a zero `minRewardUsdcOut` is a caller error: TRUE for `flatten`,
    ///        FALSE for the terminal settle AND the async redeem unwind (`redeemUnwindImpl` via
    ///        `sellRewardImpl`), neither of which has an argument to supply.
    /// @param skim Pay the fund's fee out of this sale — TRUE for `flatten` and the async redeem, both of
    ///        which realize the WHOLE book's accrual; FALSE for the terminal settle. See `compoundImpl`.
    function _sellRewardBalance(uint256 minRewardUsdcOut, bool callerFloorRequired, bool skim) private {
        Layout storage $ = _layout();
        address rewardTok = ICLGauge($.gauge).rewardToken();
        uint256 bal = IERC20(rewardTok).balanceOf(address(this));
        if (bal == 0) return;
        // ORACLE-FREE DUST BAND, checked BEFORE the priced one below, whose `floor == 0` skip sits AFTER
        // `readUsd8` — so a dust donation would otherwise gate `flatten`, and hence `migrateVenue`, on
        // reward-feed staleness. `REWARD_PRICE_CEILING_USD8` substitutes a price no live read could exceed
        // (peg divisor included), so this only skips balances the priced check would also skip.
        if (bal < 1e20 / REWARD_PRICE_CEILING_USD8) return;
        // THE FUND'S FEE, IN KIND, sized (rounding DOWN) ahead of every bound below exactly as
        // `compoundImpl` sizes it, so both floors price only what really reaches the router.
        uint256 feeAmt = skim ? Math.mulDiv(bal, uint256($.compoundFeeBps), 10_000) : 0;
        uint256 sellAmt = bal - feeAmt;
        // PEG LEG, not `/1e20` (same fix as `LeveragedAeroManager.compoundImpl`): the floor is post-checked
        // against `usdcOut`, a USDC-FACE fill, so the USD value must be divided by the USDC/USD price rather
        // than an assumed 1.00 — below peg a lax floor, above peg an UNCLEARABLE one that bricks `flatten`.
        uint256 pUsdc8 = LeveragedAeroValuation.readUsd8($.usdcFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        uint256 floor = Math.mulDiv(
            Math.mulDiv(
                sellAmt,
                LeveragedAeroValuation.readUsd8($.aeroUsdFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod),
                1e18
            ),
            1e6,
            pUsdc8
        ) * (10000 - uint256($.maxSlippageBps)) / 10000;
        if (floor == 0) return; // dust: unsellable, and worth strictly less than one NAV unit
        if (callerFloorRequired && minRewardUsdcOut == 0) revert ZeroMinOut();
        // Behind both gates, as `compoundImpl` keeps its own: a no-op sale must pay nothing. A plain
        // transfer reading no oracle, so the must-complete redeem paths gain no new revert path.
        if (feeAmt > 0) {
            address recipient = $.feeRecipient;
            IERC20(rewardTok).safeTransfer(recipient, feeAmt);
            emit RewardFeePaid(recipient, feeAmt);
        }
        uint256 usdcOut = LeveragedAeroValuation.swapAeroToUsdc(rewardTok, $.usdc, sellAmt, minRewardUsdcOut);
        if (usdcOut < floor) revert BelowOracleFloor();
    }

    /// @notice Execute the staged venue rewrite: verify `p` byte-matches the owner-staged hash and the book
    ///         is FLAT, re-run the full init-grade venue validation, rewrite the venue subset of storage,
    ///         consume the hash. Value-neutral: on a flat book NAV is the idle USDC balance, which no venue
    ///         field touches, so share pricing is continuous across it.
    /// @dev The flat-book gate is deliberately NOT extended to residual collateral or token balances, which
    ///      are rescuable and where a 1-wei donation must not brick a migration.
    function migrateImpl(VenueParams memory p, address currentOwner) public {
        Layout storage $ = _layout();
        bytes32 staged = $.stagedVenueHash;
        if (staged == bytes32(0) || keccak256(abi.encode(keccak256(abi.encode(p)), currentOwner)) != staged) {
            revert VenueNotStaged();
        }
        if ($.tokenId != 0 || $.hedgedDebtA != 0 || $.hedgedDebtB != 0) revert BookNotFlat();
        if (IMoonwellMarket($.mCbBTC).borrowBalanceStored(address(this)) != 0) revert BookNotFlat();
        if (IMoonwellMarket($.mWeth).borrowBalanceStored(address(this)) != 0) revert BookNotFlat();
        address oldPool = $.pool;
        applyVenue(p);
        _clearStagedVenue($); // announced, or a stage-tracking indexer shows a phantom armed stage here
        emit VenueMigrated(oldPool, p.pool);
    }

    /// @notice Open a FRESH position from a flat `Executed` book (the migration's last leg, and the
    ///         recovery from any flatten): `LeveragedAeroManager.executeImpl`'s exact genesis sequence —
    ///         enterMarkets, calm-gate, range at the stored width, supply + borrow at the stored target
    ///         LTV, mint + stake, health assert — deploying the strategy's ENTIRE idle USDC balance.
    /// @dev `deployIdle` cannot serve this state (it `increaseLiquidity`s a `tokenId` that is 0 on a flat
    ///      book), and conversely this is fresh-mint ONLY, so a live position reverts `PositionAlreadyOpen`.
    ///      It takes a `minLiquidity` `execute` does not, because it re-enters the WHOLE book repeatedly
    ///      against live depositors while the in-mint mins are self-referential to the `slot0()` it mints
    ///      at. CONSUMES ANY STAGED HASH, so a `flatten → redeploy` rollback cannot leave an owner
    ///      authorization armed for the proposer to fire later.
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

    /// @notice Validate `p` to the exact standard `_initialize` enforced in-line before this block was
    ///         extracted, then persist the venue subset of `Layout`; the non-migratable core is read from
    ///         live storage. Check order mirrors `_initialize` so the same input reverts with the same
    ///         error; the one ADDITION is the `gauge.pool() == pool` binding.
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
        // L9: the reward-token floor scales an 8dp price, so a non-8dp aggregator would silently mis-scale
        // it by orders of magnitude. Checked here, not at read time, because the floor consumes the raw answer.
        if (IAggregatorV3(p.aeroUsdFeed).decimals() != 8) revert UnexpectedFeedDecimals();
        // The LEG feeds, for the same reason: `readUsd8` rejects a non-8dp answer too, but at the wrong
        // MOMENT — an 18dp leg feed migrates cleanly and then bricks every priced op on the new venue.
        if (IAggregatorV3(p.wethFeed).decimals() != 8) revert UnexpectedFeedDecimals();
        if (IAggregatorV3(p.cbBTCFeed).decimals() != 8) revert UnexpectedFeedDecimals();

        // ── SHAPE DERIVATION — the ONE line that selects the pool shape (see `_initialize`) ──
        bool legBIsAsset_ = p.cbBTC == usdc;

        // Venue identity: the pool must BE the declared leg pair at the declared spacing and each Moonwell
        // borrow market must wrap its declared leg. Ordering is DERIVED here, never assumed.
        if (ICLPool(p.pool).tickSpacing() != p.tickSpacing) revert VenueMismatch();
        address t0 = ICLPool(p.pool).token0();
        bool wethIsToken0_ = t0 == p.weth;
        if (!wethIsToken0_ && t0 != p.cbBTC) revert VenueMismatch();
        if (ICLPool(p.pool).token1() != (wethIsToken0_ ? p.cbBTC : p.weth)) revert VenueMismatch();
        if (IMoonwellMarket(p.mCbBTC).underlying() != p.cbBTC) revert VenueMismatch();
        if (IMoonwellMarket(p.mWeth).underlying() != p.weth) revert VenueMismatch();
        // Symmetric with the two borrow legs: the collateral market must wrap the unit of account.
        if (IMoonwellMarket(mUsdc).underlying() != usdc) revert VenueMismatch();
        // CANONICAL FACTORY BINDING: `pool.factory()` is SELF-ATTESTED, so a hostile pool paired with a
        // hostile "factory" satisfies every probe below for free. Pinning the real CLFactory and requiring
        // it to REGISTER `p.pool` means the attacker must control that factory, not merely deploy a pool.
        if (ICLPool(p.pool).factory() != AERODROME_CL_FACTORY) revert VenueMismatch();
        if (ICLFactory(AERODROME_CL_FACTORY).getPool(p.weth, p.cbBTC, p.tickSpacing) != p.pool) {
            revert VenueMismatch();
        }
        address clFactory = AERODROME_CL_FACTORY;
        if (legBIsAsset_) {
            // ── ASSET-MODE: the three leg-B slots that only make sense for a BORROWED leg ──
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

        // Gauge↔pool binding, BOTH directions: a wrong gauge strands the staked NFT or burns every reward,
        // and `gauge.pool()` is SELF-ATTESTED (a hostile gauge names the real pool for free, then receives
        // the NFT). A real pool's `gauge()` is Voter-written, so agreement means controlling the pool too.
        if (ICLGauge(p.gauge).pool() != p.pool) revert VenueMismatch();
        if (ICLPool(p.pool).gauge() != p.gauge) revert VenueMismatch();

        // TWAP AVAILABILITY: `calmGate` reads `pool.observe([twapWindow, 0])`, which REVERTS on a pool whose
        // oracle cardinality does not yet span the window — `redeploy`, `rerange` and `flatten` would all
        // revert, i.e. adoptable but neither usable nor exitable. (`stageVenue` validates NOTHING, so this
        // and every check here runs at `migrateVenue`, on a book the proposer has already flattened.)
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
        // The reward leg is a THIRD swap venue and `swapAeroToUsdc` hardcodes its route (Aerodrome v2,
        // volatile). A reward token with no v2/USDC pool reverts inside BOTH `compound` and `flatten` the
        // moment a tranche accrues — and `flatten` is `migrateVenue`'s own precondition.
        if (LeveragedAeroValuation.aeroV2VolatilePool(rewardTok, usdc) == address(0)) revert VenueMismatch();

        // Leg decimals drive every token↔USDC conversion — read them, never assume.
        uint8 cbDec = IERC20Metadata(p.cbBTC).decimals();
        uint8 wethDec = IERC20Metadata(p.weth).decimals();
        if (cbDec < 2 || cbDec > 18 || wethDec < 2 || wethDec > 18) revert LegDecimalsOutOfRange();

        // ── RANGE LADDER — ONE copy, in `LeveragedAeroValuation`, shared with the per-cycle `rerange`.
        // THE SKEW COMES FROM STORAGE, not from `p` (that band is venue-independent governance config), but
        // still needs RE-validating because `checkRange`'s one-spacing-per-side span guard couples the live
        // skew to `(width, tickSpacing)`, which a migration rewrites: a destination that would starve one
        // side is rejected HERE, not found as a `DegenerateRange` in `redeploy` on an already-flat book.
        LeveragedAeroValuation.checkBands(p.tickSpacing, p.minWidth, p.maxWidth, $.minSkewBps, $.maxSkewBps);
        LeveragedAeroValuation.checkRange(
            p.width, $.skewBps, p.tickSpacing, p.minWidth, p.maxWidth, $.minSkewBps, $.maxSkewBps
        );

        // Risk invariants against the LIVE collateral factor (fresher than init's); both the read and the
        // five rungs are the Valuation copies shared with the init ladder.
        uint16 cfBps = LeveragedAeroValuation.readCollateralFactor($.comptroller, mUsdc);
        // The lower bound is the only rung not mirrored in that ladder, and `applyVenue` is the shared route
        // for init and migrate, so it closes every path to a stored zero target — a fund that can never lever.
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
        // MUST precede the two persists below — the guard reads the OUTGOING band.
        if ($.minWidth != p.minWidth || $.maxWidth != p.maxWidth) {
            emit WidthBoundsUpdated($.minWidth, $.maxWidth, p.minWidth, p.maxWidth);
        }
        $.minWidth = p.minWidth;
        $.maxWidth = p.maxWidth;
        // The target LTV is the one venue field that is also POLICY, so announce it or a migration becomes
        // the one route that moves leverage policy in silence. Guarded on inequality, so the event means
        // "policy moved", not "a migration happened"; at init it is trivially true, announcing the opener.
        // Same argument for the ceiling, the band and the floor below: `VenueMigrated` carries only the pools,
        // without these a migration moves them in silence past a monitor keyed on the setters' events.
        if ($.targetLtvBps != p.targetLtvBps) emit TargetLtvUpdated($.targetLtvBps, p.targetLtvBps);
        if ($.maxLtvBps != p.maxLtvBps) emit MaxLtvUpdated($.maxLtvBps, p.maxLtvBps);
        if ($.minHealthBps != p.minHealthBps) emit MinHealthUpdated($.minHealthBps, p.minHealthBps);
        $.targetLtvBps = p.targetLtvBps;
        $.maxLtvBps = p.maxLtvBps;
        $.minHealthBps = p.minHealthBps;
        $.usdcCollateralFactorBps = cfBps;
        $.cbBTCDecimals = cbDec;
        $.wethDecimals = wethDec;
        $.wethIsToken0 = wethIsToken0_;
        $.legBIsAsset = legBIsAsset_;
    }

    // ── Bodies of the strategy's four admin policy setters, hosted here for its EIP-170 budget ──

    /// @dev A staged hash authorises a venue whose params carry a `maxLtvBps` / width band / target the
    ///      owner picked under the policy standing AT STAGE TIME. An admin write moves that policy, so the
    ///      authorization is consumed here for the same reason `redeployImpl` consumes it: a stale
    ///      `migrateVenue` must not be firable into a context the owner did not stage it for. The owner
    ///      re-stages against the new policy.
    function _clearStagedVenue(Layout storage $) private {
        if ($.stagedVenueHash != bytes32(0)) {
            $.stagedVenueHash = bytes32(0);
            emit VenueStaged(bytes32(0));
        }
    }

    /// @notice The BODY of `LeveragedAerodromeCLStrategy.setTargetLtv` — validation, persist and emit
    ///         verbatim from the strategy, relocated for its EIP-170 budget and to share the stage clear.
    function setTargetLtvImpl(uint16 targetLtvBps_) public {
        Layout storage $ = _layout();
        if (targetLtvBps_ > $.maxLtvBps) revert TargetLtvExceedsMax();
        if (targetLtvBps_ == 0) revert TargetLtvZero();
        emit TargetLtvUpdated($.targetLtvBps, targetLtvBps_);
        $.targetLtvBps = targetLtvBps_;
        _clearStagedVenue($);
    }

    /// @notice The BODY of `LeveragedAerodromeCLStrategy.setMaxLtv`, on the shared `checkLtvBand` ladder.
    /// @dev The CF is read live (see the entrypoint); `$.usdcCollateralFactorBps` stays the adoption record.
    function setMaxLtvImpl(uint16 maxLtvBps_) public {
        Layout storage $ = _layout();
        uint16 cfBps = LeveragedAeroValuation.readCollateralFactor($.comptroller, $.mUsdc);
        LeveragedAeroValuation.checkLtvBand($.targetLtvBps, maxLtvBps_, $.minHealthBps, cfBps);
        emit MaxLtvUpdated($.maxLtvBps, maxLtvBps_);
        $.maxLtvBps = maxLtvBps_;
        _clearStagedVenue($);
    }

    /// @notice The BODY of `LeveragedAerodromeCLStrategy.setMinHealth`, on `setMaxLtvImpl`'s exact ladder.
    function setMinHealthImpl(uint16 minHealthBps_) public {
        Layout storage $ = _layout();
        uint16 cfBps = LeveragedAeroValuation.readCollateralFactor($.comptroller, $.mUsdc);
        LeveragedAeroValuation.checkLtvBand($.targetLtvBps, $.maxLtvBps, minHealthBps_, cfBps);
        emit MinHealthUpdated($.minHealthBps, minHealthBps_);
        $.minHealthBps = minHealthBps_;
        _clearStagedVenue($);
    }

    /// @notice The BODY of `LeveragedAerodromeCLStrategy.setWidthBounds`, on both ladders `applyVenue` runs.
    /// @dev `checkBands` is the band's shape; `checkRange` is the stored-width containment rule.
    function setWidthBoundsImpl(uint24 minWidth_, uint24 maxWidth_) public {
        Layout storage $ = _layout();
        int24 spacing = $.tickSpacing;
        uint16 minSkew = $.minSkewBps;
        uint16 maxSkew = $.maxSkewBps;
        LeveragedAeroValuation.checkBands(spacing, minWidth_, maxWidth_, minSkew, maxSkew);
        LeveragedAeroValuation.checkRange($.width, $.skewBps, spacing, minWidth_, maxWidth_, minSkew, maxSkew);
        emit WidthBoundsUpdated($.minWidth, $.maxWidth, minWidth_, maxWidth_);
        $.minWidth = minWidth_;
        $.maxWidth = maxWidth_;
        _clearStagedVenue($);
    }

    /// @notice The strategy's full `LayoutView` read out of diamond storage — the BODY of
    ///         `LeveragedAerodromeCLStrategy.layout()`, hosted here for the strategy's EIP-170 budget.
    /// @dev Field-by-field, not a struct literal: a 51-field literal overflows the 16-live-variable stack
    ///      window under via_ir. Solc emits no library call-protection guard for views, so a direct call on
    ///      the deployed library reads the LIBRARY's own all-zero slot — reach it via `strategy.layout()`.
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
        v.compoundFeeBps = $.compoundFeeBps;
        v.feeRecipient = $.feeRecipient;
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
    ///         marshalled HERE instead of in the strategy, for the strategy's EIP-170 budget.
    /// @dev An internal jump into `applyVenue`, not a second copy of the ladder; `migrateVenue` still calls
    ///      it directly, so both entries share one validation path. Field-by-field for `layoutView`'s reason.
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
