// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeveragedAeroManager} from "./LeveragedAeroManager.sol";
import {IMoonwellMarket} from "./sherwood/interfaces/IMoonwellMarket.sol";
import {ICLFactory, ICLGauge, ICLPool} from "./sherwood/interfaces/ISlipstream.sol";
import {TickMath} from "./sherwood/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
    error WidthOutOfBounds();
    error TargetLtvExceedsMax();
    error MinHealthTooLow(); // minHealthBps < 10500 (1.05x floor)
    error MaxLtvExceedsCF(); // maxLtvBps >= Moonwell USDC collateral factor
    error MinHealthMaxLtvConflict();
    error ComptrollerCallFailed();
    error VenueNotStaged(); // migrate without a staged hash, or params that do not match it
    error BookNotFlat(); // migrate while a CL position, hedged basis, or leg debt is still live
    error PositionAlreadyOpen(); // redeploy on a book that already has a CL position (use deployIdle)

    // ── Events (emitted from the strategy's address via delegatecall) ──
    /// @notice A destination venue hash was staged (or cleared, when `venueHash == 0`) by the vault owner.
    event VenueStaged(bytes32 venueHash);
    /// @notice The whole book was unwound to idle USDC without settling (strategy stays Executed).
    event Flattened(uint256 idleUsdc);
    /// @notice The staged venue rewrite executed on a flat book.
    event VenueMigrated(address indexed oldPool, address indexed newPool);

    /// @notice The venue subset of the strategy's config — everything a pool/pair change touches.
    ///         Field semantics are LEG SLOTS exactly as in `InitParams` (names historical): `weth*`
    ///         is leg A (the natively-wrappable, always-borrowed slot), `cbBTC*` is leg B (the slot
    ///         that may be the unit of account — that IS asset-mode). The non-migratable core (usdc,
    ///         mUsdc, comptroller, npm, swapRouter, usdcFeed, sequencerFeed, aeroUsdFeed, oracle/calm
    ///         params, maxSlippageBps, fee params) is read from live storage, never from here.
    struct VenueParams {
        address mCbBTC; // Moonwell market for leg B (must be mUsdc in asset-mode)
        address mWeth; // Moonwell market for leg A
        address cbBTC; // leg B underlying (== usdc selects asset-mode)
        address weth; // leg A underlying
        address pool; // Aerodrome Slipstream CL pool for the leg A/B pair
        address gauge; // Gauge for the pool (AERO rewards); must report `pool()` == pool
        address cbBTCFeed; // leg B/USD aggregator (must be the USDC/USD feed in asset-mode)
        address wethFeed; // leg A/USD aggregator
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
    function flattenImpl() public {
        LeveragedAeroManager.settleImpl();
        Layout storage $ = _layout();
        // Same pathological-case belt as `_settle`: repays drive the bases to 0 through `_repay`'s
        // clamp except when residual debt could not be covered at all — zero them explicitly so a
        // flat book never carries a stale hedge basis into the next venue.
        $.hedgedDebtA = 0;
        $.hedgedDebtB = 0;
        emit Flattened(IERC20($.usdc).balanceOf(address(this)));
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
    ///      inside the mint (no caller min-out, exactly like `execute`).
    function redeployImpl() public {
        if (_layout().tokenId != 0) revert PositionAlreadyOpen();
        LeveragedAeroManager.executeImpl();
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
        // The leg↔USDC swap pools are separate venues from the LP pool — probe them so a typo'd
        // spacing can't route every swap at a nonexistent pool on a live levered book.
        address clFactory = ICLPool(p.pool).factory();
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
        if (ICLGauge(p.gauge).pool() != p.pool) revert VenueMismatch();

        // Reject legs that break an accounting invariant (see `_initialize`'s original block).
        address rewardTok = ICLGauge(p.gauge).rewardToken();
        if (p.weth == usdc || p.weth == rewardTok || p.cbBTC == rewardTok) {
            revert UnsupportedLeg();
        }
        // `compoundImpl`'s oracle floor hardcodes an 18dp reward token against an 8dp feed.
        if (IERC20Metadata(rewardTok).decimals() != 18) revert UnexpectedFeedDecimals();

        // Leg decimals drive every token↔USDC conversion — read them, never assume.
        uint8 cbDec = IERC20Metadata(p.cbBTC).decimals();
        uint8 wethDec = IERC20Metadata(p.weth).decimals();
        if (cbDec < 2 || cbDec > 18 || wethDec < 2 || wethDec > 18) revert LegDecimalsOutOfRange();

        // Rerange width band: on the tickSpacing grid, floor spans ≥ two spacings, ceiling inside
        // the tick domain (see `_initialize`'s original block for the int24-wrap rationale).
        if (p.tickSpacing <= 0) revert WidthOutOfBounds();
        uint24 spacing = uint24(p.tickSpacing);
        if (p.minWidth % spacing != 0 || p.maxWidth % spacing != 0) revert WidthOutOfBounds();
        if (uint256(p.minWidth) < 2 * uint256(spacing)) revert WidthOutOfBounds();
        if (p.minWidth > p.maxWidth) revert WidthOutOfBounds();
        if (uint256(p.maxWidth) > 2 * uint256(uint24(TickMath.MAX_TICK))) revert WidthOutOfBounds();
        if (p.width % spacing != 0 || p.width < p.minWidth || p.width > p.maxWidth) revert WidthOutOfBounds();

        // Risk invariants against the LIVE collateral factor (re-read here — fresher than init's).
        uint16 cfBps = _readCollateralFactor($.comptroller, mUsdc);
        if (p.targetLtvBps > p.maxLtvBps) revert TargetLtvExceedsMax();
        if (p.minHealthBps < 10500) revert MinHealthTooLow();
        if (p.maxLtvBps >= cfBps) revert MaxLtvExceedsCF();
        // L4: the permissionless-deleverage trigger LTV must sit strictly above maxLtvBps.
        if (uint256(p.minHealthBps) * uint256(p.maxLtvBps) >= 1e8) revert MinHealthMaxLtvConflict();

        // ── Persist the venue subset (every field a pool/pair change touches, nothing else) ──
        $.mCbBTC = p.mCbBTC;
        $.mWeth = p.mWeth;
        $.cbBTC = p.cbBTC;
        $.weth = p.weth;
        $.pool = p.pool;
        $.gauge = p.gauge;
        $.cbBTCFeed = p.cbBTCFeed;
        $.wethFeed = p.wethFeed;
        $.tickSpacing = p.tickSpacing;
        $.cbBTCSwapTickSpacing = p.cbBTCSwapTickSpacing;
        $.wethSwapTickSpacing = p.wethSwapTickSpacing;
        $.wethDeliversNative = p.wethDeliversNative;
        $.width = p.width;
        $.minWidth = p.minWidth;
        $.maxWidth = p.maxWidth;
        $.targetLtvBps = p.targetLtvBps;
        $.maxLtvBps = p.maxLtvBps;
        $.minHealthBps = p.minHealthBps;
        $.usdcCollateralFactorBps = cfBps;
        $.cbBTCDecimals = cbDec;
        $.wethDecimals = wethDec;
        $.wethIsToken0 = wethIsToken0_;
        $.legBIsAsset = legBIsAsset_;
    }

    /// @dev USDC collateral factor (bps) from `Comptroller.markets(mUsdc)` — verbatim the strategy's
    ///      original `_readCollateralFactor` (moved here with the venue block; init was its only caller).
    function _readCollateralFactor(address comptroller_, address mUsdc_) private view returns (uint16 cfBps) {
        (bool ok, bytes memory ret) = comptroller_.staticcall(abi.encodeWithSignature("markets(address)", mUsdc_));
        if (!ok || ret.length < 64) revert ComptrollerCallFailed();
        uint256 cfMantissa;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            cfMantissa := mload(add(ret, 0x40))
        }
        cfBps = uint16(cfMantissa / 1e14); // 0.88e18 / 1e14 = 8800
        if (cfBps == 0) revert ComptrollerCallFailed();
    }
}
