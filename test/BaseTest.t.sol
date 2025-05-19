// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "@forge-std/Test.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {MAMO} from "@contracts/token/MamoXERC20.sol";

import {MintLimits} from "@contracts/token/MintLimits.sol";
import {WormholeBridgeAdapter} from "@contracts/token/WormholeBridgeAdapter.sol";
import {MamoXERC20DeployScript} from "@script/MamoXERC20Deploy.s.sol";

// TODO: move this to ChainIds.sol
uint16 constant BASE_WORMHOLE_CHAIN_ID = 30;

contract BaseTest is MamoXERC20DeployScript, Test {
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
    address public owner;

    /// @notice pause guardian address for the contracts
    address public pauseGuardian;

    /// @notice the duration of the pause for the MAMO token
    /// once the contract has been paused, in this period of time,
    /// it will automatically unpause if no action is taken.
    uint128 public constant pauseDuration = 10 days;

    function setUp() public virtual {
        // Initialize addresses with the folder path and chain IDs
        uint256[] memory chainIdArray = new uint256[](1);
        chainIdArray[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIdArray);

        pauseGuardian = addresses.getAddress("MAMO_PAUSE_GUARDIAN");
        owner = addresses.getAddress("MAMO_MULTISIG");

        {
            MAMO mamoLogicTemp;
            WormholeBridgeAdapter bridgeAdapterLogic;
            address mamoProxyTemp;
            address bridgeAdapterProxyTemp;

            (mamoLogicTemp, bridgeAdapterLogic, proxyAdmin, mamoProxyTemp, bridgeAdapterProxyTemp) =
                deployMamo(addresses);

            mamoLogic = mamoLogicTemp;
            mamoProxy = MAMO(mamoProxyTemp);
            wormholeBridgeAdapterProxy = WormholeBridgeAdapter(bridgeAdapterProxyTemp);

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
        initializeMamo(address(mamoProxy), owner, newRateLimits, pauseDuration, pauseGuardian);

        /// initialize wormhole adapter
        uint16[] memory chainIds = new uint16[](1);
        chainIds[0] = BASE_WORMHOLE_CHAIN_ID;

        address[] memory targets = new address[](1);
        targets[0] = address(wormholeBridgeAdapterProxy);

        address wormholeRelayer = addresses.getAddress("WORMHOLE_BRIDGE_RELAYER_PROXY");

        initializeWormholeAdapter(
            address(wormholeBridgeAdapterProxy), address(mamoProxy), owner, wormholeRelayer, chainIds, targets
        );
    }
}
