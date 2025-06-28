// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IPool
 * @dev Interface for Pool contracts
 */
interface IPool {
    /**
     * @notice The pool's fee in hundredths of a bip, i.e. 1e-6
     * @return The fee
     */
    function fee() external view returns (uint24);

    /**
     * @notice The pool's tick spacing
     * @return The tick spacing
     */
    function tickSpacing() external view returns (int24);
}
