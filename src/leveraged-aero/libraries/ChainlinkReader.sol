// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @notice Fail-closed Chainlink USD reads for Base: staleness + round-completeness
///         + L2 sequencer-uptime + grace period. (Hardens Mamo SlippagePriceChecker._readFeed,
///         which checks staleness only.)
library ChainlinkReader {
    error StaleOracle();
    error SequencerDown();
    error GracePeriodNotOver();

    function readUsd(address feed, address sequencerUptimeFeed, uint256 maxDelay, uint256 gracePeriod)
        internal
        view
        returns (uint256 price, uint8 decimals)
    {
        (, int256 up, uint256 seqStartedAt,,) = IAggregatorV3(sequencerUptimeFeed).latestRoundData();
        if (up != 0) revert SequencerDown();
        // `seqStartedAt == 0` is an uninitialized / invalid sequencer round — fail closed (mirrors
        // the price feed's `startedAt == 0` guard below) instead of treating round-0 as a valid
        // restart time that `block.timestamp - 0 > gracePeriod` would otherwise wave through as a
        // healthy sequencer. A future seqStartedAt (misconfigured feed / L2 clock skew) means the
        // sequencer (re)started "in the future" → grace definitely not over. Guard the subtraction
        // so a caller catching the named error gets GracePeriodNotOver, not an underflow panic.
        if (seqStartedAt == 0 || seqStartedAt > block.timestamp || block.timestamp - seqStartedAt <= gracePeriod) {
            revert GracePeriodNotOver();
        }

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert StaleOracle();
        if (answeredInRound < roundId) revert StaleOracle();
        if (startedAt == 0) revert StaleOracle();
        // A future updatedAt (feed clock ahead of a lagging L2 block.timestamp, e.g. a Tenderly
        // vnet) is the freshest possible answer → age 0; never underflow.
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > maxDelay) revert StaleOracle();

        price = uint256(answer);
        decimals = IAggregatorV3(feed).decimals();
    }
}
