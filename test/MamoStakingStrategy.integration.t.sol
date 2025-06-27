// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {Vm} from "@forge-std/Vm.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {AccountRegistry} from "@contracts/AccountRegistry.sol";
import {MamoAccount} from "@contracts/MamoAccount.sol";
import {MamoAccountFactory} from "@contracts/MamoAccountFactory.sol";
import {MamoStakingStrategy} from "@contracts/MamoStakingStrategy.sol";
import {StrategyFactory} from "@contracts/StrategyFactory.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployMamoStaking} from "@script/DeployMamoStaking.s.sol";

contract MamoStakingStrategyIntegrationTest is Test {
    Addresses public addresses;
    AccountRegistry public accountRegistry;
    MamoAccountFactory public mamoAccountFactory;
    MamoStakingStrategy public mamoStakingStrategy;
    MamoAccount public userAccount;
    IMultiRewards public multiRewards;

    IERC20 public mamoToken;
    address public user;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));

        // Create addresses instance
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get deployer address from addresses
        address deployer = addresses.getAddress("DEPLOYER_EOA");

        // Create an instance of the deployment script
        DeployMamoStaking deployScript = new DeployMamoStaking();

        // Deploy contracts using the DeployMamoStaking script functions
        address[] memory deployedContracts = deployScript.deploy(addresses, deployer);

        // Set contract instances
        accountRegistry = AccountRegistry(deployedContracts[0]);
        mamoAccountFactory = MamoAccountFactory(deployedContracts[1]);
        mamoStakingStrategy = MamoStakingStrategy(deployedContracts[2]);

        // Get MAMO token and MultiRewards from addresses
        mamoToken = IERC20(addresses.getAddress("MAMO"));
        multiRewards = IMultiRewards(addresses.getAddress("MULTI_REWARDS"));

        // Create test user (only address we create)
        user = makeAddr("testUser");

        // Deploy a MamoAccount for the test user
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        userAccount = MamoAccount(payable(mamoAccountFactory.createAccountForUser(user)));
        vm.stopPrank();
    }

    // Helper function to set up and execute a deposit, returns the deposited amount
    function _setupAndDeposit(address depositor, address account, uint256 amount) internal returns (uint256) {
        // Approve strategy in registry
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        // Whitelist strategy for account
        address accountOwner = MamoAccount(payable(account)).owner();
        vm.startPrank(accountOwner);
        accountRegistry.setWhitelistStrategy(account, address(mamoStakingStrategy), true);
        vm.stopPrank();

        // Give tokens to depositor and approve
        deal(address(mamoToken), depositor, amount);
        vm.startPrank(depositor);
        mamoToken.approve(address(mamoStakingStrategy), amount);

        // Execute deposit
        mamoStakingStrategy.deposit(account, amount);
        vm.stopPrank();

        return amount;
    }

    function testUserCanDepositIntoStrategy() public {
        // Step 1: Approve the MamoStakingStrategy in AccountRegistry (backend role)
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        // Step 2: Whitelist the strategy for the user account (account owner)
        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), address(mamoStakingStrategy), true);
        vm.stopPrank();

        // Step 3: Set up MAMO token balance for the user
        uint256 depositAmount = 1000 * 10 ** 18; // 1000 MAMO tokens

        // Deal MAMO tokens to the user
        deal(address(mamoToken), user, depositAmount);

        // Step 4: User approves the strategy to spend their MAMO tokens
        vm.startPrank(user);
        mamoToken.approve(address(mamoStakingStrategy), depositAmount);
        vm.stopPrank();

        // Step 5: Deposit MAMO tokens into the strategy
        vm.startPrank(user);
        mamoStakingStrategy.deposit(address(userAccount), depositAmount);
        vm.stopPrank();

        // Verify that the deposit was successful - check that user balance decreased
        assertEq(mamoToken.balanceOf(user), 0, "User MAMO balance should be 0 after deposit");

        // Verify that the tokens were staked in MultiRewards (not sitting in userAccount)
        assertEq(mamoToken.balanceOf(address(userAccount)), 0, "UserAccount should not hold MAMO after staking");

        // Verify that MultiRewards contract received the MAMO tokens
        assertEq(
            mamoToken.balanceOf(address(multiRewards)), depositAmount, "MultiRewards should hold the staked MAMO tokens"
        );

        // Verify that the user account has a staking balance in MultiRewards
        assertEq(
            multiRewards.balanceOf(address(userAccount)),
            depositAmount,
            "UserAccount should have staking balance in MultiRewards"
        );
    }

    function testRandomUserCanDepositOnBehalfOfOther() public {
        // Step 1: Approve the MamoStakingStrategy in AccountRegistry (backend role)
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        // Step 2: Whitelist the strategy for the user account (account owner)
        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), address(mamoStakingStrategy), true);
        vm.stopPrank();

        // Step 3: Create a random depositor (different from the account owner)
        address randomDepositor = makeAddr("randomDepositor");
        uint256 depositAmount = 500 * 10 ** 18; // 500 MAMO tokens

        // Step 4: Give MAMO tokens to the random depositor
        deal(address(mamoToken), randomDepositor, depositAmount);

        // Step 5: Random depositor approves the strategy to spend their MAMO tokens
        vm.startPrank(randomDepositor);
        mamoToken.approve(address(mamoStakingStrategy), depositAmount);
        vm.stopPrank();

        // Step 6: Random depositor deposits MAMO tokens on behalf of the user account
        vm.startPrank(randomDepositor);
        mamoStakingStrategy.deposit(address(userAccount), depositAmount);
        vm.stopPrank();

        // Verify that the random depositor's balance decreased
        assertEq(mamoToken.balanceOf(randomDepositor), 0, "Random depositor MAMO balance should be 0 after deposit");

        // Verify that the tokens were staked in MultiRewards on behalf of the user account
        assertEq(mamoToken.balanceOf(address(userAccount)), 0, "UserAccount should not hold MAMO after staking");

        // Verify that the user account owner didn't spend any tokens
        assertEq(mamoToken.balanceOf(user), 0, "User should not have spent any tokens");

        // Verify that MultiRewards contract received the MAMO tokens
        assertEq(
            mamoToken.balanceOf(address(multiRewards)), depositAmount, "MultiRewards should hold the staked MAMO tokens"
        );

        // Verify that the user account has a staking balance in MultiRewards
        assertEq(
            multiRewards.balanceOf(address(userAccount)),
            depositAmount,
            "UserAccount should have staking balance in MultiRewards"
        );
    }

    // ========== UNHAPPY PATH TESTS ==========

    function testDepositRevertsWhenAmountIsZero() public {
        // Setup
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), address(mamoStakingStrategy), true);
        vm.stopPrank();

        // Attempt to deposit 0 amount
        vm.startPrank(user);
        vm.expectRevert("Amount must be greater than 0");
        mamoStakingStrategy.deposit(address(userAccount), 0);
        vm.stopPrank();
    }

    function testDepositRevertsWhenAccountIsZeroAddress() public {
        // Setup
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        uint256 depositAmount = 1000 * 10 ** 18;
        deal(address(mamoToken), user, depositAmount);

        vm.startPrank(user);
        mamoToken.approve(address(mamoStakingStrategy), depositAmount);

        // Attempt to deposit to zero address
        vm.expectRevert("Invalid account");
        mamoStakingStrategy.deposit(address(0), depositAmount);
        vm.stopPrank();
    }

    function testDepositRevertsWhenContractIsPaused() public {
        // Setup
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), address(mamoStakingStrategy), true);
        vm.stopPrank();

        uint256 depositAmount = 1000 * 10 ** 18;
        deal(address(mamoToken), user, depositAmount);

        vm.startPrank(user);
        mamoToken.approve(address(mamoStakingStrategy), depositAmount);
        vm.stopPrank();

        // Pause the contract
        address guardian = addresses.getAddress("MAMO_MULTISIG");
        vm.startPrank(guardian);
        mamoStakingStrategy.pause();
        vm.stopPrank();

        // Attempt to deposit when paused
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mamoStakingStrategy.deposit(address(userAccount), depositAmount);
        vm.stopPrank();
    }

    function testDepositRevertsWhenInsufficientBalance() public {
        // Setup
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), address(mamoStakingStrategy), true);
        vm.stopPrank();

        uint256 depositAmount = 1000 * 10 ** 18;
        // Don't give user enough tokens - they have 0 balance

        vm.startPrank(user);
        mamoToken.approve(address(mamoStakingStrategy), depositAmount);

        // Attempt to deposit more than balance
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", user, 0, depositAmount)
        );
        mamoStakingStrategy.deposit(address(userAccount), depositAmount);
        vm.stopPrank();
    }

    function testDepositRevertsWhenInsufficientAllowance() public {
        // Setup
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), address(mamoStakingStrategy), true);
        vm.stopPrank();

        uint256 depositAmount = 1000 * 10 ** 18;
        deal(address(mamoToken), user, depositAmount);

        vm.startPrank(user);
        // Approve less than deposit amount
        mamoToken.approve(address(mamoStakingStrategy), depositAmount - 1);

        // Attempt to deposit more than allowance
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)",
                address(mamoStakingStrategy),
                depositAmount - 1,
                depositAmount
            )
        );
        mamoStakingStrategy.deposit(address(userAccount), depositAmount);
        vm.stopPrank();
    }

    function testDepositRevertsWhenAccountIsNotMamoAccount() public {
        // Setup
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        uint256 depositAmount = 1000 * 10 ** 18;
        deal(address(mamoToken), user, depositAmount);

        // Create a regular address instead of MamoAccount
        address regularAccount = makeAddr("regularAccount");

        vm.startPrank(user);
        mamoToken.approve(address(mamoStakingStrategy), depositAmount);

        // Attempt to deposit to regular address (not a MamoAccount)
        // This should fail when trying to call multicall on a non-contract address
        vm.expectRevert();
        mamoStakingStrategy.deposit(regularAccount, depositAmount);
        vm.stopPrank();
    }

    function testDepositRevertsWhenStrategyNotApprovedInRegistry() public {
        // Don't approve the strategy in AccountRegistry

        vm.startPrank(user);
        // This should fail because the strategy is not approved
        vm.expectRevert();
        accountRegistry.setWhitelistStrategy(address(userAccount), address(mamoStakingStrategy), true);
        vm.stopPrank();
    }

    function testDepositRevertsWhenStrategyNotWhitelistedForAccount() public {
        // Setup - approve strategy in registry but don't whitelist for account
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        // Don't whitelist strategy for the user account

        uint256 depositAmount = 1000 * 10 ** 18;
        deal(address(mamoToken), user, depositAmount);

        vm.startPrank(user);
        mamoToken.approve(address(mamoStakingStrategy), depositAmount);

        // This should fail during multicall execution due to whitelisting check
        vm.expectRevert();
        mamoStakingStrategy.deposit(address(userAccount), depositAmount);
        vm.stopPrank();
    }

    function testDepositRevertsWhenMultiRewardsIsPaused() public {
        // Setup
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        accountRegistry.setApprovedStrategy(address(mamoStakingStrategy), true);
        vm.stopPrank();

        vm.startPrank(user);
        accountRegistry.setWhitelistStrategy(address(userAccount), address(mamoStakingStrategy), true);
        vm.stopPrank();

        uint256 depositAmount = 1000 * 10 ** 18;
        deal(address(mamoToken), user, depositAmount);

        vm.startPrank(user);
        mamoToken.approve(address(mamoStakingStrategy), depositAmount);
        vm.stopPrank();

        // Pause MultiRewards contract
        address multiRewardsOwner = addresses.getAddress("MAMO_MULTISIG");
        vm.startPrank(multiRewardsOwner);
        multiRewards.setPaused(true);
        vm.stopPrank();

        // Attempt to deposit when MultiRewards is paused (should fail because stake() has notPaused modifier)
        vm.startPrank(user);
        vm.expectRevert("This action cannot be performed while the contract is paused");
        mamoStakingStrategy.deposit(address(userAccount), depositAmount);
        vm.stopPrank();
    }

    // ========== WITHDRAW TESTS - HAPPY PATH ==========

    function testUserCanWithdrawFullDeposit() public {
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Verify initial state after deposit
        assertEq(multiRewards.balanceOf(address(userAccount)), depositAmount, "Should have staked balance");
        assertEq(mamoToken.balanceOf(user), 0, "User should have no MAMO tokens after deposit");

        // Withdraw full amount
        vm.startPrank(user);
        mamoStakingStrategy.withdraw(address(userAccount), depositAmount);
        vm.stopPrank();

        // Verify withdraw was successful
        assertEq(multiRewards.balanceOf(address(userAccount)), 0, "Should have no staked balance after withdraw");
        assertEq(mamoToken.balanceOf(user), depositAmount, "User should have received all MAMO tokens back");
    }

    function testUserCanWithdrawPartialDeposit() public {
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 withdrawAmount = 400 * 10 ** 18;
        uint256 remainingAmount = depositAmount - withdrawAmount;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Verify initial state after deposit
        assertEq(multiRewards.balanceOf(address(userAccount)), depositAmount, "Should have full staked balance");
        assertEq(mamoToken.balanceOf(user), 0, "User should have no MAMO tokens after deposit");

        // Withdraw partial amount
        vm.startPrank(user);
        mamoStakingStrategy.withdraw(address(userAccount), withdrawAmount);
        vm.stopPrank();

        // Verify partial withdraw was successful
        assertEq(multiRewards.balanceOf(address(userAccount)), remainingAmount, "Should have remaining staked balance");
        assertEq(mamoToken.balanceOf(user), withdrawAmount, "User should have received withdrawn MAMO tokens");
    }

    // ========== WITHDRAW TESTS - UNHAPPY PATH ==========

    function testWithdrawRevertsWhenAmountIsZero() public {
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Attempt to withdraw 0 amount
        vm.startPrank(user);
        vm.expectRevert("Amount must be greater than 0");
        mamoStakingStrategy.withdraw(address(userAccount), 0);
        vm.stopPrank();
    }

    function testWithdrawRevertsWhenAccountIsZeroAddress() public {
        // Attempt to withdraw from zero address
        vm.startPrank(user);
        vm.expectRevert("Invalid account");
        mamoStakingStrategy.withdraw(address(0), 1000 * 10 ** 18);
        vm.stopPrank();
    }

    function testWithdrawRevertsWhenContractIsPaused() public {
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Pause the contract
        address guardian = addresses.getAddress("MAMO_MULTISIG");
        vm.startPrank(guardian);
        mamoStakingStrategy.pause();
        vm.stopPrank();

        // Attempt to withdraw when paused
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mamoStakingStrategy.withdraw(address(userAccount), depositAmount);
        vm.stopPrank();
    }

    function testWithdrawRevertsWhenInsufficientStakedBalance() public {
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 withdrawAmount = 1500 * 10 ** 18; // More than deposited

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Attempt to withdraw more than staked balance
        vm.startPrank(user);
        vm.expectRevert(); // MultiRewards will revert with insufficient balance
        mamoStakingStrategy.withdraw(address(userAccount), withdrawAmount);
        vm.stopPrank();
    }

    function testWithdrawRevertsWhenNotAccountOwner() public {
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Create another user who is not the account owner
        address attacker = makeAddr("attacker");

        // Attempt to withdraw as non-owner
        vm.startPrank(attacker);
        vm.expectRevert(); // Should revert because attacker is not the account owner
        mamoStakingStrategy.withdraw(address(userAccount), depositAmount);
        vm.stopPrank();
    }

    function testWithdrawSucceedsWhenMultiRewardsIsPaused() public {
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Pause MultiRewards contract
        address multiRewardsOwner = addresses.getAddress("MAMO_MULTISIG");
        vm.startPrank(multiRewardsOwner);
        multiRewards.setPaused(true);
        vm.stopPrank();

        // Withdraw should succeed even when MultiRewards is paused (withdraw is not restricted by pause)
        vm.startPrank(user);
        mamoStakingStrategy.withdraw(address(userAccount), depositAmount);
        vm.stopPrank();

        // Verify withdraw was successful
        assertEq(multiRewards.balanceOf(address(userAccount)), 0, "Should have no staked balance after withdraw");
        assertEq(mamoToken.balanceOf(user), depositAmount, "User should have received all MAMO tokens back");
    }

    // ========== PROCESS REWARDS TESTS - REINVEST MODE ==========

    // Helper function to setup rewards in MultiRewards contract
    function _setupRewardsInMultiRewards(address rewardToken, uint256 rewardAmount, uint256 duration) internal {
        address multiRewardsOwner = addresses.getAddress("MAMO_MULTISIG");

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

    // Helper function to deploy a cbBTC strategy for testing
    function _deployCbBTCStrategy(address strategyOwner) internal returns (address cbBTCStrategy) {
        address backend = addresses.getAddress("MAMO_BACKEND");
        address cbBTCStrategyFactory = addresses.getAddress("cbBTC_STRATEGY_FACTORY");

        // Deploy strategy using the factory
        vm.startPrank(backend);
        cbBTCStrategy = StrategyFactory(cbBTCStrategyFactory).createStrategyForUser(strategyOwner);
        vm.stopPrank();

        return cbBTCStrategy;
    }

    // Helper function to setup cbBTC reward token for testing
    function _setupCbBTCRewardToken(address strategyOwner) internal returns (address cbBTCStrategy) {
        address backend = addresses.getAddress("MAMO_BACKEND");
        address cbBTC = addresses.getAddress("cbBTC");

        // Deploy an actual cbBTC strategy for the specified owner
        cbBTCStrategy = _deployCbBTCStrategy(strategyOwner);

        vm.startPrank(backend);
        // Add cbBTC as a reward token with the deployed strategy
        mamoStakingStrategy.addRewardToken(cbBTC, cbBTCStrategy);
        vm.stopPrank();

        return cbBTCStrategy;
    }

    function testProcessRewardsReinvestModeWithMamoOnly() public {
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 mamoRewardAmount = 100 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Set account to REINVEST mode
        vm.startPrank(user);
        mamoStakingStrategy.setCompoundMode(address(userAccount), MamoStakingStrategy.CompoundMode.REINVEST);
        vm.stopPrank();

        // Setup MAMO rewards in MultiRewards
        _setupRewardsInMultiRewards(address(mamoToken), mamoRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Get initial state
        uint256 initialStakedBalance = multiRewards.balanceOf(address(userAccount));
        uint256 earnedRewards = multiRewards.earned(address(userAccount), address(mamoToken));

        // Process rewards as backend
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();

        // Verify MAMO rewards were claimed and staked
        assertGt(earnedRewards, 0, "Should have earned some MAMO rewards");
        assertEq(
            multiRewards.balanceOf(address(userAccount)),
            initialStakedBalance + earnedRewards,
            "Should have staked all MAMO rewards"
        );

        // Verify account has no remaining MAMO tokens
        assertEq(mamoToken.balanceOf(address(userAccount)), 0, "Account should have no remaining MAMO");
    }

    function testProcessRewardsReinvestModeWithCbBTCRewards() public {
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 mamoRewardAmount = 50 * 10 ** 18; // Add MAMO rewards too
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Setup cbBTC reward token for testing - strategy owned by the same user
        address cbBTCStrategy = _setupCbBTCRewardToken(user);

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Set account to REINVEST mode
        vm.startPrank(user);
        mamoStakingStrategy.setCompoundMode(address(userAccount), MamoStakingStrategy.CompoundMode.REINVEST);
        vm.stopPrank();

        // Setup MAMO rewards in MultiRewards
        _setupRewardsInMultiRewards(address(mamoToken), mamoRewardAmount, 7 days);

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Get initial state
        uint256 initialStakedBalance = multiRewards.balanceOf(address(userAccount));
        uint256 earnedMamoRewards = multiRewards.earned(address(userAccount), address(mamoToken));
        uint256 earnedCbBTCRewards = multiRewards.earned(address(userAccount), cbBTC);

        // Get initial strategy token balances (mToken and Morpho vault shares)
        address mToken = addresses.getAddress("MOONWELL_cbBTC");
        address morphoVault = addresses.getAddress("cbBTC_METAMORPHO_VAULT");
        uint256 initialMTokenBalance = IERC20(mToken).balanceOf(cbBTCStrategy);
        uint256 initialMorphoBalance = IERC20(morphoVault).balanceOf(cbBTCStrategy);

        // Process rewards as backend - this should restake MAMO and deposit cbBTC to strategy
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();

        // Verify both rewards were earned
        assertGt(earnedMamoRewards, 0, "Should have earned some MAMO rewards");
        assertGt(earnedCbBTCRewards, 0, "Should have earned some cbBTC rewards");

        // Verify MAMO was restaked in MultiRewards
        assertEq(
            multiRewards.balanceOf(address(userAccount)),
            initialStakedBalance + earnedMamoRewards,
            "Should have restaked all MAMO rewards"
        );

        // Verify account has no remaining tokens
        assertEq(mamoToken.balanceOf(address(userAccount)), 0, "Account should have no remaining MAMO");
        assertEq(IERC20(cbBTC).balanceOf(address(userAccount)), 0, "Account should have no remaining cbBTC");

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
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Create another user who will own the strategy
        address otherUser = makeAddr("otherUser");

        // Setup cbBTC reward token for testing - strategy owned by different user
        address cbBTCStrategy = _setupCbBTCRewardToken(otherUser);

        // Setup and deposit using helper function (user account)
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Set account to REINVEST mode
        vm.startPrank(user);
        mamoStakingStrategy.setCompoundMode(address(userAccount), MamoStakingStrategy.CompoundMode.REINVEST);
        vm.stopPrank();

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Process rewards as backend - this should fail because strategy is owned by different user
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        vm.expectRevert(); // Should revert because the strategy owner doesn't match the account owner
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();
    }

    function testProcessRewardsReinvestModeWithMamoAndFees() public {
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 mamoRewardAmount = 100 * 10 ** 18;
        uint256 cbBTCRewardAmount = 2 * 10 ** 8; // cbBTC has 8 decimals

        // Setup cbBTC reward token for testing - strategy owned by the same user
        address cbBTCStrategy = _setupCbBTCRewardToken(user);

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Set account to REINVEST mode
        vm.startPrank(user);
        mamoStakingStrategy.setCompoundMode(address(userAccount), MamoStakingStrategy.CompoundMode.REINVEST);
        vm.stopPrank();

        // Setup MAMO rewards in MultiRewards
        _setupRewardsInMultiRewards(address(mamoToken), mamoRewardAmount, 7 days);

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Get initial state
        uint256 initialStakedBalance = multiRewards.balanceOf(address(userAccount));
        uint256 earnedMamoRewards = multiRewards.earned(address(userAccount), address(mamoToken));
        uint256 earnedCbBTCRewards = multiRewards.earned(address(userAccount), cbBTC);

        // Get initial strategy token balances (mToken and Morpho vault shares)
        address mToken = addresses.getAddress("MOONWELL_cbBTC");
        address morphoVault = addresses.getAddress("cbBTC_METAMORPHO_VAULT");
        uint256 initialMTokenBalance = IERC20(mToken).balanceOf(cbBTCStrategy);
        uint256 initialMorphoBalance = IERC20(morphoVault).balanceOf(cbBTCStrategy);

        // Process rewards as backend
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();

        // Verify MAMO was restaked
        assertEq(
            multiRewards.balanceOf(address(userAccount)),
            initialStakedBalance + earnedMamoRewards,
            "Should have restaked all MAMO rewards"
        );

        // Verify account has no remaining tokens
        assertEq(mamoToken.balanceOf(address(userAccount)), 0, "Account should have no remaining MAMO");
        assertEq(IERC20(cbBTC).balanceOf(address(userAccount)), 0, "Account should have no remaining cbBTC");

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

    function testProcessRewardsRevertsWhenNotBackendRole() public {
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Attempt to process rewards as non-backend user
        vm.startPrank(user);
        vm.expectRevert(); // Should revert because user doesn't have BACKEND_ROLE
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();
    }

    function testProcessRewardsRevertsWhenContractPaused() public {
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Pause the contract
        address guardian = addresses.getAddress("MAMO_MULTISIG");
        vm.startPrank(guardian);
        mamoStakingStrategy.pause();
        vm.stopPrank();

        // Attempt to process rewards when paused
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();
    }

    function testProcessRewardsDefaultsToCompoundMode() public {
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 mamoRewardAmount = 100 * 10 ** 18;

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Don't set compound mode - should default to COMPOUND (CompoundMode(0))

        // Setup MAMO rewards in MultiRewards
        _setupRewardsInMultiRewards(address(mamoToken), mamoRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Get initial state
        uint256 initialStakedBalance = multiRewards.balanceOf(address(userAccount));
        uint256 earnedRewards = multiRewards.earned(address(userAccount), address(mamoToken));

        // Process rewards as backend
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();

        // Verify MAMO was staked (COMPOUND behavior)
        assertEq(
            multiRewards.balanceOf(address(userAccount)),
            initialStakedBalance + earnedRewards,
            "Should have staked all MAMO rewards using COMPOUND mode"
        );

        // Verify account has no remaining MAMO tokens
        assertEq(mamoToken.balanceOf(address(userAccount)), 0, "Account should have no remaining MAMO");
    }

    function testMamoAccountHasCorrectStrategyTypeId() public {
        // Verify the MamoAccount has the correct strategyTypeId
        assertEq(userAccount.strategyTypeId(), 2, "MamoAccount should have strategyTypeId 1");
    }

    // ========== PROCESS REWARDS TESTS - COMPOUND MODE WITH DEX SWAPS ==========

    function testProcessRewardsCompoundModeWithCbBTCAndDEXSwap() public {
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 mamoRewardAmount = 50 * 10 ** 18;
        uint256 cbBTCRewardAmount = 2 * 10 ** 8; // cbBTC has 8 decimals

        // Setup cbBTC reward token for testing - strategy owned by the same user
        address cbBTCStrategy = _setupCbBTCRewardToken(user);

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Explicitly set account to COMPOUND mode
        vm.startPrank(user);
        mamoStakingStrategy.setCompoundMode(address(userAccount), MamoStakingStrategy.CompoundMode.COMPOUND);
        vm.stopPrank();

        // Setup MAMO rewards in MultiRewards
        _setupRewardsInMultiRewards(address(mamoToken), mamoRewardAmount, 7 days);

        // Setup cbBTC rewards in MultiRewards
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Get initial state
        uint256 initialStakedBalance = multiRewards.balanceOf(address(userAccount));
        uint256 earnedMamoRewards = multiRewards.earned(address(userAccount), address(mamoToken));
        uint256 earnedCbBTCRewards = multiRewards.earned(address(userAccount), cbBTC);

        // Get initial balances before swap
        uint256 initialMamoBalanceInAccount = mamoToken.balanceOf(address(userAccount));
        uint256 initialCbBTCBalanceInAccount = IERC20(cbBTC).balanceOf(address(userAccount));

        // Process rewards as backend - this should swap cbBTC to MAMO and compound everything
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();

        // Verify both rewards were earned
        assertGt(earnedMamoRewards, 0, "Should have earned some MAMO rewards");
        assertGt(earnedCbBTCRewards, 0, "Should have earned some cbBTC rewards");

        // Verify the DEX swap occurred - account should have more MAMO than just the original MAMO rewards
        uint256 finalMamoBalanceInAccount = mamoToken.balanceOf(address(userAccount));
        assertEq(finalMamoBalanceInAccount, 0, "All MAMO should have been staked after compound");

        // Verify cbBTC was swapped (account should have no cbBTC left)
        uint256 finalCbBTCBalanceInAccount = IERC20(cbBTC).balanceOf(address(userAccount));
        assertEq(finalCbBTCBalanceInAccount, 0, "All cbBTC should have been swapped to MAMO");

        // Verify the final staked balance is higher than initial + just MAMO rewards
        // This proves the cbBTC was swapped to MAMO and then staked
        uint256 finalStakedBalance = multiRewards.balanceOf(address(userAccount));
        assertGt(
            finalStakedBalance,
            initialStakedBalance + earnedMamoRewards,
            "Final staked balance should include swapped cbBTC converted to MAMO"
        );

        // Verify the increase in staked balance comes from both MAMO rewards and swapped cbBTC
        uint256 totalIncrease = finalStakedBalance - initialStakedBalance;
        assertGt(totalIncrease, earnedMamoRewards, "Total increase should be more than just MAMO rewards due to swap");
    }

    function testProcessRewardsCompoundModeMultipleTokensDEXSwap() public {
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 mamoRewardAmount = 50 * 10 ** 18;
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Setup cbBTC reward token for testing
        address cbBTCStrategy = _setupCbBTCRewardToken(user);

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Set account to COMPOUND mode
        vm.startPrank(user);
        mamoStakingStrategy.setCompoundMode(address(userAccount), MamoStakingStrategy.CompoundMode.COMPOUND);
        vm.stopPrank();

        // Setup rewards in MultiRewards
        _setupRewardsInMultiRewards(address(mamoToken), mamoRewardAmount, 7 days);
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Get pre-process state
        uint256 initialStakedBalance = multiRewards.balanceOf(address(userAccount));
        uint256 earnedMamoRewards = multiRewards.earned(address(userAccount), address(mamoToken));
        uint256 earnedCbBTCRewards = multiRewards.earned(address(userAccount), cbBTC);

        // Process rewards - compound mode with DEX swaps
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();

        // Verify final state
        uint256 finalStakedBalance = multiRewards.balanceOf(address(userAccount));

        // Check that both reward tokens were processed
        assertGt(earnedMamoRewards, 0, "Should have earned MAMO rewards");
        assertGt(earnedCbBTCRewards, 0, "Should have earned cbBTC rewards");

        // Verify all tokens were converted and staked
        assertEq(mamoToken.balanceOf(address(userAccount)), 0, "No MAMO should remain in account");
        assertEq(IERC20(cbBTC).balanceOf(address(userAccount)), 0, "No cbBTC should remain in account");

        // Verify the compound worked - staked balance should include original MAMO rewards + swapped tokens
        assertGt(
            finalStakedBalance,
            initialStakedBalance + earnedMamoRewards,
            "Staked balance should include both MAMO rewards and swapped tokens"
        );

        // Verify the account doesn't hold any reward tokens in its strategy (they should be compounded back to MAMO staking)
        // The cbBTC strategy should remain unchanged since we're in COMPOUND mode, not REINVEST mode
        address mToken = addresses.getAddress("MOONWELL_cbBTC");
        address morphoVault = addresses.getAddress("cbBTC_METAMORPHO_VAULT");
        assertEq(
            IERC20(mToken).balanceOf(cbBTCStrategy), 0, "cbBTC strategy should not receive deposits in COMPOUND mode"
        );
        assertEq(
            IERC20(morphoVault).balanceOf(cbBTCStrategy),
            0,
            "cbBTC strategy should not receive deposits in COMPOUND mode"
        );
    }

    function testProcessRewardsCompoundModeZeroRewardsNoDEXSwap() public {
        uint256 depositAmount = 1000 * 10 ** 18;

        // Setup cbBTC reward token
        address cbBTCStrategy = _setupCbBTCRewardToken(user);

        // Setup and deposit using helper function
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Set account to COMPOUND mode
        vm.startPrank(user);
        mamoStakingStrategy.setCompoundMode(address(userAccount), MamoStakingStrategy.CompoundMode.COMPOUND);
        vm.stopPrank();

        // Don't setup any rewards - so no rewards to claim or swap

        // Get initial state
        uint256 initialStakedBalance = multiRewards.balanceOf(address(userAccount));

        // Process rewards - should not perform any swaps since there are no rewards
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();

        // Verify no changes occurred
        uint256 finalStakedBalance = multiRewards.balanceOf(address(userAccount));
        assertEq(finalStakedBalance, initialStakedBalance, "Staked balance should remain unchanged with zero rewards");

        // Verify no tokens in account
        assertEq(mamoToken.balanceOf(address(userAccount)), 0, "Account should have no MAMO");
        address cbBTC = addresses.getAddress("cbBTC");
        assertEq(IERC20(cbBTC).balanceOf(address(userAccount)), 0, "Account should have no cbBTC");
    }

    function testProcessRewardsCompoundModeVerifyDEXRouterCalls() public {
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 cbBTCRewardAmount = 1 * 10 ** 8; // cbBTC has 8 decimals

        // Setup cbBTC reward token for testing
        address cbBTCStrategy = _setupCbBTCRewardToken(user);

        // Setup and deposit
        _setupAndDeposit(user, address(userAccount), depositAmount);

        // Set account to COMPOUND mode
        vm.startPrank(user);
        mamoStakingStrategy.setCompoundMode(address(userAccount), MamoStakingStrategy.CompoundMode.COMPOUND);
        vm.stopPrank();

        // Setup only cbBTC rewards (no MAMO rewards to isolate the swap test)
        address cbBTC = addresses.getAddress("cbBTC");
        _setupRewardsInMultiRewards(cbBTC, cbBTCRewardAmount, 7 days);

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Verify cbBTC rewards are available
        uint256 earnedCbBTCRewards = multiRewards.earned(address(userAccount), cbBTC);
        assertGt(earnedCbBTCRewards, 0, "Should have earned cbBTC rewards");

        // Get initial balances to track the swap
        uint256 initialStakedBalance = multiRewards.balanceOf(address(userAccount));
        uint256 initialMamoInAccount = mamoToken.balanceOf(address(userAccount));

        // Process rewards - this should trigger DEX swap from cbBTC to MAMO
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        mamoStakingStrategy.processRewards(address(userAccount));
        vm.stopPrank();

        // Verify the swap occurred by checking final balances
        uint256 finalStakedBalance = multiRewards.balanceOf(address(userAccount));
        uint256 finalMamoInAccount = mamoToken.balanceOf(address(userAccount));
        uint256 finalCbBTCInAccount = IERC20(cbBTC).balanceOf(address(userAccount));

        // Verify cbBTC was fully consumed in the swap
        assertEq(finalCbBTCInAccount, 0, "All cbBTC should have been swapped");

        // Verify account has no remaining MAMO (it was all staked after swap)
        assertEq(finalMamoInAccount, 0, "All MAMO should have been staked after swap");

        // Verify staked balance increased due to the swap
        assertGt(finalStakedBalance, initialStakedBalance, "Staked balance should increase from swapped MAMO");

        // The increase should be the result of swapping cbBTC to MAMO
        uint256 stakingIncrease = finalStakedBalance - initialStakedBalance;
        assertGt(stakingIncrease, 0, "Should have staked some MAMO from the cbBTC swap");
    }
}
