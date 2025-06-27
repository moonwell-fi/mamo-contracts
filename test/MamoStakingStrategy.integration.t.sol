// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {AccountRegistry} from "@contracts/AccountRegistry.sol";
import {MamoAccount} from "@contracts/MamoAccount.sol";
import {MamoAccountFactory} from "@contracts/MamoAccountFactory.sol";
import {MamoStakingStrategy} from "@contracts/MamoStakingStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";

import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IDEXRouter} from "@interfaces/IDEXRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployMamoStaking} from "@script/DeployMamoStaking.s.sol";

contract MamoStakingStrategyIntegrationTest is Test {
    Addresses public addresses;
    
    // Contracts
    AccountRegistry public accountRegistry;
    MamoAccountFactory public mamoAccountFactory;
    MamoStakingStrategy public mamoStakingStrategy;
    MamoStrategyRegistry public mamoStrategyRegistry;
    ERC20MoonwellMorphoStrategy public morphoStrategy;
    
    // External contracts
    IMultiRewards public multiRewards;
    IERC20 public mamoToken;
    IDEXRouter public dexRouter;
    
    // Addresses
    address public admin;
    address public backend;
    address public guardian;
    address public deployer;
    address public feeCollector;
    
    // Test user
    address public user;
    MamoAccount public userAccount;

    function setUp() public {
        // Create a new addresses instance for testing
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        
        addresses = new Addresses(addressesFolderPath, chainIds);
        
        // Get the addresses for the roles
        admin = addresses.getAddress("MAMO_COMPOUNDER");
        backend = addresses.getAddress("BACKEND_ADDRESS");
        guardian = addresses.getAddress("GUARDIAN_ADDRESS");
        feeCollector = addresses.getAddress("FEE_COLLECTOR");
        deployer = addresses.getAddress("DEPLOYER_EOA");
        
        // Get external contract addresses
        mamoStrategyRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        morphoStrategy = ERC20MoonwellMorphoStrategy(payable(addresses.getAddress("MORPHO_STRATEGY")));
        multiRewards = IMultiRewards(addresses.getAddress("MULTI_REWARDS"));
        mamoToken = IERC20(addresses.getAddress("MAMO_TOKEN"));
        dexRouter = IDEXRouter(addresses.getAddress("DEX_ROUTER"));
        
        // Deploy the MamoStaking contracts using the script
        DeployMamoStaking deployScript = new DeployMamoStaking();
        address[] memory deployedContracts = deployScript.deploy(addresses, deployer);
        
        // Get the deployed contract instances
        accountRegistry = AccountRegistry(deployedContracts[0]);
        mamoAccountFactory = MamoAccountFactory(deployedContracts[1]);
        mamoStakingStrategy = MamoStakingStrategy(deployedContracts[2]);
        
        // Create a random test user
        user = makeAddr("testUser");
        
        // Deploy a MamoAccount for the test user
        vm.startPrank(backend);
        address accountImplementation = addresses.getAddress("MAMO_ACCOUNT_IMPLEMENTATION");
        userAccount = MamoAccount(payable(mamoAccountFactory.createAccount(user, accountImplementation)));
        vm.stopPrank();
    }
}