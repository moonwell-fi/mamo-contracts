// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountRegistry} from "@contracts/AccountRegistry.sol";

import {StrategyMulticall} from "@contracts/StrategyMulticall.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title MamoAccount
 * @notice Acts as an intermediary UUPS proxy contract that holds user stakes and enables automated reward management
 * @dev This contract inherits from StrategyMulticall for multicall functionality and is designed to be used as a proxy implementation
 */
contract MamoAccount is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /// @notice The AccountRegistry contract for permission management
    AccountRegistry public immutable registry;

    /// @notice The MamoStrategyRegistry contract for implementation validation
    IMamoStrategyRegistry public immutable mamoStrategyRegistry;

    /**
     * @notice Constructor sets immutable references
     * @param _registry The AccountRegistry contract
     * @param _mamoStrategyRegistry The MamoStrategyRegistry contract
     */
    constructor(AccountRegistry _registry, IMamoStrategyRegistry _mamoStrategyRegistry) {
        require(address(_registry) != address(0), "Invalid registry");
        require(address(_mamoStrategyRegistry) != address(0), "Invalid strategy registry");

        registry = _registry;
        mamoStrategyRegistry = _mamoStrategyRegistry;

        // Disable initializers in the implementation contract
        _disableInitializers();
    }

    /**
     * @notice Initialize the account
     * @param _owner The owner of the account
     */
    function initialize(address _owner) external initializer {
        require(_owner != address(0), "Invalid owner");

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
     * @notice Execute a multicall with strategy validation (similar to StrategyMulticall.genericMulticall)
     * @param calls Array of Call structs containing target, data, and value for each call
     */
    function genericMulticall(StrategyMulticall.Call[] calldata calls) external payable onlyWhitelistedStrategy {
        require(calls.length > 0, "Empty calls array");

        for (uint256 i = 0; i < calls.length; i++) {
            StrategyMulticall.Call calldata call = calls[i];
            require(call.target != address(0), "Invalid target address");

            (bool success, bytes memory returnData) = call.target.call{value: call.value}(call.data);

            if (!success) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
    }

    /**
     * @notice Batch multiple delegatecalls together
     * @param targets Array of targets to call
     * @param data Array of data to pass with the calls
     */
    function multicall(address[] calldata targets, bytes[] calldata data) external payable onlyWhitelistedStrategy {
        require(targets.length == data.length, "Length mismatch");

        for (uint256 i = 0; i < data.length; i++) {
            if (targets[i] == address(0)) {
                continue; // No-op
            }

            (bool success, bytes memory result) = targets[i].delegatecall(data[i]);

            if (!success) {
                if (result.length == 0) revert();
                assembly {
                    revert(add(32, result), mload(result))
                }
            }
        }
    }

    /**
     * @notice Execute a direct call to a target contract
     * @param target The target contract address
     * @param data The call data
     * @return result The return data from the call
     */
    function execute(address target, bytes calldata data)
        external
        payable
        onlyWhitelistedStrategy
        returns (bytes memory result)
    {
        require(target != address(0), "Invalid target");

        (bool success, bytes memory returnData) = target.call{value: msg.value}(data);

        if (!success) {
            if (returnData.length == 0) revert();
            assembly {
                revert(add(32, returnData), mload(returnData))
            }
        }

        return returnData;
    }

    /**
     * @notice Receive function to accept ETH
     */
    receive() external payable {}

    /**
     * @notice Fallback function
     */
    fallback() external payable {}
}
