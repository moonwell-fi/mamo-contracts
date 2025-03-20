// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeploySlippagePriceChecker} from "../script/DeploySlippagePriceChecker.s.sol";
import {Addresses} from "@addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {Surl} from "@surl/Surl.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {GPv2Order} from "@libraries/GPv2Order.sol";

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./MockERC20.sol";

contract USDCStrategyTest is Test {
    using GPv2Order for GPv2Order.Data;
    using Surl for *;
    using stdJson for string;

    // Magic value returned by isValidSignature for valid orders
    bytes4 private constant MAGIC_VALUE = 0x1626ba7e;
    Addresses public addresses;

    // Contracts
    ERC20MoonwellMorphoStrategy strategy;
    MamoStrategyRegistry registry;
    SlippagePriceChecker slippagePriceChecker;
    IERC20 usdc;
    IERC20 well;
    IMToken mToken;
    IERC4626 metaMorphoVault;

    // Addresses
    address owner;
    address backend;
    address admin;
    address guardian;

    uint256 splitMToken;
    uint256 splitVault;

    function setUp() public {
        // Initialize addresses
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get the addresses for the roles
        admin = addresses.getAddress("MAMO_MULTISIG");
        backend = addresses.getAddress("MAMO_BACKEND");
        guardian = addresses.getAddress("MAMO_MULTISIG");
        owner = makeAddr("owner");

        usdc = IERC20(addresses.getAddress("USDC"));
        well = IERC20(addresses.getAddress("xWELL_PROXY"));
        mToken = IMToken(addresses.getAddress("MOONWELL_USDC"));
        metaMorphoVault = IERC4626(addresses.getAddress("USDC_METAMORPHO_VAULT"));

        // Create an instance of the DeploySlippagePriceChecker script
        DeploySlippagePriceChecker deployScript = new DeploySlippagePriceChecker();

        // Deploy the swap checker using the script
        slippagePriceChecker = deployScript.deploySlippagePriceChecker(addresses);

        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);

        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: addresses.getAddress("CHAINLINK_WELL_USD"),
            reverse: false
        });

        vm.prank(addresses.getAddress("MAMO_MULTISIG"));
        slippagePriceChecker.configureToken(address(well), configs);

        // Deploy the registry with admin, backend, and guardian addresses
        registry = new MamoStrategyRegistry(admin, backend, guardian);

        // Deploy the strategy implementation
        ERC20MoonwellMorphoStrategy implementation = new ERC20MoonwellMorphoStrategy();

        // Whitelist the implementation
        vm.prank(backend);
        registry.whitelistImplementation(address(implementation));

        splitMToken = splitVault = 5000; // 50% in basis points each

        // Encode initialization data for the strategy
        bytes memory initData = abi.encodeWithSelector(
            ERC20MoonwellMorphoStrategy.initialize.selector,
            ERC20MoonwellMorphoStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                mToken: address(mToken),
                metaMorphoVault: address(metaMorphoVault),
                token: address(usdc),
                slippagePriceChecker: address(slippagePriceChecker),
                vaultRelayer: addresses.getAddress("COWSWAP_VAULT_RELAYER"),
                splitMToken: splitMToken,
                splitVault: splitVault
            })
        );

        // Deploy the proxy with the implementation and initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vm.label(address(proxy), "USER_USDC_STRATEGY_PROXY");

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

    function testOwnerCanWithdrawFunds() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), owner, depositAmount);

        vm.startPrank(owner);
        usdc.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        // Verify initial balances
        assertEq(usdc.balanceOf(owner), 0, "Owner's USDC balance should be 0 after deposit");
        uint256 strategyBalance = strategy.getTotalBalance();
        assertApproxEqAbs(strategyBalance, depositAmount, 1e3, "Strategy should have the deposited amount");

        // Withdraw half of the funds
        uint256 withdrawAmount = depositAmount / 2;
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify the owner received the withdrawn funds
        assertApproxEqAbs(usdc.balanceOf(owner), withdrawAmount, 1e3, "Owner should have received the withdrawn amount");

        // Verify the strategy's balance decreased
        uint256 newStrategyBalance = strategy.getTotalBalance();
        assertApproxEqAbs(
            newStrategyBalance,
            strategyBalance - withdrawAmount,
            1e3,
            "Strategy balance should decrease by withdrawn amount"
        );

        // Verify the protocol balances reflect the withdrawal
        uint256 expectedMTokenAmount = ((depositAmount - withdrawAmount) * splitMToken) / 10000;
        uint256 expectedVaultAmount = ((depositAmount - withdrawAmount) * splitVault) / 10000;

        // Verify mToken balance
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(mTokenBalance, expectedMTokenAmount, 1e3, "mToken balance should be updated after withdrawal");

        // Verify vault balance
        uint256 vaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(vaultShares);
        assertApproxEqAbs(vaultBalance, expectedVaultAmount, 1e3, "Vault balance should be updated after withdrawal");
    }

    function testRevertIfNonOwnerWithdraw() public {
        // First deposit funds as the owner
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), owner, depositAmount);

        vm.startPrank(owner);
        usdc.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Attempt to withdraw as non-owner
        vm.startPrank(nonOwner);
        uint256 withdrawAmount = depositAmount / 2;

        // Attempt to withdraw should revert with "Not strategy owner"
        vm.expectRevert("Not strategy owner");
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify the strategy balance remains unchanged
        assertApproxEqAbs(strategy.getTotalBalance(), depositAmount, 1e3, "Strategy balance should remain unchanged");
    }

    function testRevertIfWithdrawAmountTooLarge() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), owner, depositAmount);

        vm.startPrank(owner);
        usdc.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        // Attempt to withdraw more than deposited
        uint256 withdrawAmount = depositAmount * 2;

        // Attempt to withdraw should revert with the updated error message
        vm.expectRevert("Withdrawal amount exceeds available balance in strategy");
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify the strategy balance remains unchanged
        assertApproxEqAbs(strategy.getTotalBalance(), depositAmount, 1e3, "Strategy balance should remain unchanged");
    }

    function testRevertIfWithdrawAmountIsZero() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), owner, depositAmount);

        vm.startPrank(owner);
        usdc.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        // Attempt to withdraw zero amount
        uint256 withdrawAmount = 0;

        // Attempt to withdraw should revert with "Amount must be greater than 0"
        vm.expectRevert("Amount must be greater than 0");
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify the strategy balance remains unchanged
        assertApproxEqAbs(strategy.getTotalBalance(), depositAmount, 1e3, "Strategy balance should remain unchanged");
    }

    function testRevertIfDepositAmountIsZero() public {
        // Mint USDC to the owner
        uint256 initialBalance = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), owner, initialBalance);

        // Attempt to deposit zero amount
        uint256 depositAmount = 0;

        vm.startPrank(owner);
        usdc.approve(address(strategy), depositAmount);

        // Attempt to deposit should revert with "Amount must be greater than 0"
        vm.expectRevert("Amount must be greater than 0");
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Verify the owner's balance remains unchanged
        assertEq(usdc.balanceOf(owner), initialBalance, "Owner's USDC balance should remain unchanged");

        // Verify the strategy balance remains unchanged
        assertApproxEqAbs(strategy.getTotalBalance(), 0, 1e3, "Strategy balance should remain unchanged");
    }

    function testOwnerCanRecoverERC20() public {
        // Create a mock ERC20 token
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK");

        // Mint some tokens to the strategy contract
        uint256 tokenAmount = 1000 * 10 ** 18; // 1000 tokens with 18 decimals
        deal(address(mockToken), address(strategy), tokenAmount);

        // Verify the strategy has the tokens
        assertEq(mockToken.balanceOf(address(strategy)), tokenAmount, "Strategy should have the mock tokens");

        // Create a recipient address
        address recipient = makeAddr("recipient");

        // Owner recovers the tokens
        vm.startPrank(owner);
        strategy.recoverERC20(address(mockToken), recipient, tokenAmount);
        vm.stopPrank();

        // Verify the tokens were transferred to the recipient
        assertEq(mockToken.balanceOf(recipient), tokenAmount, "Recipient should have received the tokens");
        assertEq(mockToken.balanceOf(address(strategy)), 0, "Strategy should have no tokens left");
    }

    function testRevertIfNonOwnerRecoverERC20() public {
        // Create a mock ERC20 token
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK");

        // Mint some tokens to the strategy contract
        uint256 tokenAmount = 1000 * 10 ** 18; // 1000 tokens with 18 decimals
        deal(address(mockToken), address(strategy), tokenAmount);

        // Create a recipient address
        address recipient = makeAddr("recipient");

        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Non-owner attempts to recover the tokens
        vm.startPrank(nonOwner);
        vm.expectRevert("Not strategy owner");
        strategy.recoverERC20(address(mockToken), recipient, tokenAmount);
        vm.stopPrank();

        // Verify the tokens remain in the strategy
        assertEq(mockToken.balanceOf(address(strategy)), tokenAmount, "Strategy should still have the tokens");
        assertEq(mockToken.balanceOf(recipient), 0, "Recipient should not have received any tokens");
    }

    function testRevertIfRecoverERC20ToZeroAddress() public {
        // Create a mock ERC20 token
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK");

        // Mint some tokens to the strategy contract
        uint256 tokenAmount = 1000 * 10 ** 18; // 1000 tokens with 18 decimals
        deal(address(mockToken), address(strategy), tokenAmount);

        // Owner attempts to recover the tokens to the zero address
        vm.startPrank(owner);
        vm.expectRevert("Cannot send to zero address");
        strategy.recoverERC20(address(mockToken), address(0), tokenAmount);
        vm.stopPrank();

        // Verify the tokens remain in the strategy
        assertEq(mockToken.balanceOf(address(strategy)), tokenAmount, "Strategy should still have the tokens");
    }

    function testRevertIfRecoverERC20ZeroAmount() public {
        // Create a mock ERC20 token
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK");

        // Mint some tokens to the strategy contract
        uint256 tokenAmount = 1000 * 10 ** 18; // 1000 tokens with 18 decimals
        deal(address(mockToken), address(strategy), tokenAmount);

        // Create a recipient address
        address recipient = makeAddr("recipient");

        // Owner attempts to recover zero tokens
        vm.startPrank(owner);
        vm.expectRevert("Amount must be greater than 0");
        strategy.recoverERC20(address(mockToken), recipient, 0);
        vm.stopPrank();

        // Verify the tokens remain in the strategy
        assertEq(mockToken.balanceOf(address(strategy)), tokenAmount, "Strategy should still have the tokens");
        assertEq(mockToken.balanceOf(recipient), 0, "Recipient should not have received any tokens");
    }

    function testOwnerCanRecoverETH() public {
        // Send some ETH to the strategy contract
        uint256 ethAmount = 1 ether;
        vm.deal(address(strategy), ethAmount);

        // Verify the strategy has the ETH
        assertEq(address(strategy).balance, ethAmount, "Strategy should have the ETH");

        // Create a recipient address
        address payable recipient = payable(makeAddr("recipient"));
        uint256 initialRecipientBalance = recipient.balance;

        // Owner recovers the ETH
        vm.startPrank(owner);
        strategy.recoverETH(recipient);
        vm.stopPrank();

        // Verify the ETH was transferred to the recipient
        assertEq(recipient.balance, initialRecipientBalance + ethAmount, "Recipient should have received the ETH");
        assertEq(address(strategy).balance, 0, "Strategy should have no ETH left");
    }

    function testRevertIfNonOwnerRecoverETH() public {
        // Send some ETH to the strategy contract
        uint256 ethAmount = 1 ether;
        vm.deal(address(strategy), ethAmount);

        // Create a recipient address
        address payable recipient = payable(makeAddr("recipient"));

        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Non-owner attempts to recover the ETH
        vm.startPrank(nonOwner);
        vm.expectRevert("Not strategy owner");
        strategy.recoverETH(recipient);
        vm.stopPrank();

        // Verify the ETH remains in the strategy
        assertEq(address(strategy).balance, ethAmount, "Strategy should still have the ETH");
        assertEq(recipient.balance, 0, "Recipient should not have received any ETH");
    }

    function testRevertIfRecoverETHToZeroAddress() public {
        // Send some ETH to the strategy contract
        uint256 ethAmount = 1 ether;
        vm.deal(address(strategy), ethAmount);

        // Owner attempts to recover the ETH to the zero address
        vm.startPrank(owner);
        vm.expectRevert("Cannot send to zero address");
        strategy.recoverETH(payable(address(0)));
        vm.stopPrank();

        // Verify the ETH remains in the strategy
        assertEq(address(strategy).balance, ethAmount, "Strategy should still have the ETH");
    }

    function testBackendCanUpdatePosition() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), owner, depositAmount);

        vm.startPrank(owner);
        usdc.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Verify initial split
        assertEq(strategy.splitMToken(), 5000, "Initial mToken split should be 5000 (50%)");
        assertEq(strategy.splitVault(), 5000, "Initial vault split should be 5000 (50%)");

        // Verify initial balances match the expected split
        uint256 totalBalance = strategy.getTotalBalance();
        uint256 expectedInitialMTokenBalance = (totalBalance * splitMToken) / 10000;
        uint256 expectedInitialVaultBalance = (totalBalance * splitVault) / 10000;

        uint256 initialMTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 initialVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 initialVaultBalance = metaMorphoVault.convertToAssets(initialVaultShares);

        assertApproxEqAbs(
            initialMTokenBalance,
            expectedInitialMTokenBalance,
            1e3,
            "Initial mToken balance should match expected amount based on split"
        );

        assertApproxEqAbs(
            initialVaultBalance,
            expectedInitialVaultBalance,
            1e3,
            "Initial vault balance should match expected amount based on split"
        );

        // Update position to 70% mToken, 30% vault
        uint256 newSplitMToken = 7000; // 70%
        uint256 newSplitVault = 3000; // 30%

        vm.startPrank(backend);
        strategy.updatePosition(newSplitMToken, newSplitVault);
        vm.stopPrank();

        // Verify the split was updated
        assertEq(strategy.splitMToken(), newSplitMToken, "mToken split should be updated to 7000 (70%)");
        assertEq(strategy.splitVault(), newSplitVault, "Vault split should be updated to 3000 (30%)");

        // Calculate new balances based on updated split
        uint256 newMTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 newVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 newVaultBalance = metaMorphoVault.convertToAssets(newVaultShares);

        // Verify the balances reflect the new split
        // Get the updated total balance
        totalBalance = strategy.getTotalBalance();
        uint256 expectedMTokenBalance = (totalBalance * newSplitMToken) / 10000;
        uint256 expectedVaultBalance = (totalBalance * newSplitVault) / 10000;

        assertApproxEqAbs(newMTokenBalance, expectedMTokenBalance, 1e3, "mToken balance should reflect the new split");

        assertApproxEqAbs(newVaultBalance, expectedVaultBalance, 1e3, "Vault balance should reflect the new split");
    }

    function testRevertIfNonBackendUpdatePosition() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), owner, depositAmount);

        vm.startPrank(owner);
        usdc.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Create a non-backend address
        address nonBackend = makeAddr("nonBackend");

        // Non-backend attempts to update position
        vm.startPrank(nonBackend);
        vm.expectRevert("Not backend");
        strategy.updatePosition(6000, 4000);
        vm.stopPrank();

        // Verify the split remains unchanged
        assertEq(strategy.splitMToken(), 5000, "mToken split should remain unchanged");
        assertEq(strategy.splitVault(), 5000, "Vault split should remain unchanged");
    }

    function testRevertIfInvalidSplitParameters() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), owner, depositAmount);

        vm.startPrank(owner);
        usdc.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Backend attempts to update position with invalid split parameters
        vm.startPrank(backend);
        vm.expectRevert("Split parameters must add up to SPLIT_TOTAL");
        strategy.updatePosition(6000, 5000); // 60% + 50% = 110%
        vm.stopPrank();

        // Verify the split remains unchanged
        assertEq(strategy.splitMToken(), 5000, "mToken split should remain unchanged");
        assertEq(strategy.splitVault(), 5000, "Vault split should remain unchanged");
    }

    function testRevertIfNoFundsToRebalance() public {
        // No funds deposited

        // Backend attempts to update position
        vm.startPrank(backend);
        vm.expectRevert("Nothing to rebalance");
        strategy.updatePosition(6000, 4000);
        vm.stopPrank();

        // Verify the split remains unchanged
        assertEq(strategy.splitMToken(), 5000, "mToken split should remain unchanged");
        assertEq(strategy.splitVault(), 5000, "Vault split should remain unchanged");
    }

    function testDepositIdleTokens() public {
        // Mint USDC directly to the strategy contract (simulating tokens received from elsewhere)
        uint256 idleAmount = 500 * 10 ** 6; // 500 USDC (6 decimals)
        deal(address(usdc), address(strategy), idleAmount);

        // Verify the strategy has the idle tokens
        assertEq(usdc.balanceOf(address(strategy)), idleAmount, "Strategy should have idle USDC");

        // Check initial balances in protocols
        uint256 initialMTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 initialVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 initialVaultBalance = metaMorphoVault.convertToAssets(initialVaultShares);

        // Call depositIdleTokens (can be called by anyone)
        address caller = makeAddr("caller");
        vm.prank(caller);
        uint256 depositedAmount = strategy.depositIdleTokens();

        // Verify the returned amount matches the idle amount
        assertEq(depositedAmount, idleAmount, "Returned amount should match idle amount");

        // Verify the strategy's token balance is now 0
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should have no idle USDC left");

        // Calculate expected balances based on split
        uint256 expectedMTokenAmount = (idleAmount * splitMToken) / 10000;
        uint256 expectedVaultAmount = (idleAmount * splitVault) / 10000;

        // Verify mToken balance increased
        uint256 newMTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(
            newMTokenBalance - initialMTokenBalance,
            expectedMTokenAmount,
            1e3,
            "mToken balance should increase by expected amount"
        );

        // Verify vault balance increased
        uint256 newVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 newVaultBalance = metaMorphoVault.convertToAssets(newVaultShares);
        assertApproxEqAbs(
            newVaultBalance - initialVaultBalance,
            expectedVaultAmount,
            1e3,
            "Vault balance should increase by expected amount"
        );
    }

    function testRevertIfNoIdleTokensToDeposit() public {
        // Ensure the strategy has no idle tokens
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should have no idle USDC");

        // Call depositIdleTokens should revert
        vm.expectRevert("No tokens to deposit");
        strategy.depositIdleTokens();
    }

    function testDepositIdleTokensWithDifferentSplit() public {
        // First deposit some funds to have a non-zero balance
        uint256 initialDeposit = 1000 * 10 ** 6; // 1000 USDC
        deal(address(usdc), owner, initialDeposit);

        vm.startPrank(owner);
        usdc.approve(address(strategy), initialDeposit);
        strategy.deposit(initialDeposit);
        vm.stopPrank();

        // Update position to 70% mToken, 30% vault
        uint256 newSplitMToken = 7000; // 70%
        uint256 newSplitVault = 3000; // 30%

        vm.prank(backend);
        strategy.updatePosition(newSplitMToken, newSplitVault);

        // Mint USDC directly to the strategy contract
        uint256 idleAmount = 500 * 10 ** 6; // 500 USDC
        deal(address(usdc), address(strategy), idleAmount);

        // Check balances before depositing idle tokens
        uint256 initialMTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 initialVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 initialVaultBalance = metaMorphoVault.convertToAssets(initialVaultShares);

        // Call depositIdleTokens
        strategy.depositIdleTokens();

        // Calculate expected balances based on new split
        uint256 expectedMTokenAmount = (idleAmount * newSplitMToken) / 10000;
        uint256 expectedVaultAmount = (idleAmount * newSplitVault) / 10000;

        // Verify mToken balance increased according to new split
        uint256 newMTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(
            newMTokenBalance - initialMTokenBalance,
            expectedMTokenAmount,
            1e3,
            "mToken balance should increase by expected amount with new split"
        );

        // Verify vault balance increased according to new split
        uint256 newVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 newVaultBalance = metaMorphoVault.convertToAssets(newVaultShares);
        assertApproxEqAbs(
            newVaultBalance - initialVaultBalance,
            expectedVaultAmount,
            1e3,
            "Vault balance should increase by expected amount with new split"
        );
    }

    function testAnyoneCanCallDepositIdleTokens() public {
        // Mint USDC directly to the strategy contract
        uint256 idleAmount = 500 * 10 ** 6; // 500 USDC
        deal(address(usdc), address(strategy), idleAmount);

        // Create various addresses to test
        address randomUser1 = makeAddr("randomUser1");
        address randomUser2 = makeAddr("randomUser2");

        // First user calls depositIdleTokens
        vm.prank(randomUser1);
        uint256 depositedAmount = strategy.depositIdleTokens();

        // Verify the returned amount matches the idle amount
        assertEq(depositedAmount, idleAmount, "Returned amount should match idle amount");

        // Verify the strategy's token balance is now 0
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should have no idle USDC left");

        // Second user tries to call depositIdleTokens but it should revert
        vm.prank(randomUser2);
        vm.expectRevert("No tokens to deposit");
        strategy.depositIdleTokens();
    }

    function testIsValidSignature() public {
        uint256 wellAmount = 100e18;
        // mock claimRewards simulation strategy has well
        deal(address(well), address(strategy), wellAmount);

        // Approve the vault relayer to spend the well token
        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        // Set up parameters for the order
        uint256 feeAmount;
        {
            string[] memory headers = new string[](1);
            headers[0] = "Content-Type: application/json";

            (uint256 status, bytes memory data) = "https://api.cow.fi/base/api/v1/quote".post(
                headers,
                string(
                    abi.encodePacked(
                        '{"sellToken": "',
                        vm.toString(address(well)),
                        '", "buyToken": "',
                        vm.toString(address(usdc)),
                        '", "from": "',
                        vm.toString(address(strategy)),
                        '", "kind": "sell", "sellAmountBeforeFee": "',
                        vm.toString(wellAmount),
                        '", "priceQuality": "fast", "signingScheme": "eip1271"',
                        "}"
                    )
                )
            );

            assertEq(status, 200);

            string memory json = string(data);

            buyAmount = parseUint(json, ".quote.buyAmount");
        }
        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24; // 24 hours from now

        // Create a valid order that meets all requirements
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);

        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        bytes4 isValidSignature = strategy.isValidSignature(digest, encodedOrder);

        assertEq(isValidSignature, MAGIC_VALUE, "Signature invalid");
    }

    function testRevertIfOrderHashDoesNotMatch() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24; // 24 hours from now
        uint256 buyAmount = 1000 * 10 ** 6; // Mock buy amount

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);

        // Create an incorrect digest
        bytes32 incorrectDigest = bytes32(uint256(order.hash(strategy.DOMAIN_SEPARATOR())) + 1);

        vm.expectRevert("Order hash does not match the provided digest");
        strategy.isValidSignature(incorrectDigest, encodedOrder);
    }

    function testRevertIfNotSellOrder() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24;
        uint256 buyAmount = 1000 * 10 ** 6;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_BUY, // Using buy order instead of sell
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("Order must be a sell order");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfOrderExpiresTooSoon() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        // Set validTo to less than 5 minutes in the future
        uint32 validTo = uint32(block.timestamp) + 4 minutes;
        uint256 buyAmount = 1000 * 10 ** 6;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("Order expires too soon - must be valid for at least 5 minutes");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfOrderIsPartiallyFillable() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24;
        uint256 buyAmount = 1000 * 10 ** 6;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: true, // Setting to true to trigger revert
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("Order must be fill-or-kill, partial fills not allowed");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfSellTokenBalanceNotERC20() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24;
        uint256 buyAmount = 1000 * 10 ** 6;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_INTERNAL, // Using internal balance instead of ERC20
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("Sell token must be an ERC20 token");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfBuyTokenBalanceNotERC20() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24;
        uint256 buyAmount = 1000 * 10 ** 6;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_EXTERNAL // Using external balance instead of ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("Buy token must be an ERC20 token");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfBuyTokenDoesNotMatchStrategyToken() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        // Create a mock token that is different from the strategy token
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK");

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24;
        uint256 buyAmount = 1000 * 10 ** 18; // Using 18 decimals for mock token

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(mockToken)), // Using a different token than USDC
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("Buy token must match the strategy token");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfReceiverIsNotStrategy() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24;
        uint256 buyAmount = 1000 * 10 ** 6;

        // Create a different receiver address
        address differentReceiver = makeAddr("differentReceiver");

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: differentReceiver, // Using a different receiver
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("Order receiver must be this strategy contract");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfFeeAmountNotZero() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24;
        uint256 buyAmount = 1000 * 10 ** 6;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 1000, // Setting a non-zero fee amount
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("Fee amount must be zero");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfAppDataNotZero() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24;
        uint256 buyAmount = 1000 * 10 ** 6;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(uint256(1)), // Setting a non-zero app data
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("App data must be zero");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfPriceCheckFails() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        uint32 validTo = uint32(block.timestamp) + 60 * 60 * 24;

        // Set a very low buy amount that will fail the price check
        uint256 buyAmount = 1; // Extremely low amount

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(usdc)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("Price check failed - output amount too low");
        strategy.isValidSignature(digest, encodedOrder);
    }

    // Tests for approveVaultRelayer function

    function testOwnerCanApproveVaultRelayer() public {
        // Verify the token is configured in the swap checker
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: addresses.getAddress("CHAINLINK_WELL_USD"),
            reverse: false
        });

        vm.prank(addresses.getAddress("MAMO_MULTISIG"));
        slippagePriceChecker.configureToken(address(well), configs);

        // Check initial approval
        uint256 initialAllowance = IERC20(address(well)).allowance(address(strategy), strategy.vaultRelayer());
        assertEq(initialAllowance, 0, "Initial allowance should be zero");

        // Owner approves the vault relayer
        vm.prank(owner);
        strategy.approveVaultRelayer(address(well));

        // Verify the approval was successful
        uint256 finalAllowance = IERC20(address(well)).allowance(address(strategy), strategy.vaultRelayer());
        assertEq(finalAllowance, type(uint256).max, "Allowance should be set to maximum");
    }

    function testRevertIfNonOwnerApproveVaultRelayer() public {
        // Configure the token in the swap checker
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: addresses.getAddress("CHAINLINK_WELL_USD"),
            reverse: false
        });

        vm.prank(addresses.getAddress("MAMO_MULTISIG"));
        slippagePriceChecker.configureToken(address(well), configs);

        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Non-owner attempts to approve the vault relayer
        vm.prank(nonOwner);
        vm.expectRevert("Not strategy owner");
        strategy.approveVaultRelayer(address(well));

        // Verify the approval was not granted
        uint256 allowance = IERC20(address(well)).allowance(address(strategy), strategy.vaultRelayer());
        assertEq(allowance, 0, "Allowance should remain zero");
    }

    function testRevertIfTokenNotConfiguredInSlippagePriceChecker() public {
        // Create a mock token that is not configured in the swap checker
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK");

        // Owner attempts to approve the vault relayer for an unconfigured token
        vm.prank(owner);
        vm.expectRevert("Token not allowed");
        strategy.approveVaultRelayer(address(mockToken));

        // Verify the approval was not granted
        uint256 allowance = IERC20(address(mockToken)).allowance(address(strategy), strategy.vaultRelayer());
        assertEq(allowance, 0, "Allowance should remain zero");
    }

    function testAuthorizeUpgrade() public {
        // Deploy a new implementation for upgrade
        ERC20MoonwellMorphoStrategy newImplementation = new ERC20MoonwellMorphoStrategy();

        // Create an unauthorized address
        address unauthorizedAddress = makeAddr("unauthorized");

        // Test case 1: Call from unauthorized address should revert
        vm.startPrank(unauthorizedAddress);
        vm.expectRevert("Only Mamo Strategy Registry can call");
        UUPSUpgradeable(address(strategy)).upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();

        // Test case 2: Call from Mamo Strategy Registry should succeed
        vm.startPrank(address(registry));
        UUPSUpgradeable(address(strategy)).upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();
    }

    function parseUint(string memory json, string memory key) internal pure returns (uint256) {
        bytes memory valueBytes = vm.parseJson(json, key);
        string memory valueString = abi.decode(valueBytes, (string));
        return vm.parseUint(valueString);
    }
}
