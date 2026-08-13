// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";

import {LPGeometryLib} from "@libraries/LPGeometryLib.sol";
import {LPPositionLib} from "@libraries/LPPositionLib.sol";
import {LPValuationLib} from "@libraries/LPValuationLib.sol";
import {SwapWindowLib} from "@libraries/SwapWindowLib.sol";

/// @dev Minimal view surface of LPCompoundModule needed for the EIP-1271 passthrough.
interface ILPCompoundModuleRebalance {
    function validateRebalanceOrder(bytes32 orderDigest, bytes calldata encodedOrder) external view returns (bytes4);
}

/// @title LPAutoBalancerV2
/// @notice Safe-governed, dual-position (balanced `main` + single-sided `alt`) Aerodrome CL
///         rebalancer. Holds position NFTs, re-ranges them with on-chain-computed ticks without
///         swapping principal, stakes for AERO emissions, and skims fees/emissions to the weekly
///         drop. See docs/superpowers/specs/2026-06-17-lp-auto-balancer-v2-dual-position-design.md
///         and docs/superpowers/specs/2026-07-02-lp-auto-balancer-v2-swap-rebalance-design.md
contract LPAutoBalancerV2 is AccessControlEnumerable, ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;
    using SwapWindowLib for SwapWindowLib.SwapWindow;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_LOSS_CAP_BPS = 500;

    /// @notice Caps the per-call compound percentage; also guards `BPS_DENOMINATOR - compoundBps`
    ///         from underflow. Equals BPS_DENOMINATOR (100%).
    uint16 public constant MAX_COMPOUND_BPS = 10_000;

    /// @notice Minimum USD value of the surplus leg required to mint the single-sided alt.
    ///         Scale is 8-decimal USD (Chainlink convention), the same scale `LPValuationLib.valueInUsd`
    ///         returns. Below this the leftover is treated as dust and forwarded to the
    ///         feeCollector instead — a sub-tick remainder too small to seed a position would
    ///         revert the mint or round to zero liquidity. MUST be a USD threshold, never raw
    ///         base units: the phase-1 pair is WETH (18-dec) / cbBTC (8-dec), so a flat raw
    ///         threshold means wildly different USD amounts per leg. 1e6 = $0.01.
    ///
    ///         ORDERING: MIN_ALT_VALUE_USD >= MIN_MAIN_LEG_USD (asserted in the unit suite). This was
    ///         originally a SAFETY invariant, and no longer is — the hazard it existed to block was
    ///         removed when `mintAlt` stopped anchoring the alt to the MAIN range's bounds and started
    ///         anchoring it to `floorAlign(spotTick)`. Under the old anchoring, a single-sided main
    ///         sitting one spacing off spot could place the opposite-side alt straddling spot: an
    ///         in-range two-sided "single-sided" mint whose in-range leg's min is forced to 0, hence
    ///         sandwichable. Spot anchoring makes that unreachable by construction — a token0 alt is
    ///         `[floor + spacing, floor + 2*spacing]`, whose tickLower is strictly above spot, and a
    ///         token1 alt is `[floor - spacing, floor]`, whose tickUpper is at or below spot. Neither
    ///         can contain spot, whatever the main did. See `LPPositionLib.mintAlt`.
    ///
    ///         What the ordering buys NOW is only a dust-vs-deploy choice: it keeps any leg too small
    ///         to seed a main from also being seeded as an alt, so sub-threshold remainders take one
    ///         consistent path (forwarded as dust) rather than two. The unit assertion is retained as
    ///         a change-detector on that choice. It is no longer load-bearing for sandwich safety, so
    ///         do not treat it as a licence to skip re-deriving safety if `mintAlt`'s placement rule
    ///         changes again — the anchoring is what carries that property.
    uint256 public constant MIN_ALT_VALUE_USD = 1e6;

    /// @notice Minimum USD value (8-decimal scale) a minority leg must hold for the main to be built
    ///         as a spot-centered straddle. Below this, the minority leg is treated as dust: the main
    ///         is built SINGLE-SIDED on the majority leg instead of straddling. A near-zero minority
    ///         leg (e.g. 1 wei) would otherwise force the straddle branch and compute near-zero (or
    ///         zero, reverting) liquidity, dumping principal into the transient alt. Value-based, not
    ///         exact-zero, for the same per-leg-decimals reason as MIN_ALT_VALUE_USD. 1e6 = $0.01.
    uint256 public constant MIN_MAIN_LEG_USD = 1e6;

    INonfungiblePositionManager public immutable POSITION_MANAGER;
    address public immutable AERO;

    /// @notice Hard ceiling on either per-feed staleness bound. 1 day is ~72x the ~20-minute
    ///         heartbeat of the feeds this contract is built for (Base ETH/USD, BTC/USD), so it
    ///         leaves ample room for a slow or degraded feed while still rejecting a fat-fingered
    ///         value outright. Deliberately NOT the 7-day cap the sequencer grace period uses: a
    ///         staleness bound three orders of magnitude above the heartbeat is indistinguishable
    ///         from no bound at all, which is the substance of MOO-740.
    uint256 public constant MAX_ORACLE_DELAY = 1 days;

    /// @notice Constructor default for BOTH per-feed staleness bounds. 3x the ~20-minute heartbeat
    ///         of the feeds this contract is built for: tight enough that the value which SHIPS is
    ///         already a real bound, loose enough to ride out a couple of missed rounds.
    /// @dev    The value a deployment ships with is the value that protects it. A default sized for
    ///         "some feed, somewhere" (the old 26 hours) means a deployment whose setup proposal
    ///         forgets to tighten the bound is running with no meaningful staleness check at all —
    ///         and nothing on chain distinguishes that from a deliberate choice. Failing CLOSED is
    ///         cheap here: `registerPosition`/`setOracles` probe both feeds against these bounds, so
    ///         pairing this contract with a genuinely slower feed reverts in the admin transaction
    ///         rather than shipping a silent hole.
    uint256 public constant DEFAULT_MAX_ORACLE_DELAY = 1 hours;

    /// @notice Staleness bound for `position.oracle0` ONLY.
    /// @dev Per-feed, not shared. The two legs are different assets on different heartbeats — Base
    ///      cbBTC/USD and ETH/USD both publish on ~20-minute cadences — so a single bound sized for
    ///      the slowest feed accepts the fastest feed's answers many multiples past their own
    ///      validity. Both `_mainRange` and `_mintAlt` pick a SIDE from a value0-vs-value1
    ///      comparison, so one stale leg puts the position on the wrong side of the market.
    ///      Constructor seeds `DEFAULT_MAX_ORACLE_DELAY` for both; admins tighten each to its feed's
    ///      real heartbeat via `setMaxOracleDelays` (proposal 011 does this explicitly for the
    ///      phase-1 pair, and its `validate()` asserts the result).
    uint256 public maxOracleDelay0;

    /// @notice Staleness bound for `position.oracle1` ONLY. See `maxOracleDelay0`.
    uint256 public maxOracleDelay1;

    /// @notice Base sequencer uptime feed (Chainlink L2 uptime aggregator). `address(0)` disables
    ///         the check — every Chainlink read then trusts a report that may pre-date an outage.
    ///         Set it (with a grace period) on any L2 deployment.
    address public sequencerUptimeFeed;

    /// @notice Seconds the sequencer must have been continuously up before a feed read is accepted.
    ///         Only consulted when `sequencerUptimeFeed != address(0)`.
    uint256 public sequencerGracePeriod;

    struct ManagedPositionV2 {
        uint256 mainTokenId;
        uint256 altTokenId; // 0 when no alt this cycle
        address pool;
        address token0;
        address token1;
        int24 tickSpacing;
        address gauge;
        bool mainStaked;
        bool altStaked;
        address feeCollector;
        address oracle0;
        address oracle1;
        uint24 minWidth;
        uint24 maxWidth;
        uint24 maxCenterDeviation;
        uint32 twapWindow;
        int24 maxTickDeviation;
        uint16 maxRebalanceLossBps;
        uint256 minRebalanceInterval;
        uint256 lastRebalance;
        bool active;
    }

    ManagedPositionV2 public position;

    /// @notice LPCompoundModule sink for the compound share of harvested AERO. The module owns the
    ///         CowSwap orders + EIP-1271; set once by the Safe via `setCompoundModule`.
    address public compoundModule;

    /// @notice CowSwap settlement vault relayer (same constant as LPCompoundModule; duplicated to
    ///         avoid an external call from the balancer's hot paths).
    address public constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    /// @notice Cap on the extra rebalance-loss tolerance granted for the CowSwap round trip.
    uint16 public constant MAX_SWAP_LOSS_ALLOWANCE_BPS = 500;

    /// @notice The swap-rebalance in-flight window (see SwapWindowLib): open between
    ///         unwindForSwap() and rebuildAfterSwap()/exit(). All writes go through the library's
    ///         open/closeForRebuild/closeForExit — never direct field assignment (write discipline
    ///         documented on the library). Reads from views are fine.
    /// @dev    ABI NOTE: the old `rebalanceValueBefore()` / `rebalanceValueBeforePos()` /
    ///         `rebalanceLooseBefore()` USD getters are GONE, replaced by
    ///         `rebalanceAmountsBefore()`. They reported a USD figure frozen at unwind, which is
    ///         exactly the quantity the floor stopped using (see SwapWindowLib.Snapshot) — keeping
    ///         them would have meant re-deriving a number the contract no longer relies on, at a
    ///         cost the balancer's EIP-170 budget could not absorb. Off-chain consumers should read
    ///         the amounts and price them themselves.
    SwapWindowLib.SwapWindow private _window;

    /// @notice True between unwindForSwap() and rebuildAfterSwap()/exit(); gates rebalance-order validation.
    function rebalanceInFlight() external view returns (bool) {
        return _window.inFlight;
    }

    /// @notice Raw token AMOUNTS snapshotted at unwind: main+alt principal, and the pre-existing
    ///         loose balance. These are what the window actually stores and what the rebuild floor
    ///         re-prices — see SwapWindowLib.Snapshot for why the baseline is amounts, not USD.
    function rebalanceAmountsBefore()
        external
        view
        returns (uint256 amount0Pos, uint256 amount1Pos, uint256 loose0, uint256 loose1)
    {
        return (_window.amount0Pos, _window.amount1Pos, _window.loose0, _window.loose1);
    }

    /// @notice Timestamp of the last unwindForSwap() (diagnostics + snapshot field).
    function rebalanceStartedAt() external view returns (uint256) {
        return _window.startedAt;
    }

    /// @notice Token approved to VAULT_RELAYER during the in-flight window (revoked at rebuild/exit).
    function sellTokenInFlight() external view returns (address) {
        return _window.sellToken;
    }

    /// @notice Whether the main position was staked at unwind time (restake at rebuild).
    function rebalanceWasStaked() external view returns (bool) {
        return _window.wasStaked;
    }

    /// @notice Extra floor tolerance (bps) added to maxRebalanceLossBps for the swap round trip.
    uint16 public swapLossAllowanceBps;

    error ZeroAddress();
    error TwapDeviation();
    error StaleOracle();
    /// @dev Redeclared from LPValuationLib so they appear in this contract's ABI (an error's
    ///      selector depends only on its signature, so the library's reverts match these).
    error SequencerDown();
    error SequencerGracePeriod();
    error LossCapExceeded();
    error InvalidWidth();
    error WidthTooNarrow();
    error GaugeRewardMismatch();
    error PoolMismatch();
    error OracleRequired();
    error InvalidConfig();
    error NotActive();
    error NotHeld();
    error PositionStaked();
    error NoGauge();
    error AlreadyStaked();
    error NotStaked();
    error Cooldown();
    error WidthOutOfBounds();
    error CenterDeviation();
    error ValueFloor();
    error AlreadyRegistered();
    error NotEmpty();
    error CompoundBpsTooHigh();
    error NothingToCompound();
    error ModuleNotSet();
    error NotInFlight();
    error AlreadyInFlight();
    error InvalidSellToken();
    error SwapLossAllowanceTooHigh();
    /// @dev The range the contract computed differs from the one the caller committed to in
    ///      RebuildParams — spot moved (or was moved) between decision and execution.
    error TickMismatch();
    /// @dev Only the position manager may push an NFT onto this contract.
    error NotPositionManager();
    /// @dev `recoverETH` recipient rejected the transfer.
    error EthTransferFailed();

    event PositionRegistered(address indexed pool, uint256 indexed tokenId);
    event PoolChanged(address indexed pool, uint256 indexed mainTokenId);
    event PositionDeregistered(address indexed to);
    event PositionWithdrawn(address indexed to);
    event PositionConfigUpdated();
    event FeeCollectorUpdated(address feeCollector);
    event OraclesUpdated(address oracle0, address oracle1);
    event GaugeUpdated(address gauge);
    event MaxOracleDelaysUpdated(uint256 delay0, uint256 delay1);
    event SequencerUptimeFeedUpdated(address feed, uint256 gracePeriod);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event Staked(uint256 indexed tokenId, address gauge);
    event Unstaked(uint256 indexed tokenId, address gauge);
    event EmissionsClaimed(uint256 amount);
    event CompoundModuleUpdated(address module);
    event CompoundInitiated(uint256 compoundAmount, uint256 droppedAmount, uint16 compoundBps);
    event FeesSkimmed(uint256 amount0, uint256 amount1);
    event RebalancedUsingAlt(uint256 mainTokenId, uint256 altTokenId, int24 tickLower, int24 tickUpper);
    event RebalanceUnwound(address sellToken, uint256 sellAmount);
    event RebalanceRebuilt(uint256 mainTokenId, uint256 altTokenId);
    event SwapLossAllowanceUpdated(uint256 oldBps, uint256 newBps);

    constructor(
        address admin_,
        address manager_,
        address rebalancer_,
        address guardian_,
        address positionManager_,
        address aero_
    ) {
        if (admin_ == address(0) || positionManager_ == address(0) || aero_ == address(0)) {
            revert ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        if (manager_ != address(0)) _grantRole(MANAGER_ROLE, manager_);
        if (rebalancer_ != address(0)) _grantRole(REBALANCER_ROLE, rebalancer_);
        if (guardian_ != address(0)) _grantRole(GUARDIAN_ROLE, guardian_);

        POSITION_MANAGER = INonfungiblePositionManager(positionManager_);
        AERO = aero_;
        maxOracleDelay0 = DEFAULT_MAX_ORACLE_DELAY;
        maxOracleDelay1 = DEFAULT_MAX_ORACLE_DELAY;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(POSITION_MANAGER)) revert NotPositionManager();
        return this.onERC721Received.selector;
    }

    /// @notice Accept native ETH.
    /// @dev REQUIRED, not a convenience. Slipstream's NonfungiblePositionManager.mint() ends with an
    ///      unconditional `refundETH()`, which forwards the manager's ENTIRE native balance to
    ///      msg.sender and reverts if the recipient rejects it. The manager is shared infrastructure,
    ///      so anyone can force 1 wei into it (create + selfdestruct) — without a payable receiver
    ///      every mint from this contract would revert, disabling rebalanceUsingAlt() and
    ///      rebuildAfterSwap(), the only two paths that redeploy principal. Landing mid swap-window
    ///      that would strand the whole principal loose with no rebalancer-callable recovery.
    ///      Any ETH that arrives here is sweepable by the admin via `recoverETH`.
    receive() external payable {}

    /// @notice Register a position NFT already held by this contract.
    /// @param config Full position configuration. `active`, `mainStaked`, `altStaked`, `altTokenId`,
    ///               and `lastRebalance` are overridden by `_store` (forced to true / false / false /
    ///               0 / 0 respectively) regardless of the values supplied here.
    function registerPosition(ManagedPositionV2 calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (position.active) revert AlreadyRegistered();
        _validateAndStore(config);
        emit PositionRegistered(config.pool, config.mainTokenId);
    }

    /// @notice Re-point this (emptied) contract at a new pool/pair. Requires `position` to be fully
    ///         empty: only exit() zeroes the NFT ids (active=false, mainTokenId=0, altTokenId=0), so
    ///         setPool is the re-point path after exit(). After withdrawPosition()/deregisterPosition()
    ///         the token ids remain set, so re-point via registerPosition() in that case instead.
    ///         Runs the same validation as registerPosition.
    function setPool(ManagedPositionV2 calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (position.active || position.mainTokenId != 0 || position.altTokenId != 0) revert NotEmpty();
        _validateAndStore(config);
        emit PoolChanged(config.pool, config.mainTokenId);
    }

    /// @notice Deregister a position and transfer its NFT(s) to `to`.
    ///         Intentionally reverts if EITHER the main or the alt is staked: the admin must
    ///         `unstake` (or use `withdrawPosition`, which auto-unstakes) first. This keeps
    ///         deregister a pure book-keeping/transfer path and never silently strands a staked
    ///         NFT (an NFT held by the gauge can't be safeTransferFrom'd by this contract).
    function deregisterPosition(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _releaseNfts(to, false);
    }

    /// @notice Emergency withdraw: auto-unstakes both legs (if staked) then transfers the NFT(s)
    ///         to `to`. Allows an admin to rescue a position in one call regardless of staking state.
    function withdrawPosition(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _releaseNfts(to, true);
    }

    /// @dev Shared body of deregisterPosition/withdrawPosition — the two differ only in whether a
    ///      staked leg is auto-unstaked or rejected, and in which event they emit.
    /// @param autoUnstake true  → unstake both legs first (auto-claims AERO to the feeCollector);
    ///                    false → revert PositionStaked if EITHER leg is staked, keeping deregister
    ///                    a pure book-keeping/transfer path that can never strand a staked NFT (one
    ///                    held by the gauge cannot be safeTransferFrom'd by this contract).
    function _releaseNfts(address to, bool autoUnstake) private {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        if (to == address(0)) revert ZeroAddress();
        if (autoUnstake) {
            if (p.mainStaked) _unstakeLeg(p, true); // returns NFT to this contract
            if (p.altStaked) _unstakeLeg(p, false);
        } else if (p.mainStaked || p.altStaked) {
            revert PositionStaked();
        }
        uint256 tokenId = p.mainTokenId;
        p.active = false; // effects before interaction (CEI)
        if (autoUnstake) emit PositionWithdrawn(to);
        else emit PositionDeregistered(to);
        if (p.altTokenId != 0) POSITION_MANAGER.safeTransferFrom(address(this), to, p.altTokenId);
        POSITION_MANAGER.safeTransferFrom(address(this), to, tokenId); // interaction last
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Manager setters
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Update the core rebalance parameters for an active position.
    function setPositionConfig(
        uint24 minWidth,
        uint24 maxWidth,
        uint24 maxCenterDeviation,
        uint32 twapWindow,
        int24 maxTickDeviation,
        uint16 maxRebalanceLossBps,
        uint256 minRebalanceInterval
    ) external onlyRole(MANAGER_ROLE) {
        if (!position.active) revert NotActive();
        // Same validation body as registration (LPPositionLib.validateRebalanceConfig), so the two
        // config paths cannot drift.
        LPPositionLib.validateRebalanceConfig(
            minWidth,
            maxWidth,
            maxCenterDeviation,
            twapWindow,
            maxTickDeviation,
            maxRebalanceLossBps,
            MAX_LOSS_CAP_BPS,
            position.tickSpacing
        );

        ManagedPositionV2 storage p = position;
        p.minWidth = minWidth;
        p.maxWidth = maxWidth;
        p.maxCenterDeviation = maxCenterDeviation;
        p.twapWindow = twapWindow;
        p.maxTickDeviation = maxTickDeviation;
        p.maxRebalanceLossBps = maxRebalanceLossBps;
        p.minRebalanceInterval = minRebalanceInterval;

        emit PositionConfigUpdated();
    }

    /// @notice Update the fee collector for an active position. Admin (Safe) only: feeCollector is the
    ///         destination for all fee/AERO/dust flows, so it is a drain-direction power kept off the manager EOA.
    function setFeeCollector(address feeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!position.active) revert NotActive();
        if (feeCollector == address(0)) revert ZeroAddress();
        position.feeCollector = feeCollector;
        emit FeeCollectorUpdated(feeCollector);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Admin setters
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Update the price-feed oracles for an active position.
    function setOracles(address oracle0, address oracle1) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!position.active) revert NotActive();
        if (oracle0 == address(0) || oracle1 == address(0)) revert OracleRequired();
        // probe each feed against ITS OWN staleness bound: fail in the admin tx, not on the next rebalance
        _readFeed(oracle0, maxOracleDelay0);
        _readFeed(oracle1, maxOracleDelay1);
        position.oracle0 = oracle0;
        position.oracle1 = oracle1;
        emit OraclesUpdated(oracle0, oracle1);
    }

    /// @notice Update the gauge for an active position. Pass address(0) to disable staking.
    ///         Requires the position to not currently be staked.
    function setGauge(address gauge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        // Both legs must be unstaked: a partial unstake can leave the alt NFT custodied by the OLD
        // gauge; changing the gauge while altStaked would strand it (M-2).
        if (position.mainStaked || position.altStaked) revert PositionStaked();
        // Same gauge->pool + reward-token binding _validateAndStore enforces at registration —
        // shared via LPPositionLib.validateGauge so the two admin paths cannot drift.
        LPPositionLib.validateGauge(gauge, p.pool, AERO);
        position.gauge = gauge;
        emit GaugeUpdated(gauge);
    }

    /// @notice Update each feed's staleness bound independently. The ONLY way to write these bounds.
    /// @dev There is deliberately no single-argument `setMaxOracleDelay(uint256)` convenience
    ///      overload. The whole point of splitting one shared bound into two (MOO-740) is that the
    ///      legs are different assets on different heartbeats; a setter that writes one value to both
    ///      silently flattens exactly the per-feed tuning the split exists to enable, and does so
    ///      through the shortest, most reachable call path. Forcing both values to be named at every
    ///      write makes flattening them a visible choice rather than an accident. Nothing on chain
    ///      depends on the old selector — this contract is deployed for the first time by proposal
    ///      011, so there is no prior ABI to stay compatible with.
    function setMaxOracleDelays(uint256 newDelay0, uint256 newDelay1) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxOracleDelays(newDelay0, newDelay1);
    }

    /// @dev Sole writer for both bounds. Each must be non-zero (a zero bound rejects every read) and
    ///      within `MAX_ORACLE_DELAY` — see that constant for why the ceiling is a day and not a week.
    function _setMaxOracleDelays(uint256 newDelay0, uint256 newDelay1) private {
        if (newDelay0 == 0 || newDelay0 > MAX_ORACLE_DELAY || newDelay1 == 0 || newDelay1 > MAX_ORACLE_DELAY) {
            revert InvalidConfig();
        }
        maxOracleDelay0 = newDelay0;
        maxOracleDelay1 = newDelay1;
        emit MaxOracleDelaysUpdated(newDelay0, newDelay1);
    }

    /// @notice Configure the L2 sequencer uptime guard applied to every Chainlink read.
    /// @param feed the sequencer uptime aggregator; `address(0)` disables the guard entirely.
    /// @param gracePeriod seconds the sequencer must have been continuously up before feed reads
    ///        are accepted again. Must be non-zero whenever `feed` is set: a zero grace period
    ///        re-admits the pre-outage report in the very block the sequencer resumes, which is
    ///        exactly the window this guard exists to close. Capped at 7 days so a fat-fingered
    ///        value cannot brick every valuation path indefinitely.
    function setSequencerUptimeFeed(address feed, uint256 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feed != address(0) && (gracePeriod == 0 || gracePeriod > 7 days)) revert InvalidConfig();
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        // Probe immediately so a wrong address / down sequencer fails in the admin tx.
        if (feed != address(0)) LPValuationLib.checkSequencer(feed, gracePeriod);
        emit SequencerUptimeFeedUpdated(feed, gracePeriod);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Pause
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pause the contract (guardian only).
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract (guardian only).
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Gauge staking
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Approve the gauge and deposit the position NFT(s) into it for AERO emissions.
    ///         Stakes the main NFT always; also stakes the alt NFT when altTokenId != 0.
    /// @dev SKIM BEFORE STAKE. Slipstream's CLGauge.deposit() collects all pre-stake LP fees with
    ///      `recipient == msg.sender` — i.e. this contract. Without the `_skimFees` call below those
    ///      fees land as loose token0/token1 and are indistinguishable from principal: a later
    ///      rebalance mints them into the new position, or exit() pays them to the principal
    ///      recipient, and the feeCollector never sees them. `_exitAll` already uses this
    ///      skim-then-act ordering; this matches it.
    function stake() external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        if (p.gauge == address(0)) revert NoGauge();
        if (p.mainStaked) revert AlreadyStaked();
        _skimFees(p, p.mainTokenId);
        _stakeLeg(p, p.mainTokenId, true);
        if (p.altTokenId != 0) {
            _skimFees(p, p.altTokenId);
            _stakeLeg(p, p.altTokenId, false);
        }
    }

    /// @dev Approve the gauge for one NFT, deposit it, set that leg's staked flag, emit Staked.
    ///      Shared by stake() and _restakeBoth so the approve/deposit/flag triple has one definition.
    /// @param main true → the main leg, false → the alt leg.
    function _stakeLeg(ManagedPositionV2 storage p, uint256 tokenId, bool main) private {
        POSITION_MANAGER.approve(p.gauge, tokenId);
        ICLGauge(p.gauge).deposit(tokenId);
        if (main) p.mainStaked = true;
        else p.altStaked = true;
        emit Staked(tokenId, p.gauge);
    }

    /// @notice Withdraw the position NFT(s) from the gauge and skim any AERO to the fee collector.
    ///         Unstakes the main NFT always; also unstakes the alt NFT when altStaked && altTokenId != 0.
    function unstake() external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
        ManagedPositionV2 storage p = position;
        if (!p.mainStaked) revert NotStaked();
        _unstakeLeg(p, true);
        if (p.altStaked && p.altTokenId != 0) _unstakeLeg(p, false);
    }

    /// @dev Withdraw one leg from the gauge (which auto-claims AERO), clear that leg's staked flag,
    ///      then skim ONLY the AERO gained by this withdraw to the feeCollector. Measuring the gain
    ///      rather than the balance means a stray AERO balance already sitting on this contract is
    ///      never swept. CEI: the flag is cleared before the AERO transfer.
    /// @dev NO LP-FEE MIRROR OF MOO-736 HERE. `CLGauge.withdraw()` opens with the same
    ///      `nft.collect({recipient: msg.sender})` that motivated the skim-before-stake fix in
    ///      `stake()`, so the symmetric worry is that fees land loose on the way OUT and get counted
    ///      as principal. They cannot, and the reason is in Slipstream, not here:
    ///        - `CLPool.calculateFees` routes the STAKED share of every swap fee to `gaugeFee` and
    ///          grows `feeGrowthGlobalX128` only over `liquidity - stakedLiquidity`, and
    ///          `Position.update(..., staked = true)` skips the tokensOwed accrual outright;
    ///        - Slipstream's `NonfungiblePositionManager.collect` takes a separate branch for a
    ///          gauge-owned position that updates the feeGrowthInside snapshot but adds NOTHING to
    ///          tokensOwed;
    ///        - `CLGauge.deposit()` already collected every pre-stake fee (and `stake()` skims before
    ///          that), so tokensOwed is zero when staking begins and stays zero throughout.
    ///      The withdraw-time collect therefore transfers 0/0. Verified against
    ///      github.com/aerodrome-finance/slipstream (`CLGauge.deposit/withdraw`, `CLPool.stake` /
    ///      `calculateFees`, `Position.update`, `NonfungiblePositionManager.collect`) rather than
    ///      assumed. The balancer never calls increase/decreaseLiquidity or collect on a staked
    ///      tokenId (it is not the owner while staked, and `collectFees()` reverts AlreadyStaked), so
    ///      there is no path that makes tokensOwed non-zero mid-stake. `_exitAll`'s existing
    ///      unstake-then-`_skimFees` order is correct as written: the post-unstake skim is what picks
    ///      up any fee accrued after the gauge released the NFT.
    /// @param main true → the main leg, false → the alt leg.
    function _unstakeLeg(ManagedPositionV2 storage p, bool main) private {
        uint256 tokenId = main ? p.mainTokenId : p.altTokenId;
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        ICLGauge(p.gauge).withdraw(tokenId); // returns NFT + auto-claims AERO
        if (main) p.mainStaked = false;
        else p.altStaked = false;
        uint256 aeroEarned = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        if (aeroEarned > 0) {
            IERC20(AERO).safeTransfer(p.feeCollector, aeroEarned);
            emit EmissionsClaimed(aeroEarned);
        }
        emit Unstaked(tokenId, p.gauge);
    }

    /// @notice Emergency exit: unstake (skimming AERO to feeCollector), collect fees, remove all
    ///         liquidity, burn both NFTs, and transfer the resulting token0/token1 balances to `to`.
    ///         Marks the position inactive. Use when the Safe needs to fully tear down a position in one
    ///         call regardless of staking state. Uses 0 sandwich mins (emergency path).
    ///         Always available mid-swap-rebalance: if unwindForSwap already tore down and burned
    ///         both NFTs (rebalanceInFlight == true), this skips the teardown (nothing left to do),
    ///         revokes the stale CowSwap relayer approval, and clears the in-flight state instead —
    ///         then falls into the same sweep/deactivate tail as the normal path.
    ///
    ///         CEI ordering:
    ///           1. active = false  — flipped first; this is the re-entry sentinel checked by the
    ///                                NotActive guard at the top of every external mutator.
    ///           2. _exitAll + token transfers — the interactions (external calls).
    ///           3. mainTokenId = altTokenId = 0 — final bookkeeping; these fields are consumed by
    ///                                             _exitAll so they must remain valid through step 2.
    function exit(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        if (to == address(0)) revert ZeroAddress();

        // Effect (re-entry sentinel): flip active before any external call.
        // _exitAll reads mainTokenId/altTokenId from the struct, so those fields are kept
        // intact until after _exitAll returns.
        p.active = false;

        if (_window.inFlight) {
            // Mid-flight: unwindForSwap already tore down and burned both NFTs before opening
            // the window. There is nothing left to decrease/skim/burn — calling _exitAll again
            // would operate on already-burned tokenIds and revert against the real position
            // manager. The escape-close revokes the stale relayer approval and clears the window;
            // the shared tail below sweeps whatever principal (± partial settlement proceeds)
            // is currently sitting on the contract.
            _window.closeForExit();
        } else {
            // Interactions: unstake (AERO → feeCollector), skim fees, decreaseAll + collect, burn NFTs.
            // Emergency path: 0 mins on both legs, deadline = block.timestamp (execute immediately).
            _exitAll(p, 0, 0, 0, 0, block.timestamp);
        }

        // Transfer all principal recovered from the position to `to`.
        _sweepPairTo(p, to);

        // Bookkeeping: zero NFT references now that _exitAll has consumed and burned them.
        p.mainTokenId = 0;
        p.altTokenId = 0;

        emit PositionWithdrawn(to);
    }

    /// @notice Claim AERO emissions from the gauge for a staked position and forward to feeCollector.
    ///         Claims from both main and alt (if altStaked && altTokenId != 0).
    /// @dev REBALANCER_ROLE-gated, deliberately NOT permissionless. This routes 100% of the claimed
    ///      AERO to the feeCollector, while `compound()` is the ONLY path that ever sends AERO to the
    ///      compoundModule. Permissionless, a bot calling this every block keeps the gauge's pending
    ///      balance at ~0, so `compound(compoundBps)` always harvests ~nothing and the compound share
    ///      never materializes — a griefing vector that silently disables reinvestment. The claim is
    ///      not time-critical (emissions keep accruing in the gauge), so gating it costs nothing.
    function claimEmissions() external onlyRole(REBALANCER_ROLE) whenNotPaused nonReentrant {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        if (!p.mainStaked) revert NotStaked();
        // Snapshot AERO balance before claiming from both legs, then forward the net gain.
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        ICLGauge(p.gauge).getReward(p.mainTokenId);
        if (p.altStaked && p.altTokenId != 0) {
            ICLGauge(p.gauge).getReward(p.altTokenId);
        }
        uint256 aeroEarned = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        if (aeroEarned > 0) {
            IERC20(AERO).safeTransfer(p.feeCollector, aeroEarned);
            emit EmissionsClaimed(aeroEarned);
        }
    }

    /// @notice Live underlying token0 — read by the compound module (survives setPool).
    function token0() external view returns (address) {
        return position.token0;
    }

    /// @notice Live underlying token1 — read by the compound module (survives setPool).
    function token1() external view returns (address) {
        return position.token1;
    }

    /// @notice Set the LPCompoundModule that receives the compound share of AERO.
    function setCompoundModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module == address(0)) revert ZeroAddress();
        compoundModule = module;
        emit CompoundModuleUpdated(module);
    }

    /// @notice Sets the extra value-floor tolerance for swap rebalances. Admin only, capped.
    function setSwapLossAllowanceBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_SWAP_LOSS_ALLOWANCE_BPS) revert SwapLossAllowanceTooHigh();
        emit SwapLossAllowanceUpdated(swapLossAllowanceBps, newBps);
        swapLossAllowanceBps = newBps;
    }

    /// @notice Harvest AERO, drop `(BPS - compoundBps)` to feeCollector, forward `compoundBps` to the
    ///         compound module. The module owns the CowSwap orders (AERO -> token0|token1) and their
    ///         EIP-1271 validation; the solver delivers underlying back to THIS contract, folded into
    ///         the main+alt at the next rebalanceUsingAlt(). Reward-only — never touches principal.
    /// @param compoundBps share of harvested AERO to reinvest (<= MAX_COMPOUND_BPS).
    function compound(uint16 compoundBps) external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
        if (compoundBps > MAX_COMPOUND_BPS) revert CompoundBpsTooHigh();
        if (compoundModule == address(0)) revert ModuleNotSet();
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();

        // Harvest pending AERO from staked legs into this contract (no unstake).
        if (p.mainStaked) ICLGauge(p.gauge).getReward(p.mainTokenId);
        if (p.altStaked && p.altTokenId != 0) ICLGauge(p.gauge).getReward(p.altTokenId);

        uint256 aero = IERC20(AERO).balanceOf(address(this));
        if (aero == 0) revert NothingToCompound();

        // Plain arithmetic: `aero` is an ERC-20 balance and the multiplier is <= 10_000, so the
        // product cannot overflow uint256 for any real token supply (FullMath's 512-bit path
        // costs the balancer bytecode it does not have).
        uint256 dropAmount = aero * (BPS_DENOMINATOR - compoundBps) / BPS_DENOMINATOR;
        uint256 compoundAmount = aero - dropAmount;

        if (dropAmount > 0) {
            IERC20(AERO).safeTransfer(p.feeCollector, dropAmount);
            emit EmissionsClaimed(dropAmount);
        }
        if (compoundAmount > 0) {
            IERC20(AERO).safeTransfer(compoundModule, compoundAmount);
        }
        emit CompoundInitiated(compoundAmount, dropAmount, compoundBps);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Rebalance
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Parameters for phase 1 of a swap rebalance.
    struct UnwindParams {
        address sellToken; // token0 or token1 — the excess leg (backend-computed)
        uint256 sellAmount; // approve exactly this to VAULT_RELAYER
        uint256 amount0MinWithdraw; // sandwich floors for the teardown (main)
        uint256 amount1MinWithdraw;
        uint256 amount0MinWithdrawAlt; // (alt)
        uint256 amount1MinWithdrawAlt;
        uint256 deadline;
    }

    /// @notice Phase 1 of a swap rebalance: tears down both positions, snapshots value,
    ///         approves the CowSwap vault relayer for exactly `sellAmount`, and opens the
    ///         order-validation window. No mint happens here; `rebuildAfterSwap` completes the cycle.
    /// @dev    ORACLE PRECHECK. Both feeds are probed below purely for the revert, before `_exitAll`
    ///         burns anything. This function does not need a price — `_snapshotAmounts` is
    ///         oracle-free by design — but `rebuildAfterSwap` cannot complete without one: it prices
    ///         the snapshot through `_mainRange`, `_mintAlt` and the value floor. Unwinding while a
    ///         feed (or the sequencer guard) is already blocking is therefore a teardown that
    ///         provably cannot be rebuilt: both NFTs burn, principal sits loose and unstaked, and the
    ///         only exit is `exit()` behind DEFAULT_ADMIN_ROLE (the timelocked Safe) until the feed
    ///         recovers. An earlier revision got this check for free — the unwind used to compute a
    ///         USD snapshot, which read both feeds incidentally. Moving the snapshot to raw amounts
    ///         (correct: a USD baseline frozen across two transactions reads an ordinary market move
    ///         as a rebalance loss) dropped the read, and with it the precondition. It is restored
    ///         here as an explicit, intentional gate rather than a side effect of a computation.
    ///
    ///         Sharpened by the L2 sequencer guard on this same path: after every Base sequencer
    ///         recovery, `checkSequencer` rejects reads for the whole grace period (3600s as
    ///         proposal 011 arms it), so without this probe each recovery opens a window in which
    ///         unwind succeeds and the matching rebuild reverts SequencerGracePeriod.
    ///
    ///         RESIDUAL (unchanged, and not closable here): this bounds the state at unwind, not the
    ///         state at rebuild. A feed that goes stale BETWEEN the two transactions still strands
    ///         the rebuild until it recovers. Closing that would require an oracle-free rebuild path,
    ///         which would mean minting and clearing the value floor with no price — strictly worse.
    ///         The probe removes the case the contract can see coming; the rest is monitoring.
    function unwindForSwap(UnwindParams calldata params)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        whenNotPaused
    {
        ManagedPositionV2 storage p = position;
        // Guards + calm-gate delegated to LPPositionLib (primitives in, primitives out) to keep this
        // function's bytecode off the balancer's EIP-170 budget. The library reverts with the same
        // error selectors declared here (NotActive/AlreadyInFlight/Cooldown/ModuleNotSet/
        // InvalidSellToken/TwapDeviation) and returns the current sqrt price, from which
        // `_snapshotAmounts` below derives the floor's token-amount baseline.
        (uint160 sqrtP,,) = LPPositionLib.unwindPrecheck(
            p.active,
            _window.inFlight,
            p.lastRebalance,
            p.minRebalanceInterval,
            compoundModule,
            p.token0,
            p.token1,
            params.sellToken,
            params.sellAmount,
            p.pool,
            p.twapWindow,
            p.maxTickDeviation
        );

        // Probe both feeds (and, inside them, the sequencer guard) BEFORE `_exitAll` burns the NFTs.
        // Discarded return values: called for the revert, not for a price — see the ORACLE PRECHECK
        // note above. Each leg is checked against ITS OWN bound, exactly as the rebuild will check
        // it. Two direct `_readFeed` calls, deliberately: routing this through a single
        // `LPValuationLib.probeFeeds(cfg)` helper reads better but measures WORSE (+34 bytes on the
        // balancer), because materialising the six-field OracleConfig in memory costs more than the
        // second external call it saves. The balancer is inside 100 bytes of EIP-170; that trade is
        // not available here.
        _readFeed(p.oracle0, maxOracleDelay0);
        _readFeed(p.oracle1, maxOracleDelay1);

        // Split the snapshot the same way rebalanceUsingAlt does: position principal (haircut by
        // the floor below) vs. pre-existing loose token0/token1 (added back un-haircut). See H-1.
        //
        // Recorded as TOKEN AMOUNTS, never USD: the floor is compared in a LATER transaction, and a
        // USD baseline frozen here would make an ordinary market move during CowSwap settlement read
        // as a rebalance loss and revert an honest rebuild (see SwapWindowLib.Snapshot). No oracle is
        // consulted at unwind at all — rebuildAfterSwap prices this snapshot with the same feed reads
        // that produce valueAfter, so the market move cancels on both sides.
        SwapWindowLib.Snapshot memory snap = _snapshotAmounts(p, sqrtP);
        bool wasStaked = p.mainStaked; // MUST be captured before _exitAll un-stakes the main

        _exitAll(
            p,
            params.amount0MinWithdraw,
            params.amount1MinWithdraw,
            params.amount0MinWithdrawAlt,
            params.amount1MinWithdrawAlt,
            params.deadline
        );

        // One call opens the window: snapshot, exact-amount relayer approval and the in-flight
        // flag are set together — none can be skipped or reordered by this call site.
        _window.open(params.sellToken, params.sellAmount, snap, wasStaked);

        emit RebalanceUnwound(params.sellToken, params.sellAmount);
    }

    /// @notice Phase 2 of a swap rebalance: revokes the relayer approval, re-mints main (+alt)
    ///         from whatever the contract currently holds, enforces the value floor against the
    ///         unwind snapshot (with swapLossAllowanceBps extra tolerance), restakes if the
    ///         position was staked before, and closes the in-flight window.
    /// @dev    Deliberately NOT gated on cooldown or on CowSwap order state: filled, expired,
    ///         or never-placed orders all rebuild from current balances. IS gated on pause and
    ///         the calm gate; exit() remains the escape hatch if either blocks.
    /// @dev    TICK COMMITMENT. `expectedTickLower`/`expectedTickUpper` are the range the CALLER
    ///         computed off-chain when it decided to rebuild; if the range this function derives from
    ///         live spot differs at all, it reverts TickMismatch. Without it this function commits to
    ///         no ticks: calmGate bounds spot-vs-TWAP deviation but hands back LIVE spot for
    ///         placement, and `_mainRange` floor-aligns that attacker-influenced spot, so one
    ///         tickSpacing of manipulation shifts the whole range. The amount minima cannot catch
    ///         that — a single-sided mint consumes the entire funded balance at both the honest and
    ///         the manipulated price, so amount0MinMain passes either way. Committing to the exact
    ///         ticks is what makes the placement verifiable rather than merely bounded.
    ///
    ///         SCOPE OF THE COMMITMENT — what it pins, and what it does NOT. The commitment names
    ///         only the MAIN bounds. From them it also pins the ALT's ANCHOR, because the width is
    ///         required to be an even multiple of tickSpacing (per-call check below and
    ///         `LPPositionLib.validateRebalanceConfig` on the bounds). `_mintAlt` anchors on
    ///         `floorAlign(spotTick)`, and each `_mainRange` branch inverts to that anchor uniquely
    ///         under that constraint: balanced → `floorAlign(spot) = tickLower + width/2` (valid only
    ///         because `width/2` is a whole number of spacings); token0-single-sided →
    ///         `tickLower - tickSpacing`; token1-single-sided → `tickUpper`. Drop the even-multiple
    ///         rule and even that stops holding: at spacing 100 / width 300, spot 150 and spot 249
    ///         both yield main [0, 300] while the token0 alt slides from [200, 300] to [300, 400]
    ///         with TickMismatch silent. So the alt's two candidate ranges — [floor + spacing,
    ///         floor + 2*spacing] and [floor - spacing, floor] — are pinned to exact ticks.
    ///
    ///         It does NOT pin WHICH of the two is minted. That choice is `_mintAlt`'s
    ///         `surplus0 = value0 >= value1`, computed from the balances left AFTER `_mintBalanced`,
    ///         and the position manager consumes the in-ratio portion at the exact `sqrtP` — not at
    ///         `floorAlign(spot)`. So spot can move WITHIN the committed bucket, leave TickMismatch
    ///         silent, and still flip the alt to the other side of spot. (`_mainRange`'s own branch is
    ///         immune: it classifies on oracle-priced leg values, which spot does not move. Only the
    ///         alt's post-mint residual is spot-sensitive.)
    ///
    ///         Bounded, and here is the bound. The flip can only occur near `value0 == value1`, since
    ///         that is the comparison being flipped — so the two candidate legs are close in USD value
    ///         precisely where the outcome is in doubt, and both candidate ranges sit one spacing from
    ///         spot on opposite sides. What actually changes is which leg is deposited into the alt
    ///         and which is left loose for `_forwardDust` to sweep to the feeCollector after the value
    ///         floor. That is a real, if narrow, effect on principal placement, and it is stated here
    ///         rather than papered over: the even-multiple width rule buys a pinned alt ANCHOR, not a
    ///         pinned alt SIDE. Pinning the side would need the alt's own bounds (and its
    ///         "no alt was minted" case) added to the commitment.
    /// @dev    Unlike rebalanceUsingAlt (same-transaction before/after split, so a donation cancels
    ///         out of the floor per H-1), BOTH floor snapshots here (the position and loose amounts)
    ///         are taken back in unwindForSwap — a prior transaction. A token
    ///         donated to the contract between unwindForSwap and rebuildAfterSwap inflates valueAfter
    ///         (whichever term — position or loose — the donation lands in) without inflating either
    ///         snapshot, widening the floor's apparent headroom by the donated amount. Not a
    ///         fund-extraction vector (REBALANCER_ROLE-gated, and a donor only gives away value to
    ///         loosen a check on their own gift), but it is a strictly weaker safety guarantee than
    ///         rebalanceUsingAlt's — a structural consequence of the floor spanning two transactions.
    ///         Separately (not a cross-tx concern): the LOOSE component is added back un-haircut here,
    ///         matching rebalanceUsingAlt's H-1 treatment — a pre-existing loose balance already on the
    ///         contract when unwindForSwap runs (e.g. un-folded AERO-compound proceeds) no longer widens
    ///         the tolerated absolute loss the way it did before this split.
    /// @dev    Second residual (availability only, same two-transaction structure): _exitAll
    ///         commingles any pre-existing loose balance with the withdrawn principal BEFORE the
    ///         off-chain sellAmount is chosen, so the CowSwap sell may dip into that loose balance.
    ///         Slippage then accrues on a notional larger than rebalanceValueBeforePos while the
    ///         floor's tolerance scales only with rebalanceValueBeforePos, which can false-revert an
    ///         honest rebuild. Not a fund-loss vector; recoverable via exit() (or by retrying with a
    ///         smaller sell). Backends should size sellAmount from the position snapshot, not from
    ///         the contract's whole balance.
    function rebuildAfterSwap(RebuildParams calldata params)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        whenNotPaused
    {
        // Success-close at the top: guard (NotInFlight), approval revoke and snapshot handoff in
        // one statement. Safe before the mint/floor logic below — a later revert unwinds this
        // close too, so a failed rebuild leaves the window open for retry (see SwapWindowLib).
        (SwapWindowLib.Snapshot memory snap, bool wasStaked) = _window.closeForRebuild();
        ManagedPositionV2 storage p = position;

        (uint160 sqrtP, int24 spotTick, uint8 dec0, uint8 dec1) =
            LPGeometryLib.calmGate(p.pool, p.twapWindow, p.maxTickDeviation, p.token0, p.token1);
        // ONE oracle set for the whole call: the unwind snapshot below is priced with exactly the
        // same feed reads (same block, same bounds, same sequencer guard) that produce valueAfter,
        // so a market move between unwind and rebuild cancels on both sides of the floor.
        LPValuationLib.OracleConfig memory cfg = _oracleCfg(p);

        if (params.width < p.minWidth || params.width > p.maxWidth) revert WidthOutOfBounds();
        // Config bounds are 2*spacing-aligned but the per-call width is caller-supplied: an unaligned
        // width would produce an unaligned tickUpper and only revert deep inside the pool's mint, and
        // an ODD multiple of the spacing would un-pin the alt from the tick commitment (see above).
        if (params.width % (2 * uint24(p.tickSpacing)) != 0) revert InvalidWidth();

        (int24 tl, int24 tu) = _mainRange(p, cfg, spotTick, params.width, dec0, dec1);
        // TICK COMMITMENT (see the natspec above): the caller pinned the range it decided on; a spot
        // that moved — or was moved — between decision and execution must abort, not silently mint a
        // shifted range that the amount minima cannot detect.
        if (tl != params.expectedTickLower || tu != params.expectedTickUpper) revert TickMismatch();

        uint256 newMain =
            _mintBalanced(p, spotTick, tl, tu, params.amount0MinMain, params.amount1MinMain, params.deadline);
        p.mainTokenId = newMain;
        p.altStaked = false;
        p.mainStaked = false;
        p.lastRebalance = block.timestamp;

        p.altTokenId =
            _mintAlt(p, cfg, spotTick, dec0, dec1, params.amount0MinAlt, params.amount1MinAlt, params.deadline);

        uint256 valueAfter = _totalValue(p, cfg, sqrtP, dec0, dec1);
        // Swap round trip gets the extra swapLossAllowanceBps tolerance on top of maxRebalanceLossBps.
        _enforceValueFloor(
            LPValuationLib.valueInUsd(snap.amount0Pos, snap.amount1Pos, cfg, dec0, dec1),
            LPValuationLib.valueInUsd(snap.loose0, snap.loose1, cfg, dec0, dec1),
            valueAfter,
            swapLossAllowanceBps
        );

        _forwardDust(p);

        _restakeBoth(p, newMain, wasStaked);

        emit RebalanceRebuilt(newMain, p.altTokenId);
    }

    /// @param expectedTickLower the main range's lower bound the CALLER computed off-chain, with the
    ///        same meaning and the same TickMismatch enforcement as on `RebuildParams` — see the TICK
    ///        COMMITMENT note on `rebuildAfterSwap`.
    /// @param expectedTickUpper the main range's upper bound the CALLER committed to.
    struct RebalanceParams {
        uint24 width;
        uint256 amount0MinMain;
        uint256 amount1MinMain;
        uint256 amount0MinAlt;
        uint256 amount1MinAlt;
        uint256 amount0MinWithdraw;
        uint256 amount1MinWithdraw;
        uint256 amount0MinWithdrawAlt;
        uint256 amount1MinWithdrawAlt;
        uint256 deadline;
        int24 expectedTickLower;
        int24 expectedTickUpper;
    }

    /// @notice Parameters for phase 2 of a swap rebalance (rebuildAfterSwap). Unlike
    ///         RebalanceParams, this has NO withdraw-min fields — unwindForSwap already tore
    ///         down the position in a prior transaction, so there is no _exitAll here to sandwich-
    ///         floor. Only the mint side needs protection.
    /// @param expectedTickLower the main range's lower bound the CALLER computed off-chain. The
    ///        rebuild reverts TickMismatch unless the range derived from live spot matches exactly.
    ///        Off-chain callers reproduce it with the same rule `_mainRange` uses: the spot-centered
    ///        aligned straddle when both legs clear MIN_MAIN_LEG_USD, otherwise the single-sided
    ///        range on the majority side adjacent to spot.
    /// @param expectedTickUpper the main range's upper bound the CALLER committed to.
    struct RebuildParams {
        uint24 width;
        uint256 amount0MinMain;
        uint256 amount1MinMain;
        uint256 amount0MinAlt;
        uint256 amount1MinAlt;
        uint256 deadline;
        int24 expectedTickLower;
        int24 expectedTickUpper;
    }

    /// @notice Tear down both positions and rebuild a fresh balanced `main` plus a single-sided
    ///         `alt` from the withdrawn principal — NO SWAP. V2 has no swap router/quoter, so the
    ///         positions are reconstituted purely from the tokens the position manager returns on
    ///         withdraw; nothing is sold. The alt parks the post-main surplus leg (see step 6).
    ///
    ///         Orchestration (all on-chain):
    ///         1.  Read spot + TWAP; deviation gate.
    ///         2.  Snapshot value-before (main + alt principal at current sqrtP).
    ///         3.  _exitAll: unstake (AERO → feeCollector), skim fees, decreaseAll + collect
    ///             principal into this contract, burn both NFTs.
    ///         4.  Width bounds check; compute spot-centered aligned range.
    ///         5.  _mintBalanced: mint new main from contract balances (PM consumes the
    ///             in-ratio portion; leftover stays in the contract).
    ///         6.  _mintAlt: mint the single-sided alt from the surplus leg (selected by USD
    ///             VALUE), parking it one tickSpacing outside the main range. Forwards NO dust.
    ///         7.  Value-floor gate: valueAfter = new main + alt + loose contract balances
    ///             (_contractPairValue), so nothing escapes the floor as "dust".
    ///         8.  Forward the genuine sub-threshold remainder → feeCollector (AFTER the floor).
    ///         9.  Restake the new main if the old main was staked.
    function rebalanceUsingAlt(RebalanceParams calldata params)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        whenNotPaused
    {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        if (block.timestamp < p.lastRebalance + p.minRebalanceInterval) revert Cooldown();

        // Shared calm-gate preamble (spot + TWAP deviation gate + token decimals) in LPGeometryLib.
        (uint160 sqrtP, int24 spotTick, uint8 dec0, uint8 dec1) =
            LPGeometryLib.calmGate(p.pool, p.twapWindow, p.maxTickDeviation, p.token0, p.token1);
        // ONE oracle set for the whole call, so both sides of the value floor are priced under
        // identical rules (same bounds, same sequencer guard, same block).
        LPValuationLib.OracleConfig memory cfg = _oracleCfg(p);

        // value BEFORE: both positions' principal at the current sqrtP snapshot, PLUS any loose
        // token0/token1 ALREADY held by this contract (donated, or leftover from a prior reverted
        // flow). This MUST be read BEFORE _exitAll withdraws principal into the contract, so it
        // captures only the genuinely pre-existing balance — not post-withdraw principal. valueAfter
        // also counts loose balances (_contractPairValue), so a stray/donated balance cancels on both
        // sides and cannot inflate the floor's headroom to mask a real rebalance loss (H-1).
        uint256 looseBefore = _contractPairValue(p, cfg, dec0, dec1);
        // valueBeforePos is POSITION principal only (main + alt). The loss haircut below applies to
        // this alone — never to looseBefore. A donated loose balance is added UNHAIRCUT to the floor's
        // RHS instead (see the value-floor gate), so a donation cannot widen the loss tolerance.
        uint256 valueBeforePos = _positionsValue(p, cfg, sqrtP, dec0, dec1);

        bool wasStaked = p.mainStaked;

        // tear down: unstake + AERO skim, fee skim, decreaseAll + collect, burn both NFTs.
        // Forward the caller-supplied withdraw mins as the sandwich floor on BOTH decreases
        // (main + alt). The alt mins are independent because the rebalancer cannot predict which
        // single leg the alt holds until execution time.
        _exitAll(
            p,
            params.amount0MinWithdraw,
            params.amount1MinWithdraw,
            params.amount0MinWithdrawAlt,
            params.amount1MinWithdrawAlt,
            params.deadline
        );

        if (params.width < p.minWidth || params.width > p.maxWidth) revert WidthOutOfBounds();
        // Config bounds are 2*spacing-aligned but the per-call width is caller-supplied: an unaligned
        // width would produce an unaligned tickUpper and only revert deep inside the pool's mint, and
        // an ODD multiple of the spacing would un-pin the alt anchor from the tick commitment below
        // (see the TICK COMMITMENT note on rebuildAfterSwap). Identical rule on both rebalance paths,
        // so "legal width" has ONE definition across them and across the config bounds.
        if (params.width % (2 * uint24(p.tickSpacing)) != 0) revert InvalidWidth();

        // Choose the new main range. The common case is a spot-centered straddle. But rebalancing a
        // FULLY out-of-range position withdraws 100%-single-sided principal (a CL position outside
        // its range holds exactly one token). A straddling balanced mint with one desired leg == 0
        // computes ZERO liquidity and the position manager reverts. With NO SWAP we cannot
        // manufacture the missing leg, so in that degenerate case we place the main entirely on the
        // FUNDED side, adjacent to spot — a valid single-sided main that waits for price to oscillate
        // back into balance (Beefy "never sell"). Principal is fully redeployed; nothing is sold.
        (int24 tl, int24 tu) = _mainRange(p, cfg, spotTick, params.width, dec0, dec1);
        // TICK COMMITMENT — same rule, same enforcement as rebuildAfterSwap (see its natspec).
        // Being single-transaction does NOT substitute for it. Atomicity guarantees the teardown and
        // the mint see one price; it says nothing about whether that price is honest. `calmGate`
        // bounds spot against the TWAP but then hands LIVE spot to `_mainRange`, which floor-aligns
        // it — so a sandwich that moves spot by up to maxTickDeviation (one full spacing at the
        // phase-1 config) shifts the entire range by a spacing and reverts the price afterwards.
        // Neither the withdraw minima nor the mint minima can see it: `_mintBalanced` zeroes the
        // unfunded leg's min on the single-sided branch, and the funded leg's min passes at ANY range
        // because the whole balance is consumed either way. Nor can the value floor: `valueAfter` is
        // measured at the manipulated sqrtP, where the freshly minted position still holds exactly
        // the tokens just deposited. The mis-ranging only materialises once spot reverts — after this
        // transaction has committed. Committing to the exact ticks is what makes the placement
        // verifiable rather than merely bounded.
        if (tl != params.expectedTickLower || tu != params.expectedTickUpper) revert TickMismatch();

        uint256 newMain =
            _mintBalanced(p, spotTick, tl, tu, params.amount0MinMain, params.amount1MinMain, params.deadline);
        p.mainTokenId = newMain;
        p.altStaked = false; // freshly minted, not yet staked (restaked below iff wasStaked)
        p.mainStaked = false; // freshly minted, not yet staked (restaked below iff wasStaked)
        p.lastRebalance = block.timestamp;

        // Mint the single-sided alt from the post-mint leftover (NO SWAP). _mintAlt selects the
        // surplus leg by USD VALUE, returns 0 (minting nothing) when the surplus is below
        // MIN_ALT_VALUE_USD, and — critically — does NOT forward dust. The value floor below must
        // see all value the contract controls BEFORE anything is shipped out as "dust".
        // Set altTokenId BEFORE the value-floor read so _totalValue sees the new alt.
        p.altTokenId =
            _mintAlt(p, cfg, spotTick, dec0, dec1, params.amount0MinAlt, params.amount1MinAlt, params.deadline);

        // value AFTER: new main principal + alt principal at the same sqrtP snapshot, PLUS the
        // USD value of any loose token0/token1 still held by this contract (_contractPairValue).
        // Counting the loose balance is the key invariant: a non-trivial surplus cannot escape the
        // floor by being forwarded as "dust" — if it's real value it is either in the alt (counted)
        // or loose (counted) at floor time. Only sub-threshold dust leaves, and only AFTER this check.
        uint256 valueAfter = _totalValue(p, cfg, sqrtP, dec0, dec1);
        // Haircut applies to POSITION value only; the pre-existing loose balance is added back UNHAIRCUT.
        // looseAfter (in valueAfter) ≈ looseBefore + withdrawn surplus, so the donated L cancels on both
        // sides and cannot inflate headroom to mask a real principal loss (H-1). No-swap path: extraBps = 0.
        _enforceValueFloor(valueBeforePos, looseBefore, valueAfter, 0);

        // Floor passed: only NOW forward the genuine sub-threshold remainder to the feeCollector.
        _forwardDust(p);

        _restakeBoth(p, newMain, wasStaked);

        emit RebalancedUsingAlt(newMain, p.altTokenId, tl, tu);
    }

    // ─── rebalanceUsingAlt private helpers ────────────────────────────────────────────────

    /// @dev Restake the freshly minted main (+ alt, if any) into the gauge, iff `wasStaked` (the
    ///      position was staked before teardown). Shared by rebalanceUsingAlt and rebuildAfterSwap.
    ///      Staking the alt too matters: once the main is staked, stake() and collectFees() both
    ///      revert AlreadyStaked, so a stranded unstaked alt could never collect AERO/fees until
    ///      the next rebalance.
    function _restakeBoth(ManagedPositionV2 storage p, uint256 newMain, bool wasStaked) private {
        if (!wasStaked || p.gauge == address(0)) return;
        _stakeLeg(p, newMain, true);
        if (p.altTokenId != 0) _stakeLeg(p, p.altTokenId, false);
    }

    /// @dev Tear down the managed position(s): unstake the main (auto-claims AERO →
    ///      feeCollector), skim LP fees on every held NFT → feeCollector, then remove all
    ///      liquidity, collect the principal into this contract, and burn the NFTs.
    ///      Handles both main and alt; the alt is skipped when altTokenId == 0.
    /// @param amount0MinWithdraw Caller-supplied sandwich floor applied to the MAIN decrease (token0).
    /// @param amount1MinWithdraw Caller-supplied sandwich floor applied to the MAIN decrease (token1).
    /// @param amount0MinWithdrawAlt Caller-supplied sandwich floor applied to the ALT decrease (token0).
    /// @param amount1MinWithdrawAlt Caller-supplied sandwich floor applied to the ALT decrease (token1).
    function _exitAll(
        ManagedPositionV2 storage p,
        uint256 amount0MinWithdraw,
        uint256 amount1MinWithdraw,
        uint256 amount0MinWithdrawAlt,
        uint256 amount1MinWithdrawAlt,
        uint256 deadline
    ) private {
        uint256 mainId = p.mainTokenId;
        uint256 altId = p.altTokenId;

        // 1. unstake both legs if staked (auto-claims AERO → feeCollector)
        if (p.mainStaked) _unstakeLeg(p, true);
        if (altId != 0 && p.altStaked) _unstakeLeg(p, false);

        // 2. skim LP fees (pre-decrease) → feeCollector, for each held NFT
        _skimFees(p, mainId);
        if (altId != 0) _skimFees(p, altId);

        // 3. decrease all liquidity + collect principal into this contract.
        //    MAIN gets the caller-supplied withdraw mins (sandwich floor) and the caller-supplied deadline.
        _decreaseLiquidityAll(mainId, amount0MinWithdraw, amount1MinWithdraw, deadline);
        //    ALT is single-sided and transient (minted by _mintAlt in rebalanceUsingAlt() whenever the
        //    post-rebuild surplus leg clears MIN_ALT_VALUE_USD). When an alt persists into the
        //    next cycle, this decrease removes its liquidity, so it gets its own caller-supplied
        //    sandwich floor (the rebalancer cannot know in advance which single leg the alt holds).
        if (altId != 0) _decreaseLiquidityAll(altId, amount0MinWithdrawAlt, amount1MinWithdrawAlt, deadline);

        // 4. burn the old NFTs
        POSITION_MANAGER.burn(mainId);
        if (altId != 0) POSITION_MANAGER.burn(altId);

        // 5. clear the now-dangling ids. exit() and rebalanceUsingAlt overwrite these in the SAME
        //    transaction, but unwindForSwap returns with active == true and no re-mint until
        //    rebuildAfterSwap lands in a LATER transaction — so without this the public `position()`
        //    getter serves BURNED tokenIds to clients for the whole in-flight window. The locals
        //    above already hold what steps 1-4 needed.
        p.mainTokenId = 0;
        p.altTokenId = 0;
    }

    /// @dev Remove all liquidity from `tokenId` and collect the resulting tokens into
    ///      this contract. `amount0Min`/`amount1Min` are the caller-supplied sandwich floor
    ///      enforced by the position manager on the decrease (revert if the withdrawn amounts
    ///      fall below them); pass 0 to skip the floor. `deadline` is forwarded to the PM so the
    ///      caller's deadline guard actually applies to the withdraw leg (not a hardcoded now).
    function _decreaseLiquidityAll(uint256 tokenId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) private {
        LPPositionLib.decreaseLiquidityAll(address(POSITION_MANAGER), tokenId, amount0Min, amount1Min, deadline);
    }

    /// @dev Mint a new balanced `main` position from this contract's current token
    ///      balances. NO SWAP: desired = full balances; the position manager consumes
    ///      only the in-ratio portion and any leftover remains in the contract (forwarded
    ///      to the feeCollector by the caller). Slipstream MintParams: int24 tickSpacing
    ///      + trailing sqrtPriceX96 (0 because the pool is already initialized).
    function _mintBalanced(
        ManagedPositionV2 storage p,
        int24 spotTick,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) private returns (uint256 newTokenId) {
        // _mainRange may return a SINGLE-SIDED range (dust-minority branch): entirely above spot
        // consumes only token0, entirely below only token1 (pool mint semantics on slot0.tick).
        // Zero the unfunded leg's min — mirroring _mintAlt: the caller cannot predict which branch
        // executes, so a nonzero min on the leg that ends up unfunded would revert an otherwise-valid
        // single-sided rebuild. The funded leg keeps the caller-supplied floor.
        if (spotTick < tickLower) amount1Min = 0;
        else if (spotTick >= tickUpper) amount0Min = 0;
        return LPPositionLib.mintPosition(
            address(POSITION_MANAGER),
            p.token0,
            p.token1,
            p.tickSpacing,
            tickLower,
            tickUpper,
            amount0Min,
            amount1Min,
            deadline
        );
    }

    /// @dev Mint the single-sided `alt` from the post-main-mint leftover (NO SWAP). Body lives in
    ///      LPPositionLib.mintAlt (EIP-170 headroom); see its NatSpec for the value-based leg
    ///      selection, the spot-anchored placement, and the "forwards NO dust" contract.
    function _mintAlt(
        ManagedPositionV2 storage p,
        LPValuationLib.OracleConfig memory cfg,
        int24 spotTick,
        uint8 dec0,
        uint8 dec1,
        uint256 amount0MinAlt,
        uint256 amount1MinAlt,
        uint256 deadline
    ) private returns (uint256 altId) {
        return LPPositionLib.mintAlt(
            LPPositionLib.AltParams({
                positionManager: address(POSITION_MANAGER),
                token0: p.token0,
                token1: p.token1,
                holder: address(this),
                spotTick: spotTick,
                tickSpacing: p.tickSpacing,
                dec0: dec0,
                dec1: dec1,
                amount0Min: amount0MinAlt,
                amount1Min: amount1MinAlt,
                deadline: deadline,
                minAltValueUsd: MIN_ALT_VALUE_USD
            }),
            cfg
        );
    }

    // ─── shared private helpers ───────────────────────────────────────────────

    /// @dev Collect any accrued LP fees for `tokenId` (before decreasing liquidity)
    ///      and forward both tokens to the feeCollector.
    function _skimFees(ManagedPositionV2 storage p, uint256 tokenId) private {
        LPPositionLib.skimFees(address(POSITION_MANAGER), p.token0, p.token1, p.feeCollector, tokenId);
    }

    /// @dev Transfer this contract's whole token0/token1 balance to `to`.
    function _sweepPairTo(ManagedPositionV2 storage p, address to) private {
        uint256 d0 = IERC20(p.token0).balanceOf(address(this));
        uint256 d1 = IERC20(p.token1).balanceOf(address(this));
        if (d0 > 0) IERC20(p.token0).safeTransfer(to, d0);
        if (d1 > 0) IERC20(p.token1).safeTransfer(to, d1);
    }

    /// @dev Transfer any residual token0 / token1 balance of this contract to the feeCollector.
    ///      Callers MUST run the value floor first: this is the "genuine sub-threshold remainder"
    ///      hand-off, and running it earlier would let real surplus escape the floor as "dust".
    function _forwardDust(ManagedPositionV2 storage p) private {
        _sweepPairTo(p, p.feeCollector);
    }

    /// @dev The oracle set every valuation runs against: both feeds, their INDEPENDENT staleness
    ///      bounds, and the L2 sequencer-uptime guard. Built once per call site so every leg of a
    ///      before/after comparison is priced under identical rules.
    function _oracleCfg(ManagedPositionV2 storage p) private view returns (LPValuationLib.OracleConfig memory) {
        return LPValuationLib.OracleConfig({
            oracle0: p.oracle0,
            oracle1: p.oracle1,
            maxDelay0: maxOracleDelay0,
            maxDelay1: maxOracleDelay1,
            sequencerUptimeFeed: sequencerUptimeFeed,
            sequencerGracePeriod: sequencerGracePeriod
        });
    }

    /// @dev Raw token amounts backing main + alt principal at `sqrtP`, plus the pre-existing loose
    ///      balance — the swap-rebalance floor's baseline. Oracle-free by construction (see
    ///      SwapWindowLib.Snapshot): pricing happens at rebuild, not here.
    function _snapshotAmounts(ManagedPositionV2 storage p, uint160 sqrtP)
        private
        view
        returns (SwapWindowLib.Snapshot memory s)
    {
        (uint256 m0, uint256 m1) = LPValuationLib.principalAmounts(address(POSITION_MANAGER), p.mainTokenId, sqrtP);
        (uint256 a0, uint256 a1) = LPValuationLib.principalAmounts(address(POSITION_MANAGER), p.altTokenId, sqrtP);
        s.amount0Pos = m0 + a0;
        s.amount1Pos = m1 + a1;
        s.loose0 = IERC20(p.token0).balanceOf(address(this));
        s.loose1 = IERC20(p.token1).balanceOf(address(this));
    }

    /// @dev USD value of this contract's current (non-position) balances of the pair tokens.
    ///      Used by the rebalance value floor to net contract-held balances out of the
    ///      before/after comparison.
    function _contractPairValue(
        ManagedPositionV2 storage p,
        LPValuationLib.OracleConfig memory cfg,
        uint8 dec0,
        uint8 dec1
    ) private view returns (uint256) {
        return LPValuationLib.contractPairValue(p.token0, p.token1, address(this), cfg, dec0, dec1);
    }

    /// @dev USD value of main + alt PRINCIPAL at `sqrtP` (no loose balances). Uses
    ///      LiquidityAmounts to derive token amounts from each NFT's stored liquidity — never
    ///      counts tokensOwed (fees), so skimming fees does not perturb this measurement. A zero
    ///      tokenId contributes 0 (no alt).
    function _positionsValue(
        ManagedPositionV2 storage p,
        LPValuationLib.OracleConfig memory cfg,
        uint160 sqrtP,
        uint8 dec0,
        uint8 dec1
    ) private view returns (uint256) {
        return LPValuationLib.positionsValue(
            address(POSITION_MANAGER), p.mainTokenId, p.altTokenId, sqrtP, cfg, dec0, dec1
        );
    }

    /// @dev Total USD value the rebalance value-floor's "after" side counts: main + alt principal,
    ///      plus any loose token0/token1 held by this contract. Shared by rebalanceUsingAlt and the
    ///      swap-rebalance rebuild floor.
    function _totalValue(
        ManagedPositionV2 storage p,
        LPValuationLib.OracleConfig memory cfg,
        uint160 sqrtP,
        uint8 dec0,
        uint8 dec1
    ) private view returns (uint256) {
        return LPValuationLib.totalValue(
            address(POSITION_MANAGER),
            p.mainTokenId,
            p.altTokenId,
            sqrtP,
            p.token0,
            p.token1,
            address(this),
            cfg,
            dec0,
            dec1
        );
    }

    /// @notice Collect accrued LP fees for an unstaked position and forward to feeCollector.
    ///         Permissionless — anyone may call. Reverts if the position is staked (use claimEmissions).
    function collectFees() external whenNotPaused nonReentrant {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        // Mid-swap-rebalance there is nothing to collect: unwindForSwap burned both NFTs and zeroed
        // both ids (_exitAll step 5), and rebuildAfterSwap does not re-mint until a LATER transaction
        // (same window getDecisionSnapshot guards). Without this, _skimFees would run collect() on
        // tokenId 0 and revert deep inside the position manager; mainStaked is already false here, so
        // no other guard catches it. Fail fast with a clear error instead.
        if (_window.inFlight) revert AlreadyInFlight();
        if (p.mainStaked) revert AlreadyStaked(); // staked => fees accrue to the gauge; use claimEmissions
        // Skim BOTH legs to the feeCollector via the shared helper. Ignoring the alt here would strand
        // its accrued fees. Reuses _skimFees rather than duplicating the collect+forward logic.
        _skimFees(p, p.mainTokenId);
        if (p.altTokenId != 0) _skimFees(p, p.altTokenId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // View — decision snapshot
    // ═══════════════════════════════════════════════════════════════════════

    struct DecisionSnapshotV2 {
        int24 spotTick;
        int24 twapTick;
        int24 mainTickLower;
        int24 mainTickUpper;
        bool mainInRange;
        int24 altTickLower;
        int24 altTickUpper;
        bool hasAlt;
        uint128 mainLiquidity;
        uint128 altLiquidity;
        bool mainStaked;
        bool hasGauge;
        uint256 earnedAero;
        uint256 cooldownRemaining;
        bool deviationGateOpen;
        bool rebalanceInFlight;
        uint256 rebalanceStartedAt;
    }

    /// @notice Return a snapshot of the fields the off-chain rebalancer reads to decide
    ///         whether and how to rebalanceUsingAlt a position. All values are read atomically in one
    ///         call. The `earnedAero` field uses try/catch so a broken gauge never blocks the view.
    /// @dev    Mid-swap-rebalance (rebalanceInFlight), unwindForSwap has already burned both NFTs and
    ///         zeroed both ids (_exitAll step 5); nothing is re-minted until rebuildAfterSwap lands in
    ///         a LATER transaction. POSITION_MANAGER.positions() reverts on the real position manager
    ///         for tokenId 0 just as it does for a burned id, so the geometry reads would revert
    ///         either way — the main/alt geometry + gauge-earned reads are SKIPPED while in flight (both legs
    ///         are already unstaked by unwindForSwap's teardown, so mainStaked/altStaked read false
    ///         here regardless). This keeps the view itself always callable — the off-chain agent
    ///         must be able to observe rebalanceInFlight/rebalanceStartedAt precisely when a rebalance
    ///         is in flight, not have its primary read-path revert for the whole window.
    function getDecisionSnapshot() external view returns (DecisionSnapshotV2 memory s) {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();

        (, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
        int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);

        s.spotTick = spotTick;
        s.twapTick = twapTick;

        bool inFlight = _window.inFlight;
        if (!inFlight) {
            // Tuple decodes and the gauge try/catch live in LPPositionLib (EIP-170 headroom).
            (s.mainTickLower, s.mainTickUpper, s.mainLiquidity) =
                LPPositionLib.positionTicks(address(POSITION_MANAGER), p.mainTokenId);
            s.mainInRange = s.mainTickLower <= spotTick && spotTick < s.mainTickUpper;
            s.hasAlt = p.altTokenId != 0;
            if (s.hasAlt) {
                (s.altTickLower, s.altTickUpper, s.altLiquidity) =
                    LPPositionLib.positionTicks(address(POSITION_MANAGER), p.altTokenId);
            }
            s.mainStaked = p.mainStaked;
            s.hasGauge = p.gauge != address(0);
            s.earnedAero = LPPositionLib.earnedTolerant(
                p.gauge, address(this), p.mainTokenId, p.mainStaked, p.altTokenId, p.altStaked
            );
        }

        uint256 ready = p.lastRebalance + p.minRebalanceInterval;
        s.cooldownRemaining = block.timestamp >= ready ? 0 : ready - block.timestamp;
        int24 dev = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        s.deviationGateOpen = dev <= p.maxTickDeviation;
        s.rebalanceInFlight = inFlight;
        s.rebalanceStartedAt = _window.startedAt;
    }

    /// @notice EIP-1271 passthrough. The balancer is the CowSwap order owner (tokens pulled
    ///         from / delivered to it); all validation logic lives on the compound module.
    /// @dev    `whenNotPaused` is load-bearing, not decoration. unwindForSwap leaves a live
    ///         VAULT_RELAYER allowance on the sell token, and pause() does not revoke it — so
    ///         without this check a solver could settle a principal-moving order while the guardian
    ///         has the contract paused, i.e. pause could not stop an in-flight swap. Safe on a view
    ///         function: Pausable._requireNotPaused() is itself view.
    function isValidSignature(bytes32 digest, bytes calldata order) external view whenNotPaused returns (bytes4) {
        return ILPCompoundModuleRebalance(compoundModule).validateRebalanceOrder(digest, order);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Token recovery
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Recover accidentally-sent ERC-20 tokens.
    function recoverERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRecovered(token, to, amount);
    }

    /// @notice Recover accidentally-sent ETH.
    function recoverETH(address payable to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert EthTransferFailed();
        emit TokensRecovered(address(0), to, bal);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Pick the new main range from this contract's current (post-withdraw) balances. Body
    ///      lives in LPValuationLib.mainRange (EIP-170 headroom); see its NatSpec for the
    ///      straddle-vs-single-sided classifier, the placement rules, and the center-deviation guard.
    ///      Both-empty is impossible here: rebalanceUsingAlt withdrew real principal, and an empty
    ///      teardown would already have reverted the value floor downstream.
    function _mainRange(
        ManagedPositionV2 storage p,
        LPValuationLib.OracleConfig memory cfg,
        int24 spotTick,
        uint24 width,
        uint8 dec0,
        uint8 dec1
    ) private view returns (int24 tickLower, int24 tickUpper) {
        return LPValuationLib.mainRange(
            LPValuationLib.RangeParams({
                token0: p.token0,
                token1: p.token1,
                holder: address(this),
                spotTick: spotTick,
                width: width,
                tickSpacing: p.tickSpacing,
                maxCenterDeviation: p.maxCenterDeviation,
                minMainLegUsd: MIN_MAIN_LEG_USD,
                dec0: dec0,
                dec1: dec1
            }),
            cfg
        );
    }

    /// @dev Consult the pool's TWAP oracle and return the time-weighted average tick
    ///      over `window` seconds. Division is floored toward −∞ (matches OracleLibrary.consult).
    function _consultTwapTick(address pool, uint32 window) internal view returns (int24) {
        return LPGeometryLib.consultTwapTick(pool, window);
    }

    /// @dev Read a Chainlink-style price feed and validate the L2 sequencer, then freshness and
    ///      positivity. Reverts StaleOracle if the answer is non-positive or the feed is stale
    ///      against `delay` — which is THAT feed's own bound, never a shared one.
    function _readFeed(address feed, uint256 delay) internal view returns (uint256 price, uint8 decimals) {
        return LPValuationLib.readFeed(feed, delay, sequencerUptimeFeed, sequencerGracePeriod);
    }

    /// @dev Shared value-floor gate for both rebalance paths (H-1); body in
    ///      LPValuationLib.enforceValueFloor (EIP-170 headroom). The haircut is
    ///      (maxRebalanceLossBps + extraBps) of the POSITION principal only; `looseBefore` is added
    ///      back un-haircut. `extraBps` carries swapLossAllowanceBps on the swap-rebuild path and 0
    ///      on rebalanceUsingAlt. Both terms are admin-capped (MAX_LOSS_CAP_BPS +
    ///      MAX_SWAP_LOSS_ALLOWANCE_BPS = 1000 bps), so `10_000 - lossBps` cannot underflow.
    function _enforceValueFloor(uint256 valueBeforePos, uint256 looseBefore, uint256 valueAfter, uint16 extraBps)
        private
        view
    {
        LPValuationLib.enforceValueFloor(
            valueBeforePos, looseBefore, valueAfter, uint256(position.maxRebalanceLossBps) + extraBps
        );
    }

    /// @dev Validate all fields of `config` and store them via `_store`.
    ///      Shared by registerPosition and setPool — the validation body is moved here verbatim so
    ///      both entry points exercise identical checks.
    function _validateAndStore(ManagedPositionV2 calldata config) private {
        if (config.pool == address(0) || config.token0 == address(0) || config.token1 == address(0)) {
            revert InvalidConfig();
        }
        if (config.oracle0 == address(0) || config.oracle1 == address(0)) revert OracleRequired();
        // feeCollector must be non-zero: every AERO/fee/dust transfer (incl. the emergency exit()
        // when staked with pending AERO) safeTransfers to it and would revert on address(0).
        // setFeeCollector already guards this — mirror it here so a bad config can't be stored.
        if (config.feeCollector == address(0)) revert ZeroAddress();
        // AERO must never be an underlying: the compound module's isValidSignature relies on AERO
        // being excluded from {token0, token1} to keep AERO-compound orders and principal-rebalance
        // orders (validateRebalanceOrder) structurally disjoint. Enforced here rather than left as an
        // unstated assumption, since a future AERO-paired pool would otherwise silently break that
        // separation.
        if (config.token0 == AERO || config.token1 == AERO) revert InvalidConfig();
        // Probe both feeds now so a wrong address fails in the admin tx (Safe simulation),
        // not as a StaleOracle revert on the next rebalance.
        _readFeed(config.oracle0, maxOracleDelay0);
        _readFeed(config.oracle1, maxOracleDelay1);
        // Loss cap, calm-gate/centering presence, and the width invariants — shared verbatim with
        // setPositionConfig via LPPositionLib.validateRebalanceConfig (see its NatSpec).
        LPPositionLib.validateRebalanceConfig(
            config.minWidth,
            config.maxWidth,
            config.maxCenterDeviation,
            config.twapWindow,
            config.maxTickDeviation,
            config.maxRebalanceLossBps,
            MAX_LOSS_CAP_BPS,
            config.tickSpacing
        );
        // Gauge reward-token + gauge->pool binding, shared with setGauge (LPPositionLib.validateGauge)
        // so the registration and post-registration admin paths enforce the same invariant.
        LPPositionLib.validateGauge(config.gauge, config.pool, AERO);
        // Pool-descriptor cross-validation + NFT ownership/binding, extracted to LPPositionLib for
        // EIP-170 headroom (see validatePoolAndNft's NatSpec for the full invariants).
        LPPositionLib.validatePoolAndNft(
            config.pool, address(POSITION_MANAGER), config.mainTokenId, config.token0, config.token1, config.tickSpacing
        );

        _store(config);
    }

    /// @dev Copy `config` into `position`, then force the derived fields:
    ///      `altTokenId = 0`, `mainStaked = false`, `altStaked = false`, `lastRebalance = 0`,
    ///      `active = true`. The whole-struct assignment is deliberate — a field-by-field copy of a
    ///      21-field struct costs the balancer bytecode it does not have, and it silently drops any
    ///      field added later, whereas this cannot.
    function _store(ManagedPositionV2 calldata config) private {
        position = config;
        ManagedPositionV2 storage p = position;
        p.altTokenId = 0;
        p.mainStaked = false;
        p.altStaked = false;
        p.lastRebalance = 0;
        p.active = true;
    }
}
