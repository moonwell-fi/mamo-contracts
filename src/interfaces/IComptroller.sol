// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IComptroller
 * @notice Interface for the Moonwell Comptroller contract
 */
interface IComptroller {
    /**
     * @notice Claims rewards for the caller across all markets
     */
    function claimReward() external;

    /**
     * @notice Claims rewards for a specific user across specified markets
     * @param holder The address to claim rewards for
     * @param mTokens The list of markets to claim rewards from
     */
    function claimReward(address holder, address[] calldata mTokens) external;

    /**
     * @notice Returns all markets
     * @return A list of all market addresses
     */
    function getAllMarkets() external view returns (address[] memory);
}
