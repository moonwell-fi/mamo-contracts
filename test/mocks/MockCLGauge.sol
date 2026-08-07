// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal mock for ICLGauge used in unit tests.
contract MockCLGauge {
    using SafeERC20 for IERC20;

    address public aeroToken;

    // Pool this gauge is bound to (read by _validateAndStore's gauge->pool binding check).
    address public pool;

    // Amount of AERO to pay out when withdraw() is called
    uint256 public aeroToPayOnWithdraw;

    // Last recorded deposit call
    uint256 public lastDepositedTokenId;
    address public lastDepositor;
    uint256 public depositCallCount;

    // Last recorded withdraw call
    uint256 public lastWithdrawnTokenId;
    address public lastWithdrawCaller;
    uint256 public withdrawCallCount;

    constructor(address aeroToken_) {
        aeroToken = aeroToken_;
    }

    /// @notice Set the pool this gauge reports as its own (for the gauge->pool binding check).
    function setPool(address pool_) external {
        pool = pool_;
    }

    /// @notice Configure how much AERO to transfer to msg.sender on withdraw.
    function setAeroToPayOnWithdraw(uint256 amount) external {
        aeroToPayOnWithdraw = amount;
    }

    /// @dev Per-depositor stake set, mirroring the real Slipstream `CLGauge._stakes`. Modelled on
    ///      purpose: the previous stub let `withdraw` succeed on an NFT the gauge never held, which
    ///      made an unstaked-but-still-referenced position indistinguishable from a staked one and
    ///      hid a permanent-DoS class of bug from the whole suite.
    mapping(address => mapping(uint256 => bool)) internal _staked;

    error MockCLGaugeNotStaked();

    function deposit(uint256 tokenId) external {
        lastDepositedTokenId = tokenId;
        lastDepositor = msg.sender;
        depositCallCount++;
        _staked[msg.sender][tokenId] = true;
    }

    function withdraw(uint256 tokenId) external {
        // The real CLGauge reverts when the caller is not the staked depositor (it transfers the NFT
        // out of the gauge's own custody). Enforced here so a test can observe the orphaned-NFT state.
        if (!_staked[msg.sender][tokenId]) revert MockCLGaugeNotStaked();
        _staked[msg.sender][tokenId] = false;

        lastWithdrawnTokenId = tokenId;
        lastWithdrawCaller = msg.sender;
        withdrawCallCount++;

        // Simulate auto-claim: transfer AERO to caller (like Aerodrome does)
        if (aeroToPayOnWithdraw > 0) {
            IERC20(aeroToken).safeTransfer(msg.sender, aeroToPayOnWithdraw);
        }
    }

    // Amount of AERO to pay out when getReward() is called
    uint256 public aeroToPayOnGetReward;

    // Last recorded getReward call
    uint256 public lastGetRewardTokenId;
    uint256 public getRewardCallCount;

    /// @notice Configure how much AERO to transfer to msg.sender on getReward.
    function setAeroToPayOnGetReward(uint256 amount) external {
        aeroToPayOnGetReward = amount;
    }

    function getReward(uint256 tokenId) external {
        lastGetRewardTokenId = tokenId;
        getRewardCallCount++;

        // Simulate reward claim: transfer AERO to caller
        if (aeroToPayOnGetReward > 0) {
            IERC20(aeroToken).safeTransfer(msg.sender, aeroToPayOnGetReward);
        }
    }

    // Configurable earned value returned by earned()
    uint256 public earnedAmount;

    /// @notice Configure the value returned by earned().
    function setEarnedAmount(uint256 amount) external {
        earnedAmount = amount;
    }

    function earned(address, uint256) external view returns (uint256) {
        return earnedAmount;
    }

    function rewardToken() external view returns (address) {
        return aeroToken;
    }

    function stakedContains(address depositor, uint256 tokenId) external view returns (bool) {
        return _staked[depositor][tokenId];
    }
}
