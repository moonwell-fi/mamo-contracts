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
    /// @notice the duration of the pause for the MAMO token
    /// once the contract has been paused, in this period of time,
    /// it will automatically unpause if no action is taken.
    uint128 public constant pauseDuration = 10 days;

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

        // initialize bridgeAdapter

        address relayer = addresses.getAddress("WORMHOLE_BRIDGE_RELAYER_PROXY");

        uint16[] memory targetChains = new uint16[](0); // initialize with 0 target chains
        address[] memory targetAddresses = new address[](0); // initialize with 0 target addresses

        WormholeBridgeAdapter(bridgeAdapterProxy).initialize(
            address(mamoProxy), addresses.getAddress("MAMO_MULTISIG"), relayer, targetChains, targetAddresses
        );

        // initialize mamoContract

        MintLimits.RateLimitMidPointInfo[] memory limits = new MintLimits.RateLimitMidPointInfo[](1);

        limits[0].bridge = bridgeAdapterProxy;
        limits[0].rateLimitPerSecond = uint128(1e18);
        limits[0].bufferCap = uint112(1_001 * 1e18); // Must be greater than MIN_BUFFER_CAP

        MAMO(mamoProxy).initialize(
            "MAMO",
            "MAMO",
            addresses.getAddress("MAMO_MULTISIG"),
            limits,
            pauseDuration,
            addresses.getAddress("MAMO_PAUSE_GUARDIAN")
        );
        vm.stopBroadcast();
    }
}
