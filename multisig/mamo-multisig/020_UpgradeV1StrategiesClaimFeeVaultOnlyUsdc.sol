// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/v1/ERC20MoonwellMorphoStrategy.sol";
import {StrategyFactory} from "@contracts/v1/StrategyFactory.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {StrategyFactoryDeployer} from "@script/v1/StrategyFactoryDeployer.s.sol";

/**
 * @title UpgradeV1Strategies
 * @notice Whitelists a new v1 implementation for type ids 1 and 4 and moves BACKEND_ROLE to three new factories.
 * @dev New contracts take the plain address-book keys; at deployment the retired ones are renamed by hand to
 *      {USDC,cbBTC}_STRATEGY_FACTORY_DEPRECATED_2, WETH_STRATEGY_FACTORY_DEPRECATED, MOONWELL_MORPHO_STRATEGY_IMPL{_DEPRECATED_2,_V2_DEPRECATED}.
 */
contract UpgradeV1Strategies is MultisigProposal {
    address internal constant OLD_IMPL = 0x4007EFfCE837701Fdd90017Ab747fefD58aAD98B;
    address internal constant OLD_IMPL_V2 = 0x6C8577fa9B10807f7485f6476C2AFE0B8d61D1e7;

    string[3] internal assets = ["USDC", "cbBTC", "WETH"];
    address[3] internal oldFactories = [
        0x3098360e627E84Fb9dD621F01ea03E325cCEE2c6,
        0xf8CFdEf5068929e022a50315983043b61E9987f8,
        0x14bA47Ef0286B345E2B74d26243767268290eE28
    ];

    function run() public override {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(vm.envOr("ADDRESSES_PATH", string("./addresses")), chainIds);
        vm.makePersistent(address(addresses));

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
        return "020_UpgradeV1Strategies";
    }

    function description() public pure override returns (string memory) {
        return "Whitelist a new v1 ERC20MoonwellMorphoStrategy for type ids 1 and 4 and move BACKEND_ROLE from the USDC, cbBTC and WETH factories to new ones, the USDC factory defaulting to the vault only";
    }

    function deploy() public override {
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        // Same bytecode twice: implementationToId maps each address to a single type id
        string[2] memory implKeys = ["MOONWELL_MORPHO_STRATEGY_IMPL", "MOONWELL_MORPHO_STRATEGY_IMPL_V2"];
        address[2] memory oldImpls = [OLD_IMPL, OLD_IMPL_V2];
        for (uint256 i; i < 2; i++) {
            if (_deployed(implKeys[i], oldImpls[i])) continue;
            vm.startBroadcast(deployer);
            address impl = address(new ERC20MoonwellMorphoStrategy());
            vm.stopBroadcast();
            addresses.changeAddress(implKeys[i], impl, true);
        }

        // Each factory pins the impl its config names and takes the key <token>_STRATEGY_FACTORY
        StrategyFactoryDeployer factoryDeployer = new StrategyFactoryDeployer();
        for (uint256 i; i < 3; i++) {
            if (_deployed(string.concat(assets[i], "_STRATEGY_FACTORY"), oldFactories[i])) continue;
            string memory path = string.concat("./config/strategies/", assets[i], "StrategyConfig.json");
            factoryDeployer.deployStrategyFactory(addresses, new DeployAssetConfig(path).getConfig(), deployer);
        }
    }

    function preBuildMock() public view override {
        MamoStrategyRegistry registry = _registry();
        assertEq(registry.latestImplementationById(1), OLD_IMPL, "type 1 should run the old implementation");
        assertEq(registry.latestImplementationById(4), OLD_IMPL_V2, "type 4 should run the old implementation");
        assertEq(
            registry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 should be the strategy multicall before this proposal"
        );
        assertFalse(registry.paused(), "registry should not be paused");
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        MamoStrategyRegistry registry = _registry();
        // Explicit ids: nextStrategyTypeId is a stale lower bound, never pass 0
        registry.whitelistImplementation(addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL"), 1);
        registry.whitelistImplementation(addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL_V2"), 4);

        bytes32 role = registry.BACKEND_ROLE();
        for (uint256 i; i < 3; i++) {
            registry.grantRole(role, _factory(i));
        }
        for (uint256 i; i < 3; i++) {
            registry.revokeRole(role, oldFactories[i]);
        }
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("MAMO_MULTISIG"));
    }

    function validate() public override {
        MamoStrategyRegistry registry = _registry();
        address[2] memory impls = [
            addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL"),
            addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL_V2")
        ];
        address[2] memory oldImpls = [OLD_IMPL, OLD_IMPL_V2];
        uint256[2] memory ids = [uint256(1), 4];
        ERC20MoonwellMorphoStrategy.InitParams memory params;
        for (uint256 i; i < 2; i++) {
            assertTrue(registry.whitelistedImplementations(impls[i]), "new implementation should be whitelisted");
            assertEq(registry.implementationToId(impls[i]), ids[i], "new implementation has the wrong type id");
            assertEq(registry.latestImplementationById(ids[i]), impls[i], "latest implementation should be the new one");
            // Un-upgraded proxies keep a valid upgrade path
            assertTrue(registry.whitelistedImplementations(oldImpls[i]), "old implementation should stay whitelisted");
            assertEq(registry.implementationToId(oldImpls[i]), ids[i], "old implementation has the wrong type id");
            try ERC20MoonwellMorphoStrategy(payable(impls[i])).initialize(params) {
                revert("bare implementation should refuse initialize");
            } catch (bytes memory reason) {
                assertEq(reason, abi.encodeWithSignature("InvalidInitialization()"), "initialize revert");
            }
        }
        assertEq(_codeWithoutSelf(impls[0]), _codeWithoutSelf(impls[1]), "implementations should share bytecode");
        (, bytes32 appDataHash) = ERC20MoonwellMorphoStrategy(payable(impls[0])).expectedAppData();
        assertEq(appDataHash, keccak256(bytes('{"appCode":"Mamo","metadata":{},"version":"1.3.0"}')), "appData");

        bytes32 role = registry.BACKEND_ROLE();
        for (uint256 i; i < 3; i++) {
            StrategyFactory factory = StrategyFactory(_factory(i));
            StrategyFactory old = StrategyFactory(oldFactories[i]);
            uint256 splitVault = i == 0 ? 10_000 : 0; // USDC vault only, cbBTC and WETH Moonwell only

            assertTrue(registry.hasRole(role, address(factory)), "new factory should hold BACKEND_ROLE");
            assertFalse(registry.hasRole(role, address(old)), "old factory should not hold BACKEND_ROLE");
            assertEq(factory.strategyImplementation(), impls[i == 2 ? 1 : 0], "factory pins the wrong implementation");
            assertEq(factory.strategyTypeId(), old.strategyTypeId(), "strategyTypeId");
            assertEq(factory.token(), old.token(), "token");
            assertEq(factory.mToken(), old.mToken(), "mToken");
            assertEq(factory.metaMorphoVault(), old.metaMorphoVault(), "metaMorphoVault");
            assertEq(factory.slippagePriceChecker(), old.slippagePriceChecker(), "slippagePriceChecker");
            assertEq(factory.hookGasLimit(), old.hookGasLimit(), "hookGasLimit");
            assertEq(factory.allowedSlippageInBps(), old.allowedSlippageInBps(), "allowedSlippageInBps");
            assertEq(factory.splitMToken(), 10_000 - splitVault, "splitMToken");
            assertEq(factory.splitVault(), splitVault, "splitVault");
            assertEq(factory.feeRecipient(), addresses.getAddress("MAMO_MULTISIG"), "feeRecipient");
            assertEq(factory.compoundFee(), 500, "compoundFee");
            assertEq(factory.mamoBackend(), addresses.getAddress("MAMO_BACKEND"), "mamoBackend");
        }

        // Un-upgraded proxies gate on index 0; the new implementation gates on BACKEND_ROLE membership
        assertEq(
            registry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 must not move"
        );

        // The revoke trips before the implementation check ("Not latest implementation")
        address user = makeAddr("user");
        vm.prank(user);
        try StrategyFactory(oldFactories[0]).createStrategyForUser(user) {
            revert("old USDC factory should not create");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, oldFactories[0], role)
            );
        }
    }

    // A rerun skips what the book already names as a new, deployed contract
    function _deployed(string memory key, address retired) internal view returns (bool) {
        address a = addresses.getAddress(key);
        return a != retired && a.code.length > 0;
    }

    // UUPS embeds address(this) as an immutable, so blank it out before comparing
    function _codeWithoutSelf(address a) internal view returns (string memory) {
        return vm.replace(vm.toString(a.code), vm.replace(vm.toLowercase(vm.toString(a)), "0x", ""), "");
    }

    function _registry() internal view returns (MamoStrategyRegistry) {
        return MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
    }

    function _factory(uint256 i) internal view returns (address) {
        return addresses.getAddress(string.concat(assets[i], "_STRATEGY_FACTORY"));
    }
}
