// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {LPGeometryLib} from "@libraries/LPGeometryLib.sol";
import {LPValuationLib} from "@libraries/LPValuationLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LPPositionLib
/// @notice Position-manager and gauge interactions for LPAutoBalancerV2: mint/decrease/collect
///         mutations, pool/NFT/gauge binding validation, and the unwind lifecycle guards. Shared
///         invariant of every function here: faces POSITION_MANAGER or the gauge, and runs under
///         DELEGATECALL so `address(this)` and token custody are the balancer's. Deployed as an
///         EXTERNAL (linked) library so its bytecode lives off the balancer — keeping the balancer
///         under the EIP-170 24,576-byte limit. Functions are `public`/`external` on purpose:
///         internal library functions would inline back into the balancer and defeat the size
///         reduction.
/// @dev Errors are redeclared here; a Solidity error's 4-byte selector depends only on its
///      signature, so `LPPositionLib.PoolMismatch.selector == LPAutoBalancerV2.PoolMismatch.selector`
///      and existing `vm.expectRevert(...)` matchers keep working.
library LPPositionLib {
    using SafeERC20 for IERC20;

    error NotActive();
    error AlreadyInFlight();
    error Cooldown();
    error ModuleNotSet();
    error InvalidSellToken();
    error GaugeRewardMismatch();
    error PoolMismatch();
    error NotHeld();
    error LossCapExceeded();
    error InvalidConfig();
    error InvalidWidth();
    error WidthTooNarrow();
    error WidthOutOfBounds();

    /// @notice The rebalance-parameter validation shared by `registerPosition`/`setPool` (via
    ///         `_validateAndStore`) and `setPositionConfig`, so the registration and the
    ///         post-registration admin path cannot drift apart.
    /// @dev Invariants, in the order checked:
    ///      - loss cap: `maxRebalanceLossBps <= maxLossCapBps`.
    ///      - calm gate + centering must be configured at all (a zero twapWindow, a non-positive
    ///        maxTickDeviation, or a zero maxCenterDeviation each disable a guard silently).
    ///      - `minWidth >= 2 * tickSpacing`: a narrower width can never straddle an ALIGNED spot,
    ///        so every balanced rebalance would revert inside `alignedRange`.
    ///      - both widths aligned to `2 * tickSpacing` (which implies spacing-aligned; an unaligned
    ///        bound only fails deep inside the pool mint). The EVEN-multiple requirement — not merely
    ///        spacing-aligned — is what makes the rebalance paths' tick commitment pin the ALT's
    ///        ANCHOR: the balanced main is `[floorAlign(spot - width/2), +width]`, so only when
    ///        `width/2` is itself a multiple of `tickSpacing` does the committed `tickLower` determine
    ///        `floorAlign(spot) = tickLower + width/2`, which is the anchor `mintAlt` places the alt
    ///        from. With an ODD multiple (e.g. spacing 100, width 300) spot has a 2-spacing-wide
    ///        preimage for the same main range — spot 150 and spot 249 both give main [0, 300] —
    ///        and the alt slides a full spacing while TickMismatch stays silent. `minWidth >=
    ///        2 * tickSpacing` above guarantees the smallest legal width already satisfies this, so
    ///        the constraint never makes a config uninhabitable. NOTE the two limits of what this
    ///        buys. (i) The inversion is PER-BRANCH and the commitment does not name the branch: at
    ///        `width == 2 * tickSpacing` a balanced pair and a token1-single-sided pair collide on
    ///        the same ticks at different anchors, so the pair alone does not determine the anchor.
    ///        Only `width >= 4 * tickSpacing` (i.e. `minWidth > 2 * maxTickDeviation`) rules that
    ///        out; this validator does NOT enforce it, it is a config choice. (ii) Even then it pins
    ///        the alt's candidate RANGES, not which side is chosen — see the SCOPE OF THE
    ///        COMMITMENT note on `LPAutoBalancerV2.rebuildAfterSwap`.
    ///      - `maxWidth <= int24.max`: widths are uint24 but the tick math casts them to int24,
    ///        which bit-REINTERPRETS rather than reverting — a huge maxWidth passes every check
    ///        above and then corrupts the geometry.
    function validateRebalanceConfig(
        uint24 minWidth,
        uint24 maxWidth,
        uint24 maxCenterDeviation,
        uint32 twapWindow,
        int24 maxTickDeviation,
        uint16 maxRebalanceLossBps,
        uint16 maxLossCapBps,
        int24 tickSpacing
    ) public pure {
        if (maxRebalanceLossBps > maxLossCapBps) revert LossCapExceeded();
        if (twapWindow == 0 || maxTickDeviation <= 0 || maxCenterDeviation == 0) revert InvalidConfig();
        if (tickSpacing <= 0) revert InvalidConfig();
        if (minWidth < 2 * uint24(tickSpacing) || maxWidth < minWidth) revert WidthTooNarrow();
        if (minWidth % (2 * uint24(tickSpacing)) != 0 || maxWidth % (2 * uint24(tickSpacing)) != 0) {
            revert InvalidWidth();
        }
        if (maxWidth > uint24(type(int24).max)) revert WidthOutOfBounds();
    }

    /// @dev Redeclared so `skimFees` logs the same topic as LPAutoBalancerV2.FeesSkimmed (event topic
    ///      is keccak of the signature; emitted from the balancer's address under DELEGATECALL).
    event FeesSkimmed(uint256 amount0, uint256 amount1);

    /// @dev Cross-validate a position config's pool descriptor and NFT binding (extracted from the
    ///      balancer's _validateAndStore for EIP-170 headroom; runs under DELEGATECALL so
    ///      address(this) is the balancer):
    ///      1. pool token0/token1/tickSpacing must match the supplied descriptor, or every on-chain
    ///         geometry computation would be wrong;
    ///      2. the balancer must hold the NFT;
    ///      3. the NFT's own token0/token1/tickSpacing must match — PoolMismatch in (1) only
    ///         validates the descriptor against `pool`, NOT that the NFT belongs to that pool. A
    ///         position minted against a DIFFERENT pool (wrong fee tier / token order) would
    ///         otherwise register and corrupt every TickMath/LiquidityAmounts computation.
    ///      NOTE: field 4 of the Slipstream `positions()` tuple carries tickSpacing (the same value
    ///      MintParams.tickSpacing consumes), NOT Uniswap's `uint24 fee`. The interface now declares
    ///      it as `int24 tickSpacing`, so this compares signed-to-signed with no cast.
    function validatePoolAndNft(
        address pool,
        address positionManager,
        uint256 mainTokenId,
        address token0,
        address token1,
        int24 spacing
    ) public view {
        if (
            ICLPool(pool).token0() != token0 || ICLPool(pool).token1() != token1
                || ICLPool(pool).tickSpacing() != spacing
        ) revert PoolMismatch();
        if (INonfungiblePositionManager(positionManager).ownerOf(mainTokenId) != address(this)) revert NotHeld();
        (,, address nftToken0, address nftToken1, int24 nftSpacing,,,,,,,) =
            INonfungiblePositionManager(positionManager).positions(mainTokenId);
        if (nftToken0 != token0 || nftToken1 != token1 || nftSpacing != spacing) {
            revert PoolMismatch();
        }
    }

    /// @dev Validate a gauge binding (shared by registerPosition/setPool via _validateAndStore AND
    ///      setGauge, so the two admin paths cannot drift): a non-zero gauge must reward in `aero`
    ///      (or staked emissions would be stranded) and must be the gauge for THIS `pool` — a valid
    ///      AERO-rewarding gauge for a different pool would otherwise be accepted and only fail
    ///      later, deep inside stake()/_restakeBoth on the rebalance path.
    function validateGauge(address gauge, address pool, address aero) public view {
        if (gauge != address(0)) {
            if (ICLGauge(gauge).rewardToken() != aero) revert GaugeRewardMismatch();
            if (ICLGauge(gauge).pool() != pool) revert PoolMismatch();
        }
    }

    /// @notice Collect accrued LP fees for `tokenId` (recipient = the balancer under DELEGATECALL) and
    ///         forward both legs to `feeCollector`. Emits FeesSkimmed. Call BEFORE decreasing liquidity
    ///         so only fees (not principal) are swept to the feeCollector.
    function skimFees(address positionManager, address token0, address token1, address feeCollector, uint256 tokenId)
        public
    {
        (uint256 a0, uint256 a1) = INonfungiblePositionManager(positionManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        if (a0 > 0) IERC20(token0).safeTransfer(feeCollector, a0);
        if (a1 > 0) IERC20(token1).safeTransfer(feeCollector, a1);
        emit FeesSkimmed(a0, a1);
    }

    /// @notice Remove ALL liquidity from `tokenId` and collect the resulting tokens into the balancer
    ///         (recipient = address(this), which is the balancer under DELEGATECALL). `amount0Min`/
    ///         `amount1Min` are the caller-supplied sandwich floor enforced by the PM on the decrease
    ///         (0 skips the floor); `deadline` is forwarded so the caller's deadline guard applies to
    ///         the withdraw leg. A zero-liquidity position skips the decrease but still collects fees.
    function decreaseLiquidityAll(
        address positionManager,
        uint256 tokenId,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) public {
        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);
        (,,,,,,, uint128 liq,,,,) = pm.positions(tokenId);
        if (liq > 0) {
            pm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liq,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: deadline
                })
            );
        }
        pm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    /// @notice Mint a Slipstream CL position from the balancer's FULL current token balances (NO SWAP).
    ///         Approves the position manager for both balances, builds MintParams (recipient = the
    ///         balancer, since this runs via DELEGATECALL), mints, and returns the new tokenId. The
    ///         position manager consumes only the in-ratio portion; any leftover stays on the balancer.
    /// @dev Shared by `_mintBalanced` (spot-centered straddle) and `_mintAlt` (single-sided): the
    ///      caller pre-computes the tick range and per-leg mins; this only does the approve+build+mint.
    ///      `sqrtPriceX96` is 0 (pool already initialized).
    function mintPosition(
        address positionManager,
        address token0,
        address token1,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) public returns (uint256 tokenId) {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));

        IERC20(token0).forceApprove(positionManager, bal0);
        IERC20(token1).forceApprove(positionManager, bal1);

        ICLPositionManager.MintParams memory mp = ICLPositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: bal0,
            amount1Desired: bal1,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: deadline,
            sqrtPriceX96: 0
        });
        (tokenId,,,) = ICLPositionManager(positionManager).mint(mp);
    }

    /// @notice The geometry of `tokenId`: its tick range and stored liquidity.
    /// @dev Exists so the balancer never decodes the position manager's 12-field return tuple
    ///      itself — that decode is several hundred bytes of bytecode per call site, and the
    ///      balancer is within a few hundred bytes of EIP-170.
    function positionTicks(address positionManager, uint256 tokenId)
        public
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        (,,,,, tickLower, tickUpper, liquidity,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);
    }

    /// @notice Total AERO earned across the staked legs, tolerating a broken gauge.
    /// @dev A leg whose `earned` reverts contributes 0 rather than bricking the read. This is a
    ///      DIAGNOSTIC path (the off-chain agent's primary read interface) — it must stay callable
    ///      even when the gauge misbehaves, which is why the try/catch is here rather than letting
    ///      the whole snapshot revert.
    function earnedTolerant(
        address gauge,
        address owner,
        uint256 mainTokenId,
        bool mainStaked,
        uint256 altTokenId,
        bool altStaked
    ) public view returns (uint256 total) {
        if (mainStaked) {
            try ICLGauge(gauge).earned(owner, mainTokenId) returns (uint256 e) {
                total += e;
            } catch {}
        }
        if (altStaked && altTokenId != 0) {
            try ICLGauge(gauge).earned(owner, altTokenId) returns (uint256 e) {
                total += e;
            } catch {}
        }
    }

    /// @notice Inputs for `mintAlt` — grouped so the balancer passes one memory struct (it is within
    ///         a few hundred bytes of EIP-170).
    /// @param minAltValueUsd the balancer's MIN_ALT_VALUE_USD, passed in so the constant keeps a
    ///        single definition site.
    struct AltParams {
        address positionManager;
        address token0;
        address token1;
        address holder;
        int24 spotTick;
        int24 tickSpacing;
        uint8 dec0;
        uint8 dec1;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        uint256 minAltValueUsd;
    }

    /// @notice Mint the single-sided `alt` from the post-main-mint leftover (NO SWAP). The surplus
    ///         leg is whichever token holds the most USD VALUE (never raw base units — the pair's
    ///         decimals differ, e.g. WETH 18 / cbBTC 8). Returns 0 (minting nothing) when the surplus
    ///         is below `minAltValueUsd`: a sub-tick remainder too small to seed liquidity.
    /// @dev Anchored to SPOT, not to the main range's bounds, with floor = floorAlign(spotTick):
    ///        - token0 surplus => [floor + spacing, floor + 2*spacing]  (tickLower strictly > spot)
    ///        - token1 surplus => [floor - spacing, floor]              (tickUpper <= spot)
    ///      Those are the CLOSEST single-token ranges to spot. Activity is
    ///      `tickLower <= tick < tickUpper`, so a token0 alt only needs tickLower above spot and a
    ///      token1 alt only needs tickUpper at or below it — anchoring to the main bounds instead
    ///      parked the alt width/2 ticks away on the straddle branch, where it earned nothing until
    ///      price traversed half the main width. Overlapping the main range is fine: separate NFTs,
    ///      independent liquidity.
    /// @dev Anchoring on spot keeps the alt's ANCHOR inside the callers' tick commitment, but not its
    ///      SIDE. `validateRebalanceConfig` forces every legal width to be an even multiple of
    ///      tickSpacing, which makes `floorAlign(spotTick)` a function of the committed MAIN bounds
    ///      (see the TICK COMMITMENT note on `LPAutoBalancerV2.rebuildAfterSwap`), so committing the
    ///      main range pins both candidate alt ranges below to exact ticks. It does NOT pin which one
    ///      is minted: `surplus0` is decided from the post-`_mintBalanced` residual balances, and the
    ///      position manager splits those at the exact `sqrtP`, not at `floorAlign(spotTick)` — so a
    ///      spot that moves within the committed bucket can flip the side while TickMismatch stays
    ///      silent. See the SCOPE OF THE COMMITMENT note on `rebuildAfterSwap` for the bound on that.
    /// @dev Forwards NO dust. The caller must run the value floor AFTER this returns — counting both
    ///      the fresh alt and any loose balance — and only THEN forward the sub-threshold remainder;
    ///      forwarding here would let a non-trivial surplus escape the floor as "dust".
    function mintAlt(AltParams memory ap, LPValuationLib.OracleConfig memory cfg) public returns (uint256 altId) {
        uint256 value0 = LPValuationLib.valueInUsd(IERC20(ap.token0).balanceOf(ap.holder), 0, cfg, ap.dec0, ap.dec1);
        uint256 value1 = LPValuationLib.valueInUsd(0, IERC20(ap.token1).balanceOf(ap.holder), cfg, ap.dec0, ap.dec1);

        bool surplus0 = value0 >= value1;
        if ((surplus0 ? value0 : value1) < ap.minAltValueUsd) {
            return 0; // genuine dust: caller forwards it after the value floor.
        }

        // `floor` is the largest aligned tick <= spot, so floor + spacing is strictly above spot
        // (also when spot is exactly aligned), and `floor` itself is <= spot.
        int24 floorTick = LPGeometryLib.floorAlign(ap.spotTick, ap.tickSpacing);
        int24 altTl;
        int24 altTu;
        if (surplus0) {
            altTl = floorTick + ap.tickSpacing;
            altTu = altTl + ap.tickSpacing;
        } else {
            altTu = floorTick;
            altTl = floorTick - ap.tickSpacing;
        }

        // Single-sided: force the UNFUNDED leg's min to 0. The caller cannot predict which leg the
        // surplus lands on (selection is by USD value at execution time), so a nonzero min on the
        // leg that ends up unfunded would revert an otherwise-valid mint.
        altId = mintPosition(
            ap.positionManager,
            ap.token0,
            ap.token1,
            ap.tickSpacing,
            altTl,
            altTu,
            surplus0 ? ap.amount0Min : 0,
            surplus0 ? 0 : ap.amount1Min,
            ap.deadline
        );
    }

    /// @notice Guards + calm-gate for phase 1 of a swap rebalance (unwindForSwap).
    /// @dev Takes primitives (never the `ManagedPositionV2` storage struct), so that struct stays
    ///      defined on the balancer. All reads go to the passed-in pool/token addresses — the guards
    ///      and the calm gate never consult msg.sender/address(this), so behavior is identical to an
    ///      inline check regardless of call context. Returns the current sqrt price and both token
    ///      decimals so the caller can reuse its shared `_totalValue` for the snapshot. The calm gate
    ///      itself lives in LPGeometryLib.
    function unwindPrecheck(
        bool active,
        bool inFlight,
        uint256 lastRebalance,
        uint256 minRebalanceInterval,
        address compoundModule,
        address token0,
        address token1,
        address sellToken,
        uint256 sellAmount,
        address pool,
        uint32 twapWindow,
        int24 maxTickDeviation
    ) public view returns (uint160 sqrtP, uint8 dec0, uint8 dec1) {
        if (!active) revert NotActive();
        if (inFlight) revert AlreadyInFlight();
        if (block.timestamp < lastRebalance + minRebalanceInterval) revert Cooldown();
        if (compoundModule == address(0)) revert ModuleNotSet();
        if (sellToken != token0 && sellToken != token1) revert InvalidSellToken();
        if (sellAmount == 0) revert InvalidSellToken();

        (sqrtP,, dec0, dec1) = LPGeometryLib.calmGate(pool, twapWindow, maxTickDeviation, token0, token1);
    }
}
