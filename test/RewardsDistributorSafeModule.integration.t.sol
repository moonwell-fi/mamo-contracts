// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Addresses} from "@addresses/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {RewardsDistributorSafeModule} from "../src/RewardsDistributorSafeModule.sol";
import {ISafe} from "../src/interfaces/ISafe.sol";
import {IMultiRewards} from "@contracts/interfaces/IMultiRewards.sol";
import {MamoStakingDeployment} from "@multisig/005_MamoStakingDeployment.sol";
import {EnableRewardsDistributorSafeModule} from "@multisig/006_EnableRewardsDistributorSafeModule.sol";

import {ModuleManager} from "../lib/safe-smart-account/contracts/base/ModuleManager.sol";
import {SafeProxyFactory} from "../lib/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";

contract RewardsDistributorSafeModuleIntegrationTest is Test {
    ISafe public safe;
    address[] public owners;
    RewardsDistributorSafeModule public module;
    IMultiRewards public multiRewards;
    IERC20 public mamoToken;
    IERC20 public cbBtcToken;
    Addresses public addresses;
    address public admin;

    SafeProxyFactory public safeFactory;
    address public safeSingleton;

    uint256 public constant THRESHOLD = 2;
    uint256 public constant OWNER_COUNT = 3;

    // Constants
    uint256 public constant TIMELOCK_DURATION = 24 hours;
    uint256 public constant MAMO_REWARD_AMOUNT = 1000e18;
    uint256 public constant CBBTC_REWARD_AMOUNT = 1e8; // 1 cbBTC (8 decimals)

    event ModuleEnabled(address indexed module);
    event RewardAdded(uint256 amountToken1, uint256 amountToken2, uint256 notifyAfter);
    event RewardsNotified(uint256 token1Amount, uint256 token2Amount, uint256 notifiedAt);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));

        // Create addresses instance
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        mamoToken = IERC20(addresses.getAddress("MAMO"));
        cbBtcToken = IERC20(addresses.getAddress("cbBTC"));
        admin = addresses.getAddress("F-MAMO");

        safe = ISafe(payable(addresses.getAddress("F-MAMO")));
        _deployContracts();

        // Get the deployed contract instances
        module = RewardsDistributorSafeModule(addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC"));
        multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        _enableModuleOnSafe();
    }

    function _deployContracts() internal {
        // Use the multisig deployment script to deploy all contracts
        MamoStakingDeployment deploymentScript = new MamoStakingDeployment();
        deploymentScript.setAddresses(addresses);

        // Call the individual functions instead of run()
        deploymentScript.deploy();
        deploymentScript.build();
        deploymentScript.simulate();
        deploymentScript.validate();

        // Enable the Safe module directly for testing
        // In production, this would be done through the 006 multisig proposal
        vm.prank(address(safe));
        safe.enableModule(addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC"));
    }

    function _enableModuleOnSafe() internal {
        // The module is already enabled in _deployContracts()
        // Just verify it's enabled
        assertTrue(safe.isModuleEnabled(address(module)));
    }

    function test_enableModuleOnSafe() public {
        // Test that the module exists and has code
        assertTrue(address(module) != address(0));
        assertTrue(address(module).code.length > 0);
        
        // Try to enable the module
        vm.prank(address(safe));
        safe.enableModule(address(module));
        
        // Verify it's enabled
        assertTrue(safe.isModuleEnabled(address(module)));
    }

    //    function test_moduleCanCallSafeAfterEnablement() public {
    //        uint256 amount = 1000e18;
    //        deal(address(mamoToken), address(module), amount);
    //        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, owners[0], amount);
    //
    //        vm.prank(address(module));
    //        bool success = safe.execTransactionFromModule(address(mamoToken), 0, data, ISafe.Operation.DelegateCall);
    //
    //        assertTrue(success);
    //        assertEq(mamoToken.balanceOf(owners[0]), amount);
    //    }

    function test_onlyEnabledModuleCanCallSafe() public {
        address unauthorizedModule = makeAddr("unauthorizedModule");

        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, address(safe), 1000);

        vm.prank(unauthorizedModule);
        vm.expectRevert("GS104");
        safe.execTransactionFromModule(address(mamoToken), 0, data, ISafe.Operation.DelegateCall);
    }

    function test_addRewardsFirstTime() public {
        deal(address(mamoToken), address(safe), MAMO_REWARD_AMOUNT);
        deal(address(cbBtcToken), address(safe), CBBTC_REWARD_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit RewardAdded(MAMO_REWARD_AMOUNT, CBBTC_REWARD_AMOUNT, 1);

        vm.prank(admin);
        module.addRewards(MAMO_REWARD_AMOUNT, CBBTC_REWARD_AMOUNT);

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.PENDING_EXECUTION));

        (uint256 amountToken1Stored, uint256 amountToken2Stored, uint256 storedUnlockTime, bool isNotified) =
            module.pendingRewards();
        assertEq(amountToken1Stored, MAMO_REWARD_AMOUNT);
        assertEq(amountToken2Stored, CBBTC_REWARD_AMOUNT);
        assertEq(storedUnlockTime, 1, "First time it is set to 1"); // first time it is set to 1
        assertEq(isNotified, false);
    }

    function test_addRewardsSecondTimeFailIfNotNotified() public {
        test_addRewardsFirstTime();

        vm.expectRevert("Pending rewards waiting to be executed");
        vm.prank(admin);
        module.addRewards(0, 1);

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.PENDING_EXECUTION));

        (uint256 amountToken1Stored, uint256 amountToken2Stored, uint256 storedUnlockTime, bool isNotified) =
            module.pendingRewards();
        assertEq(amountToken1Stored, MAMO_REWARD_AMOUNT);
        assertEq(amountToken2Stored, CBBTC_REWARD_AMOUNT);
        assertEq(storedUnlockTime, 1, "Second time it is set to 1");
        assertEq(isNotified, false);
    }

    function test_addRewardsSecondTimeSuccess() public {
        test_addRewardsFirstTime();

        module.notifyRewards();

        deal(address(cbBtcToken), address(safe), 1);
        deal(address(mamoToken), address(safe), 1);

        vm.expectEmit(true, true, true, true);
        emit RewardAdded(0, 1, block.timestamp + module.notifyDelay());

        vm.prank(admin);
        module.addRewards(0, 1);

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.NOT_READY));

        uint256 unlockTime = block.timestamp + module.notifyDelay();
        vm.warp(block.timestamp + module.notifyDelay() + 1);

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.PENDING_EXECUTION));

        (uint256 amountToken1Stored, uint256 amountToken2Stored, uint256 storedUnlockTime, bool isNotified) =
            module.pendingRewards();
        assertEq(amountToken1Stored, 0);
        assertEq(amountToken2Stored, 1);
        assertEq(storedUnlockTime, unlockTime, "Second time it is set to notifyDelay");
        assertEq(isNotified, false);
    }

    function test_notifyRewards() public {
        test_addRewardsFirstTime();

        vm.expectEmit(true, true, true, true);
        emit RewardsNotified(MAMO_REWARD_AMOUNT, CBBTC_REWARD_AMOUNT, block.timestamp);

        module.notifyRewards();

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.EXECUTED));
        assertEq(mamoToken.balanceOf(address(multiRewards)), MAMO_REWARD_AMOUNT);

        (uint256 amountToken1Stored, uint256 amountToken2Stored, uint256 storedUnlockTime, bool isNotified) =
            module.pendingRewards();

        assertEq(amountToken1Stored, MAMO_REWARD_AMOUNT);
        assertEq(amountToken2Stored, CBBTC_REWARD_AMOUNT);
        assertEq(storedUnlockTime, block.timestamp + module.notifyDelay());
        assertEq(isNotified, true);
    }

    function test_notifyRewardsSecondTime() public {
        test_addRewardsSecondTimeSuccess();

        vm.expectEmit(true, true, true, true);
        emit RewardsNotified(0, 1, block.timestamp);

        module.notifyRewards();

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.EXECUTED));

        (uint256 amountToken1Stored, uint256 amountToken2Stored, uint256 storedUnlockTime, bool isNotified) =
            module.pendingRewards();
        assertEq(amountToken1Stored, 0);
        assertEq(amountToken2Stored, 1);
        assertEq(storedUnlockTime, block.timestamp + module.notifyDelay());
        assertEq(isNotified, true);
    }

    function test_unauthorizedAccessPrevention() public {
        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert("Only admin can call this function");
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);
    }

    function test_pauseFunctionalityIntegration() public {
        // Prank as the Safe to pause the module directly
        vm.prank(address(safe));
        module.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(admin);
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        module.notifyRewards();

        // Prank as the Safe to unpause the module directly
        vm.prank(address(safe));
        module.unpause();

        deal(address(mamoToken), address(safe), MAMO_REWARD_AMOUNT);
        deal(address(cbBtcToken), address(safe), CBBTC_REWARD_AMOUNT);

        vm.prank(admin);
        module.addRewards(MAMO_REWARD_AMOUNT, CBBTC_REWARD_AMOUNT);
    }

    function test_zeroAmountRewards() public {
        vm.expectRevert("Invalid reward amount");
        vm.prank(admin);
        module.addRewards(0, 0);
    }

    function test_stateConsistencyAcrossTransactions() public {
        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.UNINITIALIZED));

        uint256 unlockTime = block.timestamp + TIMELOCK_DURATION;

        deal(address(mamoToken), address(safe), MAMO_REWARD_AMOUNT);
        deal(address(cbBtcToken), address(safe), CBBTC_REWARD_AMOUNT);

        vm.prank(admin);
        module.addRewards(MAMO_REWARD_AMOUNT, CBBTC_REWARD_AMOUNT);

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.PENDING_EXECUTION));

        vm.warp(unlockTime + 1);
        module.notifyRewards();

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.EXECUTED));
    }

    function test_rewardDistributionWithTimelock() public {
        uint256 shortTimelock = 1 hours;
        uint256 unlockTime = block.timestamp + shortTimelock;

        deal(address(cbBtcToken), address(safe), CBBTC_REWARD_AMOUNT);
        deal(address(mamoToken), address(safe), MAMO_REWARD_AMOUNT);

        vm.prank(admin);
        module.addRewards(MAMO_REWARD_AMOUNT, CBBTC_REWARD_AMOUNT);

        assertEq(cbBtcToken.balanceOf(address(multiRewards)), 0);

        vm.warp(unlockTime + 1);
        module.notifyRewards();

        assertEq(cbBtcToken.balanceOf(address(multiRewards)), CBBTC_REWARD_AMOUNT);
    }
}
