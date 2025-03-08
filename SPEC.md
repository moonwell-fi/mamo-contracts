# Mamo Contracts Specification

This document outlines the specification for the Mamo contracts, which enable users to deploy personal wallet contracts and let Mamo manage their funds.

## Mamo Core

This contract is responsible for deploying user wallet contracts, tracking user wallet contracts, moving funds/positions, and interacting with strategies. It inherits from the Ownable contract from OpenZeppelin and uses the EnumerableSet library for efficient set operations. The contract is upgradeable through a UUPS (Universal Upgradeable Proxy Standard) pattern, with only the owner able to perform upgrades.

### Storage

- `address owner`: The owner of this contract (the Mamo server)
- `EnumerableSet.AddressSet userWallets`: A set of user wallet contracts that Mamo will be responsible for managing the strategies.
- `EnumerableSet.AddressSet strategies`: A set of all strategy contract addresses

### Functions

- `function deposit(address asset, address strategy, uint256 amount) returns (address)`: User deposits funds. If the user has not granted permission to the strategy, it will revert. User must pre-approve the contract with the asset token. 
  - If the user doesn't have a wallet yet, this function will automatically deploy one using CREATE2. The address is deterministic based on the user's address. After deployment, the wallet address is added to the userWallets set using `userWallets.add(walletAddress)`.
  - The function transfers the funds to the user wallet. 
  - The next time Mamo calls `updateUsersStrategies` this amount will be considered and added to the yield contracts.
  - Returns the address of the user's wallet (either existing or newly created).

- `function updateUsersStrategies(address strategy, address[] wallets, uint256 splitA, uint256 splitB) returns (bool)`: Updates a single strategy for multiple users at once. Only callable by the owner. This function allows Mamo to efficiently update the same strategy for multiple users in a single transaction, reducing gas costs and simplifying management. The function should:
  - Validate that the strategy address exists in the strategies set
  - Validate that all provided wallet addresses exist in the userWallets set
  - Validate that the user has approved the strategy in the wallet contract
  - For each user wallet in the array: Call the wallet's updatePosition function with specified split parameters 

- `function addStrategy(address strategy)`: Adds a new strategy. Only callable by the owner.

- `function removeStrategy(address strategy)`: Removes a strategy. Only callable by the owner.

- `function claimRewardsForUsers(address strategy, address[] wallets)`: Claims rewards from the specified strategy for multiple users at once. Only callable by the owner. This function allows Mamo to efficiently claim rewards for multiple users in a single transaction, reducing gas costs and simplifying management. The function should:
  - Validate that the strategy address exists in the strategies set
  - Validate that all provided wallet addresses exist in the userWallets set
  - For each user wallet in the array: Call the wallet's claimRewards function with the specified strategy


## User Wallet

This contract holds user funds and interacts with strategies. It's deployed by the Mamo Core using CREATE2 and it's upgradeable through a UUPS (Universal Upgradeable Proxy Standard) pattern. Only the owner can upgrade. 

### Storage

- `address owner`: The owner of this contract (the user)
- `address mamoCore`: The Mamo Core contract address
- `mapping(address strategy => bool approved) approvedStrategies`: Mapping of strategies that the user has approved
- `mapping(address strategy => mapping(address token => uint256)) balances`: A mapping that tracks the balance of each token for each strategy. This allows tracking multiple token balances (e.g., USDC, mUSDC, mwUSDC).

### Functions

- `function approveStrategy(address strategy) external`: Approves a strategy to manage funds. Only callable by the owner ontract

- `function withdrawFunds(address token, uint256 amount) external`: Withdraws funds from the contract to the owner. Only callable by the owner. Makes a delegateCall to the strategy contract's `withdrawFunds` function.

- `function updatePosition(address strategy, uint256 splitA, uint256 splitB) external`: Updates the position in a strategy with specified split parameters. Only callable by the Mamo Core. Makes a delegateCall to the strategy contract to execute the actual position update logic. Updates the token balances in the wallet contract.

- `function claimRewards(address strategy) external`: Claims all available rewards from the strategy for both Moonwell and Morpho protocols. Only callable by the Mamo Core or the owner. Makes a delegateCall to the strategy contract's claimRewards function. Updates the token balances in the wallet contract.

## USDC Strategy

A specific implementation of a Strategy Contract for USDC that splits deposits between Moonwell core market and Moonwell Vaults.

### Storage

- `address moonwellComptroller`: The address of the Moonwell Comptroller contract
- `address moonwellUSDC`: The address of the Moonwell USDC mToken contract
- `address metaMorphoVault`: The address of the MetaMorpho Vault contract
- `address dexRouter`: The address of the DEX router for swapping reward tokens to USDC
- `address[] rewardTokens`: An array of reward token addresses (e.g., WELL, OP, MORPHO, etc.)
- `IERC20 usdc`: The USDC token interface
- `uint256 constant SPLIT_TOTAL`: The total basis points for split calculations (10,000)

### Constructor

- `constructor(address _moonwellComptroller, address _moonwellUSDC, address _metaMorphoVault, address _dexRouter, address[] memory _rewardTokens)`: Initializes the strategy with the necessary contract addresses. The constructor should:
  - Set the moonwellComptroller, moonwellUSDC, metaMorphoVault, and dexRouter addresses
  - Store the array of reward token addresses
  - Initialize the USDC token interface by getting the underlying asset from the moonwellUSDC contract
  - Verify that the MetaMorpho Vault's asset matches the USDC token address

