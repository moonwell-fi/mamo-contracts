// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {FeeSplitter} from "@contracts/FeeSplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployFeeSplitter} from "@script/DeployFeeSplitter.s.sol";

contract FeeSplitterIntegrationTest is BaseTest, DeployFeeSplitter {
    FeeSplitter public feeSplitter;
    IERC20 public token0;
    IERC20 public token1;

    address public recipient1;
    address public recipient2;

    // Test amounts
    uint256 constant INITIAL_TOKEN0_AMOUNT = 1000e18;
    uint256 constant INITIAL_TOKEN1_AMOUNT = 500e18;
    uint256 constant EXPECTED_RECIPIENT1_SHARE_TOKEN0 = 300e18; // 30% of 1000
    uint256 constant EXPECTED_RECIPIENT2_SHARE_TOKEN0 = 700e18; // 70% of 1000
    uint256 constant EXPECTED_RECIPIENT1_SHARE_TOKEN1 = 150e18; // 30% of 500
    uint256 constant EXPECTED_RECIPIENT2_SHARE_TOKEN1 = 350e18; // 70% of 500

    // Events
    event FeesSplit(address indexed token, uint256 recipient1Amount, uint256 recipient2Amount);

    function setUp() public override {
        super.setUp();

        // Check if FeeSplitter already exists, otherwise deploy it
        if (addresses.isAddressSet("FEE_SPLITTER")) {
            feeSplitter = FeeSplitter(addresses.getAddress("FEE_SPLITTER"));
        } else {
            // Deploy FeeSplitter via the deploy script
            feeSplitter = deployFeeSplitter(addresses);
        }

        // Get the real token contracts from the deployed FeeSplitter
        token0 = IERC20(feeSplitter.TOKEN_0());
        token1 = IERC20(feeSplitter.TOKEN_1());

        // Get recipients from the deployed FeeSplitter
        recipient1 = feeSplitter.RECIPIENT_1();
        recipient2 = feeSplitter.RECIPIENT_2();
    }

    function testInitialization() public view {
        assertEq(feeSplitter.TOKEN_0(), address(token0), "incorrect TOKEN_0");
        assertEq(feeSplitter.TOKEN_1(), address(token1), "incorrect TOKEN_1");
        assertEq(feeSplitter.RECIPIENT_1(), recipient1, "incorrect RECIPIENT_1");
        assertEq(feeSplitter.RECIPIENT_2(), recipient2, "incorrect RECIPIENT_2");
        assertEq(feeSplitter.RECIPIENT_1_SHARE(), 3000, "incorrect RECIPIENT_1_SHARE");
        assertEq(feeSplitter.RECIPIENT_2_SHARE(), 7000, "incorrect RECIPIENT_2_SHARE");
    }

    function testConstructorValidation() public {
        // Create test addresses for validation
        address testRecipient1 = makeAddr("testRecipient1");
        address testRecipient2 = makeAddr("testRecipient2");

        // Test zero address validation
        vm.expectRevert("TOKEN_0 cannot be zero address");
        new FeeSplitter(address(0), address(token1), testRecipient1, testRecipient2, 7000);

        vm.expectRevert("TOKEN_1 cannot be zero address");
        new FeeSplitter(address(token0), address(0), testRecipient1, testRecipient2, 7000);

        vm.expectRevert("RECIPIENT_1 cannot be zero address");
        new FeeSplitter(address(token0), address(token1), address(0), testRecipient2, 7000);

        vm.expectRevert("RECIPIENT_2 cannot be zero address");
        new FeeSplitter(address(token0), address(token1), testRecipient1, address(0), 7000);

        // Test same token validation
        vm.expectRevert("Tokens must be different");
        new FeeSplitter(address(token0), address(token0), testRecipient1, testRecipient2, 7000);

        // Test same recipient validation
        vm.expectRevert("Recipients must be different");
        new FeeSplitter(address(token0), address(token1), testRecipient1, testRecipient1, 7000);

        // Test split ratio validation
        vm.expectRevert("Split A cannot exceed 10000 basis points");
        new FeeSplitter(address(token0), address(token1), testRecipient1, testRecipient2, 10001);
    }

    function testCustomSplitRatios() public {
        // Test different split ratios
        address testRecipient1 = makeAddr("testRecipient1");
        address testRecipient2 = makeAddr("testRecipient2");

        // Test 50/50 split
        FeeSplitter splitter50_50 =
            new FeeSplitter(address(token0), address(token1), testRecipient1, testRecipient2, 5000);
        assertEq(splitter50_50.RECIPIENT_1_SHARE(), 5000, "incorrect 50/50 split for recipient1");
        assertEq(splitter50_50.RECIPIENT_2_SHARE(), 5000, "incorrect 50/50 split for recipient2");

        // Test 80/20 split
        FeeSplitter splitter80_20 =
            new FeeSplitter(address(token0), address(token1), testRecipient1, testRecipient2, 8000);
        assertEq(splitter80_20.RECIPIENT_1_SHARE(), 8000, "incorrect 80/20 split for recipient1");
        assertEq(splitter80_20.RECIPIENT_2_SHARE(), 2000, "incorrect 80/20 split for recipient2");

        // Test 0/100 split (all to recipient2)
        FeeSplitter splitter0_100 = new FeeSplitter(address(token0), address(token1), testRecipient1, testRecipient2, 0);
        assertEq(splitter0_100.RECIPIENT_1_SHARE(), 0, "incorrect 0/100 split for recipient1");
        assertEq(splitter0_100.RECIPIENT_2_SHARE(), 10000, "incorrect 0/100 split for recipient2");

        // Test 100/0 split (all to recipient1)
        FeeSplitter splitter100_0 =
            new FeeSplitter(address(token0), address(token1), testRecipient1, testRecipient2, 10000);
        assertEq(splitter100_0.RECIPIENT_1_SHARE(), 10000, "incorrect 100/0 split for recipient1");
        assertEq(splitter100_0.RECIPIENT_2_SHARE(), 0, "incorrect 100/0 split for recipient2");
    }

    function testSplitWithBothTokens() public {
        // Setup: Deal tokens to the fee splitter contract
        deal(address(token0), address(feeSplitter), INITIAL_TOKEN0_AMOUNT);
        deal(address(token1), address(feeSplitter), INITIAL_TOKEN1_AMOUNT);

        // Verify initial balances
        assertEq(token0.balanceOf(address(feeSplitter)), INITIAL_TOKEN0_AMOUNT, "incorrect initial TOKEN_0 balance");
        assertEq(token1.balanceOf(address(feeSplitter)), INITIAL_TOKEN1_AMOUNT, "incorrect initial TOKEN_1 balance");

        // Record pre-split balances
        uint256 recipient1Token0Before = token0.balanceOf(recipient1);
        uint256 recipient2Token0Before = token0.balanceOf(recipient2);
        uint256 recipient1Token1Before = token1.balanceOf(recipient1);
        uint256 recipient2Token1Before = token1.balanceOf(recipient2);

        // Expect events
        vm.expectEmit(true, false, false, true);
        emit FeesSplit(address(token0), EXPECTED_RECIPIENT1_SHARE_TOKEN0, EXPECTED_RECIPIENT2_SHARE_TOKEN0);

        vm.expectEmit(true, false, false, true);
        emit FeesSplit(address(token1), EXPECTED_RECIPIENT1_SHARE_TOKEN1, EXPECTED_RECIPIENT2_SHARE_TOKEN1);

        // Execute split
        feeSplitter.split();

        // Verify TOKEN_0 distributions
        assertEq(
            token0.balanceOf(recipient1),
            recipient1Token0Before + EXPECTED_RECIPIENT1_SHARE_TOKEN0,
            "incorrect TOKEN_0 balance for recipient1"
        );
        assertEq(
            token0.balanceOf(recipient2),
            recipient2Token0Before + EXPECTED_RECIPIENT2_SHARE_TOKEN0,
            "incorrect TOKEN_0 balance for recipient2"
        );

        // Verify TOKEN_1 distributions
        assertEq(
            token1.balanceOf(recipient1),
            recipient1Token1Before + EXPECTED_RECIPIENT1_SHARE_TOKEN1,
            "incorrect TOKEN_1 balance for recipient1"
        );
        assertEq(
            token1.balanceOf(recipient2),
            recipient2Token1Before + EXPECTED_RECIPIENT2_SHARE_TOKEN1,
            "incorrect TOKEN_1 balance for recipient2"
        );

        // Verify contract balances are zero
        assertEq(token0.balanceOf(address(feeSplitter)), 0, "TOKEN_0 should be fully distributed");
        assertEq(token1.balanceOf(address(feeSplitter)), 0, "TOKEN_1 should be fully distributed");
    }

    function testSplitWithOnlyToken0() public {
        // Setup: Deal only TOKEN_0 to the fee splitter contract
        deal(address(token0), address(feeSplitter), INITIAL_TOKEN0_AMOUNT);

        // Record pre-split balances
        uint256 recipient1Token0Before = token0.balanceOf(recipient1);
        uint256 recipient2Token0Before = token0.balanceOf(recipient2);
        uint256 recipient1Token1Before = token1.balanceOf(recipient1);
        uint256 recipient2Token1Before = token1.balanceOf(recipient2);

        // Expect only TOKEN_0 event (TOKEN_1 has zero balance, so no event)
        vm.expectEmit(true, false, false, true);
        emit FeesSplit(address(token0), EXPECTED_RECIPIENT1_SHARE_TOKEN0, EXPECTED_RECIPIENT2_SHARE_TOKEN0);

        // Execute split
        feeSplitter.split();

        // Verify TOKEN_0 distributions
        assertEq(
            token0.balanceOf(recipient1),
            recipient1Token0Before + EXPECTED_RECIPIENT1_SHARE_TOKEN0,
            "incorrect TOKEN_0 balance for recipient1"
        );
        assertEq(
            token0.balanceOf(recipient2),
            recipient2Token0Before + EXPECTED_RECIPIENT2_SHARE_TOKEN0,
            "incorrect TOKEN_0 balance for recipient2"
        );

        // Verify TOKEN_1 balances remain unchanged (no TOKEN_1 was in the splitter contract)
        assertEq(
            token1.balanceOf(recipient1),
            recipient1Token1Before,
            "TOKEN_1 balance should remain unchanged for recipient1"
        );
        assertEq(
            token1.balanceOf(recipient2),
            recipient2Token1Before,
            "TOKEN_1 balance should remain unchanged for recipient2"
        );

        // Verify contract balances
        assertEq(token0.balanceOf(address(feeSplitter)), 0, "TOKEN_0 should be fully distributed");
        assertEq(token1.balanceOf(address(feeSplitter)), 0, "TOKEN_1 should remain zero");
    }

    function testSplitWithZeroBalances() public {
        // Record initial balances before split
        uint256 recipient1Token0Before = token0.balanceOf(recipient1);
        uint256 recipient2Token0Before = token0.balanceOf(recipient2);
        uint256 recipient1Token1Before = token1.balanceOf(recipient1);
        uint256 recipient2Token1Before = token1.balanceOf(recipient2);

        // Execute split with zero balances in the splitter contract (should not revert)
        feeSplitter.split();

        // Verify balances remain unchanged (no tokens were in the splitter to split)
        assertEq(
            token0.balanceOf(recipient1), recipient1Token0Before, "recipient1 TOKEN_0 balance should remain unchanged"
        );
        assertEq(
            token0.balanceOf(recipient2), recipient2Token0Before, "recipient2 TOKEN_0 balance should remain unchanged"
        );
        assertEq(
            token1.balanceOf(recipient1), recipient1Token1Before, "recipient1 TOKEN_1 balance should remain unchanged"
        );
        assertEq(
            token1.balanceOf(recipient2), recipient2Token1Before, "recipient2 TOKEN_1 balance should remain unchanged"
        );
        assertEq(token0.balanceOf(address(feeSplitter)), 0, "feeSplitter TOKEN_0 balance should remain zero");
        assertEq(token1.balanceOf(address(feeSplitter)), 0, "feeSplitter TOKEN_1 balance should remain zero");
    }

    function testSplitWithSmallAmounts() public {
        // Test with small amounts that might have rounding issues
        uint256 smallAmount = 3; // Will result in 2.1 and 0.9, which rounds to 2 and 1

        // Record initial balances
        uint256 recipient1Token0Before = token0.balanceOf(recipient1);
        uint256 recipient2Token0Before = token0.balanceOf(recipient2);

        deal(address(token0), address(feeSplitter), smallAmount);

        // Execute split
        feeSplitter.split();

        // With integer division: 3 * 3000 / 10000 = 0, remainder = 3
        assertEq(token0.balanceOf(recipient1), recipient1Token0Before + 0, "recipient1 should get 0 additional tokens");
        assertEq(
            token0.balanceOf(recipient2),
            recipient2Token0Before + 3,
            "recipient2 should get 3 additional tokens (remainder)"
        );
        assertEq(token0.balanceOf(address(feeSplitter)), 0, "all tokens should be distributed");
    }

    function testMultipleSplits() public {
        // Record initial balances
        uint256 recipient1Token0Initial = token0.balanceOf(recipient1);
        uint256 recipient2Token0Initial = token0.balanceOf(recipient2);
        uint256 recipient1Token1Initial = token1.balanceOf(recipient1);
        uint256 recipient2Token1Initial = token1.balanceOf(recipient2);

        // Test multiple split operations
        for (uint256 i = 0; i < 3; i++) {
            // Deal tokens
            deal(address(token0), address(feeSplitter), 100e18);
            deal(address(token1), address(feeSplitter), 50e18);

            // Execute split
            feeSplitter.split();

            // Verify contract is empty after each split
            assertEq(token0.balanceOf(address(feeSplitter)), 0, "TOKEN_0 should be empty after split");
            assertEq(token1.balanceOf(address(feeSplitter)), 0, "TOKEN_1 should be empty after split");
        }

        // Verify total accumulated amounts (initial + 3 splits of 100/50 tokens each)
        assertEq(
            token0.balanceOf(recipient1),
            recipient1Token0Initial + 90e18,
            "recipient1 should have initial + 30% of 300 TOKEN_0"
        );
        assertEq(
            token0.balanceOf(recipient2),
            recipient2Token0Initial + 210e18,
            "recipient2 should have initial + 70% of 300 TOKEN_0"
        );
        assertEq(
            token1.balanceOf(recipient1),
            recipient1Token1Initial + 45e18,
            "recipient1 should have initial + 30% of 150 TOKEN_1"
        );
        assertEq(
            token1.balanceOf(recipient2),
            recipient2Token1Initial + 105e18,
            "recipient2 should have initial + 70% of 150 TOKEN_1"
        );
    }

    function testSplitCanBeCalledByAnyone() public {
        // Record initial balances
        uint256 recipient1Token0Before = token0.balanceOf(recipient1);
        uint256 recipient2Token0Before = token0.balanceOf(recipient2);

        // Setup tokens
        deal(address(token0), address(feeSplitter), 100e18);

        // Create random caller
        address randomCaller = makeAddr("randomCaller");

        // Should succeed when called by anyone
        vm.prank(randomCaller);
        feeSplitter.split();

        // Verify distribution occurred
        assertEq(
            token0.balanceOf(recipient1), recipient1Token0Before + 30e18, "recipient1 should receive additional 30%"
        );
        assertEq(
            token0.balanceOf(recipient2), recipient2Token0Before + 70e18, "recipient2 should receive additional 70%"
        );
    }

    function testDeployScriptIntegration() public {
        // This test verifies that the deploy script works correctly
        // Since setUp() already uses the deploy script, we just need to verify the deployment is correct
        assertEq(feeSplitter.TOKEN_0(), addresses.getAddress("MAMO"), "incorrect TOKEN_0 from deploy script");
        assertEq(feeSplitter.TOKEN_1(), addresses.getAddress("VIRTUALS"), "incorrect TOKEN_1 from deploy script");

        // Verify that recipients are set to valid addresses (they might differ based on current addresses.json)
        assertTrue(feeSplitter.RECIPIENT_1() != address(0), "RECIPIENT_1 should not be zero");
        assertTrue(feeSplitter.RECIPIENT_2() != address(0), "RECIPIENT_2 should not be zero");
        assertTrue(feeSplitter.RECIPIENT_1() != feeSplitter.RECIPIENT_2(), "Recipients should be different");
    }
}
