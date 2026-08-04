// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title Uniswap V3 style router interface (fee-tier based, unlike the Aerodrome tickSpacing variant)
/// @notice Minimal surface used by MorphoVaultsStrategy for reward compounding on chains without CoW Protocol
interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
