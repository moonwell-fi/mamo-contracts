## Mamo Strategy Registry

This contract is responsible for tracking user strategies, whitelisting strategy implementations, and coordinating operations across strategies. It inherits from the AccessControlEnumerable and Pausable contracts from OpenZeppelin and uses the EnumerableSet library for efficient set operations. 

The contract is initialized with three distinct roles that are passed as constructor parameters:
- `admin`: Granted the DEFAULT_ADMIN_ROLE, which can grant and revoke other roles
- `backend`: Granted the BACKEND_ROLE, which can manage strategies
- `guardian`: Granted the GUARDIAN_ROLE, which can pause and unpause the contract

### Roles

- `DEFAULT_ADMIN_ROLE`: The default admin role (multisig + timelock). Grants and revokes other roles, whitelists strategy implementations, and recovers stray ERC20s
- `BACKEND_ROLE`: The role that registers deployed strategies for users (`addStrategy`). It cannot whitelist implementations and cannot upgrade a user's strategy
- `GUARDIAN_ROLE`: The role that can pause and unpause the contract in case of emergencies

### Storage

- `mapping(address => EnumerableSet.AddressSet) _userStrategies`: Set of all strategy addresses for each user
- `mapping(address => bool) public whitelistedImplementations`: Mapping of whitelisted implementation addresses
- `mapping(uint256 => address) public latestImplementationById`: Maps strategy IDs to their latest implementation
- `mapping(address => uint256) public implementationToId`: Maps implementations to their strategy ID
- `uint256 public nextStrategyTypeId`: Counter for strategy type IDs, starting from 1

### Strategy Type ID

The strategy type ID is a simple incremental uint256 value that uniquely identifies a type of strategy. Each new strategy type receives the next available ID from the counter, which starts at 1 and increments by 1 for each new strategy type.

This approach simplifies the ID system while still allowing for type-safe upgrades. Implementations of the same strategy type (e.g., different versions of a USDC strategy) will share the same ID, ensuring that users can only upgrade to the latest implementation of the same strategy type.

### Functions

- `function pause() external`: Pauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function unpause() external`: Unpauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function whitelistImplementation(address implementation, uint256 strategyTypeId) external returns (uint256 assignedStrategyTypeId)`: Adds an implementation to the whitelist and sets it as the latest implementation for its strategy type. Passing `strategyTypeId == 0` assigns a new type ID from `nextStrategyTypeId`. Passing a non-zero value uses that id verbatim — the intent is to add another implementation version to an existing type, but **the contract does not check that the id exists**, and it does not advance `nextStrategyTypeId`. Passing an id that no strategy uses silently creates an orphan type reachable by nobody, and passing an id at or above `nextStrategyTypeId` can later collide with an auto-assigned one (see the warning in `script/DeployLeveragedAeroAccountConfig.sol`). The caller is responsible for passing an id that is already in use. Returns the assigned strategy type ID. **Only callable by accounts with the DEFAULT_ADMIN_ROLE — not the backend.**

  Whitelisting is the trust root of the entire upgrade path: `upgradeStrategy` will only move a user's proxy to `latestImplementationById[strategyTypeId]`, so whoever can whitelist can decide what code every strategy of that type eventually runs. It therefore sits behind the admin multisig with a timelock, and the operational flow is:

  1. The new implementation is deployed and reviewed.
  2. The admin multisig queues a `whitelistImplementation(implementation, strategyTypeId)` call in the timelock. The delay is the window in which users and the guardian can react — including pausing the registry, which blocks `upgradeStrategy` and `addStrategy`.
  3. After the delay the call is executed, making the implementation the latest for its type.
  4. Each user then opts in individually by calling `upgradeStrategy` on their own strategy. Nothing upgrades a user's strategy on their behalf.

  The backend (BACKEND_ROLE) can register strategies for users via `addStrategy`, but it can neither whitelist an implementation nor upgrade a user's strategy.

- `function getImplementationId(address implementation) external view returns (uint256)`: Gets the strategy ID for an implementation.

- `function getLatestImplementation(uint256 strategyId) external view returns (address)`: Gets the latest implementation for a strategy ID.

