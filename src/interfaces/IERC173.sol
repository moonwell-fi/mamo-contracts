// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @author Jason
 * @title ERC-173 Contract Ownership Standard
 * @dev ERC173 interface
 * Note: the ERC-165 identifier for this interface is 0x7f5828d0
 */
interface IERC173 {
    /**
     * @notice Get the address of the owner
     * @return owner_ The address of the owner.
     */
    function owner() external view returns (address owner_);

    /**
     * @notice Set the address of the new owner of the contract
     * @dev Set _newOwner to address(0) to renounce any ownership.
     * @param _newOwner The address of the new owner of the contract
     */
    function transferOwnership(address _newOwner) external;
}
