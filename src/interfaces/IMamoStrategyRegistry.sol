// SPDX-License-Identifier: UNLICENSED
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
     * @notice Adds an implementation to the whitelist with its strategy type
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param implementation The address of the implementation to whitelist
     * @param strategyTypeId The bytes32 representation of the strategy type
     */
    function whitelistImplementation(address implementation, bytes32 strategyTypeId) external;
    
    /**
     * @notice Checks if an implementation is whitelisted
     * @param implementation The address of the implementation to check
     * @return True if the implementation is whitelisted, false otherwise
     */
    function isImplementationWhitelisted(address implementation) external view returns (bool);
    
    /**
     * @notice Gets the strategy type for an implementation
     * @param implementation The address of the implementation
     * @return The strategy type as a bytes32 value
     */
    function getImplementationType(address implementation) external view returns (bytes32);
    
    /**
     * @notice Gets the latest implementation for a strategy type
     * @param strategyType The strategy type as a bytes32 value
     * @return The address of the latest implementation for the strategy type
     */
    function getLatestImplementation(bytes32 strategyType) external view returns (address);
    
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
     * @param newImplementation The address of the new implementation
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
}