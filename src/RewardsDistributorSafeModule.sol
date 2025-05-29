// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IBurnAndEarn} from "./interfaces/IBurnAndEarn.sol";

import {IMultiRewards} from "./interfaces/IMultiRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Safe} from "lib/safe-smart-account/contracts/Safe.sol";
import {Enum} from "lib/safe-smart-account/contracts/common/Enum.sol";

/**
 * @title RewardsDistributorSafeModule
 * @notice A Safe module that enables time-locked reward distribution to MultiRewards contracts
 * @dev This contract acts as a Safe module to manage reward distribution with built-in time delays
 *      for security. It allows an admin to set rewards that can only be executed after a specified
 *      time period, providing protection against immediate malicious actions.
 *
 *      The contract manages a state machine with four main states:
 *      - UNINITIALIZED: No rewards have been set
 *      - PENDING_EXECUTION: Rewards are set but time delay hasn't passed
 *      - READY_FOR_EXECUTION: Time delay has passed, rewards can be executed
 *      - EXECUTED: Rewards have been distributed
 *
 * @custom:security-contact evm@mamo.bot
 * @custom:audit-status unaudited
 */
contract RewardsDistributorSafeModule is Pausable {
    using SafeERC20 for IERC20;

    /**
     * @notice Struct representing pending reward distribution
     * @param amountBTC Amount of BTC tokens to distribute as rewards
     * @param amountMAMO Amount of MAMO tokens to distribute as rewards
     * @param notifyAfter Timestamp after which rewards can be notified
     * @param isNotified Whether the rewards have been notified
     */
    struct PendingRewards {
        uint256 amountBTC;
        uint256 amountMAMO;
        uint256 notifyAfter;
        bool isNotified;
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
    Safe public immutable safe;

    /// @notice The BurnAndEarn contract interface
    IBurnAndEarn public immutable burnAndEarn;

    /// @notice The MultiRewards contract interface
    IMultiRewards public immutable multiRewards;

    /// @notice The MAMO token contract
    IERC20 public immutable mamoToken;

    /// @notice The BTC token contract
    IERC20 public immutable btcToken;

    /// @notice The NFT position manager contract
    IERC721 public immutable nftPositionManager;

    /////////////////////////// STATE VARIABLES //////////////////////////

    /// @notice The current admin address
    /// @dev Can be updated by safe calls setRewards
    address public admin;

    /// @notice The duration in seconds that rewards are distributed for
    /// @dev Must be between MIN_REWARDS_DURATION and MAX_REWARDS_DURATION
    uint256 public rewardDuration;

    /// @notice The current pending rewards awaiting notification
    PendingRewards public pendingRewards;

    ///////////////////////////// EVENTS /////////////////////////////

    /// @notice Emitted when the admin address is updated
    /// @param oldAdmin The previous admin address
    /// @param newAdmin The new admin address
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when the reward duration is updated
    /// @param oldDuration The previous reward duration in seconds
    /// @param newDuration The new reward duration in seconds
    event RewardDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice Emitted when new rewards are added to the pending state
    /// @param rewardToken The amount of reward tokens (BTC amount in the current implementation)
    /// @param amount The amount of reward tokens (MAMO amount in the current implementation)
    /// @param notifyAfter The timestamp after which rewards can be executed
    event RewardAdded(uint256 rewardToken, uint256 amount, uint256 notifyAfter);

    /// @notice Emitted when pending rewards are successfully executed
    /// @param mamoAmount The amount of MAMO tokens distributed
    /// @param btcAmount The amount of BTC tokens distributed
    /// @param notifiedAt The timestamp when rewards were notified
    event RewardsNotified(uint256 mamoAmount, uint256 btcAmount, uint256 notifiedAt);

    /// @notice Emitted when a new reward token is added to the MultiRewards contract
    /// @param rewardToken The address of the reward token being added
    /// @param rewardsDistributor The address of the rewards distributor (typically the Safe)
    /// @param rewardsDuration The duration for which rewards will be distributed
    event RewardTokenAdded(address indexed rewardToken, address indexed rewardsDistributor, uint256 rewardsDuration);

    ///////////////////////////// MODIFIERS /////////////////////////////

    /// @notice Restricts function access to the admin address only
    /// @dev Reverts with "Only admin can call this function" if caller is not admin
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    /// @notice Restricts function access to the Safe contract only
    /// @dev Reverts with "Timelock: caller is not the safe" if caller is not the Safe
    modifier onlySafe() {
        require(msg.sender == address(safe), "Timelock: caller is not the safe");
        _;
    }

    /// @notice Initializes the RewardsDistributorSafeModule with required contract addresses and configuration
    /// @dev Sets up all immutable contract references and initial state variables
    /// @param _safe The address of the Safe smart account this module will be attached to
    /// @param _burnAndEarn The address of the BurnAndEarn contract for token burning functionality
    /// @param _multiRewards The address of the MultiRewards contract for reward distribution
    /// @param _mamoToken The address of the MAMO ERC20 token contract
    /// @param _btcToken The address of the BTC ERC20 token contract
    /// @param _nftPositionManager The address of the NFT position manager contract
    /// @param _admin The address that will have admin privileges for this module
    /// @param _rewardDuration The initial reward duration in seconds for time-locked execution
    constructor(
        address payable _safe,
        address _burnAndEarn,
        address _multiRewards,
        address _mamoToken,
        address _btcToken,
        address _nftPositionManager,
        address _admin,
        uint256 _rewardDuration
    ) {
        require(_safe != address(0), "Invalid Safe address");
        require(_burnAndEarn != address(0), "Invalid BurnAndEarn address");
        require(_multiRewards != address(0), "Invalid MultiRewards address");
        require(_mamoToken != address(0), "Invalid MAMO token address");
        require(_btcToken != address(0), "Invalid BTC token address");
        require(_nftPositionManager != address(0), "Invalid NFT position manager address");
        require(_admin != address(0), "Invalid admin address");
        require(_rewardDuration > 0, "Invalid reward duration");

        safe = Safe(_safe);
        burnAndEarn = IBurnAndEarn(_burnAndEarn);
        multiRewards = IMultiRewards(_multiRewards);
        mamoToken = IERC20(_mamoToken);
        btcToken = IERC20(_btcToken);
        nftPositionManager = IERC721(_nftPositionManager);
        admin = _admin;
        rewardDuration = _rewardDuration;
    }

    ///////////////////////////// PERMISSIONLESS FUNCTIONS /////////////////////////////

    /// @notice Executes pending rewards by transferring tokens and notifying the MultiRewards contract
    /// @dev Validates timing constraints, token balances, and execution state before proceeding
    /// @dev Sets up reward tokens in MultiRewards if not already configured
    /// @custom:state-machine Moves from READY_FOR_EXECUTION→EXECUTED state
    function notifyRewards() external whenNotPaused {
        require(getCurrentState() == RewardState.PENDING_EXECUTION, "Rewards not in pending state");
        require(isReadyForExecution(), "Rewards not ready to be executed");

        uint256 mamoAmount = pendingRewards.amountMAMO;
        uint256 btcAmount = pendingRewards.amountBTC;

        if (mamoAmount > 0) {
            require(mamoToken.balanceOf(address(safe)) >= mamoAmount, "Insufficient MAMO balance");

            _approveTokenFromSafe(address(mamoToken), address(multiRewards), mamoAmount);
            _setupRewardToken(address(mamoToken));
            _notifyRewardAmountFromSafe(address(mamoToken), mamoAmount);
        }

        if (btcAmount > 0) {
            require(btcToken.balanceOf(address(safe)) >= btcAmount, "Insufficient BTC balance");
            _setupRewardToken(address(btcToken));

            _approveTokenFromSafe(address(btcToken), address(multiRewards), btcAmount);
            _notifyRewardAmountFromSafe(address(btcToken), btcAmount);
        }

        pendingRewards.isNotified = true;

        emit RewardsNotified(mamoAmount, btcAmount, block.timestamp);
    }

    ///////////////////////////// VIEW FUNCTIONS /////////////////////////////

    /// @notice Returns the timestamp when pending rewards can be executed
    /// @dev View function to check the execution timestamp of pending rewards
    /// @return The timestamp after which rewards can be executed (0 if no pending rewards)
    function notifyAfter() external view returns (uint256) {
        return pendingRewards.notifyAfter;
    }

    ///////////////////////////// ONLY ADMIN /////////////////////////////

    /// @notice Sets new pending rewards with time-locked execution
    /// @dev Transitions the contract from UNINITIALIZED to PENDING_EXECUTION state, or from EXECUTED to PENDING_EXECUTION
    /// @dev Validates execution time and ensures previous rewards are executed before setting new ones
    /// @param _pendingRewards The reward amounts and execution timestamp to set
    function addRewards(PendingRewards memory _pendingRewards) external onlyAdmin whenNotPaused {
        require(
            getCurrentState() == RewardState.EXECUTED || getCurrentState() == RewardState.UNINITIALIZED,
            "Pending rewards waiting to be executed"
        );

        uint256 currentTime = block.timestamp;

        require(mamoToken.balanceOf(address(safe)) >= _pendingRewards.amountMAMO, "Insufficient MAMO balance");
        require(btcToken.balanceOf(address(safe)) >= _pendingRewards.amountBTC, "Insufficient BTC balance");

        require(_pendingRewards.notifyAfter > currentTime, "Notify after time is in the past");
        require(_pendingRewards.notifyAfter >= currentTime + MIN_NOTIFY_DELAY, "Notify after time too soon");
        require(_pendingRewards.notifyAfter <= currentTime + MAX_NOTIFY_DELAY, "Notify after time too far");
        require(
            _pendingRewards.notifyAfter > pendingRewards.notifyAfter,
            "Notify after time is not greater than the previous notify after time"
        );
        require(_pendingRewards.amountBTC > 0 || _pendingRewards.amountMAMO > 0, "Invalid reward amount");

        pendingRewards.notifyAfter = _pendingRewards.notifyAfter;
        pendingRewards.amountBTC = _pendingRewards.amountBTC;
        pendingRewards.amountMAMO = _pendingRewards.amountMAMO;
        pendingRewards.isNotified = false;

        emit RewardAdded(_pendingRewards.amountBTC, _pendingRewards.amountMAMO, _pendingRewards.notifyAfter);
    }

    ///////////////////////////// ONLY SAFE /////////////////////////////

    /// @notice Updates the admin address for the contract
    /// @dev Only callable by the Safe contract to maintain proper access control
    /// @param newAdmin The new admin address to set
    function setAdmin(address newAdmin) external onlySafe {
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Updates the reward duration for both reward tokens
    /// @dev Validates duration bounds and updates both MAMO and BTC token durations
    /// @param newDuration The new duration in seconds for reward distribution
    function setRewardDuration(uint256 newDuration) external onlySafe {
        require(newDuration >= MIN_REWARDS_DURATION && newDuration <= MAX_REWARDS_DURATION, "Invalid reward duration");

        multiRewards.setRewardsDuration(address(mamoToken), newDuration);
        multiRewards.setRewardsDuration(address(btcToken), newDuration);

        emit RewardDurationUpdated(rewardDuration, newDuration);

        rewardDuration = newDuration;
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

    ///////////////////////////// INTERNAL FUNCTIONS /////////////////////////////

    /// @notice Sets up a reward token in the MultiRewards contract if not already configured
    /// @dev Internal function that checks if reward token exists and adds it if necessary
    /// @param rewardToken The address of the token to set up as a reward token
    function _setupRewardToken(address rewardToken) internal {
        (address rewardsDistributor,,,,,) = multiRewards.rewardData(rewardToken);

        if (rewardsDistributor == address(0)) {
            _addRewardFromSafe(rewardToken, rewardDuration);
            emit RewardTokenAdded(rewardToken, address(safe), rewardDuration);
        }
    }

    /// @notice Transfers tokens from the Safe to a specified address
    /// @dev Internal function that executes token transfer through Safe's module execution
    /// @param token The address of the token to transfer
    /// @param to The recipient address for the token transfer
    /// @param amount The amount of tokens to transfer
    function _transferFromSafe(address token, address to, uint256 amount) internal {
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, to, amount);

        bool success = safe.execTransactionFromModule(token, 0, data, Enum.Operation.Call);
        require(success, "Transfer failed");
    }

    /// @notice Approves token spending from the Safe to a specified spender
    /// @dev Internal function that executes token approval through Safe's module execution
    /// @param token The address of the token to approve
    /// @param spender The address authorized to spend the tokens
    /// @param amount The amount of tokens to approve for spending
    function _approveTokenFromSafe(address token, address spender, uint256 amount) internal {
        bytes memory data = abi.encodeWithSelector(IERC20.approve.selector, spender, amount);

        bool success = safe.execTransactionFromModule(token, 0, data, Enum.Operation.Call);
        require(success, "Approve failed");
    }

    /// @notice Notifies the MultiRewards contract of new reward amounts
    /// @dev Internal function that calls notifyRewardAmount on MultiRewards through Safe execution
    /// @param rewardToken The address of the reward token being distributed
    /// @param amount The amount of reward tokens to distribute
    function _notifyRewardAmountFromSafe(address rewardToken, uint256 amount) internal {
        bytes memory data = abi.encodeWithSelector(IMultiRewards.notifyRewardAmount.selector, rewardToken, amount);

        bool success = safe.execTransactionFromModule(address(multiRewards), 0, data, Enum.Operation.Call);
        require(success, "Notify reward amount failed");
    }

    /// @notice Adds a new reward token to the MultiRewards contract
    /// @dev Internal function that calls addReward on MultiRewards through Safe execution
    /// @param rewardToken The address of the token to add as a reward
    /// @param rewardsDuration The duration over which rewards will be distributed
    function _addRewardFromSafe(address rewardToken, uint256 rewardsDuration) internal {
        bytes memory data =
            abi.encodeWithSelector(IMultiRewards.addReward.selector, rewardToken, address(safe), rewardsDuration);

        bool success = safe.execTransactionFromModule(address(multiRewards), 0, data, Enum.Operation.Call);
        require(success, "Add reward failed");
    }

    ///////////////////////////// STATE MACHINE QUERIES /////////////////////////////

    /// @notice Simplified state enumeration for the reward distribution process
    enum RewardState {
        UNINITIALIZED, // No pending rewards set
        PENDING_EXECUTION, // Rewards set but not yet notified
        EXECUTED // Rewards have been notified and distributed

    }

    /// @notice Gets the current state of the reward distribution process
    /// @return The current state as a RewardState enum value
    function getCurrentState() external view returns (RewardState) {
        if (pendingRewards.notifyAfter == 0) {
            return RewardState.UNINITIALIZED;
        }

        if (block.timestamp >= pendingRewards.notifyAfter && !pendingRewards.isNotified) {
            return RewardState.PENDING_EXECUTION;
        }

        return RewardState.EXECUTED;
    }

    /// @notice Checks if rewards are ready for execution (notification)
    /// @return True if rewards can be notified, false otherwise
    function isReadyForExecution() external view returns (bool) {
        return getCurrentState() == RewardState.PENDING_EXECUTION && block.timestamp >= pendingRewards.notifyAfter;
    }

    /// @notice Gets the timestamp when rewards will be ready for execution
    /// @return The timestamp when notifyRewards can be called, 0 if no rewards pending
    function getExecutionTimestamp() external view returns (uint256) {
        return pendingRewards.notifyAfter;
    }
}
