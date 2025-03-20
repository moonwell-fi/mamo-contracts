// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeploySlippagePriceChecker} from "../script/DeploySlippagePriceChecker.s.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPriceFeed {
    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);
}

contract SlippagePriceCheckerTest is Test {
    SlippagePriceChecker public slippagePriceChecker;
    Addresses public addresses;

    // Contracts from Base network
    ERC20 public usdc;
    ERC20 public well;
    address public owner;
    address public chainlinkWellUsd;
    address public chainlinkUsdcUsd;

    // Constants
    uint256 public constant INITIAL_SLIPPAGE = 100; // 1%
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant DEFAULT_MAX_TIME_PRICE_VALID = 3600; // 1 hour in seconds

    function setUp() public {
        // Initialize addresses
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get the addresses from the addresses contract
        owner = addresses.getAddress("MAMO_MULTISIG");
        usdc = ERC20(addresses.getAddress("USDC"));
        well = ERC20(addresses.getAddress("xWELL_PROXY"));
        chainlinkWellUsd = addresses.getAddress("CHAINLINK_WELL_USD");
        chainlinkUsdcUsd = addresses.getAddress("CHAINLINK_USDC_USD");

        // Deploy the SlippagePriceChecker using the script
        DeploySlippagePriceChecker deployScript = new DeploySlippagePriceChecker();
        slippagePriceChecker = deployScript.deploySlippagePriceChecker(addresses);

        // Configure tokens with their respective price feeds
        addTokenConfigurations();
    }

    function addTokenConfigurations() internal {
        // Configure WELL token with WELL/USD price feed
        ISlippagePriceChecker.TokenFeedConfiguration[] memory wellConfigs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        wellConfigs[0] = ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: false});

        vm.prank(owner);
        slippagePriceChecker.addTokenConfiguration(address(well), wellConfigs, DEFAULT_MAX_TIME_PRICE_VALID);

        // Configure USDC token with USDC/USD price feed
        ISlippagePriceChecker.TokenFeedConfiguration[] memory usdcConfigs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        usdcConfigs[0] = ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkUsdcUsd, reverse: false});

        vm.prank(owner);
        slippagePriceChecker.addTokenConfiguration(address(usdc), usdcConfigs, DEFAULT_MAX_TIME_PRICE_VALID);
    }

    function testInitialState() public view {
        // Check owner
        assertEq(slippagePriceChecker.owner(), owner, "Owner should be set correctly");
    }

    function testTokenConfiguration() public view {
        // Verify WELL token configuration
        ISlippagePriceChecker.TokenFeedConfiguration[] memory wellConfigs =
            slippagePriceChecker.tokenOracleInformation(address(well));
        assertEq(wellConfigs.length, 1, "WELL should have 1 configuration");
        assertEq(wellConfigs[0].chainlinkFeed, chainlinkWellUsd, "WELL price feed should match");
        assertEq(wellConfigs[0].reverse, false, "WELL reverse flag should match");
        assertEq(
            slippagePriceChecker.maxTimePriceValid(address(well)),
            DEFAULT_MAX_TIME_PRICE_VALID,
            "WELL maxTimePriceValid should match"
        );

        // Verify USDC token configuration
        ISlippagePriceChecker.TokenFeedConfiguration[] memory usdcConfigs =
            slippagePriceChecker.tokenOracleInformation(address(usdc));
        assertEq(usdcConfigs.length, 1, "USDC should have 1 configuration");
        assertEq(usdcConfigs[0].chainlinkFeed, chainlinkUsdcUsd, "USDC price feed should match");
        assertEq(usdcConfigs[0].reverse, false, "USDC reverse flag should match");
        assertEq(
            slippagePriceChecker.maxTimePriceValid(address(usdc)),
            DEFAULT_MAX_TIME_PRICE_VALID,
            "USDC maxTimePriceValid should match"
        );
    }

    function testUpdateMaxTimePriceValid() public {
        // Create a new configuration for WELL token with a different maxTimePriceValid
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: false});

        uint256 newMaxTimePriceValid = 7200; // 2 hours in seconds

        // First remove the existing configuration
        vm.prank(owner);
        slippagePriceChecker.removeTokenConfiguration(address(well));

        // Then add the new configuration with updated maxTimePriceValid
        vm.prank(owner);
        slippagePriceChecker.addTokenConfiguration(address(well), configs, newMaxTimePriceValid);

        // Verify the maxTimePriceValid was updated
        assertEq(
            slippagePriceChecker.maxTimePriceValid(address(well)),
            newMaxTimePriceValid,
            "WELL maxTimePriceValid should be updated"
        );
    }

    function testReaddTokenConfiguration() public {
        // Create a new configuration for WELL token
        ISlippagePriceChecker.TokenFeedConfiguration[] memory newConfigs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        newConfigs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: true // Change the reverse flag
        });

        // First remove the existing configuration
        vm.prank(owner);
        slippagePriceChecker.removeTokenConfiguration(address(well));

        // Then add the new configuration
        vm.prank(owner);
        slippagePriceChecker.addTokenConfiguration(address(well), newConfigs, DEFAULT_MAX_TIME_PRICE_VALID);

        // Verify the token configuration was updated
        ISlippagePriceChecker.TokenFeedConfiguration[] memory updatedConfigs =
            slippagePriceChecker.tokenOracleInformation(address(well));
        assertEq(updatedConfigs.length, 1, "WELL should still have 1 configuration");
        assertEq(updatedConfigs[0].chainlinkFeed, chainlinkWellUsd, "WELL price feed should remain the same");
        assertEq(updatedConfigs[0].reverse, true, "WELL reverse flag should be updated");
    }

    function testGetExpectedOut() public view {
        // Get the expected output from the swap checker
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 slippagePriceCheckerOut = slippagePriceChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // Verify the output is non-zero
        assertTrue(slippagePriceCheckerOut > 0, "Expected output should be greater than zero");
    }

    function testCheckPrice() public view {
        // Get the expected output for 1 WELL to USDC
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // Calculate the minimum acceptable output with slippage
        // The contract checks if minOut > (expectedOut * (MAX_BPS - slippage)) / MAX_BPS
        // So we need to set minOut to a value that is less than expectedOut but greater than the minimum
        uint256 minOut = (expectedOut * (MAX_BPS - INITIAL_SLIPPAGE + 10)) / MAX_BPS;

        // Check if the price is acceptable
        bool result = slippagePriceChecker.checkPrice(amountIn, address(well), address(usdc), minOut, INITIAL_SLIPPAGE);

        assertTrue(result, "Price check should pass with acceptable slippage");
    }

    function testCheckPriceFail() public view {
        // Get the expected output for 1 WELL to USDC
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // Calculate a minimum output that's too low (below allowed slippage)
        // The contract checks if minOut > (expectedOut * (MAX_BPS - slippage)) / MAX_BPS
        // So we need to set minOut to a value that is less than the minimum
        uint256 minOut = (expectedOut * (MAX_BPS - INITIAL_SLIPPAGE - 10)) / MAX_BPS;

        // Check if the price is acceptable (should fail)
        bool result = slippagePriceChecker.checkPrice(amountIn, address(well), address(usdc), minOut, INITIAL_SLIPPAGE);

        assertFalse(result, "Price check should fail with too much slippage");
    }

    function testRevertIfNonOwnerAddTokenConfiguration() public {
        address nonOwner = makeAddr("nonOwner");

        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: false});

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        slippagePriceChecker.addTokenConfiguration(address(well), configs, DEFAULT_MAX_TIME_PRICE_VALID);
    }

    function testRevertIfNonOwnerRemoveTokenConfiguration() public {
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        slippagePriceChecker.removeTokenConfiguration(address(well));
    }

    function testRevertIfZeroTokenAddress() public {
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: false});

        vm.prank(owner);
        vm.expectRevert("Invalid token address");
        slippagePriceChecker.addTokenConfiguration(address(0), configs, DEFAULT_MAX_TIME_PRICE_VALID);
    }

    function testRevertIfZeroPriceFeedAddress() public {
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: address(0), reverse: false});

        vm.prank(owner);
        vm.expectRevert("Invalid chainlink feed address");
        slippagePriceChecker.addTokenConfiguration(address(well), configs, DEFAULT_MAX_TIME_PRICE_VALID);
    }

    function testRemoveTokenConfiguration() public {
        // First, verify that the token is configured
        ISlippagePriceChecker.TokenFeedConfiguration[] memory initialConfigs =
            slippagePriceChecker.tokenOracleInformation(address(well));
        assertEq(initialConfigs.length, 1, "WELL should have 1 configuration initially");

        // Call removeTokenConfiguration
        vm.prank(owner);
        slippagePriceChecker.removeTokenConfiguration(address(well));

        // Verify that the token configuration has been removed
        vm.expectRevert("Token not configured");
        slippagePriceChecker.getExpectedOut(1 * 10 ** 18, address(well), address(usdc));

        // Try to get the token configuration - should return an empty array
        ISlippagePriceChecker.TokenFeedConfiguration[] memory finalConfigs =
            slippagePriceChecker.tokenOracleInformation(address(well));
        assertEq(finalConfigs.length, 0, "WELL should have no configurations after removal");
    }

    function testRevertIfEmptyConfigurationsArray() public {
        // Create an empty configurations array
        ISlippagePriceChecker.TokenFeedConfiguration[] memory emptyConfigs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](0);

        vm.prank(owner);
        vm.expectRevert("Empty configurations array");
        slippagePriceChecker.addTokenConfiguration(address(well), emptyConfigs, DEFAULT_MAX_TIME_PRICE_VALID);
    }

    function testRevertIfTokenNotConfigured() public {
        // Create a new token address that hasn't been configured
        address unconfiguredToken = makeAddr("unconfiguredToken");

        vm.expectRevert("Token not configured");
        slippagePriceChecker.getExpectedOut(1 * 10 ** 18, unconfiguredToken, address(usdc));

        vm.expectRevert("Token not configured");
        slippagePriceChecker.checkPrice(1 * 10 ** 18, unconfiguredToken, address(usdc), 1 * 10 ** 6, INITIAL_SLIPPAGE);
    }

    function testAddTokenConfigurationWithMultipleFeeds() public {
        // Configure WELL token with multiple price feeds (WELL/USD and then USD/USDC)
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](2);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: false});
        configs[1] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkUsdcUsd,
            reverse: true // Reverse to get USD/USDC
        });

        // First remove the existing configuration
        vm.prank(owner);
        slippagePriceChecker.removeTokenConfiguration(address(well));

        // Then add the new configuration
        vm.prank(owner);
        slippagePriceChecker.addTokenConfiguration(address(well), configs, DEFAULT_MAX_TIME_PRICE_VALID);

        // Verify the token configuration
        ISlippagePriceChecker.TokenFeedConfiguration[] memory storedConfigs =
            slippagePriceChecker.tokenOracleInformation(address(well));
        assertEq(storedConfigs.length, 2, "WELL should have 2 configurations");
        assertEq(storedConfigs[0].chainlinkFeed, chainlinkWellUsd, "First price feed should match");
        assertEq(storedConfigs[0].reverse, false, "First reverse flag should match");
        assertEq(storedConfigs[1].chainlinkFeed, chainlinkUsdcUsd, "Second price feed should match");
        assertEq(storedConfigs[1].reverse, true, "Second reverse flag should match");

        // Test the expected output with the new configuration
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // The expected output should be non-zero
        assertTrue(expectedOut > 0, "Expected output should be greater than zero");
    }

    function testGetExpectedOutWithReverseFlag() public {
        // Configure WELL token with reverse flag
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: true});

        // First remove the existing configuration
        vm.prank(owner);
        slippagePriceChecker.removeTokenConfiguration(address(well));

        // Then add the new configuration
        vm.prank(owner);
        slippagePriceChecker.addTokenConfiguration(address(well), configs, DEFAULT_MAX_TIME_PRICE_VALID);

        // Get the expected output from the swap checker
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // Verify the output is non-zero
        assertTrue(expectedOut > 0, "Expected output should be greater than zero");
    }
}
