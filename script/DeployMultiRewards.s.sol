// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Multicall} from "@contracts/Multicall.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployMulticall
 * @notice Script to deploy and manage Multicall contract
 */
contract DeployMultiRewards is Script {
    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID
        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        address oldMultiRewards = addresses.getAddress("MAMO_MULTI_REWARDS");

        vm.startBroadcast();
        address multiRewards = deploy(addresses);
        vm.stopBroadcast();

        addresses.changeAddress("MAMO_MULTI_REWARDS", multiRewards, true);
        addresses.addAddress("MAMO_MULTI_REWARDS_DEPRECATED", oldMultiRewards, true);
        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deploy(Addresses addresses) public returns (address multiRewards) {
        address owner = addresses.getAddress("F-MAMO");
        address stakingToken = addresses.getAddress("MAMO");

        multiRewards = deployCode("out/MultiRewards.sol/MultiRewards.json", abi.encode(owner, stakingToken));
    }
}