### Functions

- `function claimRewards(address user) external`: Claims all available rewards from both Moonwell Comptroller and Morpho for the user and immediately converts them to USDC. The function should:
  - Initialize a total converted amount variable to 0
  
  - **Moonwell Rewards:**
    - Check if the user has any existing positions in Moonwell markets
    - If positions exist, claim rewards from the Moonwell Comptroller for the user
    - For each Moonwell reward token:
      - Check if any rewards were received for this token
      - If rewards were received:
        - Approve the DEX router to spend the reward tokens
        - Swap the reward tokens for USDC using the DEX router
        - Add the received USDC to the total converted amount
  
  - **Morpho Rewards:**
    - Morpho implements a permissionless reward claiming system, which means rewards can be claimed by any external entity on behalf of users
    - The Mamo server will handle claiming Morpho rewards externally, so this contract doesn't need to implement the claiming logic
    - When this function is called, the contract should check its MORPHO token balance, which will have increased if rewards were claimed externally
    - If the MORPHO balance is greater than 0, the contract should:
      - Approve the DEX router to spend the MORPHO tokens
      - Swap the MORPHO tokens for USDC using the DEX router
      - Add the received USDC to the total converted amount

  - Emit a RewardsHarvested event with the total converted USDC amount
  - Call the updateUserPosition in the main contract to update the USDC balance
  - Only callable by the User Wallet through delegateCall

- `function updateStrategy(address user, uint256 splitA, uint256 splitB) external`: Updates a user's position in the USDC strategy by depositing funds with a specified split between Moonwell core market and MetaMorpho Vault. The function should:
  - Validate that splitA + splitB equals SPLIT_TOTAL (10,000 basis points)
  
  - Withdraw all existing funds from both the Moonwell core market and MetaMorpho Vault contracts

  - Calculate the total available USDC (withdrawn funds + converted rewards) by checking usdc.balanceOf(address(this))
  
  - Calculate the amount to be deposited into each protocol:
    - amountA = (USDC balance * splitA) / SPLIT_TOTAL for Moonwell core market
    - amountB = (USDC balance * splitB) / SPLIT_TOTAL for MetaMorpho Vault
  
  - For the Moonwell core market portion (amountA):
    - Approve the moonwellUSDC contract to spend amountA of USDC
    - Call the mint function on the moonwellUSDC contract to supply USDC and receive mUSDC tokens
  
  - For the MetaMorpho Vault portion (amountB):
    - Approve the metaMorphoVault to spend amountB of USDC
    - Call the deposit function on the metaMorphoVault (using IERC4626 interface) to deposit USDC and receive vault shares
  
  - Emit a StrategyUpdated event with the user address, total amount, and split details
  - Only callable by the User Wallet through delegateCall
  - Has a callback to the main contract to update user balances

- `function withdrawFunds(address user, uint256 amount) external`: Withdraws USDC from both Moonwell core market and MetaMorpho Vault based on the user's current position. The function should:
  - Calculate the proportional amount to withdraw from each protocol based on the current balances
  - For the Moonwell core market portion:
    - Call the redeem function on the moonwellUSDC contract to burn mUSDC tokens and receive USDC
  - For the MetaMorpho Vault portion:
    - Call the withdraw function on the metaMorphoVault (using IERC4626 interface) to burn vault shares and receive USDC
  - Transfer the withdrawn USDC to the user (the wallet contract owner) 
  - Update the user's position in both protocols by calling updateUserPosition in the main contract.
  - Emit a FundsWithdrawn event with the user address and amount
  - Only callable by a User Wallet through delegateCall

## System Flow

1. A user interacts with the Main Contract to deploy their User Wallet (if not already deployed).
2. The user approves strategies through the wallet contract, which updates the permissions.
3. The user can deposit funds into strategies through the Main Contract.
4. The main contract or the user can claim rewards from both Moonwell and Morpho at any time:
   - For Moonwell rewards, the contract directly claims them from the Moonwell Comptroller
   - For Morpho rewards, the Mamo server handles claiming them externally through Morpho's permissionless claiming system
   - All rewards are immediately converted to USDC when the claimRewards function is called
5. The Main Contract interacts with the User Wallet to update positions and manage funds.
6. The Strategy contracts interact with external protocols like Moonwell core markets and Morpho Vaults.
7. The Main Contract can add and remove strategies as needed.

## Security Considerations

1. The Main Contract should have proper access controls to ensure only authorized addresses can call sensitive functions.
2. The User Wallet should verify that calls are coming from either the owner or the Main Contract.
3. Delegate calls should be carefully managed to prevent potential security vulnerabilities.
4. The CREATE2 deployment mechanism should be properly implemented to ensure deterministic addresses.
5. Token approvals should be managed carefully to prevent excessive permissions.
6. The UUPS (Universal Upgradeable Proxy Standard) pattern places the upgrade logic in the implementation contract itself, rather than in the proxy. This means that the implementation contract must include the `_authorizeUpgrade` function that controls who can upgrade the contract. This function should be properly secured with access controls to ensure only authorized addresses can upgrade the contract.
