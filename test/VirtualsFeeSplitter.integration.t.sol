// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VirtualsFeeSplitter} from "@contracts/VirtualsFeeSplitter.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {DeployVirtualsFeeSplitter} from "@script/DeployVirtualsFeeSplitter.s.sol";

contract VirtualsFeeSplitterIntegrationTest is Test {
    VirtualsFeeSplitter public virtualsFeeSplitter;
    DeployVirtualsFeeSplitter public deployScript;
    Addresses public addresses;

    IERC20 public mamoToken;
    IERC20 public virtualsToken;
    IERC20 public cbBtcToken;

    address public owner;
    address public recipient1; // 70% recipient
    address public recipient2; // 30% recipient

    // Test accounts
    address public testUser = makeAddr("testUser");

    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork(vm.rpcUrl("base"));

        // Deploy via script
        deployScript = new DeployVirtualsFeeSplitter();

        // Setup addresses
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the contract
        virtualsFeeSplitter = deployScript.deployVirtualsFeeSplitter(addresses);

        // Get token contracts
        (address mamo, address virtuals, address cbbtc) = virtualsFeeSplitter.getTokenAddresses();
        mamoToken = IERC20(mamo);
        virtualsToken = IERC20(virtuals);
        cbBtcToken = IERC20(cbbtc);

        // Get participants
        owner = virtualsFeeSplitter.owner();
        recipient1 = virtualsFeeSplitter.RECIPIENT_1();
        recipient2 = virtualsFeeSplitter.RECIPIENT_2();

        // Log deployment info
        console.log("VirtualsFeeSplitter deployed at:", address(virtualsFeeSplitter));
        console.log("MAMO Token:", address(mamoToken));
        console.log("Virtuals Token:", address(virtualsToken));
        console.log("cbBTC Token:", address(cbBtcToken));
        console.log("Owner:", owner);
        console.log("Recipient 1 (70%):", recipient1);
        console.log("Recipient 2 (30%):", recipient2);
    }

    function testDeployment() public view {
        // Test basic deployment properties
        assertEq(virtualsFeeSplitter.owner(), owner, "incorrect owner");
        assertEq(virtualsFeeSplitter.RECIPIENT_1(), recipient1, "incorrect recipient1");
        assertEq(virtualsFeeSplitter.RECIPIENT_2(), recipient2, "incorrect recipient2");

        // Test split ratios
        (uint256 share1, uint256 share2) = virtualsFeeSplitter.getSplitRatios();
        assertEq(share1, 70, "incorrect recipient1 share");
        assertEq(share2, 30, "incorrect recipient2 share");

        // Test token addresses
        (address mamo, address virtuals, address cbbtc) = virtualsFeeSplitter.getTokenAddresses();
        assertTrue(mamo != address(0), "MAMO token should not be zero");
        assertTrue(virtuals != address(0), "Virtuals token should not be zero");
        assertTrue(cbbtc != address(0), "cbBTC token should not be zero");

        // Test recipients are different
        assertTrue(recipient1 != recipient2, "recipients should be different");
    }

    function testMamoDistribution() public {
        uint256 mamoAmount = 1000e18; // 1000 MAMO tokens

        // Deal MAMO tokens to the contract
        deal(address(mamoToken), address(virtualsFeeSplitter), mamoAmount);

        // Record balances before
        uint256 recipient1BalanceBefore = mamoToken.balanceOf(recipient1);
        uint256 recipient2BalanceBefore = mamoToken.balanceOf(recipient2);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check distributions
        uint256 recipient1BalanceAfter = mamoToken.balanceOf(recipient1);
        uint256 recipient2BalanceAfter = mamoToken.balanceOf(recipient2);

        uint256 recipient1Received = recipient1BalanceAfter - recipient1BalanceBefore;
        uint256 recipient2Received = recipient2BalanceAfter - recipient2BalanceBefore;

        // Verify 70/30 split
        assertEq(recipient1Received, 700e18, "recipient1 should receive 70%");
        assertEq(recipient2Received, 300e18, "recipient2 should receive 30%");
        assertEq(recipient1Received + recipient2Received, mamoAmount, "total should equal input");

        // Verify contract has no remaining MAMO
        assertEq(mamoToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining MAMO");
    }

    function testSwapAndCollectWithNoTokens() public {
        // Ensure no tokens in contract
        assertEq(mamoToken.balanceOf(address(virtualsFeeSplitter)), 0, "should start with no MAMO");

        // Record balances before
        uint256 recipient1MamoBefore = mamoToken.balanceOf(recipient1);
        uint256 recipient2MamoBefore = mamoToken.balanceOf(recipient2);
        uint256 recipient1CbBtcBefore = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcBefore = cbBtcToken.balanceOf(recipient2);

        // Call swapAndCollect with no tokens (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Verify no changes in balances
        assertEq(mamoToken.balanceOf(recipient1), recipient1MamoBefore, "recipient1 MAMO should not change");
        assertEq(mamoToken.balanceOf(recipient2), recipient2MamoBefore, "recipient2 MAMO should not change");
        assertEq(cbBtcToken.balanceOf(recipient1), recipient1CbBtcBefore, "recipient1 cbBTC should not change");
        assertEq(cbBtcToken.balanceOf(recipient2), recipient2CbBtcBefore, "recipient2 cbBTC should not change");
    }

    function testMamoDistributionWithDustAmount() public {
        uint256 dustAmount = 1; // 1 wei of MAMO

        // Deal dust amount to the contract
        deal(address(mamoToken), address(virtualsFeeSplitter), dustAmount);

        // Record balances before
        uint256 recipient1BalanceBefore = mamoToken.balanceOf(recipient1);
        uint256 recipient2BalanceBefore = mamoToken.balanceOf(recipient2);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that all tokens were distributed (even with rounding)
        uint256 recipient1BalanceAfter = mamoToken.balanceOf(recipient1);
        uint256 recipient2BalanceAfter = mamoToken.balanceOf(recipient2);

        uint256 totalDistributed =
            (recipient1BalanceAfter - recipient1BalanceBefore) + (recipient2BalanceAfter - recipient2BalanceBefore);

        assertEq(totalDistributed, dustAmount, "all dust should be distributed");
        assertEq(mamoToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining MAMO");
    }

    function testOwnershipFunctions() public {
        // Test that only owner can call owner functions
        vm.prank(testUser);
        vm.expectRevert(); // Should revert because testUser is not owner
        virtualsFeeSplitter.emergencyRecover(address(mamoToken), testUser, 100);

        vm.prank(testUser);
        vm.expectRevert(); // Should revert because testUser is not owner
        virtualsFeeSplitter.updateVirtualsApproval();

        vm.prank(testUser);
        vm.expectRevert(); // Should revert because testUser is not owner
        virtualsFeeSplitter.swapAndCollect();

        vm.prank(testUser);
        vm.expectRevert(); // Should revert because testUser is not owner
        virtualsFeeSplitter.setSlippage(300);

        // Test that owner can call these functions
        vm.prank(owner);
        virtualsFeeSplitter.updateVirtualsApproval(); // Should not revert

        vm.prank(owner);
        virtualsFeeSplitter.setSlippage(300); // Should not revert
    }

    function testEmergencyRecover() public {
        // Give some MAMO to the contract
        uint256 recoverAmount = 500e18;
        deal(address(mamoToken), address(virtualsFeeSplitter), recoverAmount);

        uint256 testUserBalanceBefore = mamoToken.balanceOf(testUser);

        // Owner recovers tokens to testUser
        vm.prank(owner);
        virtualsFeeSplitter.emergencyRecover(address(mamoToken), testUser, recoverAmount);

        // Verify recovery
        assertEq(
            mamoToken.balanceOf(testUser),
            testUserBalanceBefore + recoverAmount,
            "testUser should receive recovered tokens"
        );
        assertEq(mamoToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining tokens");
    }

    function testEmergencyRecoverValidation() public {
        uint256 amount = 100e18;
        deal(address(mamoToken), address(virtualsFeeSplitter), amount);

        // Test zero address validation
        vm.prank(owner);
        vm.expectRevert("Cannot send to zero address");
        virtualsFeeSplitter.emergencyRecover(address(mamoToken), address(0), amount);

        // Test zero amount validation
        vm.prank(owner);
        vm.expectRevert("Amount must be greater than 0");
        virtualsFeeSplitter.emergencyRecover(address(mamoToken), testUser, 0);
    }

    function testViewFunctions() public view {
        // Test getTokenAddresses
        (address mamo, address virtuals, address cbbtc) = virtualsFeeSplitter.getTokenAddresses();
        assertTrue(mamo != address(0), "MAMO address should not be zero");
        assertTrue(virtuals != address(0), "Virtuals address should not be zero");
        assertTrue(cbbtc != address(0), "cbBTC address should not be zero");

        // Test getAerodromeAddresses
        (address router, address quoter) = virtualsFeeSplitter.getAerodromeAddresses();
        assertTrue(router != address(0), "Router address should not be zero");
        assertTrue(quoter != address(0), "Quoter address should not be zero");

        // Test getSplitRatios
        (uint256 share1, uint256 share2) = virtualsFeeSplitter.getSplitRatios();
        assertEq(share1, 70, "Recipient 1 should get 70%");
        assertEq(share2, 30, "Recipient 2 should get 30%");

        // Test getSlippage
        (uint256 slippage, uint256 maxSlippage) = virtualsFeeSplitter.getSlippage();
        assertEq(slippage, 500, "Default slippage should be 5%");
        assertEq(maxSlippage, 1000, "Max slippage should be 10%");

        // Test getPoolConfig
        int24 tickSpacing = virtualsFeeSplitter.getPoolConfig();
        assertEq(tickSpacing, 200, "Tick spacing should be 200");
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
        uint256 virtualsAmount = 100e18; // 100 VIRTUALS tokens

        // Deal VIRTUALS tokens to the contract
        deal(address(virtualsToken), address(virtualsFeeSplitter), virtualsAmount);

        // Record balances before
        uint256 recipient1CbBtcBefore = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcBefore = cbBtcToken.balanceOf(recipient2);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that VIRTUALS were swapped (contract should have 0 VIRTUALS remaining)
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");

        // Check cbBTC distributions
        uint256 recipient1CbBtcAfter = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcAfter = cbBtcToken.balanceOf(recipient2);

        uint256 recipient1CbBtcReceived = recipient1CbBtcAfter - recipient1CbBtcBefore;
        uint256 recipient2CbBtcReceived = recipient2CbBtcAfter - recipient2CbBtcBefore;

        // Verify some cbBTC was received
        assertTrue(recipient1CbBtcReceived > 0, "recipient1 should receive cbBTC");
        assertTrue(recipient2CbBtcReceived > 0, "recipient2 should receive cbBTC");

        // Verify 70/30 split (allowing for small rounding errors)
        uint256 totalCbBtcReceived = recipient1CbBtcReceived + recipient2CbBtcReceived;
        uint256 expectedRecipient1 = (totalCbBtcReceived * 70) / 100;
        uint256 expectedRecipient2 = totalCbBtcReceived - expectedRecipient1;

        assertEq(recipient1CbBtcReceived, expectedRecipient1, "recipient1 should receive 70% of cbBTC");
        assertEq(recipient2CbBtcReceived, expectedRecipient2, "recipient2 should receive 30% of cbBTC");
    }

    function testVirtualsDistributionWithDustAmount() public {
        uint256 dustAmount = 1e18; // 1 VIRTUALS token (small amount)

        // Deal dust amount to the contract
        deal(address(virtualsToken), address(virtualsFeeSplitter), dustAmount);

        // Record balances before
        uint256 recipient1CbBtcBefore = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcBefore = cbBtcToken.balanceOf(recipient2);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that all VIRTUALS were swapped
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");

        // Check that some cbBTC was received (even for small amounts)
        uint256 recipient1CbBtcAfter = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcAfter = cbBtcToken.balanceOf(recipient2);

        uint256 totalCbBtcReceived =
            (recipient1CbBtcAfter - recipient1CbBtcBefore) + (recipient2CbBtcAfter - recipient2CbBtcBefore);

        // Should have received some cbBTC (even if small)
        assertTrue(totalCbBtcReceived > 0, "should receive some cbBTC for dust amount");
    }

    function testBothMamoAndVirtualsDistribution() public {
        uint256 mamoAmount = 1000e18; // 1000 MAMO tokens
        uint256 virtualsAmount = 50e18; // 50 VIRTUALS tokens

        // Deal both tokens to the contract
        deal(address(mamoToken), address(virtualsFeeSplitter), mamoAmount);
        deal(address(virtualsToken), address(virtualsFeeSplitter), virtualsAmount);

        // Record balances before
        uint256 recipient1MamoBefore = mamoToken.balanceOf(recipient1);
        uint256 recipient2MamoBefore = mamoToken.balanceOf(recipient2);
        uint256 recipient1CbBtcBefore = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcBefore = cbBtcToken.balanceOf(recipient2);

        // Call swapAndCollect (only owner can call)
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check MAMO distributions
        uint256 recipient1MamoAfter = mamoToken.balanceOf(recipient1);
        uint256 recipient2MamoAfter = mamoToken.balanceOf(recipient2);

        uint256 recipient1MamoReceived = recipient1MamoAfter - recipient1MamoBefore;
        uint256 recipient2MamoReceived = recipient2MamoAfter - recipient2MamoBefore;

        // Verify MAMO 70/30 split
        assertEq(recipient1MamoReceived, 700e18, "recipient1 should receive 70% of MAMO");
        assertEq(recipient2MamoReceived, 300e18, "recipient2 should receive 30% of MAMO");

        // Check VIRTUALS were swapped
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");

        // Check cbBTC distributions
        uint256 recipient1CbBtcAfter = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcAfter = cbBtcToken.balanceOf(recipient2);

        uint256 recipient1CbBtcReceived = recipient1CbBtcAfter - recipient1CbBtcBefore;
        uint256 recipient2CbBtcReceived = recipient2CbBtcAfter - recipient2CbBtcBefore;

        // Verify some cbBTC was received
        assertTrue(recipient1CbBtcReceived > 0, "recipient1 should receive cbBTC");
        assertTrue(recipient2CbBtcReceived > 0, "recipient2 should receive cbBTC");

        // Verify cbBTC 70/30 split
        uint256 totalCbBtcReceived = recipient1CbBtcReceived + recipient2CbBtcReceived;
        uint256 expectedCbBtcRecipient1 = (totalCbBtcReceived * 70) / 100;
        uint256 expectedCbBtcRecipient2 = totalCbBtcReceived - expectedCbBtcRecipient1;

        assertEq(recipient1CbBtcReceived, expectedCbBtcRecipient1, "recipient1 should receive 70% of cbBTC");
        assertEq(recipient2CbBtcReceived, expectedCbBtcRecipient2, "recipient2 should receive 30% of cbBTC");

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

        // Record balances before
        uint256 recipient1CbBtcBefore = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcBefore = cbBtcToken.balanceOf(recipient2);

        // Call swapAndCollect - should still work with slippage protection
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that VIRTUALS were swapped
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");

        // Check that cbBTC was received
        uint256 recipient1CbBtcAfter = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcAfter = cbBtcToken.balanceOf(recipient2);

        uint256 totalCbBtcReceived =
            (recipient1CbBtcAfter - recipient1CbBtcBefore) + (recipient2CbBtcAfter - recipient2CbBtcBefore);

        assertTrue(totalCbBtcReceived > 0, "should receive cbBTC even with tight slippage");
    }

    function testMultipleVirtualsSwaps() public {
        uint256 firstAmount = 30e18; // 30 VIRTUALS tokens
        uint256 secondAmount = 20e18; // 20 VIRTUALS tokens

        // First swap
        deal(address(virtualsToken), address(virtualsFeeSplitter), firstAmount);
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Record balances after first swap
        uint256 recipient1CbBtcAfterFirst = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcAfterFirst = cbBtcToken.balanceOf(recipient2);

        // Second swap
        deal(address(virtualsToken), address(virtualsFeeSplitter), secondAmount);
        vm.prank(owner);
        virtualsFeeSplitter.swapAndCollect();

        // Check that second swap also worked
        uint256 recipient1CbBtcAfterSecond = cbBtcToken.balanceOf(recipient1);
        uint256 recipient2CbBtcAfterSecond = cbBtcToken.balanceOf(recipient2);

        // Should have received more cbBTC from second swap
        assertTrue(
            recipient1CbBtcAfterSecond > recipient1CbBtcAfterFirst,
            "recipient1 should receive more cbBTC from second swap"
        );
        assertTrue(
            recipient2CbBtcAfterSecond > recipient2CbBtcAfterFirst,
            "recipient2 should receive more cbBTC from second swap"
        );

        // Contract should be clean
        assertEq(virtualsToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining VIRTUALS");
        assertEq(cbBtcToken.balanceOf(address(virtualsFeeSplitter)), 0, "contract should have no remaining cbBTC");
    }

    function testSlippageConfiguration() public {
        // Test initial slippage
        (uint256 initialSlippage,) = virtualsFeeSplitter.getSlippage();
        assertEq(initialSlippage, 500, "Initial slippage should be 5%");

        // Test setting new slippage
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SlippageUpdated(500, 300);
        virtualsFeeSplitter.setSlippage(300);

        (uint256 newSlippage,) = virtualsFeeSplitter.getSlippage();
        assertEq(newSlippage, 300, "Slippage should be updated to 3%");

        // Test setting slippage to maximum allowed
        vm.prank(owner);
        virtualsFeeSplitter.setSlippage(1000); // 10%
        (uint256 maxSlippage,) = virtualsFeeSplitter.getSlippage();
        assertEq(maxSlippage, 1000, "Should be able to set max slippage");

        // Test setting slippage too high (should revert)
        vm.prank(owner);
        vm.expectRevert("Slippage too high");
        virtualsFeeSplitter.setSlippage(1001); // 10.01%

        // Test that non-owner cannot set slippage
        vm.prank(testUser);
        vm.expectRevert();
        virtualsFeeSplitter.setSlippage(200);
    }

    // Custom event definition for testing
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
}
