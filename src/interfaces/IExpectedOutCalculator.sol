// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

interface IExpectedOutCalculator {
    function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken, bytes calldata _data)
        external
        view
        returns (uint256);
}
