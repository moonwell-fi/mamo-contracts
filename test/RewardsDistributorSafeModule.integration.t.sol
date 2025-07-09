// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Addresses} from "@addresses/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {RewardsDistributorSafeModule} from "../src/RewardsDistributorSafeModule.sol";
import {ISafe} from "../src/interfaces/ISafe.sol";
import {SigHelper} from "./utils/SigHelper.sol";
import {IMultiRewards} from "@contracts/interfaces/IMultiRewards.sol";
import {MamoStakingDeployment} from "@multisig/005_MamoStakingDeployment.sol";

import {ModuleManager} from "../lib/safe-smart-account/contracts/base/ModuleManager.sol";
import {SafeProxyFactory} from "../lib/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";

contract RewardsDistributorSafeModuleIntegrationTest is Test, SigHelper {
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
    uint256 public constant TIMELOCK_DURATION = 24 hours;
    uint256 public constant MAMO_REWARD_AMOUNT = 1000e18;
    uint256 public constant CBBTC_REWARD_AMOUNT = 1e8; // 1 cbBTC (8 decimals)

    uint256 public constant pk1 = 4;
    uint256 public constant pk2 = 2;
    uint256 public constant pk3 = 3;

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

        owners = new address[](OWNER_COUNT);
        owners[0] = vm.addr(pk1);
        vm.label(owners[0], "Owner 1");
        owners[1] = vm.addr(pk2);
        vm.label(owners[1], "Owner 2");
        owners[2] = vm.addr(pk3);
        vm.label(owners[2], "Owner 3");

        for (uint256 i = 0; i < OWNER_COUNT; i++) {
            vm.deal(owners[i], 10 ether);
        }

        _deploySafeWithOwners();
        _deployContracts();
        _enableModuleOnSafe();
    }

    function _deploySafeWithOwners() internal {
        safeSingleton = addresses.getAddress("SAFE_PROXY");

        if (!addresses.isAddressSet("SAFE_FACTORY")) {
            safeFactory = new SafeProxyFactory();
            addresses.addAddress("SAFE_FACTORY", address(safeFactory), true);
        } else {
            safeFactory = SafeProxyFactory(addresses.getAddress("SAFE_FACTORY"));
        }

        bytes memory initializer = abi.encodeWithSelector(
            ISafe.setup.selector, owners, THRESHOLD, address(0), "", address(0), address(0), 0, payable(address(0))
        );

        safe = ISafe(payable(safeFactory.createProxyWithNonce(safeSingleton, initializer, 0)));
        vm.label(address(safe), "TEST_SAFE");
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

        // Get the deployed contract instances
        module = RewardsDistributorSafeModule(addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC"));
        multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
    }

    function _enableModuleOnSafe() internal {
        if (!safe.isModuleEnabled(address(module))) {}
        bytes memory data = abi.encodeWithSelector(ISafe.enableModule.selector, address(module));

        bytes32 transactionHash = safe.getTransactionHash(
            address(safe), 0, data, ISafe.Operation.Call, 0, 0, 0, address(0), address(0), safe.nonce()
        );

        bytes memory collatedSignatures = signTxAllOwners(transactionHash, pk1, pk2, pk3);

        safe.checkNSignatures(transactionHash, data, collatedSignatures, 3);

        safe.execTransaction(
            address(safe), 0, data, ISafe.Operation.Call, 0, 0, 0, address(0), payable(address(0)), collatedSignatures
        );
        assertTrue(safe.isModuleEnabled(address(module)));
    }

    function test_enableModuleOnSafe() public view {
        assertTrue(safe.isModuleEnabled(address(module)));
        assertEq(safe.getThreshold(), THRESHOLD);
        assertEq(safe.getOwners().length, OWNER_COUNT);
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

        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, owners[0], 1000);

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

        (uint256 amountBTCStored, uint256 amountMAMOStored, uint256 storedUnlockTime, bool isNotified) =
            module.pendingRewards();
        assertEq(amountBTCStored, 0);
        assertEq(amountMAMOStored, 1);
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
        emit RewardsNotified(1, 0, block.timestamp);

        module.notifyRewards();

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.EXECUTED));

        (uint256 amountBTCStored, uint256 amountMAMOStored, uint256 storedUnlockTime, bool isNotified) =
            module.pendingRewards();
        assertEq(amountBTCStored, 0);
        assertEq(amountMAMOStored, 1);
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
        vm.prank(address(safe));
        module.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(admin);
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        module.notifyRewards();

        vm.prank(address(safe));
        module.unpause();

        deal(address(mamoToken), address(safe), MAMO_REWARD_AMOUNT);
        deal(address(cbBtcToken), address(safe), CBBTC_REWARD_AMOUNT);

        vm.prank(admin);
        module.addRewards(CBBTC_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);
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
        module.addRewards(CBBTC_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.PENDING_EXECUTION)
            );
            vm.roll(block.number + 1);
        }

        vm.warp(unlockTime + 1);
        module.notifyRewards();

        for (uint256 i = 0; i < 5; i++) {
            assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.EXECUTED));
            vm.roll(block.number + 1);
        }
    }

    function test_rewardDistributionWithTimelock() public {
        uint256 shortTimelock = 1 hours;
        uint256 unlockTime = block.timestamp + shortTimelock;

        deal(address(cbBtcToken), address(safe), CBBTC_REWARD_AMOUNT);
        deal(address(mamoToken), address(safe), MAMO_REWARD_AMOUNT);

        vm.prank(admin);
        module.addRewards(CBBTC_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

        assertEq(cbBtcToken.balanceOf(address(multiRewards)), 0);

        vm.warp(unlockTime + 1);
        module.notifyRewards();

        assertEq(cbBtcToken.balanceOf(address(multiRewards)), CBBTC_REWARD_AMOUNT);
    }
}
