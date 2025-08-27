// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";

import {StdStyle} from "@forge-std/StdStyle.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {TransferAndEarn} from "@contracts/TransferAndEarn.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployTransferAndEarn
 * @notice Script to deploy the TransferAndEarn contract
 * @dev Deploys the TransferAndEarn contract using CREATE2 for deterministic addresses
 */
contract DeployTransferAndEarn is Script, Test {
    /// @notice Salt for CREATE2 deployment to ensure same address across chains
    bytes32 public constant SALT = keccak256("MAMO_TRANSFER_AND_EARN_V1");

    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the TransferAndEarn contract
        TransferAndEarn transferAndEarn = deployTransferAndEarn(addresses);

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        // Validate the deployment
        validate(addresses, transferAndEarn);

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== TRANSFER AND EARN DEPLOYMENT COMPLETE ===")));
        console.log(
            "%s: %s", StdStyle.bold("TransferAndEarn contract"), StdStyle.yellow(vm.toString(address(transferAndEarn)))
        );
    }

    /**
     * @notice Deploy the TransferAndEarn contract
     * @param addresses The addresses contract
     * @return transferAndEarn The deployed TransferAndEarn contract
     */
    function deployTransferAndEarn(Addresses addresses) public returns (TransferAndEarn transferAndEarn) {
        vm.startBroadcast();

        // Get the MAMO_MULTISIG address to use as both owner and fee collector
        address fMamo = addresses.getAddress("F-MAMO");

        // Deploy the TransferAndEarn contract using CREATE2 with the MAMO_MULTISIG as both fee collector and owner
        transferAndEarn = new TransferAndEarn{salt: SALT}(fMamo, fMamo);
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Deploying TransferAndEarn contract with CREATE2...")));
        console.log("Salt: %s", StdStyle.blue(vm.toString(SALT)));
        console.log("TransferAndEarn contract deployed at: %s", StdStyle.yellow(vm.toString(address(transferAndEarn))));

        vm.stopBroadcast();

        if (!addresses.isAddressSet("TRANSFER_AND_EARN")) {
            // Add the address to the Addresses contract
            addresses.addAddress("TRANSFER_AND_EARN", address(transferAndEarn), true);
        } else {
            // Update the address in the Addresses contract
            addresses.changeAddress("TRANSFER_AND_EARN", address(transferAndEarn), true);
        }

        return transferAndEarn;
    }

    /**
     * @notice Validate the TransferAndEarn deployment
     * @param addresses The addresses contract
     * @param transferAndEarn The deployed TransferAndEarn contract
     */
    function validate(Addresses addresses, TransferAndEarn transferAndEarn) public view {
        address fMamo = addresses.getAddress("F-MAMO");

        // Verify the owner is set correctly
        assertEq(transferAndEarn.owner(), fMamo, "incorrect owner");

        // Verify the fee collector is set correctly
        assertEq(transferAndEarn.feeCollector(), fMamo, "incorrect fee collector");
    }
}
