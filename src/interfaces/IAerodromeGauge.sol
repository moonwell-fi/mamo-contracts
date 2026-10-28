// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IAerodromeGauge {
    function balanceOf(address account) external view returns (uint256);

    function getReward(address account) external;

    function withdraw(uint256 amount) external;

    function deposit(uint256 amount, address recipient) external;

    function earned(address account) external view returns (uint256);

    function rewardToken() external view returns (address);

    function stakingToken() external view returns (address);

    function voter() external view returns (address);
}
