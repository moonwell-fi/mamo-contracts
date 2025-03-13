// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/**
 * @title IMamoCore
 * @dev Interface for the MamoCore contract
 */
interface IMamoCore {
    /**
     * @notice Checks if a wallet is managed by Mamo
     * @param wallet The address of the wallet to check
     * @return True if the wallet is managed by Mamo, false otherwise
     */
    function isUserWallet(address wallet) external view returns (bool);

    /**
     * @notice Checks if a strategy is valid
     * @param strategy The address of the strategy to check
     * @return True if the strategy is valid, false otherwise
     */
    function isValidStrategy(address strategy) external view returns (bool);

    /**
     * @notice Gets the storage address for a strategy
     * @param strategy The address of the strategy
     * @return The address of the strategy's storage contract
     */
    function getStrategyStorage(address strategy) external view returns (address);
}
