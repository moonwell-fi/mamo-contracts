// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal mock for ICLGauge used in unit tests.
contract MockCLGauge {
    using SafeERC20 for IERC20;

    address public aeroToken;

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

    /// @notice Configure how much AERO to transfer to msg.sender on withdraw.
    function setAeroToPayOnWithdraw(uint256 amount) external {
        aeroToPayOnWithdraw = amount;
    }

    function deposit(uint256 tokenId) external {
        lastDepositedTokenId = tokenId;
        lastDepositor = msg.sender;
        depositCallCount++;
    }

    function withdraw(uint256 tokenId) external {
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

    function stakedContains(address, uint256) external pure returns (bool) {
        return false;
    }
}
