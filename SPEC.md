# Mamo Contracts Specification

This document outlines the specification for the Mamo contracts, which enable users to deploy personal strategy contracts and let Mamo manage their funds.

## Mamo Strategy Registry

This contract is responsible for tracking user strategies, deploying new strategies, and coordinating operations across strategies. It inherits from the AccessControlEnumerable and Pausable contracts from OpenZeppelin and uses the EnumerableSet library for efficient set operations. The contract is upgradeable through a UUPS (Universal Upgradeable Proxy Standard) pattern, with role-based access control.

### Roles

- `DEFAULT_ADMIN_ROLE`: The default admin role that can grant and revoke other roles, and is responsible for contract upgrades
- `BACKEND_ROLE`: The role that can manage strategies, deploy strategies, update user strategies, and claim rewards for users
- `GUARDIAN_ROLE`: The role that can pause and unpause the contract in case of emergencies

### Storage

- `mapping(address => EnumerableSet.AddressSet) _userStrategies`: Set of all strategy addresses for each user
- `mapping(address => bool) public whitelistedImplementations`: Mapping of whitelisted implementation addresses
- `mapping(bytes32 => address) public latestImplementationByType`: Maps strategy types to their latest implementation
- `mapping(address => bytes32) public implementationToStrategyType`: Maps implementations to their strategy type

### Strategy Type ID

The strategy type ID is a bytes32 value that uniquely identifies a type of strategy based on the tokens it interacts with. It is structured as follows:

1. The first element contains the number of addresses in the array
2. The subsequent elements contain the actual token addresses

This structure allows for easy decoding of the strategy type ID, as the first element indicates exactly how many addresses need to be extracted.

Examples:
- USDC strategy that interacts with USDC, mUSDC, and mxUSDC: `abi.encodePacked(uint8(3), usdc, musdc, mxusdc)`
- LP strategy that interacts with WETH, USDC, and Aerodrome LP: `abi.encodePacked(uint8(3), weth, usdc, lpAero)`
- Simple USDC strategy that interacts with USDC and mUSDC: `abi.encodePacked(uint8(2), usdc, musdc)`

This approach ensures that strategies with the same token interactions are grouped together, allowing for type-safe upgrades while maintaining flexibility and easy decoding.

### Functions

- `function pause() external`: Pauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function unpause() external`: Unpauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function whitelistImplementation(address implementation, bytes32 strategyTypeId) external`: Adds an implementation to the whitelist with its strategy type and sets it as the latest implementation for that type. Only callable by accounts with the BACKEND_ROLE.

- `function getImplementationType(address implementation) external view returns (bytes32)`: Gets the strategy type for a implementation.

- `function getLatestImplementation(bytes32 strategyType) external view returns (address)`: Gets the latest implementation for a strategy type.

- `function addStrategy(address user, address strategy) external`: Adds a strategy for a user. Only callable by accounts with the BACKEND_ROLE. The backend is responsible for deploying the strategy before calling this function. This function is pausable.

- `function upgradeStrategy(address strategy, address newImplementation) external`: Updates the implementation of a strategy. Only callable by the user. The new implementation must be whitelisted and of the same strategy type as the current implementation.

- `function getUserStrategies(address user) external view returns (address[] memory)`: Gets all strategies for a user.

- `function isUserStrategy(address user, address strategy) external view returns (bool)`: Checks if a strategy belongs to a user.

## USDC Strategy

A specific implementation of a Strategy Contract for USDC that splits deposits between Moonwell core market and Moonwell Vaults. This contract is designed to be used as an implementation for proxies.

### Storage

- `AccessControlEnumerable`: Inherits from OpenZeppelin's AccessControlEnumerable for role-based access control
- `bytes32 public constant OWNER_ROLE`: Role for the strategy owner (the user)
- `bytes32 public constant UPGRADER_ROLE`: Role for the Mamo Strategy Registry contract that can upgrade the strategy
- `bytes32 public constant BACKEND_ROLE`: Role for the Mamo Backend that can update positions
- `IMamoStrategyRegistry public mamoStrategyRegistry`: Reference to the Mamo Strategy Registry contract
- `IComptroller public moonwellComptroller`: The Moonwell Comptroller contract
- `IMToken public moonwellUSDC`: The Moonwell USDC mToken contract
- `IERC4626 public metaMorphoVault`: The MetaMorpho Vault contract
- `IDEXRouter public dexRouter`: The DEX router for swapping reward tokens
- `IERC20 public usdc`: The USDC token
- `uint256 public constant SPLIT_TOTAL`: The total basis points for split calculations (10,000)
- `uint256 public splitMToken`: Percentage of funds allocated to Moonwell mToken in basis points
- `uint256 public splitVault`: Percentage of funds allocated to MetaMorpho Vault in basis points
- `EnumerableSet.AddressSet private _rewardTokens`: Set of reward token addresses

