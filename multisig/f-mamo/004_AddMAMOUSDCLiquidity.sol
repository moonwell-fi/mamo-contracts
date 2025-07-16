// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {console} from "forge-std/console.sol";

import {BurnAndEarn} from "@contracts/BurnAndEarn.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

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

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IAgentVeToken {
    function withdraw(uint256 amount) external;
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address owner);
}

interface ICLFactory {
    function poolImplementation() external view returns (address);
}

interface IQuoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        int24 tier;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

struct PoolKey {
    address token0;
    address token1;
    int24 tickSpacing;
}

// This is a remediation for a foundry bug that is resetting storage variables between some cheatcodes uses (from the modifier)
// https://github.com/foundry-rs/foundry/issues/5739
contract Storage {
    uint256 public mamoAmountAddedInIncreaseLiquidity;
    uint256 public usdcAmountAddedInIncreaseLiquidity;
    uint256 public lpTokenId;

    function setMamoAmountAddedInIncreaseLiquidity(uint256 _mamoAmountAddedInIncreaseLiquidity) external {
        mamoAmountAddedInIncreaseLiquidity = _mamoAmountAddedInIncreaseLiquidity;
    }

    function setUsdcAmountAddedInIncreaseLiquidity(uint256 _usdcAmountAddedInIncreaseLiquidity) external {
        usdcAmountAddedInIncreaseLiquidity = _usdcAmountAddedInIncreaseLiquidity;
    }

    function setLpTokenId(uint256 _lpTokenId) external {
        lpTokenId = _lpTokenId;
    }
}

