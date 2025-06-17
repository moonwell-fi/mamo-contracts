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
     * @dev Stores the Chainlink feed address, whether to reverse the price calculation, and heartbeat
     * @param chainlinkFeed The address of the Chainlink price feed
     * @param reverse Whether to reverse the price calculation (divide instead of multiply)
     * @param heartbeat Maximum time in seconds between price feed updates before considering price stale
     */
    struct TokenFeedConfiguration {
        address chainlinkFeed;
        bool reverse;
        uint256 heartbeat;
    }

    /**
     * @notice Maps token addresses to their oracle configurations
     * @dev Each token can have multiple price feed configurations in sequence
     * @param fromToken The token address to swap from
     * @param toToken The token address to swap to
     * @return Array of TokenFeedConfiguration for the token
     */
    function tokenPairOracleInformation(address fromToken, address toToken)
        external
        view
        returns (TokenFeedConfiguration[] memory);

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

    /**
     * @notice Checks if a token is configured as a reward token
     * @dev A token is considered a reward token if it has at least one oracle configuration
     * @param token The address of the token to check
     * @return Whether the token is configured as a reward token
     */
    function isRewardToken(address token) external view returns (bool);

    /**
     * @notice Gets the maximum time a price is considered valid for a token
     * @param token The address of the token to check
     * @return The maximum time in seconds that a price is considered valid
     */
    function maxTimePriceValid(address token) external view returns (uint256);

    /**
     * @notice Adds a configuration for a token pair
     * @dev Only callable by the owner
     * @param fromToken The address of the token to swap from
     * @param toToken The address of the token to swap to
     * @param configurations Array of TokenFeedConfiguration for the token pair
     */
    function addTokenConfiguration(address fromToken, address toToken, TokenFeedConfiguration[] calldata configurations)
        external;

    /**
     * @notice Removes configuration for a token pair
     * @dev Only callable by the owner
     * @param fromToken The address of the token to swap from
     * @param toToken The address of the token to swap to
     */
    function removeTokenConfiguration(address fromToken, address toToken) external;

    /**
     * @notice Sets the maximum time a price is considered valid for a token
     * @dev Only callable by the owner
     * @param fromToken The address of the token to swap from
     * @param maxTimePriceValid Maximum time in seconds that a price is considered valid
     */
    function setMaxTimePriceValid(address fromToken, uint256 maxTimePriceValid) external;

    /**
     * @notice Checks if a token pair is configured
     * @param fromToken The address of the token to swap from
     * @param toToken The address of the token to swap to
     * @return Whether the token pair is configured
     */
    function isTokenPairConfigured(address fromToken, address toToken) external view returns (bool);
}
