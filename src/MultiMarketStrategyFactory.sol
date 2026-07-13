// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "./ERC1967Proxy.sol";
import {MamoMultiMarketStrategy} from "./MamoMultiMarketStrategy.sol";

import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";
import {IMarketRegistry} from "./interfaces/IMarketRegistry.sol";

/**
 * @title MultiMarketStrategyFactory
 * @notice Factory contract for creating new multi-market strategy instances
 * @dev Creates proxies pointing to the MamoMultiMarketStrategy implementation.
 *      Reads market definitions from MarketRegistry, stores default split allocations.
 */
contract MultiMarketStrategyFactory {
    uint256 public constant SPLIT_TOTAL = 10000;
    uint256 public constant MAX_SLIPPAGE_IN_BPS = 1000;
    uint256 public constant MAX_COMPOUND_FEE = 1000;

    address public immutable mamoStrategyRegistry;
    address public immutable mamoBackend;
    address public immutable token;
    address public immutable slippagePriceChecker;
    address public immutable strategyImplementation;
    address public immutable feeRecipient;
    address public immutable marketRegistry;
    uint256 public immutable strategyTypeId;
    uint256 public immutable hookGasLimit;
    uint256 public immutable allowedSlippageInBps;
    uint256 public immutable compoundFee;
    address[] public rewardTokens;
    uint256[] public defaultSplitBps;

    IMamoStrategyRegistry public immutable mamoStrategyRegistryInterface;

    event StrategyCreated(address indexed user, address indexed strategy);

    constructor(
        address _mamoStrategyRegistry,
        address _mamoBackend,
        address _token,
        address _slippagePriceChecker,
        address _strategyImplementation,
        address _feeRecipient,
        address _marketRegistry,
        uint256 _strategyTypeId,
        uint256 _hookGasLimit,
        uint256 _allowedSlippageInBps,
        uint256 _compoundFee,
        address[] memory _rewardTokens,
        uint256[] memory _defaultSplitBps
    ) {
        require(_mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(_mamoBackend != address(0), "Invalid mamoBackend address");
        require(_token != address(0), "Invalid token address");
        require(_slippagePriceChecker != address(0), "Invalid slippagePriceChecker address");
        require(_strategyImplementation != address(0), "Invalid strategyImplementation address");
        require(_feeRecipient != address(0), "Invalid feeRecipient address");
        require(_marketRegistry != address(0), "Invalid marketRegistry address");
        require(_strategyTypeId != 0, "Strategy type id not set");
        require(_hookGasLimit > 0, "Invalid hook gas limit");
        require(_allowedSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");
        require(_compoundFee <= MAX_COMPOUND_FEE, "Compound fee exceeds maximum");
        require(_defaultSplitBps.length > 0, "At least one split required");

        // Validate splits sum to SPLIT_TOTAL
        uint256 totalSplit = 0;
        for (uint256 i = 0; i < _defaultSplitBps.length; i++) {
            totalSplit += _defaultSplitBps[i];
            defaultSplitBps.push(_defaultSplitBps[i]);
        }
        require(totalSplit == SPLIT_TOTAL, "Splits must add up to 10000");

        mamoStrategyRegistry = _mamoStrategyRegistry;
        mamoBackend = _mamoBackend;
        token = _token;
        slippagePriceChecker = _slippagePriceChecker;
        strategyImplementation = _strategyImplementation;
        feeRecipient = _feeRecipient;
        marketRegistry = _marketRegistry;
        strategyTypeId = _strategyTypeId;
        hookGasLimit = _hookGasLimit;
        allowedSlippageInBps = _allowedSlippageInBps;
        compoundFee = _compoundFee;

        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            rewardTokens.push(_rewardTokens[i]);
        }

        mamoStrategyRegistryInterface = IMamoStrategyRegistry(_mamoStrategyRegistry);
    }

    /**
     * @notice Creates a new multi-market strategy for a specified user
     * @param user The address of the user to create the strategy for
     * @return strategy The address of the newly created strategy
     */
    function createStrategyForUser(address user) external returns (address strategy) {
        require(user != address(0), "Invalid user address");
        require(msg.sender == mamoBackend || msg.sender == user, "Only backend or user can create strategy");
        require(
            IMarketRegistry(marketRegistry).getMarketCount(token) == defaultSplitBps.length,
            "Split count must match market count"
        );

        ERC1967Proxy proxy = new ERC1967Proxy(strategyImplementation, "");
        strategy = address(proxy);

        MamoMultiMarketStrategy(payable(strategy)).initialize(
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: mamoStrategyRegistry,
                mamoBackend: mamoBackend,
                token: token,
                slippagePriceChecker: slippagePriceChecker,
                feeRecipient: feeRecipient,
                strategyTypeId: strategyTypeId,
                rewardTokens: rewardTokens,
                owner: user,
                hookGasLimit: hookGasLimit,
                allowedSlippageInBps: allowedSlippageInBps,
                compoundFee: compoundFee,
                marketRegistry: marketRegistry,
                defaultSplitBps: defaultSplitBps
            })
        );

        mamoStrategyRegistryInterface.addStrategy(user, strategy);

        emit StrategyCreated(user, strategy);

        return strategy;
    }

    /**
     * @notice Returns the default split configuration
     */
    function getDefaultSplitBps() external view returns (uint256[] memory) {
        return defaultSplitBps;
    }
}
