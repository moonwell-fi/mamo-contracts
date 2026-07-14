// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {LPGeometryLib} from "@libraries/LPGeometryLib.sol";
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
    ///      NOTE: the INonfungiblePositionManager interface labels field 4 `fee` (Uniswap), but on
    ///      Aerodrome Slipstream this slot carries tickSpacing — the same value MintParams.tickSpacing
    ///      consumes. It is uint24 in the interface, so compare against uint24(spacing).
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
        (,, address nftToken0, address nftToken1, uint24 nftSpacing,,,,,,,) =
            INonfungiblePositionManager(positionManager).positions(mainTokenId);
        if (nftToken0 != token0 || nftToken1 != token1 || nftSpacing != uint24(spacing)) {
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

    /// @notice Guards + calm-gate for phase 1 of a swap rebalance (unwindForSwap).
    /// @dev Takes primitives (never the `ManagedPositionV2` storage struct), so that struct stays
    ///      defined on the balancer. Runs via DELEGATECALL, so every pool/oracle read originates from
    ///      the balancer's address exactly as an inline check would. Returns the current sqrt price and
    ///      both token decimals so the caller can reuse its shared `_totalValue` for the snapshot.
    ///      The calm gate itself lives in LPGeometryLib; the library-to-library call is a DELEGATECALL
    ///      in the same (balancer) context.
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
