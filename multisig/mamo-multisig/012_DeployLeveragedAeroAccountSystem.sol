// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoLeveragedAeroStrategyFactory} from "@contracts/MamoLeveragedAeroStrategyFactory.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {DeployLeveragedAeroAccountConfig} from "@script/DeployLeveragedAeroAccountConfig.sol";
import {LeveragedAeroAccountDeployer} from "@script/LeveragedAeroAccountDeployer.s.sol";

/**
 * @title DeployLeveragedAeroAccountSystem
 * @notice Multisig proposal that deploys the MamoLeveragedAeroStrategy account system and wires it into
 *         the existing MamoStrategyRegistry:
 *           - deploys the {MamoLeveragedAeroStrategy} implementation + {MamoLeveragedAeroStrategyFactory};
 *           - whitelists the implementation under a NEW strategy type id (see config);
 *           - grants the factory BACKEND_ROLE on the registry so it can register user accounts;
 *           - opens deposits on the {LeveragedAeroVault} so the accounts can deposit USDC.
 *
 * @dev This account has NO Moonwell/Morpho split and NO CowSwap reward path, so there is deliberately
 *      no SlippagePriceChecker / reward-token configuration here (unlike 010/011).
 *
 *      NOT-YET-DEPLOYED DEPENDENCIES: the {LeveragedAeroVault} and its vendored
 *      {LeveragedAerodromeCLStrategy} clone are deployed separately — Tenderly vnet Base fork first,
 *      Base mainnet after. Until then the address book has no `SHERWOOD_LEVERAGED_AERO_STRATEGY` /
 *      `LEVERAGED_AERO_VAULT` entries, so this proposal COMPILES but cannot be run end-to-end: either
 *      `addresses.getAddress(...)` lookup reverts until those keys are added at that deploy time. The vault
 *      referenced by `LEVERAGED_AERO_VAULT` MUST be owned by MAMO_MULTISIG at execution time for the
 *      `setOpenDeposits(true)` call in {build} to succeed (the vault is {Ownable2Step}, so the multisig
 *      must have ACCEPTED ownership, not merely been nominated).
 */
