// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IStrategyMulticall
 * @notice Interface for the StrategyMulticall contract
 */
interface IStrategyMulticall {
    /**
     * @notice Emitted when a generic multicall is executed
     * @param initiator The address that initiated the multicall
     * @param callsCount The number of calls executed
     */
    event GenericMulticallExecuted(address indexed initiator, uint256 callsCount);


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

    /**
     * @notice Executes a sequence of arbitrary calls to contracts
     * @param calls Array of Call structs containing target, data, and value for each call
     */
    function genericMulticall(Call[] calldata calls) external payable;
}
