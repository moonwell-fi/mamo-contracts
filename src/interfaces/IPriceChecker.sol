// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

interface IPriceChecker {
    function checkPrice(
        uint256 _amountIn,
        address _fromToken,
        address _toToken,
        uint256 _feeAmount,
        uint256 _minOut,
        bytes calldata _data
    ) external view returns (bool);
}