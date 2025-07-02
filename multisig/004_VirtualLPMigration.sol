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

interface IUniswapV2Pair {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV2Router {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address owner);
}

contract VirtualLPMigration is MultisigProposal {
    // Deployed contracts
    DeployFeeSplitter public immutable deployFeeSplitterScript;
    uint256 private lpTokenId;

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

        // Withdraw all LP tokens from sMAMO (these are Uniswap V2 LP tokens)
        smamoContract.withdraw(balance);
        console.log("[INFO] Withdrawn %s V2 LP tokens from sMAMO", balance);

        // Step 3.5: Break down V2 LP tokens to get underlying VIRTUAL and MAMO tokens
        console.log("[INFO] Step 3.5: Breaking down V2 LP tokens...");

        address virtualToken = addresses.getAddress("VIRTUAL");
        address mamo = addresses.getAddress("MAMO");
        address v2Router = addresses.getAddress("UNISWAP_V2_ROUTER"); // Need to add this address
        address v2Pair = addresses.getAddress("VIRTUAL_MAMO_V2_PAIR"); // Need to add this address

        // Get the V2 LP token balance (should be what we just withdrew)
        uint256 v2LpBalance = IERC20(v2Pair).balanceOf(multisig);
        console.log("[INFO] V2 LP token balance: %s", v2LpBalance);

        // Approve the router to spend our LP tokens
        IERC20(v2Pair).approve(v2Router, v2LpBalance);

        // Remove liquidity from V2 pair to get underlying tokens
        IUniswapV2Router router = IUniswapV2Router(v2Router);
        (uint256 amountVirtual, uint256 amountMamo) = router.removeLiquidity(
            virtualToken,
            mamo,
            v2LpBalance,
            0, // Accept any amount of VIRTUAL
            0, // Accept any amount of MAMO
            multisig,
            block.timestamp + 3600
        );

        console.log("[INFO] Removed liquidity - VIRTUAL: %s, MAMO: %s", amountVirtual, amountMamo);

        // Step 4: Mint LP position with the tokens
        console.log("[INFO] Step 4: Minting LP position with tokens...");

        // Get position manager address
        address positionManager = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");

        INonfungiblePositionManager manager = INonfungiblePositionManager(positionManager);

        // Get token balances from multisig
        uint256 virtualBalance = IERC20(virtualToken).balanceOf(multisig);
        uint256 mamoBalance = IERC20(mamo).balanceOf(multisig);

        console.log("[INFO] VIRTUAL balance: %s", virtualBalance);
        console.log("[INFO] MAMO balance: %s", mamoBalance);
        // Determine token order (token0 must be < token1 in Uniswap V3)
        address token0 = virtualToken < mamo ? virtualToken : mamo;
        address token1 = virtualToken < mamo ? mamo : virtualToken;
        uint256 amount0Desired = virtualToken < mamo ? virtualBalance : mamoBalance;
        uint256 amount1Desired = virtualToken < mamo ? mamoBalance : virtualBalance;

        // Approve tokens for the position manager
        IERC20(token0).approve(positionManager, amount0Desired);
        IERC20(token1).approve(positionManager, amount1Desired);

        // Get current market price from V2 pair using the correct token order
        uint160 currentSqrtPriceX96 = getCurrentSqrtPriceX96(token0, token1, v2Pair);
        console.log("[INFO] Current sqrtPriceX96: %s", currentSqrtPriceX96);

        // Mint LP position with full range (for maximum liquidity coverage)
        // Use tick spacing 200 because it's the volatile token tick spacing recommended by Aerodrome
        int24 tickSpacing = 200;
        int24 tickLower = -887200; // Closest valid tick to min (-887220 rounded to multiple of 200)
        int24 tickUpper = 887200; // Closest valid tick to max (887220 rounded to multiple of 200)

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0, // Allow slippage since this might be initial liquidity
            amount1Min: 0, // Allow slippage since this might be initial liquidity
            recipient: addresses.getAddress("FEE_SPLITTER"), // Send LP NFT to FEE_SPLITTER
            deadline: block.timestamp + 30 minutes, // 30 minutes deadline
            sqrtPriceX96: currentSqrtPriceX96 // Current market price from V2 pair
        });

        (lpTokenId,,,) = manager.mint(params);

        console.log("[INFO] LP token ID: %s", lpTokenId);

        // Validate NFT ownership immediately after minting
        // This is a remediation for storage variable reset between foundry bug that is reseting storage variables
        // https://github.com/foundry-rs/foundry/issues/5739
        address feeSplitterAddr = addresses.getAddress("FEE_SPLITTER");
        IERC721 nftContract = IERC721(positionManager);
        address nftOwner = nftContract.ownerOf(lpTokenId);
        assertEq(nftOwner, feeSplitterAddr, "LP NFT should be owned by FEE_SPLITTER");
        console.log("[INFO] LP NFT ownership validated - owned by FEE_SPLITTER");
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

        console.log("[INFO] LP NFT ownership validation completed during build phase");

        console.log("[INFO] All validations passed successfully");
    }

    function getCurrentSqrtPriceX96(address token0, address token1, address pairAddress)
        internal
        view
        returns (uint160)
    {
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        // Get the pair's token0 and token1 to determine order
        address pairToken0 = pair.token0();
        address pairToken1 = pair.token1();

        uint256 price; // price = reserve1 / reserve0 (token1 per token0)

        // Determine the correct reserve order based on our token order
        if (token0 == pairToken0 && token1 == pairToken1) {
            // Our order matches pair order: price = reserve1 / reserve0
            price = (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else if (token0 == pairToken1 && token1 == pairToken0) {
            // Our order is reversed from pair order: price = reserve0 / reserve1
            price = (uint256(reserve0) * 1e18) / uint256(reserve1);
        } else {
            revert("Token pair mismatch");
        }

        // Calculate sqrtPriceX96 = sqrt(price) * 2^96
        // We need to be careful with precision here
        uint256 sqrtPrice = sqrt(price * 1e18); // sqrt of price with extra precision
        uint160 sqrtPriceX96 = uint160((sqrtPrice * (2 ** 96)) / 1e18);

        return sqrtPriceX96;
    }

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
