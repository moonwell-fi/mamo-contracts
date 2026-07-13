// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title BatchExecutorLib
 * @notice Stateless batch execution logic. Called via delegatecall from vaults.
 *
 *   When a vault delegatecalls into this contract:
 *     - `address(this)` = vault address (positions live on the vault)
 *     - `msg.sender` = original caller (the agent wallet)
 *     - All calls to DeFi protocols happen FROM the vault
 *
 *   This contract has NO state and NO access control. The calling vault must
 *   enforce allowlists and caps BEFORE delegatecalling here.
 *
 *   Deploy once, share across all syndicate vaults.
 */
contract BatchExecutorLib {
    struct Call {
        address target;
        bytes data;
        uint256 value;
    }

    struct CallResult {
        bool success;
        bytes returnData;
    }

    /**
     * @notice Execute a batch of calls atomically.
     * @dev Called via delegatecall from vault. All calls execute as the vault.
     *      If any call fails, the entire batch reverts.
     * @param calls Array of (target, data, value) to execute in order
     */
    function executeBatch(Call[] calldata calls) external {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory returnData) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!success) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
        }
    }

    /**
     * @notice Simulate a batch without reverting on failure.
     * @dev Call via eth_call for dry-run. Returns per-call results.
     *      State changes from earlier calls ARE visible to later calls,
     *      matching real execution behavior.
     * @param calls Array of calls to simulate
     * @return results Array of (success, returnData) per call
     */
    function simulateBatch(Call[] calldata calls) external returns (CallResult[] memory results) {
        results = new CallResult[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory returnData) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            results[i] = CallResult({success: success, returnData: returnData});
        }
    }
}
