// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IProtocolConfig {
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);
    event ProtocolFeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event GuardiansFeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);

    error InvalidProtocolFeeBps();
    error InvalidGuardianFeeBps();
    error InvalidProtocolFeeRecipient();
    error InvalidGuardiansFeeRecipient();

    function protocolFeeBps() external view returns (uint256);
    function protocolFeeRecipient() external view returns (address);
    function guardianFeeBps() external view returns (uint256);
    function guardiansFeeRecipient() external view returns (address);
}
