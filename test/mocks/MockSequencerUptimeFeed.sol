// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";

/// @notice Chainlink L2 sequencer uptime feed stand-in: answer 0 = up, 1 = down; startedAt = status start.
contract MockSequencerUptimeFeed is IPriceFeed {
    int256 public answer;
    uint256 public startedAt;

    constructor(int256 answer_, uint256 startedAt_) {
        answer = answer_;
        startedAt = startedAt_;
    }

    function set(int256 answer_, uint256 startedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}
