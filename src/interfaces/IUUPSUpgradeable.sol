// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @dev Interface for the UUPS (Universal Upgradeable Proxy Standard) pattern.
 * This interface defines the methods that a UUPS proxy implementation should expose.
 */
interface IUUPSUpgradeable {
    /**
     * @dev Upgrades the implementation to `newImplementation` and calls a function on the new implementation.
     * This function is only callable through the proxy, not through the implementation.
     * @param newImplementation Address of the new implementation
     * @param data Data to send as msg.data in the low level call.
     * It usually encodes a function call to the implementation.
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}