- `function addStrategy(address user, address strategy) external`: Adds a strategy for a user. Only callable by accounts with the BACKEND_ROLE. The backend is responsible for deploying the strategy before calling this function. This function checks that the strategy has the correct registry address set up. This function is pausable.

- `function upgradeStrategy(address strategy, address newImplementation) external`: Updates the implementation of a strategy to the latest implementation of the same type. `newImplementation` must equal `latestImplementationById[implementationToId[currentImplementation]]`, so the second argument is an explicit confirmation of what the caller expects to upgrade to, not a free choice. Only callable by the strategy's owner. This function calls the `upgradeToAndCall` method on the strategy contract through the `IUUPSUpgradeable` interface. This function is pausable.

- `function getUserStrategies(address user) external view returns (address[] memory)`: Gets all strategies for a user.

- `function isUserStrategy(address user, address strategy) external view returns (bool)`: Checks if a strategy belongs to a user.

- `function getBackendAddress() external view returns (address)`: Gets the backend address (first member of the BACKEND_ROLE).

## SlippagePriceChecker

This contract is responsible for validating swap prices using Chainlink price feeds and applying slippage tolerance. It implements the ISlippagePriceChecker interface and is used by the ERC20MoonwellMorphoStrategy contract to validate swap prices for CowSwap orders. The contract is upgradeable using the UUPS (Universal Upgradeable Proxy Standard) pattern.

### Storage

- `uint256 internal constant MAX_BPS`: The maximum basis points value (10,000 = 100%)
- `mapping(address fromToken => mapping(address toToken => TokenFeedConfiguration[])) public tokenPairOracleData`: Maps each `fromToken -> toToken` pair to its oracle path
- `mapping(address token => uint256) public maxTimePriceValid`: Per-`fromToken` price validity window, also the legacy reward-token flag
- `mapping(address fromToken => uint256) public configuredPairCount`: How many configured pairs a token has
- `mapping(address fromToken => mapping(address toToken => bool)) public pairCounted`: Whether a pair is already represented in `configuredPairCount`

### TokenFeedConfiguration

- `address chainlinkFeed`: The address of the Chainlink price feed
- `bool reverse`: Whether to reverse the price calculation (divide instead of multiply)
- `uint256 heartbeat`: Maximum age accepted for that feed's answer

### Functions

- `function initialize(address _owner) external initializer`: Initializes the contract with the given owner
- `function _authorizeUpgrade(address newImplementation) internal override onlyOwner`: Function that authorizes an upgrade to a new implementation, only callable by the owner
- `function checkPrice(uint256 _amountIn, address _fromToken, address _toToken, uint256 _minOut, uint256 _slippageInBps) external view returns (bool)`: Checks if a swap meets the price requirements with the provided slippage
- `function addTokenConfiguration(address fromToken, address toToken, TokenFeedConfiguration[] calldata configurations) external`: Configures the oracle path for a single `fromToken -> toToken` pair. Only callable by the owner. Does NOT write `maxTimePriceValid` — that is a separate, per-`fromToken` setting.
- `function removeTokenConfiguration(address fromToken, address toToken) external`: Removes the configuration for one pair. Only callable by the owner. When it removes the last counted pair for `fromToken` it also clears that token's `maxTimePriceValid`.
- `function setMaxTimePriceValid(address fromToken, uint256 maxTimePriceValid) external`: Sets, or with zero clears, how long a price stays valid for `fromToken`. Only callable by the owner. **This value also bounds an order's lifetime, and the sequencer-outage protection only closes its replay window while this is no greater than the sequencer grace period.**
- `function setSequencerUptimeFeed(address feed, uint256 gracePeriod) external`: Points the checker at a Chainlink L2 sequencer uptime feed and sets how long after recovery quotes stay refused. Only callable by the owner. While `feed` is unset the check is a no-op.
- `function backfillPairCount(address fromToken, address[] calldata toTokens) external`: Registers pairs configured before `configuredPairCount` existed into that counter. Note the shape — ONE `fromToken` against many `toTokens` per call, so backfilling several source tokens is one call each. Only callable by the owner, and idempotent. Required because the nested pair mapping cannot be enumerated on chain.
- `function configuredPairCount(address fromToken) external view returns (uint256)`: How many configured pairs a token has. Together with the legacy `maxTimePriceValid` flag this is what `isRewardToken` answers from.
- `function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken) public view returns (uint256)`: Gets the expected output amount for a swap
- `function maxTimePriceValid(address token) external view returns (uint256)`: Gets the maximum time a price is considered valid for a token.
- `function isRewardToken(address token) external view returns (bool)`: Whether the token has at least one configured pair, or a non-zero legacy `maxTimePriceValid`.
- `function isTokenPairConfigured(address fromToken, address toToken) external view returns (bool)`: Whether that pair has oracle data. Configured is not the same as settleable — an order also needs a non-zero `maxTimePriceValid` for `fromToken`.

