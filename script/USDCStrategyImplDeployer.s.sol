// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployConfig} from "./DeployConfig.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract USDCStrategyImplDeployer is Script {
    function deployImplementation(Addresses addresses) public returns (address) {
        vm.startBroadcast();
        // Deploy the implementation contract
        ERC20MoonwellMorphoStrategy implementation = new ERC20MoonwellMorphoStrategy();

        vm.stopBroadcast();

        // Check if the implementation address already exists
        string memory implName = "USDC_MOONWELL_MORPHO_STRATEGY_IMPL";
        if (addresses.isAddressSet(implName)) {
            // Update the existing address
            addresses.changeAddress(implName, address(implementation), true);
        } else {
            // Add the implementation address to the addresses contract
            addresses.addAddress(implName, address(implementation), true);
        }

        // Log the deployed contract address
        console.log("ERC20MoonwellMorphoStrategy implementation deployed at:", address(implementation));

        return address(implementation);
    }
}
