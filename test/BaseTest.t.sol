// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "@forge-std/Test.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {MAMO} from "@contracts/token/Mamo.sol";

import {MintLimits} from "@contracts/token/MintLimits.sol";
import {WormholeBridgeAdapter} from "@contracts/token/WormholeBridgeAdapter.sol";
import {MAMODeployScript} from "@script/MamoDeploy.s.sol";

// TODO: move this to ChainIds.sol
uint16 constant BASE_WORMHOLE_CHAIN_ID = 30;

contract BaseTest is MAMODeployScript, Test {
    /// @notice addresses contract, stores all addresses
    Addresses public addresses;

    /// @notice reference to the wormhole bridge adapter
    WormholeBridgeAdapter public wormholeBridgeAdapterProxy;

    /// @notice proxy admin contract
    ProxyAdmin public proxyAdmin;

    /// @notice proxy contract, stores all state
    MAMO public mamoProxy;

    MAMO public mamoLogic;

    /// @notice external chain buffer cap
    uint112 public externalChainBufferCap = 100_000_000 * 1e18;

    /// @notice external chain rate limit per second
    uint112 public externalChainRateLimitPerSecond = 1_000 * 1e18;

    /// @notice wormhole chainid for base chain
    uint16 public chainId = BASE_WORMHOLE_CHAIN_ID;

    /// @notice owner address for the contracts
    address public owner = address(0x1234);

    /// @notice pause guardian address for the contracts
    address public pauseGuardian = address(0x5678);

    function setUp() public virtual {
        // Initialize addresses with the folder path and chain IDs
        uint256[] memory chainIdArray = new uint256[](1);
        chainIdArray[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIdArray);

        {
            (mamoLogic,, proxyAdmin, mamoProxy, wormholeBridgeAdapterProxy) = deployMamo(addresses);

            vm.label(address(mamoProxy), "Mamo Proxy");
            vm.label(address(proxyAdmin), "Proxy Admin");
            vm.label(address(wormholeBridgeAdapterProxy), "Wormhole Bridge Adapter Proxy");
        }

        MintLimits.RateLimitMidPointInfo[] memory newRateLimits = new MintLimits.RateLimitMidPointInfo[](1);

        /// wormhole limit
        newRateLimits[0].bufferCap = externalChainBufferCap;
        newRateLimits[0].bridge = address(wormholeBridgeAdapterProxy);
        newRateLimits[0].rateLimitPerSecond = externalChainRateLimitPerSecond;

        /// give wormhole bridge adapter and lock box a rate limit
        //  initializeMamo(address(mamoProxy), mamoName, mamoSymbol, owner, newRateLimits, pauseDuration, pauseGuardian);

        /// initialize wormhole adapter
        uint16[] memory chainIds = new uint16[](1);
        chainIds[0] = BASE_WORMHOLE_CHAIN_ID;

        address[] memory targets = new address[](1);
        targets[0] = address(wormholeBridgeAdapterProxy);

        // initializeWormholeAdapter(
        //     address(wormholeBridgeAdapterProxy), address(mamoProxy), owner, wormholeRelayer, chainIds, targets
        // );
    }
}
