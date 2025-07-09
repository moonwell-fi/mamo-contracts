// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IQuoter
 * @notice Interface for the Aerodrome QuoterV2 contract to get swap quotes
 */
interface IQuoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @notice Returns the amount out received for a given exact input swap without executing the swap
     * @param params The parameters for the quote
     * @return amountOut The amount of tokenOut that would be received
     * @return sqrtPriceX96After The sqrt price after the swap
     * @return initializedTicksCrossed The number of initialized ticks crossed
     * @return gasEstimate The estimated gas used by the swap
     */
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}
