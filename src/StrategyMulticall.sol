// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StrategyMulticall
 * @notice Enables batching multiple calls to strategies in a single transaction
 * @dev This contract allows efficient batch updates and generic multicalls to strategies
 * @dev Only the owner can execute multicalls to prevent unauthorized strategy modifications
 */
contract StrategyMulticall is Ownable {
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

    /* CONSTRUCTOR */

    /**
     * @notice Constructor to set the initial owner of the contract
     * @param _owner The address that will own this contract and can execute multicalls
     */
    constructor(address _owner) Ownable(_owner) {}

    /* EXTERNAL FUNCTIONS */

    /**
     * @notice Executes a batch of position updates with the same split parameters for all strategies
     * @param strategies Array of strategy addresses to update
     * @param splitMoonwell The split parameter for Moonwell (basis points) to apply to all strategies
     * @param splitMorpho The split parameter for MetaMorpho (basis points) to apply to all strategies
     * @dev Updates multiple strategies with identical split parameters efficiently
     * @dev Reverts on any failure - no partial success handling
     * @dev Only callable by the contract owner
     */
    function batchUpdatePositions(address[] calldata strategies, uint256 splitMoonwell, uint256 splitMorpho)
        external
        onlyOwner
    {
        require(strategies.length > 0, "StrategyMulticall: Empty strategies array");

        for (uint256 i = 0; i < strategies.length; i++) {
            address strategy = strategies[i];
            require(strategy != address(0), "StrategyMulticall: Invalid strategy address");

            IStrategy(strategy).updatePosition(splitMoonwell, splitMorpho);
        }

        emit BatchPositionUpdated(msg.sender, strategies.length);
    }

    /**
     * @notice Executes a sequence of arbitrary calls to contracts
     * @param calls Array of Call structs containing target, data, and value for each call
     * @dev Reverts on any failure - no partial success handling
     * @dev Can be used for any contract calls, not just strategies
     * @dev Only callable by the contract owner
     */
    function genericMulticall(Call[] calldata calls) external payable onlyOwner {
        require(calls.length > 0, "StrategyMulticall: Empty calls array");

        for (uint256 i = 0; i < calls.length; i++) {
            Call calldata call = calls[i];
            require(call.target != address(0), "StrategyMulticall: Invalid target address");

            (bool success, bytes memory returnData) = call.target.call{value: call.value}(call.data);

            if (!success) {
                // Revert with the original error data
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }

        emit GenericMulticallExecuted(msg.sender, calls.length);
    }

    /**
     * @notice Executes a sequence of calls with uniform parameters
     * @param targets Array of target contract addresses
     * @param data The encoded function call data to execute on all targets
     * @param value The amount of ETH to send with each call
     * @dev Convenience function for calling the same function on multiple contracts
     * @dev Reverts on any failure - no partial success handling
     * @dev Only callable by the contract owner
     */
    function uniformMulticall(address[] calldata targets, bytes calldata data, uint256 value)
        external
        payable
        onlyOwner
    {
        require(targets.length > 0, "StrategyMulticall: Empty targets array");
        require(msg.value >= value * targets.length, "StrategyMulticall: Insufficient ETH sent");

        for (uint256 i = 0; i < targets.length; i++) {
            address target = targets[i];
            require(target != address(0), "StrategyMulticall: Invalid target address");

            (bool success, bytes memory returnData) = target.call{value: value}(data);

            if (!success) {
                // Revert with the original error data
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }

        emit GenericMulticallExecuted(msg.sender, targets.length);
    }
}