contract MamoLPMigration is MultisigProposal {
    Storage public migrationStorage;

    // Before balances for validation
    uint256 private usdcBalanceBefore;
    uint256 private mamoBalanceBefore;
    uint256 private poolUsdcBalanceBefore;
    uint256 private poolMamoBalanceBefore;

    uint256 constant MAMO_USDC_PRICE = 0.1616e6; // $0.1531 in 6 decimal USDC units
    uint256 private expectedUsdcAmount = 100_000 * 1e6;
    uint256 private expectedMamoAmount;

    constructor() {
        migrationStorage = new Storage();
        vm.makePersistent(address(migrationStorage));
        vm.label(address(migrationStorage), "DEV-MIGRATION-STORAGE");

        vm.label(0x678F431DA2aBb9B5726bbf5CCDbaEEBB60dA9813, "MAMO-USDC-CPOOl");
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

    function preBuildMock() public override {
        address multisig = addresses.getAddress("P-MAMO");
        address usdc = addresses.getAddress("USDC");
        address mamo = addresses.getAddress("MAMO");

        // Record multisig balances before migration
        usdcBalanceBefore = IERC20(usdc).balanceOf(multisig);
        mamoBalanceBefore = IERC20(mamo).balanceOf(multisig);

        // Calculate pool address and record pool balances before migration
        address poolAddress = getPoolAddress(usdc, mamo);
        poolUsdcBalanceBefore = IERC20(usdc).balanceOf(poolAddress);
        poolMamoBalanceBefore = IERC20(mamo).balanceOf(poolAddress);

        // calculate how much mamo we need that is equivalent to the expected usdc amount
        expectedMamoAmount = (expectedUsdcAmount / MAMO_USDC_PRICE) * 1e18;
    }

    function build() public override buildModifier(addresses.getAddress("P-MAMO")) {
        address usdc = addresses.getAddress("USDC");
        address mamo = addresses.getAddress("MAMO");

        // Token order: MAMO is token0, USDC is token1
        address token0 = mamo;
        address token1 = usdc;
        uint256 amount0Desired = expectedMamoAmount;
        uint256 amount1Desired = expectedUsdcAmount;

        console.log("expectedUsdcAmount", expectedUsdcAmount);
        console.log("expectedMamoAmount", expectedMamoAmount);

        address positionManager = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
        // Approve tokens for the position manager
        IERC20(token0).approve(positionManager, amount0Desired);
        IERC20(token1).approve(positionManager, amount1Desired);

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
            recipient: addresses.getAddress("BURN_AND_EARN"), // Send LP NFT to BURN_AND_EARN
            deadline: block.timestamp + 30 minutes, // 30 minutes deadline
            sqrtPriceX96: 0
        });

        INonfungiblePositionManager manager = INonfungiblePositionManager(positionManager);

        (uint256 lpTokenId,,,) = manager.mint(params);
        migrationStorage.setLpTokenId(lpTokenId);

        // Check for dust amounts after mint using multisig balances
        address multisig = addresses.getAddress("P-MAMO");
        uint256 usdcBalanceAfter = IERC20(usdc).balanceOf(multisig);

        console.log("USDC balance after:", usdcBalanceAfter);

        // If there's dust, add it to the position using increaseLiquidity
        if (usdcBalanceAfter > 0) {
            // Map dust amounts to token0/token1: MAMO is token0, USDC is token1
            uint256 token1Dust = usdcBalanceAfter;
            uint256 token0Dust = usdcBalanceAfter / MAMO_USDC_PRICE * 1e18;
            migrationStorage.setMamoAmountAddedInIncreaseLiquidity(token0Dust);
            migrationStorage.setUsdcAmountAddedInIncreaseLiquidity(token1Dust);

            // Approve the dust amounts
            IERC20(token0).approve(positionManager, token0Dust);
            IERC20(token1).approve(positionManager, token1Dust);
            INonfungiblePositionManager.IncreaseLiquidityParams memory increaseParams = INonfungiblePositionManager
                .IncreaseLiquidityParams({
                tokenId: lpTokenId,
                amount0Desired: token0Dust,
                amount1Desired: token1Dust,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 30 minutes
            });

            manager.increaseLiquidity(increaseParams);
        }
    }

    function simulate() public override {
        address multisig = addresses.getAddress("P-MAMO");
        _simulateActions(multisig);
    }

    function validate() public view override {
        BurnAndEarn burnAndEarn = BurnAndEarn(addresses.getAddress("BURN_AND_EARN"));
        assertEq(
            burnAndEarn.feeCollector(), addresses.getAddress("F-MAMO"), "BurnAndEarn feeCollector should be multisig"
        );
        assertEq(burnAndEarn.owner(), addresses.getAddress("F-MAMO"), "BurnAndEarn owner should be multisig");

        // Validate NFT ownership
        address positionManager = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
        address burnAndEarnAddr = addresses.getAddress("BURN_AND_EARN");
        IERC721 nftContract = IERC721(positionManager);
        uint256 lpTokenId = migrationStorage.lpTokenId();
        address nftOwner = nftContract.ownerOf(lpTokenId);
        assertEq(nftOwner, burnAndEarnAddr, "LP NFT should be owned by BURN_AND_EARN");

        // Validate that the pool was created during the mint operation
        address usdc = addresses.getAddress("USDC");
        address mamo = addresses.getAddress("MAMO");
        address calculatedPoolAddress = getPoolAddress(usdc, mamo);

        // Check if the calculated pool address is a contract
        uint256 poolCodeSize;
        assembly {
            poolCodeSize := extcodesize(calculatedPoolAddress)
        }
        assertTrue(poolCodeSize > 0, "Pool code size should be greater than 0");

        // Validate that the exact amounts from removeLiquidity were deposited into the pool
        address multisig = addresses.getAddress("P-MAMO");
        address poolAddress = getPoolAddress(usdc, mamo);

        // Check current balances
        uint256 usdcBalanceAfter = IERC20(usdc).balanceOf(multisig);
        uint256 mamoBalanceAfter = IERC20(mamo).balanceOf(multisig);
        uint256 poolUsdcBalanceAfter = IERC20(usdc).balanceOf(poolAddress);
        uint256 poolMamoBalanceAfter = IERC20(mamo).balanceOf(poolAddress);

        // Validate that the pool received tokens (main goal of the migration)
        assertTrue(poolMamoBalanceAfter >= poolMamoBalanceBefore, "Pool MAMO balance should increase");
        assertTrue(poolUsdcBalanceAfter >= poolUsdcBalanceBefore, "Pool USDC balance should increase");

        assertApproxEqRel(
            poolMamoBalanceAfter - poolMamoBalanceBefore,
            expectedMamoAmount,
            0.02e18, // 1%
            "Pool MAMO balance should match expected amount"
        );

        assertApproxEqRel(
            poolUsdcBalanceAfter - poolUsdcBalanceBefore,
            expectedUsdcAmount,
            0.01e18, // 1%
            "Pool USDC balance should match expected amount"
        );

        assertApproxEqRel(
            mamoBalanceBefore - mamoBalanceAfter,
            expectedMamoAmount + migrationStorage.mamoAmountAddedInIncreaseLiquidity(),
            0.02e18, // 2%
            "Multisig MAMO balance should match before amount"
        );

        assertApproxEqRel(
            usdcBalanceBefore - usdcBalanceAfter,
            expectedUsdcAmount + migrationStorage.usdcAmountAddedInIncreaseLiquidity(),
            0.01e18, // 1%
            "Multisig USDC balance should match before amount"
        );

        // log how much usdc was left in the multisig
        console.log("USDC left in multisig", usdcBalanceAfter);
        // usdc amount added in the pool
        console.log("USDC amount added in the pool", (poolUsdcBalanceAfter - poolUsdcBalanceBefore) / 1e6);
        // mamo amount added in the pool
        console.log("MAMO amount added in the pool", (poolMamoBalanceAfter - poolMamoBalanceBefore) / 1e18);
    }

    function getPoolKey(address tokenA, address tokenB, int24 tickSpacing) internal pure returns (PoolKey memory) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, tickSpacing: tickSpacing});
    }

    function computeAddress(address factory, PoolKey memory key) internal view returns (address pool) {
        require(key.token0 < key.token1);
        pool = Clones.predictDeterministicAddress(
            ICLFactory(factory).poolImplementation(),
            keccak256(abi.encode(key.token0, key.token1, key.tickSpacing)),
            factory
        );
    }

    function getPoolAddress(address tokenA, address tokenB) internal view returns (address) {
        address factory = addresses.getAddress("AERODROME_CL_FACTORY");
        int24 tickSpacing = 200; // Same tick spacing used in mint
        PoolKey memory key = getPoolKey(tokenA, tokenB, tickSpacing);
        return computeAddress(factory, key);
    }
}
