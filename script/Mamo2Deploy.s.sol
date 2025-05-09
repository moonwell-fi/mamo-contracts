// SPDX-License-Identifier: BUSL-1.1
// NOTE: This script uses Solidity 0.8.28 to match the Mamo2.sol contract.
// When running this script, use: forge script script/Mamo2Deploy.s.sol --use 0.8.28
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MAMO2} from "@contracts/token/Mamo2.sol";
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
 * @title Mamo2DeployScript
 * @notice Script to deploy the Mamo2 token, create a Uniswap liquidity pool, and configure approvals
 */
contract Mamo2DeployScript is Script {
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

        // Deploy the Mamo2 token
        (MAMO2 mamo2Implementation, address mamo2Proxy) = deployMamo2(addresses);

        // Create Uniswap liquidity pool and configure approvals
        createLiquidityPool(addresses, mamo2Proxy);

        // Update the JSON file with all the new addresses
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== MAMO2 DEPLOYMENT COMPLETE ===")));
        console.log(
            "%s: %s", StdStyle.bold("Mamo2 implementation"), StdStyle.yellow(vm.toString(address(mamo2Implementation)))
        );
        console.log("%s: %s", StdStyle.bold("Mamo2 proxy"), StdStyle.yellow(vm.toString(mamo2Proxy)));
    }

    /**
     * @notice Deploy the Mamo2 token implementation and proxy
     * @param addresses The addresses contract
     * @return mamo2Implementation The Mamo2 implementation contract
     * @return mamo2Proxy The Mamo2 proxy address
     */
    function deployMamo2(Addresses addresses) public returns (MAMO2 mamo2Implementation, address mamo2Proxy) {
        vm.startBroadcast();

        // Deploy the Mamo2 implementation
        mamo2Implementation = new MAMO2();
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Deploying Mamo2 implementation...")));
        console.log("Mamo2 implementation deployed at: %s", StdStyle.yellow(vm.toString(address(mamo2Implementation))));

        // Get the deployer address (msg.sender)
        address deployer = msg.sender;

        // Prepare initialization data for the proxy
        bytes memory initData = abi.encodeWithSelector(MAMO2.initialize.selector, "Mamo Token V2", "MAMO2", deployer);

        // Deploy the proxy with the implementation and initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(address(mamo2Implementation), initData);
        mamo2Proxy = address(proxy);
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 2: Deploying and initializing Mamo2 proxy...")));
        console.log("Mamo2 proxy deployed and initialized at: %s", StdStyle.yellow(vm.toString(mamo2Proxy)));

        vm.stopBroadcast();

        // Add the addresses to the Addresses contract
        if (addresses.isAddressSet("MAMO2_IMPLEMENTATION")) {
            addresses.changeAddress("MAMO2_IMPLEMENTATION", address(mamo2Implementation), true);
        } else {
            addresses.addAddress("MAMO2_IMPLEMENTATION", address(mamo2Implementation), true);
        }

        if (addresses.isAddressSet("MAMO2_PROXY")) {
            addresses.changeAddress("MAMO2_PROXY", mamo2Proxy, true);
        } else {
            addresses.addAddress("MAMO2_PROXY", mamo2Proxy, true);
        }

        return (mamo2Implementation, mamo2Proxy);
    }

    /**
     * @notice Create a Uniswap liquidity pool for the Mamo2 token and ETH
     * @param addresses The addresses contract
     * @param mamo2Proxy The Mamo2 proxy address
     */
    function createLiquidityPool(Addresses addresses, address mamo2Proxy) public {
        vm.startBroadcast();

        // Get or add the Uniswap V3 Factory address
        address uniswapV3FactoryAddress;
        if (addresses.isAddressSet("UNISWAP_V3_FACTORY")) {
            uniswapV3FactoryAddress = addresses.getAddress("UNISWAP_V3_FACTORY");
        } else {
            // Use the hardcoded Uniswap V3 Factory address
            uniswapV3FactoryAddress = UNISWAP_V3_FACTORY;
            addresses.addAddress("UNISWAP_V3_FACTORY", uniswapV3FactoryAddress, true);
        }

        // Get or add the WETH address
        address wethAddress = addresses.getAddress("WETH");

        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 3: Creating Uniswap V3 pool...")));
        console.log("%s: %s", StdStyle.bold("Pool Fee"), StdStyle.yellow(vm.toString(POOL_FEE)));

        // Create the pool if it doesn't exist
        IUniswapV3Factory factory = IUniswapV3Factory(uniswapV3FactoryAddress);
        address pool = factory.getPool(mamo2Proxy, wethAddress, POOL_FEE);

        if (pool == address(0)) {
            pool = factory.createPool(mamo2Proxy, wethAddress, POOL_FEE);
            console.log("%s: %s", StdStyle.bold("Created new Uniswap V3 pool"), StdStyle.yellow(vm.toString(pool)));
        } else {
            console.log("%s: %s", StdStyle.bold("Existing Uniswap V3 pool found"), StdStyle.yellow(vm.toString(pool)));
        }

        // Add the pool address to the Addresses contract
        if (addresses.isAddressSet("MAMO2_ETH_POOL")) {
            addresses.changeAddress("MAMO2_ETH_POOL", pool, true);
        } else {
            addresses.addAddress("MAMO2_ETH_POOL", pool, true);
        }

        // Initialize the pool with a starting price
        IUniswapV3Pool uniswapPool = IUniswapV3Pool(pool);

        // Check token order (token0 should be the one with the lower address)
        address token0 = uniswapPool.token0();
        address token1 = uniswapPool.token1();

        console.log("%s: %s", StdStyle.bold("Token0"), StdStyle.yellow(vm.getLabel(token0)));
        console.log("%s: %s", StdStyle.bold("Token1"), StdStyle.yellow(vm.getLabel(token1)));

        // Calculate the initial price (1:1 for simplicity)
        // For Uniswap V3, we need to provide the square root of the price as a Q64.96 fixed point number
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceX96(1e18);

        // Initialize the pool with the calculated price
        uniswapPool.initialize(sqrtPriceX96);
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 4: Initializing Uniswap V3 pool...")));
        console.log("%s: %s", StdStyle.bold("Initial sqrtPriceX96"), StdStyle.yellow(vm.toString(sqrtPriceX96)));

        // Approve tokens for future liquidity provision
        IERC20(mamo2Proxy).approve(wethAddress, INITIAL_LIQUIDITY_TOKENS);
        console.log(
            "Approved %s MAMO2 tokens for future liquidity provision",
            StdStyle.yellow(vm.toString(INITIAL_LIQUIDITY_TOKENS / 1e18))
        );
        console.log(
            "Prepared for minimal liquidity: %s ETH", StdStyle.yellow(vm.toString(INITIAL_LIQUIDITY_ETH / 1e18))
        );

        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 5: Pool initialization complete")));
        console.log("%s", StdStyle.bold("To add liquidity to this pool:"));
        console.log("  1. Use the NonfungiblePositionManager to mint a position");
        console.log("  2. Specify your desired price range and amount of tokens");

        vm.stopBroadcast();
    }
}
