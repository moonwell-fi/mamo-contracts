// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FeeConstants
/// @notice Protocol-wide performance-fee ceiling enforced by the vendored strategy at init
///         (`PerformanceFeeTooHigh`). Referenced as a compile-time constant, so it adds no runtime
///         bytecode.
library FeeConstants {
    /// @notice Hard ceiling on the performance fee, in basis points (15%).
    uint256 internal constant MAX_PERFORMANCE_FEE_BPS = 1500;
}
