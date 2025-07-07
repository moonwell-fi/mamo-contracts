// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title MockPool
 * @notice A simple mock pool contract for testing purposes
 * @dev This contract provides basic functionality to simulate a pool contract
 */
contract MockPool {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function getTokens() external view returns (address, address) {
        return (token0, token1);
    }
}
