// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoLeveragedAeroStrategyFactory} from "@contracts/MamoLeveragedAeroStrategyFactory.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {ISyndicateVault} from "@contracts/leveraged-aero/sherwood/interfaces/ISyndicateVault.sol";
import {DeployLeveragedAeroAccountConfig} from "@script/DeployLeveragedAeroAccountConfig.sol";
import {LeveragedAeroAccountDeployer} from "@script/LeveragedAeroAccountDeployer.s.sol";

/**
 * @title DeployLeveragedAeroAccountSystem
 * @notice Multisig proposal that deploys the MamoLeveragedAeroStrategy account system and wires it into
 *         the existing MamoStrategyRegistry:
 *           - deploys the {MamoLeveragedAeroStrategy} implementation + {MamoLeveragedAeroStrategyFactory};
 *           - whitelists the implementation under a NEW strategy type id (see config);
 *           - grants the factory BACKEND_ROLE on the registry so it can register user accounts;
 *           - opens deposits on the SyndicateVault so the accounts can deposit USDC.
 *
 * @dev This account has NO Moonwell/Morpho split and NO CowSwap reward path, so there is deliberately
 *      no SlippagePriceChecker / reward-token configuration here (unlike 010/011).
 *
 *      NOT-YET-DEPLOYED DEPENDENCIES: the Sherwood system (SyndicateVault + LeveragedAerodromeCLStrategy)
 *      is deployed separately — Tenderly vnet Base fork first, Base mainnet after. Until then the address
 *      book has no `SHERWOOD_LEVERAGED_AERO_STRATEGY` / `SHERWOOD_SYNDICATE_VAULT` entries, so this
 *      proposal COMPILES but cannot be run end-to-end: any `addresses.getAddress("SHERWOOD_...")` reverts
 *      until those two keys are added at Sherwood-deploy time. The vault referenced by
 *      `SHERWOOD_SYNDICATE_VAULT` MUST be owned by MAMO_MULTISIG at execution time for the
 *      `setOpenDeposits(true)` call in {build} to succeed.
 */
contract DeployLeveragedAeroAccountSystem is MultisigProposal {
    uint256 public immutable strategyTypeId;
    DeployLeveragedAeroAccountConfig public immutable deployConfig;
    LeveragedAeroAccountDeployer public immutable accountDeployer;

    string public strategyImplementationKey;
    string public strategyFactoryKey;
    string public sherwoodStrategyKey;
    string public syndicateVaultKey;

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
        syndicateVaultKey = cfg.syndicateVault;
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
        return "Deploy MamoLeveragedAeroStrategy implementation + factory, whitelist the new strategy type, grant the factory BACKEND_ROLE, and open SyndicateVault deposits";
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
        // the counter has not advanced TO OR PAST our chosen slot so the registry's auto-assign path can
        // never hand out our explicitly-claimed id to another type before this proposal executes.
        //
        // Strictly less-than, not `<=`: equality is precisely the collision case. If the counter already
        // reads our id, the very next auto-assigning whitelistImplementation(impl, 0) hands out that id
        // and overwrites latestImplementationById for it, stranding this type permanently. The empty-slot
        // assertion above is the real guard (an explicit id never advances the counter, so for any id >= 5
        // this check can only ever pass); this one exists to catch the one state it cannot.
        assertLt(registry.nextStrategyTypeId(), strategyTypeId, "nextStrategyTypeId reached the configured id");
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        address implementation = addresses.getAddress(strategyImplementationKey);
        address factory = addresses.getAddress(strategyFactoryKey);

        // 1. Whitelist the new implementation under the configured (explicit) strategy type id.
        registry.whitelistImplementation(implementation, strategyTypeId);

        // 2. Grant the factory BACKEND_ROLE so it can register user accounts with the registry.
        //    ORDERING DEPENDENCY: this grants the FACTORY only. `MamoLeveragedAeroStrategy.depositIdle`
        //    now gates on the registry's BACKEND_ROLE (Sherlock #41), and the OPERATOR's grant
        //    (`MAMO_BACKEND`) lives in 011, not here. If 012 ships without 011 having executed,
        //    depositIdle is operator-inaccessible — the account owner can still call it, so this is a
        //    liveness gap and not a lockout, but 011 must land first.
        registry.grantRole(registry.BACKEND_ROLE(), factory);

        // 3. Open deposits on the SyndicateVault so the accounts can deposit USDC.
        //    The vault must be owned by MAMO_MULTISIG at execution time (see contract-level NatSpec).
        ISyndicateVault(addresses.getAddress(syndicateVaultKey)).setOpenDeposits(true);
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

        // SyndicateVault deposits are open.
        assertTrue(
            ISyndicateVault(addresses.getAddress(syndicateVaultKey)).openDeposits(),
            "SyndicateVault deposits should be open"
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
