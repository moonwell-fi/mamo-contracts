// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {BaseStrategy} from "./BaseStrategy.sol";
import {LeveragedAeroManager} from "./LeveragedAeroManager.sol";
import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {LeveragedAeroVenue} from "./LeveragedAeroVenue.sol";

import {ILeveragedAeroVault} from "./interfaces/ILeveragedAeroVault.sol";
import {Position} from "./interfaces/IPriceRouter.sol";
import {ICLGauge, INonfungiblePositionManager} from "./interfaces/ISlipstream.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev The vault's fund-capacity ceiling, read by `deposit`; declared locally, not on `ILeveragedAeroVault`.
interface ILeveragedAeroVaultCapacity {
    function maxTotalAssets() external view returns (uint256);
}

/// @title LeveragedAerodromeCLStrategy
/// @notice Leveraged Aerodrome CL strategy on Moonwell collateral. ONE implementation serves TWO pool
///         shapes; which one a clone runs is EMERGENT FROM CONFIG at init (there is no mode flag in
///         `InitParams` — see the `legBIsAsset` derivation in `_initialize`):
///
///         1. TWO BORROWED LEGS — supply the whole USDC deposit as collateral → borrow BOTH legs 50/50
///            by USD → LP them against each other → stake. Net-short both legs.
///         2. ASSET AS A LEG (leg-B slot == usdc, e.g. a cbBTC/USDC pool) — supply PART of the deposit
///            as collateral → borrow ONLY leg A → LP it against the REMAINING USDC → stake.
///            Delta-hedged by that single borrow; the collateral/LP split is solved closed-form by
///            `LeveragedAeroValuation.assetModeSplit`.
///
///         Only the LEG-B slot may be the unit of account; leg A is always a real volatile borrowed leg
///         (it owns the `wethDeliversNative` wrap path). See `LeveragedAeroManager`'s head comment for
///         the invariants each venue path relies on.
///
///         ERC-1167 clone, one per vault (BaseStrategy's constructor locks the template).
///         NAV is oracle-priced via `LeveragedAeroValuation.netEquityUsdc`, fail-closed.
///         `ReentrancyGuardTransient` guards every state-changing external op.
contract LeveragedAerodromeCLStrategy is BaseStrategy, ReentrancyGuardTransient, ERC721Holder {
    using SafeERC20 for IERC20;

    // ── Errors ──
    // The init-validation errors are also declared identically in `LeveragedAeroValuation`, which runs those
    // ladders; same signature == same selector, so they stay on this ABI — not unused, do not delete.
    error NotImplemented();
    error TargetLtvExceedsMax();
    error MinHealthTooLow(); // minHealthBps < 10500 (1.05x floor)
    error FeeRecipientRequired();
    error FeeRecipientIsStrategy(); // feeRecipient == this clone — the skim would never leave
    error MaxLtvExceedsCF(); // maxLtvBps >= Moonwell USDC collateral factor
    error ComptrollerCallFailed();
    error UnhealthyPosition(uint256 ltvBps, uint256 limitBps);
    error InvalidNpmReturn();
    error ExecuteZeroBalance();
    error MoonwellMintFailed(uint256 errCode);
    error MoonwellBorrowFailed(uint256 errCode);
    error NpmMintFailed();
    error NpmApproveFailed();
    error MoonwellRepayFailed(uint256 errCode);
    error MoonwellRedeemFailed(uint256 errCode);
    error InsufficientShares();
    error NavUnpriceable(); // deposit while nav()==0 with supply>0 (worthless book, holders present)
    error FundAtCapacity(uint256 navAfter, uint256 cap); // deposit would cross the vault's maxTotalAssets
    error InsufficientAssetsOut();
    error InsufficientLiquidity();
    error InsufficientIdle();
    error HealthyNoDeleverage();
    error CannotRescuePositionToken();
    // Caller is not the ADMIN (`Ownable(vault()).owner()`, the vault owner / MAMO multisig). The admin holds
    // fund POLICY (`setTargetLtv`) and `rescueToVault`; the proposer keeper holds operations only.
    error NotAdmin();
    // A zero standing target is refused at every route that can store one — `_initialize` and
    // `setTargetLtv`. On an already-levered book a stored zero would make `_unwindLiquidity` strip ALL
    // liquidity, orphaning an UNSTAKED `$.tokenId` with no trustless exit. NOT reachable through
    // `adjustLeverage`, whose target is never stored: a zero there is a full unwind and `_leverDown`
    // already refuses it with `FullUnwindNotSupported` (`flatten` is the real full unwind).
    error TargetLtvZero();
    // `adjustLeverage`'s per-call target is bounded by the STORED standing target — the proposer moves the
    // book toward policy, never past it. Raising policy stays admin-only (`setTargetLtv`).
    error TargetLtvExceedsPolicy(uint16 requested, uint16 policy);
    error OnlySelf();
    error CompoundFeeTooHigh(); // compoundFeeBps > LeveragedAeroValuation.MAX_COMPOUND_FEE_BPS
    error MinHealthMaxLtvConflict();
    error DeleverageTriggerAboveCF(); // minHealthBps * cfBps <= 1e8 — trigger LTV at or above the CF
    error AssetMismatch();
    error UnexpectedAssetDecimals();
    error UnexpectedFeedDecimals(); // AERO/USD aggregator not 8dp (L9 oracle-floor scaling assumption)
    error OracleParamOutOfRange();
    error FastRedeemExceedsLtv(uint256 ltvBps, uint256 maxLtvBps); // fast-path breaches maxLtvBps → use requestRedeem
    error NotRequestOwner();
    error RequestSettled();
    error FulfillWindowOpen(); // emergencyRedeem before FULFILL_WINDOW elapsed
    error ZeroAssetsOut(); // fast redeem would pay 0 (nav()==0 or dust shares floor to 0) — burn-for-zero
    error LegDecimalsOutOfRange(); // a leg token reports decimals outside [2, 18]
    error VenueMismatch(); // pool/market wiring does not match the declared legs or tickSpacing
    error UnsupportedLeg(); // leg A is the unit of account, or a leg is the gauge reward token
    // asset-mode lever-up needs `needed` idle USDC to pair with the borrowed leg A, book holds `available`.
    // Raised by `LeveragedAeroValuation.assetModeLeverUpPair`; re-declared here (same selector) so it is on
    // the strategy's public ABI for the rebalancer / frontend.
    error InsufficientIdleForLeverUp(uint256 needed, uint256 available);
    // rerange width off the tickSpacing grid / outside [minWidth, maxWidth], OR a skew outside (0, 1e4) or one
    // that starves either side below a single tickSpacing. ONE error for both knobs: they validate together.
    error OutOfBounds();
    error ZeroShares(); // deposit would mint 0 shares (dust assets against a large book) — pay-for-nothing
    error NotVaultOwner(); // stageVenue caller is not the vault's owner (the venue-selection authority)
    // A lever-down that would repay the ENTIRE debt is rejected — it would orphan the staked position NFT;
    // use `flatten()`. Declared in the manager too (same selector) so it is on the strategy's public ABI.
    error FullUnwindNotSupported();
    // `LeveragedAeroVenue` is DELEGATECALLED, so its reverts come from THIS address: the whole migration error
    // set is re-declared here (matching selectors, zero runtime bytes) to keep it on the strategy's ABI.
    error VenueNotStaged(); // migrate without a staged hash, or params that do not match it
    error BookNotFlat(); // migrate while a CL position, hedged basis, or leg debt is still live
    error PositionAlreadyOpen(); // redeploy on a book that already has a position (use deployIdle)
    error ZeroMinOut(); // flatten with a reward balance to sell but no caller floor
    error BelowOracleFloor(); // a reward-sale fill landed under the AERO/USD oracle floor (L9)
    error InsufficientIdleAfterFlatten(uint256 idle, uint256 minIdle); // caller's aggregate unwind floor

    // ── Venue-migration events (emitted from this address via delegatecall; see above) ──
    event VenueStaged(bytes32 venueHash);
    event Flattened(uint256 idleUsdc);
    event VenueMigrated(address indexed oldPool, address indexed newPool);

    // ── Constants ──
    /// @dev Position `kind` tag for the PriceRouter adapter registry.
    bytes32 public constant POSITION_KIND = keccak256("LEVERAGED_AERO_CL");

    /// @dev ERC-4626-style virtual share offset, APPLIED ON ISSUANCE ONLY: `deposit` prices at
    ///      `assets × (supply + 1e6) / (nav + 1)` while every exit is exact pro-rata. `1e6` matches the
    ///      vault's `decimals() == asset.decimals() + 6` and the genesis rate `activateStrategy` seeds at.
    uint256 private constant SHARES_VIRTUAL_OFFSET = 1e6;

    /// @dev Deadman window: once this elapses on an unfulfilled `requestRedeem`, its owner can
    ///      `emergencyRedeem` trustlessly. 2 days tolerates a weekend backend outage.
    uint256 private constant FULFILL_WINDOW = 2 days;

    // ── Async-redeem queue events ──
    // `owner` stays topic2 on all four, so an indexer keyed on the requesting account keeps working.
    event RedeemRequested(uint256 indexed id, address indexed owner, address indexed recipient, uint256 shares);
    event RedeemFulfilled(uint256 indexed id, address indexed owner, address indexed recipient, uint256 assetsOut);
    event RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares);
    event RedeemEmergency(uint256 indexed id, address indexed owner, uint256 assetsOut);

    /// @dev The admin re-set the fund's STANDING target LTV. POLICY only — it moves nothing by itself; the
    ///      next `adjustLeverage` / `deployIdle` / `compound` sizes at the new value.
    event TargetLtvUpdated(uint16 previousBps, uint16 newBps);

    /// @dev `setMaxLtv` / `setWidthBounds`, and `applyVenue` (init + `migrateVenue`) inequality-guarded;
    ///      emitted from THIS address by the delegatecalled `LeveragedAeroVenue`, which mirror-declares them.
    event MaxLtvUpdated(uint16 previousBps, uint16 newBps);
    event WidthBoundsUpdated(uint24 previousMinWidth, uint24 previousMaxWidth, uint24 newMinWidth, uint24 newMaxWidth);

    /// @dev Mirror of `LeveragedAeroManager.RewardFeePaid` / `LeveragedAeroVenue.RewardFeePaid` (both
    ///      delegatecalled, so both log from THIS address). `aeroAmount` of a realized reward tranche was
    ///      skimmed to `recipient`, in AERO (18dp) — by `compound`, `flatten`, or the async-redeem sale.
    ///      TERMINAL `settle` alone waives it.
    event RewardFeePaid(address indexed recipient, uint256 aeroAmount);

    // ── Degradation markers for the DELIBERATE fail-opens in this stack. Naming: `…Deferred` = an optional
    //    ACTION was skipped; `…Degraded` = a GUARD fell back and the op ran with less protection. ──

    /// @dev The terminal settle's best-effort sale of the final reward tranche was skipped (stale/paused reward
    ///      feed, failed route). The tranche stays on the now-`Settled` strategy: `rescueToVault(rewardToken)`.
    event SettleRewardSaleDeferred();

    /// @dev An async redeem's best-effort sale of the tranche its OWN unwind auto-claimed was skipped; the
    ///      redeemer was paid `f × (assets − reward)` and the tranche stayed with the stayers. Clear with `compound`.
    event RedeemRewardSaleDeferred();

    /// @dev Mirror of `LeveragedAeroManager.RedeemSweepFloorsDegraded` (the manager is delegatecalled, so it
    ///      emits from THIS address). An async redeem's closing leg sweeps ran with their Chainlink floors at ZERO.
    event RedeemSweepFloorsDegraded();

    /// @dev Mirror of `LeveragedAeroVenue.WithdrawIdleBoundDegraded` (delegatecalled, so it logs from THIS
    ///      address). A `withdrawIdle` could not price its policy bound at the hardened reader and re-derived the
    ///      SAME line from Moonwell's own snapshot; the bound still applied and NAV is unaffected.
    event WithdrawIdleBoundDegraded();

    /// @dev Mirror of `LeveragedAeroValuation.HedgeLegMeasureDegraded` (delegatecalled, so it logs from THIS
    ///      address). One leg's accrued Moonwell debt could not be read, so that leg's borrow-interest hedge
    ///      was SKIPPED for the harvest and carries to the next one; `market` is the leg's Moonwell market.
    event HedgeLegMeasureDegraded(address market);

    // ── Access control ──

    /// @dev ADMIN == `Ownable(vault()).owner()` — the MAMO multisig. DERIVED, never stored, so an owner handover
    ///      on the vault carries the strategy's admin rights with it. The POLICY half of the split;
    ///      `onlyProposer` is the operations half, which may lower the target but never raise it and never move
    ///      tokens. Depends on the vault reverting `renounceOwnership` and being `Ownable2Step`.
    ///      A function, not modifier-inline code: four entrypoints carry it, and each inline copy costs bytes.
    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    function _requireAdmin() private view {
        if (msg.sender != _vaultOwner()) revert NotAdmin();
    }

    /// @dev Shared with `stageVenue`, which raises a DIFFERENT error off the same authority.
    function _vaultOwner() private view returns (address) {
        return Ownable(vault()).owner();
    }

    // ── Initialisation params (ABI-encoded → BaseStrategy.initialize → _initialize) ──
    //
    // LEG SLOTS, not token identities. The `weth`/`mWeth`/`wethFeed` slots are leg A (the slot that
    // may be delivered natively on borrow — see `wethDeliversNative`); `cbBTC`/`mCbBTC`/`cbBTCFeed`
    // are leg B. The names are historical (the first deployment was cbBTC/WETH); ANY Slipstream pool
    // whose two tokens have Moonwell borrow markets and Chainlink feeds can fill them. Decimals and
    // pool token0/token1 ordering are DERIVED at init, never assumed.

    struct InitParams {
        // ── Token addresses ──
        address usdc; // USDC (6dp) — unit of account + collateral asset
        address mUsdc; // Moonwell mUSDC market (collateral)
        address mCbBTC; // Moonwell market for leg B (borrow leg)
        address mWeth; // Moonwell market for leg A (borrow leg)
        address comptroller; // Moonwell Comptroller (enterMarkets / markets())
        address cbBTC; // leg B underlying
        address weth; // leg A underlying (the natively-wrappable slot)
        // ── Venue addresses ──
        address pool; // Aerodrome Slipstream CL pool for the leg A/B pair
        address npm; // Slipstream Non-Fungible Position Manager
        address gauge; // Gauge for the pool (AERO rewards)
        address swapRouter; // Slipstream CL Swap Router
        // ── Chainlink feeds ──
        address cbBTCFeed; // leg B/USD aggregator (8dp)
        address wethFeed; // leg A/USD aggregator (8dp)
        address usdcFeed; // USDC/USD aggregator (8dp)
        address sequencerFeed; // L2 Sequencer Uptime feed (Base)
        address aeroUsdFeed; // AERO/USD aggregator (8dp) — floors the compound reward swap (L9)
        // ── Oracle config ──
        uint256 maxDelay; // Max feed staleness (seconds)
        uint256 gracePeriod; // Sequencer grace period after restart (seconds)
        uint16 calmDeviationTicks; // Max |spotTick − twapTick| before calm-gate fires
        uint32 twapWindow; // TWAP lookback for the calm-gate (seconds)
        // ── Pool config ──
        int24 tickSpacing; // LP pool tickSpacing (asserted against `pool.tickSpacing()`)
        int24 cbBTCSwapTickSpacing; // tickSpacing of the leg B↔USDC swap pool (independent of the LP pool's)
        int24 wethSwapTickSpacing; // tickSpacing of the leg A↔USDC swap pool
        bool wethDeliversNative; // leg A's Moonwell market pays native ETH on borrow (wrap it to leg A)
        uint24 width; // initial full range width in ticks (split across the tick by `skewBps`)
        uint24 minWidth; // lower bound for a proposer-supplied rerange width
        uint24 maxWidth; // upper bound for a proposer-supplied rerange width
        uint16 skewBps; // initial fraction of `width` placed BELOW the tick (1e4 scale; 5000 == centred)
        uint16 minSkewBps; // lower bound for a proposer-supplied rerange skew (governance band)
        uint16 maxSkewBps; // upper bound for a proposer-supplied rerange skew (governance band)
        // ── Risk params ──
        uint16 targetLtvBps; // Target LTV in bps (e.g. 5000 = 50%)
        uint16 maxLtvBps; // Maximum LTV cap in bps (e.g. 6500 = 65%)
        uint16 minHealthBps; // Minimum health ratio in bps (e.g. 12000 = 1.20×)
        uint16 maxSlippageBps; // Maximum slippage tolerance for swaps in bps
        // ── Fee params ──
        uint16 compoundFeeBps; // In-kind skim of each harvested AERO tranche, bps (500 = 5%); cap 1000
        address feeRecipient; // Receives the skimmed AERO (must be non-zero if compoundFeeBps > 0)
    }

    // ── ERC-7201 namespaced (diamond) storage ──
    // CORRUPTION-CRITICAL: `Layout`, `STORAGE_SLOT`, `_layout()` and `RedeemRequest` must stay byte-identical
    // across the strategy / manager / venue delegatecall peers — see test/leveraged-aero/layout_parity.sh.

    /// @dev Escrowed async-redeem request (Lane-B-style, but NO price freeze — shares keep bearing
    ///      PnL until execution, so `cancelRedeem` is not a free look-back option). Byte-identical
    ///      to the manager's `RedeemRequest`.
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
        // fee params
        uint16 compoundFeeBps; // in-kind skim of each harvested AERO tranche, bps
        address feeRecipient;
        // ── appended for the L9 compound oracle floor (keep byte-identical in the manager) ──
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

    /// @dev Memory-returnable mirror of `Layout` minus the trailing `redeemRequests` mapping
    ///      (a struct with a nested mapping can't be an external return). Field names match
    ///      `Layout` 1:1 so `layout().field` accessors are unchanged.
    struct LayoutView {
        address usdc;
        address mUsdc;
        address mCbBTC;
        address mWeth;
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
        address comptroller;
        address npm;
        address gauge;
        address swapRouter;
        int24 tickSpacing;
        uint16 targetLtvBps;
        uint16 maxLtvBps;
        uint16 minHealthBps;
        uint16 maxSlippageBps;
        uint16 usdcCollateralFactorBps;
        uint256 tokenId;
        int24 posTickLower;
        int24 posTickUpper;
        uint16 compoundFeeBps;
        address feeRecipient;
        address aeroUsdFeed;
        uint256 nextRedeemRequestId;
        uint8 cbBTCDecimals;
        uint8 wethDecimals;
        bool wethIsToken0;
        bool wethDeliversNative;
        int24 cbBTCSwapTickSpacing;
        int24 wethSwapTickSpacing;
        uint24 width;
        uint24 minWidth;
        uint24 maxWidth;
        bool legBIsAsset;
        uint16 skewBps;
        uint16 minSkewBps;
        uint16 maxSkewBps;
        uint128 hedgedDebtA;
        uint128 hedgedDebtB;
        bytes32 stagedVenueHash;
    }

    /// @notice Full strategy storage layout (single accessor for tests / off-chain reads), minus the
    ///         `redeemRequests` mapping (queried via `redeemRequest(id)`).
    function layout() external view returns (LayoutView memory v) {
        return LeveragedAeroVenue.layoutView();
    }

    /// @notice The borrowed PRINCIPAL each leg's LP side currently hedges, and therefore the
    ///         UNHEDGED accrued borrow interest a rebalancer can compute as
    ///         `borrowBalanceStored(market) − hedgedDebt*`. `compound()` neutralises that difference
    ///         out of harvest proceeds (see `LeveragedAeroValuation.hedgeBorrowInterest`), so a
    ///         keeper can use these two numbers to decide whether a harvest is worth calling and to
    ///         verify afterwards that the drift went back to ~0. Leg B is structurally 0 in
    ///         asset-mode (leg B is the unit of account there and is never borrowed).
    /// @dev Same storage reads as `layout().hedgedDebtA/B`; exposed as its own selector purely for
    ///      keeper ergonomics, exactly as `targetLtvBps()` is.
    function hedgedDebt() external view returns (uint128 legA, uint128 legB) {
        Layout storage $ = _layout();
        return ($.hedgedDebtA, $.hedgedDebtB);
    }

    /// @notice The Chainlink min-out floors for the two residual leg sweeps that END a proportional redeem:
    ///         `oracleValue(amount) × (1 − maxSlippageBps)` per leg, on the same hardened 8dp reads every other
    ///         priced path uses. Reverts (fail-closed) on a stale feed / down sequencer.
    /// @dev EXISTS TO BE `try`-ABLE: `redeemUnwindImpl` runs under DELEGATECALL, so its own price reads are
    ///      internal and uncatchable, and `emergencyRedeem` must still complete with the floors falling back to 0.
    ///      The math is in `LeveragedAeroValuation.sweepFloors`; this is marshalling only.
    function redeemSweepFloors(uint256 cbAmt, uint256 wethAmt)
        external
        view
        returns (uint256 cbFloor, uint256 wethFloor)
    {
        return LeveragedAeroValuation.sweepFloors(_config(), cbAmt, wethAmt, _layout().maxSlippageBps);
    }

    /// @notice A single escrowed async-redeem request by id (queue introspection for tests / UI).
    function redeemRequest(uint256 id) external view returns (RedeemRequest memory) {
        return _layout().redeemRequests[id];
    }

    /// @notice The fund's STANDING target LTV in bps — policy, set at init and re-set ONLY by the admin's
    ///         `setTargetLtv`. This is what `execute` / `deployIdle` / `compound` size their borrow at, and the
    ///         CEILING on `adjustLeverage`'s per-call target, so a rebalancer reads it first.
    function targetLtvBps() external view returns (uint16) {
        return _layout().targetLtvBps;
    }

    /// @dev Some Moonwell markets (mWETH on Base) deliver native ETH on `borrow()`; when
    ///      `wethDeliversNative` is set the strategy wraps it into the leg-A token before use.
    ///      Without this receiver that borrow's ETH transfer reverts.
    receive() external payable {}

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Leveraged Aerodrome CL";
    }

    // ── Initialization ──

    /// @notice Validate `InitParams`, read the USDC collateral factor from Moonwell, and persist
    ///         everything to diamond storage. Validation order matches the per-field checks below
    ///         so the same input reverts with the same error.
    function _initialize(bytes calldata data) internal override {
        InitParams memory p = abi.decode(data, (InitParams));

        if (p.usdc == address(0)) revert ZeroAddress();
        if (p.mUsdc == address(0)) revert ZeroAddress();
        if (p.mCbBTC == address(0)) revert ZeroAddress();
        if (p.mWeth == address(0)) revert ZeroAddress();
        if (p.comptroller == address(0)) revert ZeroAddress();
        if (p.cbBTC == address(0)) revert ZeroAddress();
        if (p.weth == address(0)) revert ZeroAddress();
        if (p.pool == address(0)) revert ZeroAddress();
        if (p.npm == address(0)) revert ZeroAddress();
        if (p.gauge == address(0)) revert ZeroAddress();
        if (p.swapRouter == address(0)) revert ZeroAddress();
        if (p.cbBTCFeed == address(0)) revert ZeroAddress();
        if (p.wethFeed == address(0)) revert ZeroAddress();
        if (p.usdcFeed == address(0)) revert ZeroAddress();
        if (p.sequencerFeed == address(0)) revert ZeroAddress();
        // `aeroUsdFeed` (zero-check + the 8dp L9 assertion) is validated inside
        // `LeveragedAeroVenue.applyVenue`: it is in the migratable venue subset, attested with the gauge.

        // L7: the strategy's unit of account MUST be the vault's ERC-4626 asset, and the
        // SHARES_VIRTUAL_OFFSET (1e6) hardcodes a 6-decimal asset — reject any other wiring.
        if (p.usdc != IERC4626(vault()).asset()) revert AssetMismatch();
        if (IERC20Metadata(p.usdc).decimals() != 6) revert UnexpectedAssetDecimals();

        // ── VENUE BLOCK — extracted verbatim to `LeveragedAeroVenue.applyVenue` so `migrateVenue` re-runs the
        // EXACT same checks in order. The lib reads usdc / mUsdc / usdcFeed / comptroller from live storage.
        Layout storage $ = _layout();
        $.usdc = p.usdc;
        $.mUsdc = p.mUsdc;
        $.usdcFeed = p.usdcFeed;
        $.comptroller = p.comptroller;
        // Written HERE, not with the other oracle params below: `applyVenue`'s TWAP probe calls
        // `pool.observe([$.twapWindow, 0])`, so a downstream write would make the init-time probe vacuous.
        if (p.twapWindow == 0 || p.twapWindow > 1 days) revert OracleParamOutOfRange();
        $.twapWindow = p.twapWindow;
        // Up here for the same reason. The SKEW triple is venue-independent governance config, but the
        // one-spacing-per-side span guard couples it to `(width, tickSpacing)`, which a migration rewrites, so
        // `applyVenue` re-validates the STORED skew against the destination's grid.
        $.skewBps = p.skewBps;
        $.minSkewBps = p.minSkewBps;
        $.maxSkewBps = p.maxSkewBps;
        // `applyVenueFromInit` marshals the venue subset of `InitParams` into `VenueParams`, then calls
        // `applyVenue` — so init and `migrateVenue` share ONE validation + store path.
        LeveragedAeroVenue.applyVenueFromInit(p);

        // What remains in this frame is the non-migratable core ladder: the five ORACLE rungs and the fee rungs.
        // The risk and range ladders are venue-scoped and already ran inside `applyVenue`; `checkRiskParams`
        // re-runs the risk rungs cheaply to keep the relocated ladder in its original rung order.
        uint16 cfBps = LeveragedAeroValuation.readCollateralFactor(p.comptroller, p.mUsdc);
        LeveragedAeroValuation.checkRiskParams(
            p.targetLtvBps,
            p.maxLtvBps,
            p.minHealthBps,
            cfBps,
            p.maxDelay,
            p.gracePeriod,
            p.twapWindow,
            p.calmDeviationTicks,
            p.maxSlippageBps
        );
        LeveragedAeroValuation.checkFeeParams(p.compoundFeeBps, p.feeRecipient);

        // Non-migratable core stores; the venue subset was persisted inside `applyVenue` above.
        $.npm = p.npm;
        $.swapRouter = p.swapRouter;
        $.sequencerFeed = p.sequencerFeed;
        $.maxDelay = p.maxDelay;
        $.gracePeriod = p.gracePeriod;
        $.calmDeviationTicks = p.calmDeviationTicks;
        // `$.twapWindow` was stored ahead of `applyVenue` — see the note there.
        $.maxSlippageBps = p.maxSlippageBps;
        $.compoundFeeBps = p.compoundFeeBps;
        $.feeRecipient = p.feeRecipient;
        // tokenId / posTickLower / posTickUpper default to 0 (set in _execute).
    }

    // ── NAV ──

    /// @notice Oracle NAV of the levered book, in USDC (6dp). Flat book (`tokenId == 0`) → face value of the
    ///         strategy's USDC wherever it sits, raw PLUS parked mUSDC collateral, with NO oracle. Active
    ///         position → `netEquityUsdc`, fail-closed on any oracle/calm failure or ≤0 equity. Vault float
    ///         excluded (M2).
    function nav() public view virtual returns (uint256) {
        Layout storage $ = _layout();
        if ($.tokenId == 0) {
            // Flat book: strategy-controlled USDC only (face, 6dp, NO ORACLE — the property `flatten` relies
            // on). Vault float is excluded — `strategy.redeem` never pays it out. THE COLLATERAL TERM IS
            // MANDATORY: `supplyIdle` can park a flat book's whole pot in mUSDC, and pricing that off the raw
            // balance alone would read 0, bricking later deposits with `NavUnpriceable`.
            return LeveragedAeroValuation.usdcAvailable($.usdc, $.mUsdc, address(this));
        }
        // Active position: read ticks + liquidity from the NPM and delegate to the valuation lib.
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _npmPositionData();
        return LeveragedAeroValuation.netEquityUsdc(_config(), address(this), tickLower, tickUpper, liquidity);
    }

    /// @dev Reads only ticks + liquidity (fields 5-7) from the NPM `positions()` 12-tuple via
    ///      staticcall + assembly — avoids putting all 12 returns on the stack (Yul IR 16-slot limit).
    ///      Each is a 32-byte word at `ret + 0x20 + N*0x20`: [5] tickLower=0xC0, [6] tickUpper=0xE0,
    ///      [7] liquidity=0x100.
    function _npmPositionData() internal view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address npm_ = _layout().npm;
        uint256 tokenId_ = _layout().tokenId;
        bool ok;
        bytes memory ret;
        (ok, ret) = npm_.staticcall(abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_));
        if (!ok) revert InvalidNpmReturn();
        // Require at least 9 full words of returndata (0x120 bytes) so the mload
        // at offset 0x100 (field 7, liquidity) cannot read past the allocated buffer.
        if (ret.length < 0x120) revert InvalidNpmReturn();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // ret + 0x20 = start of returndata; field 5 = +0x20+5*0x20 = +0xC0
            tickLower := mload(add(ret, 0xC0))
            tickUpper := mload(add(ret, 0xE0))
            liquidity := mload(add(ret, 0x100))
        }
    }

    /// @notice HEALTH MARKER FOR `nav()`'s ONE FAIL-OPEN: `false` while the gauge-side `earned()` read that
    ///         `nav()` prices is failing, `true` when it answers or there is nothing to read (`tokenId == 0`). A
    ///         sustained `false` means `nav()` is UNDERSTATING the book by the unclaimed reward accrual on every
    ///         deposit and every block — poll it. A `view` cannot emit, so this is the instrumentation.
    function rewardReadOk() external view returns (bool) {
        Layout storage $ = _layout();
        return LeveragedAeroValuation.rewardReadOk($.gauge, $.tokenId);
    }

    // ── Positions (Lane A reporting for the PriceRouter) ──

    /// @inheritdoc IStrategy
    /// @notice Reports the single levered-CL position. `ref` encodes the market addresses the
    ///         `LEVERAGED_AERO_CL` adapter needs to verify the venues.
    function positions() external view override returns (Position[] memory pos) {
        Layout storage $ = _layout();
        pos = new Position[](1);
        pos[0] = Position({venue: $.pool, kind: POSITION_KIND, ref: abi.encode($.gauge, $.mUsdc, $.mCbBTC, $.mWeth)});
    }

    /// @inheritdoc IStrategy
    /// @dev Self-fee'd: the fund's only fee is the in-kind `compoundFeeBps` skim this strategy takes off each
    ///      harvested AERO tranche (see `compound`). Any vault-side settle-fee distribution MUST be skipped —
    ///      a float-delta PnL would misread net deposits as profit and charge a second fee.
    ///      `LeveragedAeroVault` has no fee path at all, so there is nothing to skip.
    function selfManagesFees() external pure override returns (bool) {
        return true;
    }

    // ── Execute / settle ──

    /// @notice Open the levered cbBTC/WETH CL position: supply USDC → enterMarkets → borrow
    ///         cbBTC+WETH → wrap ETH → mint Slipstream CL → stake gauge → assert health. The venue
    ///         sequence lives in `LeveragedAeroManager.executeImpl()` (delegatecalled, so
    ///         `address(this)` / `_layout()` resolve to this clone).
    function _execute() internal override {
        // `minLiquidity == 0`: activation is a once-per-lifetime, owner-driven open on a seed-only book and the
        // base signature carries no floor. The two-sided `maxSlippageBps` mins inside the mint still apply.
        LeveragedAeroManager.executeImpl(0);
    }

    /// @notice Full proportional unwind to the vault — remove 100% liquidity, repay both Moonwell borrows
    ///         (self-funding any IL/fee shortfall), redeem collateral, sweep residual legs to USDC, clear state —
    ///         in `settleImpl()`. The final reward tranche is sold and the realized USDC pushed to the vault here.
    function _settle() internal override {
        LeveragedAeroManager.settleImpl();
        // Sell the reward tranche the unwind's `gauge.withdraw` auto-claimed; `settleImpl` sweeps only the two
        // LEG tokens, so otherwise the tranche never reaches the USDC pot `redeemSettled` pays holders from.
        // BEST-EFFORT, and that is the asymmetry with `flatten` (which sells the same tranche FAIL-CLOSED):
        // `settle()` is TERMINAL, so a stale reward feed must not block the fund's only exit. The sale still
        // fails closed in its own frame, so a caught revert leaves the tranche rescuable, never sold blind.
        // `skim == false`: THE ONE REALIZATION PATH THAT WAIVES THE FEE — no stayer is left to protect.
        try this.sellRewardSelf(false) {}
        catch {
            emit SettleRewardSaleDeferred();
        }
        Layout storage $ = _layout();
        // Flat-book invariant, completed here: `settleImpl`'s repays normally clamp both hedged bases to 0,
        // except in the pathological case where residual debt could not be covered and no repay runs.
        $.hedgedDebtA = 0;
        $.hedgedDebtB = 0;
        _pushAllToVault($.usdc);
    }

    /// @dev Self-only external wrapper so a caller can sell an auto-claimed reward tranche best-effort via
    ///      `try/catch` (H3): its own frame is what rolls back ONLY the sale on a stale reward feed / bad route.
    ///      Two callers: the terminal `_settle`, and `LeveragedAeroManager.redeemUnwindImpl` (which runs under
    ///      DELEGATECALL and cannot `try` its own internal reverts). Not `nonReentrant`: the entry points are.
    /// @param skim Pay the fund's fee: TRUE from the async redeem, FALSE from the terminal `_settle`.
    function sellRewardSelf(bool skim) external {
        if (msg.sender != address(this)) revert OnlySelf();
        LeveragedAeroVenue.sellRewardImpl(skim);
    }

    /// @dev THE ASYNC-REDEEM SIDE OF THE SAME SALE, plus the accounting it needs.
    ///      `LeveragedAeroManager.redeemUnwindImpl` calls this right after its `_unwindLiquidity`, whose
    ///      `gauge.withdraw` auto-claims a reward tranche on EVERY async redeem; without it the redeemer is paid
    ///      `f × (assets − reward)` while 100% of the tranche stays with the stayers, which `nav()` prices — a
    ///      nav-vs-payout inconsistency. `gauge.withdraw` is all-or-nothing per NFT, so `(1−f)·proceeds` is
    ///      RETURNED for the manager to add to `stayersIdle`. BEST-EFFORT (the deadman routes through here, so a
    ///      stale reward feed must not block it), still failing closed inside `sellRewardSelf`'s own frame.
    /// @dev THE SALE SKIMS. All-or-nothing per NFT means it realizes 100% of the book's accrual with no
    ///      later `compound` left to charge it, and realizing NET is what keeps `nav()`'s mark honest.
    /// @return stayersShare `(1−f)` of the realised USDC proceeds; 0 when nothing sold.
    function sellRedeemRewardSelf(uint256 shares, uint256 supply) external returns (uint256 stayersShare) {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20 usdc_ = IERC20(_layout().usdc);
        uint256 sold = usdc_.balanceOf(address(this));
        try this.sellRewardSelf(true) {}
        catch {
            emit RedeemRewardSaleDeferred();
        }
        sold = usdc_.balanceOf(address(this)) - sold;
        return sold - Math.mulDiv(sold, shares, supply);
    }

    /// @notice Oracle-priced deposit: mint vault shares proportional to the PRE-deposit NAV (fail-closed on
    ///         the PRICE — a down oracle reverts) via the ERC-4626 virtual-offset formula, then pull the USDC.
    ///         Deposited USDC sits idle until a proposer calls `deployIdle()`.
    /// @param assets    USDC to deposit (6dp).
    /// @param minShares Minimum vault shares to accept (slippage guard).
    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (_state != State.Executed) revert NotExecuted();
        uint256 navPre = nav();
        address vault_ = vault();
        // FUND CAPACITY CEILING (`vault.maxTotalAssets`, USDC 6dp; `0` == unlimited). Enforced HERE because this
        // is the one path every share-minting deposit takes, so the ceiling binds the FUND, not a wrapper layer
        // — and not in `strategyMint`, which is issuance policy, not fund policy. Checked BEFORE the
        // transfer, measured on the post-deposit book (`navPre + assets`), and a crossing deposit is rejected.
        {
            uint256 cap = ILeveragedAeroVaultCapacity(vault_).maxTotalAssets();
            if (cap != 0 && navPre + assets > cap) revert FundAtCapacity(navPre + assets, cap);
        }
        IERC20(_layout().usdc).safeTransferFrom(msg.sender, address(this), assets);
        uint256 supply = IERC20(vault_).totalSupply();
        // Guard the navPre==0 share-inflation case: with holders present and a worthless book the
        // mulDiv denominator collapses to 1, minting ~assets×(supply+offset) shares (dilutes stayers).
        // First deposit (supply==0) legitimately has navPre==0 (empty book) → must stay allowed.
        if (navPre == 0 && supply > 0) revert NavUnpriceable();
        shares = Math.mulDiv(assets, supply + SHARES_VIRTUAL_OFFSET, navPre + 1);
        // Reject a pay-for-nothing deposit (mirrors redeem's `ZeroAssetsOut`): dust `assets` against
        // a large book floor to 0 shares, and with the common `minShares == 0` the guard below would
        // fall through and take the USDC for no claim.
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert InsufficientShares();
        ILeveragedAeroVault(vault_).strategyMint(msg.sender, shares);
    }

    /// @notice Supply `amount` of the strategy's RAW idle USDC to Moonwell as collateral, so it earns supply
    ///         interest instead of sitting dead. Does NOT borrow and does NOT touch the LP; reverts
    ///         `InsufficientIdle` above the raw balance. A KEEPER OP, not part of `deposit`: a paused or capped
    ///         Moonwell market must not decide whether the fund can take money, and the raw float is the
    ///         ORACLE-FREE IL-cover budget of `redeemUnwindImpl` Phase 1 — how much to leave un-supplied is the
    ///         operator's policy dial. The supplied USDC is LEVERAGEABLE by the next `adjustLeverage`, and this
    ///         works on a flat `Executed` book, which is why `nav()`'s flat branch must count the collateral term.
    /// @param amount USDC (6dp) to supply; must be ≤ the raw USDC balance. Zero is a DELIBERATE silent no-op.
    function supplyIdle(uint256 amount) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.supplyIdleImpl(amount); // raw-balance bound enforced inside (typed)
    }

    /// @notice Deploy `amount` of idle strategy USDC into the levered position (supply + borrow +
    ///         increaseLiquidity + health-assert) via `LeveragedAeroManager.deployIdleImpl()`.
    ///         `amount` IS BOUNDED BY RAW + UN-LEVERED COLLATERAL, not raw + ALL collateral: the manager sizes
    ///         the borrow off the gross `amount` as if it were fresh, not-yet-levered NAV, so funding it from
    ///         collateral that already backs debt would re-lever the same USDC twice and walk LTV toward
    ///         `maxLtvBps` — the capability the admin-only target split denies this `onlyProposer` key. The
    ///         `_unleveredCollateral` bound refuses it with a typed `InsufficientIdle`.
    function deployIdle(uint256 amount, uint256 minLiquidity) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.checkDeployableIdle(amount);
        LeveragedAeroManager.deployIdleImpl(amount, minLiquidity);
    }

    /// @notice Redeem `amount` of the strategy's parked mUSDC collateral back to a RAW USDC balance — the exact
    ///         inverse of `supplyIdle`, which is what makes its float-vs-yield trade-off an operator policy
    ///         rather than a one-way door. Does not borrow, repay, or touch the LP. BOUNDED TO UN-LEVERED
    ///         COLLATERAL (`C − ceil(D·1e4/targetLtvBps)`, 0 at or above target), the mirror of `deployIdle`'s
    ///         funding bound, which is what keeps the post-op book under the standing target. THE BOUND ALWAYS
    ///         RUNS: when the hardened Chainlink reader refuses, the SAME line is re-derived from Moonwell's own
    ///         snapshot and the call emits `WithdrawIdleBoundDegraded`; if even the venue cannot answer,
    ///         `ComptrollerCallFailed`. Exceeding it reverts `InsufficientIdle`. Zero is a silent no-op.
    function withdrawIdle(uint256 amount) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.withdrawIdleImpl(amount);
    }

    /// @notice Compound AERO rewards: claim → swap to USDC (Aerodrome v2 volatile pool, the deepest
    ///         AERO/USDC venue on Base) → redeploy at target leverage, via
    ///         `LeveragedAeroManager.compoundImpl()`. No-op when no AERO is claimable. The swap fill is
    ///         floored by `max(minUsdcOut, oracleFloor)`: the manager derives `oracleFloor` from a
    ///         hardened AERO/USD Chainlink read and post-checks the measured fill (L9), so a thin-pool
    ///         sandwich or a careless/compromised proposer can't realise emissions below the bound. A
    ///         stale AERO feed fail-closes → `compound` reverts (defer the harvest, intended posture).
    ///
    ///         THE FUND'S ONLY FEE IS TAKEN HERE, and on the OTHER TWO REALIZATION PATHS: `compoundFeeBps`
    ///         of each tranche goes to `feeRecipient` IN KIND before the sale, so both floors bind only what
    ///         is sold. `flatten` and the async redeem sell on the same terms (their own unwind auto-claims
    ///         the whole book's accrual); the terminal `settle` alone waives it.
    ///
    ///         A GENUINE NO-OP HAS NO SIDE EFFECTS. `compound` is a keeper-polled entrypoint, so a call with
    ///         nothing to harvest — a flat book, or a staked position with zero claimable AERO — returns
    ///         before touching the gauge. The probe reads `earned + held AERO` (held, so a stray AERO balance
    ///         from a previous partial fill or a donation is still a real harvest). The manager repeats the
    ///         same two bail-outs as belts.
    /// @param minUsdcOut   Minimum USDC out of the AERO→USDC swap (slippage guard).
    /// @param minLiquidity Minimum CL liquidity on the redeploy (slippage guard).
    function compound(uint256 minUsdcOut, uint256 minLiquidity) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        // GENUINE-NO-OP PROBE. Order matches the manager's own bail-outs: flat book first, then the
        // caller-arg belt, then "is there any reward".
        Layout storage $ = _layout();
        uint256 tokenId_ = $.tokenId;
        if (tokenId_ == 0) return; // flat book — nothing staked, nothing to harvest
        // Kept AHEAD of the reward probe so `compound(0, …)` on a LIVE book still reverts loudly whether
        // or not AERO happens to be claimable — the exact order `compoundImpl` had before the probe moved
        // here. Qualified name: the error is declared once, in the manager, and shares one selector.
        if (minUsdcOut == 0) revert LeveragedAeroManager.ZeroMinOut();
        address gauge_ = $.gauge;
        if (ICLGauge(gauge_).earned(address(this), tokenId_) == 0) {
            // Nothing claimable. A stray AERO balance (previous partial fill, donation) is still real
            // yield, so only a zero on BOTH counts is a no-op.
            if (IERC20(ICLGauge(gauge_).rewardToken()).balanceOf(address(this)) == 0) return;
        }
        LeveragedAeroManager.compoundImpl(minUsdcOut, minLiquidity);
    }

    /// @notice Re-range the CL position around the current pool tick WITHOUT swapping, via
    ///         `LeveragedAeroManager.rerangeImpl()`. The calm-gate runs FIRST, so a re-range can never execute
    ///         at a manipulated tick. No swap → principal conserved; the collected ratio cannot match the new
    ///         range, so a remainder of ONE borrowed leg is left idle, which `nav()` prices (NAV-neutral, and
    ///         the remainder stays redeployable). Debt + collateral untouched, so health is preserved; a new
    ///         tokenId is minted (Slipstream ticks are immutable) and the old empty NFT is harmless dust. Not a
    ///         harvest, so no fee is taken: nothing is claimed and nothing is sold.
    /// @param width_   Full range width in ticks; must sit on the tickSpacing grid inside `[minWidth, maxWidth]`.
    /// @param skewBps_ Fraction of `width_` placed BELOW the calm tick, 1e4 scale: `5000` is centred, `3500` puts
    ///                 35% below spot and 65% above. Must be in `(0, 10000)`, inside `[minSkewBps, maxSkewBps]`,
    ///                 and leave both sides spanning at least one `tickSpacing`; both bounds round DOWN onto the
    ///                 grid, so the realised split can sit off the request by up to one spacing.
    /// @dev BOTH knobs are PERSISTED in this frame BEFORE the delegatecall, because `rerangeImpl` takes no range
    ///      params and reads the pair from storage. On a FLAT book it returns early and the persist is all that
    ///      happens — deliberately not a revert, though nothing later consumes the pair.
    function rerange(uint24 width_, uint16 skewBps_, uint256 minLiq0, uint256 minLiq1)
        external
        onlyProposer
        nonReentrant
    {
        if (_state != State.Executed) revert NotExecuted();
        Layout storage $ = _layout();
        LeveragedAeroValuation.checkRange(
            width_, skewBps_, $.tickSpacing, $.minWidth, $.maxWidth, $.minSkewBps, $.maxSkewBps
        );
        $.width = width_;
        $.skewBps = skewBps_;
        LeveragedAeroManager.rerangeImpl(minLiq0, minLiq1);
    }

    /// @notice ADMIN-ONLY POLICY: set the fund's STANDING target LTV, in EITHER direction. Only the admin can
    ///         RAISE it, which is the point of `onlyAdmin`: a compromised rebalancer key can rebalance and
    ///         de-lever, but cannot lever the fund up toward the cap. Sets policy ONLY — the next `execute` /
    ///         `deployIdle` / `compound` / `adjustLeverage` sizes at the new value. NOT state-gated: legal in
    ///         `Pending` (how a multisig corrects an init-time target) and a no-op post-`Settled`.
    /// @param targetLtvBps_ New standing target in bps; must be non-zero (`TargetLtvZero`) and `≤ maxLtvBps`.
    /// @dev CONSUMES ANY STAGED VENUE HASH (like `redeploy`): the owner staged it under the old policy.
    function setTargetLtv(uint16 targetLtvBps_) external onlyAdmin {
        LeveragedAeroVenue.setTargetLtvImpl(targetLtvBps_);
    }

    /// @notice ADMIN-ONLY POLICY: set the OPERATIONAL LTV CEILING — the `maxLtvBps` belt `_assertHealthy`
    ///         and the fast-redeem gate measure against. Not state-gated, like `setTargetLtv`.
    /// @dev Lowering BELOW the book's live LTV is intended (a risk ratchet-down): debt-adding ops then fail
    ///      their post-op `_assertHealthy` until a lever-DOWN brings the book back inside.
    /// @dev Lowering below the STANDING TARGET needs `setTargetLtv` first — rung 1 refuses it otherwise.
    /// @dev CONSUMES ANY STAGED VENUE HASH (like `redeploy`): the owner staged it under the old policy.
    /// @param maxLtvBps_ New ceiling in bps, validated by the shared `checkLtvBand` against the LIVE
    ///        collateral factor: Moonwell governance can move CF after init, and the init-time snapshot
    ///        could approve a ceiling now above the liquidation line.
    function setMaxLtv(uint16 maxLtvBps_) external onlyAdmin {
        LeveragedAeroVenue.setMaxLtvImpl(maxLtvBps_);
    }

    /// @notice ADMIN-ONLY POLICY: set the `[minWidth, maxWidth]` band a proposer `rerange` width must land
    ///         in — `onlyAdmin` because this band is what BOUNDS the proposer. Not state-gated.
    /// @dev The band must still admit the STORED width: `redeploy` / `rerange` size from it, so narrowing
    ///      past it reverts `OutOfBounds` — rerange into the intended width first.
    /// @dev No `setWidth` (the live range moves only by minting at a calm-gated tick, i.e. `rerange`), and
    ///      the SKEW band stays init-frozen by design.
    /// @dev CONSUMES ANY STAGED VENUE HASH (like `redeploy`): the owner staged it under the old band.
    function setWidthBounds(uint24 minWidth_, uint24 maxWidth_) external onlyAdmin {
        LeveragedAeroVenue.setWidthBoundsImpl(minWidth_, maxWidth_);
    }

    /// @notice Retarget the position's LTV to `targetBps` (borrow/repay; no new USDC enters), via
    ///         `LeveragedAeroManager.adjustLeverageImpl`: lever UP borrows the leg delta and adds it
    ///         (`minLiq`), lever DOWN unwinds the matching CL fraction and repays (residual rebalanced through
    ///         USDC, bounded by `minOut`). Ends with `_assertHealthy`.
    ///
    ///         `targetBps` IS A PARAMETER BUT NOT POLICY. It is bounded by the STORED standing target
    ///         (`targetLtvBps()`, admin-only through `setTargetLtv`) and is NEVER PERSISTED, so the keeper may
    ///         move the book anywhere in `(0, targetLtvBps()]` — de-lever ahead of a `fulfillRedeem` with NO
    ///         multisig signature inside the `FULFILL_WINDOW`, then restore by passing the stored target back —
    ///         and can never raise fund risk above the policy the admin set. `maxLtvBps` remains the belt in
    ///         `_assertHealthy`. THE DE-LEVER IS TRANSIENT BY CONSTRUCTION: the next `deployIdle` / `compound`
    ///         sizes its new tranche at the STORED target, so it creeps back. A DURABLE de-risk is the admin's
    ///         `setTargetLtv`, not this; the permissionless `deleverage()` covers the health emergency.
    ///
    ///         ASSET-MODE (leg-B slot == usdc): a lever-UP borrows ONLY leg A and pairs it with the book's own
    ///         USDC — raw first, then parked collateral — sized closed-form so the LP's leg-A amount equals the
    ///         added leg-A debt, which is what preserves the delta-hedge. It shrinks the redeem-cover float, and
    ///         near a range edge the draw per unit of new debt diverges: `rerange` first in that case.
    /// @dev "The keeper cannot raise fund risk" is NOT a property of this bound alone: `migrateVenue` is
    ///      `onlyProposer` and rewrites BOTH `targetLtvBps` and `maxLtvBps`. That is safe for exactly two
    ///      reasons — `stageVenue` is OWNER-gated, and the params are BYTE-COMMITTED to the staged
    ///      `keccak256(abi.encode(p))`. Loosening either would SILENTLY UN-GATE this bound; `applyVenue` emits
    ///      `TargetLtvUpdated` on that path, so do not add a write path without an emit.
    /// @param targetBps Target LTV for THIS call only, in bps; must be `<= targetLtvBps()`. A zero (or
    ///        near-zero) target is a full unwind and fails closed in `_leverDown` with
    ///        `FullUnwindNotSupported` — `flatten()` is the real full unwind.
    function adjustLeverage(uint16 targetBps, uint256 minLiq, uint256 minOut) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        uint16 policy = _layout().targetLtvBps;
        if (targetBps > policy) revert TargetLtvExceedsPolicy(targetBps, policy);
        LeveragedAeroManager.adjustLeverageImpl(targetBps, minLiq, minOut);
    }

    /// @notice Permissionless safety valve: when health falls below `minHealthBps`, ANYONE may unwind
    ///         CL liquidity and repay debt to restore the buffer. Deliberately NOT `onlyProposer` — a
    ///         public deleverage is the user-safety backstop for the indefinitely-lived position. Logic in
    ///         `LeveragedAeroManager.deleverageImpl`: same hardened-Chainlink health basis as
    ///         `_assertHealthy`, reverts `HealthyNoDeleverage` when safe / no debt, else repays down to
    ///         a small buffer above the minimum (a recovery op, not the full LTV-≤-max gate).
    ///
    ///         A stale our-feed fail-closes the read (deleveraging at a stale/manipulated price is
    ///         worse than waiting); Moonwell liquidation uses its own oracle, an accepted residual (§13).
    /// @param minOut Minimum USDC out of any residual rebalancing swap (slippage guard).
    function deleverage(uint256 minOut) external nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroManager.deleverageImpl(minOut);
    }

    /// @notice Oracle-priced FAST-PATH redeem (the everyday exit): pay `shares × nav() / supply`, funded from
    ///         the Moonwell USDC collateral ONLY — no LP touch, no debt repay. Caller must
    ///         `vault.approve(strategy, shares)` first. Oracle-dependent by design (fail-closed like `deposit`):
    ///         a down oracle reverts and the caller routes to `requestRedeem`. The LTV gate is
    ///         authoritative in `fastRedeemImpl` (`FastRedeemExceedsLtv` ⇒ route to `requestRedeem`).
    /// @dev NO VIRTUAL OFFSET ON THE EXIT, asymmetric with `deposit` and deliberate: it is an ISSUANCE-SIDE
    ///      inflation guard whose attack is already closed here (`Executed`-only deposits, the owner's genesis
    ///      seed, `ZeroShares`). On the exit it would buy nothing — round-trip bias is bounded at
    ///      `(supply/nav − 1)` micro-USDC at ANY size — while paying the physical async exit differently and
    ///      stranding NAV behind the last redeemer.
    function redeem(uint256 shares, uint256 minAssetsOut) external nonReentrant returns (uint256 assetsOut) {
        if (_state != State.Executed) revert NotExecuted();

        // 1. Price on the pre-redeem NAV over the live supply (fail-closed: a down oracle reverts —
        //    correct, the fast path is inherently oracle-dependent).
        uint256 navPre = nav();
        address vault_ = vault();
        uint256 supply = IERC20(vault_).totalSupply();
        //    `fullRedeem` selects the whole-cToken-burn funding path — a fact about the share ledger.
        bool fullRedeem = shares == supply;

        assetsOut = Math.mulDiv(shares, navPre, supply); // rounds down, LP-favourable
        if (assetsOut < minAssetsOut) revert InsufficientAssetsOut();
        // Reject a burn-for-zero: at nav()==0 or a dust-share redeem that floors to 0, `assetsOut == 0`
        // with the common `minAssetsOut == 0` would pull + burn shares for no payout. (The async path
        // guards the same case in `_proportionalRedeem`.)
        if (assetsOut == 0) revert ZeroAssetsOut();

        // 3. Pull shares from caller (requires prior vault.approve(strategy, shares)).
        IERC20(vault_).safeTransferFrom(msg.sender, address(this), shares);

        // 4. Fund `assetsOut`: idle USDC first (up to the redeemer's pro-rata `f×idle` share, so a
        //    partial redeem never dips into a stayer's `(1-f)×idle`), remainder from collateral
        //    (LTV-gated in the manager on that remainder only).
        uint256 idleShare = Math.mulDiv(IERC20(_layout().usdc).balanceOf(address(this)), shares, supply);
        //    `fullRedeem` lets the funding step burn the cTOKEN balance rather than a stored-rate underlying
        //    amount. It returns the payout actually funded — never less than `assetsOut`, so the floor holds.
        assetsOut = LeveragedAeroVenue.fastRedeemImpl(assetsOut, idleShare, fullRedeem);

        // 5. Pay out + burn.
        IERC20(_layout().usdc).safeTransfer(msg.sender, assetsOut);
        ILeveragedAeroVault(vault_).strategyBurn(shares);
    }

    /// @notice Advisory preview of the fast-path exit — mirrors `redeem` EXACTLY: `nav()` over the live
    ///         supply, so the quote equals the executed payout to the wei in the same block. ONE CARVE-OUT, in
    ///         the SAFE direction: a FULL redeem of a flat, zero-debt book burns the whole cToken balance at
    ///         the FRESH rate while this quotes the stored rate, so it only ever UNDER-quotes. Returns
    ///         `(0, false)` rather than reverting when the oracle is down or when the payout floors to 0.
    ///         ADVISORY — `fastRedeemImpl`'s LTV gate is authoritative.
    function previewRedeem(uint256 shares) external view returns (uint256 assetsOut, bool fastOk) {
        return LeveragedAeroVenue.previewRedeemImpl(shares);
    }

    /// @dev Self-only external view so `previewRedeem` can try/catch the manager's oracle reads
    ///      (a down feed reverts inside `_readCollateralDebt`). Runs under staticcall; no state change.
    function previewCollateralDebt() external view returns (uint256 collateralUsdc, uint256 debtUsdc) {
        if (msg.sender != address(this)) revert OnlySelf();
        return LeveragedAeroManager.readCollateralDebtImpl();
    }

    // ── Escrowed async redeem (Lane-B-style, no price freeze) ──

    /// @notice Escrow `shares` for an async proportional redeem — the exit for holders the LTV-gated fast path
    ///         cannot serve, or when the oracle is down. Shares are pulled NOW and held in the strategy; NO price
    ///         is stamped, so they keep bearing PnL until `fulfillRedeem` and `cancelRedeem` is not a free
    ///         look-back option. The pre-fulfill lever-down is ONE-PARTY: the proposer runs `adjustLeverage`
    ///         at a lower per-call target, then fulfills — no multisig inside `FULFILL_WINDOW`.
    /// @param minAssetsOut Slippage floor enforced (on the net amount) at fulfill.
    /// @param recipient Payee of the `fulfillRedeem` payout, fixed here and immutable; `address(0)` means
    ///        `msg.sender`. Confers NO authority — cancel and `emergencyRedeem` stay gated on `owner`.
    function requestRedeem(uint256 shares, uint256 minAssetsOut, address recipient)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (_state != State.Executed) revert NotExecuted();
        return LeveragedAeroVenue.requestRedeemImpl(shares, minAssetsOut, recipient);
    }

    /// @notice Fulfill an escrowed request via the oracle-free proportional unwind (the demoted everyday path,
    ///         reachable ONLY here and via `emergencyRedeem`). `onlyProposer`, so the whole sequence —
    ///         `adjustLeverage` at a lower per-call target so the unwind's IL self-funds, then this — never
    ///         depends on a multisig signature inside the 2-day `FULFILL_WINDOW`. NOT owner-callable: that would resurrect
    ///         the demoted oracle-free path through the side door.
    /// @dev THE FLOOR IS `max(stored, fresh)`, NEVER `min`: the requester's own floor is their guarantee and
    ///      whoever fulfils must not be able to lower it, while the fresh one covers the up-to-2-day staleness of
    ///      the stored one — nothing else covers that (the sweep floors bound SWAPS, not the net payout). Pass 0
    ///      to defer entirely to the stored floor. PAYEE IS `r.recipient` (never zero), so a contract
    ///      requester's fulfil settles the withdrawal outright.
    function fulfillRedeem(uint256 id, uint256 minAssetsOut) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        Layout storage $ = _layout();
        RedeemRequest storage r = $.redeemRequests[id];
        if (r.settled) revert RequestSettled();
        uint256 stored = r.minAssetsOut;
        address to = r.recipient;
        uint256 assetsOut = _proportionalRedeem(to, r.shares, minAssetsOut > stored ? minAssetsOut : stored);
        r.settled = true;
        emit RedeemFulfilled(id, r.owner, to, assetsOut);
    }

    /// @notice Cancel an unsettled request and return the escrowed shares to its owner. Request owner
    ///         only, callable in ANY strategy state (no `State.Executed` gate): a request outstanding
    ///         when the strategy settles must stay cancellable so the owner can exit via the vault
    ///         normally.
    /// @dev Shares go to `owner`, never `recipient`: routing the un-redeemed escrow to the fulfil payee
    ///      would let a request hand a third party the position itself.
    /// @param id Request id to cancel.
    function cancelRedeem(uint256 id) external nonReentrant {
        RedeemRequest storage r = _layout().redeemRequests[id];
        if (msg.sender != r.owner) revert NotRequestOwner();
        if (r.settled) revert RequestSettled();
        r.settled = true;
        IERC20(vault()).safeTransfer(r.owner, r.shares);
        emit RedeemCancelled(id, r.owner, r.shares);
    }

    /// @notice Deadman trustless backstop: after `FULFILL_WINDOW` elapses on an unfulfilled request, its owner
    ///         may self-fulfill via the same oracle-free proportional unwind. That single gate covers the whole
    ///         deadman matrix — fulfill is itself oracle-free, so only "oracle down AND backend dead" is stuck.
    ///         `minAssetsOut` is a FRESH arg (the stored one may be 2 days stale).
    /// @dev ORACLE-FREE, WITH ONE NAMED RESIDUAL. Every priced read here is caught and degrades: `try this.nav()`
    ///      falls back to 0, the reward-tranche sale defers, and the leg-sweep floors degrade to 0 — each marked
    ///      by its own event. THE EXCEPTION is `redeemUnwindImpl`'s Phase 2 (`_settleShortfall`), which prices a
    ///      deficit buy at Chainlink and fails CLOSED; it is reached only on a FULL redeem with genuine deep IL
    ///      that the swept legs and raw float could not cover, and `supplyIdle` sizes that float.
    ///      PAYEE IS `r.owner`, not `r.recipient` as in `fulfillRedeem`: this RETURNS `assetsOut` to its
    ///      owner-gated caller, which forwards it — pay `recipient` and a contract requester gets nothing.
    /// @param minAssetsOut Fresh slippage floor on the net payout.
    function emergencyRedeem(uint256 id, uint256 minAssetsOut) external nonReentrant returns (uint256 assetsOut) {
        if (_state != State.Executed) revert NotExecuted();
        RedeemRequest storage r = _layout().redeemRequests[id];
        if (msg.sender != r.owner) revert NotRequestOwner();
        if (r.settled) revert RequestSettled();
        if (block.timestamp <= uint256(r.requestedAt) + FULFILL_WINDOW) revert FulfillWindowOpen();
        assetsOut = _proportionalRedeem(r.owner, r.shares, minAssetsOut);
        r.settled = true;
        emit RedeemEmergency(id, r.owner, assetsOut);
    }

    /// @dev Shared body of `fulfillRedeem` / `emergencyRedeem`: oracle-free proportional unwind of
    ///      `shares` for `recipient`, enforcing `minOut`, burning the escrowed shares. Reads NO price of its
    ///      own — `redeemUnwindImpl` is pool-based (§7). `supply` fixed once before burn.
    function _proportionalRedeem(address recipient, uint256 shares, uint256 minOut)
        private
        returns (uint256 assetsOut)
    {
        uint256 supply = IERC20(vault()).totalSupply();
        assetsOut = LeveragedAeroManager.redeemUnwindImpl(shares, supply);
        // Reject a burn-for-zero (mirrors the fast path's guard): a dust-share unwind can pay exactly 0,
        // and with a stored `minOut == 0` the `< minOut` check below would fall through and burn the
        // escrowed shares for no payout. Reverting keeps the shares escrowed (no price is stamped at
        // request time → they keep bearing PnL and pay out later) and `cancelRedeem` (no State gate)
        // always lets the owner recover them.
        if (assetsOut == 0) revert ZeroAssetsOut();
        if (assetsOut < minOut) revert InsufficientAssetsOut();
        IERC20(_layout().usdc).safeTransfer(recipient, assetsOut);
        ILeveragedAeroVault(vault()).strategyBurn(shares);
    }

    /// @notice Sweep a STRAY ERC-20 (airdrop / accidental send) back to the vault. ADMIN-ONLY (§8) — the vault
    ///         owner / multisig, NOT the proposer: moving tokens out is a custody action, and the keeper key
    ///         must not be able to move funds. Target is always `vault()`, never caller-supplied (§13); onward
    ///         recovery is the vault's owner-only `rescueERC20`. Reverts `CannotRescuePositionToken` for every
    ///         position/accounting token — usdc / cbBTC / weth / mUsdc / mCbBTC / mWeth — plus the VAULT SHARE
    ///         token, since this strategy custodies live depositor claims (else `rescueToVault(vault) →
    ///         vault.rescueERC20(vault, attacker)` would exfiltrate them; escrows exit via `cancelRedeem`), and
    ///         the gauge reward token WHILE EXECUTED, so a sweep cannot bypass `compound()`. Once `Settled` that
    ///         token IS a stray, and sweeping it recovers the residue `_settle`'s best-effort sale left behind.
    function rescueToVault(address token) external onlyAdmin nonReentrant {
        Layout storage $ = _layout();
        address aero = ICLGauge($.gauge).rewardToken();
        if (
            token == vault() || token == $.usdc || token == $.cbBTC || token == $.weth || token == $.mUsdc
                || token == $.mCbBTC || token == $.mWeth || (token == aero && _state != State.Settled)
        ) revert CannotRescuePositionToken();
        _pushAllToVault(token);
    }

    // ── Owner-staged venue migration (see LeveragedAeroVenue for the impls) ──

    /// @notice Commit the destination venue for an in-place pool/pair migration, as
    ///         `keccak256(abi.encode(LeveragedAeroVenue.VenueParams))`; `bytes32(0)` clears. VAULT OWNER ONLY —
    ///         the venue-selection authority, so the hot proposer key can never choose where the fund's liquidity
    ///         goes. Staging is inert until `migrateVenue` runs with the byte-exact params; re-staging replaces.
    function stageVenue(bytes32 venueHash) external {
        if (msg.sender != _vaultOwner()) revert NotVaultOwner();
        LeveragedAeroVenue.stageImpl(venueHash);
    }

    /// @notice Unwind the WHOLE book to idle USDC while staying `Executed` — the migration's first leg, and a
    ///         general proposer de-risk lever. Runs `settleImpl`'s exact unwind (exit gauge + CL, repay both
    ///         legs self-funding any shortfall, redeem all collateral, sweep residual legs to USDC, slippage
    ///         floored by `maxSlippageBps`) but does NOT settle: no state transition and no push-to-vault.
    ///         Deposits and redeems keep working against the flat book (NAV == idle
    ///         USDC, oracle-free); the proposer re-enters via `redeploy`. Idempotent on an already-flat book.
    ///         TWO GUARDS `settle` does not need, because `flatten` is repeatable: the pool is CALM-GATED before
    ///         the burn (the unwind's mins come off the same `slot0()` it burns at), and the auto-claimed reward
    ///         tranche is SOLD here, FAIL-CLOSED under `max(minRewardUsdcOut, L9 oracle floor)` — a reverted
    ///         `flatten` is just a retry. That sale SKIMS `compoundFeeBps` in kind first, as `compound` does,
    ///         so quote `minRewardUsdcOut` on the POST-SKIM amount.
    /// @param minIdleUsdcOut Aggregate floor on the strategy's idle USDC once the unwind completes, over and
    ///                       above the per-swap `maxSlippageBps` floors.
    function flatten(uint256 minRewardUsdcOut, uint256 minIdleUsdcOut) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.flattenImpl(minRewardUsdcOut, minIdleUsdcOut);
    }

    /// @notice Execute the owner-staged venue rewrite. PROPOSER ONLY, and only when `p` byte-matches the staged
    ///         hash AND the book is flat (no CL position, no hedged basis, no live leg debt — flatten first).
    ///         Re-runs the full init-grade venue validation against `p`, rewrites the venue subset of storage,
    ///         and consumes the staged hash. Share-ledger continuity is structural: on a flat book NAV is the
    ///         idle USDC balance, which no venue field touches. Old-leg dust becomes `rescueToVault`-able.
    function migrateVenue(LeveragedAeroVenue.VenueParams calldata p) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.migrateImpl(p);
    }

    /// @notice Open a FRESH position from a flat `Executed` book, deploying the entire idle USDC balance — the
    ///         re-entry after a `flatten`, with or without an intervening `migrateVenue`. Runs `executeImpl`'s
    ///         exact genesis sequence; reverts `PositionAlreadyOpen` when a position is live (top-ups go through
    ///         `deployIdle`). CLEARS ANY STAGED VENUE HASH, so an authorization cannot be fired later into
    ///         unevaluated conditions — re-stage (owner) if the migration is still intended.
    /// @param minLiquidity Minimum CL liquidity the fresh mint must produce (required here, unlike `execute`,
    ///                     because this path is repeatable and runs against live depositors).
    function redeploy(uint256 minLiquidity) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.redeployImpl(minLiquidity);
    }

    /// @dev No tunable params.
    function _updateParams(bytes calldata) internal override {}

    // ── Config builder for LeveragedAeroValuation ──

    /// @dev Build the valuation `Config` from stored state (leg decimals are read from the tokens at
    ///      init and stored). Field-by-field (not struct-literal) so the Yul IR emits one sload→mstore
    ///      per field, avoiding the 18-live-variable overflow struct-literals trigger under via_ir.
    function _config() internal view returns (LeveragedAeroValuation.Config memory c) {
        Layout storage $ = _layout();
        c.usdc = $.usdc;
        c.vault = vault();
        c.mUsdc = $.mUsdc;
        c.cbBTCMarket = $.mCbBTC;
        c.wethMarket = $.mWeth;
        c.cbBTC = $.cbBTC;
        c.weth = $.weth;
        c.cbBTCDecimals = $.cbBTCDecimals;
        c.wethDecimals = $.wethDecimals;
        c.pool = $.pool;
        // Gauge + tokenId + reward feed drive the gauge-reward NAV term, pricing both the claimed-but-unsold
        // balance and the still-unclaimed `gauge.earned()`. `tokenId == 0` ⇒ no `earned()` call at all.
        c.gauge = $.gauge;
        c.tokenId = $.tokenId;
        c.cbBTCFeed = $.cbBTCFeed;
        c.wethFeed = $.wethFeed;
        c.usdcFeed = $.usdcFeed;
        c.rewardFeed = $.aeroUsdFeed;
        c.sequencerFeed = $.sequencerFeed;
        c.maxDelay = $.maxDelay;
        c.gracePeriod = $.gracePeriod;
        c.calmDeviationTicks = $.calmDeviationTicks;
        c.twapWindow = $.twapWindow;
        // The reward term is marked NET of this skim — only the post-skim fraction can reach the book.
        c.compoundFeeBps = $.compoundFeeBps;
    }
}
