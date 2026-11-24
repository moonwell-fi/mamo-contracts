// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoStakingV2Deployment} from "../multisig/mamo-multisig/008_MamoStakingV2Deployment.sol";
import {DeployMultiRewards} from "../script/DeployMultiRewards.s.sol";
import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

abstract contract BaseTest is Test {
    Addresses public addresses;
    MamoStakingV2Deployment public proposal;
    DeployMultiRewards public deployMultiRewards;

    /// @dev Last state before proposal 017 executed (block 56,162,541, 2026-11-11). 017 and f-mamo 006 retired
    ///      the v1 staking factory, the v1 drop module and the un-hardened price checker; suites that still
    ///      exercise those against live state roll here first.
    uint256 internal constant PRE_017_BLOCK = 56_162_000;

    /// @dev Call before super.setUp() and run the suite WITHOUT --fork-url (a CLI fork on top panics op-revm
    ///      on the Isthmus L1Block); the zero fees are the same workaround the other pinned suites use.
    function _forkBefore017() internal {
        vm.createSelectFork({urlOrAlias: "base", blockNumber: PRE_017_BLOCK});
        vm.txGasPrice(0);
        vm.fee(0);
    }

    function setUp() public virtual {
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        addresses = PinnedAddresses.load("./addresses");
        vm.makePersistent(address(addresses));
    }
}
