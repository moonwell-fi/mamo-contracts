// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {InitiateStakingRewards} from "../multisig/f-mamo/002_InitiateStakingRewards.sol";

abstract contract BaseTest is Test {
    Addresses public addresses;
    InitiateStakingRewards public proposal;

    function setUp() public virtual {
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        // Create a new addresses instance for testing
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Create and execute the multisig proposal
        proposal = new InitiateStakingRewards();

        // Deploy any necessary contracts
        proposal.deploy();

        // Build the proposal actions
        proposal.build();

        // Simulate the proposal execution
        proposal.simulate();

        // Validate the proposal results
        proposal.validate();
    }

    /// @dev Helper function to create a fork for testing
    function createFork() internal {
        vm.createSelectFork("base");
    }
}
