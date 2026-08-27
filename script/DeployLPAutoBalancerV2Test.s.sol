// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployLPAutoBalancerV2Test
 * @notice TEST deployment of LPAutoBalancerV2 + LPCompoundModule with an EOA admin.
 *
 * @dev SEPARATE FROM `DeployLPAutoBalancerV2` ON PURPOSE. That script is the production path: it
 *      hardcodes admin = guardian = F-MAMO and registers under `MAMO_LP_AUTO_BALANCER_V2`, which is
 *      the name proposal 011 resolves through. Parameterising it would let a test run overwrite the
 *      production entry, and `011.deploy()` is idempotent on exactly that key — a test address
 *      sitting there makes the Safe proposal skip deployment and wire itself to the wrong contract.
 *
 *      So this script registers under DISTINCT names:
 *        MAMO_LP_AUTO_BALANCER_V2_TEST
 *        MAMO_LP_COMPOUND_MODULE_TEST
 *
 *      Roles, from the environment:
 *        LP_TEST_ADMIN      required — DEFAULT_ADMIN_ROLE on both contracts
 *        LP_TEST_GUARDIAN   optional — defaults to LP_TEST_ADMIN (pause/unpause)
 *        LP_TEST_MANAGER    optional — defaults to address(0)
 *        LP_TEST_REBALANCER optional — defaults to address(0); the admin grants it later with
 *                           `grantRole(REBALANCER_ROLE, eoa)`, which is why leaving it unset is safe
 *                           rather than a half-configured deployment.
 *
 *      An EOA admin means one key holds exit(), setPool, setOracles, recoverERC20 and every other
 *      unbounded-value path. That is acceptable for a test position and NOT acceptable for real
 *      funds — the production deployment keeps those behind the F-MAMO Safe.
 */
contract DeployLPAutoBalancerV2Test is Script {
    string public constant BALANCER_NAME = "MAMO_LP_AUTO_BALANCER_V2_TEST";
    string public constant MODULE_NAME = "MAMO_LP_COMPOUND_MODULE_TEST";

    function run() public {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        Addresses addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));

        address admin = vm.envAddress("LP_TEST_ADMIN");
        require(admin != address(0), "LP_TEST_ADMIN must be set");
        address guardian = vm.envOr("LP_TEST_GUARDIAN", admin);
        address manager = vm.envOr("LP_TEST_MANAGER", address(0));
        address rebalancer = vm.envOr("LP_TEST_REBALANCER", address(0));

        address positionManager = addresses.getAddress("AERODROME_SLIPSTREAM_NFPM_V2");
        address aero = addresses.getAddress("AERO");

        vm.startBroadcast();
        LPAutoBalancerV2 lab = new LPAutoBalancerV2(admin, manager, rebalancer, guardian, positionManager, aero);
        LPCompoundModule module = new LPCompoundModule(address(lab), aero, admin);
        vm.stopBroadcast();

        _record(addresses, BALANCER_NAME, address(lab));
        _record(addresses, MODULE_NAME, address(module));
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("=== TEST deployment (EOA admin) ===");
        console.log("  LPAutoBalancerV2 :", address(lab));
        console.log("  LPCompoundModule :", address(module));
        console.log("  admin/guardian   :", admin, guardian);
        console.log("  manager/rebalancer (0 = granted later by admin):", manager, rebalancer);
    }

    function _record(Addresses addresses, string memory name, address addr) internal {
        if (addresses.isAddressSet(name)) {
            addresses.changeAddress(name, addr, true);
        } else {
            addresses.addAddress(name, addr, true);
        }
    }
}
