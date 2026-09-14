// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice CL pool stand-in with a settable two-point tick-cumulative history, for use in tests
contract MockCLPoolObserve {
    address public token0;
    address public token1;
    int24 public tickSpacing = 10;
    int56 public cumulativeAtWindow;
    int56 public cumulativeNow;
    bool public revertOld;

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

    function setRevertOld(bool value) external {
        revertOld = value;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128)
    {
        if (revertOld) revert("OLD");
        require(secondsAgos.length == 2 && secondsAgos[1] == 0, "unexpected secondsAgos");
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = cumulativeAtWindow;
        tickCumulatives[1] = cumulativeNow;
        secondsPerLiquidityCumulativeX128 = new uint160[](2);
    }
}
