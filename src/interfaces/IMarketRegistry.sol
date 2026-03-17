// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Market type: mToken (Compound-fork) or ERC4626 vault
enum MarketType {
    MTOKEN,
    ERC4626
}

/// @notice Registry-level market definition (no split — splits live in each strategy)
struct RegistryMarket {
    address target; // mToken or ERC4626 vault address
    MarketType marketType; // interface selector
    bool active; // soft-delete flag
}

/**
 * @title IMarketRegistry
 * @notice Interface for the centralized market registry
 * @dev Stores market definitions per asset address. Strategies read markets from here
 *      and maintain their own per-market splits locally (keyed by market address).
 */
interface IMarketRegistry {
    /// @notice Adds a new market for an asset
    /// @param asset The token address to add the market for
    /// @param target The address of the mToken or ERC4626 vault
    /// @param marketType The type of market
    function addMarket(address asset, address target, MarketType marketType) external;

    /// @notice Deactivates a market by address (soft-delete)
    /// @param asset The token address
    /// @param target The address of the market to deactivate
    function deactivateMarket(address asset, address target) external;

    /// @notice Returns all markets for an asset
    /// @param asset The token address
    /// @return Array of RegistryMarket structs
    function getMarkets(address asset) external view returns (RegistryMarket[] memory);

    /// @notice Returns the number of markets for an asset
    /// @param asset The token address
    /// @return The number of markets
    function getMarketCount(address asset) external view returns (uint256);

    /// @notice Returns whether a market is active by address
    /// @param asset The token address
    /// @param target The address of the market
    /// @return True if the market is active
    function isMarketActive(address asset, address target) external view returns (bool);

    /// @notice Returns a single market by address
    /// @param asset The token address
    /// @param target The address of the market
    /// @return The RegistryMarket struct
    function getMarket(address asset, address target) external view returns (RegistryMarket memory);

    /// @notice Pauses the contract
    function pause() external;

    /// @notice Unpauses the contract
    function unpause() external;
}
