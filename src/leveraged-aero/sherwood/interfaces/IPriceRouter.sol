// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A position the vault holds via a strategy, described in venue-native
///         terms. The PriceRouter prices it; the strategy is NEVER trusted for
///         *value* — only for pointing at the venue/position it controls. This
///         is the "trust inversion" at the heart of the live-NAV redesign:
///         the strategy reports quantities/locators, the vault prices them.
struct Position {
    address venue; // Moonwell mToken / Aerodrome pool / HyperCore precompile
    bytes32 kind; // keccak256("MOONWELL_SUPPLY") | "AERODROME_LP" | "HL_PERP"
    bytes ref; // venue-specific locator (empty for single-venue kinds like Moonwell)
}

/// @notice Per-`kind` pricing adapter. Reads the real quantity from `venue`
///         (e.g. `mToken.balanceOf(holder)`) and prices it. Returns
///         `(value, ok)` where `ok == false` means "not safely priceable right
///         now" — unknown/foreign venue, stale oracle, deviation gate tripped.
///         The router maps `ok == false` onto instant-ineligible (Lane B).
interface IPriceAdapter {
    function value(Position calldata p, address holder) external view returns (uint256 value, bool ok);
}

/// @notice Governance-owned router. Maps a position `kind` to its adapter,
///         applies a realizability haircut, and enforces an instant size cap.
///         `valuePosition` is the only function the vault consumes.
interface IPriceRouter {
    /// @param p      the position to price (venue + kind + locator)
    /// @param holder the address whose position is read at the venue
    /// @return value     haircut-adjusted value in the position's underlying
    ///                   units, or 0 when not instantly priceable.
    /// @return instantOK true only when the position is safely priceable now
    ///                   AND within the instant cap. When false, `value` is 0
    ///                   (G2 Option A) and the caller must use the async (Lane
    ///                   B) settlement path.
    function valuePosition(Position calldata p, address holder) external view returns (uint256 value, bool instantOK);

    /// @notice Aggregate vault-facing valuation: reads a strategy's on-venue
    ///         positions and prices them. Instant-eligible (`instantOK == true`)
    ///         only when every position's kind is Lane-A-enabled and prices OK;
    ///         otherwise `(0, false)` and the vault uses the async (Lane B) path.
    function valueStrategy(address strategy) external view returns (uint256 value, bool instantOK);

    /// @notice Register the adapter that prices positions of a given `kind`.
    function registerAdapter(bytes32 kind, address adapter) external;

    /// @notice Set the realizability haircut (bps) applied to a kind's raw
    ///         value. Monotone-increasing: lowering requires a contract
    ///         upgrade (which itself inherits the owner multisig's delay).
    function setHaircutBps(bytes32 kind, uint16 bps) external;

    /// @notice Set the maximum single-position value eligible for instant
    ///         pricing. 0 means "no cap" (unlimited).
    function setInstantCap(bytes32 kind, uint256 cap) external;

    /// @notice Enable / disable the instant (Lane A) lane for a position kind.
    function setLaneAEnabled(bytes32 kind, bool enabled) external;
}
