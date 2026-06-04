// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

contract DeployLPAutoBalancer is Script {
    function run() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        Addresses addresses = new Addresses("./addresses", chainIds);

        vm.startBroadcast();
        address lab = deploy(addresses);
        vm.stopBroadcast();

        string memory key = "MAMO_LP_AUTO_BALANCER";
        if (addresses.isAddressSet(key)) {
            addresses.changeAddress(key, lab, true);
        } else {
            addresses.addAddress(key, lab, true);
        }
        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deploy(Addresses addresses) public returns (address) {
        address admin = addresses.getAddress("F-MAMO");
        address manager = addresses.getAddress("MAMO_LP_MANAGER");
        address rebalancer = addresses.getAddress("MAMO_LP_REBALANCER");
        address guardian = addresses.getAddress("MAMO_PAUSE_GUARDIAN");
        address pm = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
        address router = addresses.getAddress("AERODROME_ROUTER");
        address quoter = addresses.getAddress("AERODROME_QUOTER");
        address aero = addresses.getAddress("AERO");

        LPAutoBalancer lab = new LPAutoBalancer(admin, manager, rebalancer, guardian, pm, router, quoter, aero);
        console.log("LPAutoBalancer deployed at:", address(lab));
        return address(lab);
    }
}
