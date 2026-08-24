// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {LPValuationLib} from "@contracts/libraries/LPValuationLib.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {DeployLPAutoBalancerV2} from "@script/DeployLPAutoBalancerV2.s.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {console} from "forge-std/console.sol";
