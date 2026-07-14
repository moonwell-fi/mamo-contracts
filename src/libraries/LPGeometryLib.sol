// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICLPool} from "@interfaces/ICLPool.sol";
import {LiquidityAmounts} from "@libraries/uniswap/LiquidityAmounts.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title LPGeometryLib
/// @notice Tick/range geometry for LPAutoBalancerV2: spacing alignment, straddling ranges, TWAP
///         ticks, liquidity->amounts conversion, and the calm gate. Shared invariant of every
///         function here: inputs are ticks/spacings/widths — no oracles, no token custody.
///         Deployed as an EXTERNAL (linked) library so its bytecode lives off the balancer —
///         keeping the balancer under the EIP-170 24,576-byte limit. Functions are
///         `public`/`external` on purpose: internal library functions would inline back into the
///         balancer and defeat the size reduction.
/// @dev Errors are redeclared here; a Solidity error's 4-byte selector depends only on its
///      signature, so `LPGeometryLib.TwapDeviation.selector == LPAutoBalancerV2.TwapDeviation.selector`
///      and existing `vm.expectRevert(...)` matchers keep working.
library LPGeometryLib {
    error TwapDeviation();

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

    /// @notice Read spot (sqrtP + tick), enforce the TWAP deviation gate, and read both token
    ///         decimals — the shared calm-gate preamble for every rebalance path. Reverts TwapDeviation
    ///         when |spot − twap| exceeds `maxTickDeviation`.
    /// @dev All reads go to the passed-in `pool`/`token` addresses — nothing here depends on the
    ///      delegatecall context (msg.sender/address(this) are never consulted).
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
}
