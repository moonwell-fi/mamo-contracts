## SlippagePriceChecker

This contract validates swap prices against Chainlink price feeds and applies a slippage tolerance. It implements the ISlippagePriceChecker interface and is used by MamoMultiMarketStrategy, among others, to validate the CoW Swap orders that sell its rewards. It is upgradeable through UUPS.

### Storage

- `uint256 internal constant MAX_BPS`: The maximum basis points value (10,000 = 100%)
- `uint256 internal constant INTERNAL_DECIMALS`: Quotes are carried at 36 decimals and converted to the output token's units once, at the end
- `mapping(address fromToken => mapping(address toToken => TokenFeedConfiguration[])) public tokenPairOracleData`: The oracle path for each fromToken -> toToken pair
- `mapping(address token => uint256) public maxTimePriceValid`: The longest lifetime, in seconds, of an order selling `token`; also the legacy reward-token flag
- `mapping(address fromToken => uint256) public configuredPairCount` and `mapping(address fromToken => mapping(address toToken => bool)) public pairCounted`: How many pairs are configured for a sell token, and which ones are counted; `isRewardToken` reads the count
- `address public sequencerUptimeFeed` and `uint256 public sequencerGracePeriod`: The L2 sequencer guard
- `mapping(address chainlinkFeed => FeedBounds) public feedBounds`: Optional per-feed `minAnswer`/`maxAnswer`; a zero `maxAnswer` means no bounds
- `mapping(address token => TokenFeedConfiguration[]) public tokenOracleData`: Deprecated single-token storage, kept for the storage layout

### TokenFeedConfiguration

- `address chainlinkFeed`: The address of the Chainlink price feed
- `bool reverse`: Whether to reverse the price calculation (divide instead of multiply)
- `uint256 heartbeat`: The longest time, in seconds, since the feed's last update before its answer is refused

### Functions

- `function initialize(address _owner) external initializer`: Initializes the contract with the given owner
- `function _authorizeUpgrade(address newImplementation) internal override onlyOwner`: Authorizes an upgrade, only callable by the owner
- `function checkPrice(uint256 _amountIn, address _fromToken, address _toToken, uint256 _minOut, uint256 _slippageInBps) external view returns (bool)`: Checks that a swap of a configured pair meets the price with the provided slippage
- `function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken) public view returns (uint256)`: Gets the expected output of a configured pair. Reverts while the sequencer is down or inside its grace period, on a stale feed, and on an answer outside the feed's bounds
- `function addTokenConfiguration(address fromToken, address toToken, TokenFeedConfiguration[] calldata configurations) external`: Sets the oracle path for a pair and counts the pair the first time. It does not set `maxTimePriceValid`. Only callable by the owner.
- `function removeTokenConfiguration(address fromToken, address toToken) external`: Removes the oracle path for a pair. When the sell token's last counted pair goes, it also clears `maxTimePriceValid[fromToken]`. Only callable by the owner.
- `function setMaxTimePriceValid(address fromToken, uint256 _maxTimePriceValid) external`: Sets the order lifetime for a sell token; zero clears it. Only callable by the owner.
- `function clearRewardToken(address fromToken) external`: Clears a residual `maxTimePriceValid` flag once the token has no counted pair. Only callable by the owner.
- `function backfillPairCount(address fromToken, address[] calldata toTokens) external`: Counts pairs configured before `configuredPairCount` existed. Only callable by the owner.
- `function setSequencerUptimeFeed(address _sequencerUptimeFeed, uint256 _gracePeriod) external`: Sets the sequencer guard; `address(0)` disables it. Only callable by the owner.
- `function setFeedBounds(address chainlinkFeed, uint256 minAnswer, uint256 maxAnswer) external`: Sets the accepted answer range for a feed; a zero `maxAnswer` clears it. Only callable by the owner.
- `function isRewardToken(address token) external view returns (bool)`: True when the token has a counted pair or a non-zero `maxTimePriceValid`
- `function isTokenPairConfigured(address fromToken, address toToken) external view returns (bool)`: True when the pair has an oracle path
- `function tokenPairOracleInformation(address fromToken, address toToken) external view returns (TokenFeedConfiguration[] memory)`: The oracle path for a pair

A token configured only through `addTokenConfiguration` is reported by `isRewardToken` as a reward token, but no CoW order selling it passes `GPv2OrderChecks.validate()` until `setMaxTimePriceValid` sets a lifetime of at least 5 minutes: an order must expire between 5 minutes and `maxTimePriceValid` seconds from now.

## MamoMultiMarketStrategy

A strategy contract for ERC20 tokens that splits deposits across the Moonwell markets and ERC4626 vaults listed for its token in the MarketRegistry. It is used as an implementation behind proxies, and it sells reward tokens for its token through CoW Swap orders that this price checker validates.

### Storage

