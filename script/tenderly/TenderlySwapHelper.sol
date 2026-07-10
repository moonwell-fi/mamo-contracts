// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal Aerodrome/Uniswap-v3-style CL pool swap interface (the subset the helper needs).
interface ICLPoolSwapMin {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @title TenderlySwapHelper
/// @notice A tiny, deployed swap-callback holder for the Tenderly vnet price-simulation harness.
///         The in-process fork test can be its own swap callback (`uniswapV3SwapCallback`) because the
///         test contract is the swapper; the broadcasting harness cannot — a forge Script isn't a
///         persistent funded contract the pool can call back. So the orchestrator deploys THIS, funds
///         it with token0/token1 via `tenderly_setErc20Balance`, and calls `doSwap` as a broadcast tx
///         to move the pool's spot tick (i.e. simulate a WETH/cbBTC price move). It pays the pool from
///         its own balance in the callback.
contract TenderlySwapHelper {
    /// @notice Swap through `pool` to push its tick. `zeroForOne=true` sells token0 → price/tick falls;
    ///         `false` sells token1 → price/tick rises. `amountIn` is an exact input; `sqrtLimit` should
    ///         be an effectively-unbounded bound (TickMath MIN+1 / MAX-1) for a full push.
    function doSwap(address pool, bool zeroForOne, uint256 amountIn, uint160 sqrtLimit)
        external
        returns (int256 amount0, int256 amount1)
    {
        (amount0, amount1) = ICLPoolSwapMin(pool).swap(address(this), zeroForOne, int256(amountIn), sqrtLimit, "");
    }

    /// @dev Pool callback: pay whatever positive delta is owed, from this contract's own balance.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address pool = msg.sender;
        if (amount0Delta > 0) IERC20Min(ICLPoolSwapMin(pool).token0()).transfer(pool, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20Min(ICLPoolSwapMin(pool).token1()).transfer(pool, uint256(amount1Delta));
    }
}
