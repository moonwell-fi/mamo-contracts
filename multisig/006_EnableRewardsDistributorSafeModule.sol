// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";
import {ISafe} from "@contracts/interfaces/ISafe.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {console} from "forge-std/console.sol";

contract EnableRewardsDistributorSafeModule is MultisigProposal {
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
        return "006_EnableRewardsDistributorSafeModule";
    }

    function description() public pure override returns (string memory) {
        return "Enable RewardsDistributorSafeModule on the F-MAMO Safe multisig";
    }

    function deploy() public override {
        // No deployment needed - the module was deployed in 005
        // This proposal only enables the module on the Safe
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        ISafe safe = ISafe(payable(addresses.getAddress("F-MAMO")));
        address rewardsDistributorModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");

        // Enable the RewardsDistributorSafeModule on the Safe
        if (!safe.isModuleEnabled(rewardsDistributorModule)) {
            safe.enableModule(rewardsDistributorModule);
        }
    }

    function simulate() public override {
        address multisig = addresses.getAddress("F-MAMO");
        _simulateActions(multisig);
    }

    function validate() public view override {
        // Get contract addresses
        address safeAddress = addresses.getAddress("F-MAMO");
        address rewardsDistributorModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");

        ISafe safe = ISafe(payable(safeAddress));

        // Validate that the module is enabled on the Safe
        assertTrue(
            safe.isModuleEnabled(rewardsDistributorModule),
            "RewardsDistributorSafeModule should be enabled on F-MAMO Safe"
        );

        console.log("RewardsDistributorSafeModule successfully enabled on F-MAMO Safe");
    }
}