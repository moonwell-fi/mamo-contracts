// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {Vm} from "@forge-std/Vm.sol";
import {console} from "@forge-std/console.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoStakingRegistry} from "@contracts/MamoStakingRegistry.sol";
import {MamoStakingStrategy} from "@contracts/MamoStakingStrategy.sol";
import {MamoStakingStrategyFactory} from "@contracts/MamoStakingStrategyFactory.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StrategyFactory} from "@contracts/StrategyFactory.sol";

contract MamoStakingStrategyIntegrationTest is BaseTest {
    MamoStakingRegistry public stakingRegistry;
    MamoStakingStrategyFactory public stakingStrategyFactory;
    MamoStrategyRegistry public mamoStrategyRegistry;
    IMultiRewards public multiRewards;
    StrategyFactory public cbBTCStrategyFactory;

    IERC20 public mamoToken;
    address public user;
    address public stakingStrategyImplementation;
    address payable public userStrategy;

    function setUp() public override {
        super.setUp();

        // Get existing contract instances from addresses
        mamoStrategyRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        mamoToken = IERC20(addresses.getAddress("MAMO"));

        // Get the deployed contract instances
        stakingRegistry = MamoStakingRegistry(addresses.getAddress("MAMO_STAKING_REGISTRY"));
        stakingStrategyFactory = MamoStakingStrategyFactory(addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY"));
        multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        stakingStrategyImplementation = addresses.getAddress("MAMO_STAKING_STRATEGY");

        // Get the cbBTC strategy factory for testing reward distribution
        cbBTCStrategyFactory = StrategyFactory(addresses.getAddress("cbBTC_STRATEGY_FACTORY"));

        // Create test user
        user = makeAddr("testUser");
    }

    // Test basic deployment and functionality
    function testDeploymentWasSuccessful() public {
        // Verify all contracts were deployed
        assertTrue(address(stakingRegistry) != address(0), "MamoStakingRegistry should be deployed");
        assertTrue(address(stakingStrategyFactory) != address(0), "MamoStakingStrategyFactory should be deployed");
        assertTrue(address(multiRewards) != address(0), "MultiRewards should be deployed");
        assertTrue(stakingStrategyImplementation != address(0), "MamoStakingStrategy implementation should be deployed");

        // Verify factory configuration
        assertEq(stakingStrategyFactory.mamoToken(), address(mamoToken), "Factory should have correct MAMO token");
        assertEq(
            stakingStrategyFactory.multiRewards(), address(multiRewards), "Factory should have correct MultiRewards"
        );
        assertEq(
            stakingStrategyFactory.strategyImplementation(),
            stakingStrategyImplementation,
            "Factory should have correct implementation"
        );
    }

    function testMultiRewardsConfiguration() public {
        // Verify MultiRewards is configured with MAMO as staking token
        address mamoTokenAddr = addresses.getAddress("MAMO");
        assertEq(address(mamoToken), mamoTokenAddr, "MAMO token address should match");

        // Verify MultiRewards contract exists and is initialized
        assertTrue(address(multiRewards).code.length > 0, "MultiRewards should have code");
    }

    function testStakingRegistryConfiguration() public {
        // Verify staking registry configuration
        assertEq(stakingRegistry.mamoToken(), address(mamoToken), "Staking registry should have correct MAMO token");
        assertEq(stakingRegistry.defaultSlippageInBps(), 100, "Staking registry should have correct default slippage");
    }

    // Helper function to deploy a strategy for a user
    function _deployUserStrategy(address userAddress) internal returns (address payable) {
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");

        vm.startPrank(backend);
        address strategyAddress = stakingStrategyFactory.createStrategy(userAddress);
        vm.stopPrank();

        return payable(strategyAddress);
    }

    // Helper function to setup and execute a deposit
    function _setupAndDeposit(address depositor, address payable strategy, uint256 amount) internal {
        // Give tokens to depositor and approve
        deal(address(mamoToken), depositor, amount);
        vm.startPrank(depositor);
        mamoToken.approve(strategy, amount);

        // Execute deposit through the strategy
        MamoStakingStrategy(strategy).deposit(amount);
        vm.stopPrank();
    }

    // ========== DEPOSIT TESTS - HAPPY PATH ==========

    function testRandomUserCanDepositOnBehalfOfOwner() public {
        // Deploy strategy for user
        userStrategy = _deployUserStrategy(user);

        // Create a random depositor (different from the strategy owner)
        address randomDepositor = makeAddr("randomDepositor");
        uint256 depositAmount = 500 * 10 ** 18; // 500 MAMO tokens

        // Give MAMO tokens to the random depositor
        deal(address(mamoToken), randomDepositor, depositAmount);

        // Random depositor approves the strategy to spend their MAMO tokens
        vm.startPrank(randomDepositor);
        mamoToken.approve(userStrategy, depositAmount);

        // Random depositor deposits MAMO tokens into the user's strategy
        MamoStakingStrategy(userStrategy).deposit(depositAmount);
        vm.stopPrank();

        // Verify that the random depositor's balance decreased
        assertEq(mamoToken.balanceOf(randomDepositor), 0, "Random depositor MAMO balance should be 0 after deposit");

        // Verify that the strategy owner didn't spend any tokens
        assertEq(mamoToken.balanceOf(user), 0, "Strategy owner should not have spent any tokens");

        // Verify that the tokens were staked in MultiRewards
        assertEq(
            multiRewards.balanceOf(userStrategy), depositAmount, "Strategy should have staking balance in MultiRewards"
        );

        // Verify that only the strategy owner can withdraw
        vm.startPrank(randomDepositor);
        vm.expectRevert();
        MamoStakingStrategy(userStrategy).withdraw(depositAmount);
        vm.stopPrank();

        // But the strategy owner can withdraw the deposited funds
        vm.startPrank(user);
        MamoStakingStrategy(userStrategy).withdraw(depositAmount);
        vm.stopPrank();

        assertEq(mamoToken.balanceOf(user), depositAmount, "Strategy owner should receive the withdrawn tokens");
    }

    function testUserCanDepositIntoStrategy() public {
        // Deploy strategy for user
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18; // 1000 MAMO tokens

        // Setup and execute deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Verify that the deposit was successful - check that user balance decreased
        assertEq(mamoToken.balanceOf(user), 0, "User MAMO balance should be 0 after deposit");

        // Verify that the tokens were staked in MultiRewards
        assertEq(
            multiRewards.balanceOf(userStrategy), depositAmount, "Strategy should have staking balance in MultiRewards"
        );
    }

    function testMultipleUsersCanDepositSimultaneously() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        address payable strategy1 = _deployUserStrategy(user1);
        address payable strategy2 = _deployUserStrategy(user2);

        uint256 depositAmount1 = 500 * 10 ** 18;
        uint256 depositAmount2 = 750 * 10 ** 18;

        // Both users deposit
        _setupAndDeposit(user1, strategy1, depositAmount1);
        _setupAndDeposit(user2, strategy2, depositAmount2);

        // Verify both deposits
        assertEq(multiRewards.balanceOf(strategy1), depositAmount1, "Strategy1 should have correct balance");
        assertEq(multiRewards.balanceOf(strategy2), depositAmount2, "Strategy2 should have correct balance");
    }

    // ========== DEPOSIT TESTS - UNHAPPY PATH ==========

    function testDepositRevertsWhenMultiRewardsIsPaused() public {
        // Deploy strategy for user
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        deal(address(mamoToken), user, depositAmount);

        vm.startPrank(user);
        mamoToken.approve(userStrategy, depositAmount);
        vm.stopPrank();

        // Pause MultiRewards contract using its owner (F-MAMO)
        address multiRewardsOwner = addresses.getAddress("F-MAMO");
        vm.startPrank(multiRewardsOwner);
        multiRewards.setPaused(true);
        vm.stopPrank();

        // Attempt to deposit when MultiRewards is paused (should fail because stake() has notPaused modifier)
        vm.startPrank(user);
        vm.expectRevert("This action cannot be performed while the contract is paused");
        MamoStakingStrategy(userStrategy).deposit(depositAmount);
        vm.stopPrank();

        // Verify that MultiRewards can be unpaused and deposits work again
        vm.startPrank(multiRewardsOwner);
        multiRewards.setPaused(false);
        vm.stopPrank();

        // Now deposit should work
        vm.startPrank(user);
        MamoStakingStrategy(userStrategy).deposit(depositAmount);
        vm.stopPrank();

        // Verify deposit was successful
        assertEq(
            multiRewards.balanceOf(userStrategy), depositAmount, "Strategy should have staking balance after unpause"
        );
    }

    function testDepositRevertsWhenAmountIsZero() public {
        userStrategy = _deployUserStrategy(user);

        vm.startPrank(user);
        vm.expectRevert("Amount must be greater than 0");
        MamoStakingStrategy(userStrategy).deposit(0);
        vm.stopPrank();
    }

    function testDepositRevertsWhenInsufficientBalance() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        // Don't give user any tokens

        vm.startPrank(user);
        mamoToken.approve(userStrategy, depositAmount);

        // Attempt to deposit more than balance
        vm.expectRevert();
        MamoStakingStrategy(userStrategy).deposit(depositAmount);
        vm.stopPrank();
    }

    function testDepositRevertsWhenInsufficientAllowance() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        deal(address(mamoToken), user, depositAmount);

        vm.startPrank(user);
        // Approve less than deposit amount
        mamoToken.approve(userStrategy, depositAmount - 1);

        // Attempt to deposit more than allowance
        vm.expectRevert();
        MamoStakingStrategy(userStrategy).deposit(depositAmount);
        vm.stopPrank();
    }

    // ========== WITHDRAW TESTS - HAPPY PATH ==========

    function testUserCanWithdrawFullDeposit() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Verify initial state after deposit
        assertEq(multiRewards.balanceOf(userStrategy), depositAmount, "Should have staked balance");
        assertEq(mamoToken.balanceOf(user), 0, "User should have no MAMO tokens after deposit");

        // Withdraw full amount
        vm.startPrank(user);
        MamoStakingStrategy(userStrategy).withdraw(depositAmount);
        vm.stopPrank();

        // Verify withdraw was successful
        assertEq(multiRewards.balanceOf(userStrategy), 0, "Should have no staked balance after withdraw");
        assertEq(mamoToken.balanceOf(user), depositAmount, "User should have received all MAMO tokens back");
    }

    function testUserCanWithdrawPartialDeposit() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 withdrawAmount = 400 * 10 ** 18;
        uint256 remainingAmount = depositAmount - withdrawAmount;

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Verify initial state after deposit
        assertEq(multiRewards.balanceOf(userStrategy), depositAmount, "Should have full staked balance");
        assertEq(mamoToken.balanceOf(user), 0, "User should have no MAMO tokens after deposit");

        // Withdraw partial amount
        vm.startPrank(user);
        MamoStakingStrategy(userStrategy).withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify partial withdraw was successful
        assertEq(multiRewards.balanceOf(userStrategy), remainingAmount, "Should have remaining staked balance");
        assertEq(mamoToken.balanceOf(user), withdrawAmount, "User should have received withdrawn MAMO tokens");
    }

    function testWithdrawSucceedsWhenMultiRewardsIsPaused() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Pause MultiRewards contract
        address multiRewardsOwner = addresses.getAddress("F-MAMO");
        vm.startPrank(multiRewardsOwner);
        multiRewards.setPaused(true);
        vm.stopPrank();

        // Withdraw should succeed even when MultiRewards is paused (withdraw is not restricted by pause)
        vm.startPrank(user);
        MamoStakingStrategy(userStrategy).withdraw(depositAmount);
        vm.stopPrank();

        // Verify withdraw was successful
        assertEq(multiRewards.balanceOf(userStrategy), 0, "Should have no staked balance after withdraw");
        assertEq(mamoToken.balanceOf(user), depositAmount, "User should have received all MAMO tokens back");
    }

    // ========== WITHDRAW TESTS - UNHAPPY PATH ==========

    function testWithdrawRevertsWhenAmountIsZero() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Attempt to withdraw 0 amount
        vm.startPrank(user);
        vm.expectRevert("Amount must be greater than 0");
        MamoStakingStrategy(userStrategy).withdraw(0);
        vm.stopPrank();
    }

    function testWithdrawRevertsWhenInsufficientStakedBalance() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 withdrawAmount = 1500 * 10 ** 18; // More than deposited

        _setupAndDeposit(user, userStrategy, depositAmount);

        // Attempt to withdraw more than staked balance
        vm.startPrank(user);
        vm.expectRevert();
        MamoStakingStrategy(userStrategy).withdraw(withdrawAmount);
        vm.stopPrank();
    }

    function testWithdrawRevertsWhenNotOwner() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Create another user who is not the strategy owner
        address attacker = makeAddr("attacker");

        // Attempt to withdraw as non-owner
        vm.startPrank(attacker);
        vm.expectRevert();
        MamoStakingStrategy(userStrategy).withdraw(depositAmount);
        vm.stopPrank();
    }

    // ========== STAKING REGISTRY TESTS ==========

    // ========== MULTI-REWARDS INTEGRATION TESTS ==========

    function testMultiRewardsAccrualsBasic() public {
        userStrategy = _deployUserStrategy(user);
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Fast forward time to potentially accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Verify the staked balance is maintained
        assertEq(multiRewards.balanceOf(userStrategy), depositAmount, "Staked balance should be maintained");
    }

    function testMultiRewardsWithdrawAfterTimeElapsed() public {
        userStrategy = _deployUserStrategy(user);
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Fast forward time
        vm.warp(block.timestamp + 7 days);

        // Withdraw should still work after time elapsed
        vm.startPrank(user);
        MamoStakingStrategy(userStrategy).withdraw(depositAmount);
        vm.stopPrank();

        assertEq(multiRewards.balanceOf(userStrategy), 0, "Should have no staked balance after withdraw");
        assertEq(mamoToken.balanceOf(user), depositAmount, "User should have received all tokens back");
    }

    // ========== INTEGRATION WITH STRATEGY REGISTRY TESTS ==========

    function testStrategyRegistryImplementationMapping() public {
        userStrategy = _deployUserStrategy(user);

        // Verify the strategy is using the correct implementation
        // Import ERC1967Proxy to access getImplementation
        address implementation = ERC1967Proxy(userStrategy).getImplementation();
        assertEq(implementation, stakingStrategyImplementation, "Strategy should use correct implementation");
    }

    function testStrategyRegistryTypeIdMapping() public {
        userStrategy = _deployUserStrategy(user);

        // Get the implementation and verify its type ID
        address implementation = ERC1967Proxy(userStrategy).getImplementation();
        uint256 typeId = mamoStrategyRegistry.implementationToId(implementation);
        assertEq(typeId, 2, "Implementation should have correct strategy type ID");
    }

    // ========== ERROR HANDLING AND EDGE CASES ==========

    function testDepositWithExactAllowanceWorks() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        deal(address(mamoToken), user, depositAmount);

        vm.startPrank(user);
        // Approve exact amount
        mamoToken.approve(userStrategy, depositAmount);
        MamoStakingStrategy(userStrategy).deposit(depositAmount);
        vm.stopPrank();

        assertEq(multiRewards.balanceOf(userStrategy), depositAmount, "Deposit with exact allowance should work");
    }

    function testWithdrawExactBalanceWorks() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Withdraw exact balance
        vm.startPrank(user);
        MamoStakingStrategy(userStrategy).withdraw(depositAmount);
        vm.stopPrank();

        assertEq(multiRewards.balanceOf(userStrategy), 0, "Withdraw exact balance should work");
        assertEq(mamoToken.balanceOf(user), depositAmount, "User should receive exact amount");
    }

    function testWithdrawAllWorks() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Verify initial state
        assertEq(multiRewards.balanceOf(userStrategy), depositAmount, "Should have staked balance");
        assertEq(mamoToken.balanceOf(user), 0, "User should have no MAMO after deposit");

        // Withdraw all using withdrawAll function
        vm.startPrank(user);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(address(mamoToken), depositAmount);
        MamoStakingStrategy(userStrategy).withdrawAll();
        vm.stopPrank();

        // Verify withdraw all was successful
        assertEq(multiRewards.balanceOf(userStrategy), 0, "Should have no staked balance after withdrawAll");
        assertEq(mamoToken.balanceOf(user), depositAmount, "User should have received all MAMO tokens back");
    }

    function testWithdrawAllRevertsWhenNoTokensToWithdraw() public {
        userStrategy = _deployUserStrategy(user);

        // Attempt to withdrawAll when no tokens are staked
        vm.startPrank(user);
        vm.expectRevert("No tokens to withdraw");
        MamoStakingStrategy(userStrategy).withdrawAll();
        vm.stopPrank();
    }

    function testWithdrawAllRevertsWhenNotOwner() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Create another user who is not the strategy owner
        address attacker = makeAddr("attacker");

        // Attempt to withdrawAll as non-owner
        vm.startPrank(attacker);
        vm.expectRevert();
        MamoStakingStrategy(userStrategy).withdrawAll();
        vm.stopPrank();
    }

    function testWithdrawAllClaimsRewardsWhenExiting() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 mamoRewardAmount = 100 * 10 ** 18; // MAMO rewards
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Setup MAMO rewards in MultiRewards (will be included in withdraw)
        address multiRewardsOwner = addresses.getAddress("F-MAMO");
        vm.startPrank(multiRewardsOwner);

        // Check if MAMO is already added as a reward token
        (, uint256 existingDuration,,,,) = multiRewards.rewardData(address(mamoToken));
        if (existingDuration == 0) {
            multiRewards.addReward(address(mamoToken), multiRewardsOwner, 7 days);
        }

        // Give MAMO reward tokens to the owner and notify reward amount
        deal(address(mamoToken), multiRewardsOwner, mamoRewardAmount);
        mamoToken.approve(address(multiRewards), mamoRewardAmount);
        multiRewards.notifyRewardAmount(address(mamoToken), mamoRewardAmount);
        vm.stopPrank();

        // Setup cbBTC rewards in MultiRewards (will be transferred to user)
        address cbBTC = addresses.getAddress("cbBTC");
        vm.startPrank(multiRewardsOwner);

        // Check if cbBTC is already added as a reward token
        (, uint256 existingCbBTCDuration,,,,) = multiRewards.rewardData(cbBTC);
        if (existingCbBTCDuration == 0) {
            multiRewards.addReward(cbBTC, multiRewardsOwner, 7 days);
        }

        // Give cbBTC reward tokens to the owner and notify reward amount
        deal(cbBTC, multiRewardsOwner, cbBTCRewardAmount);
        IERC20(cbBTC).approve(address(multiRewards), cbBTCRewardAmount);
        multiRewards.notifyRewardAmount(cbBTC, cbBTCRewardAmount);
        vm.stopPrank();

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 7 days);

        // Check earned rewards before withdrawal
        uint256 earnedMamoRewards = multiRewards.earned(userStrategy, address(mamoToken));
        uint256 earnedCbBTCRewards = multiRewards.earned(userStrategy, cbBTC);
        uint256 initialCbBTCBalance = IERC20(cbBTC).balanceOf(user);

        // Withdraw all using withdrawAll function (which now uses exit)
        vm.startPrank(user);

        // Expect multiple Withdrawn events - one for MAMO and one for each reward token
        uint256 expectedMamoTotal = depositAmount + earnedMamoRewards;

        // First expect the MAMO withdrawal event
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(address(mamoToken), expectedMamoTotal);

        // Then expect the cbBTC withdrawal event
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(cbBTC, earnedCbBTCRewards);

        MamoStakingStrategy(userStrategy).withdrawAll();
        vm.stopPrank();

        // Verify withdraw all was successful
        assertEq(multiRewards.balanceOf(userStrategy), 0, "Should have no staked balance after withdrawAll");

        assertEq(mamoToken.balanceOf(user), expectedMamoTotal, "User should have received original MAMO + MAMO rewards");

        // Verify cbBTC rewards were transferred to user
        uint256 finalCbBTCBalance = IERC20(cbBTC).balanceOf(user);
        assertEq(finalCbBTCBalance, initialCbBTCBalance + earnedCbBTCRewards, "User should have received cbBTC rewards");

        // Verify strategy has no remaining reward tokens
        assertEq(mamoToken.balanceOf(userStrategy), 0, "Strategy should have no remaining MAMO");
        assertEq(IERC20(cbBTC).balanceOf(userStrategy), 0, "Strategy should have no remaining cbBTC");
    }

    function testWithdrawRewardsOnlyClaimsRewardsWithoutAffectingStake() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        address multiRewardsOwner = addresses.getAddress("F-MAMO");
        vm.startPrank(multiRewardsOwner);

        // Check if cbBTC is already added as a reward token
        (, uint256 existingCbBTCDuration,,,,) = multiRewards.rewardData(cbBTC);
        if (existingCbBTCDuration == 0) {
            multiRewards.addReward(cbBTC, multiRewardsOwner, 7 days);
        }

        // Give cbBTC reward tokens to the owner and notify reward amount
        deal(cbBTC, multiRewardsOwner, cbBTCRewardAmount);
        IERC20(cbBTC).approve(address(multiRewards), cbBTCRewardAmount);
        multiRewards.notifyRewardAmount(cbBTC, cbBTCRewardAmount);
        vm.stopPrank();

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 7 days);

        // Check earned rewards and initial balances
        uint256 earnedCbBTCRewards = multiRewards.earned(userStrategy, cbBTC);
        uint256 initialCbBTCBalance = IERC20(cbBTC).balanceOf(user);

        // Verify initial staked balance
        uint256 initialStakedBalance = multiRewards.balanceOf(userStrategy);
        assertEq(initialStakedBalance, depositAmount, "Should have original staked balance");

        // Withdraw rewards using withdrawRewards function
        vm.startPrank(user);

        // Expect Withdrawn event for cbBTC reward token
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(cbBTC, earnedCbBTCRewards);

        MamoStakingStrategy(userStrategy).withdrawRewards();
        vm.stopPrank();

        // Verify staked balance unchanged
        assertEq(multiRewards.balanceOf(userStrategy), depositAmount, "Staked balance should remain unchanged");

        // Verify rewards were claimed and transferred
        uint256 finalCbBTCBalance = IERC20(cbBTC).balanceOf(user);
        assertEq(finalCbBTCBalance, initialCbBTCBalance + earnedCbBTCRewards, "User should have received cbBTC rewards");

        // Verify strategy has no remaining reward tokens
        assertEq(IERC20(cbBTC).balanceOf(userStrategy), 0, "Strategy should have no remaining cbBTC rewards");
    }

    function testWithdrawRewardsRevertsWhenNotOwner() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Create another user who is not the strategy owner
        address attacker = makeAddr("attacker");

        // Attempt to withdrawRewards as non-owner
        vm.startPrank(attacker);
        vm.expectRevert();
        MamoStakingStrategy(userStrategy).withdrawRewards();
        vm.stopPrank();
    }

    // ========== VIEW FUNCTION TESTS ==========

    function testStrategyViewFunctions() public {
        userStrategy = _deployUserStrategy(user);

        // Test strategy configuration views
        MamoStakingStrategy strategy = MamoStakingStrategy(userStrategy);
        assertEq(strategy.owner(), user, "Strategy should have correct owner");
        assertEq(address(strategy.mamoToken()), address(mamoToken), "Strategy should have correct MAMO token");
        assertEq(address(strategy.multiRewards()), address(multiRewards), "Strategy should have correct MultiRewards");
    }

    // ========== COMPOUND FUNCTIONALITY TESTS ==========

    function testProcessRewardsCompoundModeWithoutRewards() public {
        userStrategy = _deployUserStrategy(user);
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Process rewards in compound mode (no rewards to claim)
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);

        // Should not revert even with no rewards
        MamoStakingStrategy(userStrategy).compound();
        vm.stopPrank();

        // Verify the original deposit is still there
        assertEq(multiRewards.balanceOf(userStrategy), depositAmount, "Original deposit should remain");
    }

    function testProcessRewardsDefaultsToCompoundMode() public {
        userStrategy = _deployUserStrategy(user);
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);

        // Process rewards with COMPOUND mode explicitly
        MamoStakingStrategy(userStrategy).compound();
        vm.stopPrank();

        // Verify deposit is maintained
        assertEq(multiRewards.balanceOf(userStrategy), depositAmount, "Deposit should be maintained");
    }

    function testProcessRewardsReinvestModeRequiresStrategies() public {
        userStrategy = _deployUserStrategy(user);
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);

        // Get reward tokens to know how many strategies we need
        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();

        if (rewardTokens.length > 0) {
            // Create insufficient strategies array
            address[] memory insufficientStrategies = new address[](rewardTokens.length - 1);

            // Should revert with strategies length mismatch
            vm.expectRevert("Strategies length mismatch");
            MamoStakingStrategy(userStrategy).reinvest(insufficientStrategies);
        }
        vm.stopPrank();
    }

    function testSetAccountSlippageByOwner() public {
        userStrategy = _deployUserStrategy(user);

        // Update slippage as owner
        uint256 newSlippage = 150;
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true);
        emit AccountSlippageUpdated(0, newSlippage);
        MamoStakingStrategy(userStrategy).setAccountSlippage(newSlippage);
        vm.stopPrank();

        // Verify slippage was updated
        assertEq(MamoStakingStrategy(userStrategy).getAccountSlippage(), newSlippage, "Slippage should be updated");
    }

    function testSetAccountSlippageRevertsWhenNotOwner() public {
        userStrategy = _deployUserStrategy(user);
        address attacker = makeAddr("attacker");

        // Attempt to set slippage as non-owner
        vm.startPrank(attacker);
        vm.expectRevert();
        MamoStakingStrategy(userStrategy).setAccountSlippage(150);
        vm.stopPrank();
    }

    function testSetAccountSlippageRevertsWhenTooHigh() public {
        userStrategy = _deployUserStrategy(user);

        // Attempt to set slippage above maximum
        vm.startPrank(user);
        vm.expectRevert("Slippage too high");
        MamoStakingStrategy(userStrategy).setAccountSlippage(2501); // Above 25%
        vm.stopPrank();
    }

    function testGetAccountSlippageFallsBackToDefault() public {
        userStrategy = _deployUserStrategy(user);

        // Initially should return account-specific slippage (set during initialization)
        uint256 accountSlippage = MamoStakingStrategy(userStrategy).getAccountSlippage();
        assertEq(accountSlippage, 100, "Should return account-specific slippage");

        // Reset account slippage to 0 to test fallback
        vm.startPrank(user);
        MamoStakingStrategy(userStrategy).setAccountSlippage(0);
        vm.stopPrank();

        // Should fall back to default from registry
        uint256 fallbackSlippage = MamoStakingStrategy(userStrategy).getAccountSlippage();
        uint256 expectedDefault = stakingRegistry.defaultSlippageInBps();
        assertEq(fallbackSlippage, expectedDefault, "Should fall back to registry default");
    }

    function testStrategyUsesRegistryForRewardTokens() public {
        userStrategy = _deployUserStrategy(user);

        // Deploy strategy first, then test that processRewards works with registry reward tokens
        uint256 depositAmount = 1000 * 10 ** 18;
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Get reward tokens from registry
        MamoStakingRegistry.RewardToken[] memory registryRewardTokens = stakingRegistry.getRewardTokens();

        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);

        // Create strategies array with correct length for reinvest mode
        address[] memory strategies = new address[](registryRewardTokens.length);

        // This should not revert, indicating strategy correctly uses registry for reward tokens
        MamoStakingStrategy(userStrategy).reinvest(strategies);
        vm.stopPrank();

        // Verify original deposit is maintained
        assertEq(multiRewards.balanceOf(userStrategy), depositAmount, "Deposit should be maintained");
    }

    function testProcessRewardsOnlyCallableByBackend() public {
        userStrategy = _deployUserStrategy(user);
        address attacker = makeAddr("attacker");

        // Attempt to process rewards as non-backend
        vm.startPrank(attacker);
        vm.expectRevert("Not backend");
        MamoStakingStrategy(userStrategy).compound();
        vm.stopPrank();

        // Attempt to process rewards as owner (should also fail)
        vm.startPrank(user);
        vm.expectRevert("Not backend");
        MamoStakingStrategy(userStrategy).compound();
        vm.stopPrank();

        // Should work as backend
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);
        MamoStakingStrategy(userStrategy).compound();
        vm.stopPrank();
    }

    function testCompoundModeProcessing() public {
        userStrategy = _deployUserStrategy(user);
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Verify initial staked balance
        uint256 initialBalance = multiRewards.balanceOf(userStrategy);
        assertEq(initialBalance, depositAmount, "Initial balance should match deposit");

        // Simulate time passing to accrue rewards
        vm.warp(block.timestamp + 7 days);

        // Fast forward several blocks to potentially trigger reward accrual
        vm.roll(block.number + 100);

        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);

        // Process rewards in compound mode - this will claim any accrued rewards
        MamoStakingStrategy(userStrategy).compound();
        vm.stopPrank();

        // Check the balance after processing rewards
        uint256 finalBalance = multiRewards.balanceOf(userStrategy);

        // The balance might be the same if no rewards were distributed, or higher if rewards were compounded
        assertTrue(
            finalBalance >= initialBalance,
            "Balance should be at least the same, potentially higher with compounded rewards"
        );

        // Log for debugging
        console.log("Initial balance:", initialBalance);
        console.log("Final balance after compound:", finalBalance);
        if (finalBalance > initialBalance) {
            console.log("Rewards compounded successfully!");
        }
    }

    function testCompoundModeEmitsCorrectEvents() public {
        userStrategy = _deployUserStrategy(user);
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Setup cbBTC rewards in MultiRewards to have actual rewards to compound
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Verify we have some rewards to compound
        uint256 earnedCbBTCRewards = multiRewards.earned(userStrategy, cbBTC);
        if (earnedCbBTCRewards > 0) {
            address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
            vm.startPrank(backend);

            // Expect the new CompoundRewardTokenProcessed event with amountIn and amountOut
            vm.expectEmit(true, false, false, false);
            emit CompoundRewardTokenProcessed(cbBTC, 0, 0); // amounts will be checked separately

            MamoStakingStrategy(userStrategy).compound();
            vm.stopPrank();
        }
    }

    function testReinvestModeEmitsCorrectEvents() public {
        userStrategy = _deployUserStrategy(user);
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Setup cbBTC strategy for the same user
        address cbBTCStrategy = _setupCbBTCStrategy(user);

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Verify we have some rewards to reinvest
        uint256 earnedCbBTCRewards = multiRewards.earned(userStrategy, cbBTC);
        if (earnedCbBTCRewards > 0) {
            address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
            vm.startPrank(backend);

            // Get reward tokens to create strategies array
            MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();
            address[] memory strategies = new address[](rewardTokens.length);

            // Find cbBTC index and set the strategy
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                if (rewardTokens[i].token == cbBTC) {
                    strategies[i] = cbBTCStrategy;
                    break;
                }
            }

            // Expect the new ReinvestRewardTokenProcessed event (only amountIn, no amountOut)
            vm.expectEmit(true, false, false, false);
            emit ReinvestRewardTokenProcessed(cbBTC, 0); // amount will be checked separately

            MamoStakingStrategy(userStrategy).reinvest(strategies);
            vm.stopPrank();
        }
    }

    function testEventParametersAreAccurate() public {
        userStrategy = _deployUserStrategy(user);
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 cbBTCRewardAmount = 5 * 10 ** 8; // Larger amount for better testing

        // Setup and deposit
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue substantial rewards
        vm.warp(block.timestamp + 2 days);

        uint256 earnedCbBTCRewards = multiRewards.earned(userStrategy, cbBTC);

        if (earnedCbBTCRewards > 1000) {
            // Only test if we have meaningful rewards
            address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
            vm.startPrank(backend);

            // Record events manually to verify parameters
            vm.recordLogs();

            MamoStakingStrategy(userStrategy).compound();

            Vm.Log[] memory logs = vm.getRecordedLogs();

            // Find CompoundRewardTokenProcessed event
            bool foundEvent = false;
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].topics[0] == keccak256("CompoundRewardTokenProcessed(address,uint256,uint256)")) {
                    foundEvent = true;

                    // Decode event data
                    address eventRewardToken = address(uint160(uint256(logs[i].topics[1])));
                    (uint256 amountIn, uint256 amountOut) = abi.decode(logs[i].data, (uint256, uint256));

                    // Verify event parameters
                    assertEq(eventRewardToken, cbBTC, "Event should emit correct reward token");
                    assertTrue(amountIn > 0, "Event should emit non-zero amountIn");
                    assertTrue(amountOut > 0, "Event should emit non-zero amountOut");

                    break;
                }
            }

            assertTrue(foundEvent, "CompoundRewardTokenProcessed event should be emitted");
            vm.stopPrank();
        }
    }

    // Helper function to setup cbBTC strategy for a user
    function _setupCbBTCStrategy(address userAddress) internal returns (address) {
        // Create a cbBTC strategy for the user using the factory
        // Check if the cbBTC factory has a different backend or use the user directly
        address cbBTCBackend = addresses.getAddress("MAMO_BACKEND");

        vm.startPrank(cbBTCBackend);
        address cbBTCStrategy = cbBTCStrategyFactory.createStrategyForUser(userAddress);
        vm.stopPrank();

        return cbBTCStrategy;
    }

    // Helper function to setup rewards in MultiRewards contract
    function _setupRewardsInMultiRewards(address rewardToken, uint256 rewardAmount, uint256 duration) internal {
        address multiRewardsOwner = addresses.getAddress("F-MAMO");

        // Add reward token to MultiRewards (as owner)
        vm.startPrank(multiRewardsOwner);

        // Check if reward token is already added by checking if rewardsDuration > 0
        (, uint256 existingDuration,,,,) = multiRewards.rewardData(rewardToken);
        if (existingDuration == 0) {
            multiRewards.addReward(rewardToken, multiRewardsOwner, duration);
        }

        // Give reward tokens to the owner and notify reward amount
        deal(rewardToken, multiRewardsOwner, rewardAmount);
        IERC20(rewardToken).approve(address(multiRewards), rewardAmount);
        multiRewards.notifyRewardAmount(rewardToken, rewardAmount);

        vm.stopPrank();
    }

    // ========== REINVEST MODE TESTS ==========

    function testProcessRewardsReinvestModeWithCbBTCRewards() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 mamoRewardAmount = 50 * 10 ** 18; // Add MAMO rewards
        uint256 cbBTCRewardAmount = 10 * 10 ** 8; // cbBTC has 8 decimals - increased for better precision

        // Setup cbBTC strategy for the same user
        address cbBTCStrategy = _setupCbBTCStrategy(user);

        // Setup and deposit using helper function
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Setup MAMO rewards in MultiRewards
        _setupRewardsInMultiRewards(address(mamoToken), mamoRewardAmount, 7 days);

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Get initial state
        uint256 initialStakedBalance = multiRewards.balanceOf(userStrategy);
        uint256 earnedMamoRewards = multiRewards.earned(userStrategy, address(mamoToken));
        uint256 earnedCbBTCRewards = multiRewards.earned(userStrategy, cbBTC);

        // Get initial strategy token balances (mToken and Morpho vault shares)
        address mToken = addresses.getAddress("MOONWELL_cbBTC");
        address morphoVault = addresses.getAddress("cbBTC_METAMORPHO_VAULT");
        uint256 initialMTokenBalance = IERC20(mToken).balanceOf(cbBTCStrategy);
        uint256 initialMorphoBalance = IERC20(morphoVault).balanceOf(cbBTCStrategy);

        // Process rewards as backend in reinvest mode
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);

        // Create strategies array for reinvest mode (cbBTC strategy for cbBTC rewards)
        address[] memory strategies = new address[](1);
        strategies[0] = cbBTCStrategy;

        MamoStakingStrategy(userStrategy).reinvest(strategies);
        vm.stopPrank();

        // Verify both rewards were earned
        assertGt(earnedMamoRewards, 0, "Should have earned some MAMO rewards");
        assertGt(earnedCbBTCRewards, 0, "Should have earned some cbBTC rewards");

        // Verify MAMO was restaked in MultiRewards
        assertEq(
            multiRewards.balanceOf(userStrategy),
            initialStakedBalance + earnedMamoRewards,
            "Should have restaked all MAMO rewards"
        );

        // Verify the staking strategy has no remaining reward tokens
        assertEq(mamoToken.balanceOf(userStrategy), 0, "Strategy should have no remaining MAMO");
        assertEq(IERC20(cbBTC).balanceOf(userStrategy), 0, "Strategy should have no remaining cbBTC");

        // Verify cbBTC was deposited to strategy by checking strategy token balances increased
        // The strategy converts cbBTC to mTokens or deposits to Morpho vault
        uint256 finalMTokenBalance = IERC20(mToken).balanceOf(cbBTCStrategy);
        uint256 finalMorphoBalance = IERC20(morphoVault).balanceOf(cbBTCStrategy);

        bool strategyBalanceIncreased =
            (finalMTokenBalance > initialMTokenBalance) || (finalMorphoBalance > initialMorphoBalance);
        assertTrue(
            strategyBalanceIncreased, "Strategy should have received deposited cbBTC (as mTokens or Morpho shares)"
        );
    }

    function testProcessRewardsFailsWhenStrategyOwnershipMismatch() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Create another user who will own the cbBTC strategy
        address otherUser = makeAddr("otherUser");

        // Setup cbBTC strategy owned by different user
        address cbBTCStrategy = _setupCbBTCStrategy(otherUser);

        // Setup and deposit using helper function (user's staking strategy)
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 7 days);

        // Process rewards as backend - this should fail because cbBTC strategy is owned by different user
        address backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(backend);

        address[] memory strategies = new address[](1);
        strategies[0] = cbBTCStrategy;

        vm.expectRevert("Strategy owner mismatch");
        MamoStakingStrategy(userStrategy).reinvest(strategies);
        vm.stopPrank();
    }

    function testProcessRewardsFailsWhenStrategyNotRegistered() public {
        userStrategy = _deployUserStrategy(user);

        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Setup cbBTC strategy owned by the same user but not in registry
        address cbBTCStrategy = _setupCbBTCStrategy(user);

        // Test with a fake address that simulates an unregistered strategy
        // We'll create a simple contract that pretends to be a strategy but isn't registered
        address fakeStrategy = makeAddr("fakeStrategy");

        // Mock the strategy to return the correct owner and token
        vm.mockCall(fakeStrategy, abi.encodeWithSignature("owner()"), abi.encode(user));
        vm.mockCall(fakeStrategy, abi.encodeWithSignature("token()"), abi.encode(addresses.getAddress("cbBTC")));

        // Setup and deposit using helper function (user's staking strategy)
        _setupAndDeposit(user, userStrategy, depositAmount);

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 7 days);

        // Process rewards as backend - this should fail because strategy is not registered
        address stakingBackend = addresses.getAddress("MAMO_STAKING_BACKEND");
        vm.startPrank(stakingBackend);

        address[] memory strategies = new address[](1);
        strategies[0] = fakeStrategy;

        vm.expectRevert("Strategy not registered");
        MamoStakingStrategy(userStrategy).reinvest(strategies);
        vm.stopPrank();
    }

    // Event declarations
    event AccountSlippageUpdated(uint256 oldSlippageInBps, uint256 newSlippageInBps);
    event Withdrawn(address indexed token, uint256 amount);
    event CompoundRewardTokenProcessed(address indexed rewardToken, uint256 amountIn, uint256 amountOut);
    event ReinvestRewardTokenProcessed(address indexed rewardToken, uint256 amount);
}