### Functions

- `struct InitParams`: A struct containing all initialization parameters to avoid stack too deep errors.

- `function initialize(InitParams calldata params) external`: Initializer function that sets all the parameters and grants appropriate roles. This is used instead of a constructor since the contract is designed to be used with proxies.

- `function setDexRouter(address _newDexRouter) external onlyRole(BACKEND_ROLE)`: Updates the DEX router address. Only callable by accounts with the BACKEND_ROLE.

- `function deposit(uint256 amount) external onlyRole(OWNER_ROLE)`: Deposits funds into the strategy. Only callable by accounts with the OWNER_ROLE.

- `function withdraw(uint256 amount) external onlyRole(OWNER_ROLE)`: Withdraws funds from the strategy. Only callable by accounts with the OWNER_ROLE.

- `function updatePosition(uint256 splitA, uint256 splitB) external onlyRole(BACKEND_ROLE)`: Updates the position in the strategy. Only callable by accounts with the BACKEND_ROLE.

- `function updateRewardToken(address token, bool add) external onlyRole(BACKEND_ROLE)`: Updates the reward tokens set by adding or removing a token. USDC cannot be added as a reward token. Only callable by accounts with the BACKEND_ROLE.

- `function harvestRewards() external onlyRole(BACKEND_ROLE)`: Harvests reward tokens by swapping them to USDC and depositing according to the current split. Emits a RewardsHarvested event. Only callable by accounts with the BACKEND_ROLE.

- `function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE)`: Internal function that authorizes an upgrade to a new implementation. Only callable by accounts with the UPGRADER_ROLE (Mamo Strategy Registry). This ensures that only the Mamo Strategy Registry contract can upgrade the strategy implementation.

- `function recoverERC20(address token, address to, uint256 amount) external onlyRole(OWNER_ROLE)`: Recovers ERC20 tokens accidentally sent to this contract. Only callable by the OWNER_ROLE.

- `function getTotalBalance() public returns (uint256)`: Gets the total balance of USDC across both protocols.

## System Flow

1. Mamo Backend deploys a strategy for a user using the latest implementation for the desired strategy type.
2. Mamo Backend calls Mamo Strategy Registry addStrategy to register the strategy for the user.
3. User deposits funds into their strategy.
4. Mamo Backend reads Deposit events and calls updateUserPosition to manage the strategy.
5. User or Mamo Backend can call claimRewards to harvest rewards from the strategy.
6. When USDC balance for a user strategy changes, Mamo Backend notes that and calls updateUserStrategy to rebalance the position.
7. If the user wants to move funds to a new strategy, they call withdrawFunds, and the Mamo Backend deploys a new strategy and calls addStrategy to register it, then the user deposits into the new strategy.
8. If Mamo wants to upgrade a strategy (example, deposit USDC into a new protocol) it can whitelist the new implementation and ask users to upgrade. Users can only upgrade to implementations of the same strategy type.

## Security Considerations

1. Each user has their own dedicated strategy contract, eliminating the need for delegatecall and its associated security risks.
2. Implementation whitelist ensures that only trusted and audited implementations can be used.
3. Strategy implementations can be upgraded, but only to whitelisted implementations of the same strategy type, providing flexibility while maintaining security.
4. The Mamo Strategy Registry contract has proper access controls to ensure only authorized addresses can call sensitive functions.
5. Strategy contracts have clear ownership semantics, with only the owner able to deposit and withdraw funds, while only the Mamo Backend can update positions.
6. The Mamo Strategy Registry contract maintains a registry of all deployed strategies, allowing for efficient coordination and verification.
