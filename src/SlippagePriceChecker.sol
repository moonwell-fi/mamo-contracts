// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
     * @notice The internal fixed-point scale every quote is carried at
     * @dev Quotes are normalized to this many decimals before the first price-feed hop and converted
     *      back to the output token's smallest units exactly once, at the end. Carrying the running
     *      value at the sell token's own (possibly tiny) precision made every hop truncate up to a
     *      whole unit at that scale, and later hops amplified the error.
     */
    uint256 internal constant INTERNAL_DECIMALS = 36;

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

    // ==================== Storage appended after the initial deployment ====================
    // NOTE: this contract is behind a UUPS proxy and has no storage gap. Everything below was added
    // after the first deployment, so new variables MUST be appended here and never reordered.

    /**
     * @notice Number of distinct toTokens currently configured for a given fromToken
     * @dev Lets isRewardToken() answer from real pair configuration without enumerating the nested
     *      tokenPairOracleData mapping.
     */
    mapping(address fromToken => uint256 configuredPairs) public configuredPairCount;

    /**
     * @notice Chainlink L2 sequencer uptime feed (address(0) disables the check)
     */
    address public sequencerUptimeFeed;

    /**
     * @notice Seconds that must elapse after the sequencer comes back up before prices are trusted
     */
    uint256 public sequencerGracePeriod;

    /**
     * @notice Optional per-aggregator sane-range bounds
     * @param minAnswer Lowest answer accepted from this feed
     * @param maxAnswer Highest answer accepted from this feed; zero means "no bounds configured"
     */
    struct FeedBounds {
        uint256 minAnswer;
        uint256 maxAnswer;
    }

    /**
     * @notice Maps a Chainlink feed to its configured sane-range bounds
     */
    mapping(address chainlinkFeed => FeedBounds bounds) public feedBounds;

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
     * @notice Emitted when the sequencer uptime feed or its grace period changes
     * @param sequencerUptimeFeed The new sequencer uptime feed (address(0) disables the check)
     * @param gracePeriod The new post-recovery grace period in seconds
     */
    event SequencerUptimeFeedSet(address indexed sequencerUptimeFeed, uint256 gracePeriod);

    /**
     * @notice Emitted when a feed's sane-range bounds change
     * @param chainlinkFeed The feed the bounds apply to
     * @param minAnswer The lowest accepted answer
     * @param maxAnswer The highest accepted answer; zero clears the bounds
     */
    event FeedBoundsSet(address indexed chainlinkFeed, uint256 minAnswer, uint256 maxAnswer);

    /**
     * @notice Locks the implementation contract so it cannot be initialized directly
     * @dev Without this, anyone can call initialize() on the implementation and become its owner,
     *      which is enough to authorize an upgrade of the implementation itself.
     */
    constructor() {
        _disableInitializers();
    }

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

        // Track the pair the first time it is configured so isRewardToken() can answer from real
        // pair configuration rather than from the legacy maxTimePriceValid mapping.
        if (tokenPairOracleData[fromToken][toToken].length == 0) {
            configuredPairCount[fromToken] += 1;
        }

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

        // Pairs configured before this bookkeeping existed have a zero count; do not underflow.
        if (configuredPairCount[fromToken] > 0) {
            configuredPairCount[fromToken] -= 1;
        }

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

    /**
     * @notice Sets the L2 sequencer uptime feed and the post-recovery grace period
     * @dev Only callable by the owner. Passing address(0) disables the check, which is the state the
     *      contract upgrades into so an in-place upgrade cannot brick pricing before the feed is
     *      configured.
     * @param _sequencerUptimeFeed The Chainlink sequencer uptime feed, or address(0) to disable
     * @param _gracePeriod Seconds that must elapse after the sequencer restarts before prices are used
     */
    function setSequencerUptimeFeed(address _sequencerUptimeFeed, uint256 _gracePeriod) external onlyOwner {
        require(_sequencerUptimeFeed == address(0) || _gracePeriod > 0, "Grace period must be greater than 0");

        sequencerUptimeFeed = _sequencerUptimeFeed;
        sequencerGracePeriod = _gracePeriod;

        emit SequencerUptimeFeedSet(_sequencerUptimeFeed, _gracePeriod);
    }

    /**
     * @notice Sets sane-range bounds for a Chainlink feed
     * @dev Only callable by the owner. Today's aggregators report minAnswer = 1 and
     *      maxAnswer = 2**176 - 1, i.e. representational limits rather than market bounds, so no
     *      answer can saturate. A future proxy upgrade to an aggregator with ACTIVE finite bounds
     *      would report a clamped boundary value as a valid price; these bounds reject that.
     *      Setting maxAnswer to zero clears the bounds for the feed.
     * @param chainlinkFeed The feed the bounds apply to
     * @param minAnswer The lowest accepted answer
     * @param maxAnswer The highest accepted answer, or zero to clear
     */
    function setFeedBounds(address chainlinkFeed, uint256 minAnswer, uint256 maxAnswer) external onlyOwner {
        require(chainlinkFeed != address(0), "Invalid chainlink feed address");
        require(maxAnswer == 0 || maxAnswer > minAnswer, "Invalid bounds");

        feedBounds[chainlinkFeed] = FeedBounds({minAnswer: minAnswer, maxAnswer: maxAnswer});

        emit FeedBoundsSet(chainlinkFeed, minAnswer, maxAnswer);
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
     * @notice Checks if a token is configured as a sellable reward token
     * @dev Answers from real pair configuration: a token is a reward token once at least one
     *      fromToken -> toToken pair has been configured for it. It previously returned
     *      maxTimePriceValid[token] > 0, which addTokenConfiguration never writes, so a pair
     *      configured the modern way reported false and every consumer that gates on this
     *      function (strategy approvals, CoW swap approvals) reverted with "Token not allowed".
     * @dev The legacy maxTimePriceValid term is kept so tokens configured before this contract was
     *      upgraded — whose pairs predate configuredPairCount — keep reporting true.
     * @param token The address of the token to check
     * @return Whether the token is configured as a reward token
     */
    function isRewardToken(address token) external view override returns (bool) {
        return configuredPairCount[token] > 0 || maxTimePriceValid[token] > 0;
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

        _requireSequencerUp();

        uint256 _fromTokenDecimals = uint256(IERC20MetaData(_fromToken).decimals());
        uint256 _toTokenDecimals = uint256(IERC20MetaData(_toToken).decimals());
        require(
            _fromTokenDecimals <= INTERNAL_DECIMALS && _toTokenDecimals <= INTERNAL_DECIMALS,
            "Unsupported token decimals"
        );

        // Normalize the input to a common high-precision scale ONCE, up front, so that no hop
        // truncates at the sell token's own precision.
        uint256 _running = _amountIn * (10 ** (INTERNAL_DECIMALS - _fromTokenDecimals));

        for (uint256 _i = 0; _i < _priceFeedsLen; _i++) {
            IPriceFeed _priceFeed = IPriceFeed(_priceFeeds[_i]);

            (, int256 answer,, uint256 updatedAt,) = _priceFeed.latestRoundData();

            require(answer > 0, "Chainlink price cannot be lower or equal to 0");
            require(updatedAt != 0, "Round is in incompleted state");
            require(updatedAt <= block.timestamp, "Price feed update time in the future");

            require(block.timestamp <= updatedAt + _heartbeats[_i], "Price feed update time exceeds heartbeat");

            _requireAnswerInBounds(_priceFeeds[_i], uint256(answer));

            uint256 _scaleAnswerBy = 10 ** uint256(_priceFeed.decimals());

            // Without a reverse, we multiply amount * price
            // With a reverse, we divide amount / price
            // mulDiv keeps the intermediate product at full 512-bit precision, so the only rounding
            // in the whole chain is the single floor division at the end of each hop.
            _running = _reverses[_i]
                ? Math.mulDiv(_running, _scaleAnswerBy, uint256(answer))
                : Math.mulDiv(_running, uint256(answer), _scaleAnswerBy);
        }

        // Convert to the output token's smallest units exactly once, rounding DOWN so a caller's
        // slippage floor derived from this quote can only tighten, never loosen.
        _expectedOutFromChainlink = _running / (10 ** (INTERNAL_DECIMALS - _toTokenDecimals));
    }

    /**
     * @notice Reverts if the L2 sequencer is down or has not been back up for the grace period
     * @dev No-op while sequencerUptimeFeed is unset. A Chainlink uptime feed answers 0 when the
     *      sequencer is up and 1 when it is down, and startedAt is when that status began.
     */
    function _requireSequencerUp() internal view {
        address _feed = sequencerUptimeFeed;
        if (_feed == address(0)) return;

        (, int256 _answer, uint256 _startedAt,,) = IPriceFeed(_feed).latestRoundData();

        require(_answer == 0, "Sequencer is down");
        require(_startedAt != 0, "Sequencer round is in incompleted state");
        require(block.timestamp >= _startedAt + sequencerGracePeriod, "Sequencer grace period not over");
    }

    /**
     * @notice Reverts if a feed answer falls outside its configured sane range
     * @dev No-op for feeds with no bounds configured (maxAnswer == 0).
     * @param chainlinkFeed The feed the answer came from
     * @param answer The answer to bound-check
     */
    function _requireAnswerInBounds(address chainlinkFeed, uint256 answer) internal view {
        FeedBounds memory _bounds = feedBounds[chainlinkFeed];
        if (_bounds.maxAnswer == 0) return;

        require(answer >= _bounds.minAnswer && answer <= _bounds.maxAnswer, "Chainlink price out of bounds");
    }

    /**
     * @dev Function that authorizes an upgrade to a new implementation
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
