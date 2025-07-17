// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoStakingRegistry} from "@contracts/MamoStakingRegistry.sol";
import {MamoStakingStrategy} from "@contracts/MamoStakingStrategy.sol";
import {MamoStakingStrategyFactory} from "@contracts/MamoStakingStrategyFactory.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";

import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";
import {IMultiRewards} from "@contracts/interfaces/IMultiRewards.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {console} from "forge-std/console.sol";

contract MamoStakingV2Deployment is MultisigProposal {
    // Constants for deployment
    uint256 public constant STRATEGY_TYPE_ID = 3; // Strategy type ID for staking strategies
    uint256 public constant DEFAULT_SLIPPAGE_IN_BPS = 100; // 1% default slippage
    uint256 public constant DEFAULT_REWARD_DURATION = 7 days;
    uint256 public constant DEFAULT_NOTIFY_DELAY = 7 days;

    function _initializeAddresses() internal {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }

    function run() public override {
        _initializeAddresses();

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
        return "005_MamoStakingDeployment";
    }

    function description() public pure override returns (string memory) {
        return
        "Deploy MAMO staking system V2: MamoStakingRegistry, MultiRewards, MamoStakingStrategy implementation, MamoStakingStrategyFactory, and RewardsDistributorSafeModule";
    }

    function deploy() public override {
        address admin = addresses.getAddress("F-MAMO"); // admin of rewards distributor safe modules
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        address backend = addresses.getAddress("STRATEGY_MULTICALL");
        address guardian = addresses.getAddress("F-MAMO"); // Use multisig as guardian
        address mamoToken = addresses.getAddress("MAMO");
        address dexRouter = addresses.getAddress("AERODROME_ROUTER");
        address quoter = addresses.getAddress("AERODROME_QUOTER");
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address multiRewards = addresses.getAddress("MAMO_MULTI_REWARDS");

        vm.startBroadcast(deployer);

        address mamoStakingRegistry = address(
            new MamoStakingRegistry(deployer, deployer, guardian, mamoToken, dexRouter, quoter, DEFAULT_SLIPPAGE_IN_BPS)
        );

        address mamoStakingStrategy = address(new MamoStakingStrategy());

        address mamoStakingStrategyFactory = address(
            new MamoStakingStrategyFactory(
                admin,
                mamoStrategyRegistry,
                backend,
                mamoStakingRegistry,
                multiRewards,
                mamoToken,
                mamoStakingStrategy,
                STRATEGY_TYPE_ID,
                DEFAULT_SLIPPAGE_IN_BPS
            )
        );

        address cbBTC = addresses.getAddress("cbBTC");
        address cbBTCMamoPool = addresses.getAddress("cbBTC_MAMO_POOL");
        MamoStakingRegistry(mamoStakingRegistry).addRewardToken(cbBTC, cbBTCMamoPool);

        // Deploy RewardsDistributorSafeModule for MAMO/cbBTC pair
        address rewardsDistributorMamoCbbtc = address(
            new RewardsDistributorSafeModule(
                payable(admin), multiRewards, mamoToken, cbBTC, admin, DEFAULT_REWARD_DURATION, DEFAULT_NOTIFY_DELAY
            )
        );

        MamoStakingRegistry(mamoStakingRegistry).grantRole(
            MamoStakingRegistry(mamoStakingRegistry).BACKEND_ROLE(), backend
        );
        MamoStakingRegistry(mamoStakingRegistry).revokeRole(
            MamoStakingRegistry(mamoStakingRegistry).BACKEND_ROLE(), deployer
        );
        MamoStakingRegistry(mamoStakingRegistry).grantRole(
            MamoStakingRegistry(mamoStakingRegistry).DEFAULT_ADMIN_ROLE(), admin
        );
        MamoStakingRegistry(mamoStakingRegistry).revokeRole(
            MamoStakingRegistry(mamoStakingRegistry).DEFAULT_ADMIN_ROLE(), deployer
        ); // revoke deployer from admin role

        vm.stopBroadcast();

        addresses.changeAddress("MAMO_STAKING_STRATEGY", mamoStakingStrategy, true);
        addresses.changeAddress("MAMO_STAKING_REGISTRY", mamoStakingRegistry, true);
        addresses.changeAddress("MAMO_STAKING_STRATEGY_FACTORY", mamoStakingStrategyFactory, true);
        addresses.changeAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC", rewardsDistributorMamoCbbtc, true);
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        address stakingStrategyFactory = addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY");
        address mamoStakingStrategy = addresses.getAddress("MAMO_STAKING_STRATEGY");

        registry.grantRole(registry.BACKEND_ROLE(), stakingStrategyFactory);
        // This will assign strategy type id to 3
        MamoStrategyRegistry(registry).whitelistImplementation(mamoStakingStrategy, 0);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);
    }

    function validate() public view override {
        // Get contract addresses
        address stakingRegistry = addresses.getAddress("MAMO_STAKING_REGISTRY");
        address multiRewardsAddr = addresses.getAddress("MAMO_MULTI_REWARDS");
        address stakingStrategyImpl = addresses.getAddress("MAMO_STAKING_STRATEGY");
        address stakingStrategyFactory = addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY");
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");

        // Get expected addresses
        address expectedBackend = addresses.getAddress("STRATEGY_MULTICALL");
        address expectedMamoToken = addresses.getAddress("MAMO");

        // Check MamoStakingRegistry
        MamoStakingRegistry stakingRegistryContract = MamoStakingRegistry(stakingRegistry);
        assertEq(
            stakingRegistryContract.mamoToken(), expectedMamoToken, "MamoStakingRegistry should have correct MAMO token"
        );
        assertEq(
            stakingRegistryContract.defaultSlippageInBps(),
            DEFAULT_SLIPPAGE_IN_BPS,
            "MamoStakingRegistry should have correct default slippage"
        );
        assertTrue(
            stakingRegistryContract.hasRole(
                stakingRegistryContract.DEFAULT_ADMIN_ROLE(), addresses.getAddress("F-MAMO")
            ),
            "MamoStakingRegistry should have correct admin"
        );
        assertTrue(
            stakingRegistryContract.hasRole(stakingRegistryContract.BACKEND_ROLE(), expectedBackend),
            "MamoStakingRegistry should have correct backend"
        );

        // Check MamoStakingStrategyFactory
        MamoStakingStrategyFactory factoryContract = MamoStakingStrategyFactory(stakingStrategyFactory);
        assertEq(
            factoryContract.mamoStrategyRegistry(),
            mamoStrategyRegistry,
            "Factory should have correct strategy registry"
        );
        address expectedFactoryBackend = addresses.getAddress("STRATEGY_MULTICALL");
        assertTrue(
            factoryContract.hasRole(factoryContract.BACKEND_ROLE(), expectedFactoryBackend),
            "Factory should have BACKEND_ROLE for expected backend"
        );
        assertEq(factoryContract.stakingRegistry(), stakingRegistry, "Factory should have correct staking registry");
        assertEq(factoryContract.multiRewards(), multiRewardsAddr, "Factory should have correct MultiRewards address");
        assertEq(factoryContract.mamoToken(), expectedMamoToken, "Factory should have correct MAMO token");
        assertEq(
            factoryContract.strategyImplementation(),
            stakingStrategyImpl,
            "Factory should have correct strategy implementation"
        );
        assertEq(factoryContract.strategyTypeId(), STRATEGY_TYPE_ID, "Factory should have correct strategy type ID");
        assertEq(
            factoryContract.defaultSlippageInBps(),
            DEFAULT_SLIPPAGE_IN_BPS,
            "Factory should have correct default slippage"
        );

        // Check MamoStrategyRegistry
        MamoStrategyRegistry registryContract = MamoStrategyRegistry(mamoStrategyRegistry);
        assertTrue(
            registryContract.whitelistedImplementations(stakingStrategyImpl),
            "MamoStakingStrategy implementation should be whitelisted"
        );
        assertEq(
            registryContract.implementationToId(stakingStrategyImpl),
            STRATEGY_TYPE_ID,
            "Implementation should have correct strategy type ID"
        );
        assertEq(
            registryContract.latestImplementationById(STRATEGY_TYPE_ID),
            stakingStrategyImpl,
            "Latest implementation should be set correctly"
        );
        assertTrue(
            registryContract.hasRole(registryContract.BACKEND_ROLE(), stakingStrategyFactory),
            "Factory should have BACKEND_ROLE"
        );

        IMultiRewards multiRewardsContract = IMultiRewards(multiRewardsAddr);
        assertEq(multiRewardsContract.owner(), addresses.getAddress("F-MAMO"), "MultiRewards should have correct owner");
        assertEq(
            multiRewardsContract.stakingToken(), expectedMamoToken, "MultiRewards should have correct staking token"
        );

        assertTrue(stakingStrategyImpl.code.length > 0, "MamoStakingStrategy implementation should have code");

        // Validate RewardsDistributorSafeModule contract
        address rewardsDistributorMamoCbbtcAddr = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        RewardsDistributorSafeModule mamoCbbtcModule = RewardsDistributorSafeModule(rewardsDistributorMamoCbbtcAddr);
        address expectedAdmin = addresses.getAddress("F-MAMO");

        // Validate MAMO/cbBTC module
        assertEq(address(mamoCbbtcModule.safe()), expectedAdmin, "MAMO/cbBTC module should have correct Safe address");
        assertEq(
            address(mamoCbbtcModule.multiRewards()),
            multiRewardsAddr,
            "MAMO/cbBTC module should have correct MultiRewards address"
        );
        assertEq(
            address(mamoCbbtcModule.token1()), expectedMamoToken, "MAMO/cbBTC module should have correct token1 (MAMO)"
        );
        assertEq(
            address(mamoCbbtcModule.token2()),
            addresses.getAddress("cbBTC"),
            "MAMO/cbBTC module should have correct token2 (cbBTC)"
        );
        assertEq(mamoCbbtcModule.admin(), expectedAdmin, "MAMO/cbBTC module should have correct admin");
        assertEq(
            mamoCbbtcModule.rewardDuration(),
            DEFAULT_REWARD_DURATION,
            "MAMO/cbBTC module should have correct reward duration"
        );

        assertTrue(
            rewardsDistributorMamoCbbtcAddr.code.length > 0, "MAMO/cbBTC RewardsDistributorSafeModule should have code"
        );

        // Validate RewardsDistributorSafeModule notify delay
        assertEq(
            mamoCbbtcModule.notifyDelay(), DEFAULT_NOTIFY_DELAY, "MAMO/cbBTC module should have correct notify delay"
        );

        // Validate RewardsDistributorSafeModule state
        assertEq(
            uint256(mamoCbbtcModule.getCurrentState()),
            uint256(RewardsDistributorSafeModule.RewardState.UNINITIALIZED),
            "MAMO/cbBTC module should start in UNINITIALIZED state"
        );

        // Validate that RewardsDistributorSafeModule is not paused
        assertFalse(mamoCbbtcModule.paused(), "MAMO/cbBTC module should not be paused initially");

        // Validate cbBTC is added as reward token in MamoStakingRegistry
        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistryContract.getRewardTokens();
        bool cbBTCFound = false;
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i].token == addresses.getAddress("cbBTC")) {
                cbBTCFound = true;
                assertEq(
                    rewardTokens[i].pool,
                    addresses.getAddress("cbBTC_MAMO_POOL"),
                    "cbBTC should have correct pool in registry"
                );
                break;
            }
        }
        assertTrue(cbBTCFound, "cbBTC should be added as reward token in staking registry");

        // Validate MultiRewards address registry entry matches deployment
        assertEq(
            addresses.getAddress("MAMO_MULTI_REWARDS"),
            multiRewardsAddr,
            "Address registry: MultiRewards entry should match deployed address"
        );

        // Validate all contract addresses are properly registered
        assertEq(
            addresses.getAddress("MAMO_STAKING_STRATEGY"),
            stakingStrategyImpl,
            "Address registry: MAMO_STAKING_STRATEGY should be registered"
        );
        assertEq(
            addresses.getAddress("MAMO_STAKING_REGISTRY"),
            stakingRegistry,
            "Address registry: MAMO_STAKING_REGISTRY should be registered"
        );

        assertEq(
            addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY"),
            stakingStrategyFactory,
            "Address registry: MAMO_STAKING_STRATEGY_FACTORY should be registered"
        );
        assertEq(
            addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC"),
            rewardsDistributorMamoCbbtcAddr,
            "Address registry: REWARDS_DISTRIBUTOR_MAMO_CBBTC should be registered"
        );
    }
}
