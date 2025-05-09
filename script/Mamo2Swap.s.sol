// SPDX-License-Identifier: BUSL-1.1
// NOTE: This script uses Solidity 0.8.28 to match the Mamo2.sol contract.
// When running this script, use: forge script script/Mamo2Swap.s.sol --use 0.8.28
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";
import {Script} from "@forge-std/Script.sol";
import {StdStyle} from "@forge-std/StdStyle.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MAMO2} from "@contracts/token/Mamo2.sol";
import {Script} from "@forge-std/Script.sol";
import {StdStyle} from "@forge-std/StdStyle.sol";
import {console} from "@forge-std/console.sol";
import {console} from "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/**
 * @title ISwapRouter
 * @notice Interface for the Uniswap V3 SwapRouter
 */

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams`
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams`
    /// @return amountIn The amount of the input token
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/**
 * @title IWETH9
 * @notice Interface for WETH9
 */
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address guy, uint256 wad) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title Mamo2SwapScript
 * @notice Script to perform swaps on the Uniswap V3 pool for the MAMO2 token
 */
contract Mamo2SwapScript is Script {
    // Uniswap V3 SwapRouter address on Base
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    // Pool fee (0.3%)
    uint24 constant POOL_FEE = 3000;

    // Default swap amount
    uint256 constant DEFAULT_SWAP_AMOUNT_ETH = 0.001 ether;
    uint256 constant DEFAULT_SWAP_AMOUNT_TOKENS = 1 * 1e18; // 1 token

    // Command line parameters
    uint256 ethAmount;
    uint256 tokenAmount;
    bool skipEthToToken;
    bool skipTokenToEth;

    function run() external {
        // Parse command line arguments
        ethAmount = vm.envOr("ETH_AMOUNT", DEFAULT_SWAP_AMOUNT_ETH);
        tokenAmount = vm.envOr("TOKEN_AMOUNT", DEFAULT_SWAP_AMOUNT_TOKENS);
        skipEthToToken = vm.envOr("SKIP_ETH_TO_TOKEN", false);
        skipTokenToEth = vm.envOr("SKIP_TOKEN_TO_ETH", false);
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        // Get the addresses of the MAMO2 token and WETH
        address mamo2 = addresses.getAddress("MAMO2_PROXY");
        address weth = addresses.getAddress("WETH");

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== MAMO2 SWAP OPERATIONS ===")));
        console.log("%s: %s", StdStyle.bold("MAMO2 Token"), StdStyle.yellow(vm.toString(mamo2)));
        console.log("%s: %s", StdStyle.bold("WETH"), StdStyle.yellow(vm.toString(weth)));
        console.log("%s: %s", StdStyle.bold("Swap Router"), StdStyle.yellow(vm.toString(SWAP_ROUTER)));
        console.log("%s: %s", StdStyle.bold("Pool Fee"), StdStyle.yellow(vm.toString(POOL_FEE)));
        console.log("%s: %s ETH", StdStyle.bold("ETH Amount"), StdStyle.yellow(vm.toString(ethAmount / 1e18)));
        console.log("%s: %s MAMO2", StdStyle.bold("Token Amount"), StdStyle.yellow(vm.toString(tokenAmount / 1e18)));

        // Perform exactInputSingle swap (ETH -> MAMO2)
        if (!skipEthToToken) {
            swapExactInputSingle(addresses, weth, mamo2, ethAmount);
        } else {
            console.log("\n%s", StdStyle.bold(StdStyle.yellow("Skipping ETH -> MAMO2 swap")));
        }

        // Perform exactOutputSingle swap (MAMO2 -> ETH)
        if (!skipTokenToEth) {
            swapExactOutputSingle(addresses, mamo2, weth, ethAmount / 2);
        } else {
            console.log("\n%s", StdStyle.bold(StdStyle.yellow("Skipping MAMO2 -> ETH swap")));
        }
    }

    /**
     * @notice Perform an exactInputSingle swap (swap exact amount of input token for as much output token as possible)
     * @param addresses The addresses contract
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountIn The exact amount of input token to swap
     */
    function swapExactInputSingle(Addresses addresses, address tokenIn, address tokenOut, uint256 amountIn) public {
        // Check sender balance before broadcast
        uint256 senderBalance = msg.sender.balance;
        console.log(
            "%s: %s ETH", StdStyle.bold("Initial sender balance"), StdStyle.yellow(vm.toString(senderBalance / 1e18))
        );

        // Fund the sender with enough ETH for the swap and gas fees
        uint256 fundAmount = amountIn + 0.1 ether; // Add extra for gas
        if (senderBalance < fundAmount) {
            console.log("%s", StdStyle.bold(StdStyle.green("Funding sender with ETH for swap and gas...")));
            vm.deal(msg.sender, fundAmount);
            console.log(
                "%s: %s ETH",
                StdStyle.bold("New sender balance"),
                StdStyle.yellow(vm.toString(msg.sender.balance / 1e18))
            );
        }

        vm.startBroadcast();

        console.log("\n%s", StdStyle.bold(StdStyle.green("Performing exactInputSingle swap...")));
        console.log("%s: %s", StdStyle.bold("Token In"), StdStyle.yellow(vm.getLabel(tokenIn)));
        console.log("%s: %s", StdStyle.bold("Token Out"), StdStyle.yellow(vm.getLabel(tokenOut)));
        console.log("%s: %s", StdStyle.bold("Amount In"), StdStyle.yellow(vm.toString(amountIn)));

        // If tokenIn is WETH, we need to wrap ETH first
        if (tokenIn == addresses.getAddress("WETH")) {
            // Check the ETH balance of both the script contract and the sender
            uint256 scriptBalance = address(this).balance;
            uint256 senderBalance = msg.sender.balance;

            console.log(
                "%s: %s ETH",
                StdStyle.bold("Script contract balance"),
                StdStyle.yellow(vm.toString(scriptBalance / 1e18))
            );

            console.log(
                "%s: %s ETH", StdStyle.bold("Sender balance"), StdStyle.yellow(vm.toString(senderBalance / 1e18))
            );

            console.log("%s: %s", StdStyle.bold("Script address"), StdStyle.yellow(vm.toString(address(this))));

            console.log("%s: %s", StdStyle.bold("Sender address"), StdStyle.yellow(vm.toString(msg.sender)));

            // Check if we have enough ETH
            if (scriptBalance < amountIn) {
                console.log(
                    "%s: %s ETH (required: %s ETH)",
                    StdStyle.bold(StdStyle.red("Insufficient ETH balance in script contract")),
                    StdStyle.yellow(vm.toString(scriptBalance / 1e18)),
                    StdStyle.yellow(vm.toString(amountIn / 1e18))
                );

                // Fund the script contract with ETH for testing purposes
                console.log("%s", StdStyle.bold(StdStyle.green("Funding script contract with ETH...")));
                vm.deal(address(this), amountIn);
                scriptBalance = address(this).balance;
                console.log(
                    "%s: %s ETH",
                    StdStyle.bold("New script contract balance"),
                    StdStyle.yellow(vm.toString(scriptBalance / 1e18))
                );
            }

            try IWETH9(tokenIn).deposit{value: amountIn}() {
                console.log("Successfully deposited ETH to WETH");
            } catch Error(string memory reason) {
                console.log("%s: %s", StdStyle.bold(StdStyle.red("Deposit failed")), reason);
                vm.stopBroadcast();
                return;
            } catch (bytes memory) {
                console.log(StdStyle.bold(StdStyle.red("Deposit failed with no reason")));
                vm.stopBroadcast();
                return;
            }
            console.log("Wrapped %s ETH to WETH", StdStyle.yellow(vm.toString(amountIn / 1e18)));
        } else {
            // Check if we have enough tokens
            uint256 tokenBalance = IERC20(tokenIn).balanceOf(address(this));
            if (tokenBalance < amountIn) {
                console.log(
                    "Insufficient token balance: %s %s (required: %s)",
                    vm.toString(tokenBalance / 1e18),
                    vm.getLabel(tokenIn),
                    vm.toString(amountIn / 1e18)
                );
                vm.stopBroadcast();
                return;
            }
        }

        // Approve the router to spend our tokens
        IERC20(tokenIn).approve(SWAP_ROUTER, amountIn);
        console.log(
            "Approved SwapRouter to spend %s %s", StdStyle.yellow(vm.toString(amountIn / 1e18)), vm.getLabel(tokenIn)
        );

        // Get the balance of tokenOut before the swap
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // Set up the parameters for the swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: amountIn,
            amountOutMinimum: 0, // No slippage protection for simplicity
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Execute the swap
        try ISwapRouter(SWAP_ROUTER).exactInputSingle(params) returns (uint256 amountOut) {
            console.log("Swap successful!");
            console.log("%s: %s", StdStyle.bold("Amount Out"), StdStyle.yellow(vm.toString(amountOut)));

            // Get the balance of tokenOut after the swap
            uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
            console.log(
                "Balance of %s increased by %s",
                vm.getLabel(tokenOut),
                StdStyle.yellow(vm.toString((balanceAfter - balanceBefore) / 1e18))
            );
        } catch Error(string memory reason) {
            console.log("%s: %s", StdStyle.bold(StdStyle.red("Swap failed")), reason);
        } catch (bytes memory) {
            console.log(StdStyle.bold(StdStyle.red("Swap failed with no reason")));
        }

        vm.stopBroadcast();
    }

    /**
     * @notice Perform an exactOutputSingle swap (swap as little input token as possible for an exact amount of output token)
     * @param addresses The addresses contract
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountOut The exact amount of output token to receive
     */
    function swapExactOutputSingle(Addresses addresses, address tokenIn, address tokenOut, uint256 amountOut) public {
        // Check sender balance before broadcast
        uint256 senderBalance = msg.sender.balance;
        console.log(
            "%s: %s ETH", StdStyle.bold("Initial sender balance"), StdStyle.yellow(vm.toString(senderBalance / 1e18))
        );

        // Fund the sender with enough ETH for gas fees
        uint256 fundAmount = 0.1 ether; // Add for gas
        if (senderBalance < fundAmount) {
            console.log("%s", StdStyle.bold(StdStyle.green("Funding sender with ETH for gas...")));
            vm.deal(msg.sender, fundAmount);
            console.log(
                "%s: %s ETH",
                StdStyle.bold("New sender balance"),
                StdStyle.yellow(vm.toString(msg.sender.balance / 1e18))
            );
        }

        vm.startBroadcast();

        console.log("\n%s", StdStyle.bold(StdStyle.green("Performing exactOutputSingle swap...")));
        console.log("%s: %s", StdStyle.bold("Token In"), StdStyle.yellow(vm.getLabel(tokenIn)));
        console.log("%s: %s", StdStyle.bold("Token Out"), StdStyle.yellow(vm.getLabel(tokenOut)));
        console.log("%s: %s", StdStyle.bold("Amount Out"), StdStyle.yellow(vm.toString(amountOut)));

        // Calculate a reasonable amountInMaximum (2x the expected amount for safety)
        uint256 amountInMaximum;
        if (tokenIn == addresses.getAddress("MAMO2_PROXY")) {
            amountInMaximum = tokenAmount * 2;
        } else {
            amountInMaximum = amountOut * 2; // 2x the output amount as a safe maximum
        }

        // Check if we have enough tokens
        uint256 tokenBalance = IERC20(tokenIn).balanceOf(address(this));
        if (tokenBalance < amountInMaximum) {
            vm.stopBroadcast();
            return;
        }

        // Approve the router to spend our tokens
        IERC20(tokenIn).approve(SWAP_ROUTER, amountInMaximum);
        console.log(
            "Approved SwapRouter to spend up to %s %s",
            StdStyle.yellow(vm.toString(amountInMaximum / 1e18)),
            vm.getLabel(tokenIn)
        );

        // Get the balance of tokenOut before the swap
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // Set up the parameters for the swap
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Execute the swap
        try ISwapRouter(SWAP_ROUTER).exactOutputSingle(params) returns (uint256 amountIn) {
            console.log("Swap successful!");
            console.log("%s: %s", StdStyle.bold("Amount In Used"), StdStyle.yellow(vm.toString(amountIn)));

            // Get the balance of tokenOut after the swap
            uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
            console.log(
                "Balance of %s increased by %s",
                vm.getLabel(tokenOut),
                StdStyle.yellow(vm.toString((balanceAfter - balanceBefore) / 1e18))
            );

            // If we have any unused input tokens, we can refund them
            if (amountIn < amountInMaximum) {
                console.log(
                    "Unused %s: %s",
                    vm.getLabel(tokenIn),
                    StdStyle.yellow(vm.toString((amountInMaximum - amountIn) / 1e18))
                );
            }

            // If tokenOut is WETH, we can unwrap it to ETH
            if (tokenOut == addresses.getAddress("WETH")) {
                uint256 wethBalance = IERC20(tokenOut).balanceOf(address(this));
                if (wethBalance > 0) {
                    try IWETH9(tokenOut).withdraw(wethBalance) {
                        console.log("Unwrapped %s WETH to ETH", StdStyle.yellow(vm.toString(wethBalance / 1e18)));
                    } catch Error(string memory reason) {
                        console.log("%s: %s", StdStyle.bold(StdStyle.red("Unwrap failed")), reason);
                    } catch (bytes memory) {
                        console.log(StdStyle.bold(StdStyle.red("Unwrap failed with no reason")));
                    }
                }
            }
        } catch Error(string memory reason) {
            console.log("%s: %s", StdStyle.bold(StdStyle.red("Swap failed")), reason);
        } catch (bytes memory) {
            console.log(StdStyle.bold(StdStyle.red("Swap failed with no reason")));
        }

        vm.stopBroadcast();
    }

    // Function to receive ETH when unwrapping WETH
    receive() external payable {}

    // Helper function to print usage instructions
    function printUsage() internal view {
        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("=== USAGE INSTRUCTIONS ===")));
        console.log("To specify custom amounts:");
        console.log("  ETH_AMOUNT=<amount in wei> forge script script/Mamo2Swap.s.sol --use 0.8.28 --fork-url base");
        console.log("  TOKEN_AMOUNT=<amount in wei> forge script script/Mamo2Swap.s.sol --use 0.8.28 --fork-url base");
        console.log("\nTo skip specific swaps:");
        console.log("  SKIP_ETH_TO_TOKEN=true forge script script/Mamo2Swap.s.sol --use 0.8.28 --fork-url base");
        console.log("  SKIP_TOKEN_TO_ETH=true forge script script/Mamo2Swap.s.sol --use 0.8.28 --fork-url base");
        console.log("\nTo run with a specific account:");
        console.log("  forge script script/Mamo2Swap.s.sol --use 0.8.28 --fork-url base --sender <address>");
    }
}
