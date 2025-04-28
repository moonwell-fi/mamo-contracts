// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";

import {MAMO} from "@contracts/token/Mamo.sol";

import {MintLimits} from "@contracts/token/MintLimits.sol";
import {WormholeBridgeAdapter} from "@contracts/token/WormholeBridgeAdapter.sol";
import {Script} from "@forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// TODO: make sure it uses create2
contract MAMODeployScript is Script {
    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        deployMamo(addresses);
    }

    function deployMamo(Addresses addresses)
        public
        returns (
            MAMO mamoLogic,
            WormholeBridgeAdapter bridgeAdapterLogic,
            ProxyAdmin proxyAdmin,
            address mamoProxy,
            address bridgeAdapterProxy
        )
    {
        vm.startBroadcast();

        mamoLogic = new MAMO();

        bridgeAdapterLogic = new WormholeBridgeAdapter();

        proxyAdmin = new ProxyAdmin(addresses.getAddress("MAMO_MULTISIG"));

        mamoProxy = address(new TransparentUpgradeableProxy(address(mamoLogic), address(proxyAdmin), ""));

        bridgeAdapterProxy =
            address(new TransparentUpgradeableProxy(address(bridgeAdapterLogic), address(proxyAdmin), ""));

        vm.stopBroadcast();
    }

    function initializeWormholeAdapter(
        address wormholeBridgeAdapterProxy,
        address mamoProxy,
        address owner,
        address wormholeRelayer,
        uint16[] memory chainIds,
        address[] memory targets
    ) public {
        vm.startBroadcast();

        WormholeBridgeAdapter(wormholeBridgeAdapterProxy).initialize(
            address(mamoProxy), owner, wormholeRelayer, chainIds, targets
        );

        vm.stopBroadcast();
    }

    function initializeMamo(
        address mamoProxy,
        address owner,
        MintLimits.RateLimitMidPointInfo[] memory limits,
        uint128 pauseDuration,
        address pauseGuardian
    ) public {
        vm.startBroadcast();

        MAMO(mamoProxy).initialize("MAMO", "MAMO", owner, limits, pauseDuration, pauseGuardian);

        vm.stopBroadcast();
    }
}
