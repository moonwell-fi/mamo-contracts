// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountRegistry} from "@contracts/AccountRegistry.sol";

import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IMulticall} from "@interfaces/IMulticall.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MamoAccount
 * @notice Acts as an intermediary UUPS proxy contract that holds user stakes and enables automated reward management
 * @dev This contract inherits from Multicall for multicall functionality and is designed to be used as a proxy implementation
 */
contract MamoAccount is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard, IMulticall {
    /**
     * @notice Emitted when a multicall is executed
     * @param initiator The address that initiated the multicall
     * @param callsCount The number of calls executed
     */
    event MulticallExecuted(address indexed initiator, uint256 callsCount);

    /// @notice The AccountRegistry contract for permission management
    AccountRegistry public registry;

    /// @notice The MamoStrategyRegistry contract for implementation validation
    IMamoStrategyRegistry public mamoStrategyRegistry;

    /**
     * @notice Constructor disables initializers in the implementation contract
     */
    constructor() {
        // Disable initializers in the implementation contract
        _disableInitializers();
    }

    /**
     * @notice Initialize the account
     * @param _owner The owner of the account
     * @param _registry The AccountRegistry contract
     * @param _mamoStrategyRegistry The MamoStrategyRegistry contract
     */
    function initialize(address _owner, AccountRegistry _registry, IMamoStrategyRegistry _mamoStrategyRegistry)
        external
        initializer
    {
        require(_owner != address(0), "Invalid owner");
        require(address(_registry) != address(0), "Invalid registry");
        require(address(_mamoStrategyRegistry) != address(0), "Invalid strategy registry");

        registry = _registry;
        mamoStrategyRegistry = _mamoStrategyRegistry;

        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @param newImplementation The new implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Check if the new implementation is whitelisted in MamoStrategyRegistry
        require(mamoStrategyRegistry.whitelistedImplementations(newImplementation), "Implementation not whitelisted");
    }

    modifier onlyWhitelistedStrategy() {
        require(registry.isWhitelistedStrategy(address(this), msg.sender), "Strategy not whitelisted");
        _;
    }

    /**
     * @notice Executes a sequence of arbitrary calls to contracts
     * @param calls Array of Call structs containing target, data, and value for each call
     * @dev Reverts on any failure - no partial success handling
     * @dev Can be used for any contract calls, not just strategies
     * @dev Only callable by the contract owner
     * @dev Validates that total call values don't exceed msg.value and refunds excess ETH
     * @dev Protected against reentrancy attacks
     */
    function multicall(IMulticall.Call[] calldata calls) external payable onlyWhitelistedStrategy nonReentrant {
        require(calls.length > 0, "Multicall: Empty calls array");

        // Calculate total ETH required for all calls
        uint256 totalValue = 0;
        for (uint256 i = 0; i < calls.length; i++) {
            totalValue += calls[i].value;
        }

        // Ensure we have enough ETH to cover all calls
        require(totalValue <= msg.value, "Multicall: Insufficient ETH provided");

        // Execute all calls
        for (uint256 i = 0; i < calls.length; i++) {
            IMulticall.Call calldata call = calls[i];
            require(call.target != address(0), "Multicall: Invalid target address");

            (bool success, bytes memory returnData) = call.target.call{value: call.value}(call.data);

            if (!success) {
                // Revert with the original error data
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }

        // Refund any excess ETH to the caller
        uint256 excessETH = msg.value - totalValue;
        if (excessETH > 0) {
            (bool refundSuccess,) = payable(msg.sender).call{value: excessETH}("");
            require(refundSuccess, "Multicall: ETH refund failed");
        }

        emit MulticallExecuted(msg.sender, calls.length);
    }
}
