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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployMamoStaking} from "@script/DeployMamoStaking.s.sol";

contract MamoStakingStrategyIntegrationTest is Test {
    Addresses public addresses;
    AccountRegistry public accountRegistry;
    MamoAccountFactory public mamoAccountFactory;
    MamoStakingStrategy public mamoStakingStrategy;
    MamoAccount public userAccount;

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

        // Get MAMO token from addresses
        mamoToken = IERC20(addresses.getAddress("MAMO"));

        // Create test user (only address we create)
        user = makeAddr("testUser");

        // Deploy a MamoAccount for the test user
        address backend = addresses.getAddress("MAMO_BACKEND");
        vm.startPrank(backend);
        userAccount = MamoAccount(payable(mamoAccountFactory.createAccountForUser(user)));
        vm.stopPrank();
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
    }
}
