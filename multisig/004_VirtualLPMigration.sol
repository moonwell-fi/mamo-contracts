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
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
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
    // Deployed contracts
    DeployFeeSplitter public immutable deployFeeSplitterScript;
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
            //        addresses.updateJson();
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
        console.log("[INFO] Starting VirtualLP Migration deployment...");

        // Step 1: Deploy FeeSplitter contract
        console.log("[INFO] Step 1: Deploying FeeSplitter...");
        FeeSplitter feeSplitter = deployFeeSplitterScript.deployFeeSplitter(addresses);

        // Step 2: Deploy BurnAndEarn contract with FeeSplitter as feeCollector
        console.log("[INFO] Step 2: Deploying BurnAndEarn...");
        deployBurnAndEarn(feeSplitter);

        console.log("[INFO] VirtualLP Migration deployment completed");
    }

    function preBuildMock() public override {
        // Mock timestamp to be after maturity to allow sMAMO withdrawal
        // TODO remove this
        vm.warp(block.timestamp + 10 * 365 days);
    }

    function deployBurnAndEarn(FeeSplitter feeSplitter) internal {
        vm.startBroadcast();

        address owner = addresses.getAddress("MAMO_MULTISIG");

        // Deploy BurnAndEarn with FeeSplitter as feeCollector and multisig as owner
        BurnAndEarn burnAndEarn = new BurnAndEarn(address(feeSplitter), owner);

        console.log("BurnAndEarn deployed at: %s", address(burnAndEarn));
        console.log("Fee collector set to: %s", address(feeSplitter));
        console.log("Owner set to: %s", owner);

        vm.stopBroadcast();

        // Add the address to the Addresses contract
        addresses.addAddress("BURN_AND_EARN_VIRTUAL_MAMO_LP", address(burnAndEarn), true);
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Step 3: Withdraw all tokens from sMAMO contract
        console.log("[INFO] Step 3: Withdrawing from sMAMO contract...");

        address smamoAddress = addresses.getAddress("VIRTUALS_sMAMO");
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        IAgentVeToken smamoContract = IAgentVeToken(smamoAddress);

        // Get the current balance of the multisig in sMAMO
        // Since we need to know the balance, we'll call withdraw with the full amount
        // The sMAMO contract should handle the balance check internally
        uint256 balance = IERC20(smamoAddress).balanceOf(multisig);

        // Withdraw all tokens from sMAMO
        smamoContract.withdraw(balance);
        console.log("[INFO] Withdrawn %s tokens from sMAMO", balance);

        // Check VIRTUAL token balance after withdrawal
        address virtualToken = addresses.getAddress("VIRTUAL");
        uint256 virtualBalance = IERC20(virtualToken).balanceOf(multisig);
        console.log("[INFO] VIRTUAL token balance after withdrawal: %s", virtualBalance);

        // Step 4: Mint LP position with the tokens
        console.log("[INFO] Step 4: Minting LP position with tokens...");

        // Get token addresses from the addresses contract
        address mamo = addresses.getAddress("MAMO");
        address positionManager = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");

        // Sort tokens (token0 < token1)
        (address token0, address token1) = mamo < virtualToken ? (mamo, virtualToken) : (virtualToken, mamo);

        INonfungiblePositionManager manager = INonfungiblePositionManager(positionManager);

        // Get token balances (assuming we have some tokens to provide liquidity)
        uint256 amount0Desired = IERC20(token0).balanceOf(multisig);
        uint256 amount1Desired = IERC20(token1).balanceOf(multisig);

        console.log("[INFO] Token0 (%s) balance: %s", token0, amount0Desired);
        console.log("[INFO] Token1 (%s) balance: %s", token1, amount1Desired);
        // Approve tokens for the position manager
        IERC20(token0).approve(positionManager, amount0Desired);
        IERC20(token1).approve(positionManager, amount1Desired);

        // Mint LP position with full range (for maximum liquidity coverage)
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: 200, // Standard tick spacing for 0.3% fee tier
            tickLower: -887220, // Min tick for full range
            tickUpper: 887220, // Max tick for full range
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0, // TODO
            amount1Min: 0, // TODO
            recipient: addresses.getAddress("FEE_SPLITTER"), // Send LP NFT to multisig
            deadline: block.timestamp + 3600, // 1 hour deadline
            sqrtPriceX96: 79228162514264337593543950336 // 1:1 price ratio (sqrt(1) * 2^96)
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = manager.mint(params);

        // Store the LP token ID for validation
        lpTokenId = tokenId;

        console.log("[INFO] Liquidity: %s", liquidity);
        console.log("[INFO] Amount0 used: %s", amount0);
        console.log("[INFO] Amount1 used: %s", amount1);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);
    }

    function validate() public view override {
        console.log("[INFO] Validating VirtualLP Migration...");
        // Validate FeeSplitter deployment
        address feeSplitterAddress = addresses.getAddress("FEE_SPLITTER");
        assertTrue(addresses.isAddressSet("FEE_SPLITTER"), "FeeSplitter address should be set");

        console.log("[INFO] Validating FeeSplitter...");
        // Validate FeeSplitter configuration using the script's validation
        FeeSplitter feeSplitter = FeeSplitter(feeSplitterAddress);
        deployFeeSplitterScript.validate(addresses, feeSplitter);

        console.log("[INFO] Validating BurnAndEarn...");
        // Validate BurnAndEarn deployment
        address burnAndEarnAddress = addresses.getAddress("BURN_AND_EARN_VIRTUAL_MAMO_LP");
        assertTrue(addresses.isAddressSet("BURN_AND_EARN_VIRTUAL_MAMO_LP"), "BurnAndEarn address should be set");

        console.log("[INFO] Validating BurnAndEarn configuration...");
        // Validate BurnAndEarn configuration
        BurnAndEarn burnAndEarn = BurnAndEarn(burnAndEarnAddress);
        assertEq(burnAndEarn.feeCollector(), feeSplitterAddress, "BurnAndEarn feeCollector should be FeeSplitter");
        assertEq(burnAndEarn.owner(), addresses.getAddress("MAMO_MULTISIG"), "BurnAndEarn owner should be multisig");

        console.log("[INFO] Validating that contracts are linked correctly...");
        // Validate that contracts are linked correctly
        assertEq(burnAndEarn.feeCollector(), feeSplitterAddress, "BurnAndEarn feeCollector should match FeeSplitter");

        console.log("[INFO] Validating that LP NFT was minted and transferred to FEE_SPLITTER...");
        // Validate that LP NFT was minted and transferred to multisig
        address positionManager = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
        address feeSplitter = addresses.getAddress("FEE_SPLITTER");

        IERC721 nftContract = IERC721(positionManager);
        address nftOwner = nftContract.ownerOf(lpTokenId);

        assertEq(nftOwner, multisig, "LP NFT should be owned by FEE_SPLITTER");

        console.log("[INFO] All validations passed successfully");
    }
}
