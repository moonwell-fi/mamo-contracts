// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal balancer surface the compound module reads live (survives setPool).
interface ILPAutoBalancerV2 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function rebalanceInFlight() external view returns (bool);
}
