// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract USDCStrategyDeployer is Script {
    Addresses public addresses;

    function run() external {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the strategy implementation and proxy
        deployImplementation();
    }

    function deployImplementation() public returns (address) {
        vm.startBroadcast();
        // Deploy the implementation contract
        ERC20MoonwellMorphoStrategy implementation = new ERC20MoonwellMorphoStrategy();

        vm.stopBroadcast();

        // Add implementation address to addresses
        addresses.addAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL", address(implementation), true);

        // Log the deployed contract address
        console.log("ERC20MoonwellMorphoStrategy implementation deployed at:", address(implementation));

        return address(implementation);
    }

    function deployUSDCStrategy() public returns (address strategyProxy) {
        vm.startBroadcast();
        // Get the addresses for the initialization parameters
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address mamoBackend = addresses.getAddress("BACKEND");
        address moonwellComptroller = addresses.getAddress("MOONWELL_COMPTROLLER");
        address mUSDC = addresses.getAddress("MOONWELL_USDC");
        address metaMorphoVault = addresses.getAddress("USDC_METAMORPHO_VAULT");
        address dexRouter = addresses.getAddress("DEX_ROUTER");
        address usdc = addresses.getAddress("USDC");

        // Define the split parameters (50/50 by default)
        uint256 splitMToken = 5000; // 50% in basis points
        uint256 splitVault = 5000; // 50% in basis points

        // Encode the initialization data
        bytes memory initData = abi.encodeWithSelector(
            ERC20MoonwellMorphoStrategy.initialize.selector,
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: mamoStrategyRegistry,
                mamoBackend: mamoBackend,
                moonwellComptroller: moonwellComptroller,
                mToken: mUSDC,
                metaMorphoVault: metaMorphoVault,
                dexRouter: dexRouter,
                token: usdc,
                splitMToken: splitMToken,
                splitVault: splitVault
            })
        );

        // Deploy the proxy with the implementation and initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(addresses.getAddress("USDC_MOONWELL_MORPHO_STRATEGY_IMPL"), initData);

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Log the deployed proxy address
        console.log("USDC Strategy proxy deployed at:", address(proxy));

        return address(proxy);
    }
}
