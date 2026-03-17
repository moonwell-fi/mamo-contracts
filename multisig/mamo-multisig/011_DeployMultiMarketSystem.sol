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
 * @notice Multisig proposal to deploy the multi-market strategy system:
 *         MarketRegistry, new strategy implementation, and MultiMarketStrategyFactory.
 * @dev Parameterized by ASSET_CONFIG_PATH env var. Run once per asset to upgrade
 *      an existing strategy type with multi-market support.
 */
contract DeployMultiMarketSystem is MultisigProposal {
    DeployAssetConfig public immutable deployAssetConfig;

    uint256 public strategyTypeId;
    string public implKey;
    string public factoryKey;

    constructor() {
        string memory configPath =
            vm.envOr("ASSET_CONFIG_PATH", string("config/strategies/USDCStrategyConfig.json"));
        deployAssetConfig = new DeployAssetConfig(configPath);
        vm.makePersistent(address(deployAssetConfig));
    }

    function run() public override {
        _initializeAddresses();

        DeployAssetConfig.Config memory cfg = deployAssetConfig.getConfig();
        implKey = string(abi.encodePacked(cfg.token, "_MULTI_MARKET_IMPL"));
        factoryKey = string(abi.encodePacked(cfg.token, "_MULTI_MARKET_STRATEGY_FACTORY"));

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
        return "Deploy multi-market strategy system: MarketRegistry, implementation, and factory";
    }

    function deploy() public override {
        DeployAssetConfig.Config memory cfg = deployAssetConfig.getConfig();
        address deployer = addresses.getAddress("DEPLOYER_EOA");

        // Use the existing strategy type ID from config (upgrade, not new type)
        strategyTypeId = cfg.strategyParams.strategyTypeId;

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

        // 2. Deploy new strategy implementation (one per asset/type)
        if (!addresses.isAddressSet(implKey)) {
            address newImpl = address(new MamoMultiMarketStrategy());
            addresses.addAddress(implKey, newImpl, true);
        }

        // 3. Deploy MultiMarketStrategyFactory
        address impl = addresses.getAddress(implKey);
        address[] memory rewardTokens = new address[](cfg.rewardTokens.length);
        for (uint256 i = 0; i < cfg.rewardTokens.length; i++) {
            rewardTokens[i] = addresses.getAddress(cfg.rewardTokens[i].token);
        }

        uint256[] memory defaultSplitBps = new uint256[](cfg.markets.length);
        for (uint256 i = 0; i < cfg.markets.length; i++) {
            defaultSplitBps[i] = cfg.markets[i].splitBps;
        }

        MultiMarketStrategyFactory factory = new MultiMarketStrategyFactory(
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            addresses.getAddress("MAMO_BACKEND"),
            addresses.getAddress(cfg.token),
            addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"),
            impl,
            addresses.getAddress("MAMO_MULTISIG"),
            addresses.getAddress("MARKET_REGISTRY"),
            strategyTypeId,
            cfg.strategyParams.hookGasLimit,
            cfg.strategyParams.allowedSlippageInBps,
            cfg.strategyParams.compoundFee,
            rewardTokens,
            defaultSplitBps
        );

        if (addresses.isAddressSet(factoryKey)) {
            addresses.changeAddress(factoryKey, address(factory), true);
        } else {
            addresses.addAddress(factoryKey, address(factory), true);
        }

        vm.stopBroadcast();
    }

    function preBuildMock() public view override {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        // Existing type should already have an implementation (we're upgrading it)
        assertTrue(registry.latestImplementationById(strategyTypeId) != address(0), "Type should already exist");
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        MarketRegistry marketReg = MarketRegistry(addresses.getAddress("MARKET_REGISTRY"));
        DeployAssetConfig.Config memory cfg = deployAssetConfig.getConfig();

        address impl = addresses.getAddress(implKey);

        // 1. Whitelist implementation on MamoStrategyRegistry
        registry.whitelistImplementation(impl, strategyTypeId);

        // 2. Register markets in MarketRegistry
        //    Multisig is admin on MarketRegistry, grant itself BACKEND_ROLE temporarily
        marketReg.grantRole(marketReg.BACKEND_ROLE(), addresses.getAddress("MAMO_MULTISIG"));

        for (uint256 i = 0; i < cfg.markets.length; i++) {
            MarketType mType = _parseMarketType(cfg.markets[i].marketType);
            marketReg.addMarket(strategyTypeId, addresses.getAddress(cfg.markets[i].target), mType);
        }

        marketReg.revokeRole(marketReg.BACKEND_ROLE(), addresses.getAddress("MAMO_MULTISIG"));

        // 3. Grant BACKEND_ROLE to STRATEGY_MULTICALL on MarketRegistry
        //    (it serves as the backend in the deploy config)
        if (addresses.isAddressSet("STRATEGY_MULTICALL")) {
            marketReg.grantRole(marketReg.BACKEND_ROLE(), addresses.getAddress("STRATEGY_MULTICALL"));
        }

        // 4. Grant BACKEND_ROLE to new factory on MamoStrategyRegistry
        registry.grantRole(registry.BACKEND_ROLE(), addresses.getAddress(factoryKey));
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);
    }

    function validate() public view override {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        MarketRegistry marketReg = MarketRegistry(addresses.getAddress("MARKET_REGISTRY"));
        DeployAssetConfig.Config memory cfg = deployAssetConfig.getConfig();

        address impl = addresses.getAddress(implKey);

        // Verify implementation is whitelisted
        assertTrue(registry.whitelistedImplementations(impl), "Implementation should be whitelisted");
        assertEq(registry.implementationToId(impl), strategyTypeId, "Wrong strategy type ID");
        assertEq(registry.latestImplementationById(strategyTypeId), impl, "Wrong latest implementation");

        // Verify factory has BACKEND_ROLE
        assertTrue(
            registry.hasRole(registry.BACKEND_ROLE(), addresses.getAddress(factoryKey)),
            "Factory should have BACKEND_ROLE"
        );

        // Verify markets are registered
        assertEq(marketReg.getMarketCount(strategyTypeId), cfg.markets.length, "Wrong market count");

        for (uint256 i = 0; i < cfg.markets.length; i++) {
            address target = addresses.getAddress(cfg.markets[i].target);
            assertTrue(marketReg.isMarketActive(strategyTypeId, target), "Market should be active");
        }

        // Verify multisig no longer has BACKEND_ROLE on MarketRegistry
        assertFalse(
            marketReg.hasRole(marketReg.BACKEND_ROLE(), addresses.getAddress("MAMO_MULTISIG")),
            "Multisig should not have BACKEND_ROLE on MarketRegistry"
        );

        // Verify factory configuration
        MultiMarketStrategyFactory factory = MultiMarketStrategyFactory(addresses.getAddress(factoryKey));
        assertEq(factory.strategyTypeId(), strategyTypeId, "Factory strategyTypeId mismatch");
        assertEq(factory.token(), addresses.getAddress(cfg.token), "Factory token mismatch");
        assertEq(
            factory.mamoStrategyRegistry(),
            addresses.getAddress("MAMO_STRATEGY_REGISTRY"),
            "Factory registry mismatch"
        );
        assertEq(factory.marketRegistry(), addresses.getAddress("MARKET_REGISTRY"), "Factory market registry mismatch");
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
