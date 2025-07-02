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
     * @notice Swaps tokens for an exact amount of output tokens
     * @param amountOut The amount of output tokens to receive
     * @param amountInMax The maximum amount of input tokens that can be required
     * @param path An array of token addresses representing the swap path
     * @param to Recipient of the output tokens
     * @param deadline Unix timestamp after which the transaction will revert
     * @return amounts The input token amount and all subsequent output token amounts
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /**
     * @notice Given an input amount of an asset and pair reserves, returns the maximum output amount
     * @param amountIn The amount of input tokens
     * @param reserveIn The amount of input tokens in the pair reserves
     * @param reserveOut The amount of output tokens in the pair reserves
     * @return amountOut The amount of output tokens
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);

    /**
     * @notice Given an output amount of an asset and pair reserves, returns a required input amount
     * @param amountOut The amount of output tokens
     * @param reserveIn The amount of input tokens in the pair reserves
     * @param reserveOut The amount of output tokens in the pair reserves
     * @return amountIn The amount of input tokens
     */
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn);

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

    /**
     * @notice Performs chained getAmountIn calculations on any number of pairs
     * @param amountOut The amount of output tokens
     * @param path An array of token addresses representing the swap path
     * @return amounts The input token amount and all subsequent output token amounts
     */
    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}
