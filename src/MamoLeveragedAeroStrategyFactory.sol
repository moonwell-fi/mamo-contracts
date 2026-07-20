// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "./ERC1967Proxy.sol";
import {MamoLeveragedAeroStrategy} from "./MamoLeveragedAeroStrategy.sol";
import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title MamoLeveragedAeroStrategyFactory
 * @notice Factory for creating per-user {MamoLeveragedAeroStrategy} accounts.
 * @dev Deploys {ERC1967Proxy} instances pointing to a shared {MamoLeveragedAeroStrategy} implementation
 *      via CREATE2 (deterministic address keyed on the user), initializes them, and registers them with
 *      the {IMamoStrategyRegistry}. Creation is gated to the backend role or the user themselves.
 */
contract MamoLeveragedAeroStrategyFactory is AccessControl {
    /// @notice Backend role for strategy creation operations.
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice The MamoStrategyRegistry that tracks and owns strategy registration.
    address public immutable mamoStrategyRegistry;

    /// @notice The {MamoLeveragedAeroStrategy} implementation the proxies delegate to.
    address public immutable strategyImplementation;

    /// @notice The strategy type ID assigned to accounts created by this factory.
    uint256 public immutable strategyTypeId;

    /// @notice The vendored Sherwood leveraged Aerodrome CL strategy each account drives.
    address public immutable sherwoodStrategy;

    /// @notice The USDC token (6dp) used by the accounts.
    address public immutable usdc;

    /// @notice Typed reference to the MamoStrategyRegistry.
    IMamoStrategyRegistry public immutable mamoStrategyRegistryInterface;

    /// @notice Emitted when a new account is created for a user.
    event StrategyCreated(address indexed user, address indexed strategy);

    /**
     * @notice Constructor that initializes the factory with all required parameters.
     * @param _admin Address granted the DEFAULT_ADMIN_ROLE.
     * @param _mamoBackend Address granted the BACKEND_ROLE (the Mamo backend).
     * @param _mamoStrategyRegistry Address of the MamoStrategyRegistry contract.
     * @param _strategyImplementation Address of the MamoLeveragedAeroStrategy implementation.
     * @param _strategyTypeId The strategy type ID (must be non-zero).
     * @param _sherwoodStrategy Address of the Sherwood leveraged Aerodrome CL strategy.
     * @param _usdc Address of the USDC token.
     */
    constructor(
        address _admin,
        address _mamoBackend,
        address _mamoStrategyRegistry,
        address _strategyImplementation,
        uint256 _strategyTypeId,
        address _sherwoodStrategy,
        address _usdc
    ) {
        require(_admin != address(0), "Invalid admin address");
        require(_mamoBackend != address(0), "Invalid mamoBackend address");
        require(_mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(_strategyImplementation != address(0), "Invalid strategyImplementation address");
        require(_strategyImplementation.code.length > 0, "Implementation must be a contract");
        require(_strategyTypeId != 0, "Strategy type id not set");
        require(_sherwoodStrategy != address(0), "Invalid sherwoodStrategy address");
        require(_usdc != address(0), "Invalid usdc address");

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(BACKEND_ROLE, _mamoBackend);

        mamoStrategyRegistry = _mamoStrategyRegistry;
        strategyImplementation = _strategyImplementation;
        strategyTypeId = _strategyTypeId;
        sherwoodStrategy = _sherwoodStrategy;
        usdc = _usdc;

        mamoStrategyRegistryInterface = IMamoStrategyRegistry(_mamoStrategyRegistry);
    }

    /**
     * @notice Computes the deterministic address for a user's account.
     * @param user The address of the user.
     * @return The deterministic address where the account will be deployed.
     */
    function computeStrategyAddress(address user) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(user));

        bytes memory bytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(strategyImplementation, ""));

        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    /**
     * @notice Creates a new {MamoLeveragedAeroStrategy} account for a user.
     * @dev Callable by an account with the BACKEND_ROLE or by the user themselves. Reverts if the
     *      account already exists. Deploys the proxy via CREATE2, initializes it, and registers it with
     *      the MamoStrategyRegistry.
     * @param user The address of the user to create the account for.
     * @return strategy The address of the newly created account.
     */
    function createStrategyForUser(address user) public returns (address strategy) {
        require(user != address(0), "Invalid user address");
        require(hasRole(BACKEND_ROLE, msg.sender) || msg.sender == user, "Only backend or user can create strategy");

        address strategyAddress = computeStrategyAddress(user);
        // Check if strategy already exists
        require(strategyAddress.code.length == 0, "Strategy already exists");

        // Generate salt for deterministic deployment (only user address)
        bytes32 salt = keccak256(abi.encodePacked(user));

        // Deploy the proxy using CREATE2 with deterministic address
        bytes memory bytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(strategyImplementation, ""));

        strategy = Create2.deploy(0, salt, bytecode);

        // Initialize the account with the parameters
        MamoLeveragedAeroStrategy(payable(strategy))
            .initialize(
                MamoLeveragedAeroStrategy.InitParams({
                mamoStrategyRegistry: mamoStrategyRegistry,
                strategyTypeId: strategyTypeId,
                owner: user,
                sherwoodStrategy: sherwoodStrategy,
                usdc: usdc
            })
            );

        // Register the account with the MamoStrategyRegistry
        mamoStrategyRegistryInterface.addStrategy(user, strategy);

        emit StrategyCreated(user, strategy);

        return strategy;
    }

    /**
     * @notice Alias for {createStrategyForUser}.
     * @param user The address of the user to create the account for.
     * @return strategy The address of the newly created account.
     */
    function createStrategy(address user) external returns (address strategy) {
        return createStrategyForUser(user);
    }
}
