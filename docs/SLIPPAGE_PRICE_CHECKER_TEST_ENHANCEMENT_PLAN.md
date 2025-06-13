# SlippagePriceChecker Integration Test Enhancement Plan

## Overview

This document outlines a comprehensive plan for enhancing `SlippagePriceChecker.integration.t.sol` to be dynamic and configuration-driven using the `ASSET_CONFIG_PATH` environment variable, following the same pattern as [`MoonwellMorphoStrategy.integration.t.sol`](test/MoonwellMorphoStrategy.integration.t.sol:97).

## Current State Analysis

### Existing Architecture
- **Configuration Loading Pattern**: [`MoonwellMorphoStrategy.integration.t.sol`](test/MoonwellMorphoStrategy.integration.t.sol:97) successfully uses `vm.envString("ASSET_CONFIG_PATH")` to load asset configurations dynamically
- **JSON Parsing Infrastructure**: [`DeployAssetConfig.sol`](script/DeployAssetConfig.sol) provides robust JSON parsing with [`stdJson`](script/DeployAssetConfig.sol:4) library
- **Current Limitations**: [`SlippagePriceChecker.integration.t.sol`](test/SlippagePriceChecker.integration.t.sol:67-91) uses hardcoded configurations that need to be made generic

### Configuration Structure Analysis
- **cbBTC Configuration**: [`cbBTCStrategyConfig.json`](config/strategies/cbBTCStrategyConfig.json:18-33) shows complex multi-feed setup
  - xWELL token with WELL/USD + BTC/USD (reversed) price feed chain
  - MORPHO token with single MORPHO/USD feed
- **USDC Configuration**: [`USDCStrategyConfig.json`](config/strategies/USDCStrategyConfig.json:16-27) shows simpler single-feed configurations
  - xWELL token with single WELL/USD feed
  - MORPHO token with single MORPHO/USD feed
- **Structure**: Both configs contain structured `rewardTokens` arrays with nested `priceFeeds` configurations

## Implementation Plan

### Phase 1: Environment-Driven Configuration Loading

#### 1.1 Update Test Setup
Modify [`SlippagePriceChecker.integration.t.sol`](test/SlippagePriceChecker.integration.t.sol:37-65) to follow the same pattern as [`MoonwellMorphoStrategy.integration.t.sol`](test/MoonwellMorphoStrategy.integration.t.sol:87-103):

```solidity
import {AddTokenConfiguration} from "@script/AddTokenConfiguration.s.sol";

contract SlippagePriceCheckerTest is Test {
    using stdJson for string;
    
    // Add asset configuration support
    DeployAssetConfig.Config public assetConfig;
    
    function setUp() public {
        // Existing setup...
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get environment configuration
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));
        
        // Load asset configuration from environment
        string memory assetConfigPath = vm.envString("ASSET_CONFIG_PATH");
        
        DeployConfig configDeploy = new DeployConfig(configPath);
        config = configDeploy.getConfig();
        
        DeployAssetConfig assetConfigDeploy = new DeployAssetConfig(assetConfigPath);
        assetConfig = assetConfigDeploy.getConfig();
        
        // Dynamic token setup based on configuration
        _setupDynamicTokens();
        _setupSlippagePriceChecker();
    }
}
```

#### 1.2 Dynamic Token Configuration
Replace hardcoded token setup with configuration-driven approach:

```solidity
function _setupDynamicTokens() internal {
    // Get underlying token from asset config
    underlying = IERC20(addresses.getAddress(assetConfig.token));
    well = IERC20(addresses.getAddress("xWELL_PROXY"));
    
    // Set up owner and addresses
    owner = addresses.getAddress(config.admin);
    
    // Dynamic price feed addresses based on asset config
    for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
        DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
        // Store token configurations for later use in tests
        _storeTokenConfiguration(rewardToken);
    }
}

function _storeTokenConfiguration(DeployAssetConfig.RewardToken memory rewardToken) internal {
    // Store token configuration for use in tests
    // This will be used to dynamically configure price feeds
}
```

### Phase 2: Configuration-Driven Price Feed Setup

#### 2.1 Dynamic SlippagePriceChecker Configuration
Replace [`addTokenConfigurations()`](test/SlippagePriceChecker.integration.t.sol:67-91) with configuration-driven setup:

