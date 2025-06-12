// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IStrategyMulticall
 * @notice Interface for the StrategyMulticall contract
 */
interface IStrategyMulticall {
    /* EVENTS */

    /**
     * @notice Emitted when a batch of position updates is executed
     * @param initiator The address that initiated the batch update
     * @param strategiesCount The number of strategies updated
     */
    event BatchPositionUpdated(address indexed initiator, uint256 strategiesCount);

    /**
     * @notice Emitted when a generic multicall is executed
     * @param initiator The address that initiated the multicall
     * @param callsCount The number of calls executed
     */
    event GenericMulticallExecuted(address indexed initiator, uint256 callsCount);

    /* STRUCTS */

    /**
     * @notice Struct containing the parameters for a generic call
     * @param target The address of the target contract
     * @param data The encoded function call data
     * @param value The amount of ETH to send with the call
     */
    struct Call {
        address target;
        bytes data;
        uint256 value;
    }

    /* VIEW FUNCTIONS */

    /**
     * @notice Returns the owner of the contract
     * @return The address of the owner
     */
    function owner() external view returns (address);

    /* EXTERNAL FUNCTIONS */

    /**
     * @notice Executes a batch of position updates with the same split parameters for all strategies
     * @param strategies Array of strategy addresses to update
     * @param splitMoonwell The split parameter for Moonwell (basis points) to apply to all strategies
     * @param splitMorpho The split parameter for MetaMorpho (basis points) to apply to all strategies
     */
    function batchUpdatePositions(address[] calldata strategies, uint256 splitMoonwell, uint256 splitMorpho) external;

    /**
     * @notice Executes a sequence of arbitrary calls to contracts
     * @param calls Array of Call structs containing target, data, and value for each call
     */
    function genericMulticall(Call[] calldata calls) external payable;

    /**
     * @notice Executes a sequence of calls with uniform parameters
     * @param targets Array of target contract addresses
     * @param data The encoded function call data to execute on all targets
     * @param value The amount of ETH to send with each call
     */
    function uniformMulticall(address[] calldata targets, bytes calldata data, uint256 value) external payable;
}
