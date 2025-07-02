// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title Aerodrome Router interface for token swapping
/// @notice Functions for swapping tokens via Aerodrome protocol
interface ISwapRouterV2 {
    /// @notice Route struct for defining swap paths
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output tokens as possible
     * @param amountIn The amount of input tokens to send
     * @param amountOutMin The minimum amount of output tokens that must be received
     * @param routes An array of Route structs representing the swap path
     * @param to Recipient of the output tokens
     * @param deadline Unix timestamp after which the transaction will revert
     * @return amounts The input token amount and all subsequent output token amounts
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /**
     * @notice Performs chained getAmountOut calculations on any number of pairs
     * @param amountIn The amount of input tokens
     * @param routes An array of Route structs representing the swap path
     * @return amounts The input token amount and all subsequent output token amounts
     */
    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        external
        view
        returns (uint256[] memory amounts);
}
