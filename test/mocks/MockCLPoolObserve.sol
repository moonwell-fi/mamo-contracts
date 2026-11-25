// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice CL pool stand-in with a settable two-point tick-cumulative history, for use in tests
contract MockCLPoolObserve {
    address public token0;
    address public token1;
    int24 public tickSpacing = 10;
    int56 public cumulativeAtWindow;
    int56 public cumulativeNow;
    uint160 public secondsPerLiquidityAtWindow;
    uint160 public secondsPerLiquidityNow;
    /// @dev secondsPerLiquidity at the start of the baseline; unset reads as a baseline at near-infinite liquidity
    uint160 public secondsPerLiquidityAtHistory;
    bool public historySet;
    /// @dev Mean tick of the baseline before the window; unset follows the window's own mean
    int24 public baselineTick;
    bool public baselineSet;
    bool public revertOld;
    /// @dev Longest window this pool has history for; 0 means any window
    uint32 public maxObservableWindow;
    address public factory;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    /// @notice Sets the two cumulatives `observe([window, 0])` returns
    function setCumulatives(int56 atWindow, int56 now_) external {
        cumulativeAtWindow = atWindow;
        cumulativeNow = now_;
    }

    /// @notice Mean tick `tick` over `window` seconds, anchored at cumulative zero
    function setMeanTick(int24 tick, uint32 window) external {
        cumulativeAtWindow = 0;
        cumulativeNow = int56(tick) * int56(uint56(window));
    }

    /// @notice Sets the two secondsPerLiquidityCumulativeX128 values `observe([window, 0])` returns
    function setSecondsPerLiquidity(uint160 atWindow, uint160 now_) external {
        secondsPerLiquidityAtWindow = atWindow;
        secondsPerLiquidityNow = now_;
    }

    function setSecondsPerLiquidityAtHistory(uint160 value) external {
        secondsPerLiquidityAtHistory = value;
        historySet = true;
    }

    function setBaselineTick(int24 tick) external {
        baselineTick = tick;
        baselineSet = true;
    }

    function setFactory(address value) external {
        factory = value;
    }

    function setRevertOld(bool value) external {
        revertOld = value;
    }

    /// @notice Caps the history this pool can serve, so longer windows revert "OLD" as Slipstream does
    function setMaxObservableWindow(uint32 value) external {
        maxObservableWindow = value;
    }

    /// @notice Answers `observe([history, window, 0])`; the baseline runs at `baselineTick` before the window
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128)
    {
        if (revertOld) revert("OLD");
        if (maxObservableWindow != 0 && secondsAgos[0] > maxObservableWindow) revert("OLD");
        require(secondsAgos.length == 3 && secondsAgos[2] == 0, "unexpected secondsAgos");
        int56 window = int56(uint56(secondsAgos[1]));
        int56 baselineMean = baselineSet ? int56(baselineTick) : (cumulativeNow - cumulativeAtWindow) / window;

        tickCumulatives = new int56[](3);
        tickCumulatives[0] = cumulativeAtWindow - baselineMean * int56(uint56(secondsAgos[0] - secondsAgos[1]));
        tickCumulatives[1] = cumulativeAtWindow;
        tickCumulatives[2] = cumulativeNow;
        secondsPerLiquidityCumulativeX128 = new uint160[](3);
        unchecked {
            secondsPerLiquidityCumulativeX128[0] =
                historySet ? secondsPerLiquidityAtHistory : secondsPerLiquidityAtWindow - 1;
        }
        secondsPerLiquidityCumulativeX128[1] = secondsPerLiquidityAtWindow;
        secondsPerLiquidityCumulativeX128[2] = secondsPerLiquidityNow;
    }
}
