// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@fps/addresses/Addresses.sol";

import {BurnAndEarn} from "@contracts/BurnAndEarn.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {console} from "forge-std/console.sol";

contract TransferFeeCollector is MultisigProposal {
    constructor() {
        setPrimaryForkId(vm.createSelectFork("base"));

        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);
    }

    function name() public pure override returns (string memory) {
        return "TRANSFER_FEE_COLLECTOR_AND_OWNERSHIP";
    }

    function description() public pure override returns (string memory) {
        return "Transfer BurnAndEarn setFeeCollector and ownership to F-MAMO";
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Get the BurnAndEarn contract
        address burnAndEarnAddress = addresses.getAddress("BURN_AND_EARN");
        BurnAndEarn burnAndEarn = BurnAndEarn(burnAndEarnAddress);

        // Get the F-MAMO address
        address fMamoAddress = addresses.getAddress("F-MAMO");

        // Set the fee collector to F-MAMO
        burnAndEarn.setFeeCollector(fMamoAddress);

        // Transfer ownership to F-MAMO
        burnAndEarn.transferOwnership(fMamoAddress);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");

        _simulateActions(multisig);
    }

    function validate() public override {
        // Verify the fee collector has been set to F-MAMO
        address burnAndEarnAddress = addresses.getAddress("BURN_AND_EARN");
        BurnAndEarn burnAndEarn = BurnAndEarn(burnAndEarnAddress);

        address fMamoAddress = addresses.getAddress("F-MAMO");
        address oldOwner = addresses.getAddress("MAMO_MULTISIG");

        assertEq(burnAndEarn.feeCollector(), fMamoAddress, "Fee collector should be set to F-MAMO");
        assertEq(burnAndEarn.owner(), fMamoAddress, "Owner should be transferred to F-MAMO");
        assertFalse(burnAndEarn.owner() == oldOwner, "Old owner should no longer have ownership");
        assertFalse(burnAndEarn.feeCollector() == oldOwner, "Old owner should no longer have ownership");
    }
}