```solidity
function _setupSlippagePriceChecker() internal {
    if (!addresses.isAddressSet("CHAINLINK_SWAP_CHECKER_PROXY")) {
        DeploySlippagePriceChecker deployScript = new DeploySlippagePriceChecker();
        slippagePriceChecker = deployScript.deploySlippagePriceChecker(addresses, config);
    } else {
        slippagePriceChecker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
    }
    
    // Configure tokens based on asset configuration
    _configureTokensForAsset();
}

function _configureTokensForAsset() internal {
    // Check if this is cbBTC configuration - if so, run AddTokenConfiguration script
    if (keccak256(bytes(assetConfig.symbol)) == keccak256(bytes("cbBTC"))) {
        _addCBBTCTokenConfiguration();
    }
    // For USDC, tokens are already configured on Base network
    // No additional configuration needed when forking Base
}

function _addCBBTCTokenConfiguration() internal {
    // Use the existing AddTokenConfiguration script for cbBTC
    AddTokenConfiguration addTokenScript = new AddTokenConfiguration();
    
    // Load the asset configuration for the script
    DeployAssetConfig assetConfigForScript = new DeployAssetConfig("config/strategies/cbBTCStrategyConfig.json");
    
    // Run the token configuration script
    addTokenScript.addTokenConfiguration(addresses, assetConfigForScript);
}
```

### Phase 3: Generic Test Implementation

#### 3.1 Configuration-Aware Test Functions
Update existing tests to work with any configuration:

```solidity
function testTokenConfiguration() public view {
    // Test all tokens from asset configuration
    for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
        DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
        address tokenAddress = addresses.getAddress(rewardToken.token);
        
        // Verify token configuration
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            slippagePriceChecker.tokenOracleInformation(tokenAddress);
        
        assertEq(configs.length, rewardToken.priceFeeds.length, 
            string(abi.encodePacked(rewardToken.token, " should have correct number of configurations")));
        
        // Verify each price feed configuration
        for (uint256 j = 0; j < configs.length; j++) {
            assertEq(configs[j].chainlinkFeed, addresses.getAddress(rewardToken.priceFeeds[j].priceFeed),
                "Price feed should match configuration");
            assertEq(configs[j].reverse, rewardToken.priceFeeds[j].reverse,
                "Reverse flag should match configuration");
            assertEq(configs[j].heartbeat, rewardToken.priceFeeds[j].heartbeat,
                "Heartbeat should match configuration");
        }
        
        assertEq(slippagePriceChecker.maxTimePriceValid(tokenAddress), rewardToken.maxTimePriceValid,
            "Max time price valid should match configuration");
    }
}
```

#### 3.2 Multi-Feed Chain Testing
Special focus on testing complex price feed chains like cbBTC's xWELL configuration:

```solidity
function testMultiFeedChainCalculation() public view {
    // Find tokens with multiple price feeds
    for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
        DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
        
        if (rewardToken.priceFeeds.length > 1) {
            _testMultiFeedToken(rewardToken);
        }
    }
}

function _testMultiFeedToken(DeployAssetConfig.RewardToken memory rewardToken) internal view {
    address tokenAddress = addresses.getAddress(rewardToken.token);
    address underlyingAddress = addresses.getAddress(assetConfig.token);
    
    // Test price calculation with multi-feed setup
    uint256 amountIn = 1 * 10 ** 18; // 1 token (assuming 18 decimals for test)
    uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, tokenAddress, underlyingAddress);
    
    assertTrue(expectedOut > 0, 
        string(abi.encodePacked("Multi-feed calculation should return positive value for ", rewardToken.token)));
    
    // Test that the calculation is consistent
    uint256 expectedOut2 = slippagePriceChecker.getExpectedOut(amountIn, tokenAddress, underlyingAddress);
    assertEq(expectedOut, expectedOut2, "Multi-feed calculation should be deterministic");
}
```

#### 3.3 Configuration-Specific Edge Cases
Test edge cases specific to each configuration:

