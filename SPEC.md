# Mamo Contracts Specification

This document outlines the specification for the Mamo contracts, which enable users to deploy personal strategy contracts and let Mamo manage their funds.

## Mamo Strategy Registry

This contract is responsible for tracking user strategies, deploying new strategies, and coordinating operations across strategies. It inherits from the AccessControlEnumerable and Pausable contracts from OpenZeppelin and uses the EnumerableSet library for efficient set operations. The contract is upgradeable through a UUPS (Universal Upgradeable Proxy Standard) pattern, with role-based access control.

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
- `mapping(address => uint256) public implementationToId`: Maps implementations to their strategy IDt co
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

## Interfaces

### IBaseStrategy

This interface defines the methods that a strategy contract should expose.

- `function mamoStrategyRegistry() external view returns (IMamoStrategyRegistry)`: Gets the Mamo Strategy Registry contract.

### IUUPSUpgradeable

This interface defines the methods that a UUPS (Universal Upgradeable Proxy Standard) proxy implementation should expose.

- `function upgradeToAndCall(address newImplementation, bytes memory data) external payable`: Upgrades the implementation to `newImplementation` and calls a function on the new implementation. This function is only callable through the proxy, not through the implementation.

## ERC20MoonwellMorphoStrategy

A generic implementation of a Strategy Contract for ERC20 tokens that splits deposits between Moonwell core market and Moonwell Vaults. This contract is designed to be used as an implementation for proxies.

### Storage

- `AccessControlEnumerable`: Inherits from OpenZeppelin's AccessControlEnumerable for role-based access control
- `bool private _initialized`: Flag to track if the contract has been initialized
- `bytes32 public constant BACKEND_ROLE`: Role identifier for the backend role in the registry
- `IMamoStrategyRegistry public mamoStrategyRegistry`: Reference to the Mamo Strategy Registry contract
- `IComptroller public moonwellComptroller`: The Moonwell Comptroller contract
- `IMToken public mToken`: The Moonwell mToken contract
- `IERC4626 public metaMorphoVault`: The MetaMorpho Vault contract
- `IDEXRouter public dexRouter`: The DEX router for swapping reward tokens
- `IERC20 public token`: The ERC20 token
- `uint256 public constant SPLIT_TOTAL`: The total basis points for split calculations (10,000)
- `uint256 public splitMToken`: Percentage of funds allocated to Moonwell mToken in basis points
- `uint256 public splitVault`: Percentage of funds allocated to MetaMorpho Vault in basis points
- `EnumerableSet.AddressSet private _rewardTokens`: Set of reward token addresses

### Functions

- `struct InitParams`: A struct containing all initialization parameters to avoid stack too deep errors. Includes owner, mamoStrategyRegistry, mamoBackend, admin, moonwellComptroller, mToken, metaMorphoVault, dexRouter, token, splitMToken, and splitVault.

- `modifier onlyStrategyRegistry()`: Modifier to ensure the caller is the Mamo Strategy Registry contract.

- `modifier onlyStrategyOwner()`: Modifier to ensure the caller is the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `modifier onlyBackend()`: Modifier to ensure the caller is the backend address from the Mamo Strategy Registry.

- `modifier onlyBackendOrStrategyOwner()`: Modifier to ensure the caller is either the backend address from the Mamo Strategy Registry or the user who owns this strategy.

- `function initialize(InitParams calldata params) external`: Initializer function that sets all the parameters and grants appropriate roles. This is used instead of a constructor since the contract is designed to be used with proxies. The function sets up the admin role for the specified admin address.

- `function setDexRouter(address _newDexRouter) external`: Updates the DEX router address. Only callable by the backend address from the Mamo Strategy Registry.

- `function deposit(uint256 amount) external`: Deposits funds into the strategy. Only callable by the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `function withdraw(uint256 amount) external`: Withdraws funds from the strategy. Only callable by the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `function updatePosition(uint256 splitA, uint256 splitB) external`: Updates the position in the strategy. Only callable by the backend address from the Mamo Strategy Registry.

- `function updateRewardToken(address rewardToken, bool add) external`: Updates the reward tokens set by adding or removing a token. The strategy token cannot be added as a reward token. Only callable by the backend address from the Mamo Strategy Registry.

- `function harvestRewards() external`: Harvests reward tokens by swapping them to the strategy token and depositing according to the current split. Emits a RewardsHarvested event. Callable by the backend address from the Mamo Strategy Registry or the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `function _authorizeUpgrade(address) internal view override onlyStrategyRegistry()`: Internal function that authorizes an upgrade to a new implementation. Only callable by the Mamo Strategy Registry contract. This ensures that only the Mamo Strategy Registry contract can upgrade the strategy implementation.

- `function recoverERC20(address token, address to, uint256 amount) external`: Recovers ERC20 tokens accidentally sent to this contract. Only callable by the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `function getTotalBalance() public returns (uint256)`: Gets the total balance of tokens across both protocols.

## System Flow

1. Mamo Backend deploys a strategy for a user using the latest implementation for the desired strategy type.
2. Mamo Backend calls Mamo Strategy Registry addStrategy to register the strategy for the user.
3. User deposits funds into their strategy.
4. Mamo Backend reads Deposit events and calls updateUserPosition to manage the strategy.
5. User or Mamo Backend can call claimRewards to harvest rewards from the strategy.
6. When token balance for a user strategy changes, Mamo Backend notes that and calls updateUserStrategy to rebalance the position.
7. If the user wants to move funds to a new strategy, they call withdrawFunds, and the Mamo Backend deploys a new strategy and calls addStrategy to register it, then the user deposits into the new strategy.
8. If Mamo wants to upgrade a strategy (example, deposit tokens into a new protocol) it can whitelist the new implementation and ask users to upgrade. Users can only upgrade to the latest implementation of the same strategy type.

## Security Considerations

1. Each user has their own dedicated strategy contract, eliminating the need for delegatecall and its associated security risks.
2. Implementation whitelist ensures that only trusted and audited implementations can be used.
3. Strategy implementations can be upgraded, but only to whitelisted implementations of the same strategy type, providing flexibility while maintaining security.
4. The Mamo Strategy Registry contract has proper access controls to ensure only authorized addresses can call sensitive functions.
5. Strategy contracts have clear ownership semantics, with only the user registered in the Mamo Strategy Registry able to deposit and withdraw funds, while only the backend address from the Mamo Strategy Registry can update positions.
6. The Mamo Strategy Registry contract maintains a registry of all deployed strategies, allowing for efficient coordination and verification.
