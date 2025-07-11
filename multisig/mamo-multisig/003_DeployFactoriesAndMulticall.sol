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
    DeployMulticall public immutable deployMulticall;

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

        deployMulticall = new DeployMulticall();
        vm.makePersistent(address(deployMulticall));
    }

    function _initalizeAddresses() internal {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }

    function run() public override {
        _initalizeAddresses();

        if (DO_DEPLOY) {
            deploy();
            addresses.updateJson();
            addresses.printJSONChanges();
        }

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
        if (DO_UPDATE_ADDRESS_JSON) addresses.updateJson();
    }

    function name() public pure override returns (string memory) {
        return "003_DeployFactoriesAndMulticall";
    }

    function description() public pure override returns (string memory) {
        return "Deploy cbBTC and USDC strategy factories and Multicall contract";
    }

    function deploy() public override {
        address deployer = addresses.getAddress("DEPLOYER_EOA");

        // Deploy cbBTC strategy factory
        DeployAssetConfig.Config memory configBtc = deployAssetConfigBtc.getConfig();
        strategyFactoryDeployer.deployStrategyFactory(addresses, configBtc, deployer);

        // Deploy USDC strategy factory
        DeployAssetConfig.Config memory configUsdc = deployAssetConfigUsdc.getConfig();
        strategyFactoryDeployer.deployStrategyFactory(addresses, configUsdc, deployer);

        // Deploy Multicall
        deployMulticall.deploy(addresses, deployer);
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Get the registry contract
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Get current backend address
        address currentBackend = addresses.getAddress("MAMO_BACKEND");

        // Step 1: Revoke current backend role
        registry.revokeRole(registry.BACKEND_ROLE(), currentBackend);

        // Step 2: Grant BACKEND_ROLE to multicall first
        registry.grantRole(registry.BACKEND_ROLE(), addresses.getAddress("STRATEGY_MULTICALL"));

        address cbBTCFactory = addresses.getAddress("cbBTC_STRATEGY_FACTORY");

        // Step 3: Grant BACKEND_ROLE to cbBTC strategy factory
        registry.grantRole(registry.BACKEND_ROLE(), cbBTCFactory);

        address usdcFactory = addresses.getAddress("USDC_STRATEGY_FACTORY");

        // Step 4: Grant BACKEND_ROLE to USDC strategy factory
        registry.grantRole(registry.BACKEND_ROLE(), usdcFactory);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);
    }

    function validate() public view override {
        // Get the registry contract
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Get addresses
        address currentCompounder = addresses.getAddress("MAMO_COMPOUNDER");

        // Validate that all contracts were deployed
        assertTrue(addresses.isAddressSet("cbBTC_STRATEGY_FACTORY"), "cbBTC Strategy Factory should be deployed");
        assertTrue(addresses.isAddressSet("USDC_STRATEGY_FACTORY"), "USDC Strategy Factory should be deployed");
        assertTrue(addresses.isAddressSet("STRATEGY_MULTICALL"), "Multicall should be deployed");

        // Validate that all contracts have the BACKEND_ROLE
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("STRATEGY_MULTICALL")),
            "Multicall should have BACKEND_ROLE"
        );
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("cbBTC_STRATEGY_FACTORY")),
            "cbBTC Strategy Factory should have BACKEND_ROLE"
        );
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("USDC_STRATEGY_FACTORY")),
            "USDC Strategy Factory should have BACKEND_ROLE"
        );

        // Validate Multicall owner
        Multicall multicall = Multicall(addresses.getAddress("STRATEGY_MULTICALL"));
        assertEq(multicall.owner(), currentCompounder, "Multicall owner should be the compounder");

        // Validate Strategy Factory configurations
        StrategyFactory cbBTCFactory = StrategyFactory(payable(addresses.getAddress("cbBTC_STRATEGY_FACTORY")));
        StrategyFactory usdcFactory = StrategyFactory(payable(addresses.getAddress("USDC_STRATEGY_FACTORY")));

        // Check that both factories are properly configured
        assertEq(cbBTCFactory.mamoStrategyRegistry(), address(registry), "cbBTC Factory should have correct registry");
        assertEq(usdcFactory.mamoStrategyRegistry(), address(registry), "USDC Factory should have correct registry");

        // Validate that factories have the correct backend address
        address expectedBackend = addresses.getAddress("MAMO_BACKEND");
        assertEq(cbBTCFactory.mamoBackend(), expectedBackend, "cbBTC Factory should have correct backend address");
        assertEq(usdcFactory.mamoBackend(), expectedBackend, "USDC Factory should have correct backend address");

        // Validate that addresses were added to the addresses contract
        string memory cbBTCFactoryName = string(abi.encodePacked("cbBTC", "_STRATEGY_FACTORY"));
        string memory usdcFactoryName = string(abi.encodePacked("USDC", "_STRATEGY_FACTORY"));
        string memory multicallName = "STRATEGY_MULTICALL";

        assertTrue(addresses.isAddressSet(cbBTCFactoryName), "cbBTC Factory address should be set");
        assertTrue(addresses.isAddressSet(usdcFactoryName), "USDC Factory address should be set");
        assertTrue(addresses.isAddressSet(multicallName), "Multicall address should be set");

        assertEq(
            addresses.getAddress(cbBTCFactoryName),
            addresses.getAddress("cbBTC_STRATEGY_FACTORY"),
            "cbBTC Factory address should match"
        );
        assertEq(
            addresses.getAddress(usdcFactoryName),
            addresses.getAddress("USDC_STRATEGY_FACTORY"),
            "USDC Factory address should match"
        );
        assertEq(
            addresses.getAddress(multicallName),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "Multicall address should match"
        );

        console.log("All validations passed successfully");
    }
}
