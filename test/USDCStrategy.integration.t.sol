// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Addresses} from "@addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock DEX Router
contract MockDEXRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256, // amountOutMin (unused)
        address[] calldata path,
        address, // to (unused)
        uint256 // deadline (unused)
    ) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn; // 1:1 swap for simplicity
        return amounts;
    }
}

contract USDCStrategyTest is Test {
    Addresses public addresses;

    // Contracts
    ERC20MoonwellMorphoStrategy strategy;
    MamoStrategyRegistry registry;

    // Mock tokens and contracts
    ERC20 usdc;
    IMToken mToken;
    IERC4626 metaMorphoVault;
    MockDEXRouter dexRouter;

    // Addresses
    address owner;
    address backend;
    address admin;
    address guardian;
    address moonwellComptroller;

    uint256 splitMToken;
    uint256 splitVault;

    function setUp() public {
        // Create test addresses
        owner = makeAddr("owner");
        backend = makeAddr("backend");
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        moonwellComptroller = makeAddr("moonwellComptroller");

        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Deploy mock tokens and contracts
        usdc = ERC20(addresses.getAddress("USDC"));
        mToken = IMToken(addresses.getAddress("MOONWELL_USDC"));
        metaMorphoVault = IERC4626(addresses.getAddress("USDC_METAMORPHO_VAULT"));
        dexRouter = new MockDEXRouter();

        // Deploy the registry with admin, backend, and guardian addresses
        registry = new MamoStrategyRegistry(admin, backend, guardian);

        // Deploy the strategy implementation
        ERC20MoonwellMorphoStrategy implementation = new ERC20MoonwellMorphoStrategy();

        // Whitelist the implementation
        vm.prank(backend);
        registry.whitelistImplementation(address(implementation));

        splitMToken = splitVault = 5000; // 50$ in basis points each

        // Encode initialization data for the strategy
        bytes memory initData = abi.encodeWithSelector(
            ERC20MoonwellMorphoStrategy.initialize.selector,
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                moonwellComptroller: moonwellComptroller,
                mToken: address(mToken),
                metaMorphoVault: address(metaMorphoVault),
                dexRouter: address(dexRouter),
                token: address(usdc),
                splitMToken: splitMToken,
                splitVault: splitVault
            })
        );

        // Deploy the proxy with the implementation and initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        strategy = ERC20MoonwellMorphoStrategy(payable(address(proxy)));

        // Add the strategy to the registry
        vm.prank(backend);
        registry.addStrategy(owner, address(strategy));
    }

    function testOwnerCanDepositFunds() public {
        // Mint USDC to the owner
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), owner, depositAmount);

        // Verify the owner has the USDC balance
        assertEq(usdc.balanceOf(owner), depositAmount, "Owner should have USDC balance");

        // Owner approves the strategy to spend USDC
        vm.startPrank(owner);
        usdc.approve(address(strategy), depositAmount);

        // Check initial strategy balance
        uint256 initialBalance = strategy.getTotalBalance();

        // Owner deposits USDC into the strategy
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Verify the deposit was successful
        uint256 finalBalance = strategy.getTotalBalance();
        assertApproxEqAbs(
            finalBalance - initialBalance, depositAmount, 1e3, "Strategy balance should increase by deposit amount"
        );

        // Verify the owner's USDC balance decreased
        assertEq(usdc.balanceOf(owner), 0, "Owner's USDC balance should be 0 after deposit");

        // Calculate expected balances based on split
        uint256 expectedMTokenAmount = (depositAmount * splitMToken) / 10000;
        uint256 expectedVaultAmount = (depositAmount * splitVault) / 10000;

        // Verify mToken balance
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(
            mTokenBalance, expectedMTokenAmount, 1e3, "mToken balance should match expected amount based on split"
        );

        // Verify vault balance
        uint256 vaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(vaultShares);
        assertApproxEqAbs(
            vaultBalance, expectedVaultAmount, 1e3, "Vault balance should match expected amount based on split"
        );
    }

    function testRevertIfNonOwnerDeposit() public {
        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Mint USDC to the non-owner
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), nonOwner, depositAmount);

        // Verify the non-owner has the USDC balance
        assertEq(usdc.balanceOf(nonOwner), depositAmount, "Non-owner should have USDC balance");

        // Non-owner approves the strategy to spend USDC
        vm.startPrank(nonOwner);
        usdc.approve(address(strategy), depositAmount);

        // Attempt to deposit should revert with "Not strategy owner"
        vm.expectRevert("Not strategy owner");
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Verify the non-owner's USDC balance remains unchanged
        assertEq(usdc.balanceOf(nonOwner), depositAmount, "Non-owner's USDC balance should remain unchanged");
    }
}