- `bytes32 public constant DOMAIN_SEPARATOR`: The settlement contract's EIP-712 domain separator for Cow Swap
- `uint256 public constant SPLIT_TOTAL`: The total basis points for split calculations (10,000)
- `address public constant VAULT_RELAYER`: The Cow Protocol Vault Relayer, approved for the fee-settled reward balance only
- `IMamoStrategyRegistry public mamoStrategyRegistry`: Reference to the Mamo Strategy Registry contract
- `IERC20 public token`: The ERC20 token
- `ISlippagePriceChecker public slippagePriceChecker`: The price checker used to validate swap prices
- `IMarketRegistry public marketRegistry`: The registry listing the markets for `token`
- `mapping(address => uint256) public marketSplitBps`: Each market's share of deposits in basis points
- `uint256 public allowedSlippageInBps`: The allowed slippage in basis points (e.g., 100 = 1%) used for swap price validation
- `uint256 public compoundFee` and `address public feeRecipient`: The fee charged on reward tokens and its recipient
- `mapping(address => uint256) public rewardFeeCharged`: How much of a reward token's balance has already been charged the fee
- `IMToken public mToken`, `IERC4626 public metaMorphoVault`, `uint256 public splitMToken`, `uint256 public splitVault`: Deprecated v1 slots, kept for migration

### Functions

- `struct InitParams`: A struct containing all initialization parameters to avoid stack too deep errors. Includes mamoStrategyRegistry, token, slippagePriceChecker, feeRecipient, strategyTypeId, rewardTokens, owner, hookGasLimit, allowedSlippageInBps, compoundFee, marketRegistry and defaultSplitBps.

- `modifier onlyOwner()`: Modifier to ensure the caller is the user who owns this strategy.

- `modifier onlyBackend()`: Modifier to ensure the caller holds BACKEND_ROLE on the Mamo Strategy Registry.

# Mamo Contracts Specification

This document outlines the specification for the Mamo contracts, which enable users to deploy personal strategy contracts and let Mamo manage their funds.

## Mamo Strategy Registry

This contract is responsible for tracking user strategies, whitelisting strategy implementations, and coordinating operations across strategies. It inherits from the AccessControlEnumerable and Pausable contracts from OpenZeppelin and uses the EnumerableSet library for efficient set operations. 

The contract is initialized with three distinct roles that are passed as constructor parameters:
- `admin`: Granted the DEFAULT_ADMIN_ROLE, which can grant and revoke other roles
- `backend`: Granted the BACKEND_ROLE, which can manage strategies
- `guardian`: Granted the GUARDIAN_ROLE, which can pause and unpause the contract

### Roles

- `DEFAULT_ADMIN_ROLE`: The default admin role that can grant and revoke other roles, and is responsible for contract upgrades
- `BACKEND_ROLE`: The role that can manage strategies, deploy strategies, update user strategies, and claim rewards for users
- `GUARDIAN_ROLE`: The role that can pause and unpause the contract in case of emergencies

### Storage

- `mapping(address => EnumerableSet.AddressSet) _userStrategies`: Set of all strategy addresses for each user
- `mapping(address => bool) public whitelistedImplementations`: Mapping of whitelisted implementation addresses
- `mapping(uint256 => address) public latestImplementationById`: Maps strategy IDs to their latest implementation
- `mapping(address => uint256) public implementationToId`: Maps implementations to their strategy ID
- `uint256 private _nextStrategyTypeId`: Counter for strategy type IDs, starting from 1

### Strategy Type ID

The strategy type ID is a simple incremental uint256 value that uniquely identifies a type of strategy. Each new strategy type receives the next available ID from the counter, which starts at 1 and increments by 1 for each new strategy type.

This approach simplifies the ID system while still allowing for type-safe upgrades. Implementations of the same strategy type (e.g., different versions of a USDC strategy) will share the same ID, ensuring that users can only upgrade to the latest implementation of the same strategy type.

### Functions

- `function pause() external`: Pauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function unpause() external`: Unpauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function whitelistImplementation(address implementation, uint256 strategyTypeId) external returns (uint256 assignedStrategyTypeId)`: Adds an implementation to the whitelist and sets it as the latest implementation for its strategy type. Passing `strategyTypeId == 0` assigns a new type ID. Returns the assigned strategy type ID. **Only callable by accounts with the DEFAULT_ADMIN_ROLE — not the backend.** See `STRATEGY_REGISTRY_SPEC.md` for the authoritative description; this section is a copy kept for convenience.

- `function getImplementationId(address implementation) external view returns (uint256)`: Gets the strategy ID for an implementation.

- `function getLatestImplementation(uint256 strategyId) external view returns (address)`: Gets the latest implementation for a strategy ID.

- `function addStrategy(address user, address strategy) external`: Adds a strategy for a user. Only callable by accounts with the BACKEND_ROLE. The backend is responsible for deploying the strategy before calling this function. This function checks that the strategy has the correct registry address set up. This function is pausable.

- `function upgradeStrategy(address strategy) external`: Updates the implementation of a strategy to the latest implementation of the same type. Only callable by the user. This function calls the `upgradeToAndCall` method on the strategy contract through the `IUUPSUpgradeable` interface.

- `function getUserStrategies(address user) external view returns (address[] memory)`: Gets all strategies for a user.

- `function isUserStrategy(address user, address strategy) external view returns (bool)`: Checks if a strategy belongs to a user.

- `function getBackendAddress() external view returns (address)`: Gets the backend address (first member of the BACKEND_ROLE). **Deprecated as an authorization primitive** — index 0 changes identity as a side effect of unrelated membership edits (Sherlock #41). New code gates on `hasRole(BACKEND_ROLE, account)`; see `docs/STRATEGY_REGISTRY_SPEC.md`. It remains a live read for the already-deployed strategy proxies, which still authorize against index 0 until their owners upgrade.

## SlippagePriceChecker

See the SlippagePriceChecker section at the top of this document.
