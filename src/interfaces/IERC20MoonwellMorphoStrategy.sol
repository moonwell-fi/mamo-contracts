// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IERC20MoonwellMorphoStrategy
 * @notice Interface for the ERC20MoonwellMorphoStrategy contract
 */
interface IERC20MoonwellMorphoStrategy {
    /**
     * @notice Gets the underlying token of the strategy
     * @return The underlying ERC20 token
     */
    function token() external view returns (IERC20);

    /**
     * @notice Gets the owner of the strategy
     * @return The owner address
     */
    function owner() external view returns (address);

    /**
     * @notice Deposit tokens into the strategy
     * @param amount The amount to deposit
     */
    function deposit(uint256 amount) external;
}
