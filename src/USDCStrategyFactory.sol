// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "./ERC1967Proxy.sol";
import {ERC20MoonwellMorphoStrategy} from "./ERC20MoonwellMorphoStrategy.sol";
import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";

/**
 * @title USDCStrategyFactory
 * @notice Factory contract for creating new USDC strategy instances with configurable parameters
 * @dev Creates proxies pointing to the ERC20MoonwellMorphoStrategy implementation
 */
contract USDCStrategyFactory {
    // Strategy parameters
    address public immutable mamoStrategyRegistry;
    address public immutable mamoBackend;
    address public immutable mToken;
    address public immutable metaMorphoVault;
    address public immutable token;
    address public immutable slippagePriceChecker;
    address public immutable strategyImplementation;
    uint256 public immutable splitMToken;
    uint256 public immutable splitVault;
    uint256 public immutable strategyTypeId;

    // Reference to the MamoStrategyRegistry
    IMamoStrategyRegistry public immutable mamoStrategyRegistryInterface;

    // Events
    event StrategyCreated(address indexed user, address indexed strategy);

    /**
     * @notice Constructor that initializes the factory with all required parameters
     * @param _mamoStrategyRegistry Address of the MamoStrategyRegistry contract
     * @param _mamoBackend Address of the Mamo backend
     * @param _mToken Address of the Moonwell mToken
     * @param _metaMorphoVault Address of the MetaMorpho Vault
     * @param _token Address of the underlying token (USDC)
     * @param _slippagePriceChecker Address of the SlippagePriceChecker
     * @param _strategyImplementation Address of the strategy implementation
     * @param _splitMToken Percentage of funds allocated to Moonwell mToken in basis points
     * @param _splitVault Percentage of funds allocated to MetaMorpho Vault in basis points
     * @param _strategyTypeId The strategy type ID
     */
    constructor(
        address _mamoStrategyRegistry,
        address _mamoBackend,
        address _mToken,
        address _metaMorphoVault,
        address _token,
        address _slippagePriceChecker,
        address _strategyImplementation,
        uint256 _splitMToken,
        uint256 _splitVault,
        uint256 _strategyTypeId
    ) {
        require(_mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(_mamoBackend != address(0), "Invalid mamoBackend address");
        require(_mToken != address(0), "Invalid mToken address");
        require(_metaMorphoVault != address(0), "Invalid metaMorphoVault address");
        require(_token != address(0), "Invalid token address");
        require(_slippagePriceChecker != address(0), "Invalid slippagePriceChecker address");
        require(_strategyImplementation != address(0), "Invalid strategyImplementation address");
        require(_splitMToken + _splitVault == 10000, "Split parameters must add up to 10000");
        require(_strategyTypeId != 0, "Strategy type id not set");

        mamoStrategyRegistry = _mamoStrategyRegistry;
        mamoBackend = _mamoBackend;
        mToken = _mToken;
        metaMorphoVault = _metaMorphoVault;
        token = _token;
        slippagePriceChecker = _slippagePriceChecker;
        strategyImplementation = _strategyImplementation;
        splitMToken = _splitMToken;
        splitVault = _splitVault;
        strategyTypeId = _strategyTypeId;

        // Initialize the MamoStrategyRegistry reference
        mamoStrategyRegistryInterface = IMamoStrategyRegistry(_mamoStrategyRegistry);

        // Validate that the implementation is whitelisted
        require(
            mamoStrategyRegistryInterface.whitelistedImplementations(_strategyImplementation),
            "Implementation not whitelisted"
        );
    }

    /**
     * @notice Creates a new USDC strategy for a specified user
     * @dev Only callable by accounts with the BACKEND_ROLE in the MamoStrategyRegistry
     * @param user The address of the user to create the strategy for
     * @return strategy The address of the newly created strategy
     */
    function createStrategyForUser(address user) external returns (address strategy) {
        // Encode the initialization data with the parameters
        bytes memory initData = abi.encodeWithSelector(
            ERC20MoonwellMorphoStrategy.initialize.selector,
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: mamoStrategyRegistry,
                mamoBackend: mamoBackend,
                mToken: mToken,
                metaMorphoVault: metaMorphoVault,
                token: token,
                slippagePriceChecker: slippagePriceChecker,
                splitMToken: splitMToken,
                splitVault: splitVault,
                strategyTypeId: strategyTypeId
            })
        );

        // Deploy the proxy with the implementation and initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(strategyImplementation, initData);
        strategy = address(proxy);

        emit StrategyCreated(user, strategy);

        return strategy;
    }
}
