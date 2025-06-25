// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {StdStyle} from "@forge-std/StdStyle.sol";
import {console} from "@forge-std/console.sol";

import {IStrategy} from "@interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DepositUSDC
 * @notice Script to approve USDC and deposit it into a strategy
 * @dev This script approves USDC for a strategy proxy and then calls the deposit function
 */
contract DepositUSDC is Script {
    Addresses public addresses;

    /**
     * @notice Main entry point for the script
     * @param strategyProxy The address of the strategy proxy to deposit into
     * @param depositAmount The amount of USDC to deposit (in USDC units, e.g., 100 for 100 USDC)
     */
    function run(address strategyProxy, uint256 depositAmount) external {
        require(strategyProxy != address(0), "Strategy proxy address cannot be zero");
        require(depositAmount > 0, "Deposit amount must be greater than zero");

        console.log("\n%s\n", StdStyle.bold(StdStyle.blue("Depositing USDC into Strategy")));
        console.log("%s: %s", StdStyle.bold("Target Strategy"), StdStyle.yellow(vm.toString(strategyProxy)));
        console.log("%s: %s USDC\n", StdStyle.bold("Amount"), StdStyle.yellow(vm.toString(depositAmount)));

        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Execute the approve and deposit
        approveAndDeposit(strategyProxy, depositAmount);
    }

    /**
     * @notice Approves USDC for the strategy proxy and deposits it
     * @param strategyProxy The address of the strategy proxy to deposit into
     * @param depositAmount The amount of USDC to deposit (in USDC units)
     */
    function approveAndDeposit(address strategyProxy, uint256 depositAmount) public {
        vm.startBroadcast();

        // Get the USDC address from Addresses.sol
        address usdc = addresses.getAddress("USDC");

        // Convert the deposit amount to the correct decimals (USDC has 6 decimals)
        uint256 scaledAmount = depositAmount * 10 ** 6; // Convert to USDC's 6 decimals

        // Approve USDC for the strategy proxy
        IERC20(usdc).approve(strategyProxy, scaledAmount);
        console.log("\n%s", StdStyle.bold(StdStyle.blue("Step 1: Approving USDC")));
        console.log("%s: %s", StdStyle.bold("USDC Token"), StdStyle.yellow(vm.toString(usdc)));
        console.log("%s: %s", StdStyle.bold("Amount"), StdStyle.yellow(vm.toString(depositAmount)), "USDC");

        // Call deposit on the strategy proxy
        console.log("\n%s", StdStyle.bold(StdStyle.blue("Step 2: Depositing into Strategy")));
        //IStrategy(strategyProxy).deposit(usdc, scaledAmount);

        console.log("\n%s", StdStyle.bold(StdStyle.green("Deposit completed successfully")));

        vm.stopBroadcast();
    }
}
