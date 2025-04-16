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

- `function whitelistImplementation(address implementation) external returns (uint256 strategyTypeId)`: Adds an implementation to the whitelist with a new strategy type ID and sets it as the latest implementation for that type. Returns the assigned strategy type ID. Only callable by accounts with the BACKEND_ROLE.

- `function getImplementationId(address implementation) external view returns (uint256)`: Gets the strategy ID for an implementation.

- `function getLatestImplementation(uint256 strategyId) external view returns (address)`: Gets the latest implementation for a strategy ID.

- `function addStrategy(address user, address strategy) external`: Adds a strategy for a user. Only callable by accounts with the BACKEND_ROLE. The backend is responsible for deploying the strategy before calling this function. This function checks that the strategy has the correct registry address set up. This function is pausable.

- `function upgradeStrategy(address strategy) external`: Updates the implementation of a strategy to the latest implementation of the same type. Only callable by the user. This function calls the `upgradeToAndCall` method on the strategy contract through the `IUUPSUpgradeable` interface.

- `function getUserStrategies(address user) external view returns (address[] memory)`: Gets all strategies for a user.

- `function isUserStrategy(address user, address strategy) external view returns (bool)`: Checks if a strategy belongs to a user.

- `function getBackendAddress() external view returns (address)`: Gets the backend address (first member of the BACKEND_ROLE).

## SlippagePriceChecker

This contract is responsible for validating swap prices using Chainlink price feeds and applying slippage tolerance. It implements the ISlippagePriceChecker interface and is used by the ERC20MoonwellMorphoStrategy contract to validate swap prices for CowSwap orders. The contract is upgradeable using the UUPS (Universal Upgradeable Proxy Standard) pattern.

### Storage

- `uint256 internal constant MAX_BPS`: The maximum basis points value (10,000 = 100%)
- `mapping(address token => TokenFeedConfiguration[]) public tokenOracleData`: Maps token addresses to their oracle configurations

### TokenFeedConfiguration

- `address chainlinkFeed`: The address of the Chainlink price feed
- `bool reverse`: Whether to reverse the price calculation (divide instead of multiply)

### Functions

- `function initialize(address _owner) external initializer`: Initializes the contract with the given owner
- `function _authorizeUpgrade(address newImplementation) internal override onlyOwner`: Function that authorizes an upgrade to a new implementation, only callable by the owner
- `function checkPrice(uint256 _amountIn, address _fromToken, address _toToken, uint256 _minOut, uint256 _slippageInBps) external view returns (bool)`: Checks if a swap meets the price requirements with the provided slippage
- `function addTokenConfiguration(address token, TokenFeedConfiguration[] calldata configurations, uint256 maxTimePriceValid) external`: Adds a configuration for a token with price checker data and sets the maximum time a price is considered valid. Only callable by the owner.
- `function removeTokenConfiguration(address token) external`: Removes all configurations for a token. Only callable by the owner.
- `function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken) public view returns (uint256)`: Gets the expected output amount for a swap
- `function maxTimePriceValid(address token) external view returns (uint256)`: Gets the maximum time a price is considered valid for a token.

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

- `function whitelistImplementation(address implementation) external returns (uint256 strategyTypeId)`: Adds an implementation to the whitelist with a new strategy type ID and sets it as the latest implementation for that type. Returns the assigned strategy type ID. Only callable by accounts with the BACKEND_ROLE.

- `function getImplementationId(address implementation) external view returns (uint256)`: Gets the strategy ID for an implementation.

- `function getLatestImplementation(uint256 strategyId) external view returns (address)`: Gets the latest implementation for a strategy ID.

- `function addStrategy(address user, address strategy) external`: Adds a strategy for a user. Only callable by accounts with the BACKEND_ROLE. The backend is responsible for deploying the strategy before calling this function. This function checks that the strategy has the correct registry address set up. This function is pausable.

- `function upgradeStrategy(address strategy) external`: Updates the implementation of a strategy to the latest implementation of the same type. Only callable by the user. This function calls the `upgradeToAndCall` method on the strategy contract through the `IUUPSUpgradeable` interface.

- `function getUserStrategies(address user) external view returns (address[] memory)`: Gets all strategies for a user.

- `function isUserStrategy(address user, address strategy) external view returns (bool)`: Checks if a strategy belongs to a user.

- `function getBackendAddress() external view returns (address)`: Gets the backend address (first member of the BACKEND_ROLE).
