// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployChainlinkSwapChecker} from "../script/DeployChainlinkSwapChecker.s.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {ChainlinkSwapChecker} from "@contracts/ChainlinkSwapChecker.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {ISwapChecker} from "@interfaces/ISwapChecker.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPriceFeed {
    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);
}

contract ChainlinkSwapCheckerTest is Test {
    ChainlinkSwapChecker public swapChecker;
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

        // Deploy the ChainlinkSwapChecker using the script
        DeployChainlinkSwapChecker deployScript = new DeployChainlinkSwapChecker();
        swapChecker = deployScript.deployChainlinkSwapChecker(addresses);

        // Configure tokens with their respective price feeds
        configureTokens();
    }

    function configureTokens() internal {
        // Configure WELL token with WELL/USD price feed
        ISwapChecker.TokenFeedConfiguration[] memory wellConfigs = new ISwapChecker.TokenFeedConfiguration[](1);
        wellConfigs[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: false});

        vm.prank(owner);
        swapChecker.configureToken(address(well), wellConfigs);

        // Configure USDC token with USDC/USD price feed
        ISwapChecker.TokenFeedConfiguration[] memory usdcConfigs = new ISwapChecker.TokenFeedConfiguration[](1);
        usdcConfigs[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkUsdcUsd, reverse: false});

        vm.prank(owner);
        swapChecker.configureToken(address(usdc), usdcConfigs);
    }

    function testInitialState() public view {
        // Check initial slippage
        assertEq(swapChecker.ALLOWED_SLIPPAGE_IN_BPS(), INITIAL_SLIPPAGE, "Initial slippage should be set correctly");

        // Check owner
        assertEq(swapChecker.owner(), owner, "Owner should be set correctly");
    }

    function testTokenConfiguration() public view {
        // Verify WELL token configuration
        ISwapChecker.TokenFeedConfiguration[] memory wellConfigs = swapChecker.tokenOracleInformation(address(well));
        assertEq(wellConfigs.length, 1, "WELL should have 1 configuration");
        assertEq(wellConfigs[0].chainlinkFeed, chainlinkWellUsd, "WELL price feed should match");
        assertEq(wellConfigs[0].reverse, false, "WELL reverse flag should match");

        // Verify USDC token configuration
        ISwapChecker.TokenFeedConfiguration[] memory usdcConfigs = swapChecker.tokenOracleInformation(address(usdc));
        assertEq(usdcConfigs.length, 1, "USDC should have 1 configuration");
        assertEq(usdcConfigs[0].chainlinkFeed, chainlinkUsdcUsd, "USDC price feed should match");
        assertEq(usdcConfigs[0].reverse, false, "USDC reverse flag should match");
    }

    function testReconfigureToken() public {
        // Create a new configuration for WELL token
        ISwapChecker.TokenFeedConfiguration[] memory newConfigs = new ISwapChecker.TokenFeedConfiguration[](1);
        newConfigs[0] = ISwapChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkWellUsd,
            reverse: true // Change the reverse flag
        });

        vm.prank(owner);
        swapChecker.configureToken(address(well), newConfigs);

        // Verify the token configuration was updated
        ISwapChecker.TokenFeedConfiguration[] memory updatedConfigs = swapChecker.tokenOracleInformation(address(well));
        assertEq(updatedConfigs.length, 1, "WELL should still have 1 configuration");
        assertEq(updatedConfigs[0].chainlinkFeed, chainlinkWellUsd, "WELL price feed should remain the same");
        assertEq(updatedConfigs[0].reverse, true, "WELL reverse flag should be updated");
    }

    function testSetSlippage() public {
        uint256 newSlippage = 200; // 2%

        vm.prank(owner);
        swapChecker.setSlippage(newSlippage);

        assertEq(swapChecker.ALLOWED_SLIPPAGE_IN_BPS(), newSlippage, "Slippage should be updated");
    }

    function testGetExpectedOut() public view {
        // Get the expected output from the swap checker
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 swapCheckerOut = swapChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // Verify the output is non-zero
        assertTrue(swapCheckerOut > 0, "Expected output should be greater than zero");
    }

    function testCheckPrice() public view {
        // Get the expected output for 1 WELL to USDC
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = swapChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // Calculate the minimum acceptable output with slippage
        // The contract checks if minOut > (expectedOut * (MAX_BPS - ALLOWED_SLIPPAGE_IN_BPS)) / MAX_BPS
        // So we need to set minOut to a value that is less than expectedOut but greater than the minimum
        uint256 minOut = (expectedOut * (MAX_BPS - INITIAL_SLIPPAGE + 10)) / MAX_BPS;

        // Check if the price is acceptable
        bool result = swapChecker.checkPrice(amountIn, address(well), address(usdc), minOut);

        assertTrue(result, "Price check should pass with acceptable slippage");
    }

    function testCheckPriceFail() public view {
        // Get the expected output for 1 WELL to USDC
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = swapChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // Calculate a minimum output that's too low (below allowed slippage)
        // The contract checks if minOut > (expectedOut * (MAX_BPS - ALLOWED_SLIPPAGE_IN_BPS)) / MAX_BPS
        // So we need to set minOut to a value that is less than the minimum
        uint256 minOut = (expectedOut * (MAX_BPS - INITIAL_SLIPPAGE - 10)) / MAX_BPS;

        // Check if the price is acceptable (should fail)
        bool result = swapChecker.checkPrice(amountIn, address(well), address(usdc), minOut);

        assertFalse(result, "Price check should fail with too much slippage");
    }

    function testRevertIfNonOwnerConfigureToken() public {
        address nonOwner = makeAddr("nonOwner");

        ISwapChecker.TokenFeedConfiguration[] memory configs = new ISwapChecker.TokenFeedConfiguration[](1);
        configs[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: false});

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        swapChecker.configureToken(address(well), configs);
    }

    function testRevertIfNonOwnerSetSlippage() public {
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        swapChecker.setSlippage(200);
    }

    function testRevertIfInvalidSlippage() public {
        uint256 invalidSlippage = 10001; // > 100%

        vm.prank(owner);
        vm.expectRevert("Slippage exceeds maximum");
        swapChecker.setSlippage(invalidSlippage);
    }

    function testRevertIfZeroTokenAddress() public {
        ISwapChecker.TokenFeedConfiguration[] memory configs = new ISwapChecker.TokenFeedConfiguration[](1);
        configs[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: false});

        vm.prank(owner);
        vm.expectRevert("Invalid token address");
        swapChecker.configureToken(address(0), configs);
    }

    function testRevertIfZeroPriceFeedAddress() public {
        ISwapChecker.TokenFeedConfiguration[] memory configs = new ISwapChecker.TokenFeedConfiguration[](1);
        configs[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: address(0), reverse: false});

        vm.prank(owner);
        vm.expectRevert("Invalid chainlink feed address");
        swapChecker.configureToken(address(well), configs);
    }

    function testConfigureTokenWithEmptyArrayRemovesConfiguration() public {
        // First, verify that the token is configured
        ISwapChecker.TokenFeedConfiguration[] memory initialConfigs = swapChecker.tokenOracleInformation(address(well));
        assertEq(initialConfigs.length, 1, "WELL should have 1 configuration initially");

        // Call configureToken with an empty array
        ISwapChecker.TokenFeedConfiguration[] memory emptyConfigs = new ISwapChecker.TokenFeedConfiguration[](0);

        vm.prank(owner);
        swapChecker.configureToken(address(well), emptyConfigs);

        // Verify that the token configuration has been removed
        vm.expectRevert("Token not configured");
        swapChecker.getExpectedOut(1 * 10 ** 18, address(well), address(usdc));

        // Try to get the token configuration - should return an empty array
        ISwapChecker.TokenFeedConfiguration[] memory finalConfigs = swapChecker.tokenOracleInformation(address(well));
        assertEq(finalConfigs.length, 0, "WELL should have no configurations after removal");
    }

    function testRevertIfTokenNotConfigured() public {
        // Create a new token address that hasn't been configured
        address unconfiguredToken = makeAddr("unconfiguredToken");

        vm.expectRevert("Token not configured");
        swapChecker.getExpectedOut(1 * 10 ** 18, unconfiguredToken, address(usdc));

        vm.expectRevert("Token not configured");
        swapChecker.checkPrice(1 * 10 ** 18, unconfiguredToken, address(usdc), 1 * 10 ** 6);
    }

    function testConfigureTokenWithMultipleFeeds() public {
        // Configure WELL token with multiple price feeds (WELL/USD and then USD/USDC)
        ISwapChecker.TokenFeedConfiguration[] memory configs = new ISwapChecker.TokenFeedConfiguration[](2);
        configs[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: false});
        configs[1] = ISwapChecker.TokenFeedConfiguration({
            chainlinkFeed: chainlinkUsdcUsd,
            reverse: true // Reverse to get USD/USDC
        });

        vm.prank(owner);
        swapChecker.configureToken(address(well), configs);

        // Verify the token configuration
        ISwapChecker.TokenFeedConfiguration[] memory storedConfigs = swapChecker.tokenOracleInformation(address(well));
        assertEq(storedConfigs.length, 2, "WELL should have 2 configurations");
        assertEq(storedConfigs[0].chainlinkFeed, chainlinkWellUsd, "First price feed should match");
        assertEq(storedConfigs[0].reverse, false, "First reverse flag should match");
        assertEq(storedConfigs[1].chainlinkFeed, chainlinkUsdcUsd, "Second price feed should match");
        assertEq(storedConfigs[1].reverse, true, "Second reverse flag should match");

        // Test the expected output with the new configuration
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = swapChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // The expected output should be non-zero
        assertTrue(expectedOut > 0, "Expected output should be greater than zero");
    }

    function testGetExpectedOutWithReverseFlag() public {
        // Configure WELL token with reverse flag
        ISwapChecker.TokenFeedConfiguration[] memory configs = new ISwapChecker.TokenFeedConfiguration[](1);
        configs[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: chainlinkWellUsd, reverse: true});

        vm.prank(owner);
        swapChecker.configureToken(address(well), configs);

        // Get the expected output from the swap checker
        uint256 amountIn = 1 * 10 ** 18; // 1 WELL
        uint256 expectedOut = swapChecker.getExpectedOut(amountIn, address(well), address(usdc));

        // Verify the output is non-zero
        assertTrue(expectedOut > 0, "Expected output should be greater than zero");
    }
}
