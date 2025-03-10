// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/**
 * @title IMamoStrategyRegistry
 * @dev Interface for the MamoStrategyRegistry contract
 */
interface IMamoStrategyRegistry {
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
     * @notice Checks if an address is a registered strategy
     * @param strategy The address to check
     * @return True if the address is a registered strategy, false otherwise
     */
    function isStrategy(address strategy) external view returns (bool);
}
