// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Market type: Moonwell (Compound-fork mToken) or ERC4626 vault
enum MarketType {
    MOONWELL,
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
 * @dev Stores market definitions per strategyTypeId. Strategies read markets from here
 *      and maintain their own per-market splits locally.
 */
interface IMarketRegistry {
    /// @notice Adds a new market for a strategy type
    /// @param strategyTypeId The strategy type to add the market to
    /// @param target The address of the mToken or ERC4626 vault
    /// @param marketType The type of market
    function addMarket(uint256 strategyTypeId, address target, MarketType marketType) external;

    /// @notice Deactivates a market (soft-delete)
    /// @param strategyTypeId The strategy type
    /// @param marketIndex The index of the market to deactivate
    function deactivateMarket(uint256 strategyTypeId, uint256 marketIndex) external;

    /// @notice Returns all markets for a strategy type
    /// @param strategyTypeId The strategy type
    /// @return Array of RegistryMarket structs
    function getMarkets(uint256 strategyTypeId) external view returns (RegistryMarket[] memory);

    /// @notice Returns the number of markets for a strategy type
    /// @param strategyTypeId The strategy type
    /// @return The number of markets
    function getMarketCount(uint256 strategyTypeId) external view returns (uint256);

    /// @notice Returns whether a market is active
    /// @param strategyTypeId The strategy type
    /// @param marketIndex The index of the market
    /// @return True if the market is active
    function isMarketActive(uint256 strategyTypeId, uint256 marketIndex) external view returns (bool);

    /// @notice Returns a single market
    /// @param strategyTypeId The strategy type
    /// @param marketIndex The index of the market
    /// @return The RegistryMarket struct
    function getMarket(uint256 strategyTypeId, uint256 marketIndex) external view returns (RegistryMarket memory);

    /// @notice Pauses the contract
    function pause() external;

    /// @notice Unpauses the contract
    function unpause() external;
}
