// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IAerodromeVoter {
    function isAlive(address gauge) external view returns (bool);
}
