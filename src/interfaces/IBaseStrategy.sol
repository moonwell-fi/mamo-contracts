// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";

/**
 * @title IBaseStrategy
 * @notice Interface for the base strategy contract
 */
interface IBaseStrategy {
    /**
     * @notice Gets the Mamo Strategy Registry contract
     * @return The Mamo Strategy Registry contract
     */
    function mamoStrategyRegistry() external view returns (IMamoStrategyRegistry);

    /**
     * @notice Gets the strategy type ID
     * @return The strategy type ID
     */
    function strategyTypeId() external view returns (uint256);

    /**
     * @notice Returns the owner address of this strategy
     * @return The address of the strategy owner
     */
    function getOwner() external view returns (address);
}
