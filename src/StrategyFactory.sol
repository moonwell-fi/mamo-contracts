// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "./ERC1967Proxy.sol";
import {ERC20MoonwellMorphoStrategy} from "./ERC20MoonwellMorphoStrategy.sol";
import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";

/**
 * @title StrategyFactory
 * @notice Factory contract for creating new strategy instances with configurable parameters
 * @dev Creates proxies pointing to the ERC20MoonwellMorphoStrategy implementation
 */
contract StrategyFactory {
    // @notice Total basis points used for split calculations (100%)
    uint256 public constant SPLIT_TOTAL = 10000; // 100% in basis points

    /// @notice The maximum allowed slippage in basis points
    uint256 public constant MAX_SLIPPAGE_IN_BPS = 1000; // 10% in basis points

    /// @notice The maximum allowed compound fee in basis points
    uint256 public constant MAX_COMPOUND_FEE = 1000; // 10% in basis points

    // Strategy parameters
    address public immutable mamoStrategyRegistry;
    address public immutable mamoBackend;
    address public immutable mToken;
    address public immutable metaMorphoVault;
    address public immutable token;
    address public immutable slippagePriceChecker;
    address public immutable strategyImplementation;
    address public immutable feeRecipient;
    uint256 public immutable splitMToken;
    uint256 public immutable splitVault;
    uint256 public immutable strategyTypeId;
    uint256 public immutable hookGasLimit;
    uint256 public immutable allowedSlippageInBps;
    uint256 public immutable compoundFee;
    address[] public rewardTokens;

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
     * @param _token Address of the underlying token
     * @param _slippagePriceChecker Address of the SlippagePriceChecker
     * @param _strategyImplementation Address of the strategy implementation
     * @param _splitMToken Percentage of funds allocated to Moonwell mToken in basis points
     * @param _splitVault Percentage of funds allocated to MetaMorpho Vault in basis points
     * @param _strategyTypeId The strategy type ID
     * @param _hookGasLimit The gas limit for the hook
     * @param _allowedSlippageInBps The allowed slippage in basis points
     * @param _compoundFee The compound fee in basis points
     * @param _rewardTokens Array of reward token addresses to be approved for CowSwap
     */
    constructor(
        address _mamoStrategyRegistry,
        address _mamoBackend,
        address _mToken,
        address _metaMorphoVault,
        address _token,
        address _slippagePriceChecker,
        address _strategyImplementation,
        address _feeRecipient,
        uint256 _splitMToken,
        uint256 _splitVault,
        uint256 _strategyTypeId,
        uint256 _hookGasLimit,
        uint256 _allowedSlippageInBps,
        uint256 _compoundFee,
        address[] memory _rewardTokens
    ) {
        require(_mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(_mamoBackend != address(0), "Invalid mamoBackend address");
        require(_mToken != address(0), "Invalid mToken address");
        require(_metaMorphoVault != address(0), "Invalid metaMorphoVault address");
        require(_token != address(0), "Invalid token address");
        require(_slippagePriceChecker != address(0), "Invalid slippagePriceChecker address");
        require(_strategyImplementation != address(0), "Invalid strategyImplementation address");
        require(_feeRecipient != address(0), "Invalid feeRecipient address");
        require(_splitMToken + _splitVault == SPLIT_TOTAL, "Split parameters must add up to 10000");
        require(_strategyTypeId != 0, "Strategy type id not set");
        require(_hookGasLimit > 0, "Invalid hook gas limit");
        require(_allowedSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");
        require(_compoundFee <= MAX_COMPOUND_FEE, "Compound fee exceeds maximum");

        mamoStrategyRegistry = _mamoStrategyRegistry;
        mamoBackend = _mamoBackend;
        mToken = _mToken;
        metaMorphoVault = _metaMorphoVault;
        token = _token;
        slippagePriceChecker = _slippagePriceChecker;
        strategyImplementation = _strategyImplementation;
        feeRecipient = _feeRecipient;
        splitMToken = _splitMToken;
        splitVault = _splitVault;
        strategyTypeId = _strategyTypeId;
        hookGasLimit = _hookGasLimit;
        allowedSlippageInBps = _allowedSlippageInBps;
        compoundFee = _compoundFee;

        // Store the reward tokens
        if (_rewardTokens.length > 0) {
            for (uint256 i = 0; i < _rewardTokens.length; i++) {
                rewardTokens.push(_rewardTokens[i]);
            }
        }

        // Initialize the MamoStrategyRegistry reference
        mamoStrategyRegistryInterface = IMamoStrategyRegistry(_mamoStrategyRegistry);
    }

    /**
     * @notice Creates a new strategy for a specified user
     * @dev Only callable by accounts with the BACKEND_ROLE and the user address
     * @param user The address of the user to create the strategy for
     * @return strategy The address of the newly created strategy
     */
    function createStrategyForUser(address user) external returns (address strategy) {
        require(user != address(0), "Invalid user address");
        require(msg.sender == mamoBackend || msg.sender == user, "Only backend or user can create strategy");

        // Deploy the proxy with empty initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(strategyImplementation, "");
        strategy = address(proxy);

        // Initialize the strategy with the parameters
        ERC20MoonwellMorphoStrategy(payable(strategy)).initialize(
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: mamoStrategyRegistry,
                mamoBackend: mamoBackend,
                mToken: mToken,
                metaMorphoVault: metaMorphoVault,
                token: token,
                slippagePriceChecker: slippagePriceChecker,
                feeRecipient: feeRecipient,
                splitMToken: splitMToken,
                splitVault: splitVault,
                strategyTypeId: strategyTypeId,
                rewardTokens: rewardTokens,
                owner: user,
                hookGasLimit: hookGasLimit,
                allowedSlippageInBps: allowedSlippageInBps,
                compoundFee: compoundFee
            })
        );

        // Register the strategy with the MamoStrategyRegistry
        mamoStrategyRegistryInterface.addStrategy(user, strategy);

        emit StrategyCreated(user, strategy);

        return strategy;
    }
}