contract DeployLeveragedAeroAccountSystem is MultisigProposal {
    uint256 public immutable strategyTypeId;
    DeployLeveragedAeroAccountConfig public immutable deployConfig;
    LeveragedAeroAccountDeployer public immutable accountDeployer;

    string public strategyImplementationKey;
    string public strategyFactoryKey;
    string public sherwoodStrategyKey;
    string public vaultKey;

    constructor() {
        deployConfig = new DeployLeveragedAeroAccountConfig("./config/strategies/LeveragedAeroAccountConfig.json");
        vm.makePersistent(address(deployConfig));

        accountDeployer = new LeveragedAeroAccountDeployer();
        vm.makePersistent(address(accountDeployer));

        DeployLeveragedAeroAccountConfig.Config memory cfg = deployConfig.getConfig();
        strategyTypeId = cfg.strategyTypeId;
        strategyImplementationKey = cfg.strategyImplementation;
        strategyFactoryKey = cfg.strategyFactory;
        sherwoodStrategyKey = cfg.sherwoodStrategy;
        vaultKey = cfg.vault;
    }

    function run() public override {
        _initializeAddresses();

        if (DO_DEPLOY) {
            deploy();
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
        return "012_DeployLeveragedAeroAccountSystem";
    }

    function description() public pure override returns (string memory) {
        return "Deploy MamoLeveragedAeroStrategy implementation + factory, whitelist the new strategy type, grant the factory BACKEND_ROLE, and open LeveragedAeroVault deposits";
    }

    function deploy() public override {
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        accountDeployer.deployImplementationAndFactory(addresses, deployConfig.getConfig(), deployer);
    }

    function preBuildMock() public view override {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Availability check (source of truth): the configured type id MUST be an empty slot.
        // This is the definitive guard against clobbering an existing strategy type.
        assertEq(
            registry.latestImplementationById(strategyTypeId),
            address(0),
            "Configured strategy type id already has an implementation"
        );

        // PR #49 (010) pattern verifies `nextStrategyTypeId() == id`. That counter is only advanced when
        // an implementation is whitelisted with id 0 (auto-assign); whitelisting with an explicit non-zero
        // id (as 010/011 and this proposal do) leaves it untouched. On Base mainnet it currently reads 4
        // while ids 1-4 are all filled, i.e. it is a stale lower bound, NOT the next free slot. We assert
        // the counter has not advanced PAST our chosen slot so the registry's auto-assign path can never
        // hand out our explicitly-claimed id to another type before this proposal executes.
        assertLe(registry.nextStrategyTypeId(), strategyTypeId, "nextStrategyTypeId advanced past the configured id");
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        address implementation = addresses.getAddress(strategyImplementationKey);
        address factory = addresses.getAddress(strategyFactoryKey);

        // 1. Whitelist the new implementation under the configured (explicit) strategy type id.
        registry.whitelistImplementation(implementation, strategyTypeId);

        // 2. Grant the factory BACKEND_ROLE so it can register user accounts with the registry.
        registry.grantRole(registry.BACKEND_ROLE(), factory);

        // 3. Open deposits on the LeveragedAeroVault so the accounts can deposit USDC.
        //    The vault must be owned by MAMO_MULTISIG at execution time (see contract-level NatSpec).
        LeveragedAeroVault(addresses.getAddress(vaultKey)).setOpenDeposits(true);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);
    }

    function validate() public view override {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        address implementation = addresses.getAddress(strategyImplementationKey);

        // Implementation is whitelisted and mapped to the configured type id (both directions).
        assertTrue(registry.whitelistedImplementations(implementation), "Implementation should be whitelisted");
        assertEq(
            registry.implementationToId(implementation), strategyTypeId, "Implementation should map to the type id"
        );
        assertEq(
            registry.latestImplementationById(strategyTypeId),
            implementation,
            "Latest implementation for the type should be the new implementation"
        );

        // Factory has BACKEND_ROLE on the registry.
        address factory = addresses.getAddress(strategyFactoryKey);
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), factory), "Factory should have BACKEND_ROLE on the registry"
        );

        // LeveragedAeroVault deposits are open.
        assertTrue(
            LeveragedAeroVault(addresses.getAddress(vaultKey)).depositsOpen(),
            "LeveragedAeroVault deposits should be open"
        );

        // Every factory immutable matches config / address book.
        _validateFactoryConfig();
    }

    function _validateFactoryConfig() internal view {
        MamoLeveragedAeroStrategyFactory factory =
            MamoLeveragedAeroStrategyFactory(addresses.getAddress(strategyFactoryKey));
        DeployLeveragedAeroAccountConfig.Config memory cfg = deployConfig.getConfig();

        assertEq(
            factory.mamoStrategyRegistry(),
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            "Factory mamoStrategyRegistry mismatch"
        );
        assertEq(
            factory.strategyImplementation(),
            addresses.getAddress(strategyImplementationKey),
            "Factory strategyImplementation mismatch"
        );
        assertEq(factory.strategyTypeId(), strategyTypeId, "Factory strategyTypeId mismatch");
        assertEq(
            factory.sherwoodStrategy(), addresses.getAddress(cfg.sherwoodStrategy), "Factory sherwoodStrategy mismatch"
        );
        assertEq(factory.usdc(), addresses.getAddress(cfg.token), "Factory usdc mismatch");

        // Roles wired at construction: admin = MAMO_MULTISIG, backend = MAMO_BACKEND.
        assertTrue(
            factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), addresses.getAddress("MAMO_MULTISIG")),
            "Factory admin should be MAMO_MULTISIG"
        );
        assertTrue(
            factory.hasRole(factory.BACKEND_ROLE(), addresses.getAddress("MAMO_BACKEND")),
            "Factory backend should be MAMO_BACKEND"
        );
    }

    function _initializeAddresses() internal {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }
}
