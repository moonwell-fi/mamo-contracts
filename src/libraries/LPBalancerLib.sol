// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICLPool} from "@interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";
import {LiquidityAmounts} from "@libraries/uniswap/LiquidityAmounts.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LPBalancerLib
/// @notice Pure/view geometry + valuation math for LPAutoBalancerV2, deployed as an EXTERNAL
///         (linked) library so its bytecode lives off the balancer — keeping the balancer under
///         the EIP-170 24,576-byte limit. Functions are `public`/`external` on purpose: internal
///         library functions would inline back into the balancer and defeat the size reduction.
/// @dev Errors are redeclared here; a Solidity error's 4-byte selector depends only on its
///      signature, so `LPBalancerLib.StaleOracle.selector == LPAutoBalancerV2.StaleOracle.selector`
///      and existing `vm.expectRevert(...)` matchers keep working.
library LPBalancerLib {
    error StaleOracle();

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
}
