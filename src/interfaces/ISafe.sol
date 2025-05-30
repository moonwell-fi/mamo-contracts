// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISafe {
    enum Operation {
        Call,
        DelegateCall
    }

    function checkNSignatures(bytes32 transactionHash, bytes memory data, bytes memory signatures, uint256 threshold)
        external
        view;

    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function isModuleEnabled(address module) external view returns (bool);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        bytes calldata signatures
    ) external;

    function nonce() external view returns (uint256);

    function getOwners() external view returns (address[] memory);

    function getThreshold() external view returns (uint256);

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
        external
        returns (bool success);

    function enableModule(address module) external;
}
