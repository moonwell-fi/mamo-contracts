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

// Mock ERC20 Token
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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
        strategy.recoverETH(recipient, ethAmount);
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
        strategy.recoverETH(recipient, ethAmount);
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
        strategy.recoverETH(payable(address(0)), ethAmount);
        vm.stopPrank();
        
        // Verify the ETH remains in the strategy
        assertEq(address(strategy).balance, ethAmount, "Strategy should still have the ETH");
    }
    
    function testRevertIfRecoverETHZeroAmount() public {
        // Send some ETH to the strategy contract
        uint256 ethAmount = 1 ether;
        vm.deal(address(strategy), ethAmount);
        
        // Create a recipient address
        address payable recipient = payable(makeAddr("recipient"));
        
        // Owner attempts to recover zero ETH
        vm.startPrank(owner);
        vm.expectRevert("Amount must be greater than 0");
        strategy.recoverETH(recipient, 0);
        vm.stopPrank();
        
        // Verify the ETH remains in the strategy
        assertEq(address(strategy).balance, ethAmount, "Strategy should still have the ETH");
        assertEq(recipient.balance, 0, "Recipient should not have received any ETH");
    }
    
    function testRevertIfRecoverETHInsufficientBalance() public {
        // Send some ETH to the strategy contract
        uint256 ethAmount = 1 ether;
        vm.deal(address(strategy), ethAmount);
        
        // Create a recipient address
        address payable recipient = payable(makeAddr("recipient"));
        
        // Owner attempts to recover more ETH than the strategy has
        vm.startPrank(owner);
        vm.expectRevert("Insufficient ETH balance");
        strategy.recoverETH(recipient, ethAmount + 1);
        vm.stopPrank();
        
        // Verify the ETH remains in the strategy
        assertEq(address(strategy).balance, ethAmount, "Strategy should still have the ETH");
        assertEq(recipient.balance, 0, "Recipient should not have received any ETH");
    }
    
    function testRevertIfAddStrategyTokenAsRewardToken() public {
        // Attempt to add the strategy token (USDC) as a reward token
        vm.startPrank(backend);
        
        // Attempt should revert with "Strategy token cannot be a reward token"
        vm.expectRevert("Strategy token cannot be a reward token");
        strategy.addRewardToken(address(usdc));
        vm.stopPrank();
    }
}
