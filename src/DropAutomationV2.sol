// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAerodromeGauge} from "@interfaces/IAerodromeGauge.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DropAutomationV2
 * @notice Collects Mamo fees, swaps the ones that are not paid out as they are into cbBTC, and funds the
 *         MultiRewards streams directly as the rewards distributor of every reward token
 * @dev Reward tokens are never swapped
 */
contract DropAutomationV2 is Ownable {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MAX_SLIPPAGE_BPS = 500;
    uint256 internal constant SWAP_DEADLINE_BUFFER = 300;
    int24 internal constant MAMO_CBBTC_TICK_SPACING = 200;

    /// @notice The MAMO token
    IERC20 public immutable MAMO_TOKEN;

    /// @notice The cbBTC token
    IERC20 public immutable CBBTC_TOKEN;

    /// @notice The MultiRewards contract this contract distributes to
    IMultiRewards public immutable MULTI_REWARDS;

    /// @notice The Aerodrome CL router used for swaps
    ISwapRouter public immutable AERODROME_CL_ROUTER;

    /// @notice The Aerodrome quoter used for the onchain swap minimum
    IQuoter public immutable AERODROME_QUOTER;

    /// @notice The tokens paid out as they are
    address[] public rewardTokens;

    /// @notice Whether a token is paid out as it is
    mapping(address => bool) public isRewardToken;

    /// @notice The Aerodrome gauges rewards are claimed from
    address[] public gauges;

    /// @notice Whether a gauge is configured
    mapping(address => bool) public isGauge;

    /// @notice The address allowed to run drops
    address public dedicatedMsgSender;

    /// @notice The slippage tolerance applied to Aerodrome swaps, in basis points
    uint256 public maxSlippageBps;

    event RewardTokenAdded(address indexed token);
    event RewardTokenRemoved(address indexed token);
    event RewardNotified(address indexed token, uint256 amount);
    event RewardNotifyFailed(address indexed token, bytes reason);
    event TokensSwapped(address indexed token, uint256 amountIn, uint256 amountOut);
    event GaugeAdded(address indexed gauge);
    event GaugeRemoved(address indexed gauge);
    event GaugeWithdrawn(address indexed gauge, address indexed recipient, uint256 amount);
    event DedicatedMsgSenderUpdated(address indexed oldSender, address indexed newSender);
    event MaxSlippageUpdated(uint256 oldValueBps, uint256 newValueBps);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotDedicatedSender();
    error NotSelf();
    error InvalidSlippage();
    error ArrayLengthMismatch();
    error AlreadyAdded(address item);
    error NotFound(address item);
    error RewardTokenNotSwappable(address token);
    error InsufficientOutput();
    error NothingToDistribute();

    modifier onlyDedicatedMsgSender() {
        if (msg.sender != dedicatedMsgSender) revert NotDedicatedSender();
        _;
    }

    /**
     * @param owner_ The contract owner, the F-MAMO Safe
     * @param dedicatedMsgSender_ The address allowed to run drops
     * @param mamoToken_ The MAMO token
     * @param cbBtcToken_ The cbBTC token
     * @param multiRewards_ The MultiRewards contract
     * @param aerodromeRouter_ The Aerodrome CL router
     * @param aerodromeQuoter_ The Aerodrome quoter
     * @param rewardTokens_ The tokens paid out as they are
     */
    constructor(
        address owner_,
        address dedicatedMsgSender_,
        address mamoToken_,
        address cbBtcToken_,
        address multiRewards_,
        address aerodromeRouter_,
        address aerodromeQuoter_,
        address[] memory rewardTokens_
    ) Ownable(owner_) {
        if (
            dedicatedMsgSender_ == address(0) || mamoToken_ == address(0) || cbBtcToken_ == address(0)
                || multiRewards_ == address(0) || aerodromeRouter_ == address(0) || aerodromeQuoter_ == address(0)
        ) revert ZeroAddress();

        dedicatedMsgSender = dedicatedMsgSender_;
        MAMO_TOKEN = IERC20(mamoToken_);
        CBBTC_TOKEN = IERC20(cbBtcToken_);
        MULTI_REWARDS = IMultiRewards(multiRewards_);
        AERODROME_CL_ROUTER = ISwapRouter(aerodromeRouter_);
        AERODROME_QUOTER = IQuoter(aerodromeQuoter_);
        maxSlippageBps = 100;

        for (uint256 i = 0; i < rewardTokens_.length; i++) {
            _addRewardToken(rewardTokens_[i]);
        }
    }

    /////////////////////////// DEDICATED SENDER ///////////////////////////

    /// @notice Claims the rewards of every configured gauge
    function claimGaugeRewards() external onlyDedicatedMsgSender {
        for (uint256 i = 0; i < gauges.length; i++) {
            IAerodromeGauge(gauges[i]).getReward(address(this));
        }
    }

    /**
     * @notice Swaps the given tokens into cbBTC, then funds every reward token's stream with the balance held
     * @param swapTokens_ The tokens to swap, none of them a reward token
     * @param tickSpacings_ The tick spacing of each token's pool
     * @param swapDirectToCbBtc_ Whether each token swaps straight to cbBTC rather than through MAMO
     * @param minAmountOuts_ The minimum cbBTC each token must return
     * @dev A reward token whose notification fails is skipped and stays held for the next drop
     */
    function createDrop(
        address[] calldata swapTokens_,
        int24[] calldata tickSpacings_,
        bool[] calldata swapDirectToCbBtc_,
        uint256[] calldata minAmountOuts_
    ) external onlyDedicatedMsgSender {
        if (
            swapTokens_.length != tickSpacings_.length || swapTokens_.length != swapDirectToCbBtc_.length
                || swapTokens_.length != minAmountOuts_.length
        ) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < swapTokens_.length; i++) {
            _swapToCbBtc(swapTokens_[i], tickSpacings_[i], swapDirectToCbBtc_[i], minAmountOuts_[i]);
        }

        uint256 notified;
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (_notify(rewardTokens[i])) notified++;
        }

        if (notified == 0) revert NothingToDistribute();
    }

    /**
     * @notice Funds one reward stream
     * @dev Only callable by this contract, so a failing token reverts on its own without blocking the drop
     * @param token The reward token
     * @param amount The amount to fund
     */
    function notifyReward(address token, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();

        IERC20(token).forceApprove(address(MULTI_REWARDS), amount);
        MULTI_REWARDS.notifyRewardAmount(token, amount);
    }

    /////////////////////////// OWNER ///////////////////////////

    /**
     * @notice Adds a token paid out as it is
     * @param token The token, whose MultiRewards distributor must be this contract
     */
    function addRewardToken(address token) external onlyOwner {
        _addRewardToken(token);
    }

    /**
     * @notice Removes a token paid out as it is
     * @param token The token
     */
    function removeRewardToken(address token) external onlyOwner {
        if (!isRewardToken[token]) revert NotFound(token);

        _remove(rewardTokens, token);
        isRewardToken[token] = false;

        emit RewardTokenRemoved(token);
    }

    /**
     * @notice Sets the stream duration of a reward token, once its current period has ended
     * @param token The reward token
     * @param duration The new duration in seconds
     */
    function setRewardsDuration(address token, uint256 duration) external onlyOwner {
        MULTI_REWARDS.setRewardsDuration(token, duration);
    }

    /**
     * @notice Adds an Aerodrome gauge to claim rewards from
     * @param gauge The gauge
     */
    function addGauge(address gauge) external onlyOwner {
        if (isGauge[gauge]) revert AlreadyAdded(gauge);
        if (IAerodromeGauge(gauge).stakingToken() == address(0)) revert ZeroAddress();

        gauges.push(gauge);
        isGauge[gauge] = true;

        emit GaugeAdded(gauge);
    }

    /**
     * @notice Removes an Aerodrome gauge
     * @param gauge The gauge
     */
    function removeGauge(address gauge) external onlyOwner {
        if (!isGauge[gauge]) revert NotFound(gauge);

        _remove(gauges, gauge);
        isGauge[gauge] = false;

        emit GaugeRemoved(gauge);
    }

    /**
     * @notice Withdraws staked LP tokens from a gauge
     * @param gauge The gauge
     * @param amount The amount of LP tokens
     * @param recipient The address receiving the LP tokens
     */
    function withdrawGauge(address gauge, uint256 amount, address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();

        IAerodromeGauge(gauge).withdraw(amount);
        IERC20(IAerodromeGauge(gauge).stakingToken()).safeTransfer(recipient, amount);

        emit GaugeWithdrawn(gauge, recipient, amount);
    }

    /**
     * @notice Sets the address allowed to run drops
     * @param newSender The new sender
     */
    function setDedicatedMsgSender(address newSender) external onlyOwner {
        if (newSender == address(0)) revert ZeroAddress();

        emit DedicatedMsgSenderUpdated(dedicatedMsgSender, newSender);
        dedicatedMsgSender = newSender;
    }

    /**
     * @notice Sets the slippage tolerance for swaps
     * @param newSlippageBps The new tolerance, between 1 and 500 basis points
     */
    function setMaxSlippageBps(uint256 newSlippageBps) external onlyOwner {
        if (newSlippageBps == 0 || newSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidSlippage();

        emit MaxSlippageUpdated(maxSlippageBps, newSlippageBps);
        maxSlippageBps = newSlippageBps;
    }

    /**
     * @notice Recovers a token held by the contract
     * @param token The token
     * @param to The recipient
     * @param amount The amount
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);

        emit TokensRecovered(token, to, amount);
    }

    /////////////////////////// VIEWS ///////////////////////////

    /// @notice The tokens paid out as they are
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    /// @notice The configured gauges
    function getGauges() external view returns (address[] memory) {
        return gauges;
    }

    /////////////////////////// INTERNAL ///////////////////////////

    function _notify(address token) internal returns (bool) {
        uint256 amount = IERC20(token).balanceOf(address(this));
        (, uint256 duration,,,,) = MULTI_REWARDS.rewardData(token);

        // Below one unit per second the stream's rate rounds to zero, so the balance waits for the next drop
        if (amount == 0 || amount < duration) return false;

        // The remainder of the division by the duration would never stream, so it is kept for the next drop
        if (duration != 0) amount -= amount % duration;

        try this.notifyReward(token, amount) {
            emit RewardNotified(token, amount);
            return true;
        } catch (bytes memory reason) {
            emit RewardNotifyFailed(token, reason);
            return false;
        }
    }

    function _swapToCbBtc(address token, int24 tickSpacing, bool direct, uint256 minAmountOut) internal {
        if (isRewardToken[token]) revert RewardTokenNotSwappable(token);

        uint256 amountIn = IERC20(token).balanceOf(address(this));
        if (amountIn == 0) return;

        uint256 amountOut;
        if (direct) {
            amountOut = _swap(token, address(CBBTC_TOKEN), amountIn, tickSpacing);
        } else {
            uint256 mamoAmount = _swap(token, address(MAMO_TOKEN), amountIn, tickSpacing);
            amountOut = _swap(address(MAMO_TOKEN), address(CBBTC_TOKEN), mamoAmount, MAMO_CBBTC_TICK_SPACING);
        }

        if (amountOut < minAmountOut) revert InsufficientOutput();
    }

    /// @dev Returns zero without swapping when the quoted minimum rounds to zero, so dust cannot revert a drop
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, int24 tickSpacing)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;

        (uint256 quoted,,,) = AERODROME_QUOTER.quoteExactInputSingle(
            IQuoter.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                tickSpacing: tickSpacing,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 minOut = (quoted * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        if (minOut == 0) return 0;

        IERC20(tokenIn).forceApprove(address(AERODROME_CL_ROUTER), amountIn);

        amountOut = AERODROME_CL_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp + SWAP_DEADLINE_BUFFER,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        emit TokensSwapped(tokenIn, amountIn, amountOut);
    }

    function _addRewardToken(address token) internal {
        if (token == address(0)) revert ZeroAddress();
        if (isRewardToken[token]) revert AlreadyAdded(token);

        rewardTokens.push(token);
        isRewardToken[token] = true;

        emit RewardTokenAdded(token);
    }

    function _remove(address[] storage list, address item) internal {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == item) {
                list[i] = list[list.length - 1];
                list.pop();
                return;
            }
        }
    }
}
