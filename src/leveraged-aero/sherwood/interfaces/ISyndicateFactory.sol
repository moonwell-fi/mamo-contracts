// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISyndicateFactory
/// @notice Second hop of the strategy's protocol-fee config lookup:
///         `ISyndicateFactory(vault.factory()).protocolConfig()`.
/// @dev Trimmed to the single function the vendored strategy calls. In this repo the vault plays
///      both roles, so `vault.factory()` points back at the vault itself (see
///      `LeveragedAeroVault.factory`).
interface ISyndicateFactory {
    /// @notice The protocol-fee config contract; `address(0)` == no protocol fee.
    function protocolConfig() external view returns (address);
}
