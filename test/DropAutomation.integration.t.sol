// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {DropAutomation} from "@contracts/DropAutomation.sol";
import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";

import {DropAutomationSetup} from "../multisig/f-mamo/005_DropAutomationSetup.sol";
import {IAerodromeGauge} from "@contracts/interfaces/IAerodromeGauge.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISafe} from "@contracts/interfaces/ISafe.sol";

contract DropAutomationIntegrationTest is BaseTest {
    DropAutomation public dropAutomation;
    RewardsDistributorSafeModule public rewardsModule;

    IERC20 public mamoToken;
    IERC20 public cbBtcToken;
    IERC20 public wethToken;

    ISafe public fMamoSafe;
    address public owner;
    address public dedicatedSender;

    uint256 internal constant MAMO_TOP_UP = 5_000e18;
    uint256 internal constant CBBTC_TOP_UP = 1e7; // 0.1 cbBTC (8 decimals)
    uint256 internal constant WETH_TOP_UP = 1e15; // 0.001 WETH
    uint256 internal constant EXTRA_TOKEN_TOP_UP = 1e18;

    // Additional swap tokens collected during earn (all volatile CL-200 pools vs MAMO)
    address internal constant ZORA_TOKEN = 0x1111111111166b7FE7bd91427724B487980aFc69;
    address internal constant EDGE_TOKEN = 0xED6E000dEF95780fb89734c07EE2ce9F6dcAf110;
    address internal constant VIRTUALS_TOKEN = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;

    // Events to test
    event DedicatedMsgSenderUpdated(address indexed oldSender, address indexed newSender);
    event MaxSlippageUpdated(uint256 oldValueBps, uint256 newValueBps);
    event DropCreated(uint256 mamoAmount, uint256 cbBtcAmount);

    function setUp() public override {
        super.setUp();

        // Get addresses we need
        owner = addresses.getAddress("F-MAMO");
        dedicatedSender = addresses.getAddress("ADITYA_EOA");

        // Use the 005_DropAutomationSetup script to deploy and configure
        DropAutomationSetup setupScript = new DropAutomationSetup();

        // Pass our addresses instance to the setup script
        setupScript.setAddresses(addresses);

        // Make the deployDropAutomation persistent so it can access our addresses
        vm.makePersistent(address(setupScript.deployDropAutomation()));

        // Deploy DropAutomation using the setup script's deploy function
        // Note: The deploy function doesn't add the address to the registry, so we need to do it manually
        address dropAutomationAddr;
        if (!addresses.isAddressSet("DROP_AUTOMATION")) {
            dropAutomationAddr = setupScript.deployDropAutomation().deploy(addresses);
            addresses.addAddress("DROP_AUTOMATION", dropAutomationAddr, true);
        }

        // Get the deployed contract
        dropAutomation = DropAutomation(addresses.getAddress("DROP_AUTOMATION"));

        mamoToken = IERC20(dropAutomation.MAMO_TOKEN());
        cbBtcToken = IERC20(dropAutomation.CBBTC_TOKEN());
        wethToken = IERC20(addresses.getAddress("WETH"));

        rewardsModule = RewardsDistributorSafeModule(address(dropAutomation.SAFE_REWARDS_DISTRIBUTOR_MODULE()));
        fMamoSafe = ISafe(payable(dropAutomation.F_MAMO_SAFE()));

        _ensureModuleReady();

        setupScript.build();
        setupScript.simulate();
        setupScript.validate();
    }

    function testInitialization() public view {
        assertEq(address(dropAutomation.MAMO_TOKEN()), addresses.getAddress("MAMO"), "incorrect MAMO token");
        assertEq(address(dropAutomation.CBBTC_TOKEN()), addresses.getAddress("cbBTC"), "incorrect cbBTC token");
        assertEq(dropAutomation.F_MAMO_SAFE(), addresses.getAddress("F-MAMO"), "incorrect F-MAMO safe");
        assertEq(
            address(dropAutomation.SAFE_REWARDS_DISTRIBUTOR_MODULE()),
            addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC"),
            "incorrect rewards module"
        );
        assertEq(dropAutomation.dedicatedMsgSender(), dedicatedSender, "incorrect dedicated sender");
        assertEq(dropAutomation.owner(), addresses.getAddress("F-MAMO"), "incorrect owner");
        assertEq(dropAutomation.maxSlippageBps(), 100, "incorrect default slippage");
    }

    function testOwnerFunctions() public {
        // Test setDedicatedMsgSender
        address newSender = makeAddr("newSender");
        vm.expectEmit(true, true, false, false);
        emit DedicatedMsgSenderUpdated(dedicatedSender, newSender);

        vm.prank(owner);
        dropAutomation.setDedicatedMsgSender(newSender);
        assertEq(dropAutomation.dedicatedMsgSender(), newSender, "sender should be updated");

        // Test setMaxSlippageBps
        vm.expectEmit(false, false, false, true);
        emit MaxSlippageUpdated(100, 300);

        vm.prank(owner);
        dropAutomation.setMaxSlippageBps(300);
        assertEq(dropAutomation.maxSlippageBps(), 300, "slippage should be updated");

        // Test recoverERC20
        address recipient = makeAddr("recipient");
        deal(address(mamoToken), address(dropAutomation), 100e18);

        vm.prank(owner);
        dropAutomation.recoverERC20(address(mamoToken), recipient, 100e18);
        assertEq(mamoToken.balanceOf(recipient), 100e18, "tokens should be recovered");
    }

    function testAccessControl() public {
        address attacker = makeAddr("attacker");

        // Test only owner can call setDedicatedMsgSender
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.setDedicatedMsgSender(attacker);

        // Test only owner can call setMaxSlippageBps
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.setMaxSlippageBps(100);

        // Test only owner can call recoverERC20
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.recoverERC20(address(mamoToken), attacker, 100e18);

        // Test only dedicatedMsgSender can call createDrop
        (address[] memory tokens, int24[] memory tickSpacings, bool[] memory swapDirectToCbBtc) =
            _getDefaultSwapTokensAndTickSpacings();
        uint256[] memory minAmounts = new uint256[](tokens.length);
        vm.prank(attacker);
        vm.expectRevert(DropAutomation.NotDedicatedSender.selector);
        dropAutomation.createDrop(tokens, tickSpacings, swapDirectToCbBtc, minAmounts);
    }

    function testValidationErrors() public {
        // Test invalid dedicated sender
        vm.prank(owner);
        vm.expectRevert("Invalid dedicated sender");
        dropAutomation.setDedicatedMsgSender(address(0));

        // Test invalid slippage
        vm.prank(owner);
        vm.expectRevert(DropAutomation.InvalidSlippage.selector);
        dropAutomation.setMaxSlippageBps(0);

        vm.prank(owner);
        vm.expectRevert(DropAutomation.InvalidSlippage.selector);
        dropAutomation.setMaxSlippageBps(501); // Over 5% cap

        // Test recoverERC20 with invalid params
        vm.prank(owner);
        vm.expectRevert("Invalid token");
        dropAutomation.recoverERC20(address(0), owner, 100e18);

        vm.prank(owner);
        vm.expectRevert("Invalid recipient");
        dropAutomation.recoverERC20(address(mamoToken), address(0), 100e18);

        // Test createDrop with mismatched array lengths
        address[] memory tokens = new address[](2);
        int24[] memory tickSpacings = new int24[](1);
        bool[] memory swapDirectToCbBtc = new bool[](2);
        uint256[] memory minAmounts = new uint256[](2);
        vm.prank(dedicatedSender);
        vm.expectRevert("Array length mismatch");
        dropAutomation.createDrop(tokens, tickSpacings, swapDirectToCbBtc, minAmounts);
    }

    function test_createDrop_endToEnd() public {
        // Top up DropAutomation with tokens that would normally be collected by earn
        deal(address(mamoToken), address(dropAutomation), MAMO_TOP_UP);
        deal(address(cbBtcToken), address(dropAutomation), CBBTC_TOP_UP);
        deal(address(wethToken), address(dropAutomation), WETH_TOP_UP);
        deal(ZORA_TOKEN, address(dropAutomation), EXTRA_TOKEN_TOP_UP);
        deal(EDGE_TOKEN, address(dropAutomation), EXTRA_TOKEN_TOP_UP);
        deal(VIRTUALS_TOKEN, address(dropAutomation), EXTRA_TOKEN_TOP_UP);

        // Add AERO tokens to simulate gauge rewards
        address aeroToken = addresses.getAddress("AERO");
        deal(aeroToken, address(dropAutomation), EXTRA_TOKEN_TOP_UP);

        uint256 safeMamoBefore = mamoToken.balanceOf(address(fMamoSafe));
        uint256 safeCbBtcBefore = cbBtcToken.balanceOf(address(fMamoSafe));

        (address[] memory swapTokens, int24[] memory tickSpacings, bool[] memory swapDirectToCbBtc) =
            _getDefaultSwapTokensAndTickSpacings();

        // Use 0 for all minimums to allow any output (no MEV protection in test)
        uint256[] memory minAmounts = new uint256[](swapTokens.length);

        vm.prank(dedicatedSender);
        dropAutomation.createDrop(swapTokens, tickSpacings, swapDirectToCbBtc, minAmounts);

        uint256 safeMamoAfter = mamoToken.balanceOf(address(fMamoSafe));
        uint256 safeCbBtcAfter = cbBtcToken.balanceOf(address(fMamoSafe));

        assertGe(safeMamoAfter - safeMamoBefore, MAMO_TOP_UP, "Safe should receive MAMO rewards");
        assertGt(safeCbBtcAfter - safeCbBtcBefore, 0, "Safe should receive cbBTC rewards");

        (uint256 pendingToken1, uint256 pendingToken2,, bool isNotified) = rewardsModule.pendingRewards();
        assertGe(pendingToken1, MAMO_TOP_UP, "Module should stage MAMO amount");
        assertGe(pendingToken2, CBBTC_TOP_UP, "Module should stage at least the seeded cbBTC");
        assertFalse(isNotified, "Rewards should be pending execution");

        // Drop contract should not retain tokens post distribution
        assertEq(mamoToken.balanceOf(address(dropAutomation)), 0, "Drop should not retain MAMO");
        assertEq(cbBtcToken.balanceOf(address(dropAutomation)), 0, "Drop should not retain cbBTC");
        assertEq(wethToken.balanceOf(address(dropAutomation)), 0, "Drop should swap WETH balance");
        assertEq(IERC20(ZORA_TOKEN).balanceOf(address(dropAutomation)), 0, "Drop should swap ZORA balance");
        assertEq(IERC20(EDGE_TOKEN).balanceOf(address(dropAutomation)), 0, "Drop should swap EDGE balance");
        assertEq(IERC20(VIRTUALS_TOKEN).balanceOf(address(dropAutomation)), 0, "Drop should swap Virtuals balance");
        assertEq(IERC20(aeroToken).balanceOf(address(dropAutomation)), 0, "Drop should swap AERO balance");
    }

    function _ensureModuleReady() internal {
        // Transfer admin role to DropAutomation (this is done by the multisig script in production)
        vm.startPrank(address(fMamoSafe));
        if (rewardsModule.admin() != address(dropAutomation)) {
            rewardsModule.setAdmin(address(dropAutomation));
        }
        vm.stopPrank();

        // Ensure previous round (if any) is executed so addRewards doesn't revert
        (uint256 amountToken1, uint256 amountToken2, uint256 notifyAfter, bool isNotified) =
            rewardsModule.pendingRewards();

        if (notifyAfter != 0 && !isNotified) {
            // Execute the pending round so the module transitions to EXECUTED, which is mandatory
            // before addRewards can be called again.
            if (block.timestamp <= notifyAfter) {
                vm.warp(notifyAfter + 1);
            }

            if (amountToken1 > 0) {
                deal(address(mamoToken), address(fMamoSafe), amountToken1);
            }
            if (amountToken2 > 0) {
                deal(address(cbBtcToken), address(fMamoSafe), amountToken2);
            }

            rewardsModule.notifyRewards();
        }
    }

    function _getDefaultSwapTokensAndTickSpacings()
        internal
        view
        returns (address[] memory tokens, int24[] memory tickSpacings, bool[] memory swapDirectToCbBtc)
    {
        // CL pools on Aerodrome use 200 tick spacing for volatile assets
        tokens = new address[](5);
        tickSpacings = new int24[](5);
        swapDirectToCbBtc = new bool[](5);

        tokens[0] = address(wethToken);
        tokens[1] = ZORA_TOKEN;
        tokens[2] = EDGE_TOKEN;
        tokens[3] = VIRTUALS_TOKEN;
        tokens[4] = addresses.getAddress("AERO");

        tickSpacings[0] = 200;
        tickSpacings[1] = 200;
        tickSpacings[2] = 200;
        tickSpacings[3] = 200;
        tickSpacings[4] = 200; // AERO/cbBTC pool tick spacing

        // First 4 tokens go through MAMO (false), AERO goes direct to cbBTC (true)
        swapDirectToCbBtc[0] = false;
        swapDirectToCbBtc[1] = false;
        swapDirectToCbBtc[2] = false;
        swapDirectToCbBtc[3] = false;
        swapDirectToCbBtc[4] = true; // AERO swaps directly to cbBTC
    }

    function testGaugeConfiguration() public {
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");

        // Gauge should be configured by setUp
        assertEq(dropAutomation.getGaugeCount(), 1, "should have 1 gauge configured");
        assertTrue(dropAutomation.isConfiguredGauge(gauge), "gauge should be configured");
        assertEq(address(dropAutomation.aerodromeGauges(0)), gauge, "first gauge should be the configured gauge");

        // Cannot add same gauge twice
        vm.prank(owner);
        vm.expectRevert("Gauge already configured");
        dropAutomation.addGauge(gauge);

        // Only owner can add gauge
        address attacker = makeAddr("attacker");
        address newGauge = makeAddr("newGauge");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.addGauge(newGauge);
    }

    function testTransferGaugePositionFromFMamo() public {
        // Gauge is already configured by setUp
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        // Check F-MAMO's current gauge balance
        IAerodromeGauge gaugeContract = IAerodromeGauge(gauge);
        uint256 fMamoBalance = gaugeContract.balanceOf(addresses.getAddress("F-MAMO"));

        if (fMamoBalance > 0) {
            // F-MAMO withdraws from gauge
            vm.startPrank(addresses.getAddress("F-MAMO"));
            gaugeContract.withdraw(fMamoBalance);

            // Get the LP token and transfer to DropAutomation
            IERC20 lpToken = IERC20(stakingToken);
            uint256 lpBalance = lpToken.balanceOf(addresses.getAddress("F-MAMO"));
            assertGt(lpBalance, 0, "F-MAMO should have LP tokens after withdrawal");

            // Re-deposit LP tokens to gauge with DropAutomation as recipient
            lpToken.approve(gauge, lpBalance);
            gaugeContract.deposit(lpBalance, address(dropAutomation));
            vm.stopPrank();

            // Verify staking
            assertEq(
                gaugeContract.balanceOf(address(dropAutomation)),
                lpBalance,
                "DropAutomation should have staked LP tokens"
            );
        }
    }

    function testHarvestGaugeRewards() public {
        // Gauge is already configured by setUp
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        // Transfer gauge position from F-MAMO to DropAutomation
        IAerodromeGauge gaugeContract = IAerodromeGauge(gauge);
        uint256 fMamoBalance = gaugeContract.balanceOf(addresses.getAddress("F-MAMO"));

        if (fMamoBalance > 0) {
            // F-MAMO withdraws and re-deposits with DropAutomation as recipient
            vm.startPrank(addresses.getAddress("F-MAMO"));
            gaugeContract.withdraw(fMamoBalance);

            IERC20 lpToken = IERC20(stakingToken);
            uint256 lpBalance = lpToken.balanceOf(addresses.getAddress("F-MAMO"));

            // Re-deposit LP tokens to gauge with DropAutomation as recipient
            lpToken.approve(gauge, lpBalance);
            gaugeContract.deposit(lpBalance, address(dropAutomation));
            vm.stopPrank();

            // Move time forward to accumulate rewards
            vm.warp(block.timestamp + 7 days);
            vm.roll(block.number + 50400); // ~7 days of blocks

            // Record balances before harvest
            address aeroToken = addresses.getAddress("AERO");
            IERC20 aero = IERC20(aeroToken);
            IERC20 cbBtc = IERC20(addresses.getAddress("cbBTC"));
            uint256 aeroBefore = aero.balanceOf(address(dropAutomation));
            uint256 cbBtcBefore = cbBtc.balanceOf(address(dropAutomation));

            // Only dedicatedMsgSender can call claimGaugeRewards
            vm.prank(dedicatedSender);
            dropAutomation.claimGaugeRewards();

            // Check if rewards were claimed (AERO balance should increase, no swapping yet)
            uint256 aeroAfter = aero.balanceOf(address(dropAutomation));

            // AERO balance should increase or stay same (claiming only, no swapping)
            assertGe(aeroAfter, aeroBefore, "AERO should be claimed from gauge");

            // cbBTC balance should not change (no swapping in claimGaugeRewards)
            uint256 cbBtcAfter = cbBtc.balanceOf(address(dropAutomation));
            assertEq(cbBtcAfter, cbBtcBefore, "cbBTC should not change during claim");
        }
    }

    function testWithdrawGauge() public {
        // Gauge is already configured by setUp
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        IAerodromeGauge gaugeContract = IAerodromeGauge(gauge);
        IERC20 lpToken = IERC20(stakingToken);

        // Get existing staked balance from FPS setup
        uint256 existingBalance = gaugeContract.balanceOf(address(dropAutomation));

        // Deal and stake additional LP tokens directly to gauge for DropAutomation
        uint256 amount = 1e18;
        deal(stakingToken, address(this), amount);

        lpToken.approve(gauge, amount);
        gaugeContract.deposit(amount, address(dropAutomation));

        uint256 stakedBalance = gaugeContract.balanceOf(address(dropAutomation));
        assertEq(stakedBalance, existingBalance + amount, "Should have staked balance");

        // Only owner can withdraw
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        dropAutomation.withdrawGauge(gauge, amount, makeAddr("recipient"));

        // Owner withdraws the amount we just added
        address recipient = makeAddr("recipient");
        vm.prank(owner);
        dropAutomation.withdrawGauge(gauge, amount, recipient);

        // Verify withdrawal - should have original balance minus what we withdrew
        assertEq(
            gaugeContract.balanceOf(address(dropAutomation)),
            existingBalance,
            "Staked balance should be back to original"
        );
        assertEq(lpToken.balanceOf(recipient), amount, "Recipient should receive LP tokens");
    }

    function testRecoverERC20WithZeroAmount() public {
        address testToken = address(wethToken);
        uint256 testAmount = 5e18;
        address recipient = makeAddr("emergencyRecipient");

        // Deal some tokens to the contract
        deal(testToken, address(dropAutomation), testAmount);

        // Verify initial balance
        assertEq(IERC20(testToken).balanceOf(address(dropAutomation)), testAmount, "Contract should have test tokens");
        assertEq(IERC20(testToken).balanceOf(recipient), 0, "Recipient should start with 0 tokens");

        // Only owner can call recover
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        dropAutomation.recoverERC20(testToken, recipient, 0);

        // Test invalid token address
        vm.prank(owner);
        vm.expectRevert("Invalid token");
        dropAutomation.recoverERC20(address(0), recipient, 0);

        // Test invalid recipient address
        vm.prank(owner);
        vm.expectRevert("Invalid recipient");
        dropAutomation.recoverERC20(testToken, address(0), 0);

        // Test withdraw all (amount = 0)
        vm.prank(owner);
        dropAutomation.recoverERC20(testToken, recipient, 0); // This should withdraw all

        // Now test with no balance (should revert)
        vm.prank(owner);
        vm.expectRevert("No balance to withdraw");
        dropAutomation.recoverERC20(testToken, recipient, 0);

        // Verify the successful withdrawal
        assertEq(
            IERC20(testToken).balanceOf(address(dropAutomation)), 0, "Contract should have 0 tokens after withdrawal"
        );
        assertEq(IERC20(testToken).balanceOf(recipient), testAmount, "Recipient should receive all tokens");
    }

    function testRecoverERC20EmitsEvent() public {
        address testToken = address(mamoToken);
        uint256 testAmount = 10e18;
        address recipient = makeAddr("eventRecipient");

        // Deal some tokens to the contract
        deal(testToken, address(dropAutomation), testAmount);

        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true);
        emit TokensRecovered(testToken, recipient, testAmount);

        // Execute recovery with specific amount
        vm.prank(owner);
        dropAutomation.recoverERC20(testToken, recipient, testAmount);
    }

    function testRecoverERC20PartialAmount() public {
        address token1 = address(wethToken);
        address token2 = address(mamoToken);
        uint256 amount1 = 10e18;
        uint256 amount2 = 20e18;
        uint256 withdrawAmount1 = 3e18;
        uint256 withdrawAmount2 = 7e18;
        address recipient = makeAddr("multiTokenRecipient");

        // Deal multiple tokens to the contract
        deal(token1, address(dropAutomation), amount1);
        deal(token2, address(dropAutomation), amount2);

        // Withdraw partial amount from first token
        vm.prank(owner);
        dropAutomation.recoverERC20(token1, recipient, withdrawAmount1);

        // Withdraw partial amount from second token
        vm.prank(owner);
        dropAutomation.recoverERC20(token2, recipient, withdrawAmount2);

        // Verify partial withdrawals
        assertEq(
            IERC20(token1).balanceOf(address(dropAutomation)),
            amount1 - withdrawAmount1,
            "Contract should have remaining token1"
        );
        assertEq(
            IERC20(token2).balanceOf(address(dropAutomation)),
            amount2 - withdrawAmount2,
            "Contract should have remaining token2"
        );
        assertEq(IERC20(token1).balanceOf(recipient), withdrawAmount1, "Recipient should receive partial token1");
        assertEq(IERC20(token2).balanceOf(recipient), withdrawAmount2, "Recipient should receive partial token2");
    }

    function testAddAndRemoveGauge() public {
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address aeroToken = addresses.getAddress("AERO");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        // Gauge already configured by setUp
        assertEq(dropAutomation.getGaugeCount(), 1, "should have 1 gauge from setUp");
        assertTrue(dropAutomation.isConfiguredGauge(gauge), "gauge should be configured");

        // Cannot add same gauge twice
        vm.prank(owner);
        vm.expectRevert("Gauge already configured");
        dropAutomation.addGauge(gauge);

        // Remove gauge
        vm.prank(owner);
        dropAutomation.removeGauge(gauge);

        // Verify removal
        assertEq(dropAutomation.getGaugeCount(), 0, "should have 0 gauges after removal");
        assertFalse(dropAutomation.isConfiguredGauge(gauge), "gauge should not be configured after removal");

        // Now can add it again
        vm.expectEmit(true, false, false, false);
        emit GaugeAdded(gauge);

        vm.prank(owner);
        dropAutomation.addGauge(gauge);

        // Verify re-addition
        assertEq(dropAutomation.getGaugeCount(), 1, "should have 1 gauge after re-adding");
        assertTrue(dropAutomation.isConfiguredGauge(gauge), "gauge should be configured again");
        assertEq(address(dropAutomation.aerodromeGauges(0)), gauge, "gauge should be at index 0");
    }

    // Update event definitions for the test
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event GaugeAdded(address indexed gauge);
}
