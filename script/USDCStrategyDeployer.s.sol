// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract USDCStrategyDeployer is Script {
    Addresses public addresses;

    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the strategy implementation and proxy
        deployImplementation();

        addresses.updateJson();

        addresses.printJSONChanges();
    }

    function deployImplementation() public returns (address) {
        vm.startBroadcast();
        // Deploy the implementation contract
        ERC20MoonwellMorphoStrategy implementation = new ERC20MoonwellMorphoStrategy();

        vm.stopBroadcast();

        // Add implementation address to addresses
        addresses.addAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL", address(implementation), true);

        // Log the deployed contract address
        console.log("ERC20MoonwellMorphoStrategy implementation deployed at:", address(implementation));

        return address(implementation);
    }
}
