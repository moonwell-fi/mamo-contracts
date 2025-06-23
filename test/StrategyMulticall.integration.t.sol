// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@fps/addresses/Addresses.sol";

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StrategyFactory} from "@contracts/StrategyFactory.sol";
import {StrategyMulticall} from "@contracts/StrategyMulticall.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";
import {DeployConfig} from "@script/DeployConfig.sol";

import {DeploySlippagePriceChecker} from "@script/DeploySlippagePriceChecker.s.sol";
import {StrategyFactoryDeployer} from "@script/StrategyFactoryDeployer.s.sol";
import {StrategyRegistryDeploy} from "@script/StrategyRegistryDeploy.s.sol";

import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";

import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FixIsRewardToken} from "@multisig/002_FixIsRewardToken.sol";
import {DeployFactoriesAndMulticall} from "@multisig/003_DeployFactoriesAndMulticall.sol";
import {DeployStrategyMulticall} from "@script/DeployStrategyMulticall.s.sol";

/**
 * @title MaliciousReentrantContract
 * @notice A malicious contract that attempts to perform reentrancy attacks on StrategyMulticall
 */
contract MaliciousReentrantContract {
    StrategyMulticall public immutable multicall;
    bool public attackExecuted;
    uint256 public callDepth;

    constructor(address _multicall) {
        multicall = StrategyMulticall(payable(_multicall));
    }

    /**
     * @notice This function will be called and will attempt reentrancy if it becomes owner
     */
    function triggerReentrancy() external {
        callDepth++;

        // Only attempt reentrancy if we're the owner and this is the first call
        if (multicall.owner() == address(this) && callDepth == 1) {
            // Attempt to call back into the multicall during execution
            StrategyMulticall.Call[] memory maliciousCalls = new StrategyMulticall.Call[](1);
            maliciousCalls[0] = StrategyMulticall.Call({
                target: address(this),
                data: abi.encodeWithSignature("harmlessFunction()"),
                value: 0
            });

            // This should fail due to reentrancy protection
            multicall.genericMulticall(maliciousCalls);
            attackExecuted = true; // This should never execute
        }

        callDepth--;
    }

    /**
     * @notice A harmless function for the second call
     */
    function harmlessFunction() external pure {
        // Do nothing
    }
}

