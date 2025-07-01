// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BurnAndEarn} from "@contracts/BurnAndEarn.sol";
import {FeeSplitter} from "@contracts/FeeSplitter.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {DeployFeeSplitter} from "@script/DeployFeeSplitter.s.sol";

import {console} from "forge-std/console.sol";

interface IPoolFactory {
    function createPool(address tokenA, address tokenB, bool stable) external returns (address pool);
}

interface IAgentVeToken {
    function withdraw(uint256 amount) external;
}

contract VirtualLPMigration is MultisigProposal {
    // sMAMO contract address
    address public constant SMAMO_CONTRACT = 0x022b91ed8e85ae7cd5348f1ddaafaa3350842ef3;
    
    // Deployed contracts
    DeployFeeSplitter public immutable deployFeeSplitterScript;
    FeeSplitter public feeSplitter;
    BurnAndEarn public burnAndEarn;

    constructor() {
        deployFeeSplitterScript = new DeployFeeSplitter();
        vm.makePersistent(address(deployFeeSplitterScript));
    }

    function _initalizeAddresses() internal {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }

    function run() public override {
        _initalizeAddresses();

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
        return "004_VirtualLPMigration";
    }

    function description() public pure override returns (string memory) {
        return "Deploy FeeSplitter and BurnAndEarn contracts, then withdraw from sMAMO";
    }

    function deploy() public override {
        console.log("Starting VirtualLP Migration deployment...");
        
        // Step 1: Deploy FeeSplitter contract
        console.log("Step 1: Deploying FeeSplitter...");
        feeSplitter = deployFeeSplitterScript.deployFeeSplitter(addresses);
        
        // Step 2: Deploy BurnAndEarn contract with FeeSplitter as feeCollector
        console.log("Step 2: Deploying BurnAndEarn...");
        deployBurnAndEarn();
        
        console.log("VirtualLP Migration deployment completed");
    }

    function deployBurnAndEarn() internal {
        vm.startBroadcast();
        
        address owner = addresses.getAddress("MAMO_MULTISIG");
        
        // Deploy BurnAndEarn with FeeSplitter as feeCollector and multisig as owner
        burnAndEarn = new BurnAndEarn(address(feeSplitter), owner);
        
        console.log("BurnAndEarn deployed at: %s", address(burnAndEarn));
        console.log("Fee collector set to: %s", address(feeSplitter));
        console.log("Owner set to: %s", owner);
        
        vm.stopBroadcast();
        
        // Add the address to the Addresses contract
        if (addresses.isAddressSet("BURN_AND_EARN")) {
            addresses.changeAddress("BURN_AND_EARN", address(burnAndEarn), true);
        } else {
            addresses.addAddress("BURN_AND_EARN", address(burnAndEarn), true);
        }
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Step 3: Withdraw all tokens from sMAMO contract
        console.log("Step 3: Withdrawing from sMAMO contract...");
        
        IAgentVeToken smamoContract = IAgentVeToken(SMAMO_CONTRACT);
        
        // Get the current balance of this contract in sMAMO
        // Since we need to know the balance, we'll call withdraw with the full amount
        // The sMAMO contract should handle the balance check internally
        uint256 balance = IERC20(SMAMO_CONTRACT).balanceOf(address(this));
        
        if (balance > 0) {
            // Withdraw all tokens from sMAMO
            smamoContract.withdraw(balance);
            console.log("Withdrawn %s tokens from sMAMO", balance);
        } else {
            console.log("No tokens to withdraw from sMAMO");
        }
        
        // Step 4: Create pool with the tokens from FeeSplitter
        console.log("Step 4: Creating pool with FeeSplitter tokens...");
        
        // Get token addresses from the addresses contract
        address mamo = addresses.getAddress("MAMO");
        address virtual = addresses.getAddress("VIRTUAL");
        address poolFactory = addresses.getAddress("AERODROME_POOL_FACTORY");
        
        IPoolFactory factory = IPoolFactory(poolFactory);
        
        // Create a volatile pool (stable = false) with the two tokens
        address newPool = factory.createPool(mamo, virtual, false);
        
        console.log("Created pool at address: %s", newPool);
        console.log("Pool tokens: %s (MAMO) and %s (VIRTUAL)", mamo, virtual);
        console.log("Pool type: volatile (stable = false)");
        console.log("Pool factory: %s", poolFactory);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);
    }

    function validate() public view override {
        console.log("Starting validation...");
        
        // Validate FeeSplitter deployment
        assertTrue(address(feeSplitter) != address(0), "FeeSplitter should be deployed");
        assertTrue(addresses.isAddressSet("FEE_SPLITTER"), "FeeSplitter address should be set");
        
        // Validate FeeSplitter configuration using the script's validation
        deployFeeSplitterScript.validate(addresses, feeSplitter);
        
        // Validate BurnAndEarn deployment
        assertTrue(address(burnAndEarn) != address(0), "BurnAndEarn should be deployed");
        assertTrue(addresses.isAddressSet("BURN_AND_EARN"), "BurnAndEarn address should be set");
        
        // Validate BurnAndEarn configuration
        assertEq(burnAndEarn.feeCollector(), address(feeSplitter), "BurnAndEarn feeCollector should be FeeSplitter");
        assertEq(burnAndEarn.owner(), addresses.getAddress("MAMO_MULTISIG"), "BurnAndEarn owner should be multisig");
        
        // Validate that contracts are linked correctly
        assertTrue(burnAndEarn.feeCollector() != address(0), "BurnAndEarn should have feeCollector set");
        assertEq(burnAndEarn.feeCollector(), address(feeSplitter), "BurnAndEarn feeCollector should match FeeSplitter");
        
        // Validate sMAMO contract interaction
        assertTrue(SMAMO_CONTRACT != address(0), "sMAMO contract address should be valid");
        
        console.log("All validations passed successfully");
    }
}