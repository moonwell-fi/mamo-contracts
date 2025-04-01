// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";

import {IBaseStrategy} from "@interfaces/IBaseStrategy.sol";
import {IUUPSUpgradeable} from "@interfaces/IUUPSUpgradeable.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title MamoStrategyRegistry
 * @notice This contract is responsible for tracking user strategies, deploying new strategies, and coordinating operations across strategies
 * @dev Uses AccessControlEnumerable for role-based access control and Pausable for emergency stops
 */
contract MamoStrategyRegistry is AccessControlEnumerable, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Role definitions
    /// @notice Role identifier for guardians who can pause/unpause the contract
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Role identifier for the backend that can manage strategies
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Counter for strategy type IDs
    uint256 public nextStrategyTypeId;

    // State variables
    /// @notice Set of all strategy addresses for each user
    mapping(address => EnumerableSet.AddressSet) private _userStrategies;

    /// @notice Mapping of whitelisted implementation addresses
    mapping(address => bool) public whitelistedImplementations;

    /// @notice Maps strategy IDs to their latest implementation
    mapping(uint256 => address) public latestImplementationById;

    /// @notice Maps implementations to their strategy ID
    mapping(address => uint256) public implementationToId;

    // Events
    /// @notice Emitted when a strategy is added for a user
    event StrategyAdded(address indexed user, address strategy, address implementation);

    /// @notice Emitted when a strategy's implementation is updated
    event StrategyImplementationUpdated(
        address indexed strategy, address indexed oldImplementation, address indexed newImplementation
    );

    /// @notice Emitted when an implementation is whitelisted
    event ImplementationWhitelisted(address indexed implementation, uint256 indexed strategyType);

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

        nextStrategyTypeId = 1;
    }

    // ==================== PERMISSIONLESS FUNCTIONS ====================

    /**
     * @notice Updates the implementation of a strategy to the latest implementation of the same type
     * @dev Only callable by the user who owns the strategy
     * @param strategy The address of the strategy to update
     * @param newImplementation The new implementation address
     */
    function upgradeStrategy(address strategy, address newImplementation) external whenNotPaused {
        // Check if the caller is the owner of the strategy
        require(isUserStrategy(msg.sender, strategy), "Caller is not the owner of the strategy");

        // Get the old implementation address
        address oldImplementation = ERC1967Proxy(payable(strategy)).getImplementation();

        require(oldImplementation != newImplementation, "Already using implementation");

        // Get the strategy ID
        uint256 strategyId = implementationToId[oldImplementation];

        // Get the latest implementation for this strategy ID
        address latestImplementation = latestImplementationById[strategyId];

        require(latestImplementation == newImplementation, "Not latest implementation");

        // Check if the latest implementation is whitelisted (should always be true, but checking for safety)
        require(whitelistedImplementations[latestImplementation], "Implementation not whitelisted");

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
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract after an emergency is resolved
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     * @dev Allows normal operation to resume after the contract was paused
     */
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /**
     * @notice Adds an implementation to the whitelist with a strategy type ID
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param implementation The address of the implementation to whitelist
     * @param strategyTypeId The strategy type ID to assign. If 0, a new ID will be assigned
     * @return assignedStrategyTypeId The assigned strategy type ID
     */
    function whitelistImplementation(address implementation, uint256 strategyTypeId)
        external
        onlyRole(BACKEND_ROLE)
        returns (uint256 assignedStrategyTypeId)
    {
        require(implementation != address(0), "Invalid implementation address");
        require(!whitelistedImplementations[implementation], "Implementation already whitelisted");

        // If strategyTypeId is 0, assign a new strategy type ID
        if (strategyTypeId == 0) {
            assignedStrategyTypeId = nextStrategyTypeId++;
        } else {
            // Otherwise, use the provided strategyTypeId
            assignedStrategyTypeId = strategyTypeId;
        }

        whitelistedImplementations[implementation] = true;
        implementationToId[implementation] = assignedStrategyTypeId;
        latestImplementationById[assignedStrategyTypeId] = implementation;

        emit ImplementationWhitelisted(implementation, assignedStrategyTypeId);
    }

    /**
     * @notice Adds a strategy for a user
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @dev Validates that the strategy has the correct registry address set up
     * @param user The address of the user
     * @param strategy The address of the strategy to add
     */
    function addStrategy(address user, address strategy) external whenNotPaused onlyRole(BACKEND_ROLE) {
        require(user != address(0), "Invalid user address");
        require(strategy != address(0), "Invalid strategy address");
        require(!_userStrategies[user].contains(strategy), "Strategy already added for user");

        // Get the implementation address
        address implementation = ERC1967Proxy(payable(strategy)).getImplementation();
        require(implementation != address(0), "Invalid implementation");
        require(whitelistedImplementations[implementation], "Implementation not whitelisted");

        // Check the strategy addresses are correct
        IBaseStrategy strategyContract = IBaseStrategy(strategy);

        // Check strategy registry address is set to this registry
        require(
            address(strategyContract.mamoStrategyRegistry()) == address(this), "Strategy registry not set correctly"
        );
        require(
            implementation == latestImplementationById[strategyContract.strategyTypeId()], "Not latest implementation"
        );

        // Add the strategy to the user's strategies
        _userStrategies[user].add(strategy);

        emit StrategyAdded(user, strategy, implementation);
    }

    // ==================== GETTER FUNCTIONS ====================

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
     * @notice Gets the backend address (first member of the BACKEND_ROLE)
     * @return The address of the backend
     */
    function getBackendAddress() external view returns (address) {
        return getRoleMember(BACKEND_ROLE, 0);
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Recovers ERC20 tokens accidentally sent to this contract
     * @dev Only callable by accounts with the DEFAULT_ADMIN_ROLE
     * @param tokenAddress The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address tokenAddress, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");

        bool result = IERC20(tokenAddress).transfer(to, amount);
        require(result == true, "Token transfer failed");
    }
}