```solidity
function testConfigurationSpecificEdgeCases() public {
    // Test based on asset configuration symbol
    if (keccak256(bytes(assetConfig.symbol)) == keccak256(bytes("cbBTC"))) {
        _testCBBTCSpecificCases();
    } else if (keccak256(bytes(assetConfig.symbol)) == keccak256(bytes("USDC"))) {
        _testUSDCSpecificCases();
    }
}

function _testCBBTCSpecificCases() internal {
    // Test the complex WELL/USD + BTC/USD (reversed) chain
    address xWellAddress = addresses.getAddress("xWELL_PROXY");
    address cbBTCAddress = addresses.getAddress(assetConfig.token);
    
    // Test with various amounts to ensure the multi-feed chain works correctly
    uint256[] memory testAmounts = new uint256[](3);
    testAmounts[0] = 1e18;      // 1 WELL
    testAmounts[1] = 100e18;    // 100 WELL
    testAmounts[2] = 10000e18;  // 10,000 WELL
    
    for (uint256 i = 0; i < testAmounts.length; i++) {
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(testAmounts[i], xWellAddress, cbBTCAddress);
        assertTrue(expectedOut > 0, "cbBTC multi-feed chain should work for all amounts");
        
        // Test slippage check with reasonable bounds
        uint256 slippage = 100; // 1%
        uint256 minOut = (expectedOut * (10000 - slippage)) / 10000;
        
        assertTrue(
            slippagePriceChecker.checkPrice(testAmounts[i], xWellAddress, cbBTCAddress, minOut + 1, slippage),
            "cbBTC price check should pass with reasonable slippage"
        );
    }
}

function _testUSDCSpecificCases() internal {
    // Test simpler single-feed configurations
    address xWellAddress = addresses.getAddress("xWELL_PROXY");
    address usdcAddress = addresses.getAddress(assetConfig.token);
    
    // USDC has simpler price feeds, test direct conversion
    uint256 amountIn = 1e18; // 1 WELL
    uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, xWellAddress, usdcAddress);
    
    assertTrue(expectedOut > 0, "USDC single-feed calculation should work");
    
    // Test that USDC amounts are reasonable (should be in USDC decimals)
    assertTrue(expectedOut < 1e12, "USDC output should be reasonable for 1 WELL input");
}
```

### Phase 4: Test Execution Strategy

#### 4.1 CI Integration
The tests can be run with different configurations using environment variables with `--fork-url base`:

```bash
# Test with cbBTC configuration (uses AddTokenConfiguration script)
ASSET_CONFIG_PATH=config/strategies/cbBTCStrategyConfig.json forge test --fork-url base --ffi -vv --match-path test/SlippagePriceChecker.integration.t.sol

# Test with USDC configuration (uses existing Base network configuration)
ASSET_CONFIG_PATH=config/strategies/USDCStrategyConfig.json forge test --fork-url base --ffi -vv --match-path test/SlippagePriceChecker.integration.t.sol
```

**Key Differences:**
- **cbBTC**: Runs [`AddTokenConfiguration.s.sol`](script/AddTokenConfiguration.s.sol) to configure cbBTC-specific tokens (MORPHO, xWELL with multi-feed setup)
- **USDC**: Uses existing token configurations already deployed on Base network
- **Both**: Fork Base network (`--fork-url base`) to access production price feeds and contracts

#### 4.2 Makefile Integration
Add targets to the Makefile for easy testing:

```makefile
test-slippage-cbbtc:
	ASSET_CONFIG_PATH=config/strategies/cbBTCStrategyConfig.json forge test --fork-url base --ffi -vv --match-path test/SlippagePriceChecker.integration.t.sol

test-slippage-usdc:
	ASSET_CONFIG_PATH=config/strategies/USDCStrategyConfig.json forge test --fork-url base --ffi -vv --match-path test/SlippagePriceChecker.integration.t.sol

test-slippage-all: test-slippage-cbbtc test-slippage-usdc
```

### Phase 5: Enhanced Test Coverage

#### 5.1 Configuration Validation Tests
```solidity
function testConfigurationValidation() public view {
    // Verify asset configuration is properly loaded
    assertTrue(bytes(assetConfig.symbol).length > 0, "Asset symbol should be loaded");
    assertTrue(assetConfig.decimals > 0, "Asset decimals should be valid");
    assertTrue(bytes(assetConfig.token).length > 0, "Asset token should be specified");
    assertTrue(assetConfig.rewardTokens.length > 0, "Should have reward tokens configured");
    
    // Verify all reward tokens have valid configurations
    for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
        DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
        
        assertTrue(bytes(rewardToken.token).length > 0, "Reward token should be specified");
        assertTrue(rewardToken.maxTimePriceValid > 0, "Max time price valid should be positive");
        assertTrue(rewardToken.priceFeeds.length > 0, "Should have at least one price feed");
        
        for (uint256 j = 0; j < rewardToken.priceFeeds.length; j++) {
            DeployAssetConfig.PriceFeedConfig memory priceFeed = rewardToken.priceFeeds[j];
            assertTrue(bytes(priceFeed.priceFeed).length > 0, "Price feed should be specified");
            assertTrue(priceFeed.heartbeat > 0, "Heartbeat should be positive");
        }
    }
}
```

