// SPDX-License-Identifier: UNLICENSED
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
}
