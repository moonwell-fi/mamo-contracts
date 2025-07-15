// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoStakingRegistry} from "@contracts/MamoStakingRegistry.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {console} from "forge-std/console.sol";

contract ChangeMamoStakingBackendRole is MultisigProposal {
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
        return "001_ChangeMamoStakingBackendRole";
    }

    function description() public pure override returns (string memory) {
        return "Transfer BACKEND_ROLE from MAMO_STAKING_BACKEND to STRATEGY_MULTICALL in MamoStakingRegistry";
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        MamoStakingRegistry stakingRegistry = MamoStakingRegistry(addresses.getAddress("MAMO_STAKING_REGISTRY"));
        address currentBackend = addresses.getAddress("MAMO_STAKING_BACKEND");
        address strategyMulticall = addresses.getAddress("STRATEGY_MULTICALL");

        // Revoke BACKEND_ROLE from current backend
        stakingRegistry.revokeRole(stakingRegistry.BACKEND_ROLE(), currentBackend);

        // Grant BACKEND_ROLE to STRATEGY_MULTICALL
        stakingRegistry.grantRole(stakingRegistry.BACKEND_ROLE(), strategyMulticall);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("F-MAMO");
        _simulateActions(multisig);
    }

    function validate() public view override {
        MamoStakingRegistry stakingRegistry = MamoStakingRegistry(addresses.getAddress("MAMO_STAKING_REGISTRY"));
        address currentBackend = addresses.getAddress("MAMO_STAKING_BACKEND");
        address strategyMulticall = addresses.getAddress("STRATEGY_MULTICALL");

        // Verify current backend no longer has BACKEND_ROLE
        assertFalse(
            stakingRegistry.hasRole(stakingRegistry.BACKEND_ROLE(), currentBackend),
            "Current backend should not have BACKEND_ROLE"
        );

        // Verify STRATEGY_MULTICALL has BACKEND_ROLE
        assertTrue(
            stakingRegistry.hasRole(stakingRegistry.BACKEND_ROLE(), strategyMulticall),
            "STRATEGY_MULTICALL should have BACKEND_ROLE"
        );
    }
}
