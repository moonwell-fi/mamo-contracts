// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";
import {INonfungiblePositionManager} from "@contracts/interfaces/INonfungiblePositionManager.sol";

import {LPAutoBalancerSetup} from "../multisig/f-mamo/006_LPAutoBalancerSetup.sol";

import {console} from "forge-std/console.sol";

contract LPAutoBalancerIntegrationTest is BaseTest {
    LPAutoBalancerSetup public setupScript;
    LPAutoBalancer public lab;

    uint256 public constant TOKEN_ID = 21585074;

    function setUp() public override {
        super.setUp();

        setupScript = new LPAutoBalancerSetup();

        // Pass our addresses instance to the setup script
        setupScript.setAddresses(addresses);

        // Make deploy script persistent across fork snapshots
        vm.makePersistent(address(setupScript.deployLPAutoBalancer()));

        // Deploy LPAutoBalancer if not already set in the address registry
        if (!addresses.isAddressSet("MAMO_LP_AUTO_BALANCER")) {
            address labAddr = setupScript.deployLPAutoBalancer().deploy(addresses);
            addresses.addAddress("MAMO_LP_AUTO_BALANCER", labAddr, true);
        }

        lab = LPAutoBalancer(addresses.getAddress("MAMO_LP_AUTO_BALANCER"));

        // Execute the proposal: release NFT from TransferAndEarn → F-MAMO → lab,
        // then registerPosition() on lab.
        setupScript.build();
        setupScript.simulate();
        setupScript.validate();
    }

    function test_setup_positionRegistered() public view {
        address pm = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");

        // NFT 21585074 owned by LPAutoBalancer
        assertEq(
            INonfungiblePositionManager(pm).ownerOf(TOKEN_ID),
            address(lab),
            "NFT 21585074 should be owned by LPAutoBalancer"
        );

        // Slot 0 is active
        (uint256 tokenId,,,,,,,,,,,,,,,,,,,,, bool active) = lab.positions(0);

        assertTrue(active, "Slot 0 should be active");
        assertEq(tokenId, TOKEN_ID, "Slot 0 tokenId should be 21585074");

        console.log("test_setup_positionRegistered: PASS");
        console.log("  LPAutoBalancer:", address(lab));
        console.log("  NFT tokenId:", tokenId);
        console.log("  Slot 0 active:", active);
    }
}
