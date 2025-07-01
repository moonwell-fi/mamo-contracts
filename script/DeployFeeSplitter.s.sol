// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {StdStyle} from "@forge-std/StdStyle.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {FeeSplitter} from "@contracts/FeeSplitter.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployFeeSplitter
 * @notice Script to deploy the FeeSplitter contract
 * @dev Deploys the FeeSplitter contract with specified tokens and recipients
 */
contract DeployFeeSplitter is Script, Test {
    // Token addresses as specified
    address constant TOKEN_0 = 0x7300B37DfdfAb110d83290A29DfB31B1740219fE;
    address constant TOKEN_1 = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the FeeSplitter contract
        FeeSplitter feeSplitter = deployFeeSplitter(addresses);

        // Validate the deployment
        validate(addresses, feeSplitter);

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== FEE SPLITTER DEPLOYMENT COMPLETE ===")));
        console.log("%s: %s", StdStyle.bold("FeeSplitter contract"), StdStyle.yellow(vm.toString(address(feeSplitter))));
        console.log("%s: %s", StdStyle.bold("Token 0"), StdStyle.yellow(vm.toString(TOKEN_0)));
        console.log("%s: %s", StdStyle.bold("Token 1"), StdStyle.yellow(vm.toString(TOKEN_1)));
        console.log(
            "%s: %s", StdStyle.bold("Recipient 1 (70%)"), StdStyle.yellow(vm.toString(feeSplitter.RECIPIENT_1()))
        );
        console.log(
            "%s: %s", StdStyle.bold("Recipient 2 (30%)"), StdStyle.yellow(vm.toString(feeSplitter.RECIPIENT_2()))
        );
    }

    /**
     * @notice Deploy the FeeSplitter contract
     * @param addresses The addresses contract
     * @return feeSplitter The deployed FeeSplitter contract
     */
    function deployFeeSplitter(Addresses addresses) public returns (FeeSplitter feeSplitter) {
        vm.startBroadcast();

        address recipient1 = addresses.getAddress("VIRTUALS_MULTISIG"); // 30% recipient
        address recipient2 = addresses.getAddress("MAMO_MULTISIG"); // 70% recipient

        // Deploy the FeeSplitter contract with 70/30 split
        feeSplitter = new FeeSplitter(TOKEN_0, TOKEN_1, recipient1, recipient2, 3000);

        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Deploying FeeSplitter contract...")));
        console.log("FeeSplitter contract deployed at: %s", StdStyle.yellow(vm.toString(address(feeSplitter))));
        console.log("Token 0: %s", StdStyle.yellow(vm.toString(TOKEN_0)));
        console.log("Token 1: %s", StdStyle.yellow(vm.toString(TOKEN_1)));
        console.log("Recipient 1 (70%%): %s", StdStyle.yellow(vm.toString(recipient1)));
        console.log("Recipient 2 (30%%): %s", StdStyle.yellow(vm.toString(recipient2)));

        vm.stopBroadcast();

        // Add the address to the Addresses contract
        if (addresses.isAddressSet("FEE_SPLITTER")) {
            addresses.changeAddress("FEE_SPLITTER", address(feeSplitter), true);
        } else {
            addresses.addAddress("FEE_SPLITTER", address(feeSplitter), true);
        }

        return feeSplitter;
    }

    /**
     * @notice Validate the FeeSplitter deployment
     * @param addresses The addresses contract
     * @param feeSplitter The deployed FeeSplitter contract
     */
    function validate(Addresses addresses, FeeSplitter feeSplitter) public view {
        address expectedRecipient1 = addresses.getAddress("VIRTUALS_MULTISIG");
        address expectedRecipient2 = addresses.getAddress("MAMO_MULTISIG");

        // Verify the tokens are set correctly
        assertEq(feeSplitter.TOKEN_0(), TOKEN_0, "incorrect TOKEN_0");
        assertEq(feeSplitter.TOKEN_1(), TOKEN_1, "incorrect TOKEN_1");

        // Verify the recipients are set correctly
        assertEq(feeSplitter.RECIPIENT_1(), expectedRecipient1, "incorrect RECIPIENT_1");
        assertEq(feeSplitter.RECIPIENT_2(), expectedRecipient2, "incorrect RECIPIENT_2");

        // Verify tokens are different
        assertTrue(feeSplitter.TOKEN_0() != feeSplitter.TOKEN_1(), "tokens should be different");

        // Verify recipients are different
        assertTrue(feeSplitter.RECIPIENT_1() != feeSplitter.RECIPIENT_2(), "recipients should be different");

        console.log("\n%s", StdStyle.bold(StdStyle.green("All validation checks passed!")));
    }
}
