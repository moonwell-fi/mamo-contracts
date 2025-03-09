// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/**
 * @title IUserWallet
 * @dev Interface for the UserWallet contract
 */
interface IUserWallet {
    /**
     * @notice Sets the approval status of a strategy
     * @param strategy The address of the strategy
     * @param approved True to approve the strategy, false to disapprove
     */
    function setStrategyApproval(address strategy, bool approved) external;
    
    /**
     * @notice Checks if a strategy is approved
     * @param strategy The address of the strategy to check
     * @return True if the strategy is approved, false otherwise
     */
    function isStrategyApproved(address strategy) external view returns (bool);
    
    /**
     * @notice Updates the position in a strategy with specified split parameters
     * @param strategy The address of the strategy to update
     * @param splitA The first split parameter (basis points)
     * @param splitB The second split parameter (basis points)
     */
    function updatePosition(address strategy, uint256 splitA, uint256 splitB) external;
    
    /**
     * @notice Claims all available rewards from the strategy
     * @param strategy The address of the strategy to claim rewards from
     */
    function claimRewards(address strategy) external;
}
