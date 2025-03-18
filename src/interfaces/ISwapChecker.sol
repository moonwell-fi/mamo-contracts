// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISwapChecker
 * @notice Interface for swap checking functionality
 * @dev Combines price checking and expected output calculation
 */
interface ISwapChecker {
    /**
     * @notice Checks if a swap meets the price requirements
     * @param _amountIn The input amount
     * @param _fromToken The token to swap from
     * @param _toToken The token to swap to
     * @param _minOut The minimum output amount
     * @return Whether the swap meets the price requirements
     */
    function checkPrice(uint256 _amountIn, address _fromToken, address _toToken, uint256 _minOut)
        external
        view
        returns (bool);

    /**
     * @notice Gets the expected output amount for a swap
     * @param _amountIn The input amount
     * @param _fromToken The token to swap from
     * @param _toToken The token to swap to
     * @return The expected output amount
     */
    function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken) external view returns (uint256);
}
