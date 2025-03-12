// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20MoonwellMorphoStrategy} from "../src/ERC20MoonwellMorphoStrategy.sol";
import {Addresses} from "../addresses/Addresses.sol";
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
        deployUSDCStrategy();
    }

    function deployUSDCStrategy() public {
        // Get the private key for deployment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy the implementation contract
        ERC20MoonwellMorphoStrategy implementation = new ERC20MoonwellMorphoStrategy();
        
        // Get the addresses for the initialization parameters
        address owner = addresses.getAddress("OWNER");
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address mamoBackend = addresses.getAddress("BACKEND");
        address moonwellComptroller = addresses.getAddress("MOONWELL_COMPTROLLER");
        address mUSDC = addresses.getAddress("MUSDC");
        address metaMorphoVault = addresses.getAddress("META_MORPHO_VAULT");
        address dexRouter = addresses.getAddress("DEX_ROUTER");
        address usdc = addresses.getAddress("USDC");
        
        // Define the split parameters (50/50 by default)
        uint256 splitMToken = 5000; // 50% in basis points
        uint256 splitVault = 5000; // 50% in basis points
        
        // Encode the initialization data
        bytes memory initData = abi.encodeWithSelector(
            ERC20MoonwellMorphoStrategy.initialize.selector,
            ERC20MoonwellMorphoStrategy.InitParams({
                owner: owner,
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
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        
        // Stop broadcasting transactions
        vm.stopBroadcast();
        
        // Log the deployed contract addresses
        console.log("ERC20MoonwellMorphoStrategy implementation deployed at:", address(implementation));
        console.log("USDC Strategy proxy deployed at:", address(proxy));
        
        // Add the implementation to the whitelist in the registry (this would be done separately)
        console.log("Don't forget to whitelist the implementation in the MamoStrategyRegistry!");
    }
}
