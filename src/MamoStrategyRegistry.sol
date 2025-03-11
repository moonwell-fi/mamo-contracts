// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IUUPSUpgradeable} from "./interfaces/IUUPSUpgradeable.sol";

/**
 * @title MamoStrategyRegistry
 * @notice This contract is responsible for tracking user strategies, deploying new strategies, and coordinating operations across strategies
 */
contract MamoStrategyRegistry is AccessControlEnumerable, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // EIP-1967 implementation slot
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Role definitions
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    // Set of all strategy addresses for each user
    mapping(address => EnumerableSet.AddressSet) private _userStrategies;

    // Whitelisted implementations
    mapping(address => bool) public whitelistedImplementations;

    // Maps strategy types to their latest implementation
    mapping(bytes32 => address) public latestImplementationByType;

    // Maps implementations to their strategy type
    mapping(address => bytes32) public implementationToStrategyType;

    // Events
    event StrategyAdded(address indexed user, address strategy, address implementation);
    event StrategyRemoved(address indexed user, address strategy);
    event StrategyImplementationUpdated(
        address indexed strategy, address indexed oldImplementation, address indexed newImplementation
    );
    event ImplementationWhitelisted(address indexed implementation, bytes32 indexed strategyType);
    event ImplementationRemovedFromWhitelist(address indexed implementation);
    event StrategiesUpdated(address indexed implementation, address[] strategies, uint256 splitA, uint256 splitB);
    event RewardsClaimed(address indexed implementation, address[] strategies);
    event StrategyUpdateFailed(address indexed strategy, string reason);

    constructor() {
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BACKEND_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    /**
     * @notice Pauses the contract
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function pause() external onlyRole(GUARDIAN_ROLE) whenNotPaused {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function unpause() external onlyRole(GUARDIAN_ROLE) whenPaused {
        _unpause();
    }

    /**
     * @notice Adds an implementation to the whitelist with its strategy type
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param implementation The address of the implementation to whitelist
     * @param strategyTypeId The bytes32 representation of the strategy type
     */
    function whitelistImplementation(address implementation, bytes32 strategyTypeId) external onlyRole(BACKEND_ROLE) {
        require(implementation != address(0), "Invalid implementation address");
        require(!whitelistedImplementations[implementation], "Implementation already whitelisted");

        whitelistedImplementations[implementation] = true;
        implementationToStrategyType[implementation] = strategyTypeId;
        latestImplementationByType[strategyTypeId] = implementation;

        emit ImplementationWhitelisted(implementation, strategyTypeId);
    }

    /**
     * @notice Gets the strategy type for an implementation
     * @param implementation The address of the implementation
     * @return The strategy type as a bytes32 value
     */
    function getImplementationType(address implementation) external view returns (bytes32) {
        return implementationToStrategyType[implementation];
    }

    /**
     * @notice Gets the latest implementation for a strategy type
     * @param strategyType The strategy type as a bytes32 value
     * @return The address of the latest implementation for the strategy type
     */
    function getLatestImplementation(bytes32 strategyType) external view returns (address) {
        return latestImplementationByType[strategyType];
    }

    /**
     * @notice Adds a strategy for a user
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param user The address of the user
     * @param strategy The address of the strategy to add
     */
    function addStrategy(address user, address strategy) external whenNotPaused onlyRole(BACKEND_ROLE) {
        require(user != address(0), "Invalid user address");
        require(strategy != address(0), "Invalid strategy address");
        require(!_userStrategies[user].contains(strategy), "Strategy already added for user");

        // Get the implementation address
        address implementation = getStrategyImplementation(strategy);
        require(implementation != address(0), "Invalid implementation");
        require(whitelistedImplementations[implementation], "Implementation not whitelisted");

        // Check the strategy roles are correct
        // Check that the strategy has the correct roles set up
        IAccessControlEnumerable strategyContract = IAccessControlEnumerable(strategy);
        
        // Check owner role is set to user
        require(strategyContract.hasRole(keccak256("OWNER_ROLE"), user), "Owner role not set correctly");
        
        // Check upgrader role is set to this registry
        require(strategyContract.hasRole(keccak256("UPGRADER_ROLE"), address(this)), "Upgrader role not set correctly");
        
        // Check backend role is set to our backend
        require(strategyContract.hasRole(keccak256("BACKEND_ROLE"), getRoleMember("BACKEND_ROLE", 0)), "Backend role not set correctly");

        // Add the strategy to the user's strategies
        _userStrategies[user].add(strategy);

        emit StrategyAdded(user, strategy, implementation);
    }

    /**
     * @notice Updates the implementation of a strategy
     * @dev Only callable by the user who owns the strategy
     * @param strategy The address of the strategy to update
     * @param newImplementation The address of the new implementation
     */
    function upgradeStrategy(address strategy, address newImplementation) external whenNotPaused {
        // Check if the caller is the owner of the strategy
        require(isUserStrategy(msg.sender, strategy), "Caller is not the owner of the strategy");

        // Check if the new implementation is whitelisted
        require(whitelistedImplementations[newImplementation], "New implementation not whitelisted");

        // Get the old implementation address
        address oldImplementation = getStrategyImplementation(strategy);

        // Check if the new implementation has the same strategy type
        require(
            implementationToStrategyType[oldImplementation] == implementationToStrategyType[newImplementation],
            "New implementation has different strategy type"
        );

        // Update the implementation through the proxy's upgrade mechanism
        // Call upgradeToAndCall with empty data to just upgrade the implementation
        IUUPSUpgradeable(strategy).upgradeToAndCall(newImplementation, new bytes(0));

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
     * @notice Checks if a strategy belongs to a user
     * @param user The address of the user
     * @param strategy The address of the strategy
     * @return True if the strategy belongs to the user, false otherwise
     */
    function isUserStrategy(address user, address strategy) public view returns (bool) {
        return _userStrategies[user].contains(strategy);
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
}
