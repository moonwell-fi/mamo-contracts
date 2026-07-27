// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IProtocolConfig
/// @notice Protocol-fee parameters the vendored strategy reads live on every fee crystallise.
/// @dev Trimmed to the two getters the strategy calls (`_protocolFeeBps` / `_protocolFeeRecipient`).
///      Resolved via `ISyndicateFactory(vault.factory()).protocolConfig()`; when that resolves to
///      `address(0)` the strategy treats the protocol fee as 0 bps and skips discharge entirely,
///      which is the launch configuration here.
interface IProtocolConfig {
    /// @notice Protocol fee in basis points, taken out of the strategy's crystallised profit.
    function protocolFeeBps() external view returns (uint256);

    /// @notice Recipient of the accrued protocol fee; `address(0)` defers the discharge.
    function protocolFeeRecipient() external view returns (address);
}
