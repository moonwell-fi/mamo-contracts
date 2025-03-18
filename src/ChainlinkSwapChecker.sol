// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

pragma abicoder v2;

import {ISwapChecker} from "@interfaces/ISwapChecker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPriceFeed {
    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);
}

interface IERC20MetaData {
    function decimals() external view returns (uint8);
}

/**
 * @title ChainlinkSwapChecker
 * @notice Checks swap prices using Chainlink price feeds and applies slippage tolerance
 * @dev Implements the ISwapChecker interface
 */
contract ChainlinkSwapChecker is ISwapChecker, Ownable {
    uint256 public immutable ALLOWED_SLIPPAGE_IN_BPS;

    uint256 internal constant MAX_BPS = 10_000;

    struct TokenFeedConfiguration {
        address chainlinkFeed;
        bool reverse;
    }

    // Maps token addresses to their price checker data
    mapping(address token => TokenFeedConfiguration[]) public tokenPriceCheckerData;

    // Events
    event TokenConfigured(address indexed token, address indexed chainlinkFeed, bool reverse);

    constructor(uint256 _allowedSlippageInBps) Ownable(msg.sender) {
        require(_allowedSlippageInBps <= MAX_BPS);
        ALLOWED_SLIPPAGE_IN_BPS = _allowedSlippageInBps;
    }

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
        override
        returns (bool)
    {
        // Check that the sell token exists in the mapping
        require(tokenPriceCheckerData[_fromToken].length > 0, "Token not configured");

        // Get expected out using the token configuration from storage
        uint256 _expectedOut = getExpectedOut(_amountIn, _fromToken, _toToken);

        return _minOut > (_expectedOut * (MAX_BPS - ALLOWED_SLIPPAGE_IN_BPS)) / MAX_BPS;
    }

    /**
     * @notice Configures a token with price checker data
     * @dev Only callable by the owner
     *         Allows configurations array to be empty in case the owner wants to delist a configuration
     * @param token The address of the token to configure
     * @param configurations Array of TokenFeedConfiguration for the token
     */
    function configureToken(address token, TokenFeedConfiguration[] calldata configurations) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(configurations.length > 0, "Empty configuration array");

        // Clear any existing configurations
        delete tokenPriceCheckerData[token];

        // Add new configurations
        for (uint256 i = 0; i < configurations.length; i++) {
            require(configurations[i].chainlinkFeed != address(0), "Invalid chainlink feed address");
            tokenPriceCheckerData[token].push(configurations[i]);

            // Emit event for each configuration
            emit TokenConfigured(token, configurations[i].chainlinkFeed, configurations[i].reverse);
        }
    }

    /**
     * @notice Gets the expected output amount for a swap
     * @param _amountIn The input amount
     * @param _fromToken The token to swap from
     * @param _toToken The token to swap to
     * @return The expected output amount
     */
    function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken)
        public
        view
        override
        returns (uint256)
    {
        // Check that the sell token exists in the mapping
        require(tokenPriceCheckerData[_fromToken].length > 0, "Token not configured");

        // Get the token configuration from storage
        TokenFeedConfiguration[] storage configs = tokenPriceCheckerData[_fromToken];

        // Convert to memory arrays for the getExpectedOutFromChainlink function
        address[] memory priceFeeds = new address[](configs.length);
        bool[] memory reverses = new bool[](configs.length);

        for (uint256 i = 0; i < configs.length; i++) {
            priceFeeds[i] = configs[i].chainlinkFeed;
            reverses[i] = configs[i].reverse;
        }

        return getExpectedOutFromChainlink(priceFeeds, reverses, _amountIn, _fromToken, _toToken);
    }

    /**
     * @notice Calculates the expected output amount using Chainlink price feeds
     * @param _priceFeeds The price feeds to use
     * @param _reverses Whether to reverse each price feed
     * @param _amountIn The input amount
     * @param _fromToken The token to swap from
     * @param _toToken The token to swap to
     * @return _expectedOutFromChainlink The expected output amount
     */
    function getExpectedOutFromChainlink(
        address[] memory _priceFeeds,
        bool[] memory _reverses,
        uint256 _amountIn,
        address _fromToken,
        address _toToken
    ) internal view returns (uint256 _expectedOutFromChainlink) {
        uint256 _priceFeedsLen = _priceFeeds.length;

        require(_priceFeedsLen > 0, "Need at least one price feed");
        require(_priceFeedsLen == _reverses.length, "Price feeds and reverses must have same length");

        for (uint256 _i = 0; _i < _priceFeedsLen; _i++) {
            IPriceFeed _priceFeed = IPriceFeed(_priceFeeds[_i]);

            int256 _latestAnswer = _priceFeed.latestAnswer();
            {
                require(_latestAnswer > 0, "Latest answer must be positive");
            }

            uint256 _scaleAnswerBy = 10 ** uint256(_priceFeed.decimals());

            // If it's first iteration, use amountIn to calculate. Else, use the result from the previous iteration.
            uint256 _amountIntoThisIteration = _i == 0 ? _amountIn : _expectedOutFromChainlink;

            // Without a reverse, we multiply amount * price
            // With a reverse, we divide amount / price
            _expectedOutFromChainlink = _reverses[_i]
                ? (_amountIntoThisIteration * _scaleAnswerBy) / uint256(_latestAnswer)
                : (_amountIntoThisIteration * uint256(_latestAnswer)) / _scaleAnswerBy;
        }

        uint256 _fromTokenDecimals = uint256(IERC20MetaData(_fromToken).decimals());
        uint256 _toTokenDecimals = uint256(IERC20MetaData(_toToken).decimals());

        if (_fromTokenDecimals > _toTokenDecimals) {
            // if fromToken has more decimals than toToken, we need to divide
            _expectedOutFromChainlink = _expectedOutFromChainlink / (10 ** (_fromTokenDecimals - _toTokenDecimals));
        } else if (_fromTokenDecimals < _toTokenDecimals) {
            _expectedOutFromChainlink = _expectedOutFromChainlink * (10 ** (_toTokenDecimals - _fromTokenDecimals));
        }
    }
}
