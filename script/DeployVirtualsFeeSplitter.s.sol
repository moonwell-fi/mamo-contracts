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
 * @dev Deploys the VirtualsFeeSplitter contract with specified owner and recipients
 */
contract DeployVirtualsFeeSplitter is Script, Test {
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
            StdStyle.bold("Recipient 1 (70%)"),
            StdStyle.yellow(vm.toString(virtualsFeeSplitter.RECIPIENT_1()))
        );
        console.log(
            "%s: %s",
            StdStyle.bold("Recipient 2 (30%)"),
            StdStyle.yellow(vm.toString(virtualsFeeSplitter.RECIPIENT_2()))
        );

        // Display token addresses
        (address mamo, address virtuals, address cbbtc) = virtualsFeeSplitter.getTokenAddresses();
        console.log("%s: %s", StdStyle.bold("MAMO Token"), StdStyle.yellow(vm.toString(mamo)));
        console.log("%s: %s", StdStyle.bold("Virtuals Token"), StdStyle.yellow(vm.toString(virtuals)));
        console.log("%s: %s", StdStyle.bold("cbBTC Token"), StdStyle.yellow(vm.toString(cbbtc)));

        // Display Aerodrome addresses
        (address router, address quoter) = virtualsFeeSplitter.getAerodromeAddresses();
        console.log("%s: %s", StdStyle.bold("Aerodrome Router"), StdStyle.yellow(vm.toString(router)));
        console.log("%s: %s", StdStyle.bold("Aerodrome Quoter"), StdStyle.yellow(vm.toString(quoter)));
    }

    /**
     * @notice Deploy the VirtualsFeeSplitter contract
     * @param addresses The addresses contract
     * @return virtualsFeeSplitter The deployed VirtualsFeeSplitter contract
     */
    function deployVirtualsFeeSplitter(Addresses addresses) public returns (VirtualsFeeSplitter virtualsFeeSplitter) {
        vm.startBroadcast();

        // Get owner and recipients from addresses
        address owner = addresses.getAddress("MAMO_MULTISIG"); // Owner of the contract
        address recipient1 = addresses.getAddress("MAMO_MULTISIG"); // 70% recipient
        address recipient2 = addresses.getAddress("VIRTUALS_MULTISIG"); // 30% recipient

        // Deploy the VirtualsFeeSplitter contract
        virtualsFeeSplitter = new VirtualsFeeSplitter(owner, recipient1, recipient2);

        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Deploying VirtualsFeeSplitter contract...")));
        console.log(
            "VirtualsFeeSplitter contract deployed at: %s", StdStyle.yellow(vm.toString(address(virtualsFeeSplitter)))
        );
        console.log("Owner: %s", StdStyle.yellow(vm.toString(owner)));
        console.log("Recipient 1 (70%%): %s", StdStyle.yellow(vm.toString(recipient1)));
        console.log("Recipient 2 (30%%): %s", StdStyle.yellow(vm.toString(recipient2)));

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
        address expectedRecipient1 = addresses.getAddress("MAMO_MULTISIG");
        address expectedRecipient2 = addresses.getAddress("VIRTUALS_MULTISIG");

        // Verify the owner is set correctly
        assertEq(virtualsFeeSplitter.owner(), expectedOwner, "incorrect owner");

        // Verify the recipients are set correctly
        assertEq(virtualsFeeSplitter.RECIPIENT_1(), expectedRecipient1, "incorrect RECIPIENT_1");
        assertEq(virtualsFeeSplitter.RECIPIENT_2(), expectedRecipient2, "incorrect RECIPIENT_2");

        // Verify recipients are different
        assertTrue(
            virtualsFeeSplitter.RECIPIENT_1() != virtualsFeeSplitter.RECIPIENT_2(), "recipients should be different"
        );

        // Verify split ratios
        (uint256 recipient1Share, uint256 recipient2Share) = virtualsFeeSplitter.getSplitRatios();
        assertEq(recipient1Share, 70, "incorrect recipient1 share");
        assertEq(recipient2Share, 30, "incorrect recipient2 share");

        // Verify token addresses are set
        (address mamo, address virtuals, address cbbtc) = virtualsFeeSplitter.getTokenAddresses();
        assertTrue(mamo != address(0), "MAMO token address should not be zero");
        assertTrue(virtuals != address(0), "Virtuals token address should not be zero");
        assertTrue(cbbtc != address(0), "cbBTC token address should not be zero");

        // Verify Aerodrome addresses are set
        (address router, address quoter) = virtualsFeeSplitter.getAerodromeAddresses();
        assertTrue(router != address(0), "Aerodrome router address should not be zero");
        assertTrue(quoter != address(0), "Aerodrome quoter address should not be zero");

        console.log("\n%s", StdStyle.bold(StdStyle.green("All validation checks passed!")));
    }
}
