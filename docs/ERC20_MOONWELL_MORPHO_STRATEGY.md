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

- `function initialize(InitParams calldata params) external`: Initializer function that sets all the parameters and grants appropriate roles. This is used instead of a constructor since the contract is designed to be used with proxies. The function sets up the admin role for the specified admin address.


- `function deposit(uint256 amount) external`: Deposits funds into the strategy. Only callable by the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `function approveCowSwap(address tokenAddress) external`: Approves the vault relayer to spend a specific token. Only callable by the user who owns this strategy. The function checks if the token has a configuration in the swap checker before approving.

- `function setSlippage(uint256 _newSlippageInBps) external`: Sets a new slippage tolerance value. Only callable by the strategy owner. The slippage is used when validating swap prices.

- `function withdraw(uint256 amount) external`: Withdraws funds from the strategy. Only callable by the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `function updatePosition(uint256 splitA, uint256 splitB) external`: Updates the position in the strategy. Only callable by the backend address from the Mamo Strategy Registry.

- `function addRewardToken(address rewardToken) external`: Adds a token to the reward tokens set. The strategy token cannot be added as a reward token. Only callable by the backend address from the Mamo Strategy Registry.

- `function removeRewardToken(address rewardToken) external`: Removes a token from the reward tokens set. Only callable by the backend address from the Mamo Strategy Registry.

- `function depositIdleTokens() external returns (uint256)`: Deposits any token funds currently in the contract into the strategies based on the split. This function is permissionless and can be called by anyone.

- `function isValidSignature(bytes32 orderDigest, bytes calldata encodedOrder) external view returns (bytes4)`: A function that Cow Swap will call to validate orders. This function verifies that the order parameters are valid and that the price matches the Chainlink price with the set slippage tolerance. Any bot can fulfill the order as long as the price is valid according to the SlippagePriceChecker. The function returns a magic value (0x1626ba7e) if the signature is valid, as per EIP-1271.

- `function _authorizeUpgrade(address) internal view override onlyStrategyRegistry()`: Internal function that authorizes an upgrade to a new implementation. Only callable by the Mamo Strategy Registry contract. This ensures that only the Mamo Strategy Registry contract can upgrade the strategy implementation.

- `function recoverERC20(address token, address to, uint256 amount) external`: Recovers ERC20 tokens accidentally sent to this contract. Only callable by the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `function getTotalBalance() public returns (uint256)`: Gets the total balance of tokens across both protocols.
