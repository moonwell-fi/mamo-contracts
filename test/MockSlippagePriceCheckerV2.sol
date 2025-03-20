// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";

/**
 * @title MockSlippagePriceCheckerV2
 * @notice Mock implementation of SlippagePriceChecker for testing upgrades
 */
contract MockSlippagePriceCheckerV2 is SlippagePriceChecker {
    // Add a new function to verify this is the upgraded implementation
    function version() external pure returns (string memory) {
        return "V2";
    }
}
