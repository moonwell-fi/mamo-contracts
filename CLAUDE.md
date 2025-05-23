# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build, Test, and Development Commands

### Core Commands
- **Build contracts**: `forge build`
- **Run tests**: `forge test --fork-url base --ffi -vvv`
- **Run a specific test file**: `forge test --fork-url base --ffi -vv --match-path test/TestFileName.t.sol`
- **Run a specific test function**: `forge test --fork-url base --ffi -vv --match-test testFunctionName`
- **Generate test coverage**: `make coverage` (generates HTML coverage report in the coverage directory)
- **Deploy system**: `make deploy-broadcast` (deploys to Base mainnet with configured parameters)
- **Generate TypeScript utilities**: `npm run generate-appdata` (generates app data for CowSwap integration)

### Common Foundry Commands
- **Run scripts**: `forge script script/ScriptName.s.sol:ScriptContractName --fork-url base --account <account-name> -vvv`
- **Cast (CLI utility)**: `cast call <contract> <signature> <args> --rpc-url base`
- **Inspect blockchain data**: `cast block latest --rpc-url base`

## Project Architecture

### Core Components

1. **MamoStrategyRegistry**: Central registry that coordinates strategies, tracks ownership, manages implementations, and handles upgrades.
   - Maintains a list of whitelisted strategy implementations
   - Maps users to their strategies
   - Controls strategy upgrades to ensure security

2. **BaseStrategy**: Abstract base contract that all strategy implementations inherit from.
   - Handles common functionality like token recovery
   - Implements upgrade security checks
   - Manages ownership with the registry

3. **ERC20MoonwellMorphoStrategy**: Concrete strategy implementation for USDC.
   - Splits funds between Moonwell (lending protocol) and MetaMorpho (yield aggregator)
   - Supports reward claiming and swapping via CowSwap
   - Implements EIP-1271 for signature validation

4. **USDCStrategyFactory**: Factory contract for deploying new user strategies.
   - Creates proxy instances pointing to the implementation
   - Initializes strategies with the correct parameters
   - Registers strategies with the MamoStrategyRegistry

5. **SlippagePriceChecker**: Validates swap prices using Chainlink oracles.
   - Ensures swaps get fair market prices
   - Prevents sandwich attacks and MEV extraction

### System Flow

1. Mamo Backend whitelists strategy implementations in the registry
2. Users request strategy deployment through Mamo
3. Mamo deploys a strategy and registers it for the user
4. Users deposit funds directly into their strategy
5. Mamo Backend manages positions for optimal yield
6. Rewards are claimed and swapped back to the underlying token
7. Users can withdraw funds at any time
8. Strategy upgrades can only be initiated by users

## Testing Approach

The project uses Foundry for testing with three primary test types:
- **Unit tests**: Test individual components in isolation (`*.unit.t.sol`)
- **Integration tests**: Test interactions between multiple components (`*.integration.t.sol`)
- **Base tests**: Common test setup and utilities (`BaseTest.t.sol`)

Tests fork the Base network to interact with production dependencies like Moonwell and MetaMorpho.

## Deployment Process

Deployment is managed through Foundry scripts:
1. `DeploySystem.s.sol` orchestrates the entire deployment process
2. Configuration is loaded from JSON files in the `deploy/` directory
3. Contract addresses are stored and updated in the `addresses/` directory
4. Deployments follow a specific sequence to ensure dependencies are satisfied

## Security Considerations

- The system uses a role-based access control pattern:
  - `DEFAULT_ADMIN_ROLE`: Multisig with timelock for critical operations
  - `GUARDIAN_ROLE`: Multisig without timelock for emergency pause functionality
  - `BACKEND_ROLE`: Mamo backend for position management
- Strategy contracts can only be upgraded to whitelisted implementations
- The MamoStrategyRegistry is not upgradeable to ensure ownership guarantees
- All user funds remain under user control through their strategy contracts
- CowSwap integration for reward swapping includes price validation
- System does not support fee-on-transfer tokens

## Important Files

- `src/MamoStrategyRegistry.sol`: Core registry for tracking strategies
- `src/BaseStrategy.sol`: Base contract for all strategies
- `src/ERC20MoonwellMorphoStrategy.sol`: Main strategy implementation
- `src/USDCStrategyFactory.sol`: Factory for creating new strategies
- `src/SlippagePriceChecker.sol`: Validates swap prices
- `script/DeploySystem.s.sol`: Main deployment script
- `test/MamoStrategyRegistry.integration.t.sol`: Tests for the registry
- `test/USDCStrategy.integration.t.sol`: Tests for the USDC strategy

## Environment Setup

The project requires the following environment variables for deployment:
- `BASE_RPC_URL`: RPC URL for the Base network
- `BASESCAN_API_KEY`: API key for Base block explorer
- `DEPLOY_ENV`: Environment configuration to use (e.g., "8453_PROD" or "8453_TESTING")