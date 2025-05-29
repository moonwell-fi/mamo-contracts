// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBurnAndEarn} from "./interfaces/IBurnAndEarn.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISafe {
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success);

    function isOwner(address owner) external view returns (bool);
}

interface IMultiRewards {
    function setRewardsDuration(address rewardsToken, uint256 duration) external;
    function notifyRewardAmount(address rewardsToken, uint256 reward) external;
}

contract ConfigurableRewardsModule {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant MAX_CALLER_REWARD_BPS = 1000;
    uint256 public constant MIN_EXECUTION_INTERVAL = 1 hours;
    uint256 public constant MAX_EXECUTION_INTERVAL = 30 days;

    ISafe public immutable safe;
    IBurnAndEarn public immutable burnAndEarn;
    IMultiRewards public immutable multiRewards;
    IERC20 public immutable mamoToken;
    IERC20 public immutable btcToken;

    uint256 public executionInterval;
    uint256 public lastExecutionTime;
    uint256 public callerRewardBps;
    uint256 public mamoMinBalance;
    uint256 public btcMinBalance;

    mapping(uint256 => bool) public authorizedTokenIds;

    event ExecutionIntervalUpdated(uint256 oldInterval, uint256 newInterval, address updatedBy);
    event RewardsExecuted(uint256 timestamp, uint256 mamoDistributed, uint256 btcDistributed, uint256 callerReward);
    event ConfigurationUpdated(string parameter, uint256 oldValue, uint256 newValue, address updatedBy);

    error OnlySafeOwner();
    error InvalidExecutionInterval();
    error InvalidCallerReward();
    error ExecutionTooEarly();
    error InsufficientBalance();
    error TransactionFailed();

    modifier onlySafeOwner() {
        if (!safe.isOwner(msg.sender)) revert OnlySafeOwner();
        _;
    }

    constructor(
        address _safe,
        address _burnAndEarn,
        address _multiRewards,
        address _mamoToken,
        address _btcToken,
        uint256 _initialInterval,
        uint256 _initialCallerRewardBps
    ) {
        if (_initialInterval < MIN_EXECUTION_INTERVAL || _initialInterval > MAX_EXECUTION_INTERVAL) {
            revert InvalidExecutionInterval();
        }
        if (_initialCallerRewardBps > MAX_CALLER_REWARD_BPS) {
            revert InvalidCallerReward();
        }

        safe = ISafe(_safe);
        burnAndEarn = IBurnAndEarn(_burnAndEarn);
        multiRewards = IMultiRewards(_multiRewards);
        mamoToken = IERC20(_mamoToken);
        btcToken = IERC20(_btcToken);
        executionInterval = _initialInterval;
        callerRewardBps = _initialCallerRewardBps;
        lastExecutionTime = block.timestamp;
    }

    function setExecutionInterval(uint256 _newInterval) external onlySafeOwner {
        if (_newInterval < MIN_EXECUTION_INTERVAL || _newInterval > MAX_EXECUTION_INTERVAL) {
            revert InvalidExecutionInterval();
        }

        uint256 oldInterval = executionInterval;
        executionInterval = _newInterval;
        emit ExecutionIntervalUpdated(oldInterval, _newInterval, msg.sender);
    }

    function setCallerRewardPercentage(uint256 _callerRewardBps) external onlySafeOwner {
        if (_callerRewardBps > MAX_CALLER_REWARD_BPS) {
            revert InvalidCallerReward();
        }

        uint256 oldCallerReward = callerRewardBps;
        callerRewardBps = _callerRewardBps;
        emit ConfigurationUpdated("callerRewardBps", oldCallerReward, _callerRewardBps, msg.sender);
    }

    function setMinimumBalances(uint256 _mamoMinBalance, uint256 _btcMinBalance) external onlySafeOwner {
        uint256 oldMamoMinBalance = mamoMinBalance;
        uint256 oldBtcMinBalance = btcMinBalance;

        mamoMinBalance = _mamoMinBalance;
        btcMinBalance = _btcMinBalance;

        emit ConfigurationUpdated("mamoMinBalance", oldMamoMinBalance, _mamoMinBalance, msg.sender);
        emit ConfigurationUpdated("btcMinBalance", oldBtcMinBalance, _btcMinBalance, msg.sender);
    }

    function setTokenId(uint256 tokenId, bool authorized) external onlySafeOwner {
        authorizedTokenIds[tokenId] = authorized;
        emit ConfigurationUpdated("tokenId", authorized ? 0 : 1, authorized ? 1 : 0, msg.sender);
    }

    function canExecute() external view returns (bool) {
        return block.timestamp >= lastExecutionTime + executionInterval;
    }

    function executeRewards() external {
        if (block.timestamp < lastExecutionTime + executionInterval) {
            revert ExecutionTooEarly();
        }

        // 1. Collect LP fees
        _collectLPFees();

        // 2. Calculate token balances and distribution
        (uint256 mamoDistribution, uint256 btcDistribution, uint256 callerReward) = _calculateDistributions();

        // 3. Set rewards duration to match current interval
        _setRewardsDuration(executionInterval);

        // 4. Approve and notify reward amounts
        _distributeRewards(mamoDistribution, btcDistribution);

        // 5. Reward caller
        _rewardCaller(callerReward);

        lastExecutionTime = block.timestamp;

        emit RewardsExecuted(block.timestamp, mamoDistribution, btcDistribution, callerReward);
    }

    function _collectLPFees() internal {
        // This function would iterate through authorized token IDs and collect fees
        // Implementation depends on the specific BurnAndEarn interface
        // For now, this is a placeholder for the LP fee collection logic
    }

    function _calculateDistributions()
        internal
        view
        returns (uint256 mamoDist, uint256 btcDist, uint256 callerReward)
    {
        uint256 mamoBalance = mamoToken.balanceOf(address(safe));
        uint256 btcBalance = btcToken.balanceOf(address(safe));

        // Calculate distribution amounts ensuring minimum balances remain
        mamoDist = mamoBalance > mamoMinBalance ? mamoBalance - mamoMinBalance : 0;
        btcDist = btcBalance > btcMinBalance ? btcBalance - btcMinBalance : 0;

        // Calculate caller reward from MAMO distribution using named constant
        callerReward = (mamoDist * callerRewardBps) / BASIS_POINTS_DENOMINATOR;
        mamoDist -= callerReward;
    }

    function _setRewardsDuration(uint256 duration) internal {
        bytes memory setMamoDurationData =
            abi.encodeWithSelector(IMultiRewards.setRewardsDuration.selector, address(mamoToken), duration);
        if (!safe.execTransactionFromModule(address(multiRewards), 0, setMamoDurationData, 0)) {
            revert TransactionFailed();
        }

        bytes memory setBtcDurationData =
            abi.encodeWithSelector(IMultiRewards.setRewardsDuration.selector, address(btcToken), duration);
        if (!safe.execTransactionFromModule(address(multiRewards), 0, setBtcDurationData, 0)) {
            revert TransactionFailed();
        }
    }

    function _distributeRewards(uint256 mamoAmount, uint256 btcAmount) internal {
        if (mamoAmount > 0) {
            // Approve MultiRewards to spend MAMO tokens
            bytes memory approveMamoData =
                abi.encodeWithSelector(IERC20.approve.selector, address(multiRewards), mamoAmount);
            if (!safe.execTransactionFromModule(address(mamoToken), 0, approveMamoData, 0)) {
                revert TransactionFailed();
            }

            // Notify reward amount (this will transfer tokens)
            bytes memory notifyMamoData =
                abi.encodeWithSelector(IMultiRewards.notifyRewardAmount.selector, address(mamoToken), mamoAmount);
            if (!safe.execTransactionFromModule(address(multiRewards), 0, notifyMamoData, 0)) {
                revert TransactionFailed();
            }
        }

        if (btcAmount > 0) {
            // Approve MultiRewards to spend BTC tokens
            bytes memory approveBtcData =
                abi.encodeWithSelector(IERC20.approve.selector, address(multiRewards), btcAmount);
            if (!safe.execTransactionFromModule(address(btcToken), 0, approveBtcData, 0)) {
                revert TransactionFailed();
            }

            // Notify reward amount (this will transfer tokens)
            bytes memory notifyBtcData =
                abi.encodeWithSelector(IMultiRewards.notifyRewardAmount.selector, address(btcToken), btcAmount);
            if (!safe.execTransactionFromModule(address(multiRewards), 0, notifyBtcData, 0)) {
                revert TransactionFailed();
            }
        }
    }

    function _rewardCaller(uint256 callerReward) internal {
        if (callerReward > 0) {
            bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, callerReward);
            if (!safe.execTransactionFromModule(address(mamoToken), 0, data, 0)) {
                revert TransactionFailed();
            }
        }
    }

    function getTimeUntilNextExecution() external view returns (uint256) {
        uint256 nextExecutionTime = lastExecutionTime + executionInterval;
        if (block.timestamp >= nextExecutionTime) {
            return 0;
        }
        return nextExecutionTime - block.timestamp;
    }

    function getNextExecutionTime() external view returns (uint256) {
        return lastExecutionTime + executionInterval;
    }

    function getDistributableAmounts() external view returns (uint256 mamoAmount, uint256 btcAmount) {
        uint256 mamoBalance = mamoToken.balanceOf(address(safe));
        uint256 btcBalance = btcToken.balanceOf(address(safe));

        mamoAmount = mamoBalance > mamoMinBalance ? mamoBalance - mamoMinBalance : 0;
        btcAmount = btcBalance > btcMinBalance ? btcBalance - btcMinBalance : 0;
    }

    function getCallerRewardAmounts() external view returns (uint256 mamoReward, uint256 btcReward) {
        (uint256 mamoDistributable, uint256 btcDistributable) = this.getDistributableAmounts();

        mamoReward = (mamoDistributable * callerRewardBps) / BASIS_POINTS_DENOMINATOR;
        btcReward = 0; // Only MAMO rewards for caller as per spec
    }
}
