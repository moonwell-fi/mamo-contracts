// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20MetaData {
    function decimals() external view returns (uint8);
}

/**
 * @title PriceChecker
 * @notice Checks swap prices using Chainlink price feeds and applies slippage tolerance
 * @dev Implements the ISlippagePriceChecker interface with UUPS upgradeability
 */
contract SlippagePriceChecker is ISlippagePriceChecker, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /**
     * @notice The maximum basis points value (10,000 = 100%)
     * @dev Used for percentage calculations and as an upper bound for slippage
     */
    uint256 internal constant MAX_BPS = 10_000;

    /**
     * @notice Maps token addresses to their oracle configurations
     * @dev Each token can have multiple price feed configurations in sequence
     * @dev DEPRECATED: Use tokenPairOracleData instead
     */
    mapping(address token => TokenFeedConfiguration[]) public tokenOracleData;

    /**
     * @notice Maps token addresses to their maximum time price valid
     */
    mapping(address token => uint256 maxTimePriceValid) public maxTimePriceValid;

    /**
     * @notice Maps token pairs to their oracle configurations
     * @dev Primary storage for token pair configurations (fromToken -> toToken -> configurations)
     */
    mapping(address fromToken => mapping(address toToken => TokenFeedConfiguration[])) public tokenPairOracleData;

    /**
     * @notice Emitted when a token pair's price feed configuration is updated
     * @param fromToken The address of the token to swap from
     * @param toToken The address of the token to swap to
     * @param chainlinkFeed The address of the Chainlink price feed
     * @param reverse Whether to reverse the price calculation
     * @param heartbeat Maximum time between price feed updates
     */
    event TokenPairConfigured(
        address indexed fromToken,
        address indexed toToken,
        address indexed chainlinkFeed,
        bool reverse,
        uint256 heartbeat
    );

    /**
     * @notice Emitted when all price feed configurations for a token pair are removed
     * @param fromToken The address of the token to swap from
     * @param toToken The address of the token to swap to
     */
    event TokenPairConfigurationRemoved(address indexed fromToken, address indexed toToken);

    /**
     * @notice Emitted when the max time price valid is set for a token
     * @param fromToken The address of the token to swap from
     * @param maxTimePriceValid Maximum time in seconds that a price is considered valid
     */
    event MaxTimePriceValidSet(address indexed fromToken, uint256 maxTimePriceValid);

    /**
     * @dev Initializes the contract with the given owner
     * @param _owner The address that will own the contract
     */
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
    }

    // ==================== External Functions ====================

    /**
     * @notice Adds a configuration for a token pair
     * @dev Only callable by the owner
     * @param fromToken The address of the token to swap from
     * @param toToken The address of the token to swap to
     * @param configurations Array of TokenFeedConfiguration for the token pair
     */
    function addTokenConfiguration(address fromToken, address toToken, TokenFeedConfiguration[] calldata configurations)
        external
        onlyOwner
    {
        require(fromToken != address(0), "Invalid from token address");
        require(toToken != address(0), "Invalid to token address");
        require(configurations.length > 0, "Empty configurations array");

        // Clear existing configurations for this pair
        delete tokenPairOracleData[fromToken][toToken];

        // Add new configurations
        for (uint256 i = 0; i < configurations.length; i++) {
            require(configurations[i].chainlinkFeed != address(0), "Invalid chainlink feed address");
            require(configurations[i].heartbeat > 0, "Heartbeat must be greater than 0");
            tokenPairOracleData[fromToken][toToken].push(configurations[i]);

            // Emit event for each configuration
            emit TokenPairConfigured(
                fromToken,
                toToken,
                configurations[i].chainlinkFeed,
                configurations[i].reverse,
                configurations[i].heartbeat
            );
        }
    }

    /**
     * @notice Removes configuration for a token pair
     * @dev Only callable by the owner
     * @param fromToken The address of the token to swap from
     * @param toToken The address of the token to swap to
     */
    function removeTokenConfiguration(address fromToken, address toToken) external onlyOwner {
        require(fromToken != address(0), "Invalid from token address");
        require(toToken != address(0), "Invalid to token address");
        require(tokenPairOracleData[fromToken][toToken].length > 0, "Token pair not configured");

        // Clear configurations
        delete tokenPairOracleData[fromToken][toToken];

        emit TokenPairConfigurationRemoved(fromToken, toToken);
    }

    function setMaxTimePriceValid(address fromToken, uint256 _maxTimePriceValid) external onlyOwner {
        require(fromToken != address(0), "Invalid from token address");
        require(_maxTimePriceValid > 0, "Max time price valid can't be zero");
        maxTimePriceValid[fromToken] = _maxTimePriceValid;

        emit MaxTimePriceValidSet(fromToken, _maxTimePriceValid);
    }

    // ==================== External View Functions ====================

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
    ) external view override returns (bool) {
        // Check that the token pair is configured
        require(tokenPairOracleData[_fromToken][_toToken].length > 0, "Token pair not configured");
        require(_slippageInBps <= MAX_BPS, "Slippage exceeds maximum");

        // Get expected out using the token pair configuration from storage
        uint256 _expectedOut = getExpectedOut(_amountIn, _fromToken, _toToken);

        return _minOut > (_expectedOut * (MAX_BPS - _slippageInBps)) / MAX_BPS;
    }

    /**
     * @notice Checks if a token is configured as a reward token
     * @dev DEPRECATED: This function cannot determine reward tokens in the new token pair model
     * @return Always returns false - use isTokenPairConfigured instead
     */
    function isRewardToken(address) external view override returns (bool) {
        // Return false to indicate this function is deprecated
        return false;
    }

    /**
     * @notice Checks if a token pair is configured
     * @param fromToken The address of the token to swap from
     * @param toToken The address of the token to swap to
     * @return Whether the token pair is configured
     */
    function isTokenPairConfigured(address fromToken, address toToken) external view override returns (bool) {
        return tokenPairOracleData[fromToken][toToken].length > 0 && maxTimePriceValid[fromToken] > 0;
    }

    /**
     * @notice Gets the oracle information for a token pair
     * @param fromToken The address of the token to swap from
     * @param toToken The address of the token to swap to
     * @return Array of TokenFeedConfiguration for the token pair
     */
    function tokenPairOracleInformation(address fromToken, address toToken)
        external
        view
        override
        returns (TokenFeedConfiguration[] memory)
    {
        return tokenPairOracleData[fromToken][toToken];
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
        // Check that the token pair is configured
        require(tokenPairOracleData[_fromToken][_toToken].length > 0, "Token pair not configured");

        // Get the token pair configuration from storage
        TokenFeedConfiguration[] storage configs = tokenPairOracleData[_fromToken][_toToken];

        // Convert to memory arrays for the getExpectedOutFromChainlink function
        address[] memory priceFeeds = new address[](configs.length);
        bool[] memory reverses = new bool[](configs.length);
        uint256[] memory heartbeats = new uint256[](configs.length);

        uint256 configsLen = configs.length;
        for (uint256 i = 0; i < configsLen; i++) {
            priceFeeds[i] = configs[i].chainlinkFeed;
            reverses[i] = configs[i].reverse;
            heartbeats[i] = configs[i].heartbeat;
        }

        return getExpectedOutFromChainlink(priceFeeds, reverses, heartbeats, _amountIn, _fromToken, _toToken);
    }

    // ==================== Internal Functions ====================

    /**
     * @notice Calculates the expected output amount using Chainlink price feeds
     * @param _priceFeeds The price feeds to use
     * @param _reverses Whether to reverse each price feed
     * @param _heartbeats The heartbeats for each price feed
     * @param _amountIn The input amount
     * @param _fromToken The token to swap from
     * @param _toToken The token to swap to
     * @return _expectedOutFromChainlink The expected output amount
     */
    function getExpectedOutFromChainlink(
        address[] memory _priceFeeds,
        bool[] memory _reverses,
        uint256[] memory _heartbeats,
        uint256 _amountIn,
        address _fromToken,
        address _toToken
    ) internal view returns (uint256 _expectedOutFromChainlink) {
        uint256 _priceFeedsLen = _priceFeeds.length;

        require(_priceFeedsLen > 0, "Need at least one price feed");
        require(_priceFeedsLen == _reverses.length, "Price feeds and reverses must have same length");
        require(_priceFeedsLen == _heartbeats.length, "Price feeds and heartbeats must have same length");

        for (uint256 _i = 0; _i < _priceFeedsLen; _i++) {
            IPriceFeed _priceFeed = IPriceFeed(_priceFeeds[_i]);

            (, int256 answer,, uint256 updatedAt,) = _priceFeed.latestRoundData();

            require(answer > 0, "Chainlink price cannot be lower or equal to 0");
            require(updatedAt != 0, "Round is in incompleted state");

            require(block.timestamp <= updatedAt + _heartbeats[_i], "Price feed update time exceeds heartbeat");

            uint256 _scaleAnswerBy = 10 ** uint256(_priceFeed.decimals());

            // If it's first iteration, use amountIn to calculate. Else, use the result from the previous iteration.
            uint256 _amountIntoThisIteration = _i == 0 ? _amountIn : _expectedOutFromChainlink;

            // Without a reverse, we multiply amount * price
            // With a reverse, we divide amount / price
            _expectedOutFromChainlink = _reverses[_i]
                ? (_amountIntoThisIteration * _scaleAnswerBy) / uint256(answer)
                : (_amountIntoThisIteration * uint256(answer)) / _scaleAnswerBy;
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

    /**
     * @dev Function that authorizes an upgrade to a new implementation
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
