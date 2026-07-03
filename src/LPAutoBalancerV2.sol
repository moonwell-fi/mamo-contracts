// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";

import {LPBalancerLib} from "@libraries/LPBalancerLib.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";

/// @title LPAutoBalancerV2
/// @notice Safe-governed, single-position Aerodrome CL rebalancer. Holds position NFTs,
///         re-ranges them with on-chain-computed ticks, stakes for AERO emissions, and
///         skims fees/emissions to the weekly drop. See docs/superpowers/specs/2026-06-01-lp-auto-balancer-design.md
contract LPAutoBalancerV2 is AccessControlEnumerable, ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_LOSS_CAP_BPS = 500;

    /// @notice Caps the per-call compound percentage; also guards `BPS_DENOMINATOR - compoundBps`
    ///         from underflow. Equals BPS_DENOMINATOR (100%).
    uint16 public constant MAX_COMPOUND_BPS = 10_000;

    /// @notice Minimum USD value of the surplus leg required to mint the single-sided alt.
    ///         Scale is 8-decimal USD (Chainlink convention), the same scale `_valueInUsd`
    ///         returns. Below this the leftover is treated as dust and forwarded to the
    ///         feeCollector instead — a sub-tick remainder too small to seed a position would
    ///         revert the mint or round to zero liquidity. MUST be a USD threshold, never raw
    ///         base units: the phase-1 pair is WETH (18-dec) / cbBTC (8-dec), so a flat raw
    ///         threshold means wildly different USD amounts per leg. 1e6 = $0.01.
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

    uint256 public maxOracleDelay;

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

    error ZeroAddress();
    error TwapDeviation();
    error StaleOracle();
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

    event PositionRegistered(address indexed pool, uint256 indexed tokenId);
    event PoolChanged(address indexed pool, uint256 indexed mainTokenId);
    event PositionDeregistered(address indexed to);
    event PositionWithdrawn(address indexed to);
    event PositionConfigUpdated();
    event FeeCollectorUpdated(address feeCollector);
    event OraclesUpdated(address oracle0, address oracle1);
    event GaugeUpdated(address gauge);
    event MaxOracleDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event Staked(uint256 indexed tokenId, address gauge);
    event Unstaked(uint256 indexed tokenId, address gauge);
    event EmissionsClaimed(uint256 amount);
    event CompoundModuleUpdated(address module);
    event CompoundInitiated(uint256 compoundAmount, uint256 droppedAmount, uint16 compoundBps);
    event FeesSkimmed(uint256 amount0, uint256 amount1);
    event RebalancedUsingAlt(uint256 mainTokenId, uint256 altTokenId, int24 tickLower, int24 tickUpper);

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
        maxOracleDelay = 26 hours;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(POSITION_MANAGER), "Only position manager");
        return this.onERC721Received.selector;
    }

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
    function deregisterPosition(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        if (to == address(0)) revert ZeroAddress();
        if (p.mainStaked || p.altStaked) revert PositionStaked();
        uint256 tokenId = p.mainTokenId;
        p.active = false; // effects before interaction (CEI)
        emit PositionDeregistered(to);
        if (p.altTokenId != 0) POSITION_MANAGER.safeTransferFrom(address(this), to, p.altTokenId);
        POSITION_MANAGER.safeTransferFrom(address(this), to, tokenId); // interaction last
    }

    /// @notice Emergency withdraw: auto-unstakes both legs (if staked) then transfers the NFT(s)
    ///         to `to`. Allows an admin to rescue a position in one call regardless of staking state.
    function withdrawPosition(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        if (to == address(0)) revert ZeroAddress();
        if (p.mainStaked) _unstake(p); // auto-claims AERO -> feeCollector, returns NFT to this contract
        if (p.altStaked) _unstakeAlt(p); // unstake the alt before transferring it
        uint256 tokenId = p.mainTokenId;
        p.active = false; // effects before interaction (CEI)
        emit PositionWithdrawn(to);
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
        if (maxRebalanceLossBps > MAX_LOSS_CAP_BPS) revert LossCapExceeded();
        if (twapWindow == 0 || maxTickDeviation <= 0) revert InvalidConfig();
        if (maxCenterDeviation == 0) revert InvalidConfig();
        int24 spacing = position.tickSpacing;
        // minWidth must be at least 2*tickSpacing so a balanced rebalanceUsingAlt can straddle an aligned spot.
        if (minWidth < 2 * uint24(spacing) || maxWidth < minWidth) revert WidthTooNarrow();
        if (minWidth % uint24(spacing) != 0 || maxWidth % uint24(spacing) != 0) revert InvalidWidth();

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
        _readFeed(oracle0); // probe: fail in the admin tx, not on the next rebalance
        _readFeed(oracle1);
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
        // A non-zero gauge must reward in AERO or staked emissions would be stranded.
        if (gauge != address(0) && ICLGauge(gauge).rewardToken() != AERO) revert GaugeRewardMismatch();
        position.gauge = gauge;
        emit GaugeUpdated(gauge);
    }

    /// @notice Update the maximum acceptable oracle staleness.
    function setMaxOracleDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDelay == 0 || newDelay > 7 days) revert InvalidConfig();
        uint256 old = maxOracleDelay;
        maxOracleDelay = newDelay;
        emit MaxOracleDelayUpdated(old, newDelay);
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
    function stake() external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        if (p.gauge == address(0)) revert NoGauge();
        if (p.mainStaked) revert AlreadyStaked();
        POSITION_MANAGER.approve(p.gauge, p.mainTokenId);
        ICLGauge(p.gauge).deposit(p.mainTokenId);
        p.mainStaked = true;
        if (p.altTokenId != 0) {
            POSITION_MANAGER.approve(p.gauge, p.altTokenId);
            ICLGauge(p.gauge).deposit(p.altTokenId);
            p.altStaked = true;
        }
        emit Staked(p.mainTokenId, p.gauge);
    }

    /// @notice Withdraw the position NFT(s) from the gauge and skim any AERO to the fee collector.
    ///         Unstakes the main NFT always; also unstakes the alt NFT when altStaked && altTokenId != 0.
    function unstake() external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
        ManagedPositionV2 storage p = position;
        if (!p.mainStaked) revert NotStaked();
        _unstake(p);
        if (p.altStaked && p.altTokenId != 0) _unstakeAlt(p);
    }

    /// @dev Internal unstake: withdraw from gauge (auto-claims AERO), set mainStaked=false,
    ///      then skim any AERO balance to the fee collector (CEI: state update before AERO transfer).
    function _unstake(ManagedPositionV2 storage p) internal {
        // Measure only the AERO GAINED by this withdraw so we never sweep a stray AERO
        // balance sitting on this contract.
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        ICLGauge(p.gauge).withdraw(p.mainTokenId); // returns NFT + auto-claims AERO
        p.mainStaked = false; // CEI: effect before interaction (AERO transfer below)
        uint256 aeroEarned = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        if (aeroEarned > 0) {
            IERC20(AERO).safeTransfer(p.feeCollector, aeroEarned);
            emit EmissionsClaimed(aeroEarned);
        }
        emit Unstaked(p.mainTokenId, p.gauge);
    }

    /// @dev Internal unstake for the ALT leg: withdraw the alt NFT from the gauge
    ///      (auto-claims AERO), set altStaked=false, then skim only the AERO gained by
    ///      this withdraw to the feeCollector (CEI: state update before AERO transfer).
    function _unstakeAlt(ManagedPositionV2 storage p) internal {
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        ICLGauge(p.gauge).withdraw(p.altTokenId); // returns NFT + auto-claims AERO
        p.altStaked = false; // CEI: effect before interaction (AERO transfer below)
        uint256 aeroEarned = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        if (aeroEarned > 0) {
            IERC20(AERO).safeTransfer(p.feeCollector, aeroEarned);
            emit EmissionsClaimed(aeroEarned);
        }
        emit Unstaked(p.altTokenId, p.gauge);
    }

    /// @notice Emergency exit: unstake (skimming AERO to feeCollector), collect fees, remove all
    ///         liquidity, burn both NFTs, and transfer the resulting token0/token1 balances to `to`.
    ///         Marks the position inactive. Use when the Safe needs to fully tear down a position in one
    ///         call regardless of staking state. Uses 0 sandwich mins (emergency path).
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

        // Interactions: unstake (AERO → feeCollector), skim fees, decreaseAll + collect, burn NFTs.
        // Emergency path: 0 mins on both legs, deadline = block.timestamp (execute immediately).
        _exitAll(p, 0, 0, 0, 0, block.timestamp);

        // Transfer all principal recovered from the position to `to`.
        uint256 bal0 = IERC20(p.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(p.token1).balanceOf(address(this));
        if (bal0 > 0) IERC20(p.token0).safeTransfer(to, bal0);
        if (bal1 > 0) IERC20(p.token1).safeTransfer(to, bal1);

        // Bookkeeping: zero NFT references now that _exitAll has consumed and burned them.
        p.mainTokenId = 0;
        p.altTokenId = 0;

        emit PositionWithdrawn(to);
    }

    /// @notice Claim AERO emissions from the gauge for a staked position and forward to feeCollector.
    ///         Claims from both main and alt (if altStaked && altTokenId != 0).
    ///         Permissionless — anyone may call to trigger the skim.
    function claimEmissions() external whenNotPaused nonReentrant {
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

        uint256 dropAmount = FullMath.mulDiv(aero, BPS_DENOMINATOR - compoundBps, BPS_DENOMINATOR);
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
    }

    /// @notice Tear down both positions and rebuild ONLY the balanced `main` from the
    ///         withdrawn principal — NO SWAP. V2 has no swap router/quoter, so the
    ///         position is reconstituted purely from the tokens the position manager
    ///         returns on withdraw; nothing is sold. The single-sided alt is added in Task 3.
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

        (uint160 sqrtP, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
        int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);
        _checkDeviation(spotTick, twapTick, p.maxTickDeviation);

        uint8 dec0 = IERC20Metadata(p.token0).decimals();
        uint8 dec1 = IERC20Metadata(p.token1).decimals();

        // value BEFORE: both positions' principal at the current sqrtP snapshot, PLUS any loose
        // token0/token1 ALREADY held by this contract (donated, or leftover from a prior reverted
        // flow). This MUST be read BEFORE _exitAll withdraws principal into the contract, so it
        // captures only the genuinely pre-existing balance — not post-withdraw principal. valueAfter
        // also counts loose balances (_contractPairValue), so a stray/donated balance cancels on both
        // sides and cannot inflate the floor's headroom to mask a real rebalance loss (H-1).
        uint256 looseBefore = _contractPairValue(p, dec0, dec1);
        // valueBeforePos is POSITION principal only (main + alt). The loss haircut below applies to
        // this alone — never to looseBefore. A donated loose balance is added UNHAIRCUT to the floor's
        // RHS instead (see the value-floor gate), so a donation cannot widen the loss tolerance.
        uint256 valueBeforePos = _principalValue(p, p.mainTokenId, sqrtP, dec0, dec1) + _altValue(p, sqrtP, dec0, dec1);

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

        // Choose the new main range. The common case is a spot-centered straddle. But a rebalanceUsingAlt of a
        // FULLY out-of-range position withdraws 100%-single-sided principal (a CL position outside
        // its range holds exactly one token). A straddling balanced mint with one desired leg == 0
        // computes ZERO liquidity and the position manager reverts. With NO SWAP we cannot
        // manufacture the missing leg, so in that degenerate case we place the main entirely on the
        // FUNDED side, adjacent to spot — a valid single-sided main that waits for price to oscillate
        // back into balance (Beefy "never sell"). Principal is fully redeployed; nothing is sold.
        (int24 tl, int24 tu) = _mainRange(p, spotTick, params.width, dec0, dec1);

        uint256 newMain = _mintBalanced(p, tl, tu, params);
        p.mainTokenId = newMain;
        p.altStaked = false; // freshly minted, not yet staked (restaked below iff wasStaked)
        p.mainStaked = false; // freshly minted, not yet staked (restaked below iff wasStaked)
        p.lastRebalance = block.timestamp;

        // Mint the single-sided alt from the post-mint leftover (NO SWAP). _mintAlt selects the
        // surplus leg by USD VALUE, returns 0 (minting nothing) when the surplus is below
        // MIN_ALT_VALUE_USD, and — critically — does NOT forward dust. The value floor below must
        // see all value the contract controls BEFORE anything is shipped out as "dust".
        // Set altTokenId BEFORE the value-floor read so _altValue sees the new alt.
        p.altTokenId = _mintAlt(p, tl, tu, dec0, dec1, params);

        // value AFTER: new main principal + alt principal at the same sqrtP snapshot, PLUS the
        // USD value of any loose token0/token1 still held by this contract (_contractPairValue).
        // Counting the loose balance is the key invariant: a non-trivial surplus cannot escape the
        // floor by being forwarded as "dust" — if it's real value it is either in the alt (counted)
        // or loose (counted) at floor time. Only sub-threshold dust leaves, and only AFTER this check.
        uint256 valueAfter = _principalValue(p, p.mainTokenId, sqrtP, dec0, dec1) + _altValue(p, sqrtP, dec0, dec1)
            + _contractPairValue(p, dec0, dec1);
        // Haircut applies to POSITION value only; the pre-existing loose balance is added back UNHAIRCUT.
        // looseAfter (in valueAfter) ≈ looseBefore + withdrawn surplus, so the donated L cancels on both
        // sides and cannot inflate headroom to mask a real principal loss (H-1).
        if (
            valueAfter
                < FullMath.mulDiv(valueBeforePos, BPS_DENOMINATOR - p.maxRebalanceLossBps, BPS_DENOMINATOR)
                    + looseBefore
        ) {
            revert ValueFloor();
        }

        // Floor passed: only NOW forward the genuine sub-threshold remainder to the feeCollector.
        _forwardDust(p);

        if (wasStaked && p.gauge != address(0)) {
            POSITION_MANAGER.approve(p.gauge, newMain);
            ICLGauge(p.gauge).deposit(newMain);
            p.mainStaked = true;
            emit Staked(newMain, p.gauge);
            // Stake the freshly minted alt too. Otherwise the alt is stranded unstaked: once the
            // main is staked, stake() reverts AlreadyStaked and collectFees() reverts AlreadyStaked,
            // so the alt's AERO emissions and LP fees could never be collected until the next rebalanceUsingAlt.

            if (p.altTokenId != 0) {
                POSITION_MANAGER.approve(p.gauge, p.altTokenId);
                ICLGauge(p.gauge).deposit(p.altTokenId);
                p.altStaked = true;
                emit Staked(p.altTokenId, p.gauge);
            }
        }

        emit RebalancedUsingAlt(newMain, p.altTokenId, tl, tu);
    }

    // ─── rebalanceUsingAlt private helpers ────────────────────────────────────────────────

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
        if (p.mainStaked) _unstake(p);
        if (altId != 0 && p.altStaked) _unstakeAlt(p);

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
    }

    /// @dev Remove all liquidity from `tokenId` and collect the resulting tokens into
    ///      this contract. `amount0Min`/`amount1Min` are the caller-supplied sandwich floor
    ///      enforced by the position manager on the decrease (revert if the withdrawn amounts
    ///      fall below them); pass 0 to skip the floor. `deadline` is forwarded to the PM so the
    ///      caller's deadline guard actually applies to the withdraw leg (not a hardcoded now).
    function _decreaseLiquidityAll(uint256 tokenId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) private {
        (,,,,,,, uint128 liq,,,,) = POSITION_MANAGER.positions(tokenId);
        if (liq > 0) {
            POSITION_MANAGER.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liq, amount0Min: amount0Min, amount1Min: amount1Min, deadline: deadline
                })
            );
        }
        POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
    }

    /// @dev Mint a new balanced `main` position from this contract's current token
    ///      balances. NO SWAP: desired = full balances; the position manager consumes
    ///      only the in-ratio portion and any leftover remains in the contract (forwarded
    ///      to the feeCollector by the caller). Slipstream MintParams: int24 tickSpacing
    ///      + trailing sqrtPriceX96 (0 because the pool is already initialized).
    function _mintBalanced(
        ManagedPositionV2 storage p,
        int24 tickLower,
        int24 tickUpper,
        RebalanceParams calldata params
    ) private returns (uint256 newTokenId) {
        uint256 bal0 = IERC20(p.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(p.token1).balanceOf(address(this));

        IERC20(p.token0).forceApprove(address(POSITION_MANAGER), bal0);
        IERC20(p.token1).forceApprove(address(POSITION_MANAGER), bal1);

        ICLPositionManager.MintParams memory mp = ICLPositionManager.MintParams({
            token0: p.token0,
            token1: p.token1,
            tickSpacing: p.tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: bal0,
            amount1Desired: bal1,
            amount0Min: params.amount0MinMain,
            amount1Min: params.amount1MinMain,
            recipient: address(this),
            deadline: params.deadline,
            sqrtPriceX96: 0 // pool already initialized
        });
        (newTokenId,,,) = ICLPositionManager(address(POSITION_MANAGER)).mint(mp);
    }

    /// @dev Mint a single-sided `alt` position from the post-main-mint leftover (NO SWAP). The
    ///      surplus leg is whichever token holds the most USD VALUE (NOT raw base units) — the
    ///      legs may have different decimals (phase-1 pair: WETH 18-dec / cbBTC 8-dec), so comparing
    ///      raw balances would almost always pick the higher-decimal leg regardless of real value.
    ///      The surplus leg is parked in a one-tickSpacing-wide range that holds ONLY that token, so
    ///      no swap is needed. Returns 0 (minting nothing) when the surplus leg's USD value is below
    ///      MIN_ALT_VALUE_USD — a sub-tick remainder too small to seed liquidity.
    ///
    ///      NOTE: this function does NOT forward dust. The caller (`rebalanceUsingAlt`) must run the value floor
    ///      AFTER this returns — counting both the freshly minted alt and any loose contract balance
    ///      via `_contractPairValue` — and only THEN forward the genuine sub-threshold remainder.
    ///      Forwarding here would let a non-trivial surplus escape the floor as "dust".
    ///
    ///      Orientation (Slipstream/Uniswap: price = token1/token0, ticks increase with price):
    ///      a range strictly ABOVE spot holds only token0; strictly BELOW holds only token1
    ///      (see LiquidityAmounts.getAmountsForLiquidity branches). Therefore:
    ///        - token0 surplus => range ABOVE the main upper:  [mainTu, mainTu + tickSpacing]
    ///        - token1 surplus => range BELOW the main lower:  [mainTl - tickSpacing, mainTl]
    function _mintAlt(
        ManagedPositionV2 storage p,
        int24 mainTl,
        int24 mainTu,
        uint8 dec0,
        uint8 dec1,
        RebalanceParams calldata params
    ) private returns (uint256 altId) {
        uint256 bal0 = IERC20(p.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(p.token1).balanceOf(address(this));

        // Value each leg in USD (8-decimal scale) from its own oracle. Pass the other amount as 0
        // so each call values exactly one leg. Selection is by USD value, never raw base units.
        uint256 value0 = _valueInUsd(bal0, 0, p.oracle0, p.oracle1, dec0, dec1);
        uint256 value1 = _valueInUsd(0, bal1, p.oracle0, p.oracle1, dec0, dec1);

        bool surplus0 = value0 >= value1;
        uint256 surplusValue = surplus0 ? value0 : value1;
        if (surplusValue < MIN_ALT_VALUE_USD) {
            return 0; // genuine dust: caller forwards it after the value floor.
        }

        int24 altTl;
        int24 altTu;
        if (surplus0) {
            altTl = mainTu;
            altTu = mainTu + p.tickSpacing;
        } else {
            altTu = mainTl;
            altTl = mainTl - p.tickSpacing;
        }

        // The alt is single-sided: a range strictly above spot consumes ONLY token0, strictly below
        // ONLY token1. Force the unfunded leg's min to 0 — the caller cannot predict which leg the
        // surplus lands on (selection is by USD value at execution time), so a nonzero min on the
        // leg that ends up unfunded would revert an otherwise-valid mint. Only the funded leg keeps
        // the caller-supplied floor.
        uint256 altAmount0Min = surplus0 ? params.amount0MinAlt : 0;
        uint256 altAmount1Min = surplus0 ? 0 : params.amount1MinAlt;

        IERC20(p.token0).forceApprove(address(POSITION_MANAGER), bal0);
        IERC20(p.token1).forceApprove(address(POSITION_MANAGER), bal1);

        ICLPositionManager.MintParams memory mp = ICLPositionManager.MintParams({
            token0: p.token0,
            token1: p.token1,
            tickSpacing: p.tickSpacing,
            tickLower: altTl,
            tickUpper: altTu,
            amount0Desired: bal0,
            amount1Desired: bal1,
            amount0Min: altAmount0Min,
            amount1Min: altAmount1Min,
            recipient: address(this),
            deadline: params.deadline,
            sqrtPriceX96: 0 // pool already initialized
        });
        (altId,,,) = ICLPositionManager(address(POSITION_MANAGER)).mint(mp);
    }

    // ─── shared private helpers ───────────────────────────────────────────────

    /// @dev Collect any accrued LP fees for `tokenId` (before decreasing liquidity)
    ///      and forward both tokens to the feeCollector.
    function _skimFees(ManagedPositionV2 storage p, uint256 tokenId) private {
        (uint256 a0, uint256 a1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        if (a0 > 0) IERC20(p.token0).safeTransfer(p.feeCollector, a0);
        if (a1 > 0) IERC20(p.token1).safeTransfer(p.feeCollector, a1);
        emit FeesSkimmed(a0, a1);
    }

    /// @dev Transfer residual balances of t0 and t1 to `to`.
    function _forwardDustTokens(address t0, address t1, address to) private {
        uint256 d0 = IERC20(t0).balanceOf(address(this));
        uint256 d1 = IERC20(t1).balanceOf(address(this));
        if (d0 > 0) IERC20(t0).safeTransfer(to, d0);
        if (d1 > 0) IERC20(t1).safeTransfer(to, d1);
    }

    /// @dev Transfer any residual token0 / token1 balance of this contract to the feeCollector.
    function _forwardDust(ManagedPositionV2 storage p) private {
        _forwardDustTokens(p.token0, p.token1, p.feeCollector);
    }

    /// @dev USD value of this contract's current (non-position) balances of the pair tokens.
    ///      Used by the rebalance value floor to net contract-held balances out of the
    ///      before/after comparison.
    function _contractPairValue(ManagedPositionV2 storage p, uint8 dec0, uint8 dec1) private view returns (uint256) {
        return _valueInUsd(
            IERC20(p.token0).balanceOf(address(this)),
            IERC20(p.token1).balanceOf(address(this)),
            p.oracle0,
            p.oracle1,
            dec0,
            dec1
        );
    }

    /// @dev Compute the USD value of the principal tokens locked in `tokenId`,
    ///      valued at the given sqrtP (Q64.96 sqrt price). Uses LiquidityAmounts to
    ///      derive token amounts from the NFT's stored liquidity — never counts tokensOwed
    ///      (fees), so skimming fees does not perturb this measurement.
    ///      Returns 0 for tokenId == 0 (no position), used by _altValue when there is no alt.
    function _principalValue(ManagedPositionV2 storage p, uint256 tokenId, uint160 sqrtP, uint8 dec0, uint8 dec1)
        private
        view
        returns (uint256)
    {
        if (tokenId == 0) return 0;
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = POSITION_MANAGER.positions(tokenId);
        (uint256 a0, uint256 a1) = LPBalancerLib.amountsForLiquidityAtTicks(sqrtP, tl, tu, liq);
        return _valueInUsd(a0, a1, p.oracle0, p.oracle1, dec0, dec1);
    }

    /// @dev USD value of the alt position principal at `sqrtP`; 0 when there is no alt.
    function _altValue(ManagedPositionV2 storage p, uint160 sqrtP, uint8 dec0, uint8 dec1)
        private
        view
        returns (uint256)
    {
        return _principalValue(p, p.altTokenId, sqrtP, dec0, dec1);
    }

    /// @notice Collect accrued LP fees for an unstaked position and forward to feeCollector.
    ///         Permissionless — anyone may call. Reverts if the position is staked (use claimEmissions).
    function collectFees() external whenNotPaused nonReentrant {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
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
    }

    /// @notice Return a snapshot of the fields the off-chain rebalancer reads to decide
    ///         whether and how to rebalanceUsingAlt a position. All values are read atomically in one
    ///         call. The `earnedAero` field uses try/catch so a broken gauge never blocks the view.
    function getDecisionSnapshot() external view returns (DecisionSnapshotV2 memory s) {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();

        (, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
        int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);
        (,,,,, int24 mtl, int24 mtu, uint128 mliq,,,,) = POSITION_MANAGER.positions(p.mainTokenId);

        s.spotTick = spotTick;
        s.twapTick = twapTick;
        s.mainTickLower = mtl;
        s.mainTickUpper = mtu;
        s.mainInRange = mtl <= spotTick && spotTick < mtu;
        s.mainLiquidity = mliq;
        s.hasAlt = p.altTokenId != 0;
        if (s.hasAlt) {
            (,,,,, int24 atl, int24 atu, uint128 aliq,,,,) = POSITION_MANAGER.positions(p.altTokenId);
            s.altTickLower = atl;
            s.altTickUpper = atu;
            s.altLiquidity = aliq;
        }
        s.mainStaked = p.mainStaked;
        s.hasGauge = p.gauge != address(0);

        uint256 aero;
        if (p.mainStaked) {
            try ICLGauge(p.gauge).earned(address(this), p.mainTokenId) returns (uint256 e) {
                aero += e;
            } catch {}
        }
        if (p.altStaked && p.altTokenId != 0) {
            try ICLGauge(p.gauge).earned(address(this), p.altTokenId) returns (uint256 e) {
                aero += e;
            } catch {}
        }
        s.earnedAero = aero;

        uint256 ready = p.lastRebalance + p.minRebalanceInterval;
        s.cooldownRemaining = block.timestamp >= ready ? 0 : ready - block.timestamp;
        int24 dev = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        s.deviationGateOpen = dev <= p.maxTickDeviation;
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
        require(ok, "ETH transfer failed");
        emit TokensRecovered(address(0), to, bal);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Round `tick` down to the nearest multiple of `spacing`, toward −∞.
    ///      Solidity truncates division toward zero, so we adjust negative remainders.
    function _floorAlign(int24 tick, int24 spacing) internal pure returns (int24) {
        return LPBalancerLib.floorAlign(tick, spacing);
    }

    /// @dev Compute a tick range of `width` ticks centered on `referenceTick`,
    ///      with both bounds aligned to `spacing`. The range is shifted left until
    ///      `tickLower` is the largest spacing-aligned tick that is ≤ (referenceTick − width/2).
    ///      Reverts if `currentTick` does not strictly straddle the resulting range.
    function _alignedRange(int24 referenceTick, uint24 width, int24 spacing, int24 currentTick)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        return LPBalancerLib.alignedRange(referenceTick, width, spacing, currentTick);
    }

    /// @dev Pick the new main range from this contract's current (post-withdraw) balances.
    ///      - Both legs funded → spot-centered straddle (the normal balanced main).
    ///      - The minority leg below MIN_MAIN_LEG_USD (including exactly one leg funded — a fully
    ///        out-of-range rebalanceUsingAlt returns 100% single-sided principal) → a single-sided `width`-wide
    ///        range on the MAJORITY (funded) side, adjacent to spot, so the mint has positive
    ///        liquidity. NO SWAP is ever performed; this only changes WHERE the funded token is parked.
    ///        Orientation (price = token1/token0, ticks rise with price): a range strictly ABOVE spot
    ///        holds only token0; strictly BELOW holds only token1.
    ///          token0-majority: [up, up + width]      where up   = first aligned tick > spot
    ///          token1-majority: [down - width, down]  where down = first aligned tick < spot
    ///      Both-empty is impossible here (rebalanceUsingAlt withdrew real principal; an empty teardown would
    ///      already have reverted the value floor downstream).
    ///
    ///      Classifier is VALUE-based, not exact-zero: a tiny minority leg (e.g. 1 wei) would force the
    ///      straddle branch and compute near-zero (or zero, reverting) liquidity. Only when BOTH legs
    ///      carry >= MIN_MAIN_LEG_USD do we straddle; a genuinely dust minority is parked single-sided
    ///      on the majority side and its remainder flows to the alt/dust path downstream.
    function _mainRange(ManagedPositionV2 storage p, int24 spotTick, uint24 width, uint8 dec0, uint8 dec1)
        private
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        uint256 bal0 = IERC20(p.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(p.token1).balanceOf(address(this));
        int24 spacing = p.tickSpacing;
        int24 w = int24(width);

        // Value each leg independently (pass the other amount as 0). The minority is the smaller-value
        // leg; only straddle when BOTH legs are >= MIN_MAIN_LEG_USD. A sub-threshold minority is treated
        // as dust → single-sided main on the majority side (placed on the correct side of spot below).
        uint256 value0 = _valueInUsd(bal0, 0, p.oracle0, p.oracle1, dec0, dec1);
        uint256 value1 = _valueInUsd(0, bal1, p.oracle0, p.oracle1, dec0, dec1);
        uint256 minorityValue = value0 < value1 ? value0 : value1;

        if (minorityValue >= MIN_MAIN_LEG_USD) {
            // Balanced straddle centered on spot (guaranteed straddle for width ≥ 2*spacing).
            (tickLower, tickUpper) = _alignedRange(spotTick, width, spacing, spotTick);
            // Enforce maxCenterDeviation on the BALANCED path only. The range is centered on spotTick
            // (the reference), so today the deviation is just the spacing-alignment remainder and is
            // always within a non-trivial bound. This guard backstops any future change to the
            // centering reference (e.g. centering on TWAP) so a skewed center can never slip through.
            // The single-sided branch is intentionally off-center (it parks on the funded side), so it
            // is NOT subject to this check.
            int24 center = (tickLower + tickUpper) / 2;
            int24 dev = center > spotTick ? center - spotTick : spotTick - center;
            if (uint24(dev) > p.maxCenterDeviation) revert CenterDeviation();
            return (tickLower, tickUpper);
        }

        // Single-sided on the MAJORITY (higher-value) leg. token0-majority → range ABOVE spot;
        // token1-majority → range BELOW spot.
        int24 floor = _floorAlign(spotTick, spacing);
        if (value0 >= value1) {
            // token0-majority → range strictly ABOVE spot. `floor` is the largest aligned tick ≤ spot,
            // so floor+spacing is the first aligned tick strictly above spot (also holds when spot
            // is exactly aligned: floor == spot ⇒ floor+spacing > spot).
            int24 up = floor + spacing;
            tickLower = up;
            tickUpper = up + w;
        } else {
            // token1-majority → range strictly BELOW spot.
            // The first aligned tick strictly below spot is `floor` when spot is unaligned, else
            // floor - spacing when spot sits exactly on an aligned tick.
            int24 down = floor == spotTick ? floor - spacing : floor;
            tickUpper = down;
            tickLower = down - w;
        }
    }

    /// @dev Consult the pool's TWAP oracle and return the time-weighted average tick
    ///      over `window` seconds. Division is floored toward −∞ (matches OracleLibrary.consult).
    function _consultTwapTick(address pool, uint32 window) internal view returns (int24) {
        return LPBalancerLib.consultTwapTick(pool, window);
    }

    /// @dev Revert if the absolute difference between `spotTick` and `twapTick` exceeds `maxDev`.
    function _checkDeviation(int24 spotTick, int24 twapTick, int24 maxDev) internal pure {
        int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        if (diff > maxDev) revert TwapDeviation();
    }

    /// @dev Read a Chainlink-style price feed and validate freshness and positivity.
    ///      Reverts with StaleOracle if the answer is non-positive or the feed is stale.
    function _readFeed(address feed) internal view returns (uint256 price, uint8 decimals) {
        return LPBalancerLib.readFeed(feed, maxOracleDelay);
    }

    /// @notice Value token amounts in USD scaled to 1e8 (8-decimal USD).
    /// @param dec0 token0 ERC20 decimals; dec1 token1 ERC20 decimals.
    function _valueInUsd(uint256 amount0, uint256 amount1, address oracle0, address oracle1, uint8 dec0, uint8 dec1)
        internal
        view
        returns (uint256 usd)
    {
        return LPBalancerLib.valueInUsd(amount0, amount1, oracle0, oracle1, dec0, dec1, maxOracleDelay);
    }

    /// @dev Validate all fields of `config` and store them via `_store`.
    ///      Shared by registerPosition and setPool — the validation body is moved here verbatim so
    ///      both entry points exercise identical checks.
    function _validateAndStore(ManagedPositionV2 calldata config) private {
        if (config.maxRebalanceLossBps > MAX_LOSS_CAP_BPS) revert LossCapExceeded();
        if (config.pool == address(0) || config.token0 == address(0) || config.token1 == address(0)) {
            revert InvalidConfig();
        }
        if (config.oracle0 == address(0) || config.oracle1 == address(0)) revert OracleRequired();
        // Probe both feeds now so a wrong address fails in the admin tx (Safe simulation),
        // not as a StaleOracle revert on the next rebalance.
        _readFeed(config.oracle0);
        _readFeed(config.oracle1);
        if (config.twapWindow == 0 || config.maxTickDeviation <= 0) revert InvalidConfig();
        if (config.maxCenterDeviation == 0) revert InvalidConfig();
        int24 spacing = config.tickSpacing;
        if (spacing <= 0) revert InvalidConfig();
        // Cross-validate the supplied pool descriptor against the live pool: token0/token1 ordering
        // and tickSpacing must match, or every on-chain geometry computation would be wrong.
        if (
            ICLPool(config.pool).token0() != config.token0 || ICLPool(config.pool).token1() != config.token1
                || ICLPool(config.pool).tickSpacing() != spacing
        ) revert PoolMismatch();
        // A width narrower than 2*tickSpacing can never straddle an aligned spot, so a balanced
        // rebalanceUsingAlt would always revert in _alignedRange. Require at least two spacings of room.
        if (config.minWidth < 2 * uint24(spacing) || config.maxWidth < config.minWidth) revert WidthTooNarrow();
        if (config.minWidth % uint24(spacing) != 0 || config.maxWidth % uint24(spacing) != 0) revert InvalidWidth();
        // If a gauge is set, its reward token MUST be AERO or staked emissions would be stranded.
        if (config.gauge != address(0) && ICLGauge(config.gauge).rewardToken() != AERO) revert GaugeRewardMismatch();
        if (POSITION_MANAGER.ownerOf(config.mainTokenId) != address(this)) revert NotHeld();
        // Bind the NFT to the configured pool: PoolMismatch above only validates the supplied
        // descriptor against config.pool, NOT that the NFT actually belongs to that pool. Read the
        // NFT's own token0/token1/tickSpacing and require they match — otherwise a position minted
        // against a DIFFERENT pool (wrong fee tier / token order) could be registered, and every
        // on-chain geometry computation (TickMath/LiquidityAmounts on p.tickSpacing) would be wrong.
        // NOTE: the INonfungiblePositionManager interface labels field 4 `fee` (Uniswap), but on
        // Aerodrome Slipstream this slot carries tickSpacing — the same value MintParams.tickSpacing
        // consumes. It is uint24 in the interface, so compare against uint24(spacing).
        (,, address nftToken0, address nftToken1, uint24 nftSpacing,,,,,,,) =
            POSITION_MANAGER.positions(config.mainTokenId);
        if (nftToken0 != config.token0 || nftToken1 != config.token1 || nftSpacing != uint24(spacing)) {
            revert PoolMismatch();
        }

        _store(config);
    }

    /// @dev Copies every field from `config` into `position`, but forces
    ///      `active = true`, `mainStaked = false`, `altStaked = false`, `altTokenId = 0`, and `lastRebalance = 0`.
    function _store(ManagedPositionV2 calldata config) private {
        ManagedPositionV2 storage p = position;
        p.mainTokenId = config.mainTokenId;
        p.altTokenId = 0; // forced
        p.pool = config.pool;
        p.token0 = config.token0;
        p.token1 = config.token1;
        p.tickSpacing = config.tickSpacing;
        p.gauge = config.gauge;
        p.mainStaked = false; // forced
        p.altStaked = false; // forced
        p.feeCollector = config.feeCollector;
        p.oracle0 = config.oracle0;
        p.oracle1 = config.oracle1;
        p.minWidth = config.minWidth;
        p.maxWidth = config.maxWidth;
        p.maxCenterDeviation = config.maxCenterDeviation;
        p.twapWindow = config.twapWindow;
        p.maxTickDeviation = config.maxTickDeviation;
        p.maxRebalanceLossBps = config.maxRebalanceLossBps;
        p.minRebalanceInterval = config.minRebalanceInterval;
        p.lastRebalance = 0; // forced
        p.active = true; // forced
    }
}