## ERC20MoonwellMorphoStrategy

A generic implementation of a Strategy Contract for ERC20 tokens that splits deposits between Moonwell core market and Morpho Vaults. This contract is designed to be used as an implementation for proxies.

### Storage


- `bytes32 public constant DOMAIN_SEPARATOR`: The settlement contract's EIP-712 domain separator for Cow Swap
- `uint256 public constant SPLIT_TOTAL`: The total basis points for split calculations (10,000)
- `IMamoStrategyRegistry public mamoStrategyRegistry`: Reference to the Mamo Strategy Registry contract
- `IMToken public mToken`: The Moonwell mToken contract
- `IERC4626 public metaMorphoVault`: The MetaMorpho Vault contract
- `IERC20 public token`: The ERC20 token
- `ISlippagePriceChecker public SlippagePriceChecker`: Reference to the swap checker contract used to validate swap prices
- `address public vaultRelayer`: The address of the Cow Protocol Vault Relayer contract that needs token approval for executing trades
- `uint256 public splitMToken`: Percentage of funds allocated to Moonwell mToken in basis points
- `uint256 public splitVault`: Percentage of funds allocated to MetaMorpho Vault in basis points
- `uint256 public allowedSlippageInBps`: The allowed slippage in basis points (e.g., 100 = 1%) used for swap price validation

### Functions

- `struct InitParams`: A struct containing all initialization parameters to avoid stack too deep errors. Includes mamoStrategyRegistry, mamoBackend, mToken, metaMorphoVault, token, SlippagePriceChecker, vaultRelayer, splitMToken, and splitVault.

- `modifier onlyStrategyRegistry()`: Modifier to ensure the caller is the Mamo Strategy Registry contract.

- `modifier onlyStrategyOwner()`: Modifier to ensure the caller is the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `modifier onlyBackend()`: Modifier to ensure the caller is the backend address from the Mamo Strategy Registry.

- `modifier onlyBackendOrStrategyOwner()`: Modifier to ensure the caller is either the backend address from the Mamo Strategy Registry or the user who owns this strategy.

- `function initialize(InitParams calldata params) external`: Initializer function that sets all the parameters and grants appropriate roles. This is used instead of a constructor since the contract is designed to be used with proxies. The function sets up the admin role for the specified admin address. Only the backend address specified in params can call this function, providing protection against unauthorized initialization.

# Mamo Contracts Specification

This document outlines the specification for the Mamo contracts, which enable users to deploy personal strategy contracts and let Mamo manage their funds.

## Mamo Strategy Registry

This contract is responsible for tracking user strategies, whitelisting strategy implementations, and coordinating operations across strategies. It inherits from the AccessControlEnumerable and Pausable contracts from OpenZeppelin and uses the EnumerableSet library for efficient set operations. 

The contract is initialized with three distinct roles that are passed as constructor parameters:
- `admin`: Granted the DEFAULT_ADMIN_ROLE, which can grant and revoke other roles
- `backend`: Granted the BACKEND_ROLE, which can manage strategies
- `guardian`: Granted the GUARDIAN_ROLE, which can pause and unpause the contract

### Roles

- `DEFAULT_ADMIN_ROLE`: The default admin role (multisig + timelock). Grants and revokes other roles, whitelists strategy implementations, and recovers stray ERC20s
- `BACKEND_ROLE`: The role that registers deployed strategies for users (`addStrategy`). It cannot whitelist implementations and cannot upgrade a user's strategy
- `GUARDIAN_ROLE`: The role that can pause and unpause the contract in case of emergencies

