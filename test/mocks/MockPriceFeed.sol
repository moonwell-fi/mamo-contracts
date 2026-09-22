// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";

/// @notice Configurable mock of IPriceFeed for unit-testing _readFeed / _valueInUsd.
contract MockPriceFeed is IPriceFeed {
    int256 public mockAnswer;
    uint8 public mockDecimals;
    uint256 public mockUpdatedAt;

    constructor(int256 answer_, uint8 decimals_, uint256 updatedAt_) {
        mockAnswer = answer_;
        mockDecimals = decimals_;
        mockUpdatedAt = updatedAt_;
    }

    // ── Setters ──────────────────────────────────────────────────────────────

    function setAnswer(int256 answer_) external {
        mockAnswer = answer_;
    }

    function setDecimals(uint8 decimals_) external {
        mockDecimals = decimals_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        mockUpdatedAt = updatedAt_;
    }

    // ── IPriceFeed ────────────────────────────────────────────────────────────

    function decimals() external view returns (uint8) {
        return mockDecimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, mockAnswer, 0, mockUpdatedAt, 1);
    }
}
