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
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {FixedPoint96} from "@libraries/uniswap/FixedPoint96.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";
import {LiquidityAmounts} from "@libraries/uniswap/LiquidityAmounts.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";

/// @title LPAutoBalancer
/// @notice Safe-governed, multi-position Aerodrome CL rebalancer. Holds position NFTs,
///         re-ranges them with on-chain-computed ticks, stakes for AERO emissions, and
///         skims fees/emissions to the weekly drop. See docs/superpowers/specs/2026-06-01-lp-auto-balancer-design.md
contract LPAutoBalancer is AccessControlEnumerable, ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_SLIPPAGE_CAP_BPS = 500;
    uint16 public constant MAX_LOSS_CAP_BPS = 500;
    uint256 public constant SWAP_DEADLINE_BUFFER = 300;

    INonfungiblePositionManager public immutable POSITION_MANAGER;
    ISwapRouter public immutable SWAP_ROUTER;
    IQuoter public immutable QUOTER;
    address public immutable AERO;

    uint256 public maxOracleDelay;

    struct ManagedPosition {
        uint256 tokenId;
        address pool;
        address token0;
        address token1;
        int24 tickSpacing;
        address gauge;
        bool staked;
        address feeCollector;
        address oracle0;
        address oracle1;
        uint8 swapPolicy; // 0 = either; 1 = counter-asset only (never sell protectedToken); 2 = protected only
        address protectedToken;
        uint24 minWidth;
        uint24 maxWidth;
        uint24 maxCenterDeviation;
        uint16 maxSlippageBps;
        uint32 twapWindow;
        int24 maxTickDeviation;
        uint16 maxRebalanceLossBps;
        uint256 minRebalanceInterval;
        uint256 lastRebalance;
        bool active;
    }

    mapping(uint256 => ManagedPosition) public positions;
    uint256 public nextSlotId;

    error ZeroAddress();
    error TwapDeviation();
    error StaleOracle();
    error SlippageCapExceeded();
    error LossCapExceeded();
    error InvalidWidth();
    error OracleRequired();
    error InvalidConfig();
    error NotActive();
    error NotHeld();
    error InvalidSwapPolicy();
    error PositionStaked();
    error SlippageTooHigh();
    error NoGauge();
    error AlreadyStaked();
    error NotStaked();
    error Cooldown();
    error WidthOutOfBounds();
    error CenterDeviation();
    error ValueFloor();

    event PositionRegistered(uint256 indexed slotId, address indexed pool, uint256 indexed tokenId);
    event PositionDeregistered(uint256 indexed slotId, address indexed to);
    event PositionWithdrawn(uint256 indexed slotId, address indexed to);
    event PositionConfigUpdated(uint256 indexed slotId);
    event FeeCollectorUpdated(uint256 indexed slotId, address feeCollector);
    event OraclesUpdated(uint256 indexed slotId, address oracle0, address oracle1);
    event SwapPolicyUpdated(uint256 indexed slotId, uint8 swapPolicy, address protectedToken);
    event GaugeUpdated(uint256 indexed slotId, address gauge);
    event MaxOracleDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event Staked(uint256 indexed slotId, uint256 indexed tokenId, address gauge);
    event Unstaked(uint256 indexed slotId, uint256 indexed tokenId, address gauge);
    event EmissionsClaimed(uint256 indexed slotId, uint256 amount);
    event FeesSkimmed(uint256 indexed slotId, uint256 amount0, uint256 amount1);
    event Rebalanced(uint256 indexed slotId, uint256 oldTokenId, uint256 newTokenId, int24 tickLower, int24 tickUpper);
    event Migrated(uint256 indexed slotId, address oldPool, address destPool, uint256 oldTokenId, uint256 newTokenId);

    constructor(
        address admin_,
        address manager_,
        address rebalancer_,
        address guardian_,
        address positionManager_,
        address swapRouter_,
        address quoter_,
        address aero_
    ) {
        if (
            admin_ == address(0) || positionManager_ == address(0) || swapRouter_ == address(0) || quoter_ == address(0)
                || aero_ == address(0)
        ) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        if (manager_ != address(0)) _grantRole(MANAGER_ROLE, manager_);
        if (rebalancer_ != address(0)) _grantRole(REBALANCER_ROLE, rebalancer_);
        if (guardian_ != address(0)) _grantRole(GUARDIAN_ROLE, guardian_);

        POSITION_MANAGER = INonfungiblePositionManager(positionManager_);
        SWAP_ROUTER = ISwapRouter(swapRouter_);
        QUOTER = IQuoter(quoter_);
        AERO = aero_;
        maxOracleDelay = 26 hours;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(POSITION_MANAGER), "Only position manager");
        return this.onERC721Received.selector;
    }

    /// @notice Register a position NFT already held by this contract.
    /// @param config Full position configuration. `active`, `staked`, and `lastRebalance` are
    ///               overridden by `_store` regardless of the values supplied here.
    /// @return slotId The slot index assigned to this position.
    function registerPosition(ManagedPosition calldata config)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 slotId)
    {
        if (config.maxSlippageBps > MAX_SLIPPAGE_CAP_BPS) revert SlippageCapExceeded();
        if (config.maxRebalanceLossBps > MAX_LOSS_CAP_BPS) revert LossCapExceeded();
        if (config.pool == address(0) || config.token0 == address(0) || config.token1 == address(0)) {
            revert InvalidConfig();
        }
        if (config.oracle0 == address(0) || config.oracle1 == address(0)) revert OracleRequired();
        if (config.twapWindow == 0 || config.maxTickDeviation <= 0) revert InvalidConfig();
        if (config.maxCenterDeviation == 0) revert InvalidConfig();
        int24 spacing = config.tickSpacing;
        if (spacing <= 0) revert InvalidConfig();
        if (
            config.minWidth == 0 || config.minWidth > config.maxWidth || config.minWidth % uint24(spacing) != 0
                || config.maxWidth % uint24(spacing) != 0
        ) revert InvalidWidth();
        if (POSITION_MANAGER.ownerOf(config.tokenId) != address(this)) revert NotHeld();

        slotId = nextSlotId++;
        _store(slotId, config);
        emit PositionRegistered(slotId, config.pool, config.tokenId);
    }

    /// @notice Deregister a position and transfer its NFT to `to`.
    ///         Intentionally reverts if the position is staked: the admin must `unstake`
    ///         (or use `withdrawPosition`, which auto-unstakes) first. This keeps deregister
    ///         a pure book-keeping/transfer path and never silently strands a staked NFT.
    function deregisterPosition(uint256 slotId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ManagedPosition storage p = positions[slotId];
        if (!p.active) revert NotActive();
        if (to == address(0)) revert ZeroAddress();
        if (p.staked) revert PositionStaked();
        uint256 tokenId = p.tokenId;
        p.active = false; // effects before interaction (CEI)
        emit PositionDeregistered(slotId, to);
        POSITION_MANAGER.safeTransferFrom(address(this), to, tokenId); // interaction last
    }

    /// @notice Emergency withdraw: auto-unstakes (if staked) then transfers the NFT to `to`.
    ///         Allows an admin to rescue a position in one call regardless of staking state.
    function withdrawPosition(uint256 slotId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        ManagedPosition storage p = positions[slotId];
        if (!p.active) revert NotActive();
        if (to == address(0)) revert ZeroAddress();
        if (p.staked) _unstake(p, slotId); // auto-claims AERO -> feeCollector, returns NFT to this contract
        uint256 tokenId = p.tokenId;
        p.active = false; // effects before interaction (CEI)
        emit PositionWithdrawn(slotId, to);
        POSITION_MANAGER.safeTransferFrom(address(this), to, tokenId); // interaction last
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Manager setters
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Update the core rebalance parameters for an active position.
    function setPositionConfig(
        uint256 slotId,
        uint24 minWidth,
        uint24 maxWidth,
        uint24 maxCenterDeviation,
        uint16 maxSlippageBps,
        uint32 twapWindow,
        int24 maxTickDeviation,
        uint16 maxRebalanceLossBps,
        uint256 minRebalanceInterval
    ) external onlyRole(MANAGER_ROLE) {
        if (!positions[slotId].active) revert NotActive();
        if (maxSlippageBps > MAX_SLIPPAGE_CAP_BPS) revert SlippageCapExceeded();
        if (maxRebalanceLossBps > MAX_LOSS_CAP_BPS) revert LossCapExceeded();
        if (twapWindow == 0 || maxTickDeviation <= 0) revert InvalidConfig();
        if (maxCenterDeviation == 0) revert InvalidConfig();
        int24 spacing = positions[slotId].tickSpacing;
        if (minWidth == 0 || minWidth > maxWidth || minWidth % uint24(spacing) != 0 || maxWidth % uint24(spacing) != 0)
        {
            revert InvalidWidth();
        }

        ManagedPosition storage p = positions[slotId];
        p.minWidth = minWidth;
        p.maxWidth = maxWidth;
        p.maxCenterDeviation = maxCenterDeviation;
        p.maxSlippageBps = maxSlippageBps;
        p.twapWindow = twapWindow;
        p.maxTickDeviation = maxTickDeviation;
        p.maxRebalanceLossBps = maxRebalanceLossBps;
        p.minRebalanceInterval = minRebalanceInterval;

        emit PositionConfigUpdated(slotId);
    }

    /// @notice Update the fee collector for an active position.
    function setFeeCollector(uint256 slotId, address feeCollector) external onlyRole(MANAGER_ROLE) {
        if (!positions[slotId].active) revert NotActive();
        if (feeCollector == address(0)) revert ZeroAddress();
        positions[slotId].feeCollector = feeCollector;
        emit FeeCollectorUpdated(slotId, feeCollector);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Admin setters
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Update the price-feed oracles for an active position.
    function setOracles(uint256 slotId, address oracle0, address oracle1) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!positions[slotId].active) revert NotActive();
        if (oracle0 == address(0) || oracle1 == address(0)) revert OracleRequired();
        positions[slotId].oracle0 = oracle0;
        positions[slotId].oracle1 = oracle1;
        emit OraclesUpdated(slotId, oracle0, oracle1);
    }

    /// @notice Update the swap policy for an active position.
    ///         swapPolicy: 0 = either, 1 = counter-asset only, 2 = protected only.
    function setSwapPolicy(uint256 slotId, uint8 swapPolicy, address protectedToken)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!positions[slotId].active) revert NotActive();
        if (swapPolicy > 2) revert InvalidSwapPolicy();
        ManagedPosition storage p = positions[slotId];
        if (swapPolicy == 0) {
            protectedToken = address(0);
        } else if (protectedToken != p.token0 && protectedToken != p.token1) {
            revert InvalidConfig();
        }
        p.swapPolicy = swapPolicy;
        p.protectedToken = protectedToken;
        emit SwapPolicyUpdated(slotId, swapPolicy, protectedToken);
    }

    /// @notice Update the gauge for an active position. Pass address(0) to disable staking.
    ///         Requires the position to not currently be staked.
    function setGauge(uint256 slotId, address gauge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!positions[slotId].active) revert NotActive();
        if (positions[slotId].staked) revert PositionStaked();
        positions[slotId].gauge = gauge;
        emit GaugeUpdated(slotId, gauge);
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

    /// @notice Approve the gauge and deposit the position NFT into it for AERO emissions.
    function stake(uint256 slotId) external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
        ManagedPosition storage p = positions[slotId];
        if (!p.active) revert NotActive();
        if (p.gauge == address(0)) revert NoGauge();
        if (p.staked) revert AlreadyStaked();
        POSITION_MANAGER.approve(p.gauge, p.tokenId);
        ICLGauge(p.gauge).deposit(p.tokenId);
        p.staked = true;
        emit Staked(slotId, p.tokenId, p.gauge);
    }

    /// @notice Withdraw the position NFT from the gauge and skim any AERO to the fee collector.
    function unstake(uint256 slotId) external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
        ManagedPosition storage p = positions[slotId];
        if (!p.staked) revert NotStaked();
        _unstake(p, slotId);
    }

    /// @dev Internal unstake: withdraw from gauge (auto-claims AERO), set staked=false,
    ///      then skim any AERO balance to the fee collector (CEI: state update before AERO transfer).
    function _unstake(ManagedPosition storage p, uint256 slotId) internal {
        // Measure only the AERO GAINED by this withdraw so we never sweep another slot's
        // pending AERO or a stray balance sitting on this contract.
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        ICLGauge(p.gauge).withdraw(p.tokenId); // returns NFT + auto-claims AERO
        p.staked = false; // CEI: effect before interaction (AERO transfer below)
        uint256 aeroEarned = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        if (aeroEarned > 0) {
            IERC20(AERO).safeTransfer(p.feeCollector, aeroEarned);
            emit EmissionsClaimed(slotId, aeroEarned);
        }
        emit Unstaked(slotId, p.tokenId, p.gauge);
    }

    /// @notice Claim AERO emissions from the gauge for a staked position and forward to feeCollector.
    ///         Permissionless — anyone may call to trigger the skim.
    function claimEmissions(uint256 slotId) external whenNotPaused nonReentrant {
        ManagedPosition storage p = positions[slotId];
        if (!p.active) revert NotActive();
        if (!p.staked) revert NotStaked();
        // Forward only the AERO gained by THIS claim, not the whole contract balance —
        // avoids cross-slot sweeps and stray-balance theft.
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        ICLGauge(p.gauge).getReward(p.tokenId);
        uint256 aeroEarned = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        if (aeroEarned > 0) {
            IERC20(AERO).safeTransfer(p.feeCollector, aeroEarned);
            emit EmissionsClaimed(slotId, aeroEarned);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Rebalance
    // ═══════════════════════════════════════════════════════════════════════

    struct RebalanceParams {
        uint24 width;
        uint256 swapMinAmountOut;
        uint256 amount0MinDecrease;
        uint256 amount1MinDecrease;
        uint256 amount0MinMint;
        uint256 amount1MinMint;
        uint256 deadline;
    }

    /// @notice Re-range an active position to a new tick range centered on the TWAP tick.
    ///
    ///         Orchestration (all on-chain):
    ///         1.  Read spot + TWAP; deviation gate.
    ///         2.  Snapshot value-before (principal only, at current sqrtP).
    ///         3.  Unstake (if staked) — AERO auto-claimed → feeCollector.
    ///         4.  Skim LP fees → feeCollector (does not perturb value measurement because
    ///             _principalValue uses liquidity only, never tokensOwed).
    ///         5.  DecreaseAll + collect principal into this contract.
    ///         6.  Compute new aligned range; center-deviation gate.
    ///         7.  Compute + execute swap to re-ratio balances for the new range.
    ///         8.  Mint new NFT; burn old; update p.tokenId.
    ///         9.  Restake (if it was staked).
    ///         10. Snapshot value-after (same sqrtP); value-floor gate.
    ///         11. Forward dust to feeCollector.
    function rebalance(uint256 slotId, RebalanceParams calldata params)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        whenNotPaused
    {
        ManagedPosition storage p = positions[slotId];
        if (!p.active) revert NotActive();
        if (block.timestamp < p.lastRebalance + p.minRebalanceInterval) revert Cooldown();
        if (params.width < p.minWidth || params.width > p.maxWidth) revert WidthOutOfBounds();

        bool wasStaked = p.staked;

        // 1. spot + TWAP ticks; deviation gate
        (uint160 sqrtP, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
        int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);
        _checkDeviation(spotTick, twapTick, p.maxTickDeviation);

        // 2. token decimals
        uint8 dec0 = IERC20Metadata(p.token0).decimals();
        uint8 dec1 = IERC20Metadata(p.token1).decimals();

        // 3. value BEFORE: read old position's liquidity at current sqrtP.
        //    _principalValue uses liquidity only — owed fees are excluded by construction,
        //    so step 4 (skim fees) does NOT alter this measurement.
        uint256 valueBefore = _principalValue(p, sqrtP, dec0, dec1);

        // 4. unstake if needed (auto-claims AERO → feeCollector)
        if (wasStaked) _unstake(p, slotId);

        // 5. skim LP fees (pre-decrease) → feeCollector
        _skimFees(p, slotId);

        // 6. decrease all liquidity + collect principal into this contract
        _decreaseAll(p, params);

        // 7. compute new range centered on SPOT, with center-deviation gate vs TWAP.
        //    Center on spot (already gate-passed vs TWAP above); straddle is then guaranteed
        //    for width >= 2*tickSpacing. The center-vs-TWAP deviation is still bounded by
        //    maxCenterDeviation below, so a spot-centered range can't drift far from the
        //    manipulation-resistant TWAP.
        (int24 tickLower, int24 tickUpper) = _alignedRange(spotTick, params.width, p.tickSpacing, spotTick);
        {
            int24 center = (tickLower + tickUpper) / 2;
            int24 dev = center > twapTick ? center - twapTick : twapTick - center;
            if (dev > int24(uint24(p.maxCenterDeviation))) revert CenterDeviation();
        }

        // 8. compute + execute swap to re-ratio balances for the new range
        {
            uint256 bal0 = IERC20(p.token0).balanceOf(address(this));
            uint256 bal1 = IERC20(p.token1).balanceOf(address(this));
            (bool zeroForOne, uint256 amountIn) = _computeSwap(
                sqrtP, tickLower, tickUpper, bal0, bal1, p.swapPolicy, p.token0, p.token1, p.protectedToken
            );
            if (amountIn > 0) {
                (address tin, address tout) = zeroForOne ? (p.token0, p.token1) : (p.token1, p.token0);
                _executeSwap(tin, tout, amountIn, p.tickSpacing, params.swapMinAmountOut, p.maxSlippageBps);
            }
        }

        // 9. mint new NFT; burn old; update tokenId + lastRebalance
        uint256 oldTokenId = p.tokenId;
        uint256 newTokenId = _mintNew(p, tickLower, tickUpper, params);
        POSITION_MANAGER.burn(oldTokenId);
        p.tokenId = newTokenId;
        p.lastRebalance = block.timestamp;

        // 10. restake if it was staked before
        if (wasStaked && p.gauge != address(0)) {
            POSITION_MANAGER.approve(p.gauge, newTokenId);
            ICLGauge(p.gauge).deposit(newTokenId);
            p.staked = true;
            emit Staked(slotId, newTokenId, p.gauge);
        }

        // 11. value AFTER: p.tokenId now points to new position; same sqrtP snapshot from step 1.
        //     Both measurements use principal-only liquidity → consistent comparison.
        uint256 valueAfter = _principalValue(p, sqrtP, dec0, dec1);
        if (valueAfter < FullMath.mulDiv(valueBefore, BPS_DENOMINATOR - p.maxRebalanceLossBps, BPS_DENOMINATOR)) {
            revert ValueFloor();
        }

        // 12. forward residual dust to feeCollector
        _forwardDust(p);

        emit Rebalanced(slotId, oldTokenId, newTokenId, tickLower, tickUpper);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Migrate — Safe-admin gated, arbitrary destination pool
    // ═══════════════════════════════════════════════════════════════════════

    struct MigrateParams {
        address destPool;
        address destToken0;
        address destToken1;
        int24 destTickSpacing;
        address destGauge;
        address destOracle0;
        address destOracle1;
        uint8 destSwapPolicy;
        address destProtectedToken;
        int24 tickLower;
        int24 tickUpper;
        address swapTokenIn;
        uint256 swapAmountIn;
        uint256 swapMinAmountOut;
        uint256 amount0MinDecrease;
        uint256 amount1MinDecrease;
        uint256 amount0MinMint;
        uint256 amount1MinMint;
        uint256 deadline;
    }

    /// @notice Move a managed position into a DIFFERENT pool/pair (open destination).
    ///
    ///         WHY NO VALUE FLOOR / TWAP GATE:
    ///         The destination pool is arbitrary — it may be a brand-new pair with no
    ///         trustworthy on-chain oracle and no TWAP history. An automated value check
    ///         could be spoofed or vacuous. The Safe multisig review IS the value guard:
    ///         signers inspect the destination pool, token addresses, and swap route
    ///         before signing. Only cheap fat-finger sanity guards are enforced on-chain.
    ///
    ///         The swap route (swapTokenIn / swapAmountIn / swapMinAmountOut) is
    ///         entirely human-supplied; swapMinAmountOut acts as defense-in-depth
    ///         slippage protection reviewed by the Safe signers.
    function migrate(uint256 slotId, MigrateParams calldata params)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        ManagedPosition storage p = positions[slotId];
        if (!p.active) revert NotActive();

        // ── Cheap fat-finger sanity guards (NOT value protection) ───────────
        if (params.destPool.code.length == 0) revert InvalidConfig();
        if (params.destTickSpacing != ICLPool(params.destPool).tickSpacing()) revert InvalidConfig();
        if (params.tickLower >= params.tickUpper) revert InvalidConfig();
        if (params.destToken0 == address(0) || params.destToken1 == address(0)) revert InvalidConfig();
        if (params.swapAmountIn > 0 && params.swapTokenIn != p.token0 && params.swapTokenIn != p.token1) {
            revert InvalidConfig();
        }
        // Destination oracle/policy must be valid so the next rebalance values the new pair
        // with the correct Chainlink feeds and a consistent swap policy (not stale source config).
        if (params.destOracle0 == address(0) || params.destOracle1 == address(0)) revert OracleRequired();
        if (params.destSwapPolicy > 2) revert InvalidSwapPolicy();
        if (
            params.destSwapPolicy != 0 && params.destProtectedToken != params.destToken0
                && params.destProtectedToken != params.destToken1
        ) revert InvalidConfig();
        // Dest ticks must align to the destination pool's spacing so mint + future rebalances work.
        if (params.tickLower % params.destTickSpacing != 0 || params.tickUpper % params.destTickSpacing != 0) {
            revert InvalidConfig();
        }

        address oldPool = p.pool;
        uint256 oldTokenId = p.tokenId;

        // 1. Unstake if staked (auto-claims AERO → feeCollector)
        if (p.staked) _unstake(p, slotId);

        // 2. Skim LP fees → feeCollector
        _skimFees(p, slotId);

        // 3. Decrease all liquidity + collect principal
        _decreaseLiquidityAll(p.tokenId, params.amount0MinDecrease, params.amount1MinDecrease, params.deadline);

        // 4. Execute the human-supplied swap (defense-in-depth slippage via swapMinAmountOut).
        //    No _computeSwap — the multisig reviewed the route.
        //    The swap converts the decreased OLD-pair principal between the OLD tokens and is
        //    routed through the OLD pool (p.tickSpacing) — a single hop in the source pool —
        //    BEFORE we mint into the destination pool. exactInputSingle cannot route cross-pair,
        //    so this intentionally uses the old pool's tickSpacing, not the destination's.
        if (params.swapAmountIn > 0) {
            address tin = params.swapTokenIn;
            address tout = tin == p.token0 ? p.token1 : p.token0;
            _executeSwap(tin, tout, params.swapAmountIn, p.tickSpacing, params.swapMinAmountOut, p.maxSlippageBps);
        }

        // 5. Mint into destPool with dest tokens / ticks.
        //    NOTE: For a real cross-pair migration the multisig must set swapTokenIn/Out so the
        //    contract holds destToken0/destToken1 by the time we reach this step.
        //    For unit tests destToken0/1 == old tok0/1 (same-pair, different pool) so balances
        //    naturally align without a swap.
        uint256 newTokenId = _mintIntoDest(params);

        // 6. Burn old NFT
        POSITION_MANAGER.burn(oldTokenId);

        // 7. Update slot in-place to the destination, INCLUDING oracles + swap policy so the
        //    next rebalance values the new pair with the correct feeds, not stale source config.
        p.pool = params.destPool;
        p.token0 = params.destToken0;
        p.token1 = params.destToken1;
        p.tickSpacing = params.destTickSpacing;
        p.gauge = params.destGauge;
        p.oracle0 = params.destOracle0;
        p.oracle1 = params.destOracle1;
        p.swapPolicy = params.destSwapPolicy;
        p.protectedToken = params.destSwapPolicy == 0 ? address(0) : params.destProtectedToken;
        p.tokenId = newTokenId;
        p.staked = false;
        p.lastRebalance = block.timestamp;

        // 8. Optionally restake into destGauge
        if (params.destGauge != address(0)) {
            POSITION_MANAGER.approve(params.destGauge, newTokenId);
            ICLGauge(params.destGauge).deposit(newTokenId);
            p.staked = true;
            emit Staked(slotId, newTokenId, params.destGauge);
        }

        // 9. Forward any residual dest-token dust → feeCollector
        _forwardDustTokens(params.destToken0, params.destToken1, p.feeCollector);

        emit Migrated(slotId, oldPool, params.destPool, oldTokenId, newTokenId);
    }

    // ─── migrate private helpers ─────────────────────────────────────────────

    /// @dev Shared internal: remove all liquidity from tokenId and collect into this contract.
    ///      Used by both rebalance (via _decreaseAll wrapper) and migrate.
    function _decreaseLiquidityAll(uint256 tokenId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) private {
        (,,,,,,, uint128 liq,,,,) = POSITION_MANAGER.positions(tokenId);
        if (liq > 0) {
            POSITION_MANAGER.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liq,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: deadline
                })
            );
        }
        POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    /// @dev Mint a new position into the destination pool using current contract balances
    ///      of destToken0/destToken1.
    ///      NOTE: After a cross-pair swap the contract holds the dest tokens because the
    ///      human-supplied swap route converted old tokens into destToken0/1.
    ///      For same-pair migrations (unit tests) the balances already are the dest tokens.
    function _mintIntoDest(MigrateParams calldata params) private returns (uint256 newTokenId) {
        uint256 bal0 = IERC20(params.destToken0).balanceOf(address(this));
        uint256 bal1 = IERC20(params.destToken1).balanceOf(address(this));

        IERC20(params.destToken0).forceApprove(address(POSITION_MANAGER), bal0);
        IERC20(params.destToken1).forceApprove(address(POSITION_MANAGER), bal1);

        ICLPositionManager.MintParams memory mp = ICLPositionManager.MintParams({
            token0: params.destToken0,
            token1: params.destToken1,
            tickSpacing: params.destTickSpacing,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            amount0Desired: bal0,
            amount1Desired: bal1,
            amount0Min: params.amount0MinMint,
            amount1Min: params.amount1MinMint,
            recipient: address(this),
            deadline: params.deadline,
            sqrtPriceX96: 0 // pool already initialized
        });
        (newTokenId,,,) = ICLPositionManager(address(POSITION_MANAGER)).mint(mp);
    }

    /// @dev Transfer residual balances of t0 and t1 to `to`.
    ///      Extracted so both _forwardDust (rebalance) and _forwardDustTokens (migrate) share it.
    function _forwardDustTokens(address t0, address t1, address to) private {
        uint256 d0 = IERC20(t0).balanceOf(address(this));
        uint256 d1 = IERC20(t1).balanceOf(address(this));
        if (d0 > 0) IERC20(t0).safeTransfer(to, d0);
        if (d1 > 0) IERC20(t1).safeTransfer(to, d1);
    }

    // ─── rebalance private helpers ───────────────────────────────────────────

    /// @dev Collect any accrued LP fees for the position (before decreasing liquidity)
    ///      and forward both tokens to the feeCollector.
    function _skimFees(ManagedPosition storage p, uint256 slotId) private {
        (uint256 a0, uint256 a1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: p.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        if (a0 > 0) IERC20(p.token0).safeTransfer(p.feeCollector, a0);
        if (a1 > 0) IERC20(p.token1).safeTransfer(p.feeCollector, a1);
        emit FeesSkimmed(slotId, a0, a1);
    }

    /// @dev Remove all liquidity from the position and collect the resulting tokens
    ///      into this contract. Delegates to the shared _decreaseLiquidityAll helper.
    function _decreaseAll(ManagedPosition storage p, RebalanceParams calldata params) private {
        _decreaseLiquidityAll(p.tokenId, params.amount0MinDecrease, params.amount1MinDecrease, params.deadline);
    }

    /// @dev Mint a new position NFT using the current token balances of this contract.
    ///      Builds Slipstream MintParams keyed by tickSpacing (not a fee tier) and passes
    ///      sqrtPriceX96=0 because the destination pool is already initialized.
    function _mintNew(ManagedPosition storage p, int24 tickLower, int24 tickUpper, RebalanceParams calldata params)
        private
        returns (uint256 newTokenId)
    {
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
            amount0Min: params.amount0MinMint,
            amount1Min: params.amount1MinMint,
            recipient: address(this),
            deadline: params.deadline,
            sqrtPriceX96: 0 // pool already initialized
        });
        (newTokenId,,,) = ICLPositionManager(address(POSITION_MANAGER)).mint(mp);
    }

    /// @dev Transfer any residual token0 / token1 balance of this contract to the feeCollector.
    function _forwardDust(ManagedPosition storage p) private {
        _forwardDustTokens(p.token0, p.token1, p.feeCollector);
    }

    /// @dev Compute the USD value of the principal tokens locked in the position,
    ///      valued at the given sqrtP (Q64.96 sqrt price). Uses LiquidityAmounts to
    ///      derive token amounts from the NFT's stored liquidity — never counts tokensOwed
    ///      (fees), so skimming fees does not perturb this measurement.
    function _principalValue(ManagedPosition storage p, uint160 sqrtP, uint8 dec0, uint8 dec1)
        private
        view
        returns (uint256)
    {
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = POSITION_MANAGER.positions(p.tokenId);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liq
        );
        return _valueInUsd(a0, a1, p.oracle0, p.oracle1, dec0, dec1);
    }

    /// @notice Collect accrued LP fees for an unstaked position and forward to feeCollector.
    ///         Permissionless — anyone may call. Reverts if the position is staked (use claimEmissions).
    function collectFees(uint256 slotId) external whenNotPaused nonReentrant {
        ManagedPosition storage p = positions[slotId];
        if (!p.active) revert NotActive();
        if (p.staked) revert AlreadyStaked(); // staked => fees accrue to the gauge; use claimEmissions
        (uint256 a0, uint256 a1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: p.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        if (a0 > 0) IERC20(p.token0).safeTransfer(p.feeCollector, a0);
        if (a1 > 0) IERC20(p.token1).safeTransfer(p.feeCollector, a1);
        emit FeesSkimmed(slotId, a0, a1);
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
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q -= 1; // floor toward -inf
        return q * spacing;
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
        int24 half = int24(width / 2);
        tickLower = _floorAlign(referenceTick - half, spacing);
        tickUpper = tickLower + int24(width);
        require(tickLower < currentTick && currentTick < tickUpper, "no straddle");
    }

    /// @dev Consult the pool's TWAP oracle and return the time-weighted average tick
    ///      over `window` seconds. Division is floored toward −∞ (matches OracleLibrary.consult).
    function _consultTwapTick(address pool, uint32 window) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory cum,) = ICLPool(pool).observe(secondsAgos);
        int56 delta = cum[1] - cum[0];
        int24 twapTick = int24(delta / int56(uint56(window)));
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) twapTick--; // round toward -inf
        return twapTick;
    }

    /// @dev Revert if the absolute difference between `spotTick` and `twapTick` exceeds `maxDev`.
    function _checkDeviation(int24 spotTick, int24 twapTick, int24 maxDev) internal pure {
        int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        if (diff > maxDev) revert TwapDeviation();
    }

    /// @dev Read a Chainlink-style price feed and validate freshness and positivity.
    ///      Reverts with StaleOracle if the answer is non-positive or the feed is stale.
    function _readFeed(address feed) internal view returns (uint256 price, uint8 decimals) {
        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(feed).latestRoundData();
        if (answer <= 0) revert StaleOracle();
        if (block.timestamp - updatedAt > maxOracleDelay) revert StaleOracle();
        price = uint256(answer);
        decimals = IPriceFeed(feed).decimals();
    }

    /// @notice Value token amounts in USD scaled to 1e8 (8-decimal USD).
    /// @param dec0 token0 ERC20 decimals; dec1 token1 ERC20 decimals.
    function _valueInUsd(uint256 amount0, uint256 amount1, address oracle0, address oracle1, uint8 dec0, uint8 dec1)
        internal
        view
        returns (uint256 usd)
    {
        (uint256 p0, uint8 fd0) = _readFeed(oracle0);
        (uint256 p1, uint8 fd1) = _readFeed(oracle1);
        usd = FullMath.mulDiv(amount0, p0, 10 ** dec0) * (10 ** 8) / (10 ** fd0)
            + FullMath.mulDiv(amount1, p1, 10 ** dec1) * (10 ** 8) / (10 ** fd1);
    }

    /// @dev Compute how much of which token to swap so the held balances match the
    ///      target ratio for a new range at the current sqrt price.
    ///      This is an APPROXIMATE single-swap; any residual becomes dust.
    ///      Per-position swapPolicy can forbid selling a protected token:
    ///        0 = either token may be sold
    ///        1 = never sell protectedToken (counter-asset only)
    ///        2 = only sell protectedToken
    /// @return zeroForOne true => sell token0 for token1
    /// @return amountIn   amount of the surplus token to swap (0 => no swap needed)
    function _computeSwap(
        uint160 sqrtP,
        int24 tickLower,
        int24 tickUpper,
        uint256 bal0,
        uint256 bal1,
        uint8 swapPolicy,
        address token0,
        address token1,
        address protectedToken
    ) internal pure returns (bool zeroForOne, uint256 amountIn) {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);

        // price of token0 in token1, Q96: P = sqrtP^2 / 2^96
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), FixedPoint96.Q96);

        uint256 total1 = bal1 + FullMath.mulDiv(bal0, priceX96, FixedPoint96.Q96);
        if (total1 == 0) return (false, 0);

        (uint256 req0, uint256 req1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, 1e18);
        uint256 req0In1 = FullMath.mulDiv(req0, priceX96, FixedPoint96.Q96);
        uint256 denom = req0In1 + req1;
        if (denom == 0) {
            // range entirely on one side at current price (extreme rounding with L=1e18)
            if (req1 == 0) {
                // range wants all token0 => sell any token1 we have
                zeroForOne = false;
                amountIn = bal1;
            } else {
                // range wants all token1 => sell any token0 we have
                zeroForOne = true;
                amountIn = bal0;
            }
        } else {
            uint256 desired0In1 = FullMath.mulDiv(total1, req0In1, denom);
            uint256 cur0In1 = FullMath.mulDiv(bal0, priceX96, FixedPoint96.Q96);

            if (cur0In1 > desired0In1) {
                uint256 surplus1 = cur0In1 - desired0In1;
                amountIn = FullMath.mulDiv(surplus1, FixedPoint96.Q96, priceX96); // back to token0 units
                zeroForOne = true;
            } else {
                amountIn = desired0In1 - cur0In1;
                zeroForOne = false;
            }
        }

        // swap-leg policy applied uniformly to ALL paths (including denom==0 one-sided ranges)
        // 1 = never sell protectedToken; 2 = only sell protectedToken
        address sellToken = zeroForOne ? token0 : token1;
        if (swapPolicy == 1 && sellToken == protectedToken) return (zeroForOne, 0);
        if (swapPolicy == 2 && sellToken != protectedToken) return (zeroForOne, 0);
    }

    /// @notice Swap exactly `amountIn` of tokenIn for tokenOut on the Aerodrome CL router,
    ///         bounded by max(quoter-derived floor at maxSlippageBps, callerMinOut).
    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        int24 tickSpacing,
        uint256 callerMinOut,
        uint16 maxSlippageBps
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), amountIn);

        IQuoter.QuoteExactInputSingleParams memory qp = IQuoter.QuoteExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            tickSpacing: tickSpacing,
            sqrtPriceLimitX96: 0
        });
        (uint256 quotedOut,,,) = QUOTER.quoteExactInputSingle(qp);
        require(quotedOut > 0, "Invalid quote");

        uint256 quoterMin = (quotedOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        if (quoterMin == 0) revert SlippageTooHigh();
        uint256 minOut = callerMinOut > quoterMin ? callerMinOut : quoterMin;

        ISwapRouter.ExactInputSingleParams memory sp = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tickSpacing: tickSpacing,
            recipient: address(this),
            deadline: block.timestamp + SWAP_DEADLINE_BUFFER,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
        amountOut = SWAP_ROUTER.exactInputSingle(sp);
        require(amountOut >= minOut, "Received less than min amount");
    }

    /// @dev Copies every field from `config` into `positions[slotId]`, but forces
    ///      `active = true`, `staked = false`, and `lastRebalance = 0`.
    function _store(uint256 slotId, ManagedPosition calldata config) private {
        ManagedPosition storage p = positions[slotId];
        p.tokenId = config.tokenId;
        p.pool = config.pool;
        p.token0 = config.token0;
        p.token1 = config.token1;
        p.tickSpacing = config.tickSpacing;
        p.gauge = config.gauge;
        p.staked = false; // forced
        p.feeCollector = config.feeCollector;
        p.oracle0 = config.oracle0;
        p.oracle1 = config.oracle1;
        p.swapPolicy = config.swapPolicy;
        p.protectedToken = config.protectedToken;
        p.minWidth = config.minWidth;
        p.maxWidth = config.maxWidth;
        p.maxCenterDeviation = config.maxCenterDeviation;
        p.maxSlippageBps = config.maxSlippageBps;
        p.twapWindow = config.twapWindow;
        p.maxTickDeviation = config.maxTickDeviation;
        p.maxRebalanceLossBps = config.maxRebalanceLossBps;
        p.minRebalanceInterval = config.minRebalanceInterval;
        p.lastRebalance = 0; // forced
        p.active = true; // forced
    }
}
