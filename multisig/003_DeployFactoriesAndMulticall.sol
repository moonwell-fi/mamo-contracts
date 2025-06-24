// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";

import {Multicall} from "@contracts/Multicall.sol";
import {StrategyFactory} from "@contracts/StrategyFactory.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";

import {DeployMulticall} from "@script/DeployMulticall.s.sol";
import {StrategyFactoryDeployer} from "@script/StrategyFactoryDeployer.s.sol";
import {console} from "forge-std/console.sol";

contract DeployFactoriesAndMulticall is MultisigProposal {
    DeployAssetConfig public immutable deployAssetConfigBtc;
    DeployAssetConfig public immutable deployAssetConfigUsdc;
    StrategyFactoryDeployer public immutable strategyFactoryDeployer;
    DeployMulticall public immutable deploy;

    address public cbBTCStrategyFactory;
    address public usdcStrategyFactory;
    address public strategyMulticall;

    constructor() {
        // Load asset configurations
        deployAssetConfigBtc = new DeployAssetConfig("./config/strategies/cbBTCStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfigBtc));

        deployAssetConfigUsdc = new DeployAssetConfig("./config/strategies/USDCStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfigUsdc));

        // Initialize deployer contracts
        strategyFactoryDeployer = new StrategyFactoryDeployer();
        vm.makePersistent(address(strategyFactoryDeployer));

        deploy = new DeployMulticall();
        vm.makePersistent(address(deploy));
    }

    function name() public pure override returns (string memory) {
        return "003_DeployFactoriesAndMulticall";
    }

    function description() public pure override returns (string memory) {
        return "Deploy cbBTC and USDC strategy factories and Multicall contract";
    }

    function deploy() public override {
        // Deploy cbBTC strategy factory
        DeployAssetConfig.Config memory configBtc = deployAssetConfigBtc.getConfig();
        cbBTCStrategyFactory = strategyFactoryDeployer.deployStrategyFactory(addresses, configBtc);

        // Deploy USDC strategy factory
        DeployAssetConfig.Config memory configUsdc = deployAssetConfigUsdc.getConfig();
        usdcStrategyFactory = strategyFactoryDeployer.deployStrategyFactory(addresses, configUsdc);

        // Deploy Multicall
        strategyMulticall = deploy.DeployMulticall(addresses);

        console.log("cbBTC Strategy Factory deployed at:", cbBTCStrategyFactory);
        console.log("USDC Strategy Factory deployed at:", usdcStrategyFactory);
        console.log("Multicall deployed at:", strategyMulticall);
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Get the registry contract
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Get current backend address
        address currentBackend = addresses.getAddress("MAMO_BACKEND");

        // Step 1: Revoke current backend role
        registry.revokeRole(registry.BACKEND_ROLE(), currentBackend);

        // Step 2: Grant BACKEND_ROLE to multicall first
        registry.grantRole(registry.BACKEND_ROLE(), strategyMulticall);

        // Step 3: Grant BACKEND_ROLE to cbBTC strategy factory
        registry.grantRole(registry.BACKEND_ROLE(), cbBTCStrategyFactory);

        // Step 4: Grant BACKEND_ROLE to USDC strategy factory
        registry.grantRole(registry.BACKEND_ROLE(), usdcStrategyFactory);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);
    }

    function validate() public view override {
        // Get the registry contract
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Get addresses
        address currentBackend = addresses.getAddress("MAMO_BACKEND");

        // Validate that all contracts were deployed
        assertTrue(cbBTCStrategyFactory != address(0), "cbBTC Strategy Factory should be deployed");
        assertTrue(usdcStrategyFactory != address(0), "USDC Strategy Factory should be deployed");
        assertTrue(strategyMulticall != address(0), "Multicall should be deployed");

        // Validate that all contracts have the BACKEND_ROLE
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), strategyMulticall), "Multicall should have BACKEND_ROLE");
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), cbBTCStrategyFactory),
            "cbBTC Strategy Factory should have BACKEND_ROLE"
        );
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), usdcStrategyFactory),
            "USDC Strategy Factory should have BACKEND_ROLE"
        );

        // Validate Multicall owner
        Multicall multicall = Multicall(strategyMulticall);
        assertEq(multicall.owner(), currentBackend, "Multicall owner should be the backend");

        // Validate Strategy Factory configurations
        StrategyFactory cbBTCFactory = StrategyFactory(payable(cbBTCStrategyFactory));
        StrategyFactory usdcFactory = StrategyFactory(payable(usdcStrategyFactory));

        // Check that both factories are properly configured
        assertEq(cbBTCFactory.mamoStrategyRegistry(), address(registry), "cbBTC Factory should have correct registry");
        assertEq(usdcFactory.mamoStrategyRegistry(), address(registry), "USDC Factory should have correct registry");

        // Validate that addresses were added to the addresses contract
        string memory cbBTCFactoryName = string(abi.encodePacked("cbBTC", "_STRATEGY_FACTORY"));
        string memory usdcFactoryName = string(abi.encodePacked("USDC", "_STRATEGY_FACTORY"));
        string memory multicallName = "STRATEGY_MULTICALL";

        assertTrue(addresses.isAddressSet(cbBTCFactoryName), "cbBTC Factory address should be set");
        assertTrue(addresses.isAddressSet(usdcFactoryName), "USDC Factory address should be set");
        assertTrue(addresses.isAddressSet(multicallName), "Multicall address should be set");

        assertEq(addresses.getAddress(cbBTCFactoryName), cbBTCStrategyFactory, "cbBTC Factory address should match");
        assertEq(addresses.getAddress(usdcFactoryName), usdcStrategyFactory, "USDC Factory address should match");
        assertEq(addresses.getAddress(multicallName), strategyMulticall, "Multicall address should match");

        console.log("All validations passed successfully");
    }
}
