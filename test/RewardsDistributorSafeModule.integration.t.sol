// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {DeployRewardsDistributorSafeModule} from "../script/DeployRewardsDistributorSafeModule.s.sol";

import {RewardsDistributorSafeModule} from "../src/RewardsDistributorSafeModule.sol";
import {ISafe} from "../src/interfaces/ISafe.sol";
import {SigHelper} from "./utils/SigHelper.sol";
import {IMultiRewards} from "@contracts/interfaces/IMultiRewards.sol";

import {ModuleManager} from "../lib/safe-smart-account/contracts/base/ModuleManager.sol";
import {SafeProxyFactory} from "../lib/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract RewardsDistributorSafeModuleIntegrationTest is DeployRewardsDistributorSafeModule, SigHelper {
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
    event RewardAdded(uint256 amountBTC, uint256 amountMAMO, uint256 notifyAfter);
    event RewardsNotified(uint256 mamoAmount, uint256 btcAmount, uint256 notifiedAt);

    function setUp() public {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        addresses = new Addresses(addressesFolderPath, chainIds);

        mamoToken = IERC20(addresses.getAddress("MAMO"));
        cbBtcToken = IERC20(addresses.getAddress("cbBTC"));
        admin = addresses.getAddress("MAMO_BACKEND");

        owners = new address[](OWNER_COUNT);
        owners[0] = vm.addr(pk1);
        owners[1] = vm.addr(pk2);
        owners[2] = vm.addr(pk3);

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
        addresses.addAddress("TestSafe", address(safe), true);
    }

    function _deployContracts() internal {
        if (!addresses.isAddressSet("MAMO_STAKING")) {
            deployMultiRewards(addresses);
        }

        if (!addresses.isAddressSet("REWARDS_DISTRIBUTOR_SAFE_MODULE")) {
            deployRewardsDistributorSafeModule(addresses);
        }

        module = RewardsDistributorSafeModule(addresses.getAddress("REWARDS_DISTRIBUTOR_SAFE_MODULE"));
        multiRewards = IMultiRewards(addresses.getAddress("MAMO_STAKING"));
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

    function test_moduleCanCallSafeAfterEnablement() public {
        uint256 amount = 1000e18;
        deal(address(mamoToken), address(safe), amount);
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, owners[0], amount);

        vm.prank(address(module));
        bool success = safe.execTransactionFromModule(address(mamoToken), 0, data, ISafe.Operation.DelegateCall);

        assertTrue(success);
        assertEq(mamoToken.balanceOf(owners[0]), amount);
    }

    function test_onlyEnabledModuleCanCallSafe() public {
        address unauthorizedModule = makeAddr("unauthorizedModule");

        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, owners[0], 1000);

        vm.prank(unauthorizedModule);
        vm.expectRevert("GS104");
        safe.execTransactionFromModule(address(mamoToken), 0, data, ISafe.Operation.DelegateCall);
    }

    function test_addRewardsIntegration() public {
        uint256 amountBTC = 100e8;
        uint256 amountMAMO = 1000e18;

        vm.expectEmit(true, true, true, true);
        emit RewardAdded(amountBTC, amountMAMO, block.timestamp + module.notifyDelay());

        module.addRewards(amountBTC, amountMAMO);

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.PENDING_EXECUTION));

        (uint256 amountBTCStored, uint256 amountMAMOStored, uint256 storedUnlockTime, bool isNotified) =
            module.pendingRewards();
        assertEq(amountBTCStored, amountBTC);
        assertEq(amountMAMOStored, amountMAMO);
        assertEq(storedUnlockTime, block.timestamp + module.notifyDelay());
        assertEq(isNotified, false);
    }

    function test_notifyRewardsIntegration() public {
        uint256 unlockTime = block.timestamp + TIMELOCK_DURATION;
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

        vm.warp(unlockTime + 1);

        vm.expectEmit(true, true, true, true);
        emit RewardsNotified(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT, block.timestamp);

        module.notifyRewards();

        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.EXECUTED));
        assertEq(mamoToken.balanceOf(address(multiRewards)), MAMO_REWARD_AMOUNT);
    }

    function test_multipleRewardTokensIntegration() public {
        uint256 unlockTime1 = block.timestamp + TIMELOCK_DURATION;
        uint256 unlockTime2 = block.timestamp + TIMELOCK_DURATION + 1 hours;

        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);
        vm.warp(unlockTime1 + 1);
        module.notifyRewards();

        module.addRewards(CBBTC_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);
        vm.warp(unlockTime2 + 1);
        module.notifyRewards();

        assertEq(mamoToken.balanceOf(address(multiRewards)), MAMO_REWARD_AMOUNT);
        assertEq(cbBtcToken.balanceOf(address(multiRewards)), CBBTC_REWARD_AMOUNT);
    }

    function test_stateTransitionFlow() public {
        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.UNINITIALIZED));

        uint256 unlockTime = block.timestamp + TIMELOCK_DURATION;
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);
        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.PENDING_EXECUTION));

        vm.warp(unlockTime + 1);
        module.notifyRewards();
        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.EXECUTED));
    }

    function test_timelockEnforcementIntegration() public {
        uint256 unlockTime = block.timestamp + TIMELOCK_DURATION;
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

        vm.expectRevert("Timelock not expired");
        module.notifyRewards();

        vm.warp(unlockTime);
        vm.expectRevert("Timelock not expired");
        module.notifyRewards();

        vm.warp(unlockTime + 1);
        module.notifyRewards();
    }

    function test_unauthorizedAccessPrevention() public {
        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert();
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);
        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);

        vm.prank(unauthorized);
        vm.expectRevert();
        module.notifyRewards();
    }

    function test_pauseFunctionalityIntegration() public {
        module.pause();

        vm.expectRevert("Pausable: paused");
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

        module.unpause();
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);
    }

    function test_zeroAmountRewards() public {
        vm.expectRevert("Amount must be greater than 0");
        vm.prank(admin);
        module.addRewards(MAMO_REWARD_AMOUNT, 0);
    }

    function test_stateConsistencyAcrossTransactions() public {
        assertEq(uint256(module.getCurrentState()), uint256(RewardsDistributorSafeModule.RewardState.UNINITIALIZED));

        uint256 unlockTime = block.timestamp + TIMELOCK_DURATION;
        module.addRewards(MAMO_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

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

        module.addRewards(CBBTC_REWARD_AMOUNT, MAMO_REWARD_AMOUNT);

        assertEq(cbBtcToken.balanceOf(address(multiRewards)), 0);

        vm.warp(unlockTime + 1);
        module.notifyRewards();

        assertEq(cbBtcToken.balanceOf(address(multiRewards)), CBBTC_REWARD_AMOUNT);
    }
}
