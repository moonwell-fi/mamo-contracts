// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {LPPairConfig} from "@script/LPPairConfig.sol";

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployLPAutoBalancerV2Pair
 * @notice Deploys LPAutoBalancerV2 + LPCompoundModule for ONE production pair (CREATEs only).
 *
 * @dev No position, no NFT deposit, no allocation: the balancer manages a single position and
 *      `registerPosition` is a later admin tx, so deploying and funding are separate steps here.
 *      Likewise the safety wiring (setSequencerUptimeFeed / setMaxOracleDelays / setCompoundModule)
 *      is admin-gated and is NOT done here.
 *
 *      Env:
 *        LP_PAIR        required — "WETH_USDC" or "USDC_CBBTC"
 *        LP_ADMIN       optional — DEFAULT_ADMIN_ROLE; defaults to MAMO_LP_REBALANCER
 *        LP_GUARDIAN    optional — defaults to LP_ADMIN
 *        LP_MANAGER     optional — defaults to address(0), granted later by the admin
 *        LP_REBALANCER  optional — defaults to address(0), granted later by the admin
 *
 *      Registers under MAMO_LP_AUTO_BALANCER_V2_<LP_PAIR> / MAMO_LP_COMPOUND_MODULE_<LP_PAIR> and
 *      is idempotent on the balancer name, so a re-run never silently forks the deployment.
 */
contract DeployLPAutoBalancerV2Pair is Script {
    using LPPairConfig for LPPairConfig.Pair;

    function run() public returns (LPAutoBalancerV2 lab, LPCompoundModule module) {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        Addresses addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));

        LPPairConfig.Pair memory pair = LPPairConfig.byKey(addresses, vm.envString("LP_PAIR"));
        _assertPairMatchesChain(pair);

        address admin = vm.envOr("LP_ADMIN", addresses.getAddress("MAMO_LP_REBALANCER"));
        require(admin != address(0), "LP_ADMIN must be set");
        address guardian = vm.envOr("LP_GUARDIAN", admin);
        address manager = vm.envOr("LP_MANAGER", address(0));
        address rebalancer = vm.envOr("LP_REBALANCER", address(0));

        string memory balancerName = pair.balancerName();
        require(!addresses.isAddressSet(balancerName), string.concat(balancerName, " already deployed"));

        address nfpm = addresses.getAddress("AERODROME_SLIPSTREAM_NFPM_V2");
        address aero = addresses.getAddress("AERO");

        vm.startBroadcast();
        lab = new LPAutoBalancerV2(admin, manager, rebalancer, guardian, nfpm, aero);
        module = new LPCompoundModule(address(lab), aero, admin);
        vm.stopBroadcast();

        addresses.addAddress(balancerName, address(lab), true);
        addresses.addAddress(pair.moduleName(), address(module), true);
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("=== LPAutoBalancerV2 pair deployment ===");
        console.log("  pair             :", pair.key);
        console.log("  pool / gauge     :", pair.pool, pair.gauge);
        console.log("  LPAutoBalancerV2 :", address(lab));
        console.log("  LPCompoundModule :", address(module));
        console.log("  admin / guardian :", admin, guardian);
        console.log("  manager / rebalancer (0 = granted later):", manager, rebalancer);
    }

    /// @dev Prove the address-book entry is the pool the later `registerPosition` will bind: a wrong
    ///      pool or gauge fails the forge simulation instead of the Safe tx that stakes the NFT.
    function _assertPairMatchesChain(LPPairConfig.Pair memory pair) internal view {
        require(ICLPool(pair.pool).token0() == pair.token0, "pool token0 mismatch");
        require(ICLPool(pair.pool).token1() == pair.token1, "pool token1 mismatch");
        require(ICLPool(pair.pool).tickSpacing() == pair.tickSpacing, "pool tickSpacing mismatch");
        require(ICLGauge(pair.gauge).pool() == pair.pool, "gauge is not this pool's gauge");
    }
}
