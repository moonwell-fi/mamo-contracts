// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/**
 * @title MamoCore
 * @notice This contract is responsible for tracking user strategies and coordinating operations across strategies
 * @dev It's upgradeable through a UUPS pattern, with role-based access control.
 */
contract MamoCore is AccessControlEnumerable, Pausable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // EIP-1967 implementation slot
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    
    // Role definitions
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant MAMO_SERVICE_ROLE = keccak256("MAMO_SERVICE_ROLE");
    
    // Set of all strategy addresses for a user
    mapping(address => EnumerableSet.AddressSet) private _userStrategies;
    
    // Total strategies registered
    EnumerableSet.AddressSet private _allStrategies;
    
    // Whitelisted implementations
    mapping(address => bool) private _whitelistedImplementations;
    
    // Mapping from implementation to strategies using it
    mapping(address => EnumerableSet.AddressSet) private _implementationStrategies;

    // Events
    event StrategyAdded(address indexed user, address strategy, address implementation);
    event StrategyRemoved(address indexed user, address strategy);
    event StrategyImplementationUpdated(address indexed strategy, address indexed oldImplementation, address indexed newImplementation);
    event ImplementationWhitelisted(address indexed implementation);
    event ImplementationRemovedFromWhitelist(address indexed implementation);
    event StrategiesUpdated(address indexed implementation, address[] strategies, uint256 splitA, uint256 splitB);
    event RewardsClaimed(address indexed implementation, address[] strategies);
    event StrategyUpdateFailed(address indexed strategy, string reason);
    event StrategyDeployed(address indexed user, address strategy, address implementation);

    constructor() {
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MAMO_SERVICE_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }
    
    /**
     * @notice Pauses the contract
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpauses the contract
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Adds an implementation to the whitelist
     * @dev Only callable by accounts with the MAMO_SERVICE_ROLE
     * @param implementation The address of the implementation to whitelist
     */
    function whitelistImplementation(address implementation) external onlyRole(MAMO_SERVICE_ROLE) {
        require(implementation != address(0), "Invalid implementation address");
        require(!_whitelistedImplementations[implementation], "Implementation already whitelisted");
        
        _whitelistedImplementations[implementation] = true;
        emit ImplementationWhitelisted(implementation);
    }
    
    /**
     * @notice Removes an implementation from the whitelist
     * @dev Only callable by accounts with the MAMO_SERVICE_ROLE
     * @param implementation The address of the implementation to remove from the whitelist
     */
    function removeImplementationFromWhitelist(address implementation) external onlyRole(MAMO_SERVICE_ROLE) {
        require(_whitelistedImplementations[implementation], "Implementation not whitelisted");
        
        _whitelistedImplementations[implementation] = false;
        emit ImplementationRemovedFromWhitelist(implementation);
    }
    
    /**
     * @notice Deploys a new strategy for a user
     * @dev Only callable by accounts with the MAMO_SERVICE_ROLE
     * @param user The address of the user
     * @param implementation The address of the implementation
     * @return The address of the deployed strategy
     */
    function deployStrategy(address user, address implementation) external whenNotPaused onlyRole(MAMO_SERVICE_ROLE) returns (address) {
        // Verify the implementation is whitelisted
        require(user != address(0), "Invalid user address");
        require(implementation != address(0), "Invalid implementation address");
        require(_whitelistedImplementations[implementation], "Implementation not whitelisted");
        
        // Deploy a new strategy contract
        // This is a simplified example and would need to be adapted to the actual deployment mechanism
        // In a real implementation, you would need to use the correct method to deploy a proxy
        // pointing to the implementation
        
        // Example (commented out as it depends on the actual deployment mechanism):
        // bytes memory initData = abi.encodeWithSelector(
        //     IStrategy(implementation).initialize.selector,
        //     user,
        //     address(this),
        //     otherParams...
        // );
        // address strategy = address(new ERC1967Proxy(implementation, initData));
        
        // For now, we'll just emit an event and return a placeholder
        // In a real implementation, you would deploy the strategy and return its address
        
        // Register the strategy
        // _userStrategies[user].add(strategy);
        // _allStrategies.add(strategy);
        // _implementationStrategies[implementation].add(strategy);
        
        // emit StrategyDeployed(user, strategy, implementation);
        
        // Return the strategy address
        // return strategy;
        
        // This is a placeholder implementation
        revert("Not implemented");
    }
    

    /**
     * @notice Updates the implementation of a strategy
     * @dev Only callable by accounts with the MAMO_SERVICE_ROLE
     * @param strategy The address of the strategy to update
     * @param newImplementation The address of the new implementation
     */
    function updateStrategyImplementation(address strategy, address newImplementation) external whenNotPaused onlyRole(MAMO_SERVICE_ROLE) {
        // Check if the strategy exists
        require(_allStrategies.contains(strategy), "Strategy not registered");
        
        // Check if the new implementation is whitelisted
        require(_whitelistedImplementations[newImplementation], "New implementation not whitelisted");
        
        // Get the old implementation address
        address oldImplementation = getStrategyImplementation(strategy);
        
        // Update the implementation through the proxy's upgrade mechanism
        // For UUPS proxies, this would typically be a call to the proxy's upgradeTo function
        // This is a simplified example and would need to be adapted to the actual proxy implementation
        // In a real implementation, you would need to use the correct interface or method to upgrade the proxy
        
        // Example (commented out as it depends on the actual proxy implementation):
        // IProxyAdmin(proxyAdmin).upgrade(strategy, newImplementation);
        // or
        // ITransparentUpgradeableProxy(strategy).upgradeTo(newImplementation);
        
        // Update our tracking
        _implementationStrategies[oldImplementation].remove(strategy);
        _implementationStrategies[newImplementation].add(strategy);
        
        emit StrategyImplementationUpdated(strategy, oldImplementation, newImplementation);
    }
    
    /**
     * @notice Gets all strategies for a user
     * @param user The address of the user
     * @return An array of strategy addresses
     */
    function getUserStrategies(address user) external view returns (address[] memory) {
        uint256 length = _userStrategies[user].length();
        address[] memory strategies = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            strategies[i] = _userStrategies[user].at(i);
        }
        
        return strategies;
    }
    
    /**
     * @notice Gets the implementation address for a strategy
     * @param strategy The address of the strategy (proxy)
     * @return implementation The address of the implementation
     */
    function getStrategyImplementation(address strategy) public view returns (address implementation) {
        // Read the implementation address from the EIP-1967 storage slot
        assembly {
            implementation := sload(add(strategy, _IMPLEMENTATION_SLOT))
        }
    }
    
    /**
     * @notice Gets all strategies with a specific implementation
     * @param implementation The address of the implementation
     * @return An array of strategy addresses
     */
    function getStrategiesByImplementation(address implementation) external view returns (address[] memory) {
        uint256 length = _implementationStrategies[implementation].length();
        address[] memory strategies = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            strategies[i] = _implementationStrategies[implementation].at(i);
        }
        
        return strategies;
    }
    
    /**
     * @notice Checks if an implementation is whitelisted
     * @param implementation The address of the implementation to check
     * @return True if the implementation is whitelisted, false otherwise
     */
    function isImplementationWhitelisted(address implementation) public view returns (bool) {
        return _whitelistedImplementations[implementation];
    }
    
    /**
     * @notice Checks if an address is a registered strategy
     * @param strategy The address to check
     * @return True if the address is a registered strategy, false otherwise
     */
    function isStrategy(address strategy) external view returns (bool) {
        return _allStrategies.contains(strategy);
    }

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only callable by accounts with the DEFAULT_ADMIN_ROLE
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller must have DEFAULT_ADMIN_ROLE");
        // Silence unused parameter warning
        newImplementation;
    }
}
