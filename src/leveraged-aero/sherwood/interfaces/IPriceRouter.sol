// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A position the vault holds via a strategy, described in venue-native
///         terms. The PriceRouter prices it; the strategy is NEVER trusted for
///         *value* — only for pointing at the venue/position it controls. This
///         is the "trust inversion" at the heart of the live-NAV redesign:
///         the strategy reports quantities/locators, the vault prices them.
/// @dev    File path/name preserved (the vendored strategy imports it verbatim), but the
///         `IPriceAdapter` / `IPriceRouter` interfaces are gone: this repo's vault does no
///         vault-side pricing, so the struct is the only surviving surface — it is the return type
///         of the strategy's `positions()`.
struct Position {
    address venue; // Moonwell mToken / Aerodrome pool / HyperCore precompile
    bytes32 kind; // keccak256("MOONWELL_SUPPLY") | "AERODROME_LP" | "HL_PERP"
    bytes ref; // venue-specific locator (empty for single-venue kinds like Moonwell)
}
