// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {LeveragedAeroFees} from "./LeveragedAeroFees.sol";
import {LeveragedAeroManager} from "./LeveragedAeroManager.sol";
import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {LeveragedAeroVenue} from "./LeveragedAeroVenue.sol";
import {BaseStrategy} from "./sherwood/BaseStrategy.sol";
import {Position} from "./sherwood/interfaces/IPriceRouter.sol";
import {IProtocolConfig} from "./sherwood/interfaces/IProtocolConfig.sol";
import {ICLGauge, INonfungiblePositionManager} from "./sherwood/interfaces/ISlipstream.sol";
import {IStrategy} from "./sherwood/interfaces/IStrategy.sol";
import {ISyndicateFactory} from "./sherwood/interfaces/ISyndicateFactory.sol";
import {ISyndicateVault} from "./sherwood/interfaces/ISyndicateVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Just the vault's fund-capacity ceiling, read by `deposit`. Declared locally rather than added
///      to the vendored `ISyndicateVault`, so every stand-in implementing that interface does not have
///      to grow the selector. Mirrors the pattern `LeveragedAeroVault` uses for `IStrategyNav`.
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
    //
    // THE INIT-VALIDATION ERRORS ARE RAISED FROM THE LIBRARY, NOT FROM THIS FRAME. `TargetLtvExceedsMax`,
    // `MinHealthTooLow`, `MaxLtvExceedsCF`, `MinHealthMaxLtvConflict`, `FeeRecipientRequired`,
    // `PerformanceFeeTooHigh`, `ManagementFeeTooHigh`, `OracleParamOutOfRange`, `ComptrollerCallFailed`
    // and `OutOfBounds` are all declared IDENTICALLY in `LeveragedAeroValuation` (which runs those
    // ladders — the relocation bought EIP-170 headroom here). Same signature == same selector, so they
    // stay on this contract's ABI and a caller/test may expect them off either. Do not delete them as
    // "unused": the ABI is the interface a frontend and the init suite bind to.
    error NotImplemented();
    error TargetLtvExceedsMax();
    error MinHealthTooLow(); // minHealthBps < 10500 (1.05x floor)
    error FeeRecipientRequired();
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
    // Caller is not the ADMIN — i.e. not `Ownable(vault()).owner()`, the vault owner / MAMO multisig.
    // The admin/proposer split (§8): the proposer is the rebalancer keeper and drives OPERATIONS; only
    // the admin sets fund POLICY (`setTargetLtv`) or sweeps strays (`rescueToVault`). A compromised
    // keeper key therefore cannot re-point the fund's leverage or move tokens out of the strategy.
    error NotAdmin();
    // A ZERO standing target is refused at EVERY route that can store one — `_initialize`, and both
    // setters through the shared `_storeTargetLtv` floor check (so they cannot drift apart) — and the
    // defence has always had a second, structural barrier behind those checks:
    // a stored zero means `_supplyAndBorrow` borrows nothing, so `debtUsdc == 0`, so
    // `adjustLeverageImpl`'s `targetDebt == debtUsdc` and both branches skip — `_unwindLiquidity`'s
    // `num == den` full-removal branch (strips ALL liquidity, skips the re-stake, leaves `$.tokenId`
    // pointing at an UNSTAKED NFT that every later venue op assumes is staked) is never reached.
    // `deleverageImpl` computes its own non-zero `targetDebt` and gates on `debtBefore > targetDebt`,
    // so nor can it. An unguarded init-zero is therefore milder than a brick: a clone that silently
    // never levers, correctable only by a `setTargetLtv` the deployer must notice they need.
    // `setTargetLtv(0)` on an ALREADY-LEVERED book is the sharp case — there `debtUsdc > 0`, so the
    // full-removal branch IS reachable and the fund would be left with no trustless exit.
    error TargetLtvZero();
    // `lowerTargetLtv` is MONOTONIC DOWN: the proposer's copy of the leverage dial only ever reduces
    // risk. Equal is refused too — a no-op write would emit a misleading `TargetLtvUpdated`, and the
    // strict inequality is what makes the "keeper can never raise leverage" claim checkable in one line.
    error TargetLtvNotLower();
    error OnlySelf();
    error PerformanceFeeTooHigh();
    error ManagementFeeTooHigh();
    error MinHealthMaxLtvConflict();
    error AssetMismatch();
    error UnexpectedAssetDecimals();
    error UnexpectedFeedDecimals(); // AERO/USD aggregator not 8dp (L9 oracle-floor scaling assumption)
    error OracleParamOutOfRange();
    error FastRedeemExceedsLtv(uint256 ltvBps, uint256 maxLtvBps); // fast-path breaches maxLtvBps → use requestRedeem
    error NotRequestOwner();
    error RequestSettled();
    error FulfillWindowOpen(); // emergencyRedeem before FULFILL_WINDOW elapsed
    error ZeroAssetsOut(); // fast redeem would pay 0 (navNet==0 or dust shares floor to 0) — burn-for-zero
    error LegDecimalsOutOfRange(); // a leg token reports decimals outside [2, 18]
    error VenueMismatch(); // pool/market wiring does not match the declared legs or tickSpacing
    error UnsupportedLeg(); // leg A is the unit of account, or a leg is the gauge reward token
    // asset-mode lever-up needs `needed` idle USDC to pair with the borrowed leg A, book holds `available`.
    // Raised by `LeveragedAeroValuation.assetModeLeverUpPair`; re-declared here (same selector) so it is on
    // the strategy's public ABI for the rebalancer / frontend.
    error InsufficientIdleForLeverUp(uint256 needed, uint256 available);
    // rerange width off the tickSpacing grid / outside [minWidth, maxWidth], OR a skew outside (0, 1e4)
    // or one that starves either side of the range below a single tickSpacing. ONE error for both knobs:
    // they are validated together, by the same two callers (`_initialize` and `rerange`), and a caller
    // that has to fix its range params does not branch on which half was wrong.
    error OutOfBounds();
    error ZeroShares(); // deposit would mint 0 shares (dust assets against a large book) — pay-for-nothing
    error NotVaultOwner(); // stageVenue caller is not the vault's owner (the venue-selection authority)
    // A lever-down that would repay the ENTIRE debt is rejected — it would orphan the staked position
    // NFT. Declared once in the manager (same selector); re-declared here so it is on the strategy's
    // public ABI for the rebalancer, exactly as `InsufficientIdleForLeverUp` is. Use `flatten()`.
    error FullUnwindNotSupported();
    // The migration surface, for the same reason as `FullUnwindNotSupported` above and applied to the
    // whole set rather than one case: `LeveragedAeroVenue` is DELEGATECALLED, so these revert from THIS
    // address and are indistinguishable from raw bytes to anyone holding only the strategy ABI —
    // indexers, the rebalancer (which the operator docs tell to branch on `PositionAlreadyOpen`), and
    // every `vm.expectRevert` written against the strategy. Selectors match the library's by name and
    // arity; re-declaring costs zero runtime bytes. The rest of the library's set (`VenueMismatch`,
    // `UnsupportedLeg`, the width/LTV/health family, `ZeroAddress` via `BaseStrategy`) is already above.
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

    /// @dev ERC-4626 virtual share offset matching the vault's `_decimalsOffset()` (USDC 6dp → 1e6).
    uint256 private constant SHARES_VIRTUAL_OFFSET = 1e6;

    /// @dev Deadman window: after this elapses on an unfulfilled `requestRedeem`, its owner can
    ///      `emergencyRedeem` trustlessly (Chainlink-free except the deep-IL Phase-2 draw — see
    ///      `emergencyRedeem`). The backend fulfills in minutes; 2 days
    ///      tolerates a weekend outage while keeping the trustless exit reachable.
    uint256 private constant FULFILL_WINDOW = 2 days;

    // ── Async-redeem queue events ──
    event RedeemRequested(uint256 indexed id, address indexed owner, uint256 shares);
    event RedeemFulfilled(uint256 indexed id, address indexed owner, uint256 assetsOut);
    event RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares);
    event RedeemEmergency(uint256 indexed id, address indexed owner, uint256 assetsOut);

    /// @dev The fund's STANDING target LTV was re-set by the admin (`setTargetLtv`). This is a POLICY
    ///      change, not an operation: it does not move the book by itself — the next `adjustLeverage`
    ///      / `deployIdle` / `compound` sizes at the new value. Monitors should treat it as a
    ///      multisig-signed risk change, and it is the only leverage-policy event on this contract.
    event TargetLtvUpdated(uint16 previousBps, uint16 newBps);

    /// @dev A best-effort fee crystallise (deposit / fast redeem / proportional redeem) reverted and was
    ///      deferred; the op proceeded. Reverts on the fee-MINT (vault paused / feeRecipient
    ///      de-whitelisted) — or, near-unreachably, on the config read inside the crystallise (see the
    ///      per-op docstrings). `op` (see `OP_*`) tells a monitor which entrypoint deferred; `navPre` is
    ///      the NAV at risk (0 on an oracle-out proportional redeem).
    event FeeCrystallizeDeferred(uint8 op, uint256 navPre);

    // ── `FeeCrystallizeDeferred.op` codes ──
    uint8 private constant OP_DEPOSIT = 0;
    uint8 private constant OP_REDEEM = 1; // fast redeem
    uint8 private constant OP_FULFILL = 2; // proportional redeem (fulfill / emergency)
    uint8 private constant OP_COMPOUND = 3; // harvest / redeploy

    // ── Degradation markers for the three DELIBERATE fail-opens in this stack ──
    //
    // Each of these sits behind a `catch {}` that exists for a good reason (a terminal exit or the
    // async-redeem deadman must not be blockable) but that CANNOT distinguish the expected cause — a
    // stale feed, a paused aggregator, a broken route — from an out-of-gas or any other revert. Without
    // a log the degradation leaves no on-chain trace whatsoever, so a monitor cannot tell a healthy op
    // from one that ran with a guard switched off.
    //
    // NAMING, applied consistently across the four: `…Deferred` = an optional ACTION was skipped (the
    // reward sales); `…Degraded` = a GUARD fell back and the op ran with less protection (the redeem
    // sweep floors, declared on `LeveragedAeroManager`, and the interest-hedge measure, declared on
    // `LeveragedAeroValuation` — both emitted from this address via delegatecall).

    /// @dev The terminal settle's best-effort sale of the final reward tranche reverted and was
    ///      skipped; the settle completed. Expect it on a stale/paused reward feed or a reward-route
    ///      failure — the tranche is left on the strategy and, now that the strategy is `Settled`, is
    ///      recoverable with `rescueToVault(rewardToken)` → the vault's `rescueERC20`.
    event SettleRewardSaleDeferred();

    /// @dev An async redeem's best-effort sale of the tranche its OWN unwind auto-claimed reverted and
    ///      was skipped; the redeem completed and paid. Same causes as above. Consequence to monitor:
    ///      the redeemer was paid `f × (assets − reward)` for that call and the tranche stayed with the
    ///      stayers — the one residual case of the pre-fix behaviour (see `sellRedeemRewardSelf`). Clear
    ///      it with `compound` once the feed/route recovers.
    event RedeemRewardSaleDeferred();

    /// @dev Mirror of `LeveragedAeroManager.RedeemSweepFloorsDegraded` — the manager is delegatecalled,
    ///      so it emits from THIS address and belongs in this ABI. Declared in both, exactly as the
    ///      venue-migration events above are. Means an async redeem's closing leg sweeps ran with their
    ///      Chainlink min-out floors at ZERO: the swaps were unbounded for that call.
    event RedeemSweepFloorsDegraded();

    /// @dev Mirror of `LeveragedAeroVenue.WithdrawIdleBoundDegraded` — the venue library is
    ///      delegatecalled, so it logs from THIS address and belongs in this ABI. Means a `withdrawIdle`
    ///      could not price its POLICY bound at the hardened Chainlink reader and re-derived the SAME
    ///      un-levered-collateral line from Moonwell's own account snapshot for that call. The withdraw
    ///      still happened, inside that bound, and NAV is unaffected — raw and mUSDC-parked USDC price
    ///      alike; the residual is only that the line was held at the venue's (possibly stale) prices
    ///      until the feeds recover.
    event WithdrawIdleBoundDegraded();

    /// @dev Mirror of `LeveragedAeroValuation.HedgeLegMeasureDegraded` — that library's `public`
    ///      functions are delegatecalled too, so it logs from THIS address and belongs in this ABI.
    ///      Means a `compound` could not read one leg's accrued Moonwell debt (the accrual reverted), so
    ///      that leg's borrow-interest hedge was SKIPPED for that harvest while the rest of the compound
    ///      — reward sale, fee crystallisation, the other leg's hedge, the redeploy — completed. The
    ///      remainder carries to the next harvest; a leg that keeps emitting this is accumulating an
    ///      unintended short and needs its market looked at. `market` is the leg's Moonwell market.
    event HedgeLegMeasureDegraded(address market);

    // ── Access control ──

    /// @dev ADMIN == `Ownable(vault()).owner()` — the vault owner, i.e. the MAMO multisig. DERIVED,
    ///      never stored: adding an admin field would mean a `Layout` change, and the vault owner is
    ///      already the root of trust for this fund (it owns the vault that owns the shares, and it is
    ///      the only party that can rotate the strategy). Following it also means an owner handover on
    ///      the vault carries the strategy's admin rights with it, with no second migration to forget.
    ///      Same read `rescueToVault` has always used for its owner leg.
    ///
    ///      This is the POLICY half of the operations/policy split — `onlyProposer` (BaseStrategy) is
    ///      the operations half, held by the rebalancer keyed hot key. The keeper must not be capable
    ///      of increasing what the fund risks: it can move the book toward the standing target and it
    ///      can lower that target (`lowerTargetLtv`, strictly down, never to zero), but it can never
    ///      raise it and it can never move tokens (`rescueToVault`).
    ///
    ///      DEPENDS ON TWO `LeveragedAeroVault` PROPERTIES (src/LeveragedAeroVault.sol): it overrides
    ///      `renounceOwnership` to revert, and it is `Ownable2Step` so ownership cannot be handed to an
    ///      address that never accepts. Drop either and one transaction on THAT contract permanently
    ///      strands `setTargetLtv` and `rescueToVault` here, with no recovery path.
    modifier onlyAdmin() {
        if (msg.sender != Ownable(vault()).owner()) revert NotAdmin();
        _;
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
        uint16 managementFeeBps; // Annual management fee in bps (e.g. 100 = 1%/yr)
        uint16 performanceFeeBps; // HWM performance fee in bps (e.g. 1000 = 10%)
        address feeRecipient; // Address that receives fee-shares (must be non-zero if any fee > 0)
    }

    // ── ERC-7201 namespaced (diamond) storage ──
    //
    // All strategy-specific state lives in one `Layout` struct at a fixed ERC-7201 slot, NOT in
    // sequential storage (which holds only BaseStrategy's state). This lets the venue ops run from
    // the deployed `LeveragedAeroManager` library via delegatecall.
    //
    // CORRUPTION-CRITICAL: `Layout`, `STORAGE_SLOT`, `_layout()`, and `RedeemRequest` are
    // byte-identical in `LeveragedAeroManager` — they MUST stay in lockstep or a delegatecall
    // reads/writes the wrong slots. Do not reorder `Layout` fields in one file without the other.

    /// @dev Escrowed async-redeem request (Lane-B-style, but NO price freeze — shares keep bearing
    ///      PnL until execution, so `cancelRedeem` is not a free look-back option). Byte-identical
    ///      to the manager's `RedeemRequest`.
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
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        address feeRecipient;
        uint256 hwmPerShare;
        uint256 lastFeeAccrualTimestamp;
        uint256 protocolFeeOwed;
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
    /// @dev THE 51-FIELD READ ITSELF LIVES IN `LeveragedAeroVenue.layoutView()` — see the relocation note
    ///      there. It is the same field-by-field copy off the same ERC-7201 slot (the venue library's
    ///      `Layout`/`STORAGE_SLOT` copy is parity-tested byte-identical to this one, and it is
    ///      delegatecalled, so it reads THIS contract's storage); this selector, its ABI and its
    ///      semantics are unchanged. It moved because it was the largest block of bytecode on this
    ///      contract that is not on a value path, and this contract is at the EIP-170 margin.
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

    /// @notice The Chainlink min-out floors for the two residual leg sweeps that END a proportional
    ///         redeem, for `cbAmt` leg-B units and `wethAmt` leg-A units actually being sold:
    ///         `oracleValue(amount) × (1 − maxSlippageBps)` per leg, on the same hardened 8dp reads
    ///         every other priced path uses. Reverts (fail-closed) on a stale feed / down sequencer.
    ///
    /// @dev EXISTS TO BE `try`-ABLE. `LeveragedAeroManager.redeemUnwindImpl` runs under DELEGATECALL, so
    ///      its own price reads are INTERNAL and a Solidity `try` cannot catch them. Routing the
    ///      derivation through this external entry point — reached from the manager as a call on
    ///      `address(this)`, the same idiom `_proportionalRedeem` already uses for `try this.nav()` —
    ///      gives it a catchable frame, which is what lets the sweeps carry a real oracle floor while
    ///      `emergencyRedeem` (the deadman, built for exactly the oracle-down-AND-backend-dead state)
    ///      still completes with the floors falling back to 0. See `LeveragedAeroValuation.sweepFloors`
    ///      for the full rationale; the math and the hardened reads live THERE, this is marshalling only.
    ///
    ///      NOT `OnlySelf`-gated, unlike `crystallizeFeesSelf` / `sellRewardSelf`: those MUTATE
    ///      state, this is a `view` over public storage and public feeds. Ungated it doubles as a keeper
    ///      read — "what floor would a sweep of this size have to clear right now" — and a gate would
    ///      cost bytes on a contract with well under 1 KB of EIP-170 headroom for no security gain.
    ///
    ///      Reuses `_config()` (the SAME builder `nav()` uses) rather than marshalling a second config
    ///      struct: every field the floor needs is already in it, so this wrapper costs one extra sload
    ///      and one call, not a duplicate builder.
    /// @param cbAmt   Leg-B units being sold (pass 0 in asset-mode: that sweep is the identity).
    /// @param wethAmt Leg-A units being sold.
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

    /// @notice The fund's STANDING target LTV in bps — set at init and re-set ONLY by the admin's
    ///         `setTargetLtv` (it is policy, not an operation). This is what `execute` / `deployIdle` /
    ///         `compound` size their borrow at and what `adjustLeverage` retargets the live position to,
    ///         so it is the value a rebalancer must read before rebalancing. Exposed as its own selector purely
    ///         for keeper ergonomics: `layout()` already carries it, but decoding a 40-plus-field
    ///         `LayoutView` to read one uint16 is needless work off-chain.
    /// @dev Same single storage read as `layout().targetLtvBps` (`_layout().targetLtvBps`, one diamond
    ///      slot, no cached copy anywhere) — the two CANNOT disagree by construction.
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
        // `LeveragedAeroVenue.applyVenue` — it moved into the migratable venue subset so a gauge
        // change and its reward-price feed are always attested together.

        // L7: the strategy's unit of account MUST be the vault's ERC-4626 asset, and the
        // SHARES_VIRTUAL_OFFSET (1e6) hardcodes a 6-decimal asset — reject any other wiring.
        if (p.usdc != IERC4626(vault()).asset()) revert AssetMismatch();
        if (IERC20Metadata(p.usdc).decimals() != 6) revert UnexpectedAssetDecimals();

        // ── VENUE BLOCK — extracted verbatim to `LeveragedAeroVenue.applyVenue` so the owner-staged
        // venue migration (`migrateVenue`) re-runs the EXACT same validation. Everything from the
        // shape derivation through the CF/LTV invariants — plus one ADDED `gauge.pool() == pool`
        // binding check — lives there now; check order is preserved so the same input reverts with
        // the same error. The lib reads the non-migratable core (usdc / mUsdc / usdcFeed /
        // comptroller) from live storage, which is why those four are stored FIRST below.
        Layout storage $ = _layout();
        $.usdc = p.usdc;
        $.mUsdc = p.mUsdc;
        $.usdcFeed = p.usdcFeed;
        $.comptroller = p.comptroller;
        // FIFTH live-storage read, and it must be written HERE, not with the other oracle params
        // below: `applyVenue`'s TWAP-availability probe calls `pool.observe([$.twapWindow, 0])`, so
        // with the write left downstream the init-time probe ran as `observe([0, 0])` — which every
        // pool answers, making the probe vacuous at init and live only at migrate. Its own bound
        // check therefore has to move up with it, ahead of the sibling bounds below.
        if (p.twapWindow == 0 || p.twapWindow > 1 days) revert OracleParamOutOfRange();
        $.twapWindow = p.twapWindow;
        // SIXTH/SEVENTH/EIGHTH live-storage reads, up here for the same reason. The SKEW triple is
        // NOT in `VenueParams` — it is venue-independent governance config (`0 < minSkew <= maxSkew <
        // 1e4` mentions no address and no grid), so it sits with `maxSlippageBps` and the fee params
        // in the non-migratable core. But the one-spacing-per-side span guard COUPLES the live skew to
        // `(width, tickSpacing)`, both of which a migration rewrites — so `applyVenue` re-validates
        // the STORED skew against the DESTINATION's width and grid, and a venue that would make the
        // live skew degenerate is a rejected migrate rather than a `DegenerateRange` at `redeploy`.
        // Writing them here is what lets init use that same one copy of the ladder.
        $.skewBps = p.skewBps;
        $.minSkewBps = p.minSkewBps;
        $.maxSkewBps = p.maxSkewBps;
        // `applyVenueFromInit` = the venue subset of `InitParams` marshalled into `VenueParams`, then
        // `applyVenue`. Both halves live in the venue library now: the marshalling was this contract's
        // `_venueParamsOf`, moved verbatim for EIP-170 headroom (`migrateVenue` still calls `applyVenue`
        // directly with its own calldata `VenueParams`, so init and migration keep sharing ONE
        // validation + store path — that is unchanged, only the marshalling moved).
        LeveragedAeroVenue.applyVenueFromInit(p);

        // Risk / oracle / fee ladder — relocated whole (rung for rung, same order, same selectors) into
        // `LeveragedAeroValuation`, for EIP-170 headroom. What is NOT here any more: the four RISK
        // invariants (`targetLtv <= maxLtv`, the 1.05x health floor, `maxLtv < CF`, the L4
        // health×LTV conflict) and the whole RANGE ladder both ran inside `applyVenue` above — they
        // are venue-scoped (measured against the destination's collateral factor and tickSpacing
        // grid), so `migrateVenue` has to re-run them and init gets them from the same one copy.
        // What remains here is the non-migratable core: the five ORACLE rungs and the fee rungs.
        // `checkRiskParams` re-runs the four risk rungs against the same values `applyVenue` just
        // validated — cheap, and it keeps the relocated ladder in its original rung order. The
        // collateral-factor read moved with it: it is a context-free `staticcall`, so running it in
        // this frame under delegatecall is identical. The fee rungs are a separate call only because a
        // 12-argument `checkRiskParams` put this frame one slot too deep for the Yul stack allocator.
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
        LeveragedAeroValuation.checkFeeParams(p.managementFeeBps, p.performanceFeeBps, p.feeRecipient);

        // Non-migratable core stores (the venue subset — legs, markets, pool, gauge, feeds,
        // spacings, widths, LTV band, derived decimals/ordering/shape — was persisted inside
        // `applyVenue` above; usdc / mUsdc / usdcFeed / comptroller were stored ahead of it).
        $.npm = p.npm;
        $.swapRouter = p.swapRouter;
        $.sequencerFeed = p.sequencerFeed;
        $.maxDelay = p.maxDelay;
        $.gracePeriod = p.gracePeriod;
        $.calmDeviationTicks = p.calmDeviationTicks;
        // `$.twapWindow` was stored ahead of `applyVenue` — see the note there.
        $.maxSlippageBps = p.maxSlippageBps;
        $.managementFeeBps = p.managementFeeBps;
        $.performanceFeeBps = p.performanceFeeBps;
        $.feeRecipient = p.feeRecipient;
        $.lastFeeAccrualTimestamp = block.timestamp;
        // The venue subset — decimals / ordering / shape / width band / LTV band / spacings — was
        // persisted by `applyVenue`; the skew triple was written ahead of it (see the note there).
        // tokenId / posTickLower / posTickUpper / hwmPerShare default to 0 (set in _execute / on first deposit).
    }

    // ── NAV ──

    /// @notice Oracle NAV of the levered book, in USDC (6dp), NET of the accrued protocol-fee
    ///         liability (`protocolFeeOwed`). `tokenId == 0` (the flat-book invariant, maintained by
    ///         `_execute`/`_settle`) → face value of the strategy's USDC WHEREVER IT SITS: the raw
    ///         balance PLUS the mUSDC collateral it has been parked in, valued at
    ///         `balanceOf × exchangeRateStored` (`LeveragedAeroValuation.usdcAvailable`). Still no
    ///         oracle — mUSDC is a USDC claim, so the flat book prices at face either way, which is what
    ///         lets `supplyIdle` park a flat book's whole pot without moving share price. Vault float is
    ///         excluded (M2 deposit/redeem symmetry). Active position →
    ///         `LeveragedAeroValuation.netEquityUsdc` (oracle-implied sqrtP, fail-closed: reverts on
    ///         any oracle/calm failure or ≤0 equity). `protocolFeeOwed` is subtracted here (floored at
    ///         0, never reverts on owed > gross) — this is the fairness mechanism that replaces
    ///         share-dilution: deposit share-pricing + the next HWM basis both see the net NAV.
    function nav() public view virtual returns (uint256) {
        Layout storage $ = _layout();
        uint256 gross;
        if ($.tokenId == 0) {
            // Flat book: strategy-controlled USDC only (face, 6dp, NO ORACLE — the property `flatten`
            // relies on). Vault float is excluded — `strategy.redeem` never pays it out, so counting
            // it here would re-introduce the M2 deposit/redeem asymmetry the active-position branch
            // already avoids.
            //
            // THE COLLATERAL TERM IS MANDATORY, not a refinement. The proposer's `supplyIdle` can move
            // the whole pot into mUSDC on a FLAT book — that is the state holding the most dead USDC
            // (post-`flatten`, post-full-redeem), so it is the state the op is most wanted in — and a
            // flat book is one the fund genuinely takes deposits in: `flatten` leaves the strategy
            // `Executed` precisely so deposits/redeems keep working. Pricing such a book off the raw
            // balance alone would read 0: the next depositor would mint against a zero NAV and every
            // one after that would revert `NavUnpriceable`, while the supplied USDC sat invisible.
            // `usdcAvailable` counts raw + `balanceOf × exchangeRateStored`, the same collateral term
            // the active branch's `netEquityUsdc` and the health basis use, and it reads no feed — so
            // the flat book stays priceable through an oracle outage exactly as before.
            gross = LeveragedAeroValuation.usdcAvailable($.usdc, $.mUsdc, address(this));
        } else {
            // Active position: read ticks + liquidity from the NPM and delegate to the valuation lib.
            (int24 tickLower, int24 tickUpper, uint128 liquidity) = _npmPositionData();
            gross = LeveragedAeroValuation.netEquityUsdc(_config(), address(this), tickLower, tickUpper, liquidity);
        }
        uint256 owed = $.protocolFeeOwed;
        return gross > owed ? gross - owed : 0;
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

    /// @notice HEALTH MARKER FOR `nav()`'s ONE FAIL-OPEN: `false` while the gauge-side `earned()` read
    ///         that `nav()` prices is failing, `true` when it answers or when there is nothing to read
    ///         (`tokenId == 0`). A sustained `false` means `nav()` is UNDERSTATING the book by the
    ///         unclaimed reward accrual on every deposit and every block — poll it.
    ///
    /// @dev A `view` cannot emit, and unlike every other fail-open in this system (which are
    ///      transaction-scoped and carry an event — `FeeCrystallizeDeferred`, the redeem-floor and
    ///      reward-sale degradation events) this one is a standing CONDITION, so readable state is the
    ///      only instrumentation available. Behaviour-neutral: `nav()` does not read this, it gains no
    ///      revert path from it, and this function cannot itself revert. See
    ///      `LeveragedAeroValuation.rewardReadOk` / `_earnedRead` for the exact predicate and why a
    ///      code-less gauge reports `false` rather than being lumped in with a benign `"NA"`.
    ///
    ///      Ungated for the same reason `redeemSweepFloors` is: a `view` over public storage and a public
    ///      venue read, whose whole purpose is off-chain polling. Reads `Layout` directly instead of
    ///      building a `_config()` — this contract has well under 1 KB of EIP-170 headroom and the
    ///      predicate needs exactly two of that struct's fields, from the SAME slots `_config()` reads.
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
    /// @dev Self-fee'd: this strategy crystallises management + HWM performance fees against its
    ///      own NAV (custody model: LPs deposit/redeem into the strategy, shares minted/burned on
    ///      the vault). Any vault-side settle-fee distribution MUST be skipped — a float-delta PnL
    ///      would misread net deposits as profit and double-charge fees already taken via
    ///      crystallize. `LeveragedAeroVault` has no fee path at all, so there is nothing to skip.
    function selfManagesFees() external pure override returns (bool) {
        return true;
    }

    // ── Execute / settle ──

    /// @notice Open the levered cbBTC/WETH CL position: supply USDC → enterMarkets → borrow
    ///         cbBTC+WETH → wrap ETH → mint Slipstream CL → stake gauge → assert health. The venue
    ///         sequence lives in `LeveragedAeroManager.executeImpl()` (delegatecalled, so
    ///         `address(this)` / `_layout()` resolve to this clone).
    function _execute() internal override {
        // `minLiquidity == 0`: activation is a once-per-lifetime, owner-driven open on a book holding
        // only the seed — no depositor state exists for a bad fill to dilute, and the base contract's
        // activation signature carries no slippage argument. The §8 two-sided `maxSlippageBps` mins
        // inside the mint still apply. `redeploy` is the repeatable variant and DOES take a floor.
        LeveragedAeroManager.executeImpl(0);
        // Belt-and-suspenders: keep the fee-accrual clock running even if a clone bypassed
        // _initialize (guards against a ~54-year dt on the first crystallize).
        if (_layout().lastFeeAccrualTimestamp == 0) _layout().lastFeeAccrualTimestamp = block.timestamp;
    }

    /// @notice Full proportional unwind to the vault. The unwind — remove 100% liquidity, repay both
    ///         Moonwell borrows (self-funding any IL/fee shortfall), redeem collateral, sweep residual
    ///         cbBTC/WETH → USDC, clear state — lives in `LeveragedAeroManager.settleImpl()`; the
    ///         final gauge-reward tranche is sold here (best-effort, see below) and the realized USDC
    ///         is pushed to the vault here (the manager never touches `vault()`).
    function _settle() internal override {
        LeveragedAeroManager.settleImpl();
        // Sell the reward tranche the unwind's `gauge.withdraw` auto-claimed: `settleImpl` sweeps only
        // the two LEG tokens, so without this the tranche never reaches the USDC pot `redeemSettled`
        // pays holders from — it is stranded on a `Settled` strategy, recoverable only by the owner's
        // two-transaction `rescueToVault` → `vault.rescueERC20`, and arriving there as a stray token
        // rather than as shareholder proceeds.
        //
        // BEST-EFFORT, and that is the whole asymmetry with `flatten` (which calls the same
        // `LeveragedAeroVenue` helper FAIL-CLOSED, with the proposer's floor): `flatten` is a
        // RESUMABLE op on a book that stays `Executed` — a revert is just a retry after the feed
        // recovers. `settle()` is TERMINAL, owner-driven and argument-less: a hard revert here would
        // let a stale reward feed or a broken reward route BLOCK the fund's only exit. The self-call
        // is what makes the swallow safe — the sale still fails closed INSIDE its own frame (oracle
        // floor post-checked against the measured fill), so a caught revert rolls the swap back
        // entirely and degrades to exactly the pre-fix behaviour: the tranche is left in place,
        // rescuable now that the state is `Settled`. It is never sold blind.
        try this.sellRewardSelf() {}
        catch {
            emit SettleRewardSaleDeferred();
        }
        // Discharge the accrued protocol fee from realized USDC BEFORE pushing the rest to the
        // vault. Pays `min(owed, balance)` to the live recipient; skips silently when recipient == 0
        // or owed == 0 (liability persists until a recipient exists — see edge note on `redeem`).
        Layout storage $ = _layout();
        // Flat-book invariant, completed here: `settleImpl` clears `tokenId`/ticks and its repays drive
        // both hedged-principal bases to 0 through `_repay`'s clamp — EXCEPT in the pathological case
        // where residual debt could not be covered at all, where no repay runs and the basis would
        // survive a book that no longer exists. Zeroed in THIS frame (not in the manager) because it
        // already holds `_layout()` for the fee discharge below, so the two `sstore`s cost ~20 bytes here
        // versus ~70 in the manager, which is at the EIP-170 cap — the same relocation `setTargetLtv`'s
        // target-LTV write makes.
        $.hedgedDebtA = 0;
        $.hedgedDebtB = 0;
        uint256 owed = $.protocolFeeOwed;
        address recipient = _protocolFeeRecipient();
        if (owed > 0 && recipient != address(0)) {
            uint256 bal = IERC20($.usdc).balanceOf(address(this));
            uint256 pay = owed < bal ? owed : bal;
            if (pay > 0) {
                $.protocolFeeOwed = owed - pay;
                IERC20($.usdc).safeTransfer(recipient, pay);
            }
        }
        _pushAllToVault($.usdc);
    }

    /// @dev Self-only external wrapper so a caller can sell an auto-claimed reward tranche best-effort
    ///      via `try/catch` (H3 pattern, as `crystallizeFeesSelf`). Isolating the sale in its own call
    ///      frame is what lets a stale reward feed / reverting reward route roll back ONLY the sale
    ///      (tranche untouched) while the caller completes — see the flatten-vs-settle-vs-redeem note on
    ///      `LeveragedAeroVenue.sellRewardImpl`.
    ///
    ///      TWO CALLERS, hence the neutral name: the TERMINAL `_settle` below, and
    ///      `LeveragedAeroManager.redeemUnwindImpl`, which reaches it through the local `IRewardSaleSelf`
    ///      interface because it runs under DELEGATECALL and cannot `try` its own internal reverts.
    ///      Gated to `address(this)`; runs inside the caller's own frame, so it adds no reentrancy
    ///      surface (and is deliberately NOT `nonReentrant` — the entry points already hold that guard).
    function sellRewardSelf() external {
        if (msg.sender != address(this)) revert OnlySelf();
        LeveragedAeroVenue.sellRewardImpl();
    }

    /// @dev THE ASYNC-REDEEM SIDE OF THE SAME SALE, plus the one piece of accounting it needs.
    ///      `LeveragedAeroManager.redeemUnwindImpl` calls this (through its local `IRewardSaleSelf`)
    ///      immediately after its `_unwindLiquidity`, whose `gauge.withdraw` auto-claims a reward tranche
    ///      on EVERY async redeem. Without it the redeemer is paid `f × (assets − reward)` while 100% of
    ///      the tranche stays with the stayers — and since `nav()` prices that reward, that was a
    ///      nav-vs-payout inconsistency, not just an unfairness.
    ///
    ///      RETURNS THE STAYERS' RESERVATION, which is the whole reason this is not a bare sale. The
    ///      manager's `idleUsdcBefore`/`stayersIdle` snapshots are taken BEFORE the unwind (deliberately
    ///      — LP-shed USDC is 100% the redeemer's), so proceeds landing after them would otherwise flow
    ///      ENTIRELY to the redeemer. But `gauge.withdraw` is all-or-nothing per NFT: it claims what the
    ///      WHOLE book farmed, of which the redeemer owns `f`. So `(1−f)·proceeds` is returned for the
    ///      manager to add to `stayersIdle` — the same `x − f·x` form `stayersIdle` itself uses, dust
    ///      rounding to the stayers.
    ///
    ///      BEST-EFFORT, WITH THE `try` HELD HERE rather than in the manager: the manager is at the
    ///      EIP-170 cap (the same relocation `_settle`'s hedged-basis zeroing makes), and the sale still
    ///      fails CLOSED inside `sellRewardSelf`'s own frame, so a swallowed revert rolls the swap back
    ///      whole — the tranche is left in place, never sold blind. Swallowing is REQUIRED here:
    ///      `emergencyRedeem` routes through this path and exists for the oracle-down-AND-backend-dead
    ///      state, so a stale reward feed must not be able to block the exit (same posture, same reason,
    ///      as the redeem-sweep floors). Residual on failure = exactly the pre-fix behaviour, marked by
    ///      `RedeemRewardSaleDeferred` so it is not a silent degradation.
    ///
    ///      Nested self-call (`this.sellRewardSelf()` from a frame whose `msg.sender` is already
    ///      `address(this)`) — the `OnlySelf` gate passes, and neither hop is `nonReentrant` because the
    ///      redeem entry points already hold that guard.
    /// @param shares Redeeming shares (the manager's `f` numerator).
    /// @param supply Total supply at redeem time (the `f` denominator).
    /// @return stayersShare `(1−f)` of the realised USDC proceeds; 0 when nothing sold.
    function sellRedeemRewardSelf(uint256 shares, uint256 supply) external returns (uint256 stayersShare) {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20 usdc_ = IERC20(_layout().usdc);
        uint256 sold = usdc_.balanceOf(address(this));
        try this.sellRewardSelf() {}
        catch {
            emit RedeemRewardSaleDeferred();
        }
        sold = usdc_.balanceOf(address(this)) - sold;
        return sold - Math.mulDiv(sold, shares, supply);
    }

    /// @dev Crystallise management + HWM performance fees on the PRE-ACTION vault state. The caller
    ///      supplies `navPre` (not a self-call to `nav()`) so the caller controls oracle behaviour:
    ///      deposit passes `nav()` (fail-closed — correct to revert on oracle failure); redeem passes
    ///      0 when `nav()` is unavailable → `crystallize` still accrues the price-free MANAGEMENT fee
    ///      for the elapsed `dt` (D6) and defers only the performance fee (HWM unchanged), keeping
    ///      redeem oracle-free (§7).
    /// @param navPre Pre-action NAV (USDC 6dp). Pass 0 on oracle outage → performance fee defers, but
    ///      the price-free management fee still crystallises.
    function _crystallizeFees(uint256 navPre) private {
        Layout storage $ = _layout();
        uint256 supply = IERC20(vault()).totalSupply();
        if (supply == 0) return;
        if ($.lastFeeAccrualTimestamp == 0) {
            $.lastFeeAccrualTimestamp = block.timestamp;
            return;
        }
        // Protocol fee is read LIVE from ProtocolConfig via `factory.protocolConfig()` (a
        // self-fee'd strategy handles all fee accounting itself, so the protocol
        // leg is collected here instead). Treat a missing factory/config as 0 bps.
        //
        // SHARED ARG-LIST CONTRACT: the 8-arg `LeveragedAeroFees.crystallize(...)` call below is the
        // EXECUTED crystallise; `_simulateCrystallize` (just below `_protocolFeeBps`) re-marshals the
        // SAME 8 inputs read-only for `previewRedeem`. Any arg change here MUST be mirrored there —
        // F4 was a desync between the two. This site applies state (mint / owed / hwm / timestamp);
        // the simulate site only derives `(navNet, supplyPost)`, so they can't collapse into one
        // helper without either losing these raw returns or breaking the try/catch atomicity.
        (uint256 feeShares, uint256 newHwm, uint256 newLast, uint256 protocolUsdc) = LeveragedAeroFees.crystallize(
            navPre,
            supply,
            $.hwmPerShare,
            $.lastFeeAccrualTimestamp,
            block.timestamp,
            uint256($.managementFeeBps),
            uint256($.performanceFeeBps),
            _protocolFeeBps()
        );
        $.hwmPerShare = newHwm;
        $.lastFeeAccrualTimestamp = newLast;
        if (protocolUsdc > 0) $.protocolFeeOwed += protocolUsdc;
        if (feeShares > 0) ISyndicateVault(vault()).strategyMint($.feeRecipient, feeShares);
    }

    /// @dev READ-ONLY twin of `_crystallizeFees`'s compute: derives the `(navNet, supplyPost)` the
    ///      EXECUTED crystallise would produce, without applying any state. `previewRedeem` uses it so
    ///      its quote tracks execution to the wei. Marshals the SAME 8 `LeveragedAeroFees.crystallize`
    ///      args as `_crystallizeFees` — see the "SHARED ARG-LIST CONTRACT" note there; keep the two
    ///      lists in lock-step (F4 was a desync). Honours the same `lastFeeAccrualTimestamp == 0`
    ///      seed-guard early-return (no fee on first accrual). `_protocolFeeBps()` reads ProtocolConfig;
    ///      the caller wraps this in a try/catch so a reverting config read degrades to `(0, false)`.
    function _simulateCrystallize(uint256 navPre, uint256 supply)
        private
        view
        returns (uint256 navNet, uint256 supplyPost)
    {
        Layout storage $ = _layout();
        if ($.lastFeeAccrualTimestamp == 0) return (navPre, supply);
        (uint256 feeShares,,, uint256 freshSlice) = LeveragedAeroFees.crystallize(
            navPre,
            supply,
            $.hwmPerShare,
            $.lastFeeAccrualTimestamp,
            block.timestamp,
            uint256($.managementFeeBps),
            uint256($.performanceFeeBps),
            _protocolFeeBps()
        );
        navNet = navPre - freshSlice; // freshSlice ≤ navPre (lib caps at navPre) → no underflow
        supplyPost = supply + feeShares;
    }

    /// @dev Self-only external view wrapper so `previewRedeem` can `try/catch` `_simulateCrystallize`
    ///      (its `_protocolFeeBps()` does an external ProtocolConfig staticcall — near-unreachable to revert
    ///      on a set-once UUPS proxy, but the advisory view must degrade to `(0, false)` symmetrically with
    ///      its other failure modes rather than revert while executed `redeem` swallows the same).
    function simulateCrystallizeSelf(uint256 navPre, uint256 supply)
        external
        view
        returns (uint256 navNet, uint256 supplyPost)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        return _simulateCrystallize(navPre, supply);
    }

    /// @dev The protocol-wide ProtocolConfig, resolved through the vault's
    ///      `factory()` hop; `address(0)` when the vault reports no factory,
    ///      which callers treat as no protocol fee. That is the launch default
    ///      here — `LeveragedAeroVault.factory()` returns 0 until a fee config
    ///      is wired.
    function _protocolConfig() private view returns (address) {
        address factory_ = ISyndicateVault(vault()).factory();
        return factory_ == address(0) ? address(0) : ISyndicateFactory(factory_).protocolConfig();
    }

    /// @dev Live protocol-fee rate (bps) from ProtocolConfig; 0 if unset.
    function _protocolFeeBps() private view returns (uint256) {
        address cfg = _protocolConfig();
        return cfg == address(0) ? 0 : IProtocolConfig(cfg).protocolFeeBps();
    }

    /// @dev Live protocol-fee recipient from ProtocolConfig; `address(0)` when unset (skips discharge).
    function _protocolFeeRecipient() private view returns (address) {
        address cfg = _protocolConfig();
        return cfg == address(0) ? address(0) : IProtocolConfig(cfg).protocolFeeRecipient();
    }

    /// @dev Self-only external wrapper so `redeem` can crystallise fees best-effort via `try/catch`
    ///      (H3). A fee-mint can revert on the vault's `whenNotPaused` / depositor-whitelist gates;
    ///      isolating it in an external call lets a failure roll back ONLY the crystallise (HWM +
    ///      `lastFeeAccrualTimestamp` unchanged → fee defers) while redeem proceeds. Gated to
    ///      `address(this)`; runs inside redeem's `nonReentrant` scope (not itself guarded), so it
    ///      adds no reentrancy surface.
    function crystallizeFeesSelf(uint256 navPre) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _crystallizeFees(navPre);
    }

    /// @dev Best-effort crystallise (H3 pattern), single-site: isolates the fee-MINT / near-unreachable
    ///      config-read revert inside the external `crystallizeFeesSelf` self-call so a failure rolls back
    ///      ONLY the crystallise (HWM + `lastFeeAccrualTimestamp` unchanged → fee defers) while the calling
    ///      op proceeds. `navPre` stays computed by the CALLER so fail-closed pricing (a down oracle) reverts
    ///      there, outside this try. Not narrowed by selector; the asymmetric un-try'd config reads
    ///      (compound/settle/skim) hard-revert on the same failure.
    function _crystallizeBestEffort(uint256 navPre, uint8 op) private {
        try this.crystallizeFeesSelf(navPre) {}
        catch {
            emit FeeCrystallizeDeferred(op, navPre);
        }
    }

    /// @dev `_crystallizeBestEffort` + net the FRESH protocol slice the crystallise accrued out of `navPre`
    ///      (`navNet = navPre − (owedNow − owedBefore)`; prior owed already net inside `nav()`). No underflow
    ///      — the fees lib caps the slice at navPre. On a caught crystallise owed is unchanged → `navNet ==
    ///      navPre` (self-consistent). Shared by `deposit` and the fast `redeem` (both price at `f × navNet`
    ///      against a POST-crystallise `supply` read by the caller).
    function _crystallizeAndNet(uint256 navPre, uint8 op) private returns (uint256 navNet) {
        uint256 owedBefore = _layout().protocolFeeOwed;
        _crystallizeBestEffort(navPre, op);
        navNet = navPre - (_layout().protocolFeeOwed - owedBefore);
    }

    /// @notice Oracle-priced deposit: mint vault shares proportional to current NAV. Ordering is
    ///         load-bearing (phantom-fee fix): crystallise fees on the PRE-deposit NAV (fail-closed on
    ///         the PRICE) BEFORE pulling USDC, then mint via the ERC-4626 virtual-offset formula.
    ///         Deposited USDC sits idle until a proposer calls `deployIdle()`.
    ///
    ///         The crystallise is best-effort (H3, mirrors `redeem`): `navPre = nav()` stays OUTSIDE
    ///         the try/catch so a down oracle still reverts the deposit (fail-closed pricing), but a
    ///         fee-MINT revert (vault paused / feeRecipient de-whitelisted on a whitelist vault) rolls
    ///         back ONLY the crystallise (fee defers) — deposits must not brick once a fee accrues. The
    ///         catch ALSO swallows a reverting ProtocolConfig read (`_protocolFeeBps`/`_protocolFeeRecipient`
    ///         staticcall inside the crystallise) — near-unreachable on a set-once UUPS proxy, so the
    ///         intended target is the fee-MINT; it is NOT narrowed by selector (fee-mint reverts are
    ///         hard to enumerate). Note the asymmetry: `compound()` / `_settle()` / `_dischargeRedeemSkim`
    ///         read ProtocolConfig UN-try'd and hard-revert on the same failure.
    ///         Pricing mirrors `redeem`: snapshot `owedBefore`, then net the FRESH protocol slice the
    ///         crystallise accrued out of `navPre` (`navNet = navPre − (owedNow − owedBefore)`); `supply`
    ///         is read POST-crystallise (includes the perf-fee mint). Without the netting the depositor
    ///         over-pays / under-mints by their share of the fresh slice. On a caught crystallise owed is
    ///         unchanged → `navNet == navPre` (self-consistent).
    /// @param assets    USDC to deposit (6dp).
    /// @param minShares Minimum vault shares to accept (slippage guard).
    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (_state != State.Executed) revert NotExecuted();
        // Crystallize on pre-deposit NAV. `nav()` OUTSIDE try/catch → a down oracle reverts the deposit
        // (fail-closed pricing is load-bearing). Only the fee-MINT failure is swallowed (fee defers).
        uint256 navPre = nav();
        uint256 navNet = _crystallizeAndNet(navPre, OP_DEPOSIT);
        address vault_ = vault();
        // FUND CAPACITY CEILING (`vault.maxTotalAssets`, USDC 6dp; `0` == unlimited). Enforced HERE
        // because this is the one path every share-minting deposit takes — per-user accounts and
        // direct depositors alike — so the ceiling binds the FUND, not a single wrapper layer. It is
        // deliberately not in `strategyMint`, which also serves the best-effort fee-share
        // crystallisation: a capacity-blocked fee mint would silently defer fees forever.
        //
        // Checked BEFORE the transfer so a rejected deposit moves no USDC at all, and measured on the
        // POST-deposit book (`navNet + assets`): `navPre` is read above before the transfer, so it
        // excludes the incoming assets. A deposit that would CROSS the ceiling is rejected outright
        // rather than trimmed — revert-don't-trim, matching every other guard here; the depositor
        // retries with the room `vault.remainingCapacity()` reports.
        {
            uint256 cap = ILeveragedAeroVaultCapacity(vault_).maxTotalAssets();
            if (cap != 0 && navNet + assets > cap) revert FundAtCapacity(navNet + assets, cap);
        }
        IERC20(_layout().usdc).safeTransferFrom(msg.sender, address(this), assets);
        uint256 supply = IERC20(vault_).totalSupply(); // POST-crystallize (includes any perf-fee mint)
        // Guard the navNet==0 share-inflation case: with holders present and a worthless book the
        // mulDiv denominator collapses to 1, minting ~assets×(supply+offset) shares (dilutes stayers).
        // First deposit (supply==0) legitimately has navNet==0 (empty book) → must stay allowed.
        if (navNet == 0 && supply > 0) revert NavUnpriceable();
        shares = Math.mulDiv(assets, supply + SHARES_VIRTUAL_OFFSET, navNet + 1);
        // Reject a pay-for-nothing deposit (mirrors redeem's `ZeroAssetsOut`): dust `assets` against
        // a large book floor to 0 shares, and with the common `minShares == 0` the guard below would
        // fall through and take the USDC for no claim.
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert InsufficientShares();
        ISyndicateVault(vault_).strategyMint(msg.sender, shares);
    }

    /// @notice Supply `amount` of the strategy's RAW idle USDC to Moonwell as collateral, so it earns
    ///         supply interest instead of sitting dead. Does NOT borrow and does NOT touch the LP —
    ///         `deployIdle` is the op that levers, `adjustLeverage` is the op that retargets. Reverts
    ///         `InsufficientIdle` if `amount` exceeds the raw balance.
    ///
    ///         WHY THIS IS A KEEPER OP AND NOT PART OF `deposit`. Supplying inside `deposit` was the
    ///         obvious shape and it is the wrong one, for two independent reasons:
    ///
    ///           1. IT PUTS MOONWELL ON THE MONEY-IN PATH. A `mint` that errors — market paused, supply
    ///              cap reached — would revert the deposit itself, i.e. an external venue's capacity
    ///              would decide whether this fund can take money at all. Here the same failure is a
    ///              keeper retry: fail-closed inside `supplyIdleImpl`, invisible to depositors.
    ///           2. IT WOULD HAVE FORCED THE RAW FLOAT TO ZERO. The redeemer's IL-cover budget in
    ///              `LeveragedAeroManager.redeemUnwindImpl` Phase 1 is the raw USDC balance, and Phase 1
    ///              is ORACLE-FREE; Phase 2 (`_settleShortfall`) is not. Supplying every deposit on
    ///              arrival would have driven Phase 1's budget structurally to 0 and pushed every full
    ///              redeem carrying an IL shortfall onto the Chainlink-reading fallback — including the
    ///              trustless `emergencyRedeem` deadman. As a keeper op, HOW MUCH FLOAT TO LEAVE
    ///              UN-SUPPLIED IS THE OPERATOR'S CALL: supply the levered book's working capital,
    ///              leave a deliberate raw float sized against the redemptions you expect to have to
    ///              cover oracle-free. That is a policy dial, not a property of the code.
    ///
    ///         The supplied USDC is LEVERAGEABLE by policy: there is no buffer/book distinction in
    ///         `Layout` and `_readCollateralDebt` is untouched, so the next `adjustLeverage` sees the
    ///         grown collateral base and levers the WHOLE book to `targetLtvBps`. That is intended —
    ///         on a book with a live position, `supplyIdle` then `adjustLeverage` is a two-step
    ///         spelling of `deployIdle`. On a FLAT book neither `adjustLeverage` nor `deployIdle` can
    ///         run (there is no position to add into; both revert downstream) — `redeploy` is the op
    ///         that re-enters a flat book, swept or not. The inverse is `withdrawIdle`: parked USDC
    ///         can be pulled back to a raw balance without levering or flattening, bounded to the
    ///         un-levered collateral so the pair of ops can never move LTV above target (during a
    ///         feed outage that bound is re-derived at the venue's own oracle — held there, not
    ///         dropped; see `withdrawIdle`).
    ///
    ///         `State.Executed` gate matches `deployIdle` / `compound` / `adjustLeverage` (every venue
    ///         op is gated the same way): pre-`execute` the seed is the owner's to activate with, and
    ///         post-`settle` the book is terminal. It works on a FLAT but `Executed` book (post-
    ///         `flatten`), which is deliberate — that is the state holding the most dead USDC — and it
    ///         is exactly why `nav()`'s flat branch must count the collateral term.
    /// @param amount USDC (6dp) to supply; must be ≤ the strategy's raw USDC balance. Zero is a
    ///               DELIBERATE silent no-op (the impl returns before touching Moonwell) — unlike the
    ///               louder venue ops, a keeper sweeping "whatever is raw" may legitimately pass 0.
    function supplyIdle(uint256 amount) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.supplyIdleImpl(amount); // raw-balance bound enforced inside (typed)
    }

    /// @notice Deploy `amount` of idle strategy USDC into the levered position (supply + borrow +
    ///         increaseLiquidity + health-assert) via `LeveragedAeroManager.deployIdleImpl()`.
    ///
    ///         `amount` IS BOUNDED BY RAW + UN-LEVERED COLLATERAL, NOT RAW + ALL COLLATERAL. The
    ///         manager sizes the borrow off the GROSS `amount` on the assumption that `amount` is
    ///         fresh, not-yet-levered NAV — raw USDC satisfies that by construction, and so does
    ///         collateral the keeper parked with `supplyIdle` but nothing has borrowed against.
    ///         Collateral already backing debt at the standing target does NOT: a `deployIdle` funded
    ///         from it is redeem → supply-straight-back → borrow, i.e. a net debt-only increase that
    ///         re-levers the same USDC twice and walks LTV from `targetLtvBps` toward `maxLtvBps` —
    ///         the exact capability the admin-only target split denies this `onlyProposer` key. The
    ///         `_unleveredCollateral` bound refuses that with a typed `InsufficientIdle` (which is
    ///         also what keeps refusals diagnosable instead of surfacing as `MoonwellRedeemFailed`
    ///         from Moonwell's own free-collateral line).
    /// @param amount       USDC to deploy (6dp); must be ≤ raw balance + un-levered collateral.
    /// @param minLiquidity Minimum liquidity to accept (slippage guard).
    function deployIdle(uint256 amount, uint256 minLiquidity) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.checkDeployableIdle(amount);
        LeveragedAeroManager.deployIdleImpl(amount, minLiquidity);
    }

    /// @notice Redeem `amount` of the strategy's parked mUSDC collateral back to a RAW USDC balance —
    ///         the exact inverse of `supplyIdle`. Does not borrow, repay, or touch the LP.
    ///
    ///         WHY THE INVERSE EXISTS: the raw float is the oracle-free IL-cover budget of
    ///         `redeemUnwindImpl` Phase 1 — the budget the trustless `emergencyRedeem` deadman spends
    ///         when feeds are down. `supplyIdle`'s float-vs-yield trade-off is only an operator POLICY
    ///         if it can be turned in both directions; without this op, an over-parked float could be
    ///         restored only by levering (`deployIdle`) or exiting the venue (`flatten`).
    ///
    ///         BOUNDED TO UN-LEVERED COLLATERAL (`C − ceil(D·1e4/targetLtvBps)`, 0 when the book is at
    ///         or above target): withdrawing collateral raises LTV, and this bound is exactly what
    ///         keeps the post-op book at or under the standing target — the mirror of `deployIdle`'s
    ///         funding bound. THE BOUND ALWAYS RUNS; what varies is the ORACLE PRICING IT. Normally
    ///         the hardened Chainlink reader; when that reader refuses (staleness, sequencer grace)
    ///         the SAME line is re-derived from Moonwell's own account snapshot and the call emits
    ///         `WithdrawIdleBoundDegraded` — held at the venue's (possibly stale) prices rather than
    ///         at truth, never dropped (`LeveragedAeroVenue.withdrawIdleImpl`). Exceeding it reverts
    ///         `InsufficientIdle` either way; if even the venue cannot answer, `ComptrollerCallFailed`
    ///         — fail closed. A redeem Moonwell's cash cannot
    ///         cover fails closed as `MoonwellRedeemFailed(err)` with nothing moved. Same gates as
    ///         `supplyIdle` (`onlyProposer`, `State.Executed`), and like it, works on a flat book —
    ///         where debt is zero, so the whole parked pot is withdrawable and the bound reads no
    ///         oracle at all (the degrade path is unreachable there).
    /// @param amount USDC (6dp) to redeem back to the raw balance; must be ≤ un-levered collateral
    ///               (priced at the hardened reader, or re-derived at the venue's oracle when that
    ///               read degrades). Zero is a silent no-op, mirroring `supplyIdle`.
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
    ///         A GENUINE NO-OP HAS NO SIDE EFFECTS. `compound` is a keeper-polled entrypoint, so a call
    ///         with nothing to harvest — a flat book, or a staked position with zero claimable AERO —
    ///         returns BEFORE crystallising. Crystallisation is not free: it mints fee-shares, accrues the
    ///         protocol slice and RATCHETS THE HWM, so a poll that moved no funds used to still dilute
    ///         holders and advance the fee clock. The probe reads `earned + held AERO` (held, so a stray
    ///         AERO balance from a previous partial fill or a donation is still a real harvest) and is
    ///         ahead of every state write. The manager repeats the same two bail-outs as belts.
    ///
    ///         WHY CRYSTALLISATION STAYS *BEFORE* THE HARVEST (fee-model note — read before "fixing" it).
    ///         Gauge rewards are not in `nav()`, so the pre-compound crystallise cannot see the value this
    ///         harvest is about to add: a harvest charges NO performance fee on its own yield, and the fee
    ///         lands at the NEXT crystallisation point instead. That lag is DEFERRAL, NOT LEAKAGE, and it
    ///         is the correct choice, for three reasons:
    ///           1. NOBODY ESCAPES AND NOBODY OVERPAYS. Every crystallisation point in this contract runs
    ///              strictly BEFORE any share is issued or burned (`deposit` crystallises pre-mint — that
    ///              is its documented phantom-fee fix — `redeem`/`fulfillRedeem` pre-burn). So the yield
    ///              sits in NAV until the next such point and is then charged to exactly the holders who
    ///              held while it accrued. A depositor entering after the harvest cannot be diluted by a
    ///              fee on gains they never received, and a redeemer leaving after it cannot dodge one.
    ///           2. A POST-HARVEST CRYSTALLISE WOULD RAISE FEES, NOT CORRECT THEM. Under a high-water
    ///              mark, expected fees increase monotonically with crystallisation FREQUENCY (each
    ///              up-move is charged, while down-moves only recover against an already-ratcheted HWM).
    ///              Adding a second, harvest-timed crystallisation point would therefore silently
    ///              increase the fee load and hand the `onlyProposer` keeper a lever over fee timing —
    ///              manager-favourable, and not something a fee schedule quoted in bps implies.
    ///           3. NOTHING IS SPECIAL ABOUT A HARVEST. LP swap fees and Moonwell collateral interest
    ///              accrue into NAV continuously and are likewise un-crystallised between points. NAV
    ///              always carries un-crystallised performance-fee liability in a discrete-crystallisation
    ///              model; the harvest is one more contribution to it.
    ///         The one-sentence version for a fee-model reviewer: *the performance fee on harvested yield
    ///         is deferred to the next crystallisation point, never waived, and because every
    ///         crystallisation point precedes share issuance and redemption, the deferral cannot shift the
    ///         fee onto or away from any holder.* KNOWN AND ACCEPTED RESIDUAL: `_settle()` does not
    ///         crystallise, so the final harvest before a settle escapes the performance fee — in the
    ///         HOLDERS' favour, and terminal (there is no next point to shift it to).
    /// @param minUsdcOut   Minimum USDC out of the AERO→USDC swap (slippage guard).
    /// @param minLiquidity Minimum CL liquidity on the redeploy (slippage guard).
    function compound(uint256 minUsdcOut, uint256 minLiquidity) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        // GENUINE-NO-OP PROBE — must precede the crystallise (see the header). Order matches the
        // manager's own bail-outs: flat book first, then the caller-arg belt, then "is there any reward".
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
        // Crystallize on the pre-compound NAV (fail-closed on the PRICE; `nav()` stays outside the
        // try, mirroring deposit's 3.6 fee model). Best-effort on the MINT (H3): the vault's issuance
        // gate can be shut while the position stays live, and a harvest must not brick on a fee-share
        // mint — this widens the accepted H3 fee-shifting residual (a deferred slice accrues to
        // holders until the next crystallise point) from deposit/redeem to compound.
        _crystallizeBestEffort(nav(), OP_COMPOUND);
        // Discharge the protocol fee from the swapped-out USDC BEFORE it's redeployed. `skimCap`
        // is 0 when there's no recipient (accrual persists; discharge defers). The manager pays
        // `min(skimCap, usdcOut)` internally, redeploys the remainder, and returns the amount paid;
        // the STRATEGY transfers it out + decrements owed (config read + external transfer stay
        // out of the manager).
        address recipient = _protocolFeeRecipient();
        uint256 skimCap = recipient == address(0) ? 0 : $.protocolFeeOwed;
        uint256 pay = LeveragedAeroManager.compoundImpl(minUsdcOut, minLiquidity, skimCap);
        if (pay > 0) {
            $.protocolFeeOwed -= pay;
            IERC20($.usdc).safeTransfer(recipient, pay);
        }
    }

    /// @notice Re-range the CL position around the current pool tick WITHOUT swapping, via
    ///         `LeveragedAeroManager.rerangeImpl()`. The calm-gate runs FIRST, so a re-range can never
    ///         execute at a manipulated tick. No swap → principal conserved (IL is realized only on a
    ///         true exit); the collected ratio can't match the new range, so a remainder of ONE
    ///         borrowed leg is left idle — `nav()` prices it, so the re-range is NAV-neutral and the
    ///         remainder stays redeployable. Debt + collateral are untouched (health preserved); a new
    ///         tokenId is minted (Slipstream ticks are immutable), the old empty NFT is harmless dust.
    ///
    ///         NO fee crystallisation: rerange changes neither supply nor NAV, so the streaming fee is
    ///         deferred to the next crystallize point (not lost) and the HWM is unaffected.
    /// @param width_   Full range width in ticks for this cycle. Must sit on the tickSpacing grid inside
    ///                 `[minWidth, maxWidth]`.
    /// @param skewBps_ WHERE that width sits relative to the calm tick: the fraction of `width_` placed
    ///                 BELOW it, on a 1e4 scale. `5000` is centred (`width_/2` each side, the historical
    ///                 behaviour); `3500` puts 35% of the width below spot and 65% above, which is how a
    ///                 rebalancer expresses a directional view without swapping. Must be in `(0, 10000)`,
    ///                 inside the governance band `[minSkewBps, maxSkewBps]`, AND leave both sides
    ///                 spanning at least one `tickSpacing` — see `LeveragedAeroValuation.checkRange`.
    ///
    ///                 Placement is grid-approximate: both bounds round DOWN onto the spacing grid, so
    ///                 the realised range sits off the requested split by up to one spacing.
    /// @param minLiq0  Minimum token0 the re-add must consume (two-sided slippage guard).
    /// @param minLiq1  Minimum token1 the re-add must consume (two-sided slippage guard).
    ///
    /// @dev BOTH `width_` and `skewBps_` are PERSISTED here, in this frame, BEFORE the delegatecall,
    ///      because `rerangeImpl` TAKES NO RANGE PARAMS: it reads the pair straight out of storage, so
    ///      the persist must precede the delegatecall or the impl would re-range at the OLD pair. (The
    ///      stored pair's only readers are `executeImpl` and `rerangeImpl` — `nav()` does not read it,
    ///      and `deployIdle` / `compound` do not re-derive a range at all: they `increaseLiquidity` into
    ///      the STORED `posTickLower`/`posTickUpper`. So the stored pair takes economic effect at the
    ///      NEXT `rerange`, or at `execute` on a pre-genesis book.) Placing the two `sstore`s in THIS
    ///      frame rather than in the impl is a bytecode relocation for EIP-170 headroom: this frame
    ///      already holds `_layout()` for the validation, so the writes cost ~20 bytes here versus ~70 in
    ///      the manager library, which is at the cap. Exactly the same move `adjustLeverage`'s target-LTV
    ///      write already makes.
    ///
    ///      FLAT BOOK (`tokenId == 0` while still `Executed`): `rerangeImpl` returns early and the
    ///      persist is all that happens. That is deliberate — and deliberately NOT a revert — but the
    ///      honest reading is that such a book is TERMINAL UNTIL SETTLE: nothing can mint again
    ///      (`execute` is one-shot, `deployIdle` fails closed with no NFT to add into, `compound` no-ops), so
    ///      no later op consumes the stored pair. The write is kept for `layout()` / monitoring
    ///      consistency — so the fund's advertised range matches what a proposer last asked for — not
    ///      because anything re-reads it.
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

    /// @notice ADMIN-ONLY POLICY: set the fund's STANDING target LTV, in EITHER direction. This is the
    ///         multisig's leverage dial: the proposer moves the book toward the target
    ///         (`adjustLeverage`) and may de-risk by lowering it (`lowerTargetLtv`), but only the admin
    ///         can RAISE it. That is the whole point of `onlyAdmin` here: a compromised rebalancer key
    ///         can rebalance and de-lever, but it cannot lever the fund up toward the cap.
    ///
    ///         Sets policy ONLY — it moves nothing on chain. `execute` / `deployIdle` / `compound` size
    ///         their collateral/borrow split off the STORED target, and `adjustLeverage` retargets the
    ///         live position to it, so the new value takes effect on the next such call.
    ///
    ///         NOT state-gated: legal in `Pending` as well as `Executed`. Setting policy before the
    ///         genesis `execute` is exactly the case that most wants to be settable — it is how the
    ///         multisig corrects an init-time target without redeploying the clone — and there is no
    ///         invariant that a stored target only be meaningful post-execute (`_initialize` already
    ///         writes one while Pending). Post-`Settled` it is a harmless no-op on a dead book.
    /// @param targetLtvBps_ New standing target in bps. Must be non-zero (see `TargetLtvZero` — a zero
    ///                      target is not a brick, but it borrows nothing, so it is a fund that can
    ///                      silently never lever) and `≤ maxLtvBps`. A rejected value stores nothing and
    ///                      emits nothing.
    function setTargetLtv(uint16 targetLtvBps_) external onlyAdmin {
        Layout storage $ = _layout();
        if (targetLtvBps_ > $.maxLtvBps) revert TargetLtvExceedsMax();
        _storeTargetLtv($, targetLtvBps_);
    }

    /// @notice PROPOSER-SAFE DE-RISK: the proposer (rebalancer) may lower the standing target, and only
    ///         ever lower it. This is the one leverage knob the keeper holds, and it exists so the
    ///         pre-`fulfillRedeem` lever-down does not need a multisig signature inside the 2-day
    ///         `FULFILL_WINDOW` — the keeper can de-risk ahead of a large unwind and then run
    ///         `adjustLeverage` itself.
    ///
    ///         THE SECURITY PROPERTY, PLAINLY: the proposer can lower leverage, but it can NEVER raise
    ///         it (strictly-lower only), NEVER reach zero (`TargetLtvZero`, same floor as
    ///         `setTargetLtv`), and NEVER move tokens (`rescueToVault` stays `onlyAdmin`). Raising the
    ///         standing target remains admin-only via `setTargetLtv`. So the operations/policy split's
    ///         premise survives intact: a compromised keeper key still cannot rug the fund, because
    ///         levering DOWN is not a rug.
    ///
    ///         ACCEPTED RESIDUAL, stated honestly: a compromised or buggy keeper CAN ratchet the target
    ///         down toward the floor and destroy yield. That harm is bounded (it cannot pass the
    ///         non-zero floor, and de-levering conserves value modulo unwind costs), loud (every step
    ///         emits `TargetLtvUpdated` — monitor it), and reversible by the admin in ONE `setTargetLtv`.
    ///         "Every step emits `TargetLtvUpdated`" is a claim about the WHOLE contract, not just this
    ///         function: `migrateVenue` rewrites the target too, and `LeveragedAeroVenue.applyVenue`
    ///         emits the same event (same signature, same `topic0`, same emitting address) when it does.
    ///         Do not add a fourth write path without an emit — the monitor built on this sentence would
    ///         go blind to it.
    ///
    ///         THE GATE THIS RESTS ON, RECORDED SO IT IS NOT LOOSENED BY ACCIDENT. "The keeper cannot
    ///         raise leverage" is NOT a property of this function alone. `migrateVenue` is `onlyProposer`
    ///         and rewrites BOTH `targetLtvBps` and `maxLtvBps`, so a keeper that could choose the
    ///         migration params could raise both in one call and walk straight past the strictly-lower
    ///         rule here. It cannot, for exactly two reasons, and only those two:
    ///           1. `stageVenue` is OWNER-gated — the keeper cannot author a destination; and
    ///           2. the params are BYTE-COMMITTED — `migrateVenue` re-derives
    ///              `keccak256(abi.encode(p))` and requires it to equal the staged hash, so the keeper
    ///              can only execute the exact parameter set the owner signed off, never a variant.
    ///         Both hold today. LOOSENING `stageVenue`'s GATE LATER — to the proposer, to a role, to a
    ///         "trusted" relayer — WOULD SILENTLY UN-GATE THE TARGET LTV, with nothing in this file
    ///         changing to say so. Same for weakening the hash commitment to a partial or field-wise
    ///         check. If either must change, the target and `maxLtvBps` have to move out of the
    ///         migratable venue subset first.
    ///
    ///         Sets policy ONLY — it moves nothing on chain; the next `adjustLeverage` / `deployIdle` /
    ///         `compound` sizes at the new value. NOT state-gated, for the same reason `setTargetLtv`
    ///         is not: the stored target is meaningful in `Pending` too, and a post-`Settled` write is a
    ///         harmless no-op on a dead book.
    /// @param newTargetBps New standing target in bps. Must be STRICTLY below the current
    ///                     `targetLtvBps()` (equal reverts `TargetLtvNotLower`) and non-zero. A rejected
    ///                     value stores nothing and emits nothing.
    function lowerTargetLtv(uint16 newTargetBps) external onlyProposer {
        Layout storage $ = _layout();
        if (newTargetBps >= $.targetLtvBps) revert TargetLtvNotLower();
        // NO `maxLtvBps` CHECK, deliberately — do not "fix" its absence. The stored target already
        // cleared that bound (at init or via `setTargetLtv`), and this value is strictly below the
        // stored one, so it clears the cap by transitivity.
        _storeTargetLtv($, newTargetBps);
    }

    /// @dev Shared floor-check + persist behind BOTH target-LTV entrypoints, so the two cannot drift on
    ///      the invariant that matters (never store a zero) or on the event contract. Each caller
    ///      checks its OWN bound first — the admin's cap, the proposer's strict decrease — and passes
    ///      `$` in rather than have this re-read it, both to save bytes on a contract at the EIP-170 cap.
    ///
    ///      Persists HERE, in the strategy frame, not in the manager library: the callers already hold
    ///      `$` for their bound check, so the write is ~20 bytes here versus ~71 in the manager, which
    ///      is itself at the cap. (That rationale moved with the write from `adjustLeverage`, which no
    ///      longer takes or persists a target.)
    ///
    ///      Checking the floor AFTER the caller's bound is not an observable reorder for either caller:
    ///      zero can never exceed `maxLtvBps`, and zero is never `>=` a stored target that is itself
    ///      guaranteed non-zero — so a zero argument reaches `TargetLtvZero` on both paths, exactly as
    ///      it did when `setTargetLtv` checked the floor first.
    function _storeTargetLtv(Layout storage $, uint16 newTargetBps) private {
        if (newTargetBps == 0) revert TargetLtvZero();
        emit TargetLtvUpdated($.targetLtvBps, newTargetBps);
        $.targetLtvBps = newTargetBps;
    }

    /// @notice Retarget the position's LTV to the fund's STORED standing target `targetLtvBps()`
    ///         (borrow/repay; no new USDC enters). In the two-borrowed-legs shape collateral is
    ///         untouched, so LTV moves on the debt side via
    ///         `LeveragedAeroManager.adjustLeverageImpl`: lever UP borrows the cbBTC/WETH delta and adds
    ///         it (`minLiq`); lever DOWN unwinds the matching CL fraction and repays (per-leg residual
    ///         rebalanced through USDC, bounded by `minOut`). Ends with `_assertHealthy`.
    ///
    ///         The target is NOT a parameter — it is policy, written at init, by the admin via
    ///         `setTargetLtv` (either direction), or by the proposer via `lowerTargetLtv` (DOWN only).
    ///         That is what keeps the `onlyProposer` keeper unable to INCREASE the fund's risk. No
    ///         `maxLtvBps` check is needed here: the stored target cleared that bound when it was
    ///         written, so this entrypoint is purely "move the book to where policy already says".
    ///
    ///         ASSET-MODE (leg-B slot == usdc): a lever-UP borrows ONLY leg A and pairs it with USDC
    ///         drawn from the book's OWN USDC — raw balance first, then the mUSDC collateral the
    ///         keeper's `supplyIdle` parked it in — sized closed-form so the LP's leg-A amount equals
    ///         the added leg-A debt — the delta-hedge is preserved (the alternative, swapping part of
    ///         the borrow to USDC, would leave the book net short). The draw is value-conserving (a
    ///         NAV component moving into the LP) and the sizing corrects for the collateral it
    ///         consumes, landing the book AT target (see `assetModeLeverUpPair`'s fixed point). It
    ///         does shrink the raw redeem-cover float and/or the collateral cushion, and near a range
    ///         edge the draw per unit of new debt diverges — `rerange` first when the price sits near
    ///         an edge (operator note on `adjustLeverageImpl`). An under-funded op fails closed with
    ///         the whole call rolled back: realistically `MoonwellRedeemFailed(err)` from the mid-op
    ///         collateral redeem (the typed `InsufficientIdleForLeverUp` bound is unreachable from
    ///         this entrypoint and kept as defence in depth).
    ///
    ///         NO fee crystallisation (like `rerange`): no supply change, no PnL realized; the
    ///         streaming fee is deferred and the HWM is unaffected.
    /// @param minLiq Minimum CL liquidity on a lever-UP add (slippage guard).
    /// @param minOut Minimum USDC out of a lever-DOWN residual swap (slippage guard).
    function adjustLeverage(uint256 minLiq, uint256 minOut) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroManager.adjustLeverageImpl(_layout().targetLtvBps, minLiq, minOut);
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

    /// @notice Oracle-priced FAST-PATH redeem (the everyday exit): pay `shares × nav() / supply`,
    ///         funded from the Moonwell USDC collateral ONLY — no LP touch, no debt repay. Caller must
    ///         `vault.approve(strategy, shares)` first (shares are pulled via `safeTransferFrom`).
    ///
    ///         Oracle-dependent by design (fail-closed, exactly like `deposit`): `navPre = nav()`
    ///         reverts on a down oracle — the caller then routes to `requestRedeem`. **No protocol-fee
    ///         skim on this path**: `nav()` is ALREADY net of `protocolFeeOwed`, so pricing at
    ///         `f × navNet` provably preserves stayers' per-share (a skim would double-charge).
    ///
    ///         The LTV gate is authoritative in the manager (`fastRedeemImpl` computes the post-withdraw
    ///         LTV on the pre-withdraw prices and reverts `FastRedeemExceedsLtv` if it breaches
    ///         `maxLtvBps`, plus a belt `_assertHealthy()`); a breach means the collateral can't fund
    ///         this size without a deleverage → the frontend routes to `requestRedeem`.
    /// @param shares       Vault shares to redeem (12dp).
    /// @param minAssetsOut Minimum USDC out (slippage guard on the payout).
    function redeem(uint256 shares, uint256 minAssetsOut) external nonReentrant returns (uint256 assetsOut) {
        if (_state != State.Executed) revert NotExecuted();

        // 1. Crystallise on the pre-redeem NAV (fail-closed: a down oracle reverts — correct, the fast
        //    path is inherently oracle-dependent). Best-effort (H3, §7): a fee-mint revert (vault paused
        //    / feeRecipient de-whitelisted) — or a near-unreachable config-read revert inside the
        //    crystallise — rolls back ONLY the crystallise (owed + supply unchanged, so the netting below
        //    sees a 0 fresh slice) and the exit still proceeds. Not narrowed by selector; the asymmetric
        //    un-try'd config reads (compound/settle/skim) hard-revert on that same failure.
        uint256 navPre = nav();
        uint256 navNet = _crystallizeAndNet(navPre, OP_REDEEM);

        // 2. Price against the POST-crystallize book, both effects consistently: `supply` is read
        //    after the crystallize (includes the perf-fee mint dilution) and the FRESH protocol slice
        //    it just accrued is netted out of navPre inside `_crystallizeAndNet`. Without the netting
        //    the redeemer would capture f×slice from stayers.
        address vault_ = vault();
        uint256 supply = IERC20(vault_).totalSupply();
        assetsOut = Math.mulDiv(shares, navNet, supply); // rounds down, LP-favourable
        if (assetsOut < minAssetsOut) revert InsufficientAssetsOut();
        // Reject a burn-for-zero: at navNet==0 (owed ≥ gross book) or a dust-share redeem that floors to
        // 0, `assetsOut == 0` with the common `minAssetsOut == 0` would pull + burn shares for no payout.
        // (The async path guards the same case in `_proportionalRedeem`, after its skim.)
        if (assetsOut == 0) revert ZeroAssetsOut();

        // 3. Pull shares from caller (requires prior vault.approve(strategy, shares)).
        IERC20(vault_).safeTransferFrom(msg.sender, address(this), shares);

        // 4. Fund `assetsOut`: idle USDC first (up to the redeemer's pro-rata `f×idle` share, so a
        //    partial redeem never dips into a stayer's `(1-f)×idle`), remainder from collateral
        //    (LTV-gated in the manager on that remainder only).
        uint256 idleShare = Math.mulDiv(IERC20(_layout().usdc).balanceOf(address(this)), shares, supply);
        //    `shares == supply` is threaded through so the funding step can recognise a FULL redeem and
        //    burn the cTOKEN balance rather than a stored-rate underlying amount (otherwise the rate gap
        //    strands collateral in a fund that no longer has shares). It returns the payout it actually
        //    funded: identical to `assetsOut` on every other path, and `assetsOut` PLUS the fresh-rate
        //    surplus on that one — never less, so the `minAssetsOut` floor checked above still holds.
        assetsOut = LeveragedAeroVenue.fastRedeemImpl(assetsOut, idleShare, shares == supply);

        // 5. Pay out + burn.
        IERC20(_layout().usdc).safeTransfer(msg.sender, assetsOut);
        ISyndicateVault(vault_).strategyBurn(shares);
    }

    /// @notice Advisory preview of the fast-path exit — mirrors `redeem` EXACTLY, including the pending
    ///         fee crystallise. The executed `redeem` crystallises first (perf-fee mint dilutes supply,
    ///         a fresh protocol slice nets out of `nav()`), so pricing against the LIVE `nav()`/`supply`
    ///         would over-quote whenever fees are pending (real gain above the HWM, or accrued mgmt `dt`).
    ///         Here we SIMULATE that crystallise with the current storage — same pure `LeveragedAeroFees`
    ///         inputs `_crystallizeFees` uses — and price on `navNet = navPre − freshSlice` over the
    ///         post-mint `supply + feeShares`, so the quote equals the executed payout to the wei *when
    ///         executed at the same `block.timestamp`* — with ONE carve-out, below. A frontend passing it
    ///         as `minAssetsOut` should
    ///         still apply a small slippage tolerance: the streaming management fee accrues with `dt`, so
    ///         a redeem landing a few blocks later pays marginally LESS than this quote (and the NAV may
    ///         drift), which would otherwise bounce an exact-quote `minAssetsOut`.
    ///
    ///         THE CARVE-OUT, and it is in the SAFE direction: a FULL redeem of a flat, zero-debt book
    ///         burns the whole cToken balance and pays the redeemer the FRESH-rate proceeds, while this
    ///         quote prices the same collateral at `nav()`'s stored (last-accrued) rate. With un-accrued
    ///         supply interest outstanding the executed payout is therefore LARGER than the quote (on the
    ///         suite's fixture: quotes 1,370,000e6, pays 1,400,000e6). It only ever under-quotes, so a
    ///         preview-derived `minAssetsOut` cannot bounce on it.
    ///
    ///         Safe-direction edge for the PAYOUT (opposite sign): if the executed crystallise DEFERS
    ///         (fee-mint reverts on a paused / un-whitelisted vault, H3), the actual pays MORE than this
    ///         fee-adjusted quote (no dilution, no slice) — that case never bounces a preview-derived
    ///         `minAssetsOut`. NOTE `fastOk` is the OPPOSITE sign: on a deferred crystallise the executed
    ///         `assetsOut = shares × navPre / supply` is LARGER than this fee-adjusted quote (`strategyBurn`
    ///         is not `whenNotPaused`, so redeem proceeds while the crystallise defers), so its larger
    ///         `fromCollateral` yields a higher `postLtv` — the on-chain `fastRedeemImpl` gate can revert
    ///         `FastRedeemExceedsLtv` even though this preview optimistically returned `fastOk == true`.
    ///         `fastOk` is ADVISORY; the manager's LTV gate is authoritative.
    ///
    ///         Returns `(0, false)` instead of reverting when the oracle is down (try/catch on the nav +
    ///         collateral/debt reads), when the fee simulation's config read reverts (try/catch on
    ///         `simulateCrystallizeSelf` — symmetric with the other degrade-to-`(0,false)` modes rather
    ///         than reverting while executed `redeem` swallows the same), and when the simulated payout
    ///         floors to 0 (mirrors `redeem`'s `ZeroAssetsOut` guard) so a preview-`minAssetsOut` never
    ///         quotes a payout the executed path would revert on. ADVISORY ONLY — the on-chain gate in
    ///         `fastRedeemImpl` is authoritative; a frontend uses `fastOk` to pre-route to `requestRedeem`.
    /// @param shares Vault shares to preview (12dp).
    /// @return assetsOut Predicted USDC out (0 when unpriceable or the payout floors to 0).
    /// @return fastOk    True iff the fast path would price AND clear the LTV gate (advisory — see above).
    function previewRedeem(uint256 shares) external view returns (uint256 assetsOut, bool fastOk) {
        // Body relocated to `LeveragedAeroVenue.previewRedeemImpl` under EIP-170 pressure (same
        // rationale as `layout()`). Behaviour identical — see the note there.
        return LeveragedAeroVenue.previewRedeemImpl(shares);
    }

    /// @dev Self-only external view so `previewRedeem` can try/catch the manager's oracle reads
    ///      (a down feed reverts inside `_readCollateralDebt`). Runs under staticcall; no state change.
    function previewCollateralDebt() external view returns (uint256 collateralUsdc, uint256 debtUsdc) {
        if (msg.sender != address(this)) revert OnlySelf();
        return LeveragedAeroManager.readCollateralDebtImpl();
    }

    // ── Escrowed async redeem (Lane-B-style, no price freeze) ──

    /// @notice Escrow `shares` for an async proportional redeem — the exit for holders the LTV-gated
    ///         fast path can't serve (or when the oracle is down). Shares are pulled NOW
    ///         (`vault.approve(strategy, shares)` required) and held in the strategy; NO price is
    ///         stamped (shares keep bearing PnL until `fulfillRedeem`), so `cancelRedeem` is not a free
    ///         look-back option. Levering down before the fulfill stays a ONE-PARTY step under the
    ///         admin/proposer split: the proposer (rebalancer) lowers the standing target itself with
    ///         `lowerTargetLtv` (monotonic down), then runs `adjustLeverage` and `fulfillRedeem` — no
    ///         multisig round trip inside `FULFILL_WINDOW`. Only RAISING the target back afterwards is
    ///         the admin's `setTargetLtv`.
    /// @param shares       Vault shares to escrow (12dp).
    /// @param minAssetsOut Slippage floor enforced (on the net amount) at fulfill.
    /// @return id          The request id (also emitted).
    function requestRedeem(uint256 shares, uint256 minAssetsOut) external nonReentrant returns (uint256 id) {
        if (_state != State.Executed) revert NotExecuted();
        IERC20(vault()).safeTransferFrom(msg.sender, address(this), shares);
        Layout storage $ = _layout();
        id = $.nextRedeemRequestId++;
        $.redeemRequests[id] = RedeemRequest({
            owner: msg.sender,
            shares: shares,
            minAssetsOut: minAssetsOut,
            requestedAt: uint40(block.timestamp),
            settled: false
        });
        emit RedeemRequested(id, msg.sender, shares);
    }

    /// @notice Fulfill an escrowed request via the oracle-free proportional unwind (the demoted
    ///         everyday path, now reachable ONLY here and via `emergencyRedeem`). `onlyProposer`: the
    ///         proposer (rebalancer) lowers the standing target with `lowerTargetLtv` if the unwind
    ///         needs it, runs `adjustLeverage` so the unwind's IL self-funds, then fulfills paying
    ///         `request.owner` — all three are proposer-callable, so the 2-day `FULFILL_WINDOW` never
    ///         depends on a multisig signature. NOT owner-callable — an owner-callable fulfill would
    ///         resurrect the demoted oracle-free path through the side door.
    ///
    /// @dev THE FLOOR IS `max(stored, fresh)`, NEVER `min`. The requester's own `minAssetsOut` is their
    ///      guarantee and the proposer must not be able to lower it — that direction would let whoever
    ///      fulfils choose a worse payout than the redeemer signed up for. `minAssetsOut` here is the
    ///      PROPOSER's guarantee, layered on top: the stored floor was fixed at `requestRedeem` and may
    ///      be up to `FULFILL_WINDOW` (2 days) stale by the time this runs, which is a long time for a
    ///      levered book to move. Nothing else on the path covers that gap — `redeemUnwindImpl`'s
    ///      per-swap sweep floors bound individual SWAPS, not the net payout, and a full redeem's covers
    ///      lean on this number alone. Passing 0 keeps the previous behaviour exactly (the stored floor
    ///      wins), so an integrator with nothing fresher to say is not forced to invent one.
    /// @param id            Request id to fulfill.
    /// @param minAssetsOut  Fresh floor on the net payout; the effective floor is the larger of this and
    ///                      the one stored at request time. 0 to defer entirely to the stored floor.
    function fulfillRedeem(uint256 id, uint256 minAssetsOut) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        Layout storage $ = _layout();
        RedeemRequest storage r = $.redeemRequests[id];
        if (r.settled) revert RequestSettled();
        uint256 stored = r.minAssetsOut;
        uint256 assetsOut = _proportionalRedeem(r.owner, r.shares, minAssetsOut > stored ? minAssetsOut : stored);
        r.settled = true;
        emit RedeemFulfilled(id, r.owner, assetsOut);
    }

    /// @notice Cancel an unsettled request and return the escrowed shares to its owner. Request owner
    ///         only, callable in ANY strategy state (no `State.Executed` gate): a request outstanding
    ///         when the strategy settles must stay cancellable so the owner can exit via the vault
    ///         normally.
    /// @param id Request id to cancel.
    function cancelRedeem(uint256 id) external nonReentrant {
        RedeemRequest storage r = _layout().redeemRequests[id];
        if (msg.sender != r.owner) revert NotRequestOwner();
        if (r.settled) revert RequestSettled();
        r.settled = true;
        IERC20(vault()).safeTransfer(r.owner, r.shares);
        emit RedeemCancelled(id, r.owner, r.shares);
    }

    /// @notice Deadman trustless backstop: after `FULFILL_WINDOW` elapses on an unfulfilled request,
    ///         its owner may self-fulfill via the same oracle-free proportional unwind. This single
    ///         gate covers the whole deadman matrix — fulfill is oracle-free, so "oracle down + backend
    ///         alive" resolves via normal `fulfillRedeem`; the only stuck case (oracle down AND backend
    ///         dead) self-resolves here. `minAssetsOut` is a FRESH arg (the stored one may be stale
    ///         after 2 days).
    ///
    /// @dev ORACLE-FREE, WITH ONE NAMED RESIDUAL. Every priced read on this path is caught and degrades
    ///      rather than reverting: `_proportionalRedeem`'s `try this.nav()` falls back to `navPre = 0`,
    ///      the crystallise defers on that, the auto-claimed reward tranche's sale defers and marks
    ///      `RedeemRewardSaleDeferred`, and `redeemUnwindImpl`'s leg-sweep floors degrade to 0 and mark
    ///      `RedeemSweepFloorsDegraded`. The unwind, the pro-rata repays and the share burn are pure
    ///      arithmetic against pool state.
    ///
    ///      THE SINGLE EXCEPTION IS `redeemUnwindImpl`'s Phase 2 (`_settleShortfall`), which reads
    ///      Chainlink to price a deficit buy — and it is reached only when a FULL redeem still owes after
    ///      its own swept legs (step C) and raw float could not cover the shortfall, i.e. on genuine deep
    ///      IL. It fails CLOSED there, deliberately: the alternative is paying out against a book nobody
    ///      can price. Two things keep it unreached in the ordinary case — step B repays the CURRENT
    ///      accrued debt (a stored read used to leave interest dust that sent EVERY full redeem through
    ///      Phase 2), and step C sells the surplus leg into USDC before Phase 1 spends it. Sizing the raw
    ///      float with `supplyIdle` is how an operator manages what is left of the residual.
    /// @param id           Request id (owner-gated).
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
    ///      `shares` for `recipient`, paying net of the Item-3 protocol skim, enforcing `minOut`,
    ///      burning the escrowed shares. Best-effort crystallise (H3 pattern: navPre=0 on oracle
    ///      outage → price-free mgmt fee accrues, perf fee defers; a fee-mint revert — or the
    ///      near-unreachable ProtocolConfig-read revert inside the crystallise — defers the whole crystallise)
    ///      keeps the exit oracle-free (§7). Not narrowed by selector; note `_dischargeRedeemSkim` below
    ///      reads ProtocolConfig UN-try'd and hard-reverts on that same failure. `supply` fixed once before burn.
    function _proportionalRedeem(address recipient, uint256 shares, uint256 minOut)
        private
        returns (uint256 assetsOut)
    {
        uint256 navPre;
        try this.nav() returns (uint256 navNow) {
            navPre = navNow;
        } catch {
            navPre = 0;
        }
        _crystallizeBestEffort(navPre, OP_FULFILL); // navPre == 0 here on an oracle-out redeem → fee defers

        uint256 supply = IERC20(vault()).totalSupply();
        assetsOut = LeveragedAeroManager.redeemUnwindImpl(shares, supply);
        // Item-3 skim: the redeemer bears their pro-rata slice of the accrued protocol liability (the
        // proportional unwind pays the GROSS book; nav() is net → skim rebalances). Pure arithmetic,
        // no oracle. Skips silently when recipient == 0 or owed == 0.
        assetsOut -= _dischargeRedeemSkim(shares, supply, assetsOut);
        // Reject a burn-for-zero (mirrors the fast path's guard): at navNet==0 (owed ≥ gross book) the
        // skim nets the payout to exactly 0; with a stored `minOut == 0` the `< minOut` check below
        // would fall through and burn the escrowed shares for no payout. Reverting keeps the shares
        // escrowed (no price is stamped at request time → they keep bearing PnL and pay out later) and
        // `cancelRedeem` (no State/navNet gate) always lets the owner recover them.
        if (assetsOut == 0) revert ZeroAssetsOut();
        if (assetsOut < minOut) revert InsufficientAssetsOut();
        IERC20(_layout().usdc).safeTransfer(recipient, assetsOut);
        ISyndicateVault(vault()).strategyBurn(shares);
    }

    /// @dev Skim the redeemer's pro-rata protocol-fee slice from `assetsOut` and pay it to the live
    ///      recipient. Returns the amount skimmed (0 when recipient unset or nothing owed) so the
    ///      caller nets it out of the payout. `fee = owed × shares / supply` (rounds down,
    ///      LP-favourable) capped at `assetsOut`; `owed` decremented by the skim. No oracle.
    ///      Edge: if the recipient is later zeroed while `owed > 0`, discharge skips here (and in
    ///      compound/settle) and the liability persists — `nav()` stays net — until a recipient exists.
    function _dischargeRedeemSkim(uint256 shares, uint256 supply, uint256 assetsOut) private returns (uint256 fee) {
        Layout storage $ = _layout();
        uint256 owed = $.protocolFeeOwed;
        if (owed == 0) return 0;
        address recipient = _protocolFeeRecipient();
        if (recipient == address(0)) return 0;
        fee = Math.mulDiv(owed, shares, supply);
        if (fee > assetsOut) fee = assetsOut;
        if (fee == 0) return 0;
        $.protocolFeeOwed = owed - fee;
        IERC20($.usdc).safeTransfer(recipient, fee);
    }

    /// @notice Sweep a STRAY ERC-20 (airdrop / accidental send) back to the vault. ADMIN-ONLY (§8) —
    ///         the vault owner / multisig, NOT the proposer. Moving tokens out of the strategy is a
    ///         custody action, not an operation, and the operations/policy split says the keeper key
    ///         must not be able to move funds; the sweep is also rare and never time-critical, so
    ///         routing it through the multisig costs nothing operationally. (It was previously
    ///         `proposer() || owner()`; the proposer leg is gone.) Target is always `vault()`, never
    ///         caller-supplied, so the caller cannot pick the destination (§13); onward recovery is the vault's own
    ///         owner-only `rescueERC20`, which refuses BOTH the vault asset (while shares are
    ///         outstanding) and the share token itself. Reverts `CannotRescuePositionToken` for any
    ///         position/accounting token — usdc / cbBTC / weth (all NAV-counted) / mUsdc / mCbBTC /
    ///         mWeth — and for two more:
    ///
    ///         - the VAULT SHARE token: this strategy custodies live shares (`requestRedeem` escrows,
    ///           and the shares pulled mid-`redeem`), which are depositor claims, not strays. Without
    ///           this the pair `rescueToVault(vault) → vault.rescueERC20(vault, attacker)` would
    ///           exfiltrate every escrowed claim. Escrows are recovered via `cancelRedeem`.
    ///         - the gauge reward token (read live from the gauge) WHILE EXECUTED, so a sweep can't
    ///           bypass `compound()`. Once `Settled` that reason is gone (`compound` reverts
    ///           `NotExecuted`), so post-settle the reward token IS a stray and sweeping it to the
    ///           vault (where the owner's non-asset `rescueERC20` applies) is the only recovery.
    ///           `_settle` DOES sell the tranche its unwind auto-claims, so this is the RESIDUAL
    ///           case only: the sale is best-effort and a stale reward feed / broken reward route
    ///           leaves the tranche in place (`SettleRewardSaleDeferred`), as does a sub-micro-USD
    ///           dust balance. That residue, plus any post-settle donation, is what this recovers.
    ///
    ///         The position NFT is never swept (no ERC-721 path).
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
    ///         `keccak256(abi.encode(LeveragedAeroVenue.VenueParams))`; `bytes32(0)` clears. VAULT
    ///         OWNER ONLY — this is the venue-selection authority (the same trust root as
    ///         `rescueToVault`'s owner leg and the vault's fee config), so the hot proposer key can
    ///         never choose where the fund's liquidity goes. Staging is inert: nothing about the
    ///         live venue, the position, or share pricing changes until the proposer executes
    ///         `migrateVenue` with the byte-exact params. Re-staging replaces the previous hash.
    /// @param venueHash keccak256 of the ABI-encoded `VenueParams` to authorize (0 = clear).
    function stageVenue(bytes32 venueHash) external {
        if (msg.sender != Ownable(vault()).owner()) revert NotVaultOwner();
        LeveragedAeroVenue.stageImpl(venueHash);
    }

    /// @notice Unwind the WHOLE book to idle USDC while staying `Executed` — the migration's first
    ///         leg, and a general proposer de-risk lever. Runs `settleImpl`'s exact unwind (exit
    ///         gauge + CL, repay both legs self-funding any shortfall, redeem all collateral, sweep
    ///         residual legs to USDC, Chainlink-floored slippage via `maxSlippageBps`) but does NOT
    ///         settle: no state transition, no push-to-vault, no protocol-fee discharge. Deposits
    ///         and redeems keep working against the flat book (NAV == idle USDC, oracle-free); the
    ///         proposer re-enters via `redeploy` — into the current venue, or into a new one after
    ///         `migrateVenue`. Idempotent on an already-flat book.
    ///
    ///         GUARDS (both added because `flatten` is repeatable, unlike the terminal `settle` whose
    ///         unwind body it reuses): the pool is CALM-GATED before the burn — `settleImpl` has no
    ///         gate of its own and `_unwindLiquidity`'s mins are derived from the same `slot0()` it
    ///         burns at, so they bind nothing against a shoved tick — and the reward tranche the
    ///         unwind auto-claims is SOLD here, so the flat-book `nav()` (idle USDC only) is again the
    ///         whole book rather than understating it for the length of the flat window. That sale is
    ///         FAIL-CLOSED under the caller's floor, because a reverted `flatten` is just a retry;
    ///         `_settle` sells the same tranche BEST-EFFORT, because a reverted `settle` is a fund
    ///         that cannot exit (see the note at that call site).
    /// @param minRewardUsdcOut Minimum USDC out of the gauge-reward sale. Required nonzero only when
    ///                         a reward balance is actually present; the L9 oracle floor applies on
    ///                         top, so the effective bound is `max(this, floor)`.
    /// @param minIdleUsdcOut   Aggregate floor on the strategy's idle USDC once the unwind completes
    ///                         — the proposer's own bound on the realised total, over and above the
    ///                         per-swap `maxSlippageBps` floors.
    function flatten(uint256 minRewardUsdcOut, uint256 minIdleUsdcOut) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.flattenImpl(minRewardUsdcOut, minIdleUsdcOut);
    }

    /// @notice Execute the owner-staged venue rewrite. PROPOSER ONLY, and only when `p` byte-matches
    ///         the staged hash AND the book is flat (no CL position, no hedged basis, no live debt
    ///         on either current leg market — flatten first). Re-runs the full init-grade venue
    ///         validation against `p` (venue identity, swap-pool probes, gauge↔pool binding, leg /
    ///         feed decimals, width band, CF/LTV/health invariants, shape re-derivation), rewrites
    ///         the venue subset of storage, and consumes the staged hash. Share-ledger continuity is
    ///         structural: on a flat book NAV is the idle USDC balance, which no venue field
    ///         touches, so the vault, share balances, HWM, and pending redeem requests are
    ///         unaffected. Old-leg dust becomes rescuable via `rescueToVault` (its deny-list reads
    ///         the LIVE legs).
    /// @param p The full destination venue config; must hash to the staged commitment.
    function migrateVenue(LeveragedAeroVenue.VenueParams calldata p) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.migrateImpl(p);
    }

    /// @notice Open a FRESH position from a flat `Executed` book, deploying the entire idle USDC
    ///         balance — the re-entry after a `flatten` (with or without an intervening
    ///         `migrateVenue`). Runs `executeImpl`'s exact genesis sequence via
    ///         `LeveragedAeroVenue.redeployImpl`; reverts `PositionAlreadyOpen` when a position is
    ///         live (top-ups go through `deployIdle`, which conversely cannot mint from flat).
    ///
    ///         CLEARS ANY STAGED VENUE HASH — re-entering the current venue is the documented rollback
    ///         of an aborted migration, and an authorization that survived it could be fired later
    ///         into unevaluated conditions. Re-stage (owner) if the migration is still intended.
    /// @param minLiquidity Minimum CL liquidity the fresh mint must produce. Required here and not on
    ///                     `execute` because this path is repeatable and runs against live depositors;
    ///                     the mint's own §8 mins come off the same `slot0()` it executes at.
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
        // Gauge + tokenId + reward feed: the gauge-reward NAV term (`LeveragedAeroValuation._rewardUsdc`),
        // which prices BOTH the claimed-but-unsold balance and the still-unclaimed `gauge.earned()` on the
        // staked NFT. Threaded from the SAME storage `LeveragedAeroVenue.applyVenue` rewrites on a
        // migration and `_sellRewardBalance` prices its sale floor against — never a second pinned copy a
        // migration could orphan. `tokenId` is the flat-book signal too: 0 ⇒ no `earned()` call at all.
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
    }
}
