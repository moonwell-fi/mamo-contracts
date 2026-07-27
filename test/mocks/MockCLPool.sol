// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title MockCLPool
 * @notice Minimal Aerodrome Slipstream CL pool stand-in for unit tests: a settable token pair,
 *         tickSpacing, and the two oracle reads the vendored leveraged-Aero code makes
 *         (`slot0`, `observe`).
 * @dev Distinct from {MockPool}, which models a plain Aerodrome v2 pool (token pair only) and is
 *      wired into the staking-registry suites. Slipstream pools are tickSpacing-keyed and carry a
 *      TWAP oracle, so they get their own mock rather than growing that one.
 */
contract MockCLPool {
    address public token0;
    address public token1;
    int24 public tickSpacing;

    uint160 public sqrtPriceX96 = 79228162514264337593543950336; // 1:1
    int24 public tick;

    /// @notice Per-second tick used to synthesise `observe` cumulatives (flat TWAP == `tick`).
    int24 public twapTick;

    constructor(address token0_, address token1_, int24 tickSpacing_) {
        token0 = token0_;
        token1 = token1_;
        tickSpacing = tickSpacing_;
    }

    // ── Setters ──

    function setTokens(address token0_, address token1_) external {
        token0 = token0_;
        token1 = token1_;
    }

    function setTickSpacing(int24 tickSpacing_) external {
        tickSpacing = tickSpacing_;
    }

    function setTick(int24 tick_) external {
        tick = tick_;
        twapTick = tick_;
    }

    function setTwapTick(int24 twapTick_) external {
        twapTick = twapTick_;
    }

    function setSqrtPriceX96(uint160 sqrtPriceX96_) external {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    // ── ICLPool ──

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (sqrtPriceX96, tick, 0, 1, 1, true);
    }

    /// @dev Returns cumulatives consistent with a constant `twapTick` over the window, so the
    ///      calm-gate's `(cum[1] - cum[0]) / window` recovers `twapTick` exactly.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            // Cumulative measured backwards from now: -(secondsAgo) * twapTick.
            tickCumulatives[i] = -int56(int32(int256(uint256(secondsAgos[i])))) * int56(twapTick);
        }
    }

    function fee() external pure returns (uint24) {
        return 500;
    }

    function gauge() external pure returns (address) {
        return address(0);
    }
}
