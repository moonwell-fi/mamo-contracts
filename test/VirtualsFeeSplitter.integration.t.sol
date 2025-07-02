// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VirtualsFeeSplitter} from "@contracts/VirtualsFeeSplitter.sol";

contract VirtualsFeeSplitterIntegrationTest is Test {
    Addresses public addresses;
    VirtualsFeeSplitter public virtualsFeeSplitter;

    IERC20 public mamoToken;
    IERC20 public virtualsToken;
    IERC20 public cbBtcToken;

    address public owner;
    address public recipient; // Single recipient gets 100%

    // Test accounts
    address public testUser = makeAddr("testUser");

    // Token addresses for Base mainnet
    address public MAMO_TOKEN;
    address public VIRTUALS_TOKEN;
    address public CBBTC_TOKEN;
    address public AERODROME_ROUTER;

    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork(vm.rpcUrl("base"));

        // Setup test addresses
        owner = makeAddr("owner");
        recipient = makeAddr("recipient");

        // Create a new addresses instance for testing
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        addresses = new Addresses(addressesFolderPath, chainIds);

        MAMO_TOKEN = addresses.getAddress("MAMO");
        VIRTUALS_TOKEN = addresses.getAddress("VIRTUALS");
        CBBTC_TOKEN = addresses.getAddress("cbBTC");
        AERODROME_ROUTER = addresses.getAddress("AERODROME_ROUTER");

        // Deploy the contract directly with constructor parameters
        vm.prank(owner);
        virtualsFeeSplitter =
            new VirtualsFeeSplitter(owner, recipient, MAMO_TOKEN, VIRTUALS_TOKEN, CBBTC_TOKEN, AERODROME_ROUTER);

        // Get token contracts
        mamoToken = IERC20(MAMO_TOKEN);
        virtualsToken = IERC20(VIRTUALS_TOKEN);
        cbBtcToken = IERC20(CBBTC_TOKEN);
    }

    function testDeployment() public view {
        // Test basic deployment properties
        assertEq(virtualsFeeSplitter.owner(), owner, "incorrect owner");
        assertEq(virtualsFeeSplitter.RECIPIENT(), recipient, "incorrect recipient");

        // Test token addresses (now public)
        assertEq(virtualsFeeSplitter.MAMO_TOKEN(), MAMO_TOKEN, "incorrect MAMO token address");
        assertEq(virtualsFeeSplitter.VIRTUALS_TOKEN(), VIRTUALS_TOKEN, "incorrect VIRTUALS token address");
        assertEq(virtualsFeeSplitter.CBBTC_TOKEN(), CBBTC_TOKEN, "incorrect cbBTC token address");
        assertEq(virtualsFeeSplitter.AERODROME_ROUTER(), AERODROME_ROUTER, "incorrect router address");

        // Test addresses are not zero
        assertTrue(virtualsFeeSplitter.MAMO_TOKEN() != address(0), "MAMO token should not be zero");
        assertTrue(virtualsFeeSplitter.VIRTUALS_TOKEN() != address(0), "Virtuals token should not be zero");
        assertTrue(virtualsFeeSplitter.CBBTC_TOKEN() != address(0), "cbBTC token should not be zero");
        assertTrue(virtualsFeeSplitter.RECIPIENT() != address(0), "recipient should not be zero");
    }

    function testMamoDistribution() public {
        uint256 mamoAmount = 1000e18; // 1000 MAMO tokens

        // Deal MAMO tokens to the contract
        deal(address(mamoToken), address(virtualsFeeSplitter), mamoAmount);

        // Record balance before
        uint256 recipientBalanceBefore = mamoToken.balanceOf(recipient);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check distribution
        uint256 recipientBalanceAfter = mamoToken.balanceOf(recipient);
        uint256 recipientReceived = recipientBalanceAfter - recipientBalanceBefore;

        // Verify recipient gets 100%
        assertEq(recipientReceived, mamoAmount, "recipient should receive 100%");

        // Verify contract has no remaining MAMO
        assertEq(mamoToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining MAMO");
    }

    function testSwapAndCollectWithNoTokens() public {
        // Ensure no tokens in contract
        assertEq(mamoToken.balanceOf(address(virtualsFeeSplitter)), 0, "should start with no MAMO");

        // Record balances before
        uint256 recipientMamoBefore = mamoToken.balanceOf(recipient);
        uint256 recipientCbBtcBefore = cbBtcToken.balanceOf(recipient);

        // Call swapAndCollect with no tokens (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Verify no changes in balances
        assertEq(mamoToken.balanceOf(recipient), recipientMamoBefore, "recipient MAMO should not change");
        assertEq(cbBtcToken.balanceOf(recipient), recipientCbBtcBefore, "recipient cbBTC should not change");
    }

    function testMamoDistributionWithDustAmount() public {
        uint256 dustAmount = 1; // 1 wei of MAMO

        // Deal dust amount to the contract
        deal(address(mamoToken), address(virtualsFeeSplitter), dustAmount);

        // Record balance before
        uint256 recipientBalanceBefore = mamoToken.balanceOf(recipient);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that all tokens were distributed
        uint256 recipientBalanceAfter = mamoToken.balanceOf(recipient);
        uint256 totalDistributed = recipientBalanceAfter - recipientBalanceBefore;

        assertEq(totalDistributed, dustAmount, "all dust should be distributed");
        assertEq(mamoToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining MAMO");
    }

    function testOwnershipFunctions() public {
        // Test that only owner can call owner functions
        vm.prank(testUser);
        vm.expectRevert(); // Should revert because testUser is not owner
        virtualsFeeSplitter.swapAndCollect();

        vm.prank(testUser);
        vm.expectRevert(); // Should revert because testUser is not owner
        virtualsFeeSplitter.setSlippage(300);

        // Test that owner can call these functions
        vm.prank(owner);
        virtualsFeeSplitter.setSlippage(300); // Should not revert
    }

    function testMultipleSwapAndCollectCalls() public {
        uint256 mamoAmount = 1000e18;

        // First call with tokens (only owner can call)
        deal(address(mamoToken), address(virtualsFeeSplitter), mamoAmount);
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Second call with no tokens (should not revert)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Third call with more tokens
        deal(address(mamoToken), address(virtualsFeeSplitter), mamoAmount / 2);
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Verify contract still has no remaining tokens
        assertEq(mamoToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining MAMO");
    }

    function testVirtualsDistribution() public {
        uint256 virtualsAmount = 1000e18; // 1000 VIRTUALS tokens

        // Deal VIRTUALS tokens to the contract
        deal(address(virtualsToken), address(virtualsFeeSplitter), virtualsAmount);

        // Record balance before
        uint256 recipientCbBtcBefore = cbBtcToken.balanceOf(recipient);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that VIRTUALS were swapped (contract should have 0 VIRTUALS remaining)
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");

        // Check cbBTC distribution
        uint256 recipientCbBtcAfter = cbBtcToken.balanceOf(recipient);
        uint256 recipientCbBtcReceived = recipientCbBtcAfter - recipientCbBtcBefore;

        // Verify some cbBTC was received
        assertTrue(recipientCbBtcReceived > 0, "recipient should receive cbBTC");
    }

    function testVirtualsDistributionWithDustAmount() public {
        uint256 dustAmount = 1e18; // 1 VIRTUALS token (small amount)

        // Deal dust amount to the contract
        deal(address(virtualsToken), address(virtualsFeeSplitter), dustAmount);

        // Record balance before
        uint256 recipientCbBtcBefore = cbBtcToken.balanceOf(recipient);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that all VIRTUALS were swapped
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");

        // Check that some cbBTC was received (even for small amounts)
        uint256 recipientCbBtcAfter = cbBtcToken.balanceOf(recipient);
        uint256 totalCbBtcReceived = recipientCbBtcAfter - recipientCbBtcBefore;

        // Should have received some cbBTC (even if small)
        assertTrue(totalCbBtcReceived > 0, "should receive some cbBTC for dust amount");
    }

    function testBothMamoAndVirtualsDistribution() public {
        uint256 mamoAmount = 1000000e18; // 1000000 MAMO tokens
        uint256 virtualsAmount = 2000e18; // 2000 VIRTUALS tokens

        // Deal both tokens to the contract
        deal(address(mamoToken), address(virtualsFeeSplitter), mamoAmount);
        deal(address(virtualsToken), address(virtualsFeeSplitter), virtualsAmount);

        // Record balances before
        uint256 recipientMamoBefore = mamoToken.balanceOf(recipient);
        uint256 recipientCbBtcBefore = cbBtcToken.balanceOf(recipient);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check MAMO distribution
        uint256 recipientMamoAfter = mamoToken.balanceOf(recipient);
        uint256 recipientMamoReceived = recipientMamoAfter - recipientMamoBefore;

        // Verify MAMO 100% to recipient
        assertEq(recipientMamoReceived, mamoAmount, "recipient should receive 100% of MAMO");

        // Check VIRTUALS were swapped
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");

        // Check cbBTC distribution
        uint256 recipientCbBtcAfter = cbBtcToken.balanceOf(recipient);
        uint256 recipientCbBtcReceived = recipientCbBtcAfter - recipientCbBtcBefore;

        // Verify some cbBTC was received
        assertTrue(recipientCbBtcReceived > 0, "recipient should receive cbBTC");

        // Verify contracts are clean
        assertEq(mamoToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining MAMO");
        assertEq(cbBtcToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining cbBTC");
    }

    function testVirtualsSwapWithSlippageProtection() public {
        uint256 virtualsAmount = 25e18; // 25 VIRTUALS tokens

        // Set a more restrictive slippage (2%)
        vm.prank(owner);
        virtualsFeeSplitter.setSlippage(200); // 2%

        // Deal VIRTUALS tokens to the contract
        deal(address(virtualsToken), address(virtualsFeeSplitter), virtualsAmount);

        // Record balance before
        uint256 recipientCbBtcBefore = cbBtcToken.balanceOf(recipient);

        // Call swapAndCollect - should still work with slippage protection
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that VIRTUALS were swapped
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");

        // Check that cbBTC was received
        uint256 recipientCbBtcAfter = cbBtcToken.balanceOf(recipient);
        uint256 totalCbBtcReceived = recipientCbBtcAfter - recipientCbBtcBefore;

        assertTrue(totalCbBtcReceived > 0, "should receive cbBTC even with tight slippage");
    }

    function testMultipleVirtualsSwaps() public {
        uint256 firstAmount = 30e18; // 30 VIRTUALS tokens
        uint256 secondAmount = 20e18; // 20 VIRTUALS tokens

        // First swap
        deal(address(virtualsToken), address(virtualsFeeSplitter), firstAmount);
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Record balance after first swap
        uint256 recipientCbBtcAfterFirst = cbBtcToken.balanceOf(recipient);

        // Second swap
        deal(address(virtualsToken), address(virtualsFeeSplitter), secondAmount);
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that second swap also worked
        uint256 recipientCbBtcAfterSecond = cbBtcToken.balanceOf(recipient);

        // Should have received more cbBTC from second swap
        assertTrue(
            recipientCbBtcAfterSecond > recipientCbBtcAfterFirst, "recipient should receive more cbBTC from second swap"
        );

        // Contract should be clean
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");
        assertEq(cbBtcToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining cbBTC");
    }

    function testSlippageConfiguration() public {
        // Test initial slippage
        assertEq(virtualsFeeSplitter.slippageBps(), 500, "Initial slippage should be 5%");

        // Test setting new slippage
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SlippageUpdated(500, 300);
        virtualsFeeSplitter.setSlippage(300);

        assertEq(virtualsFeeSplitter.slippageBps(), 300, "Slippage should be updated to 3%");

        // Test setting slippage to maximum allowed
        vm.prank(owner);
        virtualsFeeSplitter.setSlippage(1000); // 10%
        assertEq(virtualsFeeSplitter.slippageBps(), 1000, "Should be able to set max slippage");

        // Test setting slippage too high (should revert)
        vm.prank(owner);
        vm.expectRevert("Slippage too high");
        virtualsFeeSplitter.setSlippage(10001); // 100.01%

        // Test that non-owner cannot set slippage
        vm.prank(testUser);
        vm.expectRevert();
        virtualsFeeSplitter.setSlippage(200);
    }

    function testConstructorValidation() public {
        // Test zero address validations in constructor
        vm.expectRevert("Recipient cannot be zero address");
        new VirtualsFeeSplitter(owner, address(0), MAMO_TOKEN, VIRTUALS_TOKEN, CBBTC_TOKEN, AERODROME_ROUTER);

        vm.expectRevert("MAMO token cannot be zero address");
        new VirtualsFeeSplitter(owner, recipient, address(0), VIRTUALS_TOKEN, CBBTC_TOKEN, AERODROME_ROUTER);

        vm.expectRevert("Virtuals token cannot be zero address");
        new VirtualsFeeSplitter(owner, recipient, MAMO_TOKEN, address(0), CBBTC_TOKEN, AERODROME_ROUTER);

        vm.expectRevert("cbBTC token cannot be zero address");
        new VirtualsFeeSplitter(owner, recipient, MAMO_TOKEN, VIRTUALS_TOKEN, address(0), AERODROME_ROUTER);

        vm.expectRevert("Router cannot be zero address");
        new VirtualsFeeSplitter(owner, recipient, MAMO_TOKEN, VIRTUALS_TOKEN, CBBTC_TOKEN, address(0));
    }

    // Custom event definition for testing
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
}
