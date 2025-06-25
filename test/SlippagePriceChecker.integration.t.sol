// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {DeployConfig} from "@script/DeployConfig.sol";
import {DeploySlippagePriceChecker} from "@script/DeploySlippagePriceChecker.s.sol";

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FixIsRewardToken} from "@multisig/002_FixIsRewardToken.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";

contract SlippagePriceCheckerTest is Test {
    ISlippagePriceChecker public slippagePriceChecker;
    Addresses public addresses;

    // Contracts from Base network
    ERC20 public underlying;
    ERC20 public well;
    ERC20 public morpho;
    address public owner;

    // Constants
    uint256 public constant INITIAL_SLIPPAGE = 100; // 1%
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant DEFAULT_MAX_TIME_PRICE_VALID = 3600; // 1 hour in seconds

    DeployConfig.DeploymentConfig public config;
    DeployAssetConfig.Config public assetConfig;

    mapping(address => uint256) public amountInByToken;

    address public chainlinkWellUsd;
    address public chainlinkBtcUsd;

    function setUp() public {
        // workaround to make test contract work with mappings
        vm.makePersistent(DEFAULT_TEST_CONTRACT);
        // Initialize addresses

        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get the environment from command line arguments or use default
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));

        DeployConfig configDeploy = new DeployConfig(configPath);
        config = configDeploy.getConfig();

        // Load asset configuration from environment
        string memory assetConfigPath = vm.envString("ASSET_CONFIG_PATH");
        assetConfig = new DeployAssetConfig(assetConfigPath).getConfig();

        // Get the addresses from the addresses contract
        owner = addresses.getAddress(config.admin);
        underlying = ERC20(addresses.getAddress(assetConfig.token));
        well = ERC20(addresses.getAddress("xWELL_PROXY"));
        morpho = ERC20(addresses.getAddress("MORPHO"));

        if (!addresses.isAddressSet("CHAINLINK_SWAP_CHECKER_PROXY")) {
            // Deploy the SlippagePriceChecker using the script
            DeploySlippagePriceChecker deployScript = new DeploySlippagePriceChecker();
            slippagePriceChecker = deployScript.deploySlippagePriceChecker(addresses, config);
            addresses.addAddress("CHAINLINK_SWAP_CHECKER_PROXY", address(slippagePriceChecker), true);
        } else {
            slippagePriceChecker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        }

        // todo remove this once FixIsRewardToken is executed
        FixIsRewardToken fixIsRewardToken = new FixIsRewardToken();
        fixIsRewardToken.setAddresses(addresses);
        fixIsRewardToken.deploy();
        fixIsRewardToken.build();
        fixIsRewardToken.simulate();
        fixIsRewardToken.validate();

        amountInByToken[address(well)] = 300e18;
        amountInByToken[address(morpho)] = 3e18;

        chainlinkWellUsd = addresses.getAddress("CHAINLINK_WELL_USD");
        chainlinkBtcUsd = addresses.getAddress("CHAINLINK_BTC_USD");
    }

    function testInitialState() public view {
        // Check owner
        assertEq(OwnableUpgradeable(address(slippagePriceChecker)).owner(), owner, "Owner should be set correctly");
    }

    function testTokenConfigurationMatchesAssetConfig() public view {
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
            assertEq(
                slippagePriceChecker.maxTimePriceValid(addresses.getAddress(rewardToken.token)),
                rewardToken.maxTimePriceValid,
                "maxTimePriceValid should match"
            );

            ISlippagePriceChecker.TokenFeedConfiguration[] memory rewardTokenConfigs = slippagePriceChecker
                .tokenPairOracleInformation(addresses.getAddress(rewardToken.token), address(underlying));

            assertEq(
                rewardTokenConfigs.length,
                rewardToken.priceFeeds.length,
                "rewardToken should have as many configurations as the asset config priceFeeds length"
            );
            for (uint256 j = 0; j < rewardToken.priceFeeds.length; j++) {
                DeployAssetConfig.PriceFeedConfig memory priceFeed = rewardToken.priceFeeds[j];
                assertEq(
                    rewardTokenConfigs[j].chainlinkFeed,
                    addresses.getAddress(priceFeed.priceFeed),
                    "rewardToken price feed should match"
                );
                assertEq(rewardTokenConfigs[j].reverse, priceFeed.reverse, "rewardToken reverse flag should match");
                assertEq(rewardTokenConfigs[j].heartbeat, priceFeed.heartbeat, "rewardToken heartbeat should match");
            }
        }
    }

    function testUpdateMaxTimePriceValid() public {
        // current maxTimePriceValid
        uint256 currentMaxTimePriceValid = slippagePriceChecker.maxTimePriceValid(address(well));
        assertEq(currentMaxTimePriceValid, DEFAULT_MAX_TIME_PRICE_VALID, "WELL maxTimePriceValid should be 1 hour");

        // new maxTimePriceValid
        uint256 newMaxTimePriceValid = 7200; // 2 hours in seconds

        // Then add the new configuration with updated maxTimePriceValid
        vm.prank(owner);
        slippagePriceChecker.setMaxTimePriceValid(address(well), newMaxTimePriceValid);

        // Verify the maxTimePriceValid was updated
        assertEq(
            slippagePriceChecker.maxTimePriceValid(address(well)),
            newMaxTimePriceValid,
            "WELL maxTimePriceValid should be updated"
        );
    }

    function testRemoveAndAddTokenConfiguration() public {
        // Create a new configuration for WELL token
        ISlippagePriceChecker.TokenFeedConfiguration[] memory newConfigs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        newConfigs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: true, // Change the reverse flag
            heartbeat: 1800
        });

        // First remove the existing configuration
        vm.prank(owner);
        slippagePriceChecker.removeTokenConfiguration(address(well), address(underlying));

        // Then add the new configuration
        vm.prank(owner);
        slippagePriceChecker.addTokenConfiguration(address(well), address(underlying), newConfigs);

        // Verify the token configuration was updated
        ISlippagePriceChecker.TokenFeedConfiguration[] memory updatedConfigs =
            slippagePriceChecker.tokenPairOracleInformation(address(well), address(underlying));
        assertEq(updatedConfigs.length, 1, "WELL should still have 1 configuration");
        assertEq(updatedConfigs[0].chainlinkFeed, chainlinkWellUsd, "WELL price feed should remain the same");
        assertEq(updatedConfigs[0].reverse, true, "WELL reverse flag should be updated");
    }

    function testGetExpectedOut() public view {
        // Loop over assetConfig.rewardTokens and get the expected output for each token
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
            uint256 amountIn = amountInByToken[addresses.getAddress(rewardToken.token)];

            console.log("=== DEBUGGING CALCULATION ===");
            console.log("Token:", rewardToken.token);
            console.log("AmountIn:", amountIn);

            uint256 slippagePriceCheckerOut = slippagePriceChecker.getExpectedOut(
                amountIn, addresses.getAddress(rewardToken.token), address(underlying)
            );
            console.log("SlippagePriceChecker result:", slippagePriceCheckerOut);

            assertTrue(slippagePriceCheckerOut > 0, "Expected output should be greater than zero");

            uint256 expectedOutFromChainlink = amountIn;

            // check if the output matches the chainlink price
            for (uint256 j = 0; j < rewardToken.priceFeeds.length; j++) {
                DeployAssetConfig.PriceFeedConfig memory priceFeed = rewardToken.priceFeeds[j];
                (, int256 answer,,,) = IPriceFeed(addresses.getAddress(priceFeed.priceFeed)).latestRoundData();
                uint256 chainlinkPrice = uint256(answer);
                uint256 scaleAnswerBy = 10 ** uint256(IPriceFeed(addresses.getAddress(priceFeed.priceFeed)).decimals());

                expectedOutFromChainlink = priceFeed.reverse
                    ? (expectedOutFromChainlink * scaleAnswerBy) / chainlinkPrice
                    : (expectedOutFromChainlink * chainlinkPrice) / scaleAnswerBy;

                console.log("After feed", j, ":", expectedOutFromChainlink);
            }

            uint256 fromTokenDecimals = 18; // TODO move this to assetConfig
            uint256 toTokenDecimals = assetConfig.decimals;

            // Apply decimal adjustment AFTER all price feed calculations (same as SlippagePriceChecker)
            if (fromTokenDecimals > toTokenDecimals) {
                uint256 divisor = 10 ** (fromTokenDecimals - toTokenDecimals);
                console.log("Dividing by:", divisor);
                expectedOutFromChainlink = expectedOutFromChainlink / divisor;
            } else if (fromTokenDecimals < toTokenDecimals) {
                uint256 multiplier = 10 ** (toTokenDecimals - fromTokenDecimals);
                console.log("Multiplying by:", multiplier);
                expectedOutFromChainlink = expectedOutFromChainlink * multiplier;
            }

            console.log("Final test calculation:", expectedOutFromChainlink);
            console.log("SlippagePriceChecker result:", slippagePriceCheckerOut);

            assertEq(slippagePriceCheckerOut, expectedOutFromChainlink, "Expected output should match chainlink price");
        }
    }

    function testCheckPrice() public view {
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
            address tokenAddress = addresses.getAddress(rewardToken.token);

            // Get the expected output for 1 WELL to USDC
            uint256 amountIn = amountInByToken[tokenAddress];
            uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, tokenAddress, address(underlying));

            // Calculate the minimum acceptable output with slippage
            // The contract checks if minOut > (expectedOut * (MAX_BPS - slippage)) / MAX_BPS
            // So we need to set minOut to a value that is less than expectedOut but greater than the minimum
            uint256 minOut = (expectedOut * (MAX_BPS - INITIAL_SLIPPAGE)) / MAX_BPS + 1;

            // Check if the price is acceptable
            bool result =
                slippagePriceChecker.checkPrice(amountIn, tokenAddress, address(underlying), minOut, INITIAL_SLIPPAGE);

            assertTrue(result, "Price check should pass with acceptable slippage");
        }
    }

    function testCheckPriceFail() public view {
        // Get the expected output for 1 WELL to USDC
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, address(well), address(underlying));

        // Calculate a minimum output that's too low (below allowed slippage)
        // The contract checks if minOut > (expectedOut * (MAX_BPS - slippage)) / MAX_BPS
        // So we need to set minOut to a value that is less than the minimum
        uint256 minOut = (expectedOut * (MAX_BPS - INITIAL_SLIPPAGE - 10)) / MAX_BPS;

        // Check if the price is acceptable (should fail)
        bool result =
            slippagePriceChecker.checkPrice(amountIn, address(well), address(underlying), minOut, INITIAL_SLIPPAGE);

        assertFalse(result, "Price check should fail with too much slippage");
    }

    function testRevertIfNonOwnerAddTokenConfiguration() public {
        address nonOwner = makeAddr("nonOwner");

        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: false,
            heartbeat: 1800
        });

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        slippagePriceChecker.addTokenConfiguration(address(well), address(underlying), configs);
    }

    function testRevertIfNonOwnerRemoveTokenConfiguration() public {
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        slippagePriceChecker.removeTokenConfiguration(address(well), address(underlying));
    }

    function testRevertIfZeroTokenAddress() public {
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: false,
            heartbeat: 1800
        });

        vm.prank(owner);
        vm.expectRevert("Invalid from token address");
        slippagePriceChecker.addTokenConfiguration(address(0), address(underlying), configs);
    }

    function testRevertIfZeroToTokenAddressInRemoveTokenConfiguration() public {
        vm.prank(owner);
        vm.expectRevert("Invalid to token address");
        slippagePriceChecker.removeTokenConfiguration(address(well), address(0));
    }

    function testRevertIfZeroPriceFeedAddress() public {
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] =
            ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: address(0), reverse: false, heartbeat: 1800});

        vm.prank(owner);
        vm.expectRevert("Invalid chainlink feed address");
        slippagePriceChecker.addTokenConfiguration(address(well), address(underlying), configs);
    }

    function testRemoveTokenConfiguration() public {
        // Call removeTokenConfiguration
        vm.prank(owner);
        slippagePriceChecker.removeTokenConfiguration(address(well), address(underlying));

        // Verify that the token configuration has been removed
        vm.expectRevert("Token pair not configured");
        slippagePriceChecker.getExpectedOut(1 * 10 ** 18, address(well), address(underlying));

        // Try to get the token configuration - should return an empty array
        ISlippagePriceChecker.TokenFeedConfiguration[] memory finalConfigs =
            slippagePriceChecker.tokenPairOracleInformation(address(well), address(underlying));
        assertEq(finalConfigs.length, 0, "WELL should have no configurations after removal");
    }

    function testRevertIfEmptyConfigurationsArray() public {
        // Create an empty configurations array
        ISlippagePriceChecker.TokenFeedConfiguration[] memory emptyConfigs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](0);

        vm.prank(owner);
        vm.expectRevert("Empty configurations array");
        slippagePriceChecker.addTokenConfiguration(address(well), address(underlying), emptyConfigs);
    }

    function testRevertIfTokenNotConfigured() public {
        // Create a new token address that hasn't been configured
        address unconfiguredToken = makeAddr("unconfiguredToken");

        vm.expectRevert("Token pair not configured");
        slippagePriceChecker.getExpectedOut(1 * 10 ** 18, unconfiguredToken, address(underlying));

        vm.expectRevert("Token pair not configured");
        slippagePriceChecker.checkPrice(
            1 * 10 ** 18, unconfiguredToken, address(underlying), 1 * 10 ** 6, INITIAL_SLIPPAGE
        );
    }

    function testRevertIfZeroFromTokenAddressInRemoveTokenConfiguration() public {
        vm.prank(owner);
        vm.expectRevert("Invalid from token address");
        slippagePriceChecker.removeTokenConfiguration(address(0), address(underlying));
    }

    function testRevertIfZeroToTokenAddressInAddTokenConfiguration() public {
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: false,
            heartbeat: 1800
        });

        vm.prank(owner);
        vm.expectRevert("Invalid to token address");
        slippagePriceChecker.addTokenConfiguration(address(well), address(0), configs);
    }

    function testRevertIfSlippageExceedsMaximum() public {
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, address(well), address(underlying));
        uint256 minOut = expectedOut / 2; // Some arbitrary minOut value
        uint256 excessiveSlippage = MAX_BPS + 1; // Exceeds maximum BPS

        vm.expectRevert("Slippage exceeds maximum");
        slippagePriceChecker.checkPrice(amountIn, address(well), address(underlying), minOut, excessiveSlippage);
    }

    function testRevertIfZeroMaxTimePriceValid() public {
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: false,
            heartbeat: 1800
        });

        vm.prank(owner);
        vm.expectRevert("Max time price valid can't be zero");
        slippagePriceChecker.setMaxTimePriceValid(address(well), 0);
    }

    function testRevertIfTokenNotConfiguredInRemoveTokenConfiguration() public {
        // Create a new token address that hasn't been configured
        address unconfiguredToken = makeAddr("unconfiguredToken");

        vm.prank(owner);
        vm.expectRevert("Token pair not configured");
        slippagePriceChecker.removeTokenConfiguration(unconfiguredToken, address(underlying));
    }

    function testAddTokenConfigurationWithMultipleFeeds() public {
        // Configure WELL token with multiple price feeds (WELL/USD and then USD/USDC)
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](2);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: false,
            heartbeat: 1 days
        });
        configs[1] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkBtcUsd,
            reverse: true, // Reverse to get USD/USDC
            heartbeat: 1 days
        });

        // First remove the existing configuration
        vm.prank(owner);
        slippagePriceChecker.removeTokenConfiguration(address(well), address(underlying));

        // Then add the new configuration
        vm.prank(owner);
        slippagePriceChecker.addTokenConfiguration(address(well), address(underlying), configs);

        // Verify the token configuration
        ISlippagePriceChecker.TokenFeedConfiguration[] memory storedConfigs =
            slippagePriceChecker.tokenPairOracleInformation(address(well), address(underlying));
        assertEq(storedConfigs.length, 2, "WELL should have 2 configurations");
        assertEq(storedConfigs[0].chainlinkFeed, chainlinkWellUsd, "First price feed should match");
        assertEq(storedConfigs[0].reverse, false, "First reverse flag should match");
        assertEq(storedConfigs[1].chainlinkFeed, chainlinkBtcUsd, "Second price feed should match");
        assertEq(storedConfigs[1].reverse, true, "Second reverse flag should match");

        // Test the expected output with the new configuration
        uint256 amountIn = amountInByToken[address(well)];
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, address(well), address(underlying));

        // The expected output should be non-zero
        assertTrue(expectedOut > 0, "Expected output should be greater than zero");
    }

    function testGetExpectedOutWithReverseFlag() public {
        // Configure WELL token with reverse flag
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: true,
            heartbeat: 86400
        });

        // First remove the existing configuration
        vm.prank(owner);
        slippagePriceChecker.removeTokenConfiguration(address(well), address(underlying));

        // Then add the new configuration
        vm.prank(owner);
        slippagePriceChecker.addTokenConfiguration(address(well), address(underlying), configs);

        // Get the expected output from the swap checker
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, address(well), address(underlying));

        // Verify the output is non-zero
        assertTrue(expectedOut > 0, "Expected output should be greater than zero");
    }

    function testAuthorizeUpgrade() public {
        // Deploy a new implementation
        SlippagePriceChecker newImplementation = new SlippagePriceChecker();

        // Get the proxy address
        address proxyAddress = address(slippagePriceChecker);

        // Try to upgrade as non-owner (should fail)
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        SlippagePriceChecker(proxyAddress).upgradeToAndCall(address(newImplementation), "");

        // Upgrade as owner (should succeed)
        vm.prank(owner);
        SlippagePriceChecker(proxyAddress).upgradeToAndCall(address(newImplementation), "");

        // Verify the implementation was upgraded
        // We can check this by verifying the implementation address in the proxy's storage
        // The implementation slot is defined in ERC1967Utils
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address storedImplementation = address(uint160(uint256(vm.load(proxyAddress, implementationSlot))));

        assertEq(storedImplementation, address(newImplementation), "Implementation should be upgraded");
    }

    function testRevertIfChainlinkPriceIsZero() public {
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
            address tokenAddress = addresses.getAddress(rewardToken.token);

            // Mock the latestRoundData call to return zero price
            vm.mockCall(
                addresses.getAddress(rewardToken.priceFeeds[0].priceFeed),
                abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
                abi.encode(
                    uint80(1), // roundId
                    int256(0), // answer (price)
                    uint256(0), // startedAt
                    block.timestamp, // updatedAt
                    uint80(1) // answeredInRound
                )
            );

            // Try to get expected output - should revert
            vm.expectRevert("Chainlink price cannot be lower or equal to 0");
            slippagePriceChecker.getExpectedOut(1e18, tokenAddress, address(underlying));
        }
    }

    function testRevertIfChainlinkRoundIncomplete() public {
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
            address tokenAddress = addresses.getAddress(rewardToken.token);

            // Mock the latestRoundData call to return incomplete round (updatedAt = 0)
            vm.mockCall(
                addresses.getAddress(rewardToken.priceFeeds[0].priceFeed),
                abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
                abi.encode(
                    uint80(1), // roundId
                    int256(1e8), // answer (price)
                    uint256(0), // startedAt
                    uint256(0), // updatedAt (incomplete round)
                    uint80(1) // answeredInRound
                )
            );

            // Try to get expected output - should revert
            vm.expectRevert("Round is in incompleted state");
            slippagePriceChecker.getExpectedOut(1e18, tokenAddress, address(underlying));
        }
    }

    function testRevertIfChainlinkPriceStale() public {
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
            address tokenAddress = addresses.getAddress(rewardToken.token);

            // Mock ALL price feeds for this token to return stale price
            for (uint256 j = 0; j < rewardToken.priceFeeds.length; j++) {
                vm.mockCall(
                    addresses.getAddress(rewardToken.priceFeeds[j].priceFeed),
                    abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
                    abi.encode(
                        uint80(1), // roundId
                        int256(1e8), // answer (price)
                        uint256(0), // startedAt
                        block.timestamp - rewardToken.priceFeeds[j].heartbeat - 1, // updatedAt (stale based on heartbeat)
                        uint80(1) // answeredInRound
                    )
                );
            }

            // Try to get expected output - should revert
            // Use the correct token pair: tokenAddress -> underlying (not well -> underlying)
            vm.expectRevert("Price feed update time exceeds heartbeat");
            slippagePriceChecker.getExpectedOut(1e18, tokenAddress, address(underlying));
        }
    }

    function testIsRewardToken() public {
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            DeployAssetConfig.RewardToken memory rewardToken = assetConfig.rewardTokens[i];
            address tokenAddress = addresses.getAddress(rewardToken.token);

            assertEq(slippagePriceChecker.isRewardToken(tokenAddress), true);
        }

        // random token that is not a reward token
        address randomToken = makeAddr("randomToken");
        assertEq(slippagePriceChecker.isRewardToken(randomToken), false);
    }
}
