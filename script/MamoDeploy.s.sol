// SPDX-License-Identifier: BUSL-1.1
// NOTE: This script uses Solidity 0.8.28 to match the Mamo.sol contract.
// When running this script, use: forge script script/MamoDeploy.s.sol --use 0.8.28
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";

import {MAMO} from "@contracts/token/Mamo.sol";
import {Script} from "@forge-std/Script.sol";
import {StdStyle} from "@forge-std/StdStyle.sol";
import {console} from "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Uniswap V3 interfaces
interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

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
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address guy, uint256 wad) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Library for price calculations
library TickMath {
    // The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    // The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // Helper function to calculate sqrtPriceX96 from price
    function getSqrtPriceX96(uint256 price) internal pure returns (uint160) {
        // Calculate sqrtPriceX96 for a 1:1 price ratio
        uint256 sqrtPrice = sqrt(price * (1 << 192));
        require(sqrtPrice >= MIN_SQRT_RATIO && sqrtPrice <= MAX_SQRT_RATIO, "Price out of range");
        return uint160(sqrtPrice);
    }

    // Simple square root function
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

/**
 * @title MamoDeployScript
 * @notice Script to deploy the Mamo token, create a Uniswap liquidity pool, and configure approvals
 */
contract MamoDeployScript is Script {
    // Uniswap V3 Factory address on Base
    address constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    // WETH address on Base
    address constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006;

    // Pool fee (0.3%)
    uint24 constant POOL_FEE = 3000;

    // Initial liquidity parameters
    uint256 constant INITIAL_LIQUIDITY_TOKENS = 100 * 1e18; // 100 tokens
    uint256 constant INITIAL_LIQUIDITY_ETH = 0.0001 ether; // 0.0001 ETH

    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy the Mamo token
        MAMO mamo = deployMamo(addresses);

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== MAMO DEPLOYMENT COMPLETE ===")));
        console.log("%s: %s", StdStyle.bold("Mamo contract"), StdStyle.yellow(vm.toString(address(mamo))));
    }

    /**
     * @notice Deploy the Mamo token contract (non-upgradeable)
     * @param addresses The addresses contract
     * @return mamo The deployed MAMO contract
     */
    function deployMamo(Addresses addresses) public returns (MAMO mamo) {
        vm.startBroadcast();

        address recipient = addresses.getAddress("MAMO_MULTISIG");

        // Deploy the Mamo2 contract directly with constructor parameters
        mamo = new MAMO("Mamo", "MAMO", recipient);
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Deploying Mamo contract...")));
        console.log("Mamo contract deployed at: %s", StdStyle.yellow(vm.toString(address(mamo))));

        vm.stopBroadcast();

        // Add the address to the Addresses contract
        if (addresses.isAddressSet("MAMO")) {
            addresses.changeAddress("MAMO", address(mamo), true);
        } else {
            addresses.addAddress("MAMO", address(mamo), true);
        }

        return mamo;
    }
}
