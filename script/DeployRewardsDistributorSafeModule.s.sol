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
     * @notice Deploy the MultiRewards contract
     * @param addresses The addresses contract for dependency injection
     * @return multiRewards The deployed MultiRewards contract address
     */
    function deployMultiRewards(Addresses addresses, address safe) public returns (address multiRewards) {
        console.log("\n%s", StdStyle.bold(StdStyle.green("Phase 1: Deploying MultiRewards contract...")));

        address mamoToken = addresses.getAddress("MAMO");

        vm.startBroadcast();

        multiRewards = deployCode("out/MultiRewards.sol/MultiRewards.json", abi.encode(safe, mamoToken));
        console.log("MultiRewards contract deployed at: %s", StdStyle.yellow(vm.toString(multiRewards)));

        vm.stopBroadcast();

        if (addresses.isAddressSet("MAMO_STAKING")) {
            addresses.changeAddress("MAMO_STAKING", multiRewards, true);
        } else {
            addresses.addAddress("MAMO_STAKING", multiRewards, true);
        }

        console.log("MultiRewards address registered in address registry");
        return multiRewards;
    }

    /**
     * @notice Deploy the RewardsDistributorSafeModule contract
     * @param addresses The addresses contract for dependency injection
     * @param safe The Safe contract address
     * @param token1 The first reward token address
     * @param token2 The second reward token address
     * @return rewardsModule The deployed RewardsDistributorSafeModule contract address
     */
    function deployRewardsDistributorSafeModule(
        Addresses addresses,
        address payable safe,
        address token1,
        address token2
    ) public returns (address rewardsModule) {
        console.log(
            "\n%s", StdStyle.bold(StdStyle.green("Phase 2: Deploying RewardsDistributorSafeModule contract..."))
        );

        address mamoBackend = addresses.getAddress("MAMO_BACKEND");
        address multiRewards = addresses.getAddress("MAMO_STAKING");

        console.log("Using token1: %s", StdStyle.yellow(vm.toString(token1)));
        console.log("Using token2: %s", StdStyle.yellow(vm.toString(token2)));

        vm.startBroadcast();

        rewardsModule = address(
            new RewardsDistributorSafeModule(
                safe, multiRewards, token1, token2, mamoBackend, DEFAULT_REWARD_DURATION, DEFAULT_NOTIFY_DELAY
            )
        );

        vm.stopBroadcast();

        if (addresses.isAddressSet("REWARDS_DISTRIBUTOR_SAFE_MODULE")) {
            addresses.changeAddress("REWARDS_DISTRIBUTOR_SAFE_MODULE", rewardsModule, true);
        } else {
            addresses.addAddress("REWARDS_DISTRIBUTOR_SAFE_MODULE", rewardsModule, true);
        }

        console.log("RewardsDistributorSafeModule address registered in address registry");
        return rewardsModule;
    }

    /**
     * @notice Validate the deployment of both contracts
     * @param addresses The addresses contract
     * @param multiRewards The deployed MultiRewards contract address
     * @param rewardsModule The deployed RewardsDistributorSafeModule contract address
     * @param token1 The first reward token address
     * @param token2 The second reward token address
     */
    function validateDeployment(
        Addresses addresses,
        address multiRewards,
        address rewardsModule,
        address token1,
        address token2
    ) public view {
        console.log("\n%s", StdStyle.bold(StdStyle.green("Phase 3: Validating deployment...")));

        address mamoMultisig = addresses.getAddress("F-MAMO");

        // Validate MultiRewards contract
        IMultiRewards multiRewardsContract = IMultiRewards(multiRewards);
        assertEq(multiRewardsContract.owner(), mamoMultisig, "MultiRewards: incorrect owner");
        console.log("[OK] MultiRewards owner validation passed");

        // Validate RewardsDistributorSafeModule contract
        RewardsDistributorSafeModule moduleContract = RewardsDistributorSafeModule(rewardsModule);

        assertEq(address(moduleContract.safe()), mamoMultisig, "RewardsModule: incorrect Safe address");
        assertEq(address(moduleContract.multiRewards()), multiRewards, "RewardsModule: incorrect MultiRewards address");
        assertEq(address(moduleContract.token1()), token1, "RewardsModule: incorrect token1 address");
        assertEq(address(moduleContract.token2()), token2, "RewardsModule: incorrect token2 address");
        assertEq(moduleContract.admin(), mamoMultisig, "RewardsModule: incorrect admin address");
        assertEq(moduleContract.rewardDuration(), DEFAULT_REWARD_DURATION, "RewardsModule: incorrect reward duration");

        console.log("[OK] RewardsDistributorSafeModule configuration validation passed");

        // Validate contract code exists
        uint256 multiRewardsCodeSize;
        uint256 moduleCodeSize;
        assembly {
            multiRewardsCodeSize := extcodesize(multiRewards)
            moduleCodeSize := extcodesize(rewardsModule)
        }

        assertTrue(multiRewardsCodeSize > 0, "MultiRewards: no contract code deployed");
        assertTrue(moduleCodeSize > 0, "RewardsModule: no contract code deployed");
        console.log("[OK] Contract code deployment validation passed");

        // Validate address registry updates
        assertEq(addresses.getAddress("MULTI_REWARDS"), multiRewards, "Address registry: MultiRewards not updated");
        assertEq(
            addresses.getAddress("REWARDS_DISTRIBUTOR_SAFE_MODULE"),
            rewardsModule,
            "Address registry: RewardsModule not updated"
        );
        console.log("[OK] Address registry validation passed");

        console.log("\n%s", StdStyle.bold(StdStyle.green("All deployment validations passed successfully!")));
    }
}
