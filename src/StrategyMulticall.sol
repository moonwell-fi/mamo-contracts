// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StrategyMulticall
 * @notice Enables batching multiple calls to strategies in a single transaction
 * @dev This contract allows efficient batch updates and generic multicalls to strategies
 * @dev Only the owner can execute multicalls to prevent unauthorized strategy modifications
 */
contract StrategyMulticall is Ownable, ReentrancyGuard {
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
     * @dev Validates that total call values don't exceed msg.value and refunds excess ETH
     * @dev Protected against reentrancy attacks
     */
    function genericMulticall(Call[] calldata calls) external payable onlyOwner nonReentrant {
        require(calls.length > 0, "StrategyMulticall: Empty calls array");

        // Calculate total ETH required for all calls
        uint256 totalValue = 0;
        for (uint256 i = 0; i < calls.length; i++) {
            totalValue += calls[i].value;
        }

        // Ensure we have enough ETH to cover all calls
        require(totalValue <= msg.value, "StrategyMulticall: Insufficient ETH provided");

        // Execute all calls
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

        // Refund any excess ETH to the caller
        uint256 excessETH = msg.value - totalValue;
        if (excessETH > 0) {
            (bool refundSuccess,) = payable(msg.sender).call{value: excessETH}("");
            require(refundSuccess, "StrategyMulticall: ETH refund failed");
        }

        emit GenericMulticallExecuted(msg.sender, calls.length);
    }
}
