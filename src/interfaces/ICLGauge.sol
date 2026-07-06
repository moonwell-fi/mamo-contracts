// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ICLGauge {
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;
    function earned(address account, uint256 tokenId) external view returns (uint256);
    function rewardToken() external view returns (address);
    function pool() external view returns (address);
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
}
