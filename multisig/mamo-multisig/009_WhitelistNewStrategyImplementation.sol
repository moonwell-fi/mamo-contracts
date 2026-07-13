// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoMultiMarketStrategy} from "@contracts/MamoMultiMarketStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {StrategyFactoryDeployer} from "@script/StrategyFactoryDeployer.s.sol";

/**
 * @title WhitelistNewStrategyImplementation
 * @notice Multisig proposal to whitelist a new strategy implementation for USDC and cbBTC accounts.
 *         The new implementation includes a claimRewards function compatible with the Merkle protocol.
 * @dev This script will deploy a new MamoMultiMarketStrategy implementation and whitelist it
 *      for strategy type ID 1, which is used for both USDC and cbBTC strategies.
 */
contract WhitelistNewStrategyImplementation is MultisigProposal {
    uint256 public constant STRATEGY_TYPE_ID = 1; // Token type 1 for USDC/cbBTC strategies
    DeployAssetConfig public immutable deployAssetConfigBtc;
    DeployAssetConfig public immutable deployAssetConfigUsdc;
    StrategyFactoryDeployer public immutable strategyFactoryDeployer;

    constructor() {
        // Load asset configurations
        deployAssetConfigBtc = new DeployAssetConfig("./config/strategies/cbBTCStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfigBtc));

        deployAssetConfigUsdc = new DeployAssetConfig("./config/strategies/USDCStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfigUsdc));

        // Initialize deployer contracts
        strategyFactoryDeployer = new StrategyFactoryDeployer();
        vm.makePersistent(address(strategyFactoryDeployer));
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
        return "009_WhitelistNewStrategyImplementation";
    }

    function description() public pure override returns (string memory) {
        return "Deploy and whitelist new MamoMultiMarketStrategy implementation for token type 1";
    }

    function deploy() public override {
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        vm.startBroadcast(deployer);

        // Deploy new strategy implementation
        address newImplementation = address(new MamoMultiMarketStrategy());
        vm.stopBroadcast();

        if (addresses.isAddressSet("MOONWELL_MORPHO_STRATEGY_IMPL")) {
            address oldAddress = addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL");
            addresses.changeAddress("MOONWELL_MORPHO_STRATEGY_IMPL", newImplementation, true);
        }

        // Deploy cbBTC strategy factory
        DeployAssetConfig.Config memory configBtc = deployAssetConfigBtc.getConfig();
        strategyFactoryDeployer.deployStrategyFactory(addresses, configBtc, deployer);

        // Deploy USDC strategy factory
        DeployAssetConfig.Config memory configUsdc = deployAssetConfigUsdc.getConfig();
        strategyFactoryDeployer.deployStrategyFactory(addresses, configUsdc, deployer);
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Get the strategy registry
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Get the new implementation address
        address newImplementation = addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL");

        // Whitelist the new implementation for strategy type ID 1
        // This will update latestImplementationById[1] to point to the new implementation
        registry.whitelistImplementation(newImplementation, STRATEGY_TYPE_ID);

        // give the backend role to the new factories
        registry.grantRole(registry.BACKEND_ROLE(), addresses.getAddress("cbBTC_STRATEGY_FACTORY"));
        registry.grantRole(registry.BACKEND_ROLE(), addresses.getAddress("USDC_STRATEGY_FACTORY"));

        // remove the backend role from the old factories
        registry.revokeRole(registry.BACKEND_ROLE(), addresses.getAddress("cbBTC_STRATEGY_FACTORY_DEPRECATED"));
        registry.revokeRole(registry.BACKEND_ROLE(), addresses.getAddress("USDC_STRATEGY_FACTORY_DEPRECATED"));
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");

        _simulateActions(multisig);
    }

    function validate() public view override {
        // Get addresses
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        address newImplementation = addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL");

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
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("cbBTC_STRATEGY_FACTORY")));
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("USDC_STRATEGY_FACTORY")));

        // Validate that the old factories no longer have the backend role
        assertFalse(
            registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("cbBTC_STRATEGY_FACTORY_DEPRECATED"))
        );
        assertFalse(registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("USDC_STRATEGY_FACTORY_DEPRECATED")));
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
