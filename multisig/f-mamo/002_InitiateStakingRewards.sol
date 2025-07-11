// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";
import {ISafe} from "@contracts/interfaces/ISafe.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {console} from "forge-std/console.sol";

contract InitiateStakingRewards is MultisigProposal {
    // Hardcoded reward amounts for each token
    uint256 public immutable MAMO_REWARD_AMOUNT = 1000000e18; // 1M MAMO tokens
    uint256 public immutable CBBTC_REWARD_AMOUNT = 100e8; // 100 cbBTC tokens (8 decimals)

    function _initializeAddresses() internal {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }

    function run() public override {
        _initializeAddresses();

        if (DO_DEPLOY) {
            deploy();
            addresses.updateJson();
            addresses.printJSONChanges();
        }

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
        if (DO_UPDATE_ADDRESS_JSON) addresses.updateJson();
    }

    function name() public pure override returns (string memory) {
        return "002_InitiateStakingRewards";
    }

    function description() public pure override returns (string memory) {
        return
        "Initiate staking rewards distribution by calling addRewards and notifyRewards on RewardsDistributorSafeModule";
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        address rewardsDistributorModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        RewardsDistributorSafeModule rewardsModule = RewardsDistributorSafeModule(rewardsDistributorModule);

        // Add rewards with the hardcoded amounts
        rewardsModule.addRewards(MAMO_REWARD_AMOUNT, CBBTC_REWARD_AMOUNT);

        // Notify the rewards immediately
        rewardsModule.notifyRewards();
    }

    function simulate() public override {
        address multisig = addresses.getAddress("F-MAMO");
        _simulateActions(multisig);
    }

    function validate() public override {
        // Get contract addresses
        address rewardsDistributorModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        RewardsDistributorSafeModule rewardsModule = RewardsDistributorSafeModule(rewardsDistributorModule);

        // Validate that rewards have been executed
        RewardsDistributorSafeModule.RewardState currentState = rewardsModule.getCurrentState();
        assertTrue(
            currentState == RewardsDistributorSafeModule.RewardState.EXECUTED, "Rewards should be in EXECUTED state"
        );

        // Try to notify again and verify it reverts with the correct error
        vm.expectRevert("Rewards not in pending state");
        rewardsModule.notifyRewards();

        // Check that tokens were transferred to MAMO_MULTI_REWARDS contract
        address mamoMultiRewards = addresses.getAddress("MAMO_MULTI_REWARDS");
        address mamoToken = addresses.getAddress("MAMO");
        address cbBTCToken = addresses.getAddress("cbBTC");
        
        uint256 mamoBalance = IERC20(mamoToken).balanceOf(mamoMultiRewards);
        uint256 cbBTCBalance = IERC20(cbBTCToken).balanceOf(mamoMultiRewards);
        
        assertEq(mamoBalance, MAMO_REWARD_AMOUNT, "MAMO tokens should be transferred to MultiRewards contract");
        assertEq(cbBTCBalance, CBBTC_REWARD_AMOUNT, "cbBTC tokens should be transferred to MultiRewards contract");

        console.log("Staking rewards successfully initiated and notified");
        console.log("Verified that attempting to notify again properly reverts");
        console.log("Verified that tokens were transferred to MAMO_MULTI_REWARDS contract");
        console.log("MAMO balance in MultiRewards:", mamoBalance);
        console.log("cbBTC balance in MultiRewards:", cbBTCBalance);
    }
}
