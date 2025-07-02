// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {StdStyle} from "@forge-std/StdStyle.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {VirtualsFeeSplitter} from "@contracts/VirtualsFeeSplitter.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployVirtualsFeeSplitter
 * @notice Script to deploy the VirtualsFeeSplitter contract
 * @dev Deploys the VirtualsFeeSplitter contract with specified owner and recipient
 */
contract DeployVirtualsFeeSplitter is Script, Test {
    // Token addresses for Base mainnet
    address constant MAMO_TOKEN = 0x7300B37DfdfAb110d83290A29DfB31B1740219fE;
    address constant VIRTUALS_TOKEN = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address constant CBBTC_TOKEN = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the VirtualsFeeSplitter contract
        VirtualsFeeSplitter virtualsFeeSplitter = deployVirtualsFeeSplitter(addresses);

        // Validate the deployment
        validate(addresses, virtualsFeeSplitter);

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== VIRTUALS FEE SPLITTER DEPLOYMENT COMPLETE ===")));
        console.log(
            "%s: %s",
            StdStyle.bold("VirtualsFeeSplitter contract"),
            StdStyle.yellow(vm.toString(address(virtualsFeeSplitter)))
        );
        console.log("%s: %s", StdStyle.bold("Owner"), StdStyle.yellow(vm.toString(virtualsFeeSplitter.owner())));
        console.log(
            "%s: %s",
            StdStyle.bold("Recipient"),
            StdStyle.yellow(vm.toString(virtualsFeeSplitter.RECIPIENT()))
        );

        // Display token addresses
        console.log("%s: %s", StdStyle.bold("MAMO Token"), StdStyle.yellow(vm.toString(virtualsFeeSplitter.MAMO_TOKEN())));
        console.log("%s: %s", StdStyle.bold("Virtuals Token"), StdStyle.yellow(vm.toString(virtualsFeeSplitter.VIRTUALS_TOKEN())));
        console.log("%s: %s", StdStyle.bold("cbBTC Token"), StdStyle.yellow(vm.toString(virtualsFeeSplitter.CBBTC_TOKEN())));

        // Display Aerodrome router address
        console.log("%s: %s", StdStyle.bold("Aerodrome Router"), StdStyle.yellow(vm.toString(virtualsFeeSplitter.AERODROME_ROUTER())));
    }

    /**
     * @notice Deploy the VirtualsFeeSplitter contract
     * @param addresses The addresses contract
     * @return virtualsFeeSplitter The deployed VirtualsFeeSplitter contract
     */
    function deployVirtualsFeeSplitter(Addresses addresses) public returns (VirtualsFeeSplitter virtualsFeeSplitter) {
        vm.startBroadcast();

        // Get owner and recipient from addresses
        address owner = addresses.getAddress("MAMO_MULTISIG"); // Owner of the contract
        address recipient = addresses.getAddress("VIRTUALS_MULTISIG"); // Single recipient

        // Deploy the VirtualsFeeSplitter contract with all constructor parameters
        virtualsFeeSplitter = new VirtualsFeeSplitter(
            owner,
            recipient,
            MAMO_TOKEN,
            VIRTUALS_TOKEN,
            CBBTC_TOKEN,
            AERODROME_ROUTER
        );

        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Deploying VirtualsFeeSplitter contract...")));
        console.log(
            "VirtualsFeeSplitter contract deployed at: %s", StdStyle.yellow(vm.toString(address(virtualsFeeSplitter)))
        );
        console.log("Owner: %s", StdStyle.yellow(vm.toString(owner)));
        console.log("Recipient: %s", StdStyle.yellow(vm.toString(recipient)));

        vm.stopBroadcast();

        // Add the address to the Addresses contract
        if (addresses.isAddressSet("VIRTUALS_FEE_SPLITTER")) {
            addresses.changeAddress("VIRTUALS_FEE_SPLITTER", address(virtualsFeeSplitter), true);
        } else {
            addresses.addAddress("VIRTUALS_FEE_SPLITTER", address(virtualsFeeSplitter), true);
        }

        return virtualsFeeSplitter;
    }

    /**
     * @notice Validate the VirtualsFeeSplitter deployment
     * @param addresses The addresses contract
     * @param virtualsFeeSplitter The deployed VirtualsFeeSplitter contract
     */
    function validate(Addresses addresses, VirtualsFeeSplitter virtualsFeeSplitter) public view {
        address expectedOwner = addresses.getAddress("MAMO_MULTISIG");
        address expectedRecipient = addresses.getAddress("VIRTUALS_MULTISIG");

        // Verify the owner is set correctly
        assertEq(virtualsFeeSplitter.owner(), expectedOwner, "incorrect owner");

        // Verify the recipient is set correctly
        assertEq(virtualsFeeSplitter.RECIPIENT(), expectedRecipient, "incorrect RECIPIENT");

        // Verify token addresses are set correctly
        assertEq(virtualsFeeSplitter.MAMO_TOKEN(), MAMO_TOKEN, "incorrect MAMO token address");
        assertEq(virtualsFeeSplitter.VIRTUALS_TOKEN(), VIRTUALS_TOKEN, "incorrect VIRTUALS token address");
        assertEq(virtualsFeeSplitter.CBBTC_TOKEN(), CBBTC_TOKEN, "incorrect cbBTC token address");

        // Verify Aerodrome router address is set correctly
        assertEq(virtualsFeeSplitter.AERODROME_ROUTER(), AERODROME_ROUTER, "incorrect Aerodrome router address");

        // Verify addresses are not zero
        assertTrue(virtualsFeeSplitter.MAMO_TOKEN() != address(0), "MAMO token address should not be zero");
        assertTrue(virtualsFeeSplitter.VIRTUALS_TOKEN() != address(0), "Virtuals token address should not be zero");
        assertTrue(virtualsFeeSplitter.CBBTC_TOKEN() != address(0), "cbBTC token address should not be zero");
        assertTrue(virtualsFeeSplitter.AERODROME_ROUTER() != address(0), "Aerodrome router address should not be zero");
        assertTrue(virtualsFeeSplitter.RECIPIENT() != address(0), "Recipient address should not be zero");

        console.log("\n%s", StdStyle.bold(StdStyle.green("All validation checks passed!")));
    }
}
