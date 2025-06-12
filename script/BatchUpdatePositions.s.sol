// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployConfig} from "./DeployConfig.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {StrategyMulticall} from "@contracts/StrategyMulticall.sol";

/**
 * @title BatchUpdatePositions
 * @notice Script to deploy and manage StrategyMulticall contract for batch operations
 */
contract BatchUpdatePositions is Script {
    function deployStrategyMulticall(Addresses addresses) public returns (address) {
        vm.startBroadcast();

        // Get the addresses for the initialization parameters
        address owner = addresses.getAddress("MAMO_BACKEND");

        // Deploy the StrategyMulticall
        StrategyMulticall multicall = new StrategyMulticall(owner);

        vm.stopBroadcast();

        // Check if the multicall address already exists
        string memory multicallName = "STRATEGY_MULTICALL";
        if (addresses.isAddressSet(multicallName)) {
            // Update the existing address
            addresses.changeAddress(multicallName, address(multicall), true);
        } else {
            // Add the multicall address to the addresses contract
            addresses.addAddress(multicallName, address(multicall), true);
        }

        return address(multicall);
    }
}