#### 5.2 Cross-Configuration Compatibility Tests
```solidity
function testCrossConfigurationCompatibility() public {
    // Test that the same test logic works across different configurations
    // This ensures our generic approach is truly configuration-agnostic
    
    for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
        DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
        address tokenAddress = addresses.getAddress(rewardToken.token);
        address underlyingAddress = addresses.getAddress(assetConfig.token);
        
        // Test basic functionality regardless of configuration
        _testBasicPriceFunctionality(tokenAddress, underlyingAddress, rewardToken.token);
        
        // Test error conditions
        _testErrorConditions(tokenAddress, underlyingAddress, rewardToken.token);
    }
}

function _testBasicPriceFunctionality(address tokenIn, address tokenOut, string memory tokenName) internal view {
    uint256 amountIn = 1e18;
    uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, tokenIn, tokenOut);
    
    assertTrue(expectedOut > 0, 
        string(abi.encodePacked("Basic price functionality should work for ", tokenName)));
    
    // Test slippage check
    uint256 slippage = 100; // 1%
    uint256 minOut = (expectedOut * (10000 - slippage)) / 10000;
    
    assertTrue(
        slippagePriceChecker.checkPrice(amountIn, tokenIn, tokenOut, minOut + 1, slippage),
        string(abi.encodePacked("Slippage check should work for ", tokenName))
    );
}

function _testErrorConditions(address tokenIn, address tokenOut, string memory tokenName) internal {
    uint256 amountIn = 1e18;
    uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, tokenIn, tokenOut);
    
    // Test that excessive slippage fails
    uint256 excessiveSlippage = 10001; // > 100%
    vm.expectRevert("Slippage exceeds maximum");
    slippagePriceChecker.checkPrice(amountIn, tokenIn, tokenOut, expectedOut / 2, excessiveSlippage);
    
    // Test that insufficient output fails
    uint256 reasonableSlippage = 100; // 1%
    uint256 tooLowMinOut = (expectedOut * (10000 - reasonableSlippage - 100)) / 10000; // Below acceptable
    
    assertFalse(
        slippagePriceChecker.checkPrice(amountIn, tokenIn, tokenOut, tooLowMinOut, reasonableSlippage),
        string(abi.encodePacked("Price check should fail for too low output for ", tokenName))
    );
}
```

## Implementation Benefits

### 1. **Configuration Flexibility**
- Single test file works with any asset configuration using `ASSET_CONFIG_PATH`
- Leverages existing [`AddTokenConfiguration.s.sol`](script/AddTokenConfiguration.s.sol) for cbBTC setup
- Uses production Base network state for USDC (already configured)
- CI can test multiple configurations automatically

### 2. **Multi-Feed Chain Support**
- Comprehensive testing of complex price feed chains like WELL/USD + BTC/USD (reversed)
- Validates price calculation accuracy across different feed configurations
- Ensures reliability of multi-step price conversions using real Base network data

### 3. **Maintainability**
- Follows established patterns from [`MoonwellMorphoStrategy.integration.t.sol`](test/MoonwellMorphoStrategy.integration.t.sol)
- Leverages existing [`DeployAssetConfig`](script/DeployAssetConfig.sol) infrastructure
- Reuses [`AddTokenConfiguration.s.sol`](script/AddTokenConfiguration.s.sol) script for consistency
- Reduces code duplication and maintenance overhead

### 4. **Production Environment Testing**
- Tests against real Base network state with `--fork-url base`
- Uses actual Chainlink price feeds and deployed contracts
- Validates behavior with production price data and network conditions
- Ensures compatibility with existing deployed SlippagePriceChecker contracts

### 5. **Comprehensive Coverage**
- Tests both simple single-feed (USDC) and complex multi-feed (cbBTC) scenarios
- Validates configuration loading and parsing
- Ensures cross-configuration compatibility
- Covers both new deployments (cbBTC) and existing deployments (USDC)

## Migration Strategy

### Phase 1: Backup and Preparation
1. Create backup of current [`SlippagePriceChecker.integration.t.sol`](test/SlippagePriceChecker.integration.t.sol)
2. Ensure all existing tests pass before modification

### Phase 2: Incremental Implementation
1. Add asset configuration loading to `setUp()`
2. Implement dynamic token configuration
3. Update existing tests to be configuration-aware
4. Add new multi-feed chain tests

### Phase 3: Validation and Testing
1. Test with cbBTC configuration
2. Test with USDC configuration  
3. Verify all existing functionality still works
4. Add CI integration for both configurations

### Phase 4: Documentation and Cleanup
1. Update test documentation
2. Add Makefile targets
3. Remove any remaining hardcoded values
4. Ensure comprehensive test coverage

This approach transforms the SlippagePriceChecker integration tests into a robust, configuration-driven framework that can handle both simple single-feed scenarios (USDC) and complex multi-feed chains (cbBTC), while maintaining the same high-quality testing standards and following established patterns in the codebase.