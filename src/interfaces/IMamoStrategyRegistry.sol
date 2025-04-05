// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IMamoStrategyRegistry
 * @dev Interface for the MamoStrategyRegistry contract
 */
interface IMamoStrategyRegistry {
    /**
     * @notice Pauses the contract
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function pause() external;

    /**
     * @notice Unpauses the contract
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function unpause() external;

    /**
     * @notice Adds an implementation to the whitelist with a strategy type ID
     * @dev Only callable by accounts with the ADMIN_ROLE
     * @param implementation The address of the implementation to whitelist
     * @param strategyTypeId The strategy type ID to assign. If 0, a new ID will be assigned
     * @return assignedStrategyTypeId The assigned strategy type ID
     */
    function whitelistImplementation(address implementation, uint256 strategyTypeId)
        external
        returns (uint256 assignedStrategyTypeId);

    /**
     * @notice Checks if an implementation is whitelisted
     * @param implementation The address of the implementation to check
     * @return True if the implementation is whitelisted, false otherwise
     */
    function isImplementationWhitelisted(address implementation) external view returns (bool);

    /**
     * @notice Gets the strategy ID for an implementation
     * @param implementation The address of the implementation
     * @return The strategy ID as a uint256 value
     */
    function getImplementationId(address implementation) external view returns (uint256);

    /**
     * @notice Gets the latest implementation for a strategy ID
     * @param strategyId The strategy ID as a uint256 value
     * @return The address of the latest implementation for the strategy ID
     */
    function getLatestImplementation(uint256 strategyId) external view returns (address);

    /**
     * @notice Adds a strategy for a user
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param user The address of the user
     * @param strategy The address of the strategy to add
     */
    function addStrategy(address user, address strategy) external;

    /**
     * @notice Removes a strategy for a user
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param user The address of the user
     * @param strategy The address of the strategy to remove
     */
    function removeStrategy(address user, address strategy) external;

    /**
     * @notice Updates the implementation of a strategy
     * @dev Only callable by the user who owns the strategy
     * @param strategy The address of the strategy to update
     * @param newImplementation The new implementation address
     */
    function upgradeStrategy(address strategy, address newImplementation) external;

    /**
     * @notice Gets all strategies for a user
     * @param user The address of the user
     * @return An array of strategy addresses
     */
    function getUserStrategies(address user) external view returns (address[] memory);

    /**
     * @notice Checks if a strategy belongs to a user
     * @param user The address of the user
     * @param strategy The address of the strategy
     * @return True if the strategy belongs to the user, false otherwise
     */
    function isUserStrategy(address user, address strategy) external view returns (bool);

    /**
     * @notice Gets the implementation address for a strategy
     * @param strategy The address of the strategy (proxy)
     * @return implementation The address of the implementation
     */
    function getStrategyImplementation(address strategy) external view returns (address);

    /**
     * @notice Gets the backend address (first member of the BACKEND_ROLE)
     * @return The address of the backend
     */
    function getBackendAddress() external view returns (address);

    /**
     * @notice Gets the owner of a strategy
     * @param strategy The address of the strategy
     * @return The address of the strategy owner
     */
    function strategyOwner(address strategy) external view returns (address);
}
