// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoAccountRegistry} from "@contracts/MamoAccountRegistry.sol";
import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoAccount} from "@contracts/MamoAccount.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
/**
 * @title MamoAccountFactory
 * @notice Factory contract for deploying user accounts with standardized configuration
 * @dev Supports both user self-deployment and backend-initiated deployment
 */

contract MamoAccountFactory {
    /// @notice The MamoAccountRegistry contract
    MamoAccountRegistry public immutable registry;

    /// @notice The MamoStrategyRegistry contract
    IMamoStrategyRegistry public immutable mamoStrategyRegistry;

    /// @notice The backend address that can create accounts for users
    address public immutable mamoBackend;

    /// @notice The MamoAccount implementation contract
    address public immutable accountImplementation;

    /// @notice The strategy type ID for MamoAccount implementations
    uint256 public immutable accountStrategyTypeId;

    /// @notice Mapping of user to their account address
    mapping(address => address) public userAccounts;

    event AccountCreated(address indexed user, address indexed account, address indexed creator);

    /**
     * @notice Constructor sets up the factory with required contracts and backend address
     * @param _mamoBackend The backend address that can create accounts for users
     * @param _registry The MamoAccountRegistry contract
     * @param _mamoStrategyRegistry The MamoStrategyRegistry contract
     * @param _accountImplementation The MamoAccount implementation contract
     * @param _accountStrategyTypeId The strategy type ID for MamoAccount implementations
     */
    constructor(
        address _mamoBackend,
        MamoAccountRegistry _registry,
        IMamoStrategyRegistry _mamoStrategyRegistry,
        address _accountImplementation,
        uint256 _accountStrategyTypeId
    ) {
        require(_mamoBackend != address(0), "Invalid backend address");
        require(address(_registry) != address(0), "Invalid registry");
        require(address(_mamoStrategyRegistry) != address(0), "Invalid strategy registry");
        require(_accountImplementation != address(0), "Invalid implementation");

        mamoBackend = _mamoBackend;
        registry = _registry;
        mamoStrategyRegistry = _mamoStrategyRegistry;
        accountImplementation = _accountImplementation;
        accountStrategyTypeId = _accountStrategyTypeId;
    }

    /**
     * @notice Create a new account for the caller
     * @return account The address of the deployed account
     */
    function createAccount() external returns (address account) {
        return _createAccountForUser(msg.sender, msg.sender);
    }

    /**
     * @notice Create a new account for a user (backend only)
     * @param user The user to create the account for
     * @return account The address of the deployed account
     */
    function createAccountForUser(address user) external returns (address account) {
        require(msg.sender == mamoBackend, "Only backend can create accounts for users");
        return _createAccountForUser(user, msg.sender);
    }

    /**
     * @notice Internal function to create account for a user
     * @param user The user to create the account for
     * @param creator The address initiating the creation
     * @return account The address of the deployed account
     */
    function _createAccountForUser(address user, address creator) internal returns (address account) {
        require(user != address(0), "Invalid user");
        require(userAccounts[user] == address(0), "Account already exists");

        // Calculate deterministic address using CREATE2
        bytes32 salt = keccak256(abi.encodePacked(user));

        // Deploy new account proxy without initialization
        account = address(new ERC1967Proxy{salt: salt}(accountImplementation, ""));

        // Initialize the account separately after deployment
        MamoAccount(account).initialize(user, registry, mamoStrategyRegistry, accountStrategyTypeId);

        // Register the account as a strategy in the MamoStrategyRegistry
        mamoStrategyRegistry.addStrategy(user, account);

        // Register the account locally
        userAccounts[user] = account;

        emit AccountCreated(user, account, creator);

        return account;
    }

    /**
     * @notice Get the account address for a user
     * @param user The user address
     * @return The account address (zero if not created)
     */
    function getAccountForUser(address user) external view returns (address) {
        return userAccounts[user];
    }
}
