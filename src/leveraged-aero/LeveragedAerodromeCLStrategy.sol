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
import {FeeConstants} from "./sherwood/FeeConstants.sol";
import {Position} from "./sherwood/interfaces/IPriceRouter.sol";
import {IProtocolConfig} from "./sherwood/interfaces/IProtocolConfig.sol";
import {ICLGauge, INonfungiblePositionManager} from "./sherwood/interfaces/ISlipstream.sol";
import {IStrategy} from "./sherwood/interfaces/IStrategy.sol";
import {ISyndicateFactory} from "./sherwood/interfaces/ISyndicateFactory.sol";
import {ISyndicateVault} from "./sherwood/interfaces/ISyndicateVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    error InsufficientAssetsOut();
    error InsufficientLiquidity();
    error InsufficientIdle();
    error HealthyNoDeleverage();
    error CannotRescuePositionToken();
    error NotProposerOrOwner();
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
    error WidthOutOfBounds(); // rerange width off the tickSpacing grid or outside [minWidth, maxWidth]
    error ZeroShares(); // deposit would mint 0 shares (dust assets against a large book) — pay-for-nothing
    error NotVaultOwner(); // stageVenue caller is not the vault's owner (the venue-selection authority)
    // A lever-down that would repay the ENTIRE debt is rejected — it would orphan the staked position
    // NFT. Declared once in the manager (same selector); re-declared here so it is on the strategy's
    // public ABI for the rebalancer, exactly as `InsufficientIdleForLeverUp` is. Use `flatten()`.
    error FullUnwindNotSupported();

    // ── Constants ──
    /// @dev Position `kind` tag for the PriceRouter adapter registry.
    bytes32 public constant POSITION_KIND = keccak256("LEVERAGED_AERO_CL");

    /// @dev ERC-4626 virtual share offset matching the vault's `_decimalsOffset()` (USDC 6dp → 1e6).
    uint256 private constant SHARES_VIRTUAL_OFFSET = 1e6;

    /// @dev Annual management-fee ceiling (bps); mirrors `SyndicateFactory.MAX_MANAGEMENT_FEE_BPS` (5%/yr).
    uint16 private constant MAX_MANAGEMENT_FEE_BPS = 500;

    /// @dev Deadman window: after this elapses on an unfulfilled `requestRedeem`, its owner can
    ///      `emergencyRedeem` trustlessly (oracle-free). The backend fulfills in minutes; 2 days
    ///      tolerates a weekend outage while keeping the trustless exit reachable.
    uint256 private constant FULFILL_WINDOW = 2 days;

    // ── Async-redeem queue events ──
    event RedeemRequested(uint256 indexed id, address indexed owner, uint256 shares);
    event RedeemFulfilled(uint256 indexed id, address indexed owner, uint256 assetsOut);
    event RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares);
    event RedeemEmergency(uint256 indexed id, address indexed owner, uint256 assetsOut);

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
        uint24 width; // initial full range width in ticks (rerange spans width/2 each side)
        uint24 minWidth; // lower bound for a proposer-supplied rerange width
        uint24 maxWidth; // upper bound for a proposer-supplied rerange width
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
        uint24 width; // current full range width in ticks (rerange spans width/2 each side)
        uint24 minWidth; // lower bound for a proposer-supplied rerange width
        uint24 maxWidth; // upper bound for a proposer-supplied rerange width
        // ── appended for the config-emergent pool shape (keep byte-identical) ──
        bool legBIsAsset; // DERIVED at init: leg-B slot == usdc → asset-as-a-leg shape (packs above)
        // ── appended for the borrow-interest hedge (keep byte-identical) ──
        uint128 hedgedDebtA; // leg-A borrowed PRINCIPAL the LP hedges (packs with the widths above)
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
        uint128 hedgedDebtA;
        uint128 hedgedDebtB;
        bytes32 stagedVenueHash;
    }

    /// @notice Full strategy storage layout (single accessor for tests / off-chain reads), minus the
    ///         `redeemRequests` mapping (queried via `redeemRequest(id)`). Field-by-field (not a
    ///         struct-literal) so the Yul IR emits one sload→mstore per field — avoids the
    ///         >16-live-variable overflow a struct-literal trips under via_ir.
    function layout() external view returns (LayoutView memory v) {
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
        v.hedgedDebtA = $.hedgedDebtA;
        v.hedgedDebtB = $.hedgedDebtB;
        v.stagedVenueHash = $.stagedVenueHash;
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

    /// @notice A single escrowed async-redeem request by id (queue introspection for tests / UI).
    function redeemRequest(uint256 id) external view returns (RedeemRequest memory) {
        return _layout().redeemRequests[id];
    }

    /// @notice The fund's STANDING target LTV in bps — set at init and re-set by every `adjustLeverage`.
    ///         This is what `execute` / `deployIdle` / `compound` size their borrow at, so it is the value
    ///         a rebalancer needs before deciding whether to retarget. Exposed as its own selector purely
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
        LeveragedAeroVenue.applyVenue(_venueParamsOf(p));

        // L3 (+L5): bound the oracle / calm-gate params so a misconfig can't silently disable a guard.
        // Bounds admit the confirmed config yet block degenerate values:
        //   maxDelay           ∈ (0, 7 days] — a huge value disables staleness detection
        //   gracePeriod        ∈ [0, 1 days] — sequencer-restart grace
        //   twapWindow         ∈ (0, 1 days] — 0 disables the TWAP / calm-gate
        //   calmDeviationTicks ∈ (0, 5000]   — a huge value disables the calm-gate
        //   maxSlippageBps     ∈ (0, 1000]   — 0 or huge disables swap-slippage protection (10% cap)
        if (p.maxDelay == 0 || p.maxDelay > 7 days) revert OracleParamOutOfRange();
        if (p.gracePeriod > 1 days) revert OracleParamOutOfRange();
        if (p.twapWindow == 0 || p.twapWindow > 1 days) revert OracleParamOutOfRange();
        if (p.calmDeviationTicks == 0 || p.calmDeviationTicks > 5000) revert OracleParamOutOfRange();
        if (p.maxSlippageBps == 0 || p.maxSlippageBps > 1000) revert OracleParamOutOfRange();
        if ((p.managementFeeBps != 0 || p.performanceFeeBps != 0) && p.feeRecipient == address(0)) {
            revert FeeRecipientRequired();
        }
        // M3: hard ceilings on both fee rates (perf mirrors the protocol-wide cap; mgmt the factory's).
        if (p.performanceFeeBps > FeeConstants.MAX_PERFORMANCE_FEE_BPS) revert PerformanceFeeTooHigh();
        if (p.managementFeeBps > MAX_MANAGEMENT_FEE_BPS) revert ManagementFeeTooHigh();

        // Non-migratable core stores (the venue subset — legs, markets, pool, gauge, feeds,
        // spacings, widths, LTV band, derived decimals/ordering/shape — was persisted inside
        // `applyVenue` above; usdc / mUsdc / usdcFeed / comptroller were stored ahead of it).
        $.npm = p.npm;
        $.swapRouter = p.swapRouter;
        $.sequencerFeed = p.sequencerFeed;
        $.maxDelay = p.maxDelay;
        $.gracePeriod = p.gracePeriod;
        $.calmDeviationTicks = p.calmDeviationTicks;
        $.twapWindow = p.twapWindow;
        $.maxSlippageBps = p.maxSlippageBps;
        $.managementFeeBps = p.managementFeeBps;
        $.performanceFeeBps = p.performanceFeeBps;
        $.feeRecipient = p.feeRecipient;
        $.lastFeeAccrualTimestamp = block.timestamp;
        // tokenId / posTickLower / posTickUpper / hwmPerShare default to 0 (set in _execute / on first deposit).
    }

    /// @dev Width band check shared by `_initialize` (the genesis width) and `rerange` (each
    ///      per-cycle width): on the tickSpacing grid and inside `[minWidth_, maxWidth_]`. The band
    ///      itself is validated once at init (multiples, `minWidth_ >= 2 × spacing`, min ≤ max).
    function _checkWidth(uint24 width_, int24 tickSpacing_, uint24 minWidth_, uint24 maxWidth_) private pure {
        if (tickSpacing_ <= 0) revert WidthOutOfBounds();
        if (width_ % uint24(tickSpacing_) != 0) revert WidthOutOfBounds();
        if (width_ < minWidth_ || width_ > maxWidth_) revert WidthOutOfBounds();
    }

    /// @dev The venue subset of `InitParams`, marshalled for `LeveragedAeroVenue.applyVenue` (one
    ///      shared validation + store path for init and `migrateVenue`). Field-by-field so the Yul
    ///      IR streams memory copies instead of holding a wide struct-literal live.
    function _venueParamsOf(InitParams memory p) private pure returns (LeveragedAeroVenue.VenueParams memory v) {
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
    }

    // ── NAV ──

    /// @notice Oracle NAV of the levered book, in USDC (6dp), NET of the accrued protocol-fee
    ///         liability (`protocolFeeOwed`). `tokenId == 0` (the flat-book invariant, maintained by
    ///         `_execute`/`_settle`) → face value of strategy-controlled idle USDC only (vault float
    ///         excluded — M2 deposit/redeem symmetry), no oracle. Active position →
    ///         `LeveragedAeroValuation.netEquityUsdc` (oracle-implied sqrtP, fail-closed: reverts on
    ///         any oracle/calm failure or ≤0 equity). `protocolFeeOwed` is subtracted here (floored at
    ///         0, never reverts on owed > gross) — this is the fairness mechanism that replaces
    ///         share-dilution: deposit share-pricing + the next HWM basis both see the net NAV.
    function nav() public view virtual returns (uint256) {
        Layout storage $ = _layout();
        uint256 gross;
        if ($.tokenId == 0) {
            // Flat book: strategy-controlled idle USDC only (face, 6dp, no oracle). Vault float is
            // excluded — `strategy.redeem` never pays it out, so counting it here would re-introduce
            // the M2 deposit/redeem asymmetry the active-position branch already avoids.
            gross = IERC20($.usdc).balanceOf(address(this));
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
        LeveragedAeroManager.executeImpl();
        // Belt-and-suspenders: keep the fee-accrual clock running even if a clone bypassed
        // _initialize (guards against a ~54-year dt on the first crystallize).
        if (_layout().lastFeeAccrualTimestamp == 0) _layout().lastFeeAccrualTimestamp = block.timestamp;
    }

    /// @notice Full proportional unwind to the vault. The unwind — remove 100% liquidity, repay both
    ///         Moonwell borrows (self-funding any IL/fee shortfall), redeem collateral, sweep residual
    ///         cbBTC/WETH → USDC, clear state — lives in `LeveragedAeroManager.settleImpl()`; the
    ///         realized USDC is pushed to the vault here (the manager never touches `vault()`).
    function _settle() internal override {
        LeveragedAeroManager.settleImpl();
        // Discharge the accrued protocol fee from realized USDC BEFORE pushing the rest to the
        // vault. Pays `min(owed, balance)` to the live recipient; skips silently when recipient == 0
        // or owed == 0 (liability persists until a recipient exists — see edge note on `redeem`).
        Layout storage $ = _layout();
        // Flat-book invariant, completed here: `settleImpl` clears `tokenId`/ticks and its repays drive
        // both hedged-principal bases to 0 through `_repay`'s clamp — EXCEPT in the pathological case
        // where residual debt could not be covered at all, where no repay runs and the basis would
        // survive a book that no longer exists. Zeroed in THIS frame (not in the manager) because it
        // already holds `_layout()` for the fee discharge below, so the two `sstore`s cost ~20 bytes here
        // versus ~70 in the manager, which is at the EIP-170 cap — the same relocation `adjustLeverage`'s
        // target-LTV write already makes.
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
        IERC20(_layout().usdc).safeTransferFrom(msg.sender, address(this), assets);
        address vault_ = vault();
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

    /// @notice Deploy `amount` of idle strategy USDC into the levered position (supply + borrow +
    ///         increaseLiquidity + health-assert) via `LeveragedAeroManager.deployIdleImpl()`.
    /// @param amount       USDC to deploy (6dp); must be ≤ idle USDC held.
    /// @param minLiquidity Minimum liquidity to accept (slippage guard).
    function deployIdle(uint256 amount, uint256 minLiquidity) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroManager.deployIdleImpl(amount, minLiquidity);
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

    /// @notice Recenter the CL position on the current pool tick WITHOUT swapping, via
    ///         `LeveragedAeroManager.rerangeImpl()`. The calm-gate runs FIRST, so a recenter can never
    ///         execute at a manipulated tick. No swap → principal conserved (IL is realized only on a
    ///         true exit); the collected ratio can't match the new range, so a remainder of ONE
    ///         borrowed leg is left idle — `nav()` prices it, so the recenter is NAV-neutral and the
    ///         remainder stays redeployable. Debt + collateral are untouched (health preserved); a new
    ///         tokenId is minted (Slipstream ticks are immutable), the old empty NFT is harmless dust.
    ///
    ///         NO fee crystallisation: rerange changes neither supply nor NAV, so the streaming fee is
    ///         deferred to the next crystallize point (not lost) and the HWM is unaffected.
    /// @param width_  Full range width in ticks for this cycle (span = `width_/2` each side of the
    ///                calm tick). Must sit on the tickSpacing grid inside `[minWidth, maxWidth]`;
    ///                persisted as the new `width` so `nav()`/subsequent mints see it — including on
    ///                a FLAT book, where the recenter itself is a no-op but the width still takes
    ///                effect for the next `deployIdle` / `compound` mint. Centring is grid-approximate:
    ///                both bounds round DOWN onto the spacing grid, so the realised range sits off the
    ///                calm tick by up to one spacing (largest when `width_ / tickSpacing` is odd).
    /// @param minLiq0 Minimum token0 the re-add must consume (two-sided slippage guard).
    /// @param minLiq1 Minimum token1 the re-add must consume (two-sided slippage guard).
    function rerange(uint24 width_, uint256 minLiq0, uint256 minLiq1) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        Layout storage $ = _layout();
        _checkWidth(width_, $.tickSpacing, $.minWidth, $.maxWidth);
        LeveragedAeroManager.rerangeImpl(width_, minLiq0, minLiq1);
    }

    /// @notice Retarget the position's LTV to `targetLtvBps_` (borrow/repay; no new USDC). Collateral
    ///         is untouched, so LTV moves on the debt side via `LeveragedAeroManager.adjustLeverageImpl`:
    ///         lever UP borrows the cbBTC/WETH delta and adds it (`minLiq`); lever DOWN unwinds the
    ///         matching CL fraction and repays (per-leg residual rebalanced through USDC, bounded by
    ///         `minOut`). Ends with `_assertHealthy`. `targetLtvBps_ ≤ maxLtvBps` is checked here.
    ///
    ///         ASSET-MODE (leg-B slot == usdc): a lever-UP borrows ONLY leg A and pairs it with USDC
    ///         drawn from the strategy's IDLE balance, sized closed-form so the LP's leg-A amount equals
    ///         the added leg-A debt — the delta-hedge is preserved (the alternative, swapping part of the
    ///         borrow to USDC, would leave the book net short). The drawn idle is value-conserving (it
    ///         moves from idle into the LP) but it shrinks the redeem cover budget until the next
    ///         deposit, so size lever-ups against available idle: an under-funded one reverts
    ///         `InsufficientIdleForLeverUp(needed, available)` and changes nothing.
    ///
    ///         NO fee crystallisation (like `rerange`): no supply change, no PnL realized; the
    ///         streaming fee is deferred and the HWM is unaffected.
    ///         PERSISTED, like `rerange`'s `width`: `targetLtvBps_` becomes the fund's STANDING target
    ///         (readable via `targetLtvBps()` / `layout().targetLtvBps`), not a one-shot per-call knob.
    ///         `execute` / `deployIdle` / `compound` size their borrow off the STORED target, so a
    ///         retarget that did not persist would be silently dragged back by the next redeploy —
    ///         the rebalancer would be fighting its own book.
    /// @param targetLtvBps_ Target LTV in bps (must be ≤ `maxLtvBps`). Persisted as the new standing
    ///                      target once that check passes; a rejected value stores nothing.
    /// @param minLiq        Minimum CL liquidity on a lever-UP add (slippage guard).
    /// @param minOut        Minimum USDC out of a lever-DOWN residual swap (slippage guard).
    function adjustLeverage(uint16 targetLtvBps_, uint256 minLiq, uint256 minOut) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        Layout storage $ = _layout();
        if (targetLtvBps_ > $.maxLtvBps) revert TargetLtvExceedsMax();
        // Persist the new standing target HERE, not in the manager: this frame already holds `$` for
        // the bound check above, so the write is ~20 bytes here versus ~71 in the manager library,
        // which sits at the EIP-170 cap. Semantics are unchanged — the write is in the same
        // transaction as the venue work (a later revert rolls it back), it happens only after the
        // `maxLtvBps` check, and it lands even when the retarget is a venue no-op
        // (`targetDebt == debtUsdc`), which is the `rerange`-on-a-flat-book analogue. See the ordering
        // note in `LeveragedAeroManager.adjustLeverageImpl`.
        $.targetLtvBps = targetLtvBps_;
        LeveragedAeroManager.adjustLeverageImpl(targetLtvBps_, minLiq, minOut);
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
        LeveragedAeroManager.fastRedeemImpl(assetsOut, idleShare);

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
    ///         executed at the same `block.timestamp`*. A frontend passing it as `minAssetsOut` should
    ///         still apply a small slippage tolerance: the streaming management fee accrues with `dt`, so
    ///         a redeem landing a few blocks later pays marginally LESS than this quote (and the NAV may
    ///         drift), which would otherwise bounce an exact-quote `minAssetsOut`.
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
        uint256 supply = IERC20(vault()).totalSupply();
        if (supply == 0) return (0, false);
        uint256 navPre;
        try this.nav() returns (uint256 n) {
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
        try this.simulateCrystallizeSelf(navPre, supply) returns (uint256 nn, uint256 sp) {
            navNet = nn;
            supplyPost = sp;
        } catch {
            return (0, false);
        }
        assetsOut = Math.mulDiv(shares, navNet, supplyPost);
        // Mirror `redeem`'s `ZeroAssetsOut` guard: never quote a payout the executed path would revert on.
        if (assetsOut == 0) return (0, false);
        // Idle-first (mirror `fastRedeemImpl`): the redeemer's `f×idle` share funds part of `assetsOut`,
        // so the LTV gate only sees the collateral-funded remainder.
        uint256 idleShare = Math.mulDiv(IERC20(_layout().usdc).balanceOf(address(this)), shares, supplyPost);
        uint256 fromCollateral = assetsOut > idleShare ? assetsOut - idleShare : 0;
        if (fromCollateral == 0) return (assetsOut, true); // idle alone covers it — no LTV constraint
        // Predict the LTV gate on the same pre-withdraw basis as `fastRedeemImpl`.
        try this.previewCollateralDebt() returns (uint256 collateralUsdc, uint256 debtUsdc) {
            if (fromCollateral >= collateralUsdc) return (assetsOut, false);
            uint256 maxLtv = uint256(_layout().maxLtvBps);
            fastOk = debtUsdc == 0 || (debtUsdc * 10_000) / (collateralUsdc - fromCollateral) <= maxLtv;
        } catch {
            return (assetsOut, false); // collateral/debt oracle read failed → advise the async path
        }
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
    ///         look-back option. The backend deleverages (via `adjustLeverage`) then `fulfillRedeem`s.
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
    ///         backend deleverages first (`adjustLeverage`) so the unwind's IL self-funds, then fulfills
    ///         paying `request.owner`. NOT owner-callable — an owner-callable fulfill would resurrect
    ///         the demoted oracle-free path through the side door.
    /// @param id Request id to fulfill.
    function fulfillRedeem(uint256 id) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        Layout storage $ = _layout();
        RedeemRequest storage r = $.redeemRequests[id];
        if (r.settled) revert RequestSettled();
        uint256 assetsOut = _proportionalRedeem(r.owner, r.shares, r.minAssetsOut);
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

    /// @notice Sweep a STRAY ERC-20 (airdrop / accidental send) back to the vault. Callable by the
    ///         proposer OR the vault owner (§8) — the owner leg is what keeps the sweep reachable
    ///         through a dead proposer key. Target is always `vault()`, never caller-supplied, so
    ///         neither caller picks the destination (§13); onward recovery is the vault's own
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
    ///           bypass `compound()`. Once `Settled` that reason is gone — `compound` reverts
    ///           `NotExecuted` and the unwind's `gauge.withdraw` auto-claims a final AERO tranche
    ///           that `settleImpl` never sells — so post-settle it IS a stray and sweeping it to the
    ///           vault (where the owner's non-asset `rescueERC20` applies) is the only recovery.
    ///
    ///         The position NFT is never swept (no ERC-721 path).
    function rescueToVault(address token) external nonReentrant {
        if (msg.sender != proposer() && msg.sender != Ownable(vault()).owner()) revert NotProposerOrOwner();
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
    ///         whole book rather than understating it for the length of the flat window.
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
    function redeploy() external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroVenue.redeployImpl();
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
        c.cbBTCFeed = $.cbBTCFeed;
        c.wethFeed = $.wethFeed;
        c.usdcFeed = $.usdcFeed;
        c.sequencerFeed = $.sequencerFeed;
        c.maxDelay = $.maxDelay;
        c.gracePeriod = $.gracePeriod;
        c.calmDeviationTicks = $.calmDeviationTicks;
        c.twapWindow = $.twapWindow;
    }
}
