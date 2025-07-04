// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "./ERC1967Proxy.sol";
import {MamoStakingStrategy} from "./MamoStakingStrategy.sol";
import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title MamoStakingStrategyFactory
 * @notice Factory contract for creating new MamoStakingStrategy instances
 * @dev Creates proxies pointing to the MamoStakingStrategy implementation
 */
contract MamoStakingStrategyFactory {
    /// @notice The maximum allowed slippage in basis points
    uint256 public constant MAX_SLIPPAGE_IN_BPS = 2500; // 25% in basis points

    // Strategy parameters
    address public immutable mamoStrategyRegistry;
    address public immutable mamoBackend;
    address public immutable stakingRegistry;
    address public immutable multiRewards;
    address public immutable mamoToken;
    address public immutable strategyImplementation;
    uint256 public immutable strategyTypeId;
    uint256 public immutable defaultSlippageInBps;

    // Reference to the MamoStrategyRegistry
    IMamoStrategyRegistry public immutable mamoStrategyRegistryInterface;

    // Events
    event StrategyCreated(address indexed user, address indexed strategy);

    /**
     * @notice Constructor that initializes the factory with all required parameters
     * @param _mamoStrategyRegistry Address of the MamoStrategyRegistry contract
     * @param _mamoBackend Address of the Mamo backend
     * @param _stakingRegistry Address of the MamoStakingRegistry
     * @param _multiRewards Address of the MultiRewards contract
     * @param _mamoToken Address of the MAMO token
     * @param _strategyImplementation Address of the MamoStakingStrategy implementation
     * @param _strategyTypeId The strategy type ID
     * @param _defaultSlippageInBps The default slippage in basis points
     */
    constructor(
        address _mamoStrategyRegistry,
        address _mamoBackend,
        address _stakingRegistry,
        address _multiRewards,
        address _mamoToken,
        address _strategyImplementation,
        uint256 _strategyTypeId,
        uint256 _defaultSlippageInBps
    ) {
        require(_mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(_mamoBackend != address(0), "Invalid mamoBackend address");
        require(_stakingRegistry != address(0), "Invalid stakingRegistry address");
        require(_multiRewards != address(0), "Invalid multiRewards address");
        require(_mamoToken != address(0), "Invalid mamoToken address");
        require(_strategyImplementation != address(0), "Invalid strategyImplementation address");
        require(_strategyTypeId != 0, "Strategy type id not set");
        require(_defaultSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");

        mamoStrategyRegistry = _mamoStrategyRegistry;
        mamoBackend = _mamoBackend;
        stakingRegistry = _stakingRegistry;
        multiRewards = _multiRewards;
        mamoToken = _mamoToken;
        strategyImplementation = _strategyImplementation;
        strategyTypeId = _strategyTypeId;
        defaultSlippageInBps = _defaultSlippageInBps;

        // Initialize the MamoStrategyRegistry reference
        mamoStrategyRegistryInterface = IMamoStrategyRegistry(_mamoStrategyRegistry);

        // Validate that the implementation is whitelisted
        require(
            mamoStrategyRegistryInterface.whitelistedImplementations(_strategyImplementation),
            "Implementation not whitelisted"
        );
    }

    /**
     * @notice Computes the deterministic address for a user's strategy
     * @param user The address of the user
     * @param allowedSlippageInBps Custom slippage for this user (0 to use default)
     * @return strategy The deterministic address where the strategy will be deployed
     */
    function computeStrategyAddress(address user, uint256 allowedSlippageInBps) public view returns (address) {
        uint256 slippage = allowedSlippageInBps == 0 ? defaultSlippageInBps : allowedSlippageInBps;
        bytes32 salt = keccak256(abi.encodePacked(user, slippage));

        bytes memory bytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(strategyImplementation, ""));

        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    /**
     * @notice Computes the deterministic address for a user's strategy with default slippage
     * @param user The address of the user
     * @return strategy The deterministic address where the strategy will be deployed
     */
    function computeStrategyAddress(address user) external view returns (address) {
        return computeStrategyAddress(user, 0);
    }

    /**
     * @notice Checks if a strategy already exists for a user with given slippage
     * @param user The address of the user
     * @param allowedSlippageInBps Custom slippage for this user (0 to use default)
     * @return exists True if the strategy already exists, false otherwise
     */
    function strategyExists(address user, uint256 allowedSlippageInBps) public view returns (bool) {
        address strategyAddress = computeStrategyAddress(user, allowedSlippageInBps);
        return strategyAddress.code.length > 0;
    }

    /**
     * @notice Checks if a strategy already exists for a user with default slippage
     * @param user The address of the user
     * @return exists True if the strategy already exists, false otherwise
     */
    function strategyExists(address user) external view returns (bool) {
        return strategyExists(user, 0);
    }

    /**
     * @notice Creates a new MamoStakingStrategy for a specified user
     * @dev Only callable by accounts with the BACKEND_ROLE and the user address
     * @param user The address of the user to create the strategy for
     * @param allowedSlippageInBps Custom slippage for this user (0 to use default)
     * @return strategy The address of the newly created strategy
     */
    function createStrategyForUser(address user, uint256 allowedSlippageInBps) public returns (address strategy) {
        require(user != address(0), "Invalid user address");
        require(msg.sender == mamoBackend || msg.sender == user, "Only backend or user can create strategy");

        // Use default slippage if not specified
        uint256 slippage = allowedSlippageInBps == 0 ? defaultSlippageInBps : allowedSlippageInBps;
        require(slippage <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");

        // Check if strategy already exists
        require(!strategyExists(user, allowedSlippageInBps), "Strategy already exists");

        // Generate salt for deterministic deployment
        bytes32 salt = keccak256(abi.encodePacked(user, slippage));

        // Deploy the proxy using CREATE2 with deterministic address
        bytes memory bytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(strategyImplementation, ""));

        strategy = Create2.deploy(0, salt, bytecode);

        // Initialize the strategy with the parameters
        MamoStakingStrategy(payable(strategy)).initialize(
            MamoStakingStrategy.InitParams({
                mamoStrategyRegistry: mamoStrategyRegistry,
                stakingRegistry: stakingRegistry,
                multiRewards: multiRewards,
                mamoToken: mamoToken,
                strategyTypeId: strategyTypeId,
                owner: user,
                allowedSlippageInBps: slippage
            })
        );

        // Register the strategy with the MamoStrategyRegistry
        mamoStrategyRegistryInterface.addStrategy(user, strategy);

        emit StrategyCreated(user, strategy);

        return strategy;
    }

    /**
     * @notice Creates a new MamoStakingStrategy for a specified user with default slippage
     * @dev Only callable by accounts with the BACKEND_ROLE and the user address
     * @param user The address of the user to create the strategy for
     * @return strategy The address of the newly created strategy
     */
    function createStrategy(address user) external returns (address strategy) {
        return createStrategyForUser(user, 0);
    }
}
