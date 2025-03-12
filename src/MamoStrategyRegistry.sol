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
 * @dev Uses AccessControlEnumerable for role-based access control and Pausable for emergency stops
 */
contract MamoStrategyRegistry is AccessControlEnumerable, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    /// @notice EIP-1967 implementation slot for accessing the implementation address of a proxy
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Role definitions
    /// @notice Role identifier for guardians who can pause/unpause the contract
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Role identifier for the backend that can manage strategies
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    // State variables
    /// @notice Set of all strategy addresses for each user
    mapping(address => EnumerableSet.AddressSet) private _userStrategies;

    /// @notice Mapping of whitelisted implementation addresses
    mapping(address => bool) public whitelistedImplementations;

    /// @notice Maps strategy types to their latest implementation
    mapping(bytes32 => address) public latestImplementationByType;

    /// @notice Maps implementations to their strategy type
    mapping(address => bytes32) public implementationToStrategyType;

    // Events
    /// @notice Emitted when a strategy is added for a user
    event StrategyAdded(address indexed user, address strategy, address implementation);

    /// @notice Emitted when a strategy is removed for a user
    event StrategyRemoved(address indexed user, address strategy);

    /// @notice Emitted when a strategy's implementation is updated
    event StrategyImplementationUpdated(
        address indexed strategy, address indexed oldImplementation, address indexed newImplementation
    );

    /// @notice Emitted when an implementation is whitelisted
    event ImplementationWhitelisted(address indexed implementation, bytes32 indexed strategyType);

    /// @notice Emitted when an implementation is removed from the whitelist
    event ImplementationRemovedFromWhitelist(address indexed implementation);

    /// @notice Emitted when strategies are updated
    event StrategiesUpdated(address indexed implementation, address[] strategies, uint256 splitA, uint256 splitB);

    /// @notice Emitted when rewards are claimed
    event RewardsClaimed(address indexed implementation, address[] strategies);

    /// @notice Emitted when a strategy update fails
    event StrategyUpdateFailed(address indexed strategy, string reason);

    /**
     * @notice Constructor that sets up initial roles
     * @dev Grants DEFAULT_ADMIN_ROLE, BACKEND_ROLE, and GUARDIAN_ROLE to the specified addresses
     * @param admin The address to grant the DEFAULT_ADMIN_ROLE to
     * @param backend The address to grant the BACKEND_ROLE to
     * @param guardian The address to grant the GUARDIAN_ROLE to
     */
    constructor(address admin, address backend, address guardian) {
        require(admin != address(0), "Invalid admin address");
        require(backend != address(0), "Invalid backend address");
        require(guardian != address(0), "Invalid guardian address");
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, backend);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ==================== PERMISSIONLESS FUNCTIONS ====================

    /**
     * @notice Updates the implementation of a strategy to the latest implementation of the same type
     * @dev Only callable by the user who owns the strategy
     * @param strategy The address of the strategy to update
     */
    function upgradeStrategy(address strategy) external whenNotPaused {
        // Check if the caller is the owner of the strategy
        require(isUserStrategy(msg.sender, strategy), "Caller is not the owner of the strategy");

        // Get the old implementation address
        address oldImplementation = getStrategyImplementation(strategy);

        // Get the strategy type
        bytes32 strategyType = implementationToStrategyType[oldImplementation];

        // Get the latest implementation for this strategy type
        address latestImplementation = latestImplementationByType[strategyType];

        // Ensure we're not already on the latest implementation
        require(oldImplementation != latestImplementation, "Already on latest implementation");

        // Check if the latest implementation is whitelisted (should always be true, but checking for safety)
        require(whitelistedImplementations[latestImplementation], "Latest implementation not whitelisted");

        // Update the implementation through the proxy's upgrade mechanism
        // Call upgradeToAndCall with empty data to just upgrade the implementation
        IUUPSUpgradeable(strategy).upgradeToAndCall(latestImplementation, new bytes(0));

        emit StrategyImplementationUpdated(strategy, oldImplementation, latestImplementation);
    }

    // ==================== ROLE-RESTRICTED FUNCTIONS ====================

    /**
     * @notice Pauses the contract in case of emergency
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     * @dev When paused, most functions that modify state will revert
     */
    function pause() external onlyRole(GUARDIAN_ROLE) whenNotPaused {
        _pause();
    }

    /**
     * @notice Unpauses the contract after an emergency is resolved
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     * @dev Allows normal operation to resume after the contract was paused
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

        // Check backend role is set to Mamo backend
        require(
            strategyContract.hasRole(keccak256("BACKEND_ROLE"), getRoleMember("BACKEND_ROLE", 0)),
            "Backend role not set correctly"
        );

        // Add the strategy to the user's strategies
        _userStrategies[user].add(strategy);

        emit StrategyAdded(user, strategy, implementation);
    }

    /**
     * @notice Removes a strategy for a user
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param user The address of the user
     * @param strategy The address of the strategy to remove
     */
    function removeStrategy(address user, address strategy) external whenNotPaused onlyRole(BACKEND_ROLE) {
        // Check if the strategy exists for the user
        require(_userStrategies[user].contains(strategy), "Strategy not found for user");

        // Remove the strategy
        _userStrategies[user].remove(strategy);

        emit StrategyRemoved(user, strategy);
    }

    // ==================== GETTER FUNCTIONS ====================

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
