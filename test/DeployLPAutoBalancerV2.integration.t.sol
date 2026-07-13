// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployLPAutoBalancerV2} from "../script/DeployLPAutoBalancerV2.s.sol";
import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/// @notice Deploy-script smoke test for LPAutoBalancerV2. Verifies the deploy wires the
///         F-MAMO Safe as admin, the Aerodrome NFPM + AERO immutables, and that the
///         rebalancer/manager roles are NOT granted (they are granted later via a Safe proposal).
contract DeployLPAutoBalancerV2Test is Test {
    // Pinned Base block — the constructor runs against a forked post-Isthmus block, which under
    // foundry 1.7.x panics on operator-fee refund unless gas/base fee are zeroed (see below).
    uint256 constant PINNED_BLOCK = 47_600_000;

    Addresses internal addresses;
    DeployLPAutoBalancerV2 internal deployScript;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        // Zero gas/base fee so the op-revm operator-fee refund path is a no-op (otherwise the
        // deploy tx panics with "Missing operator fee scalar for isthmus L1 Block").
        vm.txGasPrice(0);
        vm.fee(0);

        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));

        deployScript = new DeployLPAutoBalancerV2();
        vm.makePersistent(address(deployScript));
    }

    function testDeployLPAutoBalancerV2() public {
        LPAutoBalancerV2 lab = deployScript.deployLPAutoBalancerV2(addresses);

        // Contract deployed.
        assertTrue(address(lab) != address(0), "not deployed");
        assertGt(address(lab).code.length, 0, "no code");

        address fMamo = addresses.getAddress("F-MAMO");
        address nfpm = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
        address aero = addresses.getAddress("AERO");

        // F-MAMO holds DEFAULT_ADMIN_ROLE.
        assertTrue(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), fMamo), "F-MAMO not admin");
        // F-MAMO also holds GUARDIAN_ROLE (admin == guardian by design).
        assertTrue(lab.hasRole(lab.GUARDIAN_ROLE(), fMamo), "F-MAMO not guardian");

        // Immutables wired to the registered addresses.
        assertEq(address(lab.POSITION_MANAGER()), nfpm, "wrong position manager");
        assertEq(lab.AERO(), aero, "wrong AERO");

        // Rebalancer/manager roles NOT granted to anyone yet (granted later via Safe proposal).
        assertEq(lab.getRoleMemberCount(lab.REBALANCER_ROLE()), 0, "rebalancer should be ungranted");
        assertEq(lab.getRoleMemberCount(lab.MANAGER_ROLE()), 0, "manager should be ungranted");

        // Recorded in the Addresses registry.
        assertTrue(addresses.isAddressSet("MAMO_LP_AUTO_BALANCER_V2"), "not registered");
        assertEq(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2"), address(lab), "registry mismatch");
    }
}
