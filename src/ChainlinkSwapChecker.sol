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
    /**
     * @notice The allowed slippage in basis points (e.g., 100 = 1%)
     * @dev Used to calculate the minimum acceptable output amount for swaps
     */
    uint256 public ALLOWED_SLIPPAGE_IN_BPS;

    /**
     * @notice The maximum basis points value (10,000 = 100%)
     * @dev Used for percentage calculations and as an upper bound for slippage
     */
    uint256 internal constant MAX_BPS = 10_000;

    /**
     * @notice Maps token addresses to their oracle configurations
     * @dev Each token can have multiple price feed configurations in sequence
     */
    mapping(address token => TokenFeedConfiguration[]) public tokenOracleData;

    /**
     * @notice Emitted when a token's price feed configuration is updated
     * @param token The address of the configured token
     * @param chainlinkFeed The address of the Chainlink price feed
     * @param reverse Whether to reverse the price calculation
     */
    event TokenConfigured(address indexed token, address indexed chainlinkFeed, bool reverse);

    /**
     * @notice Emitted when the slippage tolerance is updated
     * @param oldSlippage The previous slippage value in basis points
     * @param newSlippage The new slippage value in basis points
     */
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);

    constructor(uint256 _allowedSlippageInBps, address _owner) Ownable(_owner) {
        require(_allowedSlippageInBps <= MAX_BPS);
        ALLOWED_SLIPPAGE_IN_BPS = _allowedSlippageInBps;
    }

    // ==================== External Functions ====================

    /**
     * @notice Sets a new slippage tolerance value
     * @dev Only callable by the owner
     * @param _newSlippageInBps The new slippage tolerance in basis points (e.g., 100 = 1%)
     */
    function setSlippage(uint256 _newSlippageInBps) external onlyOwner {
        require(_newSlippageInBps <= MAX_BPS, "Slippage exceeds maximum");

        uint256 oldSlippage = ALLOWED_SLIPPAGE_IN_BPS;
        ALLOWED_SLIPPAGE_IN_BPS = _newSlippageInBps;

        emit SlippageUpdated(oldSlippage, _newSlippageInBps);
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

        // Clear any existing configurations
        delete tokenOracleData[token];

        // Add new configurations
        for (uint256 i = 0; i < configurations.length; i++) {
            require(configurations[i].chainlinkFeed != address(0), "Invalid chainlink feed address");
            tokenOracleData[token].push(configurations[i]);

            // Emit event for each configuration
            emit TokenConfigured(token, configurations[i].chainlinkFeed, configurations[i].reverse);
        }
    }

    // ==================== External View Functions ====================

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
        require(tokenOracleData[_fromToken].length > 0, "Token not configured");

        // Get expected out using the token configuration from storage
        uint256 _expectedOut = getExpectedOut(_amountIn, _fromToken, _toToken);

        return _minOut > (_expectedOut * (MAX_BPS - ALLOWED_SLIPPAGE_IN_BPS)) / MAX_BPS;
    }

    /**
     * @notice Gets the oracle information for a token
     * @dev Implements the interface function to access the token oracle configurations
     * @param token The token address to get oracle information for
     * @return Array of TokenFeedConfiguration for the token
     */
    function tokenOracleInformation(address token) external view override returns (TokenFeedConfiguration[] memory) {
        return tokenOracleData[token];
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
        require(tokenOracleData[_fromToken].length > 0, "Token not configured");

        // Get the token configuration from storage
        TokenFeedConfiguration[] storage configs = tokenOracleData[_fromToken];

        // Convert to memory arrays for the getExpectedOutFromChainlink function
        address[] memory priceFeeds = new address[](configs.length);
        bool[] memory reverses = new bool[](configs.length);

        for (uint256 i = 0; i < configs.length; i++) {
            priceFeeds[i] = configs[i].chainlinkFeed;
            reverses[i] = configs[i].reverse;
        }

        return getExpectedOutFromChainlink(priceFeeds, reverses, _amountIn, _fromToken, _toToken);
    }

    // ==================== Internal Functions ====================

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
