// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployLPAutoBalancerV2
 * @notice Script to deploy the LPAutoBalancerV2 contract (Aerodrome CL rebalancer).
 * @dev The rebalancer (backend signer) is intentionally NOT granted at deploy time — it is
 *      granted later via a Safe proposal. The deploy therefore passes address(0) for
 *      rebalancer_ (and manager_, until a manager EOA name exists). admin_ and guardian_ are
 *      both the F-MAMO Safe.
 */
contract DeployLPAutoBalancerV2 is Script {
    /**
     * @notice Deploys the LPAutoBalancerV2 contract and records its address.
     * @param addresses The FPS Addresses instance for the target chain.
     * @return lpAutoBalancer The deployed LPAutoBalancerV2 contract.
     */
    function deployLPAutoBalancerV2(Addresses addresses) public returns (LPAutoBalancerV2 lpAutoBalancer) {
        // F-MAMO Safe is both admin (DEFAULT_ADMIN_ROLE) and guardian (GUARDIAN_ROLE).
        address admin = addresses.getAddress("F-MAMO");
        address guardian = addresses.getAddress("F-MAMO");
        // The Aerodrome Slipstream NFPM the WETH/cbBTC gauge accepts. Stored under its existing
        // name (the address is already registered; FPS forbids the same address under two names).
        address positionManager = addresses.getAddress("AERODROME_SLIPSTREAM_NFPM_V2");
        address aero = addresses.getAddress("AERO");

        // manager_ and rebalancer_ are granted later via a Safe proposal, so pass address(0).
        address manager = address(0);
        address rebalancer = address(0);

        vm.startBroadcast();
        lpAutoBalancer = new LPAutoBalancerV2(admin, manager, rebalancer, guardian, positionManager, aero);
        vm.stopBroadcast();

        string memory name = "MAMO_LP_AUTO_BALANCER_V2";
        if (addresses.isAddressSet(name)) {
            addresses.changeAddress(name, address(lpAutoBalancer), true);
        } else {
            addresses.addAddress(name, address(lpAutoBalancer), true);
        }

        console.log("LPAutoBalancerV2 deployed at:", address(lpAutoBalancer));
        console.log("  Admin (DEFAULT_ADMIN_ROLE):", admin);
        console.log("  Guardian (GUARDIAN_ROLE):", guardian);
        console.log("  Position Manager (Aerodrome NFPM):", positionManager);
        console.log("  AERO:", aero);
        console.log("  Manager / Rebalancer: not granted (address(0)) - granted later via Safe proposal");
    }

    function run() public returns (LPAutoBalancerV2 lpAutoBalancer) {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        Addresses addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));

        lpAutoBalancer = deployLPAutoBalancerV2(addresses);

        addresses.updateJson();
        addresses.printJSONChanges();
    }
}
