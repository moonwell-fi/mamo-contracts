// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BurnAndEarn} from "@contracts/BurnAndEarn.sol";
import {FeeSplitter} from "@contracts/FeeSplitter.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {DeployFeeSplitter} from "@script/DeployFeeSplitter.s.sol";

import {console} from "forge-std/console.sol";

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IAgentVeToken {
    function withdraw(uint256 amount) external;
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address owner);
}

contract VirtualLPMigration is MultisigProposal {
    // sMAMO contract address
    address public constant SMAMO_CONTRACT = 0x022b91ed8e85ae7cd5348f1ddaafaa3350842ef3;
    
    // Deployed contracts
    DeployFeeSplitter public immutable deployFeeSplitterScript;
    FeeSplitter public feeSplitter;
    BurnAndEarn public burnAndEarn;
    uint256 public lpTokenId;

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
        return "Deploy FeeSplitter and BurnAndEarn contracts, withdraw from sMAMO, and mint LP position";
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
        
            // Withdraw all tokens from sMAMO
            smamoContract.withdraw(balance);
            console.log("Withdrawn %s tokens from sMAMO", balance);
        
        // Step 4: Mint LP position with the tokens
        console.log("Step 4: Minting LP position with tokens...");
        
        // Get token addresses from the addresses contract
        address mamo = addresses.getAddress("MAMO");
        address virtual = addresses.getAddress("VIRTUAL");
        address positionManager = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
        
        // Sort tokens (token0 < token1)
        (address token0, address token1) = mamo < virtual ? (mamo, virtual) : (virtual, mamo);
        
        INonfungiblePositionManager manager = INonfungiblePositionManager(positionManager);
        
        // Get token balances (assuming we have some tokens to provide liquidity)
        uint256 amount0Desired = IERC20(token0).balanceOf(address(this));
        uint256 amount1Desired = IERC20(token1).balanceOf(address(this));
            // Approve tokens for the position manager
            IERC20(token0).approve(positionManager, amount0Desired);
            IERC20(token1).approve(positionManager, amount1Desired);
            
            // Mint LP position with full range (for maximum liquidity coverage)
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: 3000, // 0.3% fee tier
                tickLower: -887220, // Min tick for full range
                tickUpper: 887220,  // Max tick for full range
                amount0Desired: amount0Desired          ,
                amount1Desired: amount1Desired,
                amount0Min: amount0Desired, // Exact amount of token0 (new pool)
                amount1Min: amount1Desired, // Exact amount of token1 (new pool)
                recipient: addresses.getAddress("MAMO_MULTISIG"), // Send LP NFT to multisig
                deadline: block.timestamp + 3600 // 1 hour deadline
            });
            
            (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = manager.mint(params);
            
            // Store the LP token ID for validation
            lpTokenId = tokenId;
            
            console.log("Minted LP position with tokenId: %s", tokenId);
            console.log("Liquidity: %s", liquidity);
            console.log("Amount0 used: %s", amount0);
            console.log("Amount1 used: %s", amount1);
            console.log("LP NFT sent to: %s", addresses.getAddress("MAMO_MULTISIG"));
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);
    }

    function validate() public view override {
        
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
        
        // Validate that LP NFT was minted and transferred to multisig
            address positionManager = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
            address multisig = addresses.getAddress("MAMO_MULTISIG");
            
            IERC721 nftContract = IERC721(positionManager);
            address nftOwner = nftContract.ownerOf(lpTokenId);
            
            assertEq(nftOwner, multisig, "LP NFT should be owned by multisig");
        
        console.log("All validations passed successfully");
    }
}