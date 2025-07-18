// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IMultiRewards} from "./interfaces/IMultiRewards.sol";
import {ISafe} from "./interfaces/ISafe.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title RewardsDistributorSafeModule
 * @notice A Safe module that enables time-locked reward distribution to MultiRewards contracts
 * @dev This contract acts as a Safe module to manage reward distribution with built-in time delays
 *      for security. It allows an admin to set rewards that can only be executed after a specified
 *      time period, providing protection against immediate malicious actions.
 *
 *      The contract manages a simplified state machine with three main states:
 *      - UNINITIALIZED: No rewards have been set
 *      - NOT_READY: Rewards are not ready to be notified
 *      - PENDING_EXECUTION: Rewards are set and waiting for execution (includes time-locked period)
 *      - EXECUTED: Rewards have been distributed and new rewards can be set
 *
 * @custom:security-contact evm@mamo.bot
 * @custom:audit-status unaudited
 */
contract RewardsDistributorSafeModule is Pausable {
    using SafeERC20 for IERC20;

    /**
     * @notice Struct representing pending reward distribution
     * @param amountToken1 Amount of token1 tokens to distribute as rewards
     * @param amountToken2 Amount of token2 tokens to distribute as rewards
     * @param notifyAfter Timestamp after which rewards can be notified
     * @param isNotified Whether the rewards have been notified
     */
    struct PendingRewards {
        uint256 amountToken1;
        uint256 amountToken2;
        uint256 notifyAfter;
        bool isNotified;
    }

    /// @notice Simplified state enumeration for the reward distribution process
    enum RewardState {
        UNINITIALIZED, // No pending rewards set
        NOT_READY, // Rewards are not ready to be notified
        PENDING_EXECUTION, // Rewards ready to be notified
        EXECUTED // Rewards have been notified and distributed

    }

    /////////////////////////// CONSTANTS ///////////////////////////

    /// @notice Minimum allowed reward duration (7 days)
    uint256 public constant MIN_REWARDS_DURATION = 7 days;

    /// @notice Maximum allowed reward duration (30 days)
    uint256 public constant MAX_REWARDS_DURATION = 30 days;

    /// @notice Minimum allowed execute after time from current timestamp (1 day)
    uint256 public constant MIN_NOTIFY_DELAY = 1 days;

    /// @notice Maximum allowed execute after time from current timestamp (30 days)
    uint256 public constant MAX_NOTIFY_DELAY = 30 days;

    /////////////////////////// IMMUTABLES ///////////////////////////

    /// @notice The Safe smart account that this module is attached to
    ISafe public immutable safe;

    /// @notice The MultiRewards contract interface
    IMultiRewards public immutable multiRewards;

    /// @notice The token1 contract
    IERC20 public immutable token1;

    /// @notice The token2 contract
    IERC20 public immutable token2;

    /////////////////////////// STATE VARIABLES //////////////////////////

    /// @notice The current admin address
    /// @dev Can be updated by safe calls setRewards
    address public admin;

    /// @notice The duration in seconds that rewards are distributed for
    /// @dev Must be between MIN_REWARDS_DURATION and MAX_REWARDS_DURATION
    uint256 public rewardDuration;

    /// @notice The delay in seconds before rewards can be notified
    uint256 public notifyDelay;

    /// @notice The current pending rewards awaiting notification
    PendingRewards public pendingRewards;

    //////////////////////////////// EVENTS ////////////////////////////////

    /// @notice Emitted when the admin address is updated
    /// @param oldAdmin The previous admin address
    /// @param newAdmin The new admin address
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when the reward duration is updated
    /// @param oldDuration The previous reward duration in seconds
    /// @param newDuration The new reward duration in seconds
    event RewardDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice Emitted when the notify delay is updated
    /// @param oldNotifyDelay The previous notify delay in seconds
    /// @param newNotifyDelay The new notify delay in seconds
    event NotifyDelayUpdated(uint256 oldNotifyDelay, uint256 newNotifyDelay);

    /// @notice Emitted when new rewards are added to the pending state
    /// @param amountToken1 The amount of token1 tokens to distribute as rewards
    /// @param amountToken2 The amount of token2 tokens to distribute as rewards
    /// @param notifyAfter The timestamp after which rewards can be executed
    event RewardAdded(uint256 amountToken1, uint256 amountToken2, uint256 notifyAfter);

    /// @notice Emitted when pending rewards are successfully executed
    /// @param token1Amount The amount of token1 tokens distributed
    /// @param token2Amount The amount of token2 tokens distributed
    /// @param notifiedAt The timestamp when rewards were notified
    event RewardsNotified(uint256 token1Amount, uint256 token2Amount, uint256 notifiedAt);

    //////////////////////////////// MODIFIERS ////////////////////////////////

    /// @notice Restricts function access to the admin address only
    /// @dev Reverts with "Only admin can call this function" if caller is not admin
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    /// @notice Restricts function access to the Safe contract only
    /// @dev Reverts with "Only Safe can call this function" if caller is not the Safe
    modifier onlySafe() {
        require(msg.sender == address(safe), "Only Safe can call this function");
        _;
    }

    /// @notice Initializes the RewardsDistributorSafeModule with required contract addresses and configuration
    /// @dev Sets up all immutable contract references and initial state variables
    /// @param _safe The address of the Safe smart account this module will be attached to
    /// @param _multiRewards The address of the MultiRewards contract for reward distribution
    /// @param _token1 The address of the token1 ERC20 token contract
    /// @param _token2 The address of the token2 ERC20 token contract
    /// @param _admin The address that will have admin privileges for this module
    /// @param _rewardDuration The initial reward duration in seconds for time-locked execution
    /// @param _notifyDelay The initial notify delay in seconds for time-locked execution
    constructor(
        address payable _safe,
        address _multiRewards,
        address _token1,
        address _token2,
        address _admin,
        uint256 _rewardDuration,
        uint256 _notifyDelay
    ) {
        require(_safe != address(0), "Invalid Safe address");
        require(_multiRewards != address(0), "Invalid MultiRewards address");
        require(_token1 != address(0), "Invalid token1 address");
        require(_token2 != address(0), "Invalid token2 address");
        require(_admin != address(0), "Invalid admin address");
        require(_rewardDuration > 0, "Invalid reward duration");
        require(_notifyDelay > 0, "Invalid notify delay");

        safe = ISafe(_safe);
        multiRewards = IMultiRewards(_multiRewards);
        token1 = IERC20(_token1);
        token2 = IERC20(_token2);
        admin = _admin;
        rewardDuration = _rewardDuration;
        notifyDelay = _notifyDelay;
    }

    ///////////////////////////// PERMISSIONLESS FUNCTIONS /////////////////////////////

    /// @notice Executes pending rewards by transferring tokens and notifying the MultiRewards contract
    /// @dev Validates timing constraints, token balances, and execution state before proceeding
    /// @dev Sets up reward tokens in MultiRewards if not already configured
    /// @dev Can only be called when rewards are ready for execution (time delay has passed)
    function notifyRewards() external whenNotPaused {
        require(getCurrentState() == RewardState.PENDING_EXECUTION, "Rewards not in pending state");

        uint256 token1Amount = pendingRewards.amountToken1;

        if (token1Amount > 0) {
            require(token1.balanceOf(address(safe)) >= token1Amount, "Insufficient token1 balance");

            _approveTokenFromSafe(address(token1), address(multiRewards), token1Amount);

            (address rewardsDistributor,,,,,) = multiRewards.rewardData(address(token1));
            if (rewardsDistributor == address(0)) {
                _addRewardFromSafe(address(token1), rewardDuration);
            } else {
                _setRewardDurationFromSafe(address(token1), rewardDuration);
            }

            _notifyRewardAmountFromSafe(address(token1), token1Amount);
        }

        uint256 token2Amount = pendingRewards.amountToken2;

        if (token2Amount > 0) {
            require(token2.balanceOf(address(safe)) >= token2Amount, "Insufficient token2 balance");

            _approveTokenFromSafe(address(token2), address(multiRewards), token2Amount);

            (address rewardsDistributor,,,,,) = multiRewards.rewardData(address(token2));
            if (rewardsDistributor == address(0)) {
                _addRewardFromSafe(address(token2), rewardDuration);
            } else {
                _setRewardDurationFromSafe(address(token2), rewardDuration);
            }

            _notifyRewardAmountFromSafe(address(token2), token2Amount);
        }

        pendingRewards.isNotified = true; // state machine transition to EXECUTED
        pendingRewards.notifyAfter = block.timestamp + notifyDelay;

        emit RewardsNotified(token1Amount, token2Amount, block.timestamp);
    }

    //////////////////////////////// VIEW FUNCTIONS ////////////////////////////////

    /// @notice Gets the current state of the reward distribution process using centralized logic
    /// @dev This function provides the single source of truth for state determination
    /// @return The current state as a RewardState enum value
    function getCurrentState() public view returns (RewardState) {
        if (pendingRewards.notifyAfter == 0) {
            return RewardState.UNINITIALIZED;
        }

        if (block.timestamp <= pendingRewards.notifyAfter && !pendingRewards.isNotified) {
            return RewardState.NOT_READY;
        }

        if (block.timestamp > pendingRewards.notifyAfter && !pendingRewards.isNotified) {
            return RewardState.PENDING_EXECUTION;
        }

        return RewardState.EXECUTED;
    }

    /// @notice Gets the timestamp when rewards will be ready for execution
    /// @return The timestamp when notifyRewards can be called, 0 if no rewards pending
    function getExecutionTimestamp() external view returns (uint256) {
        return pendingRewards.notifyAfter;
    }

    //////////////////////////////// ONLY ADMIN ////////////////////////////////

    /// @notice Sets new pending rewards with time-locked execution
    /// @dev Transitions the contract from UNINITIALIZED or EXECUTED to PENDING_EXECUTION state
    /// @dev Validates execution time and ensures previous rewards are executed before setting new ones
    /// @dev Uses centralized state validation through getCurrentState() function
    /// @param amountToken1 The amount of token1 tokens to distribute as rewards
    /// @param amountToken2 The amount of token2 tokens to distribute as rewards
    function addRewards(uint256 amountToken1, uint256 amountToken2) external onlyAdmin whenNotPaused {
        require(
            getCurrentState() == RewardState.EXECUTED || getCurrentState() == RewardState.UNINITIALIZED,
            "Pending rewards waiting to be executed"
        );

        require(token1.balanceOf(address(safe)) >= amountToken1, "Insufficient token1 balance");
        require(token2.balanceOf(address(safe)) >= amountToken2, "Insufficient token2 balance");

        require(amountToken1 > 0 || amountToken2 > 0, "Invalid reward amount");

        if (pendingRewards.notifyAfter == 0) {
            pendingRewards.notifyAfter = 1; // set to 1 at first time to change state to PENDING_EXECUTION
        }

        pendingRewards.amountToken1 = amountToken1;
        pendingRewards.amountToken2 = amountToken2;
        pendingRewards.isNotified = false;

        emit RewardAdded(amountToken1, amountToken2, pendingRewards.notifyAfter);
    }

    //////////////////////////////// ONLY SAFE ////////////////////////////////

    /// @notice Updates the admin address for the contract
    /// @dev Only callable by the Safe contract to maintain proper access control
    /// @param newAdmin The new admin address to set
    function setAdmin(address newAdmin) external onlySafe {
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Updates the reward duration for both reward tokens
    /// @dev Validates duration bounds and updates both token1 and token2 durations
    /// @param newDuration The new duration in seconds for reward distribution
    function setRewardDuration(uint256 newDuration) external onlySafe {
        require(newDuration >= MIN_REWARDS_DURATION && newDuration <= MAX_REWARDS_DURATION, "Invalid reward duration");

        multiRewards.setRewardsDuration(address(token1), newDuration);
        multiRewards.setRewardsDuration(address(token2), newDuration);

        emit RewardDurationUpdated(rewardDuration, newDuration);
        rewardDuration = newDuration;
    }

    /// @notice Updates the notify delay for the contract
    /// @dev Validates delay bounds and updates the notify delay
    /// @param newNotifyDelay The new notify delay in seconds
    function setNotifyDelay(uint256 newNotifyDelay) external onlySafe {
        require(newNotifyDelay >= MIN_NOTIFY_DELAY && newNotifyDelay <= MAX_NOTIFY_DELAY, "Invalid notify delay");

        emit NotifyDelayUpdated(notifyDelay, newNotifyDelay);
        notifyDelay = newNotifyDelay;
    }

    /// @notice Pauses the setRewards and notifyRewards functions
    /// @dev Only callable by the Safe contract to maintain proper access control
    function pause() external onlySafe {
        _pause();
    }

    /// @notice Unpauses the setRewards and notifyRewards functions
    /// @dev Only callable by the Safe contract to maintain proper access control
    function unpause() external onlySafe {
        _unpause();
    }

    //////////////////////////////// INTERNAL FUNCTIONS ////////////////////////////////

    /// @notice Transfers tokens from the Safe to a specified address
    /// @dev Internal function that executes token transfer through Safe's module execution
    /// @param token The address of the token to transfer
    /// @param to The recipient address for the token transfer
    /// @param amount The amount of tokens to transfer
    function _transferFromSafe(address token, address to, uint256 amount) internal {
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, to, amount);

        bool success = safe.execTransactionFromModule(token, 0, data, ISafe.Operation.Call);
        require(success, "Transfer failed");
    }

    /// @notice Approves token spending from the Safe to a specified spender
    /// @dev Internal function that executes token approval through Safe's module execution
    /// @param token The address of the token to approve
    /// @param spender The address authorized to spend the tokens
    /// @param amount The amount of tokens to approve for spending
    function _approveTokenFromSafe(address token, address spender, uint256 amount) internal {
        bytes memory data = abi.encodeWithSelector(IERC20.approve.selector, spender, amount);

        bool success = safe.execTransactionFromModule(token, 0, data, ISafe.Operation.Call);
        require(success, "Approve failed");
    }

    /// @notice Notifies the MultiRewards contract of new reward amounts
    /// @dev Internal function that calls notifyRewardAmount on MultiRewards through Safe execution
    /// @param rewardToken The address of the reward token being distributed
    /// @param amount The amount of reward tokens to distribute
    function _notifyRewardAmountFromSafe(address rewardToken, uint256 amount) internal {
        bytes memory data = abi.encodeWithSelector(IMultiRewards.notifyRewardAmount.selector, rewardToken, amount);

        bool success = safe.execTransactionFromModule(address(multiRewards), 0, data, ISafe.Operation.Call);
        require(success, "Notify reward amount failed");
    }

    /// @notice Adds a new reward token to the MultiRewards contract
    /// @dev Internal function that calls addReward on MultiRewards through Safe execution
    /// @param rewardToken The address of the token to add as a reward
    /// @param rewardsDuration The duration over which rewards will be distributed
    function _addRewardFromSafe(address rewardToken, uint256 rewardsDuration) internal {
        bytes memory data =
            abi.encodeWithSelector(IMultiRewards.addReward.selector, rewardToken, address(safe), rewardsDuration);

        bool success = safe.execTransactionFromModule(address(multiRewards), 0, data, ISafe.Operation.Call);
        require(success, "Add reward failed");
    }

    /// @notice Set reward duration for a reward token in the MultiRewards contract
    /// @dev Internal function that calls setRewardsDuration on MultiRewards through Safe execution
    /// @param rewardToken The address of the reward token to set the duration for
    /// @param rewardsDuration The duration over which rewards will be distributed
    function _setRewardDurationFromSafe(address rewardToken, uint256 rewardsDuration) internal {
        bytes memory data =
            abi.encodeWithSelector(IMultiRewards.setRewardsDuration.selector, rewardToken, rewardsDuration);

        bool success = safe.execTransactionFromModule(address(multiRewards), 0, data, ISafe.Operation.Call);
        require(success, "Set reward duration failed");
    }
}
