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

    /// @notice The {MockCLFactory} this pool reports as its deployer — read by the strategy's init
    ///         swap-pool existence probe (`pool.factory().getPool(usdc, leg, spacing)`).
    address public factory;

    /// @notice The gauge this pool reports as its own. On a real Slipstream pool the Voter writes
    ///         this at gauge creation, which is why venue validation requires it to AGREE with
    ///         `gauge.pool()` — the self-attested direction alone is forgeable by a hostile gauge.
    ///         Defaults to `address(0)` (ungauged), so a test must wire it explicitly, exactly as it
    ///         must wire `gauge.setPool`.
    address public gauge;

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

    function setFactory(address factory_) external {
        factory = factory_;
    }

    function setGauge(address gauge_) external {
        gauge = gauge_;
    }

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

    /// @notice Cap the oracle history `observe` can answer for, in seconds. `0` (the default) means
    ///         unlimited — the pre-existing behaviour, so every existing fixture is unaffected.
    /// @dev Models the ONE failure mode venue validation's TWAP-availability probe exists to catch:
    ///      a real Slipstream pool whose observation cardinality does not yet span the requested
    ///      window REVERTS `observe`, and without a knob here that probe cannot be exercised at all
    ///      (it always succeeded, which is also why the vacuous `observe([0, 0])` at init went
    ///      unnoticed). Set it to `window - 1` to model "pool younger than twapWindow".
    function setMaxObservationAge(uint32 maxObservationAge_) external {
        maxObservationAge = maxObservationAge_;
    }

    /// @notice Oldest observation `observe` will serve, in seconds ago. `0` == unlimited.
    uint32 public maxObservationAge;

    /// @notice Thrown when `observe` is asked for a window the mock's history does not span.
    error MockCLPoolOldestObservation();

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
            if (maxObservationAge != 0 && secondsAgos[i] > maxObservationAge) {
                revert MockCLPoolOldestObservation();
            }
            // Cumulative measured backwards from now: -(secondsAgo) * twapTick.
            tickCumulatives[i] = -int56(int32(int256(uint256(secondsAgos[i])))) * int56(twapTick);
        }
    }

    function fee() external pure returns (uint24) {
        return 500;
    }
}

/**
 * @title MockCLFactory
 * @notice Minimal Slipstream CLFactory stand-in: the `(tokenA, tokenB, tickSpacing) -> pool`
 *         registry the strategy's init probes for the two leg<->USDC swap venues.
 * @dev Registration is order-independent (the real factory sorts the pair), so a test may register
 *      `(usdc, leg)` and the probe may ask for `(leg, usdc)`.
 */
contract MockCLFactory {
    mapping(bytes32 => address) internal _pools;

    /// @notice Register (or clear, with `pool == address(0)`) the pool for a pair + spacing.
    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        _pools[_key(tokenA, tokenB, tickSpacing)] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        return _pools[_key(tokenA, tokenB, tickSpacing)];
    }

    function _key(address tokenA, address tokenB, int24 tickSpacing) internal pure returns (bytes32) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(t0, t1, tickSpacing));
    }
}
