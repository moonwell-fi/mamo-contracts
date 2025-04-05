// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";

contract USDCStrategyImplDeployer is Script {
    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the strategy implementation and proxy
        deployUSDCStrategy(addresses);
    }

    function deployUSDCStrategy(Addresses addresses) public returns (address strategyProxy) {
        vm.startBroadcast();
        // Get the addresses for the initialization parameters
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address mamoBackend = addresses.getAddress("TESTING_EOA");
        address mUSDC = addresses.getAddress("MOONWELL_USDC");
        address metaMorphoVault = addresses.getAddress("USDC_METAMORPHO_VAULT");
        address usdc = addresses.getAddress("USDC");
        address SlippagePriceChecker = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");

        // Define the split parameters (50/50 by default)
        uint256 splitMToken = 5000; // 50% in basis points
        uint256 splitVault = 5000; // 50% in basis points

        // Encode the initialization data
        bytes memory initData = abi.encodeWithSelector(
            ERC20MoonwellMorphoStrategy.initialize.selector,
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: mamoStrategyRegistry,
                mamoBackend: mamoBackend,
                mToken: mUSDC,
                metaMorphoVault: metaMorphoVault,
                token: usdc,
                slippagePriceChecker: SlippagePriceChecker,
                splitMToken: splitMToken,
                splitVault: splitVault,
                strategyTypeId: 1
            })
        );

        // Deploy the proxy with the implementation and initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(addresses.getAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL"), initData);

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Check if the proxy address already exists
        string memory proxyName = "USER_USDC_STRATEGY_PROXY";
        if (addresses.isAddressSet(proxyName)) {
            // Update the existing address
            addresses.changeAddress(proxyName, address(proxy), true);
        } else {
            // Add the proxy address to the addresses contract
            addresses.addAddress(proxyName, address(proxy), true);
        }

        return address(proxy);
    }
}
