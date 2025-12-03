// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {StrategyFactoryDeployer} from "@script/StrategyFactoryDeployer.s.sol";

/**
 * @title WhitelistWETHStrategyImplementation
 * @notice Multisig proposal to whitelist a new strategy implementation for WETH accounts.
 *         The new implementation includes receive() function that wraps any received ETH to WETH
 * @dev This script will deploy a new ERC20MoonwellMorphoStrategy implementation and whitelist it
 *      for strategy type ID 1, which is used for USDC, cbBTC, and WETH strategies.
 */
contract WhitelistWETHStrategyImplementation is MultisigProposal {
    uint256 public constant STRATEGY_TYPE_ID = 1; // Token type 1 for USDC/cbBTC strategies
    DeployAssetConfig public immutable deployAssetConfigWeth;
    StrategyFactoryDeployer public immutable strategyFactoryDeployer;
    string public strategyImplementation;

    constructor() {
        // Load asset configurations for WETH strategy
        deployAssetConfigWeth = new DeployAssetConfig("./config/strategies/WETHStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfigWeth));

        // Initialize deployer contracts
        strategyFactoryDeployer = new StrategyFactoryDeployer();
        vm.makePersistent(address(strategyFactoryDeployer));

        strategyImplementation = deployAssetConfigWeth.getConfig().strategyImplementation;
    }

    function run() public override {
        _initalizeAddresses();

        if (DO_DEPLOY) {
            deploy();
            //addresses.updateJson();
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
        return "010_WhitelistETHAccountImplementation";
    }

    function description() public pure override returns (string memory) {
        return "Deploy and whitelist new ERC20MoonwellMorphoStrategy implementation for token type 1, with support for WETH";
    }

    function deploy() public override {
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        vm.startBroadcast(deployer);

        // Deploy new strategy implementation
        address newImplementation = address(new ERC20MoonwellMorphoStrategy());
        vm.stopBroadcast();

        if (addresses.isAddressSet(strategyImplementation)) {
            address oldAddress = addresses.getAddress(strategyImplementation);
            string memory oldImplementation = string(abi.encodePacked(strategyImplementation, "_DEPRECATED"));

            // Keep the latest deprecated implementation
            if (addresses.isAddressSet(oldImplementation)) {
                addresses.changeAddress(oldImplementation, oldAddress, true);
            } else {
                addresses.addAddress(oldImplementation, oldAddress, true);
            }

            addresses.changeAddress(strategyImplementation, newImplementation, true);
        } else {
            addresses.addAddress(strategyImplementation, newImplementation, true);
        }

        // Deploy WETH strategy factory
        strategyFactoryDeployer.deployStrategyFactory(addresses, deployAssetConfigWeth.getConfig(), deployer);
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Get the strategy registry
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Get the new implementation address
        address newImplementation = addresses.getAddress(strategyImplementation);

        // Whitelist the new implementation for strategy type ID 1
        // This will update latestImplementationById[1] to point to the new implementation
        registry.whitelistImplementation(newImplementation, STRATEGY_TYPE_ID);

        // give the backend role to the new factories
        registry.grantRole(registry.BACKEND_ROLE(), addresses.getAddress("WETH_STRATEGY_FACTORY"));
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");

        _simulateActions(multisig);
    }

    function validate() public view override {
        // Get addresses
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        address newImplementation = addresses.getAddress(strategyImplementation);

        // Validate that the new implementation is whitelisted
        assertTrue(registry.whitelistedImplementations(newImplementation), "New implementation should be whitelisted");

        // Validate that the new implementation is registered for strategy type 1
        assertEq(
            registry.implementationToId(newImplementation),
            STRATEGY_TYPE_ID,
            "Implementation should have correct strategy type ID"
        );

        // Validate that strategy type 1 now points to the new implementation
        assertEq(
            registry.latestImplementationById(STRATEGY_TYPE_ID),
            newImplementation,
            "Latest implementation for type 1 should be updated"
        );

        // Validate that the new factories have the backend role
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("WETH_STRATEGY_FACTORY")));
    }

    function _initalizeAddresses() internal {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }
}