contract StrategyMulticallIntegrationTest is Test {
    Addresses public addresses;
    StrategyMulticall public multicall;
    StrategyFactory public factory;
    MamoStrategyRegistry public registry;
    ERC20MoonwellMorphoStrategy public implementation;
    ISlippagePriceChecker public slippagePriceChecker;

    // Configuration
    DeployConfig.DeploymentConfig public config;
    DeployAssetConfig.Config public assetConfig;

    // Addresses
    address public admin;
    address public backend;
    address public guardian;
    address public deployer;
    address public mamoMultisig;

    // Strategy parameters
    uint256 public strategyTypeId;
    uint256 public splitMToken;
    uint256 public splitVault;

    // Events
    event GenericMulticallExecuted(address indexed initiator, uint256 callsCount);

    function setUp() public {
        // workaround to make test contract work with mappings
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        // Create a new addresses instance for testing
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Load configurations
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));
        string memory assetConfigPath = vm.envString("ASSET_CONFIG_PATH");

        DeployConfig configDeploy = new DeployConfig(configPath);
        config = configDeploy.getConfig();

        DeployAssetConfig assetConfigDeploy = new DeployAssetConfig(assetConfigPath);
        assetConfig = assetConfigDeploy.getConfig();

        // Get the addresses for the roles
        admin = addresses.getAddress(config.admin);
        backend = addresses.getAddress(config.backend);
        guardian = addresses.getAddress(config.guardian);
        deployer = addresses.getAddress(config.deployer);
        mamoMultisig = admin;

        // todo remove this once FixIsRewardToken is executed
        FixIsRewardToken fixIsRewardToken = new FixIsRewardToken();
        fixIsRewardToken.setAddresses(addresses);
        fixIsRewardToken.deploy();
        fixIsRewardToken.build();
        fixIsRewardToken.simulate();
        fixIsRewardToken.validate();

        DeployFactoriesAndMulticall proposal = new DeployFactoriesAndMulticall();
        proposal.setAddresses(addresses);
        proposal.deploy();
        proposal.build();
        proposal.simulate();
        proposal.validate();

        factory = StrategyFactory(payable(addresses.getAddress("cbBTC_STRATEGY_FACTORY")));
        multicall = StrategyMulticall(payable(addresses.getAddress("STRATEGY_MULTICALL")));

        registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        splitMToken = assetConfig.strategyParams.splitMToken;
        splitVault = assetConfig.strategyParams.splitVault;
    }

    function testMulticallDeployment() public view {
        // Test that the multicall was deployed correctly
        assertTrue(address(multicall) != address(0), "Multicall not deployed");

        // Test that the multicall has the correct owner
        assertEq(multicall.owner(), backend, "Owner should be backend");
    }

    function testDeployStrategiesAndUpdatePositionViaMulticall() public {
        // Create users and deploy strategies
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Deploy strategy for user1 using the backend
        vm.startPrank(backend);
        address strategy1 = factory.createStrategyForUser(user1);
        vm.stopPrank();

        // Deploy strategy for user2 using the user2
        vm.startPrank(user2);
        address strategy2 = factory.createStrategyForUser(user2);
        vm.stopPrank();

        // Verify strategies were deployed
        assertTrue(strategy1 != address(0), "Strategy1 not deployed");
        assertTrue(strategy2 != address(0), "Strategy2 not deployed");
        assertTrue(registry.isUserStrategy(user1, strategy1), "Strategy1 not registered");
        assertTrue(registry.isUserStrategy(user2, strategy2), "Strategy2 not registered");

        // Get cbBTC token address from config
        IERC20 cbBTC = IERC20(addresses.getAddress(assetConfig.token));
        uint256 depositAmount = 1e8; // 1 cbBTC (8 decimals)

        // Give cbBTC to users and deposit into strategies
        deal(address(cbBTC), user1, depositAmount);
        deal(address(cbBTC), user2, depositAmount);

        // User1 deposits into strategy1
        vm.startPrank(user1);
        cbBTC.approve(strategy1, depositAmount);
        ERC20MoonwellMorphoStrategy(payable(strategy1)).deposit(depositAmount);
        vm.stopPrank();

        // User2 deposits into strategy2
        vm.startPrank(user2);
        cbBTC.approve(strategy2, depositAmount);
        ERC20MoonwellMorphoStrategy(payable(strategy2)).deposit(depositAmount);
        vm.stopPrank();

        // Step 2: Call updatePosition function from the multicall
        uint256 newSplitMToken = 6000; // 60%
        uint256 newSplitVault = 4000; // 40%

        // Prepare multicall data for updatePosition calls
        StrategyMulticall.Call[] memory calls = new StrategyMulticall.Call[](2);

        calls[0] = StrategyMulticall.Call({
            target: strategy1,
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", newSplitMToken, newSplitVault),
            value: 0
        });

        calls[1] = StrategyMulticall.Call({
            target: strategy2,
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", newSplitMToken, newSplitVault),
            value: 0
        });

        // Execute multicall as the owner (backend)
        vm.startPrank(backend);

        // Expect the GenericMulticallExecuted event
        vm.expectEmit(true, false, false, true);
        emit GenericMulticallExecuted(backend, 2);

        multicall.genericMulticall(calls);

        vm.stopPrank();

        // Verify that the position updates were successful
        ERC20MoonwellMorphoStrategy strategyContract1 = ERC20MoonwellMorphoStrategy(payable(strategy1));
        ERC20MoonwellMorphoStrategy strategyContract2 = ERC20MoonwellMorphoStrategy(payable(strategy2));

        assertEq(strategyContract1.splitMToken(), newSplitMToken, "Strategy1 split mToken not updated");
        assertEq(strategyContract1.splitVault(), newSplitVault, "Strategy1 split vault not updated");
        assertEq(strategyContract2.splitMToken(), newSplitMToken, "Strategy2 split mToken not updated");
        assertEq(strategyContract2.splitVault(), newSplitVault, "Strategy2 split vault not updated");
    }

    function testRevokeRoleAndTransferOwnership() public {
        // Verify the role was granted
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), address(multicall)), "Multicall should have BACKEND_ROLE");

        // Step 2: Revoke the BACKEND_ROLE from multicall
        vm.startPrank(mamoMultisig);
        registry.revokeRole(registry.BACKEND_ROLE(), address(multicall));
        vm.stopPrank();

        // Verify the role was revoked
        assertFalse(
            registry.hasRole(registry.BACKEND_ROLE(), address(multicall)),
            "Multicall should not have BACKEND_ROLE after revocation"
        );

        // Step 3: Transfer ownership of multicall to a new owner
        address newOwner = makeAddr("newOwner");

        vm.startPrank(backend);
        multicall.transferOwnership(newOwner);
        vm.stopPrank();

        // Verify ownership was transferred
        assertEq(multicall.owner(), newOwner, "Ownership should be transferred to new owner");
    }

    function testRevertIfNonOwnerCallsMulticall() public {
        address nonOwner = makeAddr("nonOwner");

        // Prepare a simple multicall
        StrategyMulticall.Call[] memory calls = new StrategyMulticall.Call[](1);
        calls[0] =
            StrategyMulticall.Call({target: address(registry), data: abi.encodeWithSignature("paused()"), value: 0});

        // Try to call multicall as non-owner
        vm.startPrank(nonOwner);

        // Expect the call to revert due to onlyOwner modifier
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));

        multicall.genericMulticall(calls);

        vm.stopPrank();
    }

    function testMulticallWithEmptyCallsArray() public {
        // Prepare empty calls array
        StrategyMulticall.Call[] memory calls = new StrategyMulticall.Call[](0);

        vm.startPrank(backend);

        // Expect the call to revert with "Empty calls array"
        vm.expectRevert("StrategyMulticall: Empty calls array");

        multicall.genericMulticall(calls);

        vm.stopPrank();
    }

    function testMulticallWithInvalidTargetAddress() public {
        // Prepare multicall with invalid target (zero address)
        StrategyMulticall.Call[] memory calls = new StrategyMulticall.Call[](1);
        calls[0] =
            StrategyMulticall.Call({target: address(0), data: abi.encodeWithSignature("someFunction()"), value: 0});

        vm.startPrank(backend);

        // Expect the call to revert with "Invalid target address"
        vm.expectRevert("StrategyMulticall: Invalid target address");

        multicall.genericMulticall(calls);

        vm.stopPrank();
    }

    function testMulticallCanManageMultipleStrategies() public {
        // Create multiple users and strategies
        address[] memory users = new address[](3);
        address[] memory strategies = new address[](3);

        for (uint256 i = 0; i < 3; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", vm.toString(i))));

            vm.prank(backend);
            strategies[i] = factory.createStrategyForUser(users[i]);

            assertTrue(strategies[i] != address(0), "Strategy not deployed");
            assertTrue(registry.isUserStrategy(users[i], strategies[i]), "Strategy not registered");
        }

        // Get cbBTC token address from config and deposit into each strategy
        IERC20 cbBTC = IERC20(addresses.getAddress(assetConfig.token));
        uint256 depositAmount = 1e8; // 1 cbBTC (8 decimals)

        for (uint256 i = 0; i < 3; i++) {
            // Give cbBTC to user and deposit into strategy
            deal(address(cbBTC), users[i], depositAmount);

            vm.startPrank(users[i]);
            cbBTC.approve(strategies[i], depositAmount);
            ERC20MoonwellMorphoStrategy(payable(strategies[i])).deposit(depositAmount);
            vm.stopPrank();
        }

        // Prepare multicall to update all strategies
        uint256 newSplitMToken = 7000; // 70%
        uint256 newSplitVault = 3000; // 30%

        StrategyMulticall.Call[] memory calls = new StrategyMulticall.Call[](3);

        for (uint256 i = 0; i < 3; i++) {
            calls[i] = StrategyMulticall.Call({
                target: strategies[i],
                data: abi.encodeWithSignature("updatePosition(uint256,uint256)", newSplitMToken, newSplitVault),
                value: 0
            });
        }

        // Execute multicall
        vm.startPrank(backend);

        vm.expectEmit(true, false, false, true);
        emit GenericMulticallExecuted(backend, 3);

        multicall.genericMulticall(calls);

        vm.stopPrank();

        // Verify all strategies were updated
        for (uint256 i = 0; i < 3; i++) {
            ERC20MoonwellMorphoStrategy strategyContract = ERC20MoonwellMorphoStrategy(payable(strategies[i]));
            assertEq(strategyContract.splitMToken(), newSplitMToken, "Strategy split mToken not updated");
            assertEq(strategyContract.splitVault(), newSplitVault, "Strategy split vault not updated");
        }
    }

    function testMulticallWithFailingCall() public {
        // Create strategy
        address user = makeAddr("user");
        vm.prank(backend);
        address strategy = factory.createStrategyForUser(user);

        // Deposit some funds into the strategy so updatePosition can work
        IERC20 cbBTC = IERC20(addresses.getAddress(assetConfig.token));
        uint256 depositAmount = 1e8; // 1 cbBTC (8 decimals)

        deal(address(cbBTC), user, depositAmount);
        vm.startPrank(user);
        cbBTC.approve(strategy, depositAmount);
        ERC20MoonwellMorphoStrategy(payable(strategy)).deposit(depositAmount);
        vm.stopPrank();

        // Prepare multicall with an invalid call that will fail
        StrategyMulticall.Call[] memory calls = new StrategyMulticall.Call[](1);
        calls[0] = StrategyMulticall.Call({
            target: strategy,
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", 5000, 6000), // Invalid: adds up to 11000 > 10000
            value: 0
        });

        vm.startPrank(backend);

        // Expect the multicall to revert because the individual call fails
        vm.expectRevert();

        multicall.genericMulticall(calls);

        vm.stopPrank();
    }

    function testReentrancyProtectionViaDirectCall() public {
        // Deploy malicious contract
        MaliciousReentrantContract maliciousContract = new MaliciousReentrantContract(address(multicall));

        // Transfer ownership to the malicious contract so it can attempt reentrancy
        vm.startPrank(backend);
        multicall.transferOwnership(address(maliciousContract));
        vm.stopPrank();

        // Verify ownership transfer
        assertEq(multicall.owner(), address(maliciousContract), "Ownership should be transferred to malicious contract");

        // Prepare multicall that will trigger the malicious contract's reentrancy attempt
        StrategyMulticall.Call[] memory calls = new StrategyMulticall.Call[](1);
        calls[0] = StrategyMulticall.Call({
            target: address(maliciousContract),
            data: abi.encodeWithSignature("triggerReentrancy()"),
            value: 0
        });

        // The malicious contract will call this as the owner
        vm.startPrank(address(maliciousContract));

        // Expect the call to revert due to reentrancy protection
        // The ReentrancyGuard should prevent the nested call
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);

        multicall.genericMulticall(calls);

        vm.stopPrank();

        // Verify that the attack was not executed
        assertFalse(maliciousContract.attackExecuted(), "Reentrancy attack should have been blocked");
    }

    function testNormalOperationAfterReentrancyAttempt() public {
        // Deploy malicious contract
        MaliciousReentrantContract maliciousContract = new MaliciousReentrantContract(address(multicall));

        // Transfer ownership to the malicious contract
        vm.startPrank(backend);
        multicall.transferOwnership(address(maliciousContract));
        vm.stopPrank();

        // First, attempt reentrancy (should fail)
        StrategyMulticall.Call[] memory maliciousCalls = new StrategyMulticall.Call[](1);
        maliciousCalls[0] = StrategyMulticall.Call({
            target: address(maliciousContract),
            data: abi.encodeWithSignature("triggerReentrancy()"),
            value: 0
        });

        vm.startPrank(address(maliciousContract));

        // Expect the reentrancy attempt to fail
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        multicall.genericMulticall(maliciousCalls);

        // Now verify that normal operations still work after the failed reentrancy
        StrategyMulticall.Call[] memory normalCalls = new StrategyMulticall.Call[](1);
        normalCalls[0] = StrategyMulticall.Call({
            target: address(maliciousContract),
            data: abi.encodeWithSignature("harmlessFunction()"),
            value: 0
        });

        // This should succeed
        vm.expectEmit(true, false, false, true);
        emit GenericMulticallExecuted(address(maliciousContract), 1);

        multicall.genericMulticall(normalCalls);

        vm.stopPrank();

        // Verify attack was never executed
        assertFalse(maliciousContract.attackExecuted(), "Attack should never have been executed");

        // Transfer ownership back to backend for cleanup
        vm.startPrank(address(maliciousContract));
        multicall.transferOwnership(backend);
        vm.stopPrank();
    }
}
