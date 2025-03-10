// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/**
 * @title IStrategy
 * @notice Interface for all strategy contracts
 */
interface IStrategy {
    /**
     * @notice Returns the owner of the strategy
     * @return The address of the owner
     */
    function owner() external view returns (address);

    /**
     * @notice Returns the MamoCore contract address
     * @return The address of the MamoCore contract
     */
    function mamoCore() external view returns (address);

    /**
     * @notice Deposits funds into the strategy
     * @param asset The address of the token to deposit
     * @param amount The amount to deposit
     */
    function deposit(address asset, uint256 amount) external;

    /**
     * @notice Withdraws funds from the strategy
     * @param asset The address of the token to withdraw
     * @param amount The amount to withdraw
     */
    function withdraw(address asset, uint256 amount) external;

    /**
     * @notice Updates the position in the strategy
     * @param splitA The first split parameter (basis points)
     * @param splitB The second split parameter (basis points)
     */
    function updatePosition(uint256 splitA, uint256 splitB) external;

    /**
     * @notice Claims rewards from the strategy
     */
    function claimRewards() external;
}
