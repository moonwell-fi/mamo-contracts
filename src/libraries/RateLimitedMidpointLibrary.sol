// SPDX-License-Identifier: BSD-3.0
pragma solidity 0.8.28;

import {Math} from "@contracts/libraries/Math.sol";
import {RateLimitMidPoint, RateLimitMidpointCommonLibrary} from "@contracts/libraries/RateLimitMidpointCommonLibrary.sol";

/// @title library for putting a rate limit on how fast a contract
/// can perform an action e.g. Minting and Burning with a midpoint
/// @author Elliot Friedman
library RateLimitedMidpointLibrary {
    using RateLimitMidpointCommonLibrary for RateLimitMidPoint;

    /// @notice event emitted when buffer gets eaten into
    event BufferUsed(uint256 amountUsed, uint256 bufferRemaining);

    /// @notice event emitted when buffer gets replenished
    event BufferReplenished(uint256 amountReplenished, uint256 bufferRemaining);

    /// @notice the method that enforces the rate limit.
    /// Decreases buffer by "amount".
    /// If buffer is <= amount, revert
    /// @param limit pointer to the rate limit object
    /// @param amount to decrease buffer by
    function depleteBuffer(
        RateLimitMidPoint storage limit,
        uint256 amount
    ) internal {
        uint256 newBuffer = limit.buffer(); /// SLOAD 2x

        require(amount <= newBuffer, "RateLimited: rate limit hit");

        uint32 blockTimestamp = uint32(block.timestamp);
        uint112 newBufferStored = uint112(newBuffer - amount);

        /// gas optimization to only use a single SSTORE
        limit.lastBufferUsedTime = blockTimestamp;
        limit.bufferStored = newBufferStored;

        emit BufferUsed(amount, newBufferStored);
    }

    /// @notice function to replenish buffer
    /// @param amount to increase buffer by if under buffer cap
    /// @param limit pointer to the rate limit object
    function replenishBuffer(
        RateLimitMidPoint storage limit,
        uint256 amount
    ) internal {
        uint256 buffer = limit.buffer(); /// SLOAD 2x
        uint256 _bufferCap = limit.bufferCap; /// warm SLOAD
        uint256 newBuffer = buffer + amount;

        require(newBuffer <= _bufferCap, "RateLimited: buffer cap overflow");

        uint32 blockTimestamp = uint32(block.timestamp);
        /// ensure that bufferStored cannot be gt buffer cap
        uint112 newBufferStored = uint112(newBuffer);

        /// gas optimization to only use a single SSTORE
        limit.lastBufferUsedTime = blockTimestamp;
        limit.bufferStored = newBufferStored;

        emit BufferReplenished(amount, newBufferStored);
    }
}
