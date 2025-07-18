// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Script} from "@forge-std/Script.sol";
import {StdStyle} from "@forge-std/StdStyle.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";

import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";
import {IMultiRewards} from "@contracts/interfaces/IMultiRewards.sol";

/**
 * @title DeployRewardsDistributorSafeModule
 * @notice Script to deploy the RewardsDistributorSafeModule contract and its dependencies
 * @dev Deploys MultiRewards contract first, then RewardsDistributorSafeModule, and updates the addresses JSON file
 */
contract DeployRewardsDistributorSafeModule is Script, Test {
    uint256 public constant DEFAULT_REWARD_DURATION = 7 days;
    uint256 public constant DEFAULT_NOTIFY_DELAY = 7 days;

    /**
     * @notice Deploy the RewardsDistributorSafeModule contract
     * @param addresses The addresses contract for dependency injection
     * @return rewardsModule The deployed RewardsDistributorSafeModule contract address
     */
    function deploy(Addresses addresses) public returns (address rewardsModule) {
        address safe = addresses.getAddress("F-MAMO"); // admin of rewards distributor safe modules
        address mamoToken = addresses.getAddress("MAMO");
        address multiRewards = addresses.getAddress("MAMO_MULTI_REWARDS");
        address virtuals = addresses.getAddress("VIRTUALS");

        vm.startBroadcast();

        // Deploy RewardsDistributorSafeModule for MAMO/VIRTUALS pair
        rewardsModule = address(
            new RewardsDistributorSafeModule(
                payable(safe), multiRewards, mamoToken, virtuals, safe, DEFAULT_REWARD_DURATION, DEFAULT_NOTIFY_DELAY
            )
        );

        vm.stopBroadcast();

        if (addresses.isAddressSet("REWARDS_DISTRIBUTOR_MAMO_VIRTUALS")) {
            addresses.changeAddress("REWARDS_DISTRIBUTOR_MAMO_VIRTUALS", rewardsModule, true);
        } else {
            addresses.addAddress("REWARDS_DISTRIBUTOR_MAMO_VIRTUALS", rewardsModule, true);
        }

        return rewardsModule;
    }

    /**
     * @notice Validate the deployment of both contracts
     * @param addresses The addresses contract
     */
    function validate(Addresses addresses) public view {
        address safe = addresses.getAddress("F-MAMO");
        address multiRewards = addresses.getAddress("MAMO_MULTI_REWARDS");
        address rewardsModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_VIRTUALS");
        address mamoToken = addresses.getAddress("MAMO");
        address virtuals = addresses.getAddress("VIRTUALS");

        // Validate MultiRewards contract
        IMultiRewards multiRewardsContract = IMultiRewards(multiRewards);
        assertEq(multiRewardsContract.owner(), safe, "MultiRewards: incorrect owner");

        // Validate RewardsDistributorSafeModule contract
        RewardsDistributorSafeModule moduleContract = RewardsDistributorSafeModule(rewardsModule);

        assertEq(address(moduleContract.safe()), safe, "RewardsModule: incorrect Safe address");
        assertEq(address(moduleContract.multiRewards()), multiRewards, "RewardsModule: incorrect MultiRewards address");
        assertEq(address(moduleContract.token1()), mamoToken, "RewardsModule: incorrect token1 address");
        assertEq(address(moduleContract.token2()), virtuals, "RewardsModule: incorrect token2 address");
        assertEq(moduleContract.admin(), safe, "RewardsModule: incorrect admin address");
        assertEq(moduleContract.rewardDuration(), DEFAULT_REWARD_DURATION, "RewardsModule: incorrect reward duration");

        // Validate contract code exists
        uint256 multiRewardsCodeSize;
        uint256 moduleCodeSize;
        assembly {
            multiRewardsCodeSize := extcodesize(multiRewards)
            moduleCodeSize := extcodesize(rewardsModule)
        }

        assertTrue(multiRewardsCodeSize > 0, "MultiRewards: no contract code deployed");
        assertTrue(moduleCodeSize > 0, "RewardsModule: no contract code deployed");

        // Validate address registry updates
        assertEq(addresses.getAddress("MAMO_MULTI_REWARDS"), multiRewards, "Address registry: MultiRewards not updated");
        assertEq(
            addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_VIRTUALS"),
            rewardsModule,
            "Address registry: RewardsModule not updated"
        );
    }
}
