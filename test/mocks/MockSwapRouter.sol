// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

/// @notice Minimal mock for ISwapRouter.
///         Records the last ExactInputSingleParams it was called with (for assertion),
///         and returns a configurable amountOut. Does NOT move tokens.
contract MockSwapRouter is ISwapRouter {
    uint256 public amountOutToReturn;

    // Last call recorded
    ExactInputSingleParams public lastParams;
    bool public wasCalled;

    function setAmountOutToReturn(uint256 amount) external {
        amountOutToReturn = amount;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        lastParams = params;
        wasCalled = true;
        return amountOutToReturn;
    }

    /// @notice Convenience getter for the amountOutMinimum field of the last recorded params.
    function lastAmountOutMinimum() external view returns (uint256) {
        return lastParams.amountOutMinimum;
    }

    // Stubs for unused ISwapRouter functions
    function exactInput(ExactInputParams calldata) external payable returns (uint256) {
        revert("not implemented");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256) {
        revert("not implemented");
    }

    function exactOutput(ExactOutputParams calldata) external payable returns (uint256) {
        revert("not implemented");
    }
}
