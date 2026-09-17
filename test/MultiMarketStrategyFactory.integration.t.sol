// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoMultiMarketStrategy} from "@contracts/MamoMultiMarketStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {MarketRegistry} from "@contracts/MarketRegistry.sol";
import {MultiMarketStrategyFactory} from "@contracts/MultiMarketStrategyFactory.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";

import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {DeployConfig} from "@script/DeployConfig.sol";
import {DeploySlippagePriceChecker} from "@script/DeploySlippagePriceChecker.s.sol";

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MultiMarketStrategyFactoryTest is Test {
    Addresses public addresses;

    MamoStrategyRegistry public registry;
    MarketRegistry public marketRegistry;
    ISlippagePriceChecker public slippagePriceChecker;
    IERC20 public underlying;
    IMToken public mToken;
    IERC4626 public metaMorphoVault;

    address public owner;
    address public backend;
    address public admin;
    address public guardian;
    address public deployer;

    DeployConfig.DeploymentConfig public config;
    DeployAssetConfig.Config public assetConfig;
    uint256 public strategyTypeId;
    MamoMultiMarketStrategy public implementation;

    function setUp() public {
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));

        string memory assetConfigPath =
            vm.envOr("ASSET_CONFIG_PATH", string("config/strategies/USDCStrategyConfig.json"));

        DeployConfig configDeploy = new DeployConfig(configPath);
        config = configDeploy.getConfig();

        DeployAssetConfig assetConfigDeploy = new DeployAssetConfig(assetConfigPath);
        assetConfig = assetConfigDeploy.getConfig();

        admin = addresses.getAddress(config.admin);
        backend = addresses.getAddress(config.backend);
        guardian = addresses.getAddress(config.guardian);
        deployer = addresses.getAddress(config.deployer);
        owner = makeAddr("owner");

        underlying = IERC20(addresses.getAddress(assetConfig.token));
        mToken = IMToken(addresses.getAddress(assetConfig.moonwellMarket));
        metaMorphoVault = IERC4626(addresses.getAddress(assetConfig.metamorphoVault));

        if (addresses.isAddressSet("CHAINLINK_SWAP_CHECKER_PROXY")) {
            slippagePriceChecker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        } else {
            _setupSlippagePriceChecker();
        }

        registry = new MamoStrategyRegistry(admin, backend, guardian);
        marketRegistry = new MarketRegistry(admin, backend, guardian);

        implementation = new MamoMultiMarketStrategy(address(marketRegistry));

        vm.prank(admin);
        strategyTypeId = registry.whitelistImplementation(address(implementation), 0);

        vm.startPrank(backend);
        marketRegistry.addMarket(address(underlying), address(mToken), MarketType.MTOKEN);
        marketRegistry.addMarket(address(underlying), address(metaMorphoVault), MarketType.ERC4626);
        vm.stopPrank();
    }

    function _setupSlippagePriceChecker() private {
        DeploySlippagePriceChecker deployScript = new DeploySlippagePriceChecker();
        slippagePriceChecker = deployScript.deploySlippagePriceChecker(addresses, config);

        vm.startPrank(deployer);
        for (uint256 i = 0; i < config.rewardTokens.length; i++) {
            ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
                new ISlippagePriceChecker.TokenFeedConfiguration[](1);

            configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
                chainlinkFeed: addresses.getAddress(config.rewardTokens[i].priceFeed),
                reverse: config.rewardTokens[i].reverse,
                heartbeat: config.rewardTokens[i].heartbeat
            });

            slippagePriceChecker.addTokenConfiguration(
                address(addresses.getAddress(config.rewardTokens[i].token)), address(underlying), configs
            );
        }
        vm.stopPrank();
    }

    function testMultiMarketFactoryCreatesStrategy() public {
        uint256[] memory factoryDefaultSplits = new uint256[](2);
        factoryDefaultSplits[0] = 6000;
        factoryDefaultSplits[1] = 4000;

        MultiMarketStrategyFactory factory = new MultiMarketStrategyFactory(
            address(registry),
            address(underlying),
            address(slippagePriceChecker),
            admin,
            address(marketRegistry),
            strategyTypeId,
            100000,
            100,
            500,
            new address[](0),
            factoryDefaultSplits
        );

        bytes32 backendRole = registry.BACKEND_ROLE();
        vm.prank(admin);
        registry.grantRole(backendRole, address(factory));

        address user = makeAddr("factoryUser");
        vm.prank(user);
        address strategyAddr = factory.createStrategyForUser(user);

        MamoMultiMarketStrategy factoryStrategy = MamoMultiMarketStrategy(payable(strategyAddr));
        MamoMultiMarketStrategy.Market[] memory markets = factoryStrategy.getMarkets();
        assertEq(markets.length, 2, "Factory should create strategy with 2 markets");
        assertEq(markets[0].splitBps, 6000, "Market 0 split should be 6000");
        assertEq(markets[1].splitBps, 4000, "Market 1 split should be 4000");
    }
}
