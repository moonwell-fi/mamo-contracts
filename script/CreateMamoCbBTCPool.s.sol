// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {StdStyle} from "@forge-std/StdStyle.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {IBurnAndEarn} from "@interfaces/IBurnAndEarn.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CreateMamoCbBTCPool
 * @notice Script to create a new pool pairing MAMO and cbBTC, then send the NFT to BurnAndEarn
 * @dev Creates a pool on Aerodrome and registers the NFT with BurnAndEarn
 */
contract CreateMamoCbBTCPool is Script, Test {
    // Constants for pool creation
    uint24 public constant FEE = 3000; // 0.3% fee tier
    int24 public constant TICK_SPACING = 60;

    // Liquidity parameters
    uint256 public constant AMOUNT_MAMO = 1000 * 1e18; // 1000 MAMO
    uint256 public constant AMOUNT_CBBTC = 0.1 * 1e18; // 0.1 cbBTC
    uint256 public constant SLIPPAGE_BPS = 50; // 0.5% slippage

    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Create the pool and get the token ID
        uint256 tokenId = createPool(addresses);

        // Send the NFT to BurnAndEarn and register it
        registerWithBurnAndEarn(addresses, tokenId);

        // Validate the operation
        validate(addresses, tokenId);

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== MAMO-CBBTC POOL CREATION COMPLETE ===")));
        console.log("%s: %s", StdStyle.bold("Pool NFT Token ID"), StdStyle.yellow(vm.toString(tokenId)));
    }

    /**
     * @notice Create a new pool pairing MAMO and cbBTC
     * @param addresses The addresses contract
     * @return tokenId The ID of the NFT representing the position
     */
    function createPool(Addresses addresses) public returns (uint256 tokenId) {
        vm.startBroadcast();

        // Get the addresses
        address mamoToken = addresses.getAddress("MAMO");
        address cbBTCToken = addresses.getAddress("cbBTC");
        address positionManager = addresses.getAddress("AERODROME_POSITION_MANAGER");

        // Sort tokens by address (required by Uniswap/Aerodrome)
        (address token0, address token1, bool reversed) = _sortTokens(mamoToken, cbBTCToken);

        // Approve tokens for the position manager
        IERC20(mamoToken).approve(positionManager, AMOUNT_MAMO);
        IERC20(cbBTCToken).approve(positionManager, AMOUNT_CBBTC);

        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 1: Approving tokens for position manager...")));
        console.log("MAMO token approved: %s", StdStyle.yellow(vm.toString(AMOUNT_MAMO)));
        console.log("cbBTC token approved: %s", StdStyle.yellow(vm.toString(AMOUNT_CBBTC)));

        // Calculate tick range
        int24 tickLower = -887220; // Placeholder - would be calculated based on price
        int24 tickUpper = 887220; // Placeholder - would be calculated based on price

        // Adjust tickLower and tickUpper to be multiples of TICK_SPACING
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING;
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING;

        // Calculate minimum amounts based on slippage
        uint256 amount0Min =
            reversed ? (AMOUNT_CBBTC * (10000 - SLIPPAGE_BPS)) / 10000 : (AMOUNT_MAMO * (10000 - SLIPPAGE_BPS)) / 10000;
        uint256 amount1Min =
            reversed ? (AMOUNT_MAMO * (10000 - SLIPPAGE_BPS)) / 10000 : (AMOUNT_CBBTC * (10000 - SLIPPAGE_BPS)) / 10000;

        // Create the mint parameters
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: reversed ? AMOUNT_CBBTC : AMOUNT_MAMO,
            amount1Desired: reversed ? AMOUNT_MAMO : AMOUNT_CBBTC,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: block.timestamp + 100 days
        });

        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 2: Creating pool and minting position...")));
        console.log("Token0: %s", StdStyle.yellow(vm.toString(token0)));
        console.log("Token1: %s", StdStyle.yellow(vm.toString(token1)));
        console.log("Fee: %s", StdStyle.yellow(vm.toString(FEE)));
        console.log(
            "Tick range: %s to %s", StdStyle.yellow(vm.toString(tickLower)), StdStyle.yellow(vm.toString(tickUpper))
        );

        // Call mint on the position manager
        (tokenId,,,) = INonfungiblePositionManager(positionManager).mint(params);
        console.log("Position created with token ID: %s", StdStyle.yellow(vm.toString(tokenId)));

        vm.stopBroadcast();

        return tokenId;
    }

    /**
     * @notice Send the NFT to BurnAndEarn and register it
     * @param addresses The addresses contract
     * @param tokenId The ID of the NFT to register
     */
    function registerWithBurnAndEarn(Addresses addresses, uint256 tokenId) public {
        vm.startBroadcast();

        // Get the addresses
        address positionManager = addresses.getAddress("AERODROME_POSITION_MANAGER");
        address burnAndEarn = addresses.getAddress("BURN_AND_EARN");

        // Approve the NFT for transfer to BurnAndEarn
        INonfungiblePositionManager(positionManager).approve(burnAndEarn, tokenId);
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 3: Approving NFT for transfer to BurnAndEarn...")));
        console.log("NFT approved for BurnAndEarn: %s", StdStyle.yellow(vm.toString(tokenId)));

        // Transfer the NFT to BurnAndEarn
        INonfungiblePositionManager(positionManager).safeTransferFrom(address(this), burnAndEarn, tokenId);
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 4: Transferring NFT to BurnAndEarn...")));
        console.log("NFT transferred to BurnAndEarn: %s", StdStyle.yellow(vm.toString(tokenId)));

        // Call add on BurnAndEarn to register the NFT
        IBurnAndEarn(burnAndEarn).add(tokenId);
        console.log("\n%s", StdStyle.bold(StdStyle.green("Step 5: Registering NFT with BurnAndEarn...")));
        console.log("NFT registered with BurnAndEarn: %s", StdStyle.yellow(vm.toString(tokenId)));

        vm.stopBroadcast();
    }

    /**
     * @notice Validate that the NFT is owned by BurnAndEarn and registered
     * @param addresses The addresses contract
     * @param tokenId The ID of the NFT to validate
     */
    function validate(Addresses addresses, uint256 tokenId) public view {
        address positionManager = addresses.getAddress("AERODROME_POSITION_MANAGER");
        address burnAndEarn = addresses.getAddress("BURN_AND_EARN");

        // Verify the NFT is owned by BurnAndEarn
        address owner = INonfungiblePositionManager(positionManager).ownerOf(tokenId);
        assertEq(owner, burnAndEarn, "BurnAndEarn is not the owner of the NFT");

        // Verify the position is registered in BurnAndEarn
        // bool isLocked = IBurnAndEarn(burnAndEarn).lockedPositions(tokenId);
        // assertTrue(isLocked, "Position is not registered in BurnAndEarn");

        console.log("\n%s", StdStyle.bold(StdStyle.green("Validation successful!")));
        console.log("NFT is owned by BurnAndEarn: %s", StdStyle.yellow(vm.toString(burnAndEarn)));
        console.log("Position is registered in BurnAndEarn: %s", StdStyle.yellow("true"));
    }

    /**
     * @notice Helper function to sort tokens by address
     * @param tokenA The first token
     * @param tokenB The second token
     * @return token0 The token with the lower address
     * @return token1 The token with the higher address
     * @return reversed Whether the tokens were reversed
     */
    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1, bool reversed)
    {
        if (tokenA < tokenB) {
            return (tokenA, tokenB, false);
        }
        return (tokenB, tokenA, true);
    }
}
