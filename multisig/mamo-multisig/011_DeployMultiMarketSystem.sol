// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoMultiMarketStrategy} from "@contracts/MamoMultiMarketStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {MarketRegistry} from "@contracts/MarketRegistry.sol";
import {MultiMarketStrategyFactory} from "@contracts/MultiMarketStrategyFactory.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {IMarketRegistry, MarketType} from "@interfaces/IMarketRegistry.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";

/**
 * @title DeployMultiMarketSystem
 * @notice Multisig proposal to deploy the multi-market strategy system for all assets:
 *         MarketRegistry, new strategy implementations, and MultiMarketStrategyFactories
 *         for USDC, cbBTC, and WETH. Revokes BACKEND_ROLE from all old factories.
 */
contract DeployMultiMarketSystem is MultisigProposal {
    string[] internal CONFIG_PATHS;

    DeployAssetConfig[] public deployAssetConfigs;

    struct AssetKeys {
        string implKey;
        string factoryKey;
        string oldFactoryKey;
        uint256 strategyTypeId;
    }

    AssetKeys[] public assetKeys;

    constructor() {
        CONFIG_PATHS.push("config/strategies/USDCStrategyConfig.json");
        CONFIG_PATHS.push("config/strategies/cbBTCStrategyConfig.json");
        CONFIG_PATHS.push("config/strategies/WETHStrategyConfig.json");

        for (uint256 i = 0; i < CONFIG_PATHS.length; i++) {
            DeployAssetConfig cfg = new DeployAssetConfig(CONFIG_PATHS[i]);
            vm.makePersistent(address(cfg));
            deployAssetConfigs.push(cfg);
        }
    }

    function run() public override {
        _initializeAddresses();

        // Build asset keys for each config
        for (uint256 i = 0; i < deployAssetConfigs.length; i++) {
            DeployAssetConfig.Config memory cfg = deployAssetConfigs[i].getConfig();
            assetKeys.push(
                AssetKeys({
                    implKey: string(
                        abi.encodePacked("STRATEGY_TYPE_", vm.toString(cfg.strategyParams.strategyTypeId), "_IMPL")
                    ),
                    factoryKey: string(abi.encodePacked(cfg.token, "_MULTI_MARKET_STRATEGY_FACTORY")),
                    oldFactoryKey: string(abi.encodePacked(cfg.token, "_STRATEGY_FACTORY")),
                    strategyTypeId: cfg.strategyParams.strategyTypeId
                })
            );
        }

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
        return "011_DeployMultiMarketSystem";
    }

    function description() public pure override returns (string memory) {
        return "Deploy multi-market strategy system for USDC, cbBTC, and WETH";
    }

    /// @notice Returns the config and keys for a given asset index
    function getAssetConfig(uint256 index) public view returns (DeployAssetConfig.Config memory) {
        return deployAssetConfigs[index].getConfig();
    }

    /// @notice Returns the asset keys for a given index
    function getAssetKeys(uint256 index) public view returns (AssetKeys memory) {
        return assetKeys[index];
    }

    /// @notice Returns total number of assets
    function assetCount() public view returns (uint256) {
        return deployAssetConfigs.length;
    }

    /// @notice Find asset index by token key (e.g. "USDC", "cbBTC", "WETH")
    function findAssetIndex(string memory tokenKey) public view returns (uint256) {
        for (uint256 i = 0; i < deployAssetConfigs.length; i++) {
            if (keccak256(bytes(deployAssetConfigs[i].getConfig().token)) == keccak256(bytes(tokenKey))) {
                return i;
            }
        }
        revert(string(abi.encodePacked("Asset not found: ", tokenKey)));
    }

    function deploy() public override {
        address deployer = addresses.getAddress("DEPLOYER_EOA");

        vm.startBroadcast(deployer);

        // 1. Deploy MarketRegistry (shared, only once)
        if (!addresses.isAddressSet("MARKET_REGISTRY")) {
            MarketRegistry marketReg = new MarketRegistry(
                addresses.getAddress("MAMO_MULTISIG"),
                addresses.getAddress("MAMO_BACKEND"),
                addresses.getAddress("MAMO_MULTISIG") // guardian = multisig
            );
            addresses.addAddress("MARKET_REGISTRY", address(marketReg), true);
        }

        // 2. Deploy implementation and factory for each asset
        for (uint256 i = 0; i < deployAssetConfigs.length; i++) {
            _deployAsset(deployAssetConfigs[i].getConfig(), assetKeys[i]);
        }

        vm.stopBroadcast();
    }

    function _deployAsset(DeployAssetConfig.Config memory cfg, AssetKeys memory keys) internal {
        // Deploy new strategy implementation (one per asset/type)
        if (!addresses.isAddressSet(keys.implKey)) {
            address newImpl = address(new MamoMultiMarketStrategy());
            addresses.addAddress(keys.implKey, newImpl, true);
        }

        // Deploy MultiMarketStrategyFactory. The factory resolves the implementation and the
        // backend from MamoStrategyRegistry at call time, so neither is passed in here.
        address[] memory rewardTokens = new address[](cfg.rewardTokens.length);
        for (uint256 j = 0; j < cfg.rewardTokens.length; j++) {
            rewardTokens[j] = addresses.getAddress(cfg.rewardTokens[j].token);
        }

        uint256[] memory defaultSplitBps = new uint256[](cfg.markets.length);
        for (uint256 j = 0; j < cfg.markets.length; j++) {
            defaultSplitBps[j] = cfg.markets[j].splitBps;
        }

        MultiMarketStrategyFactory factory = new MultiMarketStrategyFactory(
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            addresses.getAddress(cfg.token),
            addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"),
            addresses.getAddress("MAMO_MULTISIG"),
            addresses.getAddress("MARKET_REGISTRY"),
            keys.strategyTypeId,
            cfg.strategyParams.hookGasLimit,
            cfg.strategyParams.allowedSlippageInBps,
            cfg.strategyParams.compoundFee,
            rewardTokens,
            defaultSplitBps
        );

        if (addresses.isAddressSet(keys.factoryKey)) {
            addresses.changeAddress(keys.factoryKey, address(factory), true);
        } else {
            addresses.addAddress(keys.factoryKey, address(factory), true);
        }
    }

    function preBuildMock() public view override {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        for (uint256 i = 0; i < assetKeys.length; i++) {
            assertTrue(
                registry.latestImplementationById(assetKeys[i].strategyTypeId) != address(0),
                "Type should already exist"
            );
        }

        // Pin who index 0 is BEFORE the proposal runs, so the paired assertion in validate() can
        // prove the role churn below did not move it. Any proposal that grants or revokes
        // BACKEND_ROLE should carry this pair — the whole point of Sherlock #41 is that the
        // identity at index 0 changes as an invisible side effect of unrelated membership edits.
        assertEq(
            registry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 should be the strategy multicall before this proposal"
        );
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        MarketRegistry marketReg = MarketRegistry(addresses.getAddress("MARKET_REGISTRY"));

        // Grant multisig BACKEND_ROLE on MarketRegistry temporarily for market registration
        marketReg.grantRole(marketReg.BACKEND_ROLE(), addresses.getAddress("MAMO_MULTISIG"));

        for (uint256 i = 0; i < deployAssetConfigs.length; i++) {
            DeployAssetConfig.Config memory cfg = deployAssetConfigs[i].getConfig();
            AssetKeys memory keys = assetKeys[i];
            address impl = addresses.getAddress(keys.implKey);

            // 1. Whitelist implementation on MamoStrategyRegistry (skip if already whitelisted)
            if (!registry.whitelistedImplementations(impl)) {
                registry.whitelistImplementation(impl, keys.strategyTypeId);
            }

            // 2. Register markets in MarketRegistry (skip if already registered)
            address tokenAddr = addresses.getAddress(cfg.token);
            for (uint256 j = 0; j < cfg.markets.length; j++) {
                address target = addresses.getAddress(cfg.markets[j].target);
                bool alreadyRegistered = false;
                try marketReg.isMarketActive(tokenAddr, target) {
                    alreadyRegistered = true;
                } catch {
                    // Market not registered yet
                }
                if (!alreadyRegistered) {
                    MarketType mType = _parseMarketType(cfg.markets[j].marketType);
                    marketReg.addMarket(tokenAddr, target, mType);
                }
            }

            // 3. Grant BACKEND_ROLE to the new factory BEFORE revoking the old one.
            //    Order is load-bearing, not cosmetic: BACKEND_ROLE is an EnumerableSet, and a
            //    revocation swaps the LAST member into the vacated slot. Revoking first therefore
            //    re-points `getRoleMember(BACKEND_ROLE, 0)` — the value `getBackendAddress()`
            //    returns — at whatever happened to be last, in the middle of the proposal. Granting
            //    first also means there is no instant in which this asset has no factory able to
            //    onboard users.
            registry.grantRole(registry.BACKEND_ROLE(), addresses.getAddress(keys.factoryKey));

            // 4. Revoke BACKEND_ROLE from the old factory
            if (addresses.isAddressSet(keys.oldFactoryKey)) {
                address oldFactory = addresses.getAddress(keys.oldFactoryKey);
                if (registry.hasRole(registry.BACKEND_ROLE(), oldFactory)) {
                    registry.revokeRole(registry.BACKEND_ROLE(), oldFactory);
                }
            }
        }

        // The operator EOA must hold BACKEND_ROLE in its own right. Before this PR the old
        // factories PINNED the MAMO_BACKEND address at construction, so it could call
        // createStrategyForUser without ever being a role member; the new factories authorize
        // against `hasRole(BACKEND_ROLE, ...)`, and on the deployed registry MAMO_BACKEND is NOT a
        // member (the current set is the multicall plus the five factories). Without this grant the
        // upgrade silently takes user onboarding offline for the operator.
        if (!registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("MAMO_BACKEND"))) {
            registry.grantRole(registry.BACKEND_ROLE(), addresses.getAddress("MAMO_BACKEND"));
        }

        // Revoke temporary BACKEND_ROLE from multisig on MarketRegistry
        marketReg.revokeRole(marketReg.BACKEND_ROLE(), addresses.getAddress("MAMO_MULTISIG"));

        // Grant BACKEND_ROLE to STRATEGY_MULTICALL on MarketRegistry
        if (addresses.isAddressSet("STRATEGY_MULTICALL")) {
            marketReg.grantRole(marketReg.BACKEND_ROLE(), addresses.getAddress("STRATEGY_MULTICALL"));
        }
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);
    }

    function validate() public view override {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        MarketRegistry marketReg = MarketRegistry(addresses.getAddress("MARKET_REGISTRY"));

        for (uint256 i = 0; i < deployAssetConfigs.length; i++) {
            DeployAssetConfig.Config memory cfg = deployAssetConfigs[i].getConfig();
            AssetKeys memory keys = assetKeys[i];
            address impl = addresses.getAddress(keys.implKey);

            // Verify implementation is whitelisted
            assertTrue(registry.whitelistedImplementations(impl), "Implementation should be whitelisted");
            assertEq(registry.implementationToId(impl), keys.strategyTypeId, "Wrong strategy type ID");
            assertEq(registry.latestImplementationById(keys.strategyTypeId), impl, "Wrong latest implementation");

            // Verify new factory has BACKEND_ROLE
            assertTrue(
                registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress(keys.factoryKey)),
                "New factory should have BACKEND_ROLE"
            );

            // Verify old factory no longer has BACKEND_ROLE
            if (addresses.isAddressSet(keys.oldFactoryKey)) {
                assertFalse(
                    registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress(keys.oldFactoryKey)),
                    "Old factory should not have BACKEND_ROLE"
                );
            }

            // Verify markets are registered
            for (uint256 j = 0; j < cfg.markets.length; j++) {
                address target = addresses.getAddress(cfg.markets[j].target);
                assertTrue(
                    marketReg.isMarketActive(addresses.getAddress(cfg.token), target), "Market should be active"
                );
            }

            // Verify factory configuration
            MultiMarketStrategyFactory factory = MultiMarketStrategyFactory(addresses.getAddress(keys.factoryKey));
            assertEq(factory.strategyTypeId(), keys.strategyTypeId, "Factory strategyTypeId mismatch");
            assertEq(factory.token(), addresses.getAddress(cfg.token), "Factory token mismatch");
            assertEq(
                factory.mamoStrategyRegistry(),
                addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
                "Factory registry mismatch"
            );
            assertEq(
                factory.marketRegistry(), addresses.getAddress("MARKET_REGISTRY"), "Factory market registry mismatch"
            );
        }

        // Verify multisig no longer has BACKEND_ROLE on MarketRegistry
        assertFalse(
            marketReg.hasRole(marketReg.BACKEND_ROLE(), addresses.getAddress("MAMO_MULTISIG")),
            "Multisig should not have BACKEND_ROLE on MarketRegistry"
        );

        // The operator EOA can onboard users. The new factories gate on hasRole rather than a
        // pinned address, so this is now a membership fact and not an implicit one.
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress("MAMO_BACKEND")),
            "MAMO_BACKEND should hold BACKEND_ROLE"
        );

        // Paired with the preBuildMock assertion: this proposal grants four members and revokes
        // three, and none of that may move index 0. `getBackendAddress()` is no longer an
        // authorization primitive anywhere in src/ (see Sherlock #41), but it remains a live
        // off-chain read, and a silent change of identity here is exactly the failure mode.
        assertEq(
            registry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 must not move"
        );
    }

    function _parseMarketType(string memory typeStr) internal pure returns (MarketType) {
        bytes32 hash = keccak256(bytes(typeStr));
        if (hash == keccak256("MTOKEN")) {
            return MarketType.MTOKEN;
        }
        require(hash == keccak256("ERC4626"), "Unknown market type");
        return MarketType.ERC4626;
    }

    function _initializeAddresses() internal {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }
}
