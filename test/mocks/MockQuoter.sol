// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IQuoter} from "@interfaces/IQuoter.sol";

/// @notice Minimal mock for IQuoter — returns a configurable quotedOut.
contract MockQuoter is IQuoter {
    uint256 public quotedOut;

    function setQuotedOut(uint256 amount) external {
        quotedOut = amount;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory)
        external
        view
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        return (quotedOut, 0, 0, 0);
    }
}
