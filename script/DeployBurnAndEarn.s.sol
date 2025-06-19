// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";

import {StdStyle} from "@forge-std/StdStyle.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {BurnAndEarn} from "@contracts/BurnAndEarn.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployBurnAndEarn
 * @notice Script to deploy the BurnAndEarn contract
 * @dev Deploys the BurnAndEarn contract and updates the addresses JSON file
 */
contract DeployBurnAndEarn is Script, Test {
    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the BurnAndEarn contract
        BurnAndEarn burnAndEarn = deployBurnAndEarn(addresses);

        // Validate the deployment
        validate(addresses, burnAndEarn);

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== BURN AND EARN DEPLOYMENT COMPLETE ===")));
        console.log("%s: %s", StdStyle.bold("BurnAndEarn contract"), StdStyle.yellow(vm.toString(address(burnAndEarn))));
    }

    /**
     * @notice Deploy the BurnAndEarn contract
     * @param addresses The addresses contract
     * @return burnAndEarn The deployed BurnAndEarn contract
     */
    function deployBurnAndEarn(Addresses addresses) public returns (BurnAndEarn burnAndEarn) {
        vm.startBroadcast();

        // Get the MAMO_MULTISIG address to use as both owner and fee collector
        address mamoMultisig = addresses.getAddress("MAMO_MULTISIG");

        // Deploy the BurnAndEarn contract with the MAMO_MULTISIG as both fee collector and owner
        burnAndEarn = new BurnAndEarn(mamoMultisig, mamoMultisig);
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Deploying BurnAndEarn contract...")));
        console.log("BurnAndEarn contract deployed at: %s", StdStyle.yellow(vm.toString(address(burnAndEarn))));

        vm.stopBroadcast();

        // Add the address to the Addresses contract
        if (addresses.isAddressSet("BURN_AND_EARN")) {
            addresses.changeAddress("BURN_AND_EARN", address(burnAndEarn), true);
        } else {
            addresses.addAddress("BURN_AND_EARN", address(burnAndEarn), true);
        }

        return burnAndEarn;
    }

    /**
     * @notice Validate the BurnAndEarn deployment
     * @param addresses The addresses contract
     * @param burnAndEarn The deployed BurnAndEarn contract
     */
    function validate(Addresses addresses, BurnAndEarn burnAndEarn) public view {
        address mamoMultisig = addresses.getAddress("MAMO_MULTISIG");

        // Verify the owner is set correctly
        assertEq(burnAndEarn.owner(), mamoMultisig, "incorrect owner");

        // Verify the fee collector is set correctly
        assertEq(burnAndEarn.feeCollector(), mamoMultisig, "incorrect fee collector");
    }
}
