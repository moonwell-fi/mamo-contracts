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

    /**
     * @notice Constructor to set the initial owner of the contract
     * @param _owner The address that will own this contract and can execute multicalls
     */
    constructor(address _owner) Ownable(_owner) {}

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
}