### Storage

- `mapping(address => EnumerableSet.AddressSet) _userStrategies`: Set of all strategy addresses for each user
- `mapping(address => bool) public whitelistedImplementations`: Mapping of whitelisted implementation addresses
- `mapping(uint256 => address) public latestImplementationById`: Maps strategy IDs to their latest implementation
- `mapping(address => uint256) public implementationToId`: Maps implementations to their strategy ID
- `uint256 public nextStrategyTypeId`: Counter for strategy type IDs, starting from 1

### Strategy Type ID

The strategy type ID is a simple incremental uint256 value that uniquely identifies a type of strategy. Each new strategy type receives the next available ID from the counter, which starts at 1 and increments by 1 for each new strategy type.

This approach simplifies the ID system while still allowing for type-safe upgrades. Implementations of the same strategy type (e.g., different versions of a USDC strategy) will share the same ID, ensuring that users can only upgrade to the latest implementation of the same strategy type.

### Functions

- `function pause() external`: Pauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function unpause() external`: Unpauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function whitelistImplementation(address implementation, uint256 strategyTypeId) external returns (uint256 assignedStrategyTypeId)`: Adds an implementation to the whitelist and sets it as the latest implementation for its strategy type. Passing `strategyTypeId == 0` assigns a new type ID from `nextStrategyTypeId`. Passing a non-zero value uses that id verbatim — the intent is to add another implementation version to an existing type, but **the contract does not check that the id exists**, and it does not advance `nextStrategyTypeId`. Passing an id that no strategy uses silently creates an orphan type reachable by nobody, and passing an id at or above `nextStrategyTypeId` can later collide with an auto-assigned one (see the warning in `script/DeployLeveragedAeroAccountConfig.sol`). The caller is responsible for passing an id that is already in use. Returns the assigned strategy type ID. **Only callable by accounts with the DEFAULT_ADMIN_ROLE — not the backend.**

  Whitelisting is the trust root of the entire upgrade path: `upgradeStrategy` will only move a user's proxy to `latestImplementationById[strategyTypeId]`, so whoever can whitelist can decide what code every strategy of that type eventually runs. It therefore sits behind the admin multisig with a timelock, and the operational flow is:

  1. The new implementation is deployed and reviewed.
  2. The admin multisig queues a `whitelistImplementation(implementation, strategyTypeId)` call in the timelock. The delay is the window in which users and the guardian can react — including pausing the registry, which blocks `upgradeStrategy` and `addStrategy`.
  3. After the delay the call is executed, making the implementation the latest for its type.
  4. Each user then opts in individually by calling `upgradeStrategy` on their own strategy. Nothing upgrades a user's strategy on their behalf.

  The backend (BACKEND_ROLE) can register strategies for users via `addStrategy`, but it can neither whitelist an implementation nor upgrade a user's strategy.

- `function getImplementationId(address implementation) external view returns (uint256)`: Gets the strategy ID for an implementation.

- `function getLatestImplementation(uint256 strategyId) external view returns (address)`: Gets the latest implementation for a strategy ID.

- `function addStrategy(address user, address strategy) external`: Adds a strategy for a user. Only callable by accounts with the BACKEND_ROLE. The backend is responsible for deploying the strategy before calling this function. This function checks that the strategy has the correct registry address set up. This function is pausable.

- `function upgradeStrategy(address strategy, address newImplementation) external`: Updates the implementation of a strategy to the latest implementation of the same type. `newImplementation` must equal `latestImplementationById[implementationToId[currentImplementation]]`, so the second argument is an explicit confirmation of what the caller expects to upgrade to, not a free choice. Only callable by the strategy's owner. This function calls the `upgradeToAndCall` method on the strategy contract through the `IUUPSUpgradeable` interface. This function is pausable.

- `function getUserStrategies(address user) external view returns (address[] memory)`: Gets all strategies for a user.

- `function isUserStrategy(address user, address strategy) external view returns (bool)`: Checks if a strategy belongs to a user.

- `function getBackendAddress() external view returns (address)`: Gets the backend address (first member of the BACKEND_ROLE).
