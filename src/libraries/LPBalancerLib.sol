// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";
import {LiquidityAmounts} from "@libraries/uniswap/LiquidityAmounts.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LPBalancerLib
/// @notice Pure/view geometry + valuation math for LPAutoBalancerV2, deployed as an EXTERNAL
///         (linked) library so its bytecode lives off the balancer — keeping the balancer under
///         the EIP-170 24,576-byte limit. Functions are `public`/`external` on purpose: internal
///         library functions would inline back into the balancer and defeat the size reduction.
/// @dev Errors are redeclared here; a Solidity error's 4-byte selector depends only on its
///      signature, so `LPBalancerLib.StaleOracle.selector == LPAutoBalancerV2.StaleOracle.selector`
///      and existing `vm.expectRevert(...)` matchers keep working.
library LPBalancerLib {
    using SafeERC20 for IERC20;

    error StaleOracle();
    // Redeclared to share 4-byte selectors with LPAutoBalancerV2 (see @dev note above) so that
    // unwindPrecheck's reverts match the balancer's own `error` selectors and existing
    // vm.expectRevert(LPAutoBalancerV2.XXX.selector) matchers keep passing unmodified.
    error NotActive();
    error AlreadyInFlight();
    error Cooldown();
    error ModuleNotSet();
    error InvalidSellToken();
    error TwapDeviation();

    /// @dev Redeclared so `skimFees` logs the same topic as LPAutoBalancerV2.FeesSkimmed (event topic
    ///      is keccak of the signature; emitted from the balancer's address under DELEGATECALL).
    event FeesSkimmed(uint256 amount0, uint256 amount1);

    /// @dev Largest spacing-aligned tick <= `tick` (floors toward -inf).
    function floorAlign(int24 tick, int24 spacing) public pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q -= 1;
        return q * spacing;
    }

    /// @dev A `width`-tick range centered on `referenceTick`, both bounds aligned to `spacing`.
    ///      Reverts if `currentTick` does not strictly straddle the range.
    function alignedRange(int24 referenceTick, uint24 width, int24 spacing, int24 currentTick)
        public
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 half = int24(width / 2);
        tickLower = floorAlign(referenceTick - half, spacing);
        tickUpper = tickLower + int24(width);
        require(tickLower < currentTick && currentTick < tickUpper, "no straddle");
    }

    /// @dev Time-weighted average tick over `window` seconds (floored toward -inf).
    function consultTwapTick(address pool, uint32 window) public view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory cum,) = ICLPool(pool).observe(secondsAgos);
        int56 delta = cum[1] - cum[0];
        int24 twapTick = int24(delta / int56(uint56(window)));
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) twapTick--;
        return twapTick;
    }

    /// @dev Read a Chainlink-style feed, validating positivity + freshness against `maxOracleDelay`.
    function readFeed(address feed, uint256 maxOracleDelay) public view returns (uint256 price, uint8 decimals) {
        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(feed).latestRoundData();
        if (answer <= 0) revert StaleOracle();
        if (block.timestamp - updatedAt > maxOracleDelay) revert StaleOracle();
        price = uint256(answer);
        decimals = IPriceFeed(feed).decimals();
    }

    /// @notice Token amounts backing `liq` between ticks `[tl, tu]` at sqrt price `sqrtP`.
    /// @dev Pulls TickMath (large tick lookup) + LiquidityAmounts off the balancer.
    function amountsForLiquidityAtTicks(uint160 sqrtP, int24 tl, int24 tu, uint128 liq)
        public
        pure
        returns (uint256 a0, uint256 a1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liq
        );
    }

    /// @notice Value token amounts in USD scaled to 1e8. Only consults a leg's feed when funded.
    function valueInUsd(
        uint256 amount0,
        uint256 amount1,
        address oracle0,
        address oracle1,
        uint8 dec0,
        uint8 dec1,
        uint256 maxOracleDelay
    ) public view returns (uint256 usd) {
        if (amount0 > 0) {
            (uint256 p0, uint8 fd0) = readFeed(oracle0, maxOracleDelay);
            usd += FullMath.mulDiv(amount0, p0, 10 ** dec0) * (10 ** 8) / (10 ** fd0);
        }
        if (amount1 > 0) {
            (uint256 p1, uint8 fd1) = readFeed(oracle1, maxOracleDelay);
            usd += FullMath.mulDiv(amount1, p1, 10 ** dec1) * (10 ** 8) / (10 ** fd1);
        }
    }

    /// @notice USD value of the principal tokens locked in `tokenId` at sqrt price `sqrtP`. Returns
    ///         0 for tokenId == 0 (no position). Never counts tokensOwed (fees) — only liquidity.
    function principalValue(
        address positionManager,
        uint256 tokenId,
        uint160 sqrtP,
        address oracle0,
        address oracle1,
        uint8 dec0,
        uint8 dec1,
        uint256 maxOracleDelay
    ) public view returns (uint256) {
        if (tokenId == 0) return 0;
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);
        (uint256 a0, uint256 a1) = amountsForLiquidityAtTicks(sqrtP, tl, tu, liq);
        return valueInUsd(a0, a1, oracle0, oracle1, dec0, dec1, maxOracleDelay);
    }

    /// @notice USD value of `holder`'s current (non-position) balances of `token0`/`token1`.
    function contractPairValue(
        address token0,
        address token1,
        address holder,
        address oracle0,
        address oracle1,
        uint8 dec0,
        uint8 dec1,
        uint256 maxOracleDelay
    ) public view returns (uint256) {
        return valueInUsd(
            IERC20(token0).balanceOf(holder),
            IERC20(token1).balanceOf(holder),
            oracle0,
            oracle1,
            dec0,
            dec1,
            maxOracleDelay
        );
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

    /// @notice Read spot (sqrtP + tick), enforce the TWAP deviation gate, and read both token
    ///         decimals — the shared calm-gate preamble for every rebalance path. Reverts TwapDeviation
    ///         when |spot − twap| exceeds `maxTickDeviation`.
    /// @dev Runs via DELEGATECALL, so pool/token reads originate from the balancer's address.
    function calmGate(address pool, uint32 twapWindow, int24 maxTickDeviation, address token0, address token1)
        public
        view
        returns (uint160 sqrtP, int24 spotTick, uint8 dec0, uint8 dec1)
    {
        (sqrtP, spotTick,,,,) = ICLPool(pool).slot0();
        int24 twapTick = consultTwapTick(pool, twapWindow);
        int24 dev = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        if (dev > maxTickDeviation) revert TwapDeviation();
        dec0 = IERC20Metadata(token0).decimals();
        dec1 = IERC20Metadata(token1).decimals();
    }

    /// @notice Guards + calm-gate for phase 1 of a swap rebalance (unwindForSwap).
    /// @dev Takes primitives (never the `ManagedPositionV2` storage struct), so that struct stays
    ///      defined on the balancer. Runs via DELEGATECALL, so every pool/oracle read originates from
    ///      the balancer's address exactly as an inline check would. Returns the current sqrt price and
    ///      both token decimals so the caller can reuse its shared `_totalValue` for the snapshot.
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

        (sqrtP,, dec0, dec1) = calmGate(pool, twapWindow, maxTickDeviation, token0, token1);
    }
}
