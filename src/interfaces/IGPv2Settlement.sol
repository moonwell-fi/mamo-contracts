// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IGPv2Settlement {
    function domainSeparator() external view returns (bytes32);

    function vaultRelayer() external view returns (address);
}
