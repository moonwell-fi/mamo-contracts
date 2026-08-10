// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {SlippagePriceCheckerOracleHardening} from
    "../multisig/mamo-multisig/013_SlippagePriceCheckerOracleHardening.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {DeployConfig} from "@script/DeployConfig.sol";
import {DeploySlippagePriceChecker} from "@script/DeploySlippagePriceChecker.s.sol";

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";

contract SlippagePriceCheckerTest is BaseTest {
    ISlippagePriceChecker public slippagePriceChecker;

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

    function setUp() public override {
        super.setUp();

        // workaround to make test contract work with mappings
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        // Load asset configuration from environment
        string memory assetConfigPath = vm.envString("ASSET_CONFIG_PATH");
        assetConfig = new DeployAssetConfig(assetConfigPath).getConfig();

        // Get the environment from command line arguments or use default
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));

        DeployConfig configDeploy = new DeployConfig(configPath);
        config = configDeploy.getConfig();

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

            uint256 slippagePriceCheckerOut = slippagePriceChecker.getExpectedOut(
                amountIn, addresses.getAddress(rewardToken.token), address(underlying)
            );

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
            }

            uint256 fromTokenDecimals = 18; // TODO move this to assetConfig
            uint256 toTokenDecimals = assetConfig.decimals;

            // Apply decimal adjustment AFTER all price feed calculations (same as SlippagePriceChecker)
            if (fromTokenDecimals > toTokenDecimals) {
                uint256 divisor = 10 ** (fromTokenDecimals - toTokenDecimals);
                expectedOutFromChainlink = expectedOutFromChainlink / divisor;
            } else if (fromTokenDecimals < toTokenDecimals) {
                uint256 multiplier = 10 ** (toTokenDecimals - fromTokenDecimals);
                expectedOutFromChainlink = expectedOutFromChainlink * multiplier;
            }

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

    /// @notice MOO-726: zero is a legitimate value — it CLEARS the legacy reward-token flag.
    /// @dev This used to revert with "Max time price valid can't be zero", which together with
    ///      removeTokenConfiguration never touching the mapping made the flag a one-way latch: once
    ///      set, a token passed isRewardToken() forever, so consumers kept approving the CoW relayer
    ///      for a token whose oracle configuration had been removed.
    function testMaxTimePriceValidCanBeClearedToZero() public {
        SlippagePriceChecker checker = _upgradeChecker();

        assertGt(checker.maxTimePriceValid(address(well)), 0, "WELL should start with the legacy flag set");

        vm.prank(owner);
        checker.setMaxTimePriceValid(address(well), 0);

        assertEq(checker.maxTimePriceValid(address(well)), 0, "Zero must clear the legacy flag");

        // Only the owner may do it.
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        checker.setMaxTimePriceValid(address(well), 0);
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

    // ========== SHERLOCK AUDIT REGRESSION TESTS ==========
    //
    // CHAINLINK_SWAP_CHECKER_PROXY resolves to the proxy deployed on Base, so every test above runs
    // against the implementation that is live today. The tests below first upgrade that proxy to the
    // implementation compiled from this branch -- exactly the operation these fixes ship as -- so
    // they exercise the new code against the real, already-populated storage.

    function _upgradeChecker() internal returns (SlippagePriceChecker) {
        SlippagePriceChecker newImplementation = new SlippagePriceChecker();

        vm.prank(owner);
        SlippagePriceChecker(address(slippagePriceChecker)).upgradeToAndCall(address(newImplementation), "");

        return SlippagePriceChecker(address(slippagePriceChecker));
    }

    /// @notice MOO-734: the implementation must not be initializable directly.
    function testImplementationInitializersAreDisabled() public {
        SlippagePriceChecker implementation = new SlippagePriceChecker();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        implementation.initialize(attacker);
    }

    /// @notice MOO-726: a pair configured only through addTokenConfiguration must count as a reward token.
    /// @dev isRewardToken() used to read maxTimePriceValid, which addTokenConfiguration never writes.
    ///      Consumers gate approvals on it (MamoMultiMarketStrategy._approveCowSwap, called in a loop
    ///      from initialize(); LPCompoundModule.approveCowSwap), so configuring a reward token the
    ///      modern way made strategy creation revert outright with "Token not allowed".
    function testIsRewardTokenFromPairConfigurationAlone() public {
        SlippagePriceChecker checker = _upgradeChecker();

        // A token the checker has never seen: no pair, no legacy maxTimePriceValid.
        address newRewardToken = makeAddr("freshRewardToken");
        assertEq(checker.maxTimePriceValid(newRewardToken), 0, "Legacy maxTimePriceValid should be unset");
        assertFalse(checker.isRewardToken(newRewardToken), "Unconfigured token is not a reward token");

        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: false,
            heartbeat: 1 days
        });

        // Configure the pair the modern way ONLY -- setMaxTimePriceValid is never called.
        vm.prank(owner);
        checker.addTokenConfiguration(newRewardToken, address(underlying), configs);

        assertEq(checker.maxTimePriceValid(newRewardToken), 0, "Legacy mapping must stay untouched");
        assertTrue(checker.isRewardToken(newRewardToken), "Pair configuration alone must mark a reward token");

        // Removing the only configured pair takes the flag away again.
        vm.prank(owner);
        checker.removeTokenConfiguration(newRewardToken, address(underlying));
        assertFalse(checker.isRewardToken(newRewardToken), "Removing the last pair clears the flag");
    }

    /// @notice MOO-726: tokens configured before the upgrade keep reporting as reward tokens.
    function testIsRewardTokenStillTrueForPreUpgradeConfiguration() public {
        SlippagePriceChecker checker = _upgradeChecker();

        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            address tokenAddress = addresses.getAddress(assetConfig.rewardTokens[i].token);
            assertTrue(checker.isRewardToken(tokenAddress), "Pre-upgrade reward token should stay a reward token");
        }

        assertFalse(checker.isRewardToken(makeAddr("randomToken")), "Random token is not a reward token");
    }

    /// @notice MOO-741: a price answer stamped in the future must be rejected.
    function testRevertIfChainlinkTimestampIsInTheFuture() public {
        SlippagePriceChecker checker = _upgradeChecker();

        vm.mockCall(
            chainlinkWellUsd,
            abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), uint256(0), block.timestamp + 1, uint80(1))
        );

        vm.expectRevert("Price feed update time in the future");
        checker.getExpectedOut(1e18, address(well), address(underlying));
    }

    /// @notice MOO-741: quotes must be refused while the Base sequencer is down or freshly recovered.
    /// @dev A reward-sell order stays valid for up to maxTimePriceValid. If the sequencer drops while
    ///      the market moves and comes back before the feed refreshes, a solver settles against the
    ///      pre-outage answer -- and the configured slippage cannot cap the loss, because slippage is
    ///      measured against that same stale answer.
    function testSequencerUptimeGuard() public {
        SlippagePriceChecker checker = _upgradeChecker();

        MockChainlinkFeed uptimeFeedContract = new MockChainlinkFeed(8);
        address uptimeFeed = address(uptimeFeedContract);
        uint256 gracePeriod = 3600;

        // Unset by default, so an in-place upgrade cannot brick pricing.
        assertEq(checker.sequencerUptimeFeed(), address(0), "Sequencer feed should start unset");
        uint256 quoteWithoutFeed = checker.getExpectedOut(1e18, address(well), address(underlying));
        assertGt(quoteWithoutFeed, 0, "Quote should work while the sequencer check is disabled");

        vm.prank(owner);
        checker.setSequencerUptimeFeed(uptimeFeed, gracePeriod);
        assertEq(checker.sequencerUptimeFeed(), uptimeFeed, "Sequencer feed should be set");
        assertEq(checker.sequencerGracePeriod(), gracePeriod, "Grace period should be set");

        // Sequencer reported down (answer == 1).
        uptimeFeedContract.set(int256(1), block.timestamp - 10, block.timestamp - 10);
        vm.expectRevert("Sequencer is down");
        checker.getExpectedOut(1e18, address(well), address(underlying));

        // Back up, but still inside the grace period.
        uptimeFeedContract.set(int256(0), block.timestamp - (gracePeriod - 1), block.timestamp);
        vm.expectRevert("Sequencer grace period not over");
        checker.getExpectedOut(1e18, address(well), address(underlying));

        // Back up long enough: quotes resume, unchanged.
        uptimeFeedContract.set(int256(0), block.timestamp - gracePeriod, block.timestamp);
        assertEq(
            checker.getExpectedOut(1e18, address(well), address(underlying)),
            quoteWithoutFeed,
            "Quote should be unchanged once the sequencer has recovered"
        );

        // The owner can disable the check again, and only the owner can touch it.
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        checker.setSequencerUptimeFeed(address(0), 0);

        vm.prank(owner);
        checker.setSequencerUptimeFeed(address(0), 0);
        assertEq(checker.sequencerUptimeFeed(), address(0), "Sequencer feed should be cleared");
    }

    /// @notice MOO-741: an answer pinned at an aggregator's boundary must not pass as a price.
    /// @dev Every aggregator behind the feeds used today reports minAnswer = 1 and
    ///      maxAnswer = 2**176 - 1, i.e. representational limits, so nothing can saturate right now.
    ///      A proxy upgrade to an aggregator with ACTIVE finite bounds is what this guards against.
    function testFeedSaneRangeBounds() public {
        SlippagePriceChecker checker = _upgradeChecker();

        (, int256 liveAnswer,,,) = IPriceFeed(chainlinkWellUsd).latestRoundData();
        uint256 answer = uint256(liveAnswer);

        // No bounds configured: nothing changes.
        uint256 quote = checker.getExpectedOut(1e18, address(well), address(underlying));
        assertGt(quote, 0, "Quote should work with no bounds configured");

        vm.prank(owner);
        checker.setFeedBounds(chainlinkWellUsd, answer + 1, answer + 100);
        vm.expectRevert("Chainlink price out of bounds");
        checker.getExpectedOut(1e18, address(well), address(underlying));

        vm.prank(owner);
        checker.setFeedBounds(chainlinkWellUsd, answer / 2, answer * 2);
        assertEq(
            checker.getExpectedOut(1e18, address(well), address(underlying)),
            quote,
            "An in-range answer should quote exactly as before"
        );

        // maxAnswer == 0 clears the bounds; nonsensical ranges are rejected.
        vm.prank(owner);
        vm.expectRevert("Invalid bounds");
        checker.setFeedBounds(chainlinkWellUsd, 10, 10);

        vm.prank(owner);
        checker.setFeedBounds(chainlinkWellUsd, 0, 0);
        (, uint256 maxAnswer) = checker.feedBounds(chainlinkWellUsd);
        assertEq(maxAnswer, 0, "Bounds should be cleared");
    }

    /// @notice MOO-748: hops must not truncate at the sell token's precision.
    /// @dev Every live reward token is 18 decimals, so there is no current exposure. This pins the
    ///      behaviour for a low-precision sell token, where the old implementation discarded up to a
    ///      whole unit at that scale on every hop and later ratios amplified the loss.
    function testLowDecimalSellTokenKeepsFullPrecision() public {
        SlippagePriceChecker checker = _upgradeChecker();

        // A 2-decimal sell token quoted through two hops.
        LowDecimalToken sellToken = new LowDecimalToken();

        // 1 sellToken = 3.00000001 USD, then USD -> underlying at 1.00000003.
        uint256 priceA = 3_00000001; // 8 decimals
        uint256 priceB = 1_00000003; // 8 decimals

        MockChainlinkFeed feedA = new MockChainlinkFeed(8);
        feedA.set(int256(priceA), 1, block.timestamp);
        MockChainlinkFeed feedB = new MockChainlinkFeed(8);
        feedB.set(int256(priceB), 1, block.timestamp);

        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](2);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: address(feedA),
            reverse: false,
            heartbeat: 1 days
        });
        configs[1] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: address(feedB),
            reverse: false,
            heartbeat: 1 days
        });

        vm.prank(owner);
        checker.addTokenConfiguration(address(sellToken), address(underlying), configs);

        uint256 amountIn = 1234; // 12.34 sellToken

        uint256 toDecimals = underlying.decimals();
        // Full-precision reference: amountIn * priceA * priceB, rescaled from 2 to toDecimals, floored.
        uint256 expected = (amountIn * priceA * priceB * (10 ** toDecimals)) / (1e8 * 1e8 * 100);

        assertEq(
            checker.getExpectedOut(amountIn, address(sellToken), address(underlying)),
            expected,
            "Quote should carry full precision through every hop"
        );

        // The pre-fix implementation truncated at the sell token's own scale on each hop.
        uint256 truncatingHops = (amountIn * priceA) / 1e8;
        truncatingHops = (truncatingHops * priceB) / 1e8;
        uint256 legacy =
            toDecimals >= 2 ? truncatingHops * (10 ** (toDecimals - 2)) : truncatingHops / (10 ** (2 - toDecimals));
        assertGt(expected, legacy, "Fixture must actually exercise the truncation the fix removes");
    }

    /// @dev The buy tokens any live pair may be configured against. Mirrors the candidate list the
    ///      release proposal backfills with; the nested pair mapping cannot be enumerated on chain.
    function _candidateBuyTokens() internal view returns (address[] memory buyTokens) {
        buyTokens = new address[](4);
        buyTokens[0] = addresses.getAddress("USDC");
        buyTokens[1] = addresses.getAddress("cbBTC");
        buyTokens[2] = addresses.getAddress("WETH");
        buyTokens[3] = addresses.getAddress("MAMO");
    }

    /// @dev Removes every configured pair for `fromToken` among the candidate buy tokens.
    function _removeAllPairs(SlippagePriceChecker checker, address fromToken) internal returns (uint256 removed) {
        address[] memory buyTokens = _candidateBuyTokens();
        for (uint256 i = 0; i < buyTokens.length; i++) {
            if (checker.tokenPairOracleInformation(fromToken, buyTokens[i]).length == 0) continue;
            vm.prank(owner);
            checker.removeTokenConfiguration(fromToken, buyTokens[i]);
            removed++;
        }
    }

    /// @notice MOO-726: removing the last configured pair must stop the token being a reward token.
    /// @dev `removeTokenConfiguration` never cleared `maxTimePriceValid`, and `setMaxTimePriceValid`
    ///      rejected zero, so the legacy flag was a permanent latch. On chain
    ///      `maxTimePriceValid(MORPHO) == 3600`, so after the owner removed MORPHO's pairs
    ///      `MamoMultiMarketStrategy._approveCowSwap` and `LPCompoundModule.approveCowSwap` still
    ///      passed their "Token not allowed" gate and handed the CoW relayer an allowance for a
    ///      de-configured token.
    function testRemoveLastPairClearsRewardTokenFlag() public {
        SlippagePriceChecker checker = _upgradeChecker();

        // Register the pre-upgrade pairs exactly as the release proposal does, so the counter knows
        // how many pairs are really live. Hoisted: a call in argument position is evaluated first and
        // would consume the prank.
        address[] memory candidates = _candidateBuyTokens();
        vm.prank(owner);
        checker.backfillPairCount(address(morpho), candidates);

        uint256 pairs = checker.configuredPairCount(address(morpho));
        assertGt(pairs, 1, "MORPHO should have more than one live pair for this test to be meaningful");
        assertGt(checker.maxTimePriceValid(address(morpho)), 0, "MORPHO carries the legacy flag on chain");
        assertTrue(checker.isRewardToken(address(morpho)), "MORPHO starts as a reward token");

        // Removing ONE of several pairs must not disarm the token.
        address[] memory buyTokens = _candidateBuyTokens();
        for (uint256 i = 0; i < buyTokens.length; i++) {
            if (checker.tokenPairOracleInformation(address(morpho), buyTokens[i]).length == 0) continue;
            vm.prank(owner);
            checker.removeTokenConfiguration(address(morpho), buyTokens[i]);
            break;
        }
        assertEq(checker.configuredPairCount(address(morpho)), pairs - 1, "One pair should have been removed");
        assertTrue(checker.isRewardToken(address(morpho)), "Still a reward token while other pairs are live");
        assertGt(checker.maxTimePriceValid(address(morpho)), 0, "Legacy flag survives a partial removal");

        // Removing the REST disarms it, legacy flag included.
        _removeAllPairs(checker, address(morpho));

        assertEq(checker.configuredPairCount(address(morpho)), 0, "No pairs should remain");
        assertEq(checker.maxTimePriceValid(address(morpho)), 0, "Legacy flag must be cleared with the last pair");
        assertFalse(checker.isRewardToken(address(morpho)), "A fully de-configured token is not a reward token");
    }

    /// @notice Pre-upgrade pairs must not be able to drive configuredPairCount below the truth.
    /// @dev The counter only ever incremented for pairs added AFTER the upgrade, but the removal path
    ///      decremented for any pair with a non-empty config. Sequence: token X has a pre-upgrade
    ///      pair X->A (count 0); add X->B (count 1); remove X->A (count 0) while X->B is still live.
    ///      With no legacy flag, isRewardToken(X) then reads false for a token that IS configured.
    function testRemovingPreUpgradePairKeepsCountForLivePairs() public {
        SlippagePriceChecker checker = _upgradeChecker();

        // WELL -> underlying is configured on chain, i.e. before this bookkeeping existed.
        assertGt(
            checker.tokenPairOracleInformation(address(well), address(underlying)).length,
            0,
            "WELL -> underlying should be a live pre-upgrade pair"
        );
        assertEq(checker.configuredPairCount(address(well)), 0, "Pre-upgrade pairs contribute nothing to the count");
        assertFalse(checker.pairCounted(address(well), address(underlying)), "Pre-upgrade pair is not counted");

        // Drop the legacy flag so isRewardToken() depends purely on the counter.
        vm.prank(owner);
        checker.setMaxTimePriceValid(address(well), 0);

        // Add a NEW pair the modern way: this one is counted.
        address newBuyToken = makeAddr("newBuyToken");
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: false,
            heartbeat: 1 days
        });
        vm.prank(owner);
        checker.addTokenConfiguration(address(well), newBuyToken, configs);
        assertEq(checker.configuredPairCount(address(well)), 1, "The new pair should be counted");
        assertTrue(checker.isRewardToken(address(well)), "WELL is a reward token through the new pair");

        // Remove the PRE-UPGRADE pair. It never incremented the counter, so it must not decrement it.
        vm.prank(owner);
        checker.removeTokenConfiguration(address(well), address(underlying));

        assertEq(checker.configuredPairCount(address(well)), 1, "Removing an uncounted pair must not decrement");
        assertTrue(checker.isRewardToken(address(well)), "WELL must still be a reward token: WELL -> new is live");
        assertGt(
            checker.tokenPairOracleInformation(address(well), newBuyToken).length, 0, "The new pair is still configured"
        );
    }

    /// @notice Pairs configured before the upgrade need an explicit backfill to enter the counter.
    /// @dev There is no reinitializer and the nested pair mapping cannot be enumerated on chain, so
    ///      without backfillPairCount a pre-upgrade pair reports isRewardToken() == false the moment
    ///      the legacy maxTimePriceValid flag is not set (or is cleared).
    function testBackfillPairCountRegistersPreUpgradePairs() public {
        SlippagePriceChecker checker = _upgradeChecker();

        vm.prank(owner);
        checker.setMaxTimePriceValid(address(well), 0);

        // Live pairs, invisible to the counter, and no legacy flag: reported as not a reward token.
        assertGt(
            checker.tokenPairOracleInformation(address(well), address(underlying)).length, 0, "Pair is live on chain"
        );
        assertEq(checker.configuredPairCount(address(well)), 0, "Counter starts empty for pre-upgrade pairs");
        assertFalse(checker.isRewardToken(address(well)), "Un-backfilled pre-upgrade token reads as not a reward token");

        // Hoisted: a call in argument position is evaluated first and would consume the prank.
        address[] memory candidates = _candidateBuyTokens();

        vm.prank(owner);
        checker.backfillPairCount(address(well), candidates);

        uint256 counted = checker.configuredPairCount(address(well));
        assertGt(counted, 0, "Backfill must register the live pairs");
        assertTrue(checker.pairCounted(address(well), address(underlying)), "The live pair must be marked counted");
        assertTrue(checker.isRewardToken(address(well)), "A backfilled token is a reward token again");

        // Idempotent: running it twice must not double count.
        vm.prank(owner);
        checker.backfillPairCount(address(well), candidates);
        assertEq(checker.configuredPairCount(address(well)), counted, "Backfill must be idempotent");

        // Unconfigured pairs are skipped, and only the owner may backfill.
        address[] memory unconfigured = new address[](1);
        unconfigured[0] = makeAddr("neverConfigured");
        vm.prank(owner);
        checker.backfillPairCount(address(well), unconfigured);
        assertEq(checker.configuredPairCount(address(well)), counted, "Unconfigured pairs must be skipped");

        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        checker.backfillPairCount(address(well), candidates);
    }

    /// @notice MOO-741: the release must leave the sequencer guard ENABLED, not merely deployed.
    /// @dev `_requireSequencerUp()` returns early while `sequencerUptimeFeed == address(0)`, so
    ///      shipping the implementation on its own leaves MOO-741 exactly as unmitigated as before.
    ///      This runs the real proposal end to end and then proves the guard actually bites.
    function testOracleHardeningProposalEnablesSequencerGuard() public {
        SlippagePriceCheckerOracleHardening proposal = new SlippagePriceCheckerOracleHardening();
        proposal.setAddresses(addresses);
        proposal.setPrimaryForkId(vm.activeFork());

        // No pre-check on sequencerUptimeFeed(): the implementation live on Base predates the getter,
        // so calling it before the upgrade reverts. Its storage slot is untouched, i.e. zero, which is
        // exactly the "guard disabled" state the upgrade would land in on its own.
        SlippagePriceChecker checker = SlippagePriceChecker(address(slippagePriceChecker));

        proposal.deploy();
        proposal.build();
        proposal.simulate();
        proposal.validate();

        address uptimeFeed = addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED");
        assertEq(checker.sequencerUptimeFeed(), uptimeFeed, "Release must wire the sequencer uptime feed");
        assertEq(checker.sequencerGracePeriod(), 3600, "Release must set the grace period");

        // The guard is live: quotes work now, and stop the moment the sequencer reports down.
        assertGt(checker.getExpectedOut(1e18, address(well), address(underlying)), 0, "Quotes work with the guard on");

        vm.mockCall(
            uptimeFeed,
            abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), block.timestamp - 10, block.timestamp - 10, uint80(1))
        );
        vm.expectRevert("Sequencer is down");
        checker.getExpectedOut(1e18, address(well), address(underlying));
    }

    /// @notice MOO-748: the upgrade must not loosen any existing quote.
    function testUpgradeDoesNotLowerExistingQuotes() public {
        uint256[] memory before = new uint256[](assetConfig.rewardTokens.length);
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            address tokenAddress = addresses.getAddress(assetConfig.rewardTokens[i].token);
            before[i] =
                slippagePriceChecker.getExpectedOut(amountInByToken[tokenAddress], tokenAddress, address(underlying));
        }

        SlippagePriceChecker checker = _upgradeChecker();

        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            address tokenAddress = addresses.getAddress(assetConfig.rewardTokens[i].token);
            uint256 quote = checker.getExpectedOut(amountInByToken[tokenAddress], tokenAddress, address(underlying));

            // Rounding can only move the quote up (less truncation), never down: a lower expected-out
            // would loosen every slippage floor derived from it.
            assertGe(quote, before[i], "Upgraded quote must not be lower than the live one");
            assertLe(quote - before[i], 1 + before[i] / 1_000_000, "Upgraded quote should differ only by rounding");
        }
    }
}

/// @dev Minimal 2-decimal ERC20 used to exercise low-precision sell tokens.
contract LowDecimalToken is ERC20 {
    constructor() ERC20("Low Decimal", "LOW") {}

    function decimals() public pure override returns (uint8) {
        return 2;
    }
}

/// @dev Settable Chainlink-shaped feed. A real contract rather than vm.mockCall because the checker
///      makes typed calls, and solc's extcodesize guard reverts before a mock on a codeless address
///      is ever consulted.
contract MockChainlinkFeed is IPriceFeed {
    uint8 private immutable _decimals;

    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function set(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (uint80(1), _answer, _startedAt, _updatedAt, uint80(1));
    }
}
