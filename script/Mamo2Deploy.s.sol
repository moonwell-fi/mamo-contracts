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
        bytes memory initData =
            abi.encodeWithSelector(MAMO2.initialize.selector, "Mamo SuperERC20 Test", "MAMO_SUPER_ERC20_TEST", deployer);

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

        // Get the NonfungiblePositionManager address
        address positionManagerAddress = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER");

        console.log(
            "\n%s", StdStyle.bold(StdStyle.green("Step 5: Adding liquidity with NonfungiblePositionManager..."))
        );
        console.log("%s: %s", StdStyle.bold("Position Manager"), StdStyle.yellow(vm.toString(positionManagerAddress)));

        // Calculate the amounts to use for the position
        uint256 tokenAmount = INITIAL_LIQUIDITY_TOKENS * 10; // Increased token amount
        uint256 ethAmount = INITIAL_LIQUIDITY_ETH * 10; // Increased ETH amount

        // Approve tokens for the position manager - make sure to approve enough!
        IERC20(mamo2Proxy).approve(positionManagerAddress, tokenAmount);
        console.log("Approved %s MAMO2 tokens for position manager", StdStyle.yellow(vm.toString(tokenAmount / 1e18)));

        // Wrap ETH to WETH - make sure to deposit enough!
        IWETH9(wethAddress).deposit{value: ethAmount}();
        IWETH9(wethAddress).approve(positionManagerAddress, ethAmount);
        console.log("Wrapped and approved %s ETH for position manager", StdStyle.yellow(vm.toString(ethAmount / 1e18)));

        // Use a narrower tick range for the position
        // The tick spacing for 0.3% fee tier is 60, so ticks must be multiples of 60
        int24 tickLower = -60 * 10; // -600, narrower range
        int24 tickUpper = 60 * 10; // 600, narrower range

        console.log("%s: %s", StdStyle.bold("Tick Lower"), StdStyle.yellow(vm.toString(int256(tickLower))));
        console.log("%s: %s", StdStyle.bold("Tick Upper"), StdStyle.yellow(vm.toString(int256(tickUpper))));

        // For Uniswap V3, we need to be careful about slippage
        // Since we initialized the pool with a 1:1 price, we need to ensure our position matches

        // Set minimum amounts to 0 to avoid slippage errors
        uint256 minLiquidityAmount = 0; // Set to 0 to avoid slippage checks

        // Get the current price from the pool
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        console.log("%s: %s", StdStyle.bold("Current sqrtPriceX96"), StdStyle.yellow(vm.toString(sqrtPriceX96)));

        // Create the mint parameters with correct token order and adjusted amounts
        // For a 1:1 price with WETH (18 decimals) and MAMO2 (18 decimals), we need equal amounts
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0, // WETH
            token1: token1, // MAMO2
            fee: POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: token0 == mamo2Proxy ? tokenAmount : ethAmount,
            amount1Desired: token1 == mamo2Proxy ? tokenAmount : ethAmount,
            amount0Min: 0, // Set to 0 to avoid slippage checks
            amount1Min: 0, // Set to 0 to avoid slippage checks
            recipient: msg.sender,
            deadline: block.timestamp + 1 hours
        });

        // Check token balance before attempting to mint
        uint256 tokenBalance = IERC20(mamo2Proxy).balanceOf(msg.sender);
        console.log("%s: %s", StdStyle.bold("Current MAMO2 balance"), StdStyle.yellow(vm.toString(tokenBalance / 1e18)));

        // If we don't have enough tokens, transfer them from the deployer
        if (tokenBalance < tokenAmount) {
            console.log("\n%s", StdStyle.bold(StdStyle.yellow("Transferring tokens for liquidity...")));

            // Get the total supply to check if tokens were minted
            uint256 totalSupply = IERC20(mamo2Proxy).totalSupply();
            console.log("%s: %s", StdStyle.bold("Total MAMO2 supply"), StdStyle.yellow(vm.toString(totalSupply / 1e18)));

            IERC20(mamo2Proxy).transfer(msg.sender, tokenAmount);
            console.log("Transferred %s MAMO2 tokens for liquidity", StdStyle.yellow(vm.toString(tokenAmount / 1e18)));

            // Check the new balance
            tokenBalance = IERC20(mamo2Proxy).balanceOf(msg.sender);
            console.log("%s: %s", StdStyle.bold("New MAMO2 balance"), StdStyle.yellow(vm.toString(tokenBalance / 1e18)));
        }

        // Only proceed with minting if we have enough tokens
        if (tokenBalance >= tokenAmount) {
            INonfungiblePositionManager positionManager = INonfungiblePositionManager(positionManagerAddress);
            (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positionManager.mint(params);

            console.log("\n%s", StdStyle.bold(StdStyle.green("Step 6: Position minted successfully")));
            console.log("%s: %s", StdStyle.bold("NFT Token ID"), StdStyle.yellow(vm.toString(tokenId)));
            console.log("%s: %s", StdStyle.bold("Liquidity"), StdStyle.yellow(vm.toString(liquidity)));
            console.log("%s: %s", StdStyle.bold("Amount0 used"), StdStyle.yellow(vm.toString(amount0)));
            console.log("%s: %s", StdStyle.bold("Amount1 used"), StdStyle.yellow(vm.toString(amount1)));
        }

        vm.stopBroadcast();
    }
}
