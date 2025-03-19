// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployChainlinkSwapChecker} from "../script/DeployChainlinkSwapChecker.s.sol";
import {Addresses} from "@addresses/Addresses.sol";
import {ChainlinkSwapChecker} from "@contracts/ChainlinkSwapChecker.sol";
import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";

import {ISwapChecker} from "@interfaces/ISwapChecker.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock ERC20 Token
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract USDCStrategyTest is Test {
    Addresses public addresses;

    // Contracts
    ERC20MoonwellMorphoStrategy strategy;
    MamoStrategyRegistry registry;
    ChainlinkSwapChecker swapChecker;

    // Mock tokens and contracts
    ERC20 usdc;
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

        usdc = ERC20(addresses.getAddress("USDC"));
        mToken = IMToken(addresses.getAddress("MOONWELL_USDC"));
        metaMorphoVault = IERC4626(addresses.getAddress("USDC_METAMORPHO_VAULT"));

        // Create an instance of the DeployChainlinkSwapChecker script
        DeployChainlinkSwapChecker deployScript = new DeployChainlinkSwapChecker();

        // Deploy the swap checker using the script
        swapChecker = deployScript.deployChainlinkSwapChecker(addresses);

        ISwapChecker.TokenFeedConfiguration[] memory configs = new ISwapChecker.TokenFeedConfiguration[](1);

        configs[0] = ISwapChecker.TokenFeedConfiguration({
            chainlinkFeed: addresses.getAddress("CHAINLINK_USDC_USD"),
            reverse: false
        });

        vm.prank(addresses.getAddress("MAMO_MULTISIG"));
        swapChecker.configureToken(address(usdc), configs);

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
                swapChecker: address(swapChecker),
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

    // TODO move this to ChainlinkSwapChecker test file
    function testTokenConfiguration() public {
        // Create a mock chainlink feed address
        address mockChainlinkFeed = makeAddr("mockChainlinkFeed");

        // Create token feed configurations
        ChainlinkSwapChecker.TokenFeedConfiguration[] memory configs =
            new ChainlinkSwapChecker.TokenFeedConfiguration[](1);
        configs[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: mockChainlinkFeed, reverse: false});

        // Configure a token in the swap checker
        vm.prank(swapChecker.owner());
        swapChecker.configureToken(address(usdc), configs);

        // Verify the token is configured - we need to check each element individually
        // since the mapping getter returns individual elements, not the whole array
        (address feed, bool reverse) = swapChecker.tokenOracleData(address(usdc), 0);
        assertEq(feed, mockChainlinkFeed, "Chainlink feed should match");
        assertEq(reverse, false, "Reverse flag should match");

        // Configure a different token with multiple configurations
        address mockToken = makeAddr("mockToken");
        address mockChainlinkFeed2 = makeAddr("mockChainlinkFeed2");

        ChainlinkSwapChecker.TokenFeedConfiguration[] memory configs2 =
            new ChainlinkSwapChecker.TokenFeedConfiguration[](2);
        configs2[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: mockChainlinkFeed, reverse: true});
        configs2[1] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: mockChainlinkFeed2, reverse: false});

        vm.prank(swapChecker.owner());
        swapChecker.configureToken(mockToken, configs2);

        // Verify the new token is configured - we need to check each element individually
        (address feed1, bool reverse1) = swapChecker.tokenOracleData(mockToken, 0);
        (address feed2, bool reverse2) = swapChecker.tokenOracleData(mockToken, 1);

        assertEq(feed1, mockChainlinkFeed, "First chainlink feed should match");
        assertEq(reverse1, true, "First reverse flag should match");
        assertEq(feed2, mockChainlinkFeed2, "Second chainlink feed should match");
        assertEq(reverse2, false, "Second reverse flag should match");

        // Instead, configure with a different feed
        ChainlinkSwapChecker.TokenFeedConfiguration[] memory newConfigs =
            new ChainlinkSwapChecker.TokenFeedConfiguration[](1);
        newConfigs[0] = ISwapChecker.TokenFeedConfiguration({chainlinkFeed: mockChainlinkFeed2, reverse: true});

        vm.prank(swapChecker.owner());
        swapChecker.configureToken(address(usdc), newConfigs);

        // Verify the token data was updated
        (address updatedFeed, bool updatedReverse) = swapChecker.tokenOracleData(address(usdc), 0);
        assertEq(updatedFeed, mockChainlinkFeed2, "Chainlink feed should be updated");
        assertEq(updatedReverse, true, "Reverse flag should be updated");
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
}
