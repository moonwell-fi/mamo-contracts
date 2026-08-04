// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title Uniswap V3 style router interface (fee-tier based, unlike the Aerodrome tickSpacing variant)
/// @notice Minimal surface used by MorphoVaultsStrategy for reward compounding on chains without CoW Protocol
/// @dev This is SwapRouter02's IV3SwapRouter shape: NO deadline field (selector 0x04e45aaf). The router
///      deployed on Robinhood Chain (0xCaf681a66D020601342297493863E78C959E5cb2) only dispatches this
///      variant — the original SwapRouter's 8-field struct (0x414bf389) is not in its dispatch table.
///      Deadline protection, if needed, goes through the router's `multicall(uint256 deadline, bytes[])`.
interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
