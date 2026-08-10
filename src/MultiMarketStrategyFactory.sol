// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "./ERC1967Proxy.sol";
import {MamoMultiMarketStrategy} from "./MamoMultiMarketStrategy.sol";

import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";
import {IMarketRegistry} from "./interfaces/IMarketRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title MultiMarketStrategyFactory
 * @notice Factory contract for creating new multi-market strategy instances
 * @dev Creates proxies pointing to the strategy implementation that MamoStrategyRegistry currently
 *      publishes for this strategy type, reads market definitions from MarketRegistry, and stores
 *      the default split allocation.
 *
 *      DESIGN NOTE — nothing registry-derived is frozen here. Both registries are mutable by
 *      design (markets are added/deactivated, implementations are rolled out), so pinning any of
 *      their outputs at construction turns a routine operation into a permanently bricked factory:
 *        - the implementation is resolved per creation from latestImplementationById, so an
 *          implementation rollout does not take creation offline;
 *        - the backend is resolved per call from the registry's BACKEND_ROLE, so a key rotation
 *          both revokes the retired key here and enables the new one;
 *        - market count is not required to equal the split count: splits are positional over the
 *          registry's append-only market array, and markets registered after this factory was
 *          configured simply default to a zero allocation until {setDefaultSplitBps} is called.
 */
contract MultiMarketStrategyFactory {
    uint256 public constant SPLIT_TOTAL = 10000;
    uint256 public constant MAX_SLIPPAGE_IN_BPS = 1000;
    uint256 public constant MAX_COMPOUND_FEE = 1000;

    /// @notice Role identifier for the backend, as defined by MamoStrategyRegistry
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    address public immutable mamoStrategyRegistry;
    address public immutable token;
    address public immutable slippagePriceChecker;
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
    event DefaultSplitBpsUpdated(uint256[] splitBps);

    modifier onlyBackend() {
        require(_hasBackendRole(msg.sender), "Only backend can call");
        _;
    }

    constructor(
        address _mamoStrategyRegistry,
        address _token,
        address _slippagePriceChecker,
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
        require(_token != address(0), "Invalid token address");
        require(_slippagePriceChecker != address(0), "Invalid slippagePriceChecker address");
        require(_feeRecipient != address(0), "Invalid feeRecipient address");
        require(_marketRegistry != address(0), "Invalid marketRegistry address");
        require(_strategyTypeId != 0, "Strategy type id not set");
        require(_hookGasLimit > 0, "Invalid hook gas limit");
        require(_allowedSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");
        require(_compoundFee <= MAX_COMPOUND_FEE, "Compound fee exceeds maximum");

        mamoStrategyRegistry = _mamoStrategyRegistry;
        token = _token;
        slippagePriceChecker = _slippagePriceChecker;
        marketRegistry = _marketRegistry;
        feeRecipient = _feeRecipient;
        strategyTypeId = _strategyTypeId;
        hookGasLimit = _hookGasLimit;
        allowedSlippageInBps = _allowedSlippageInBps;
        compoundFee = _compoundFee;

        _setDefaultSplitBps(_defaultSplitBps);

        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            rewardTokens.push(_rewardTokens[i]);
        }

        mamoStrategyRegistryInterface = IMamoStrategyRegistry(_mamoStrategyRegistry);
    }

    /**
     * @notice Replaces the default split allocation used for newly created strategies
     * @dev Only callable by an account holding BACKEND_ROLE on MamoStrategyRegistry. Splits are
     *      positional over the MarketRegistry's append-only market array for this token, so this
     *      is the operation that follows an addMarket / deactivateMarket: a deactivated market
     *      must be given a zero allocation here before new strategies can be created again.
     * @param newSplitBps The new split allocation, in basis points, one entry per market
     */
    function setDefaultSplitBps(uint256[] calldata newSplitBps) external onlyBackend {
        _setDefaultSplitBps(newSplitBps);
    }

    /**
     * @notice Creates a new multi-market strategy for a specified user
     * @param user The address of the user to create the strategy for
     * @return strategy The address of the newly created strategy
     */
    function createStrategyForUser(address user) external returns (address strategy) {
        require(user != address(0), "Invalid user address");
        require(msg.sender == user || _hasBackendRole(msg.sender), "Only backend or user can create strategy");

        address implementation = mamoStrategyRegistryInterface.latestImplementationById(strategyTypeId);
        require(implementation != address(0), "No implementation for strategy type");

        ERC1967Proxy proxy = new ERC1967Proxy(implementation, "");
        strategy = address(proxy);

        MamoMultiMarketStrategy(payable(strategy)).initialize(
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: mamoStrategyRegistry,
                mamoBackend: mamoStrategyRegistryInterface.getBackendAddress(),
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
                defaultSplitBps: _splitsForCurrentMarkets()
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

    /**
     * @notice Returns the implementation new strategies would currently be created with
     */
    function strategyImplementation() external view returns (address) {
        return mamoStrategyRegistryInterface.latestImplementationById(strategyTypeId);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /// @dev Pads the stored splits with zeros up to the registry's current market count. Markets
    ///      registered after this factory was configured therefore receive nothing rather than
    ///      bricking creation; the existing entries still have to total SPLIT_TOTAL.
    function _splitsForCurrentMarkets() internal view returns (uint256[] memory splits) {
        uint256 marketCount = IMarketRegistry(marketRegistry).getMarketCount(token);
        uint256 storedCount = defaultSplitBps.length;
        require(storedCount <= marketCount, "Split count exceeds market count");

        splits = new uint256[](marketCount);
        for (uint256 i = 0; i < storedCount; i++) {
            splits[i] = defaultSplitBps[i];
        }
    }

    function _setDefaultSplitBps(uint256[] memory newSplitBps) internal {
        // NOTE: deliberately not validated against the registry's market count here — the
        // deployment order registers markets AFTER the factory exists, so a constructor-time
        // check would be unsatisfiable. The relation is enforced where it matters, at creation
        // time in _splitsForCurrentMarkets.
        require(newSplitBps.length > 0, "At least one split required");

        uint256 totalSplit = 0;
        for (uint256 i = 0; i < newSplitBps.length; i++) {
            totalSplit += newSplitBps[i];
        }
        require(totalSplit == SPLIT_TOTAL, "Splits must add up to 10000");

        delete defaultSplitBps;
        for (uint256 i = 0; i < newSplitBps.length; i++) {
            defaultSplitBps.push(newSplitBps[i]);
        }

        emit DefaultSplitBpsUpdated(newSplitBps);
    }

    function _hasBackendRole(address account) internal view returns (bool) {
        return IAccessControl(mamoStrategyRegistry).hasRole(BACKEND_ROLE, account);
    }
}
