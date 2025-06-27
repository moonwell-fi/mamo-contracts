// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountRegistry} from "@contracts/AccountRegistry.sol";
import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoAccount} from "@contracts/MamoAccount.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/**
 * @title MamoAccountFactory
 * @notice Factory contract for deploying user accounts with standardized configuration
 * @dev Supports both user self-deployment and backend-initiated deployment
 */
contract MamoAccountFactory is AccessControlEnumerable {
    /// @notice Backend role for creating accounts on behalf of users
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Guardian role for emergency pause functionality
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice The AccountRegistry contract
    AccountRegistry public immutable registry;

    /// @notice The MamoStrategyRegistry contract
    IMamoStrategyRegistry public immutable mamoStrategyRegistry;

    /// @notice The MamoAccount implementation contract
    address public immutable accountImplementation;

    /// @notice The strategy type ID for MamoAccount implementations
    uint256 public immutable accountStrategyTypeId;

    /// @notice Mapping of user to their account address
    mapping(address => address) public userAccounts;

    event AccountCreated(address indexed user, address indexed account, address indexed creator);

    /**
     * @notice Constructor sets up the factory with required contracts and roles
     * @param admin The address to grant the DEFAULT_ADMIN_ROLE to
     * @param backend The address to grant the BACKEND_ROLE to
     * @param guardian The address to grant the GUARDIAN_ROLE to
     * @param _registry The AccountRegistry contract
     * @param _mamoStrategyRegistry The MamoStrategyRegistry contract
     * @param _accountImplementation The MamoAccount implementation contract
     * @param _accountStrategyTypeId The strategy type ID for MamoAccount implementations
     */
    constructor(
        address admin,
        address backend,
        address guardian,
        AccountRegistry _registry,
        IMamoStrategyRegistry _mamoStrategyRegistry,
        address _accountImplementation,
        uint256 _accountStrategyTypeId
    ) {
        require(admin != address(0), "Invalid admin address");
        require(backend != address(0), "Invalid backend address");
        require(guardian != address(0), "Invalid guardian address");
        require(address(_registry) != address(0), "Invalid registry");
        require(address(_mamoStrategyRegistry) != address(0), "Invalid strategy registry");
        require(_accountImplementation != address(0), "Invalid implementation");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, backend);
        _grantRole(GUARDIAN_ROLE, guardian);

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
    function createAccountForUser(address user) external onlyRole(BACKEND_ROLE) returns (address account) {
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
        bytes32 salt = keccak256(abi.encodePacked(user, block.timestamp));

        // Deploy new account proxy
        account = address(
            new ERC1967Proxy{salt: salt}(
                accountImplementation,
                abi.encodeWithSelector(
                    MamoAccount.initialize.selector, user, registry, mamoStrategyRegistry, accountStrategyTypeId
                )
            )
        );

        // Register the account
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

    /**
     * @notice Check if a user has an account
     * @param user The user address
     * @return True if the user has an account
     */
    function hasAccount(address user) external view returns (bool) {
        return userAccounts[user] != address(0);
    }
}
