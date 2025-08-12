// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoStakingV2Deployment} from "../multisig/mamo-multisig/008_MamoStakingV2Deployment.sol";
import {DeployMultiRewards} from "../script/DeployMultiRewards.s.sol";
import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

abstract contract BaseTest is Test {
    Addresses public addresses;
    MamoStakingV2Deployment public proposal;
    DeployMultiRewards public deployMultiRewards;

    function setUp() public virtual {
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        // Create a new addresses instance for testing
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        addresses = new Addresses(addressesFolderPath, chainIds);
    }
}
