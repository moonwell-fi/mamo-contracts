// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGPv2Settlement} from "@interfaces/IGPv2Settlement.sol";

/// @notice Stand-in for the CoW settlement contract, returning fixed values, for use in tests
contract MockGPv2Settlement is IGPv2Settlement {
    bytes32 public immutable override domainSeparator;
    address public immutable override vaultRelayer;

    constructor(bytes32 separator, address relayer) {
        domainSeparator = separator;
        vaultRelayer = relayer;
    }
}
