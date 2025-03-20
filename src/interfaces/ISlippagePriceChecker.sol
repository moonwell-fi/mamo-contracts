// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISlippagePriceChecker
 * @notice Interface for swap checking functionality
 * @dev Combines price checking and expected output calculation
 */
interface ISlippagePriceChecker {
    /**
     * @notice Configuration for a token's price feed
     * @dev Stores the Chainlink feed address and whether to reverse the price calculation
     * @param chainlinkFeed The address of the Chainlink price feed
     * @param reverse Whether to reverse the price calculation (divide instead of multiply)
     */
    struct TokenFeedConfiguration {
        address chainlinkFeed;
        bool reverse;
    }

    /**
     * @notice Maps token addresses to their oracle configurations
     * @dev Each token can have multiple price feed configurations in sequence
     * @param token The token address to get oracle information for
     * @return Array of TokenFeedConfiguration for the token
     */
    function tokenOracleInformation(address token) external view returns (TokenFeedConfiguration[] memory);
    /**
     * @notice Checks if a swap meets the price requirements
     * @param _amountIn The input amount
     * @param _fromToken The token to swap from
     * @param _toToken The token to swap to
     * @param _minOut The minimum output amount
     * @param _slippageInBps The allowed slippage in basis points (e.g., 100 = 1%)
     * @return Whether the swap meets the price requirements
     */
    function checkPrice(
        uint256 _amountIn,
        address _fromToken,
        address _toToken,
        uint256 _minOut,
        uint256 _slippageInBps
    ) external view returns (bool);

    /**
     * @notice Gets the expected output amount for a swap
     * @param _amountIn The input amount
     * @param _fromToken The token to swap from
     * @param _toToken The token to swap to
     * @return The expected output amount
     */
    function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken) external view returns (uint256);
}
