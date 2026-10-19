// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Chainlink aggregator stand-in with fully settable round data, for use in tests
/// @dev Every field owns a whole storage slot so a `vm.etch` over a live feed can be brought to a known
///      state by the setters alone: no packed neighbour keeps a byte of the replaced contract's storage.
contract MockChainlinkAggregator {
    uint256 internal _decimals;
    uint256 internal _roundId;
    int256 internal _answer;
    uint256 internal _startedAt;
    uint256 internal _updatedAt;
    uint256 internal _answeredInRound;

    error DecimalsTooLarge(uint256 value);

    /// @notice Sets the feed's decimals
    function setDecimals(uint8 decimals_) external {
        if (decimals_ > 77) revert DecimalsTooLarge(decimals_);
        _decimals = decimals_;
    }

    /// @notice Sets every field `latestRoundData` returns
    function setRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function decimals() external view returns (uint8) {
        return uint8(_decimals);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (uint80(_roundId), _answer, _startedAt, _updatedAt, uint80(_answeredInRound));
    }
}
