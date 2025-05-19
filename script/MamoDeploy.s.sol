// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";

import {MAMO} from "@contracts/token/Mamo.sol";
import {Script} from "@forge-std/Script.sol";
import {StdStyle} from "@forge-std/StdStyle.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

/**
 * @title MamoDeployScript
 * @notice Script to deploy the Mamo token
 */
contract MamoDeployScript is Script, Test {
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;
    uint256 internal constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the Mamo token
        MAMO mamo = deployMamo(addresses);

        validate(addresses);

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== MAMO DEPLOYMENT COMPLETE ===")));
        console.log("%s: %s", StdStyle.bold("Mamo contract"), StdStyle.yellow(vm.toString(address(mamo))));
    }

    /**
     * @notice Deploy the Mamo token contract (non-upgradeable)
     * @param addresses The addresses contract
     * @return mamo The deployed MAMO contract
     */
    function deployMamo(Addresses addresses) public returns (MAMO mamo) {
        vm.startBroadcast();

        address recipient = addresses.getAddress("MAMO_MULTISIG");

        // Deploy the Mamo2 contract directly with constructor parameters
        mamo = new MAMO("Mamo", "MAMO", recipient);
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Deploying Mamo contract...")));
        console.log("Mamo contract deployed at: %s", StdStyle.yellow(vm.toString(address(mamo))));

        vm.stopBroadcast();

        // Add the address to the Addresses contract
        if (addresses.isAddressSet("MAMO")) {
            addresses.changeAddress("MAMO", address(mamo), true);
        } else {
            addresses.addAddress("MAMO", address(mamo), true);
        }

        return mamo;
    }

    function validate(Addresses addresses) public {
        address mamoAddress = addresses.getAddress("MAMO");
        MAMO mamo = MAMO(mamoAddress);

        assertEq(mamo.name(), "Mamo", "incorrect name");
        assertEq(mamo.symbol(), "MAMO", "incorrect symbol");
        assertEq(mamo.totalSupply(), MAX_SUPPLY, "incorrect total supply");
        assertEq(mamo.balanceOf(addresses.getAddress("MAMO_MULTISIG")), MAX_SUPPLY, "incorrect recipient balance");
        assertEq(mamo.decimals(), 18, "incorrect decimals");

        uint256 amount = 100 * 1e18;
        // superchainTokenBridge can mint
        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        address recipient = makeAddr("recipient");
        mamo.crosschainMint(recipient, amount);
        assertEq(mamo.balanceOf(recipient), amount, "incorrect recipient balance");

        deal(address(mamo), recipient, amount);

        // superchainTokenBridge can burn
        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        mamo.crosschainBurn(recipient, amount);
        assertEq(mamo.balanceOf(recipient), 0, "incorrect recipient balance");
    }
}
