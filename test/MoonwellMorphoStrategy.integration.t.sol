// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployConfig} from "@script/DeployConfig.sol";

import {MockFailingERC20} from "./MockFailingERC20.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoMultiMarketStrategy} from "@contracts/MamoMultiMarketStrategy.sol";

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {MarketRegistry} from "@contracts/MarketRegistry.sol";
import {MultiMarketStrategyFactory} from "@contracts/MultiMarketStrategyFactory.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";

import {IMToken} from "@interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";
import {Surl} from "@surl/Surl.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {GPv2Order} from "@libraries/GPv2Order.sol";

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./MockERC20.sol";

import {DeployMultiMarketSystem} from "../multisig/mamo-multisig/011_DeployMultiMarketSystem.sol";

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";

/**
 * @title MockRejectETH
 * @notice A mock contract that rejects all ETH transfers
 * @dev Used for testing the failure case in recoverETH function
 */
contract MockRejectETH {
// This contract has no receive or fallback function,
// so it will reject all ETH transfers

// Alternatively, we could have a receive function that explicitly reverts
// receive() external payable {
//     revert("ETH transfer rejected");
// }
}

contract MoonwellMorphoStrategyTest is Test {
    using GPv2Order for GPv2Order.Data;
    using Surl for *;
    using stdJson for string;

    // Magic value returned by isValidSignature for valid orders
    bytes4 private constant MAGIC_VALUE = 0x1626ba7e;
    address public constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006; // Base WETH

    uint256 public deltaThreshold;

    // Events
    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);
    event Withdraw(address indexed asset, uint256 amount);

    Addresses public addresses;

    // Contracts
    MamoMultiMarketStrategy public strategy;
    MamoStrategyRegistry public registry;
    MarketRegistry public marketRegistry;
    ISlippagePriceChecker public slippagePriceChecker;
    IERC20 public underlying;
    IERC20 public well;
    IMToken public mToken;
    IERC4626 public metaMorphoVault;

    // Addresses
    address public owner;
    address public backend;
    address public admin;
    address public guardian;
    address public deployer;
    address public multicall;

    uint256 public splitMToken;
    uint256 public splitVault;
    uint256 public strategyTypeId;

    DeployConfig.DeploymentConfig public config;
    DeployAssetConfig.Config public assetConfig;

    function setUp() public {
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        // Run the multi-market deployment proposal
        DeployMultiMarketSystem proposal = new DeployMultiMarketSystem();
        vm.makePersistent(address(proposal));
        proposal.run();

        // Get addresses and config from proposal
        addresses = proposal.addresses();
        string memory assetConfigPath =
            vm.envOr("ASSET_CONFIG_PATH", string("config/strategies/USDCStrategyConfig.json"));
        DeployAssetConfig assetCfg = new DeployAssetConfig(assetConfigPath);
        assetConfig = assetCfg.getConfig();
        uint256 assetIndex = proposal.findAssetIndex(assetConfig.token);
        strategyTypeId = proposal.getAssetKeys(assetIndex).strategyTypeId;

        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));
        DeployConfig configDeploy = new DeployConfig(configPath);
        config = configDeploy.getConfig();

        admin = addresses.getAddress(config.admin);
        backend = addresses.getAddress(config.backend);
        guardian = addresses.getAddress(config.guardian);
        deployer = addresses.getAddress(config.deployer);
        owner = makeAddr("owner");

        underlying = IERC20(addresses.getAddress(assetConfig.token));
        well = IERC20(addresses.getAddress("xWELL_PROXY"));
        mToken = IMToken(addresses.getAddress(assetConfig.moonwellMarket));
        metaMorphoVault = IERC4626(addresses.getAddress(assetConfig.metamorphoVault));
        slippagePriceChecker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));

        registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        marketRegistry = MarketRegistry(addresses.getAddress("MARKET_REGISTRY"));

        splitMToken = assetConfig.strategyParams.splitMToken;
        splitVault = assetConfig.strategyParams.splitVault;
        multicall = addresses.getAddress("STRATEGY_MULTICALL");

        // Create strategy for owner using the deployed factory
        string memory factoryKey = string(abi.encodePacked(assetConfig.token, "_MULTI_MARKET_STRATEGY_FACTORY"));
        MultiMarketStrategyFactory factory = MultiMarketStrategyFactory(addresses.getAddress(factoryKey));

        vm.prank(owner);
        strategy = MamoMultiMarketStrategy(payable(factory.createStrategyForUser(owner)));

        deltaThreshold = assetConfig.decimals == 18 ? 1e9 : 1e3;

        vm.warp(block.timestamp + 1 minutes);
    }

    function _getInitData(uint256 _strategyTypeId) private view returns (bytes memory) {
        uint256[] memory defaultSplitBps = _buildDefaultSplitBps();

        return abi.encodeWithSelector(
            MamoMultiMarketStrategy.initialize.selector,
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                strategyTypeId: _strategyTypeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: assetConfig.strategyParams.hookGasLimit,
                allowedSlippageInBps: assetConfig.strategyParams.allowedSlippageInBps,
                compoundFee: assetConfig.strategyParams.compoundFee,
                marketRegistry: address(marketRegistry),
                defaultSplitBps: defaultSplitBps
            })
        );
    }

    function _buildDefaultSplitBps() private view returns (uint256[] memory) {
        uint256[] memory splits = new uint256[](2);
        splits[0] = splitMToken;
        splits[1] = splitVault;
        return splits;
    }

    function _buildUpdatePositionArray(uint256 mTokenSplit, uint256 vaultSplit)
        private
        view
        returns (MamoMultiMarketStrategy.MarketSplitUpdate[] memory)
    {
        if (vaultSplit > 0) {
            MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates =
                new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
            updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: mTokenSplit});
            updates[1] =
                MamoMultiMarketStrategy.MarketSplitUpdate({market: address(metaMorphoVault), splitBps: vaultSplit});
            return updates;
        } else {
            MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates =
                new MamoMultiMarketStrategy.MarketSplitUpdate[](1);
            updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: mTokenSplit});
            return updates;
        }
    }

    function testOwnerCanDepositFunds() public {
        // Mint USDC to the owner
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        // Verify the owner has the USDC balance
        assertEq(underlying.balanceOf(owner), depositAmount, "Owner should have USDC balance");

        // Owner approves the strategy to spend USDC
        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);

        // Check initial strategy balance
        uint256 initialBalance = getTotalBalance(address(strategy));

        // Owner deposits USDC into the strategy
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Verify the deposit was successful
        uint256 finalBalance = getTotalBalance(address(strategy));
        assertApproxEqAbs(
            finalBalance - initialBalance,
            depositAmount,
            deltaThreshold,
            "Strategy balance should increase by deposit amount"
        );

        // Verify the owner's USDC balance decreased
        assertEq(underlying.balanceOf(owner), 0, "Owner's USDC balance should be 0 after deposit");

        // Calculate expected balances based on split
        uint256 expectedMTokenAmount = (depositAmount * splitMToken) / 10000;
        uint256 expectedVaultAmount = (depositAmount * splitVault) / 10000;

        // Verify mToken balance
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(
            mTokenBalance,
            expectedMTokenAmount,
            deltaThreshold,
            "mToken balance should match expected amount based on split"
        );

        // Verify vault balance
        uint256 vaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(vaultShares);
        assertApproxEqAbs(
            vaultBalance,
            expectedVaultAmount,
            deltaThreshold,
            "Vault balance should match expected amount based on split"
        );
    }

    function testSuccessIfNonOwnerDeposit() public {
        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Mint USDC to the non-owner
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), nonOwner, depositAmount);

        // Verify the non-owner has the USDC balance
        assertEq(underlying.balanceOf(nonOwner), depositAmount, "Non-owner should have USDC balance");

        // Non-owner approves the strategy to spend USDC
        vm.startPrank(nonOwner);
        underlying.approve(address(strategy), depositAmount);

        // Attempt to deposit should not revert
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Verify the non-owner's USDC balance remains unchanged
        assertEq(underlying.balanceOf(nonOwner), 0, "Non-owner's USDC balance should be 0");
    }

    function testOwnerCanWithdrawFunds() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        // Verify initial balances
        assertEq(underlying.balanceOf(owner), 0, "Owner's USDC balance should be 0 after deposit");
        uint256 strategyBalance = getTotalBalance(address(strategy));
        assertApproxEqAbs(strategyBalance, depositAmount, deltaThreshold, "Strategy should have the deposited amount");

        // Withdraw half of the funds
        uint256 withdrawAmount = depositAmount / 2;
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify the owner received the withdrawn funds
        assertApproxEqAbs(
            underlying.balanceOf(owner),
            withdrawAmount,
            deltaThreshold,
            "Owner should have received the withdrawn amount"
        );

        // Verify the strategy's balance decreased
        uint256 newStrategyBalance = getTotalBalance(address(strategy));
        assertApproxEqAbs(
            newStrategyBalance,
            strategyBalance - withdrawAmount,
            deltaThreshold,
            "Strategy balance should decrease by withdrawn amount"
        );

        // Verify the protocol balances reflect the withdrawal
        uint256 expectedMTokenAmount = ((depositAmount - withdrawAmount) * splitMToken) / 10000;
        uint256 expectedVaultAmount = ((depositAmount - withdrawAmount) * splitVault) / 10000;

        // Verify mToken balance
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(
            mTokenBalance, expectedMTokenAmount, deltaThreshold, "mToken balance should be updated after withdrawal"
        );

        // Verify vault balance
        uint256 vaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(vaultShares);
        assertApproxEqAbs(
            vaultBalance, expectedVaultAmount, deltaThreshold, "Vault balance should be updated after withdrawal"
        );
    }

    function testRevertIfNonOwnerWithdraw() public {
        // First deposit funds as the owner
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Attempt to withdraw as non-owner
        vm.startPrank(nonOwner);
        uint256 withdrawAmount = depositAmount / 2;

        // Attempt to withdraw should revert with OwnableUnauthorizedAccount error
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify the strategy balance remains unchanged
        assertApproxEqAbs(
            getTotalBalance(address(strategy)),
            depositAmount,
            deltaThreshold,
            "Strategy balance should remain unchanged"
        );
    }

    function testRevertIfWithdrawAmountTooLarge() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        // Attempt to withdraw more than deposited
        uint256 withdrawAmount = depositAmount * 2;

        // Attempt to withdraw should revert with the updated error message
        vm.expectRevert("Withdrawal amount exceeds available balance in strategy");
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify the strategy balance remains unchanged
        assertApproxEqAbs(
            getTotalBalance(address(strategy)),
            depositAmount,
            deltaThreshold,
            "Strategy balance should remain unchanged"
        );
    }

    function testRevertIfWithdrawAmountIsZero() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        // Attempt to withdraw zero amount
        uint256 withdrawAmount = 0;

        // Attempt to withdraw should revert with "Amount must be greater than 0"
        vm.expectRevert("Amount must be greater than 0");
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify the strategy balance remains unchanged
        assertApproxEqAbs(
            getTotalBalance(address(strategy)),
            depositAmount,
            deltaThreshold,
            "Strategy balance should remain unchanged"
        );
    }

    function testRevertIfDepositAmountIsZero() public {
        // Mint USDC to the owner
        uint256 initialBalance = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, initialBalance);

        // Attempt to deposit zero amount
        uint256 depositAmount = 0;

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);

        // Attempt to deposit should revert with "Amount must be greater than 0"
        vm.expectRevert("Amount must be greater than 0");
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Verify the owner's balance remains unchanged
        assertEq(underlying.balanceOf(owner), initialBalance, "Owner's USDC balance should remain unchanged");

        // Verify the strategy balance remains unchanged
        assertApproxEqAbs(
            getTotalBalance(address(strategy)), 0, deltaThreshold, "Strategy balance should remain unchanged"
        );
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
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
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
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
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

    function testRevertIfRecoverETHNoBalance() public {
        // Ensure the strategy has no ETH balance
        assertEq(address(strategy).balance, 0, "Strategy should have no ETH balance initially");

        // Create a valid recipient address
        address payable recipient = payable(makeAddr("recipient"));
        uint256 initialRecipientBalance = recipient.balance;

        // Owner attempts to recover ETH when there is none
        vm.startPrank(owner);
        vm.expectRevert("Empty balance");
        strategy.recoverETH(recipient);
        vm.stopPrank();

        // Verify the recipient's balance remains unchanged
        assertEq(recipient.balance, initialRecipientBalance, "Recipient's balance should remain unchanged");
        assertEq(address(strategy).balance, 0, "Strategy should still have no ETH balance");
    }

    function testRevertIfRecoverERC20TransferFails() public {
        // Deploy the failing token
        MockFailingERC20 failingToken = new MockFailingERC20();

        // Set some balance for the strategy in the failing token
        uint256 tokenAmount = 1000 * 10 ** 18; // 1000 tokens
        failingToken.setBalance(address(strategy), tokenAmount);

        // Verify the strategy has the tokens
        assertEq(failingToken.balanceOf(address(strategy)), tokenAmount, "Strategy should have the failing tokens");

        // Create a recipient address
        address recipient = makeAddr("recipient");

        // Owner attempts to recover the tokens - should fail
        vm.startPrank(owner);
        vm.expectRevert("Transfer failed");
        strategy.recoverERC20(address(failingToken), recipient, tokenAmount);
        vm.stopPrank();

        // Verify the tokens remain in the strategy
        assertEq(failingToken.balanceOf(address(strategy)), tokenAmount, "Strategy should still have the tokens");
    }

    function testOwnerCanWithdrawAll() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        // Verify initial balances
        assertEq(underlying.balanceOf(owner), 0, "Owner's USDC balance should be 0 after deposit");
        uint256 strategyBalance = getTotalBalance(address(strategy));
        assertApproxEqAbs(strategyBalance, depositAmount, deltaThreshold, "Strategy should have the deposited amount");

        // Call withdrawAll
        strategy.withdrawAll();
        vm.stopPrank();

        // Verify the owner received all funds
        assertApproxEqAbs(
            underlying.balanceOf(owner), depositAmount, deltaThreshold, "Owner should have received all funds"
        );

        // Verify the strategy's balance is now 0
        assertEq(getTotalBalance(address(strategy)), 0, "Strategy balance should be 0");

        // Verify protocol balances are 0
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 0, "mToken balance should be 0");
        assertEq(metaMorphoVault.balanceOf(address(strategy)), 0, "Vault balance should be 0");
    }

    function testRevertIfNonOwnerWithdrawAll() public {
        // First deposit funds as the owner
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Attempt to withdraw all as non-owner
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        strategy.withdrawAll();
        vm.stopPrank();

        // Verify the strategy balance remains unchanged
        assertApproxEqAbs(
            getTotalBalance(address(strategy)),
            depositAmount,
            deltaThreshold,
            "Strategy balance should remain unchanged"
        );
    }

    function testRevertIfNoTokensToWithdrawAll() public {
        // Ensure the strategy has no tokens
        assertEq(getTotalBalance(address(strategy)), 0, "Strategy should have no initial balance");

        // Attempt to withdraw all
        vm.startPrank(owner);
        vm.expectRevert("No tokens to withdraw");
        strategy.withdrawAll();
        vm.stopPrank();
    }

    function testWithdrawAllWithDifferentSplits() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        // Update position to 70% mToken, 30% vault
        vm.stopPrank();
        vm.prank(multicall);
        strategy.updatePosition(_buildUpdatePositionArray(7000, 3000)); // 70% - 30% split

        // Withdraw all as owner
        vm.startPrank(owner);
        strategy.withdrawAll();
        vm.stopPrank();

        // Verify the owner received all funds
        assertApproxEqAbs(
            underlying.balanceOf(owner), depositAmount, deltaThreshold, "Owner should have received all funds"
        );

        // Verify the strategy's balance is now 0
        assertEq(getTotalBalance(address(strategy)), 0, "Strategy balance should be 0");

        // Verify protocol balances are 0
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 0, "mToken balance should be 0");
        assertEq(metaMorphoVault.balanceOf(address(strategy)), 0, "Vault balance should be 0");
    }

    function testBackendCanUpdatePosition() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Verify initial split via markets
        MamoMultiMarketStrategy.Market[] memory marketsBefore = strategy.getMarkets();
        assertEq(marketsBefore[0].splitBps, splitMToken, "Initial mToken market split should match config");

        // Verify initial balances match the expected split
        uint256 totalBalance = getTotalBalance(address(strategy));
        uint256 expectedInitialMTokenBalance = (totalBalance * splitMToken) / 10000;
        uint256 expectedInitialVaultBalance = (totalBalance * splitVault) / 10000;

        uint256 initialMTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 initialVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 initialVaultBalance = metaMorphoVault.convertToAssets(initialVaultShares);

        assertApproxEqAbs(
            initialMTokenBalance,
            expectedInitialMTokenBalance,
            deltaThreshold,
            "Initial mToken balance should match expected amount based on split"
        );

        assertApproxEqAbs(
            initialVaultBalance,
            expectedInitialVaultBalance,
            deltaThreshold,
            "Initial vault balance should match expected amount based on split"
        );

        // Update position to 70% mToken, 30% vault
        uint256 newSplitMToken = 7000; // 70%
        uint256 newSplitVault = 3000; // 30%

        vm.startPrank(multicall);
        strategy.updatePosition(_buildUpdatePositionArray(newSplitMToken, newSplitVault));
        vm.stopPrank();

        // Verify markets were updated
        MamoMultiMarketStrategy.Market[] memory marketsAfter = strategy.getMarkets();
        assertEq(marketsAfter[0].splitBps, newSplitMToken, "mToken market split should be updated to 7000 (70%)");
        assertEq(marketsAfter[1].splitBps, newSplitVault, "Vault market split should be updated to 3000 (30%)");

        // Calculate new balances based on updated split
        uint256 newMTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        uint256 newVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 newVaultBalance = metaMorphoVault.convertToAssets(newVaultShares);

        // Verify the balances reflect the new split
        // Get the updated total balance
        totalBalance = getTotalBalance(address(strategy));
        uint256 expectedMTokenBalance = (totalBalance * newSplitMToken) / 10000;
        uint256 expectedVaultBalance = (totalBalance * newSplitVault) / 10000;

        assertApproxEqAbs(
            newMTokenBalance, expectedMTokenBalance, deltaThreshold, "mToken balance should reflect the new split"
        );

        assertApproxEqAbs(
            newVaultBalance, expectedVaultBalance, deltaThreshold, "Vault balance should reflect the new split"
        );
    }

    function testRevertIfNonBackendUpdatePosition() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Create a non-backend address
        address nonBackend = makeAddr("nonBackend");

        // Non-backend attempts to update position
        vm.startPrank(nonBackend);
        vm.expectRevert("Not backend");
        strategy.updatePosition(_buildUpdatePositionArray(6000, 4000));
        vm.stopPrank();
    }

    function testRevertIfInvalidSplitParameters() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Backend attempts to update position with invalid split parameters
        vm.startPrank(multicall);
        vm.expectRevert("Split parameters must add up to SPLIT_TOTAL");
        strategy.updatePosition(_buildUpdatePositionArray(6000, 5000)); // 60% + 50% = 110%
        vm.stopPrank();
    }

    function testRevertIfNoFundsToRebalance() public {
        // No funds deposited

        // Backend attempts to update position
        vm.startPrank(multicall);
        vm.expectRevert("Nothing to rebalance");
        strategy.updatePosition(_buildUpdatePositionArray(6000, 4000));
        vm.stopPrank();
    }

    function testDepositIdleTokens() public {
        // Mint USDC directly to the strategy contract (simulating tokens received from elsewhere)
        uint256 idleAmount = 500 * 10 ** assetConfig.decimals;
        deal(address(underlying), address(strategy), idleAmount);

        // Verify the strategy has the idle tokens
        assertEq(underlying.balanceOf(address(strategy)), idleAmount, "Strategy should have idle USDC");

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
        assertEq(underlying.balanceOf(address(strategy)), 0, "Strategy should have no idle USDC left");

        // Calculate expected balances based on split
        uint256 expectedMTokenAmount = (idleAmount * splitMToken) / 10000;
        uint256 expectedVaultAmount = (idleAmount * splitVault) / 10000;

        // Verify mToken balance increased
        uint256 newMTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(
            newMTokenBalance - initialMTokenBalance,
            expectedMTokenAmount,
            deltaThreshold,
            "mToken balance should increase by expected amount"
        );

        // Verify vault balance increased
        uint256 newVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 newVaultBalance = metaMorphoVault.convertToAssets(newVaultShares);
        assertApproxEqAbs(
            newVaultBalance - initialVaultBalance,
            expectedVaultAmount,
            deltaThreshold,
            "Vault balance should increase by expected amount"
        );
    }

    function testRevertIfNoIdleTokensToDeposit() public {
        // Ensure the strategy has no idle tokens
        assertEq(underlying.balanceOf(address(strategy)), 0, "Strategy should have no idle USDC");

        // Call depositIdleTokens should revert
        vm.expectRevert("No tokens to deposit");
        strategy.depositIdleTokens();
    }

    function testDepositIdleTokensReturnValue() public {
        // Mint USDC to the strategy contract directly
        uint256 idleAmount = 500 * 10 ** assetConfig.decimals;
        deal(address(underlying), address(strategy), idleAmount);

        // Call depositIdleTokens and check the return value
        vm.startPrank(owner);
        uint256 returnedAmount = strategy.depositIdleTokens();
        vm.stopPrank();

        // Verify the returned amount matches the idle amount
        assertEq(returnedAmount, idleAmount, "Return value should match the deposited amount");

        // Verify the funds were properly deposited
        assertEq(underlying.balanceOf(address(strategy)), 0, "Strategy should have no idle USDC left");
    }

    function testDepositIdleTokensWithDifferentSplit() public {
        // First deposit some funds to have a non-zero balance
        uint256 initialDeposit = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, initialDeposit);

        vm.startPrank(owner);
        underlying.approve(address(strategy), initialDeposit);
        strategy.deposit(initialDeposit);
        vm.stopPrank();

        // Update position to 70% mToken, 30% vault
        uint256 newSplitMToken = 7000; // 70%
        uint256 newSplitVault = 3000; // 30%

        vm.prank(multicall);
        strategy.updatePosition(_buildUpdatePositionArray(newSplitMToken, newSplitVault));

        // Mint USDC directly to the strategy contract
        uint256 idleAmount = 500 * 10 ** assetConfig.decimals;
        deal(address(underlying), address(strategy), idleAmount);

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
            deltaThreshold,
            "mToken balance should increase by expected amount with new split"
        );

        // Verify vault balance increased according to new split
        uint256 newVaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 newVaultBalance = metaMorphoVault.convertToAssets(newVaultShares);
        assertApproxEqAbs(
            newVaultBalance - initialVaultBalance,
            expectedVaultAmount,
            deltaThreshold,
            "Vault balance should increase by expected amount with new split"
        );
    }

    function testAnyoneCanCallDepositIdleTokens() public {
        // Mint USDC directly to the strategy contract
        uint256 idleAmount = 500 * 10 ** assetConfig.decimals;
        deal(address(underlying), address(strategy), idleAmount);

        // Create various addresses to test
        address randomUser1 = makeAddr("randomUser1");
        address randomUser2 = makeAddr("randomUser2");

        // First user calls depositIdleTokens
        vm.prank(randomUser1);
        uint256 depositedAmount = strategy.depositIdleTokens();

        // Verify the returned amount matches the idle amount
        assertEq(depositedAmount, idleAmount, "Returned amount should match idle amount");

        // Verify the strategy's token balance is now 0
        assertEq(underlying.balanceOf(address(strategy)), 0, "Strategy should have no idle USDC left");

        // Second user tries to call depositIdleTokens but it should revert
        vm.prank(randomUser2);
        vm.expectRevert("No tokens to deposit");
        strategy.depositIdleTokens();
    }

    function testIsValidSignature() public {
        uint256 wellAmount = 10000e18;
        deal(address(well), address(strategy), wellAmount);

        // Set the maximum allowed slippage tolerance to make the test pass
        // The default is 100 (1%), but we need a higher value to account for price differences
        // between the Chainlink oracle and the CoW API
        vm.startPrank(owner);
        strategy.setSlippage(2500); // 25% slippage (maximum allowed)
        strategy.approveCowSwap(address(well), type(uint256).max);
        vm.stopPrank();

        // Set up parameters for the order
        uint256 buyAmount;
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
                        vm.toString(address(underlying)),
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
        uint32 validTo = uint32(block.timestamp) + 29 minutes;

        bytes32 appDataHash = generateAppDataHash(address(well), admin, wellAmount, address(strategy));

        // Mock the price check to always return true
        // This is necessary because the price from the CoW API is significantly different
        // from what the Chainlink oracle expects, causing the price check to fail
        // even with the maximum allowed slippage
        vm.mockCall(
            address(slippagePriceChecker),
            abi.encodeWithSelector(
                ISlippagePriceChecker.checkPrice.selector,
                wellAmount,
                address(well),
                address(underlying),
                buyAmount,
                2500
            ),
            abi.encode(true)
        );

        // Create a valid order that meets all requirements
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: appDataHash,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);

        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        bytes4 isValidSignature = strategy.isValidSignature(digest, encodedOrder);

        // Clear the mock after the test
        vm.clearMockedCalls();

        assertEq(isValidSignature, MAGIC_VALUE, "Signature invalid");
    }

    function testRevertIfOrderHashDoesNotMatch() public {
        uint256 wellAmount = 1000e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        uint32 validTo = uint32(block.timestamp) + 30 minutes; // 24 hours from now
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals; // Mock buy amount

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        vm.expectRevert("bad digest");
        strategy.isValidSignature(incorrectDigest, encodedOrder);
    }

    function testRevertIfNotSellOrder() public {
        uint256 wellAmount = 1000e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        uint32 validTo = uint32(block.timestamp) + 30 minutes;
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        vm.expectRevert("must be sell");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfOrderExpiresTooSoon() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        // Set validTo to less than 5 minutes in the future
        uint32 validTo = uint32(block.timestamp) + 4 minutes;
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        vm.expectRevert("expires too soon");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfOrderIsPartiallyFillable() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        uint32 validTo = uint32(block.timestamp) + 30 minutes;
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        vm.expectRevert("must be fill-or-kill");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfSellTokenBalanceNotERC20() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        uint32 validTo = uint32(block.timestamp) + 30 minutes;
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        vm.expectRevert("sell must be erc20");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfBuyTokenBalanceNotERC20() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        uint32 validTo = uint32(block.timestamp) + 30 minutes;
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        vm.expectRevert("buy must be erc20");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfBuyTokenDoesNotMatchStrategyToken() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        // Create a mock token that is different from the strategy token
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK");

        uint32 validTo = uint32(block.timestamp) + 30 minutes;
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
        strategy.approveCowSwap(address(well), type(uint256).max);

        uint32 validTo = uint32(block.timestamp) + 30 minutes;
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals;

        // Create a different receiver address
        address differentReceiver = makeAddr("differentReceiver");

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        vm.expectRevert("bad receiver");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfFeeAmountNotZero() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        uint32 validTo = uint32(block.timestamp) + 30 minutes;
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        vm.expectRevert("fee must be zero");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfAppDataIsWrong() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        uint32 validTo = uint32(block.timestamp) + 30 minutes;
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        vm.expectRevert("bad appData");
        strategy.isValidSignature(digest, encodedOrder);
    }

    // ==================== INITIALIZATION TESTS ====================

    function testRevertIfInvalidInitializationParameters() public {
        // Deploy a new implementation
        MamoMultiMarketStrategy implementation = new MamoMultiMarketStrategy();

        // Whitelist the implementation
        vm.prank(admin);
        uint256 _strategyTypeId = registry.whitelistImplementation(address(implementation), 0);

        // Register markets for the new type (skip if already registered from proposal)
        if (marketRegistry.getMarketCount(address(underlying)) == 0) {
            vm.startPrank(backend);
            marketRegistry.addMarket(address(underlying), address(mToken), MarketType.MTOKEN);
            marketRegistry.addMarket(address(underlying), address(metaMorphoVault), MarketType.ERC4626);
            vm.stopPrank();
        }

        uint256[] memory defaultSplitBps = _buildDefaultSplitBps();

        // Test with invalid mamoStrategyRegistry
        bytes memory invalidRegistryData = abi.encodeWithSelector(
            MamoMultiMarketStrategy.initialize.selector,
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: address(0), // Invalid address
                mamoBackend: backend,
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                strategyTypeId: _strategyTypeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: config.hookGasLimit,
                allowedSlippageInBps: config.allowedSlippageInBps,
                compoundFee: config.compoundFee,
                marketRegistry: address(marketRegistry),
                defaultSplitBps: defaultSplitBps
            })
        );

        vm.prank(backend);
        vm.expectRevert("Invalid mamoStrategyRegistry address");
        new ERC1967Proxy(address(implementation), invalidRegistryData);

        // Test with invalid split parameters (splits don't add up to 10000)
        uint256[] memory badSplits = new uint256[](2);
        badSplits[0] = 6000;
        badSplits[1] = 3000;

        bytes memory invalidSplitData = abi.encodeWithSelector(
            MamoMultiMarketStrategy.initialize.selector,
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                strategyTypeId: _strategyTypeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: config.hookGasLimit,
                allowedSlippageInBps: config.allowedSlippageInBps,
                compoundFee: config.compoundFee,
                marketRegistry: address(marketRegistry),
                defaultSplitBps: badSplits
            })
        );

        vm.prank(backend);
        vm.expectRevert("Split parameters must add up to SPLIT_TOTAL");
        new ERC1967Proxy(address(implementation), invalidSplitData);

        // Test with invalid hook gas limit
        bytes memory invalidHookGasData = abi.encodeWithSelector(
            MamoMultiMarketStrategy.initialize.selector,
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                mamoBackend: backend,
                token: address(underlying),
                slippagePriceChecker: address(slippagePriceChecker),
                feeRecipient: admin,
                strategyTypeId: _strategyTypeId,
                rewardTokens: new address[](0),
                owner: owner,
                hookGasLimit: 0, // Invalid hook gas limit
                allowedSlippageInBps: config.allowedSlippageInBps,
                compoundFee: config.compoundFee,
                marketRegistry: address(marketRegistry),
                defaultSplitBps: defaultSplitBps
            })
        );

        vm.prank(backend);
        vm.expectRevert("Invalid hook gas limit");
        new ERC1967Proxy(address(implementation), invalidHookGasData);
    }

    // Tests for setSlippage function

    function testOwnerCanSetSlippage() public {
        // Check initial slippage (default is 100 basis points = 1%)
        uint256 initialSlippage = 100;
        assertEq(strategy.allowedSlippageInBps(), initialSlippage, "Initial slippage should be 100 basis points (1%)");

        // Set a new slippage value
        uint256 newSlippage = 200; // 2%
        vm.prank(owner);
        strategy.setSlippage(newSlippage);

        // Verify the slippage was updated
        assertEq(strategy.allowedSlippageInBps(), newSlippage, "Slippage should be updated to 200 basis points (2%)");
    }

    function testRevertIfNonOwnerSetSlippage() public {
        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Non-owner attempts to set slippage
        uint256 newSlippage = 200; // 2%
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        strategy.setSlippage(newSlippage);

        // Verify the slippage remains unchanged
        assertEq(strategy.allowedSlippageInBps(), 100, "Slippage should remain at default 100 basis points (1%)");
    }

    function testRevertIfSlippageExceedsMaximum() public {
        // Attempt to set slippage higher than the maximum allowed (SPLIT_TOTAL = 10000)
        uint256 excessiveSlippage = 10001;
        vm.prank(owner);
        vm.expectRevert("Slippage exceeds maximum");
        strategy.setSlippage(excessiveSlippage);

        // Verify the slippage remains unchanged
        assertEq(strategy.allowedSlippageInBps(), 100, "Slippage should remain at default 100 basis points (1%)");
    }

    function testSlippageAffectsPriceCheck() public {
        _freshenPriceFeeds();

        uint256 wellAmount = 10000e18;
        deal(address(well), address(strategy), wellAmount);

        // First check with default slippage (1%)
        uint256 defaultSlippage = 100; // 1%
        assertEq(strategy.allowedSlippageInBps(), defaultSlippage, "Initial slippage should be 100 basis points (1%)");

        uint32 validTo = uint32(block.timestamp) + 29 minutes;

        // Generate proper app data hash for this test
        bytes32 appDataHash = generateAppDataHash(address(well), admin, wellAmount, address(strategy));

        // Set an extremely low buy amount that will definitely fail the price check
        uint256 extremelyLowBuyAmount = 1; // Just 1 unit of underlying

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: extremelyLowBuyAmount,
            validTo: validTo,
            appData: appDataHash,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        // With default slippage, this should revert
        vm.expectRevert("price check failed");
        strategy.isValidSignature(digest, encodedOrder);

        // Now set a higher but still reasonable slippage (10%)
        uint256 moderateSlippage = 1000; // 10%
        vm.prank(owner);
        strategy.setSlippage(moderateSlippage);

        assertEq(
            strategy.allowedSlippageInBps(), moderateSlippage, "Slippage should be updated to 1000 basis points (10%)"
        );

        // With 10% slippage, the extremely low amount should still fail
        vm.expectRevert("price check failed");
        strategy.isValidSignature(digest, encodedOrder);

        // Now create a more reasonable order with a higher buy amount
        // This amount is still low but might pass with high slippage
        uint256 reasonableBuyAmount = 1000 * 10 ** assetConfig.decimals;

        GPv2Order.Data memory betterOrder = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: reasonableBuyAmount,
            validTo: validTo,
            appData: appDataHash,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedBetterOrder = abi.encode(betterOrder);
        bytes32 betterDigest = betterOrder.hash(strategy.DOMAIN_SEPARATOR());

        // Set a maximum slippage 25%
        uint256 veryHighSlippage = 2500;
        vm.prank(owner);
        strategy.setSlippage(veryHighSlippage);

        assertEq(
            strategy.allowedSlippageInBps(), veryHighSlippage, "Slippage should be updated to 9000 basis points (90%)"
        );

        // Re-encode the order and get the new digest
        encodedBetterOrder = abi.encode(betterOrder);
        betterDigest = betterOrder.hash(strategy.DOMAIN_SEPARATOR());

        bytes4 result = strategy.isValidSignature(betterDigest, encodedBetterOrder);
        assertEq(result, MAGIC_VALUE, "Order should be valid with high slippage");
    }

    /// @notice Re-stamps every configured price feed's `updatedAt` to now, keeping its real answer.
    /// @dev These tests fork at `latest` and assert a SPECIFIC revert reason from checkPrice. Any feed
    ///      whose last update is older than its configured heartbeat reverts first with
    ///      "Price feed update time exceeds heartbeat", so the assertion becomes a coin flip on where
    ///      in the feed's update cycle the fork block happens to land. That is not theoretical: the
    ///      WETH config allows 1200s for CHAINLINK_ETH_USD while that feed's observed cadence on Base
    ///      is ~1230s (five consecutive 1230s gaps measured 2026-08-14), so the tail of every cycle is
    ///      stale by the configured bound and CI fails there. Freezing freshness keeps these tests
    ///      about the price check they name. The heartbeat bound itself is covered by
    ///      SlippagePriceChecker.integration.t.sol, and the live config value is an on-chain concern
    ///      tracked separately — do NOT widen a heartbeat to make a test pass.
    function _freshenPriceFeeds() internal {
        for (uint256 i = 0; i < assetConfig.rewardTokens.length; i++) {
            DeployAssetConfig.PriceFeedConfig[] memory feeds = assetConfig.rewardTokens[i].priceFeeds;

            for (uint256 j = 0; j < feeds.length; j++) {
                address feed = addresses.getAddress(feeds[j].priceFeed);

                // Read the live round FIRST: the point is to preserve the real price and move only
                // its timestamp, so the arithmetic under test stays the production arithmetic.
                (uint80 roundId, int256 answer,,, uint80 answeredInRound) = IPriceFeed(feed).latestRoundData();

                vm.mockCall(
                    feed,
                    abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
                    abi.encode(roundId, answer, block.timestamp, block.timestamp, answeredInRound)
                );
            }
        }
    }

    function testRevertIfPriceCheckFails() public {
        _freshenPriceFeeds();

        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        uint32 validTo = uint32(block.timestamp) + 29 minutes;

        // Set a very low buy amount that will fail the price check

        uint256 buyAmount = 1; // Extremely low amount

        // Generate proper app data hash
        bytes32 appDataHash = generateAppDataHash(address(well), admin, wellAmount, address(strategy));

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
            receiver: address(strategy),
            sellAmount: wellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: appDataHash,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("price check failed");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testRevertIfSellTokenIsStrategyToken() public {
        // Create a mock order where the sell token is the strategy token (USDC)
        // We need to set a valid expiration time to pass the earlier checks
        uint32 validTo = uint32(block.timestamp + 30 minutes);

        // Mock the slippagePriceChecker to return a specific max time
        vm.mockCall(
            address(slippagePriceChecker),
            abi.encodeWithSelector(ISlippagePriceChecker.maxTimePriceValid.selector, address(underlying)),
            abi.encode(60 minutes)
        );

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: underlying, // This should be rejected
            buyToken: well,
            receiver: address(strategy),
            sellAmount: 1000 * 10 ** assetConfig.decimals,
            buyAmount: 100 * 10 ** 18,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        // Encode the order
        bytes memory encodedOrder = abi.encode(order);

        // Calculate the order digest
        bytes32 orderDigest = order.hash(strategy.DOMAIN_SEPARATOR());

        // Call isValidSignature and expect it to revert
        vm.expectRevert("Sell token can't be strategy token");
        strategy.isValidSignature(orderDigest, encodedOrder);

        // Clear the mock
        vm.clearMockedCalls();
    }

    function testRevertIfOrderExpiresTooFarInFutureWithMockData() public {
        // Create a mock order with a validity period that's too long
        uint256 maxValidTime = 24 hours; // Assume this is the max time

        // Mock the slippagePriceChecker to return a specific max time
        vm.mockCall(
            address(slippagePriceChecker),
            abi.encodeWithSelector(ISlippagePriceChecker.maxTimePriceValid.selector, address(well)),
            abi.encode(maxValidTime)
        );

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: well,
            buyToken: underlying,
            receiver: address(strategy),
            sellAmount: 100 * 10 ** 18,
            buyAmount: 1000 * 10 ** assetConfig.decimals,
            validTo: uint32(block.timestamp + maxValidTime + 1 hours), // Too far in the future
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        // Encode the order
        bytes memory encodedOrder = abi.encode(order);

        // Calculate the order digest
        bytes32 orderDigest = order.hash(strategy.DOMAIN_SEPARATOR());

        // Call isValidSignature and expect it to revert
        vm.expectRevert("expires too far");
        strategy.isValidSignature(orderDigest, encodedOrder);

        // Clear the mock
        vm.clearMockedCalls();
    }

    // Tests for approveCowSwap function

    function testOwnerCanApproveCowSwap() public {
        vm.prank(owner);
        strategy.approveCowSwap(address(well), 1e18);

        // Verify the approval was successful
        uint256 finalAllowance = IERC20(address(well)).allowance(address(strategy), strategy.VAULT_RELAYER());
        assertEq(finalAllowance, 1e18, "Allowance should be set to maximum");
    }

    function testRevertIfNonOwnerApproveCowSwap() public {
        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Non-owner attempts to approve the vault relayer
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        strategy.approveCowSwap(address(well), type(uint256).max);

        // Verify the approval was not granted
        uint256 allowance = IERC20(address(well)).allowance(address(strategy), strategy.VAULT_RELAYER());
        assertEq(allowance, type(uint256).max, "Allowance should remain maximum");
    }

    function testRevertIfTokenNotConfiguredInSlippagePriceChecker() public {
        // Create a mock token that is not configured in the swap checker
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK");

        // Owner attempts to approve the vault relayer for an unconfigured token
        vm.prank(owner);
        vm.expectRevert("Token not allowed");
        strategy.approveCowSwap(address(mockToken), type(uint256).max);

        // Verify the approval was not granted
        uint256 allowance = IERC20(address(mockToken)).allowance(address(strategy), strategy.VAULT_RELAYER());
        assertEq(allowance, 0, "Allowance should remain zero");
    }

    function testApproveCowSwapZeroAmountRemovesApproval() public {
        // First set a non-zero approval
        vm.startPrank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        // Verify the initial approval was set
        uint256 initialAllowance = IERC20(address(well)).allowance(address(strategy), strategy.VAULT_RELAYER());
        assertEq(initialAllowance, type(uint256).max, "Initial allowance should be maximum");

        // Now set approval to zero
        strategy.approveCowSwap(address(well), 0);
        vm.stopPrank();

        // Verify the approval was removed
        uint256 finalAllowance = IERC20(address(well)).allowance(address(strategy), strategy.VAULT_RELAYER());
        assertEq(finalAllowance, 0, "Allowance should be set to zero");
    }

    /// @notice MOO-726 side-effect: revoking must not be gated on the token still being a reward token.
    /// @dev isRewardToken now follows live pair configuration instead of latching on forever, so once a
    ///      token's last pair is removed the reward-token gate stops passing. If revocation shared that
    ///      gate, a standing max relayer allowance granted while the token WAS configured could never
    ///      be zeroed — the only call able to do it would revert "Token not allowed". Granting stays
    ///      gated; revoking does not, because it can only reduce risk.
    function testApproveCowSwapZeroAmountStillRevokesAfterTokenDeconfigured() public {
        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);
        assertEq(
            IERC20(address(well)).allowance(address(strategy), strategy.VAULT_RELAYER()),
            type(uint256).max,
            "Fixture must start from a standing relayer allowance"
        );

        // Put WELL into the post-deconfiguration state: isRewardToken is what the gate reads, and
        // after its last pair is removed and the legacy flag cleared it answers false.
        vm.mockCall(
            address(slippagePriceChecker),
            abi.encodeWithSelector(ISlippagePriceChecker.isRewardToken.selector, address(well)),
            abi.encode(false)
        );

        assertFalse(
            slippagePriceChecker.isRewardToken(address(well)),
            "Fixture must actually have deconfigured the reward token"
        );

        // Granting is refused, as it should be.
        vm.prank(owner);
        vm.expectRevert("Token not allowed");
        strategy.approveCowSwap(address(well), type(uint256).max);

        // Revoking still works, which is the point.
        vm.prank(owner);
        strategy.approveCowSwap(address(well), 0);

        assertEq(
            IERC20(address(well)).allowance(address(strategy), strategy.VAULT_RELAYER()),
            0,
            "The standing relayer allowance must remain revocable after deconfiguration"
        );
    }

    function testAuthorizeUpgrade() public {
        // Deploy a new implementation for upgrade
        MamoMultiMarketStrategy newImplementation = new MamoMultiMarketStrategy();

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

    function testRevertIfOrderExpiresTooFarInFuture() public {
        uint256 wellAmount = 100e18;
        deal(address(well), address(strategy), wellAmount);

        vm.prank(owner);
        strategy.approveCowSwap(address(well), type(uint256).max);

        // Set validTo to more than 24 hours in the future
        uint32 validTo = uint32(block.timestamp) + 25 hours; // 25 hours from now
        uint256 buyAmount = 1000 * 10 ** assetConfig.decimals;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(well)),
            buyToken: IERC20(address(underlying)),
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

        // Generate proper app data hash
        bytes32 appDataHash = generateAppDataHash(address(well), admin, wellAmount, address(strategy));

        // Update the order with the proper app data hash
        order.appData = appDataHash;

        bytes memory encodedOrder = abi.encode(order);
        bytes32 digest = order.hash(strategy.DOMAIN_SEPARATOR());

        vm.expectRevert("expires too far");
        strategy.isValidSignature(digest, encodedOrder);
    }

    function testBackendCanSetFeeRecipient() public {
        // Create a new fee recipient address
        address newFeeRecipient = makeAddr("newFeeRecipient");

        // Get the current fee recipient
        address currentFeeRecipient = strategy.feeRecipient();

        // Backend sets a new fee recipient
        vm.prank(multicall);
        vm.expectEmit(true, true, false, true, address(strategy));
        emit FeeRecipientUpdated(currentFeeRecipient, newFeeRecipient);
        strategy.setFeeRecipient(newFeeRecipient);

        // Verify the fee recipient was updated
        assertEq(strategy.feeRecipient(), newFeeRecipient, "Fee recipient should be updated");
    }

    function testRevertIfNonBackendSetsFeeRecipient() public {
        // Create a new fee recipient address
        address newFeeRecipient = makeAddr("newFeeRecipient");

        // Get the current fee recipient
        address currentFeeRecipient = strategy.feeRecipient();

        // Owner attempts to set a new fee recipient (should fail despite being owner)
        vm.prank(owner);
        vm.expectRevert("Not backend");
        strategy.setFeeRecipient(newFeeRecipient);

        // Random address attempts to set a new fee recipient
        address randomAddress = makeAddr("randomAddress");
        vm.prank(randomAddress);
        vm.expectRevert("Not backend");
        strategy.setFeeRecipient(newFeeRecipient);

        // Verify the fee recipient remains unchanged
        assertEq(strategy.feeRecipient(), currentFeeRecipient, "Fee recipient should remain unchanged");
    }

    function testRevertIfSetFeeRecipientToZeroAddress() public {
        // Backend attempts to set fee recipient to zero address
        vm.prank(multicall);
        vm.expectRevert("Invalid fee recipient address");
        strategy.setFeeRecipient(address(0));

        // Verify the fee recipient remains unchanged
        address currentFeeRecipient = strategy.feeRecipient();
        assertEq(strategy.feeRecipient(), currentFeeRecipient, "Fee recipient should remain unchanged");
    }

    // Tests for transferOwnership function

    function testOwnerCanTransferOwnership() public {
        // Create a new owner address
        address newOwner = makeAddr("newOwner");

        // Check initial ownership
        assertEq(strategy.owner(), owner, "Initial owner should be the original owner");

        // First, we need to ensure the registry recognizes the strategy as belonging to the owner
        assertTrue(
            registry.isUserStrategy(owner, address(strategy)),
            "Registry should recognize strategy as belonging to owner"
        );

        // Mock the registry's behavior for this test
        // In a real scenario, the registry would need to be updated by the backend
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMamoStrategyRegistry.updateStrategyOwner.selector, newOwner),
            abi.encode()
        );

        // Now the owner can transfer ownership
        vm.prank(owner);
        strategy.transferOwnership(newOwner);

        // Verify ownership was transferred
        assertEq(strategy.owner(), newOwner, "Owner should be updated to the new owner");
    }

    function testRevertIfNonOwnerTransfersOwnership() public {
        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Create a new owner address
        address newOwner = makeAddr("newOwner");

        // Non-owner attempts to transfer ownership
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        strategy.transferOwnership(newOwner);

        // Verify ownership remains unchanged
        assertEq(strategy.owner(), owner, "Owner should remain unchanged");

        // Verify the registry still has the original owner
        assertTrue(registry.isUserStrategy(owner, address(strategy)), "Registry should still have the original owner");
    }

    function testRevertIfTransferOwnershipToZeroAddress() public {
        // Owner attempts to transfer ownership to zero address
        vm.prank(owner);
        vm.expectRevert("Invalid new owner address");
        strategy.transferOwnership(address(0));

        // Verify ownership remains unchanged
        assertEq(strategy.owner(), owner, "Owner should remain unchanged");

        // Verify the registry still has the original owner
        assertTrue(registry.isUserStrategy(owner, address(strategy)), "Registry should still have the original owner");
    }

    function testNewOwnerCanPerformOwnerActions() public {
        // Create a new owner address
        address newOwner = makeAddr("newOwner");

        // First, we need to ensure the registry recognizes the strategy as belonging to the owner
        assertTrue(
            registry.isUserStrategy(owner, address(strategy)),
            "Registry should recognize strategy as belonging to owner"
        );

        // Mock the registry's behavior for this test
        // In a real scenario, the registry would need to be updated by the backend
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMamoStrategyRegistry.updateStrategyOwner.selector, newOwner),
            abi.encode()
        );

        // Now the owner can transfer ownership
        vm.prank(owner);
        strategy.transferOwnership(newOwner);

        // Verify ownership was transferred
        assertEq(strategy.owner(), newOwner, "Owner should be updated to the new owner");

        // Verify new owner can perform owner-only actions
        // For example, setting slippage
        uint256 newSlippage = 200; // 2%
        vm.prank(newOwner);
        strategy.setSlippage(newSlippage);

        // Verify the slippage was updated
        assertEq(strategy.allowedSlippageInBps(), newSlippage, "New owner should be able to update slippage");

        // Verify old owner can no longer perform owner-only actions
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", owner));
        strategy.setSlippage(300);
    }

    // Tests for renounceOwnership function

    function testRevertIfOwnerRenounceOwnership() public {
        // Owner attempts to renounce ownership
        vm.prank(owner);
        vm.expectRevert("Ownership cannot be renounced in this contract");
        strategy.renounceOwnership();

        // Verify ownership remains unchanged
        assertEq(strategy.owner(), owner, "Owner should remain unchanged");

        // Verify the registry still has the original owner
        assertTrue(registry.isUserStrategy(owner, address(strategy)), "Registry should still have the original owner");
    }

    function testRevertIfNonOwnerRenounceOwnership() public {
        // Create a non-owner address
        address nonOwner = makeAddr("nonOwner");

        // Non-owner attempts to renounce ownership
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        strategy.renounceOwnership();

        // Verify ownership remains unchanged
        assertEq(strategy.owner(), owner, "Owner should remain unchanged");

        // Verify the registry still has the original owner
        assertTrue(registry.isUserStrategy(owner, address(strategy)), "Registry should still have the original owner");
    }
    // ==================== ADDITIONAL TESTS FOR BRANCH COVERAGE ====================

    function testTransferOwnershipCallsRegistryUpdateStrategyOwner() public {
        // Create a new owner address
        address newOwner = makeAddr("newOwner");

        // Check initial ownership
        assertEq(strategy.owner(), owner, "Initial owner should be the original owner");

        // First, we need to ensure the registry recognizes the strategy as belonging to the owner
        assertTrue(
            registry.isUserStrategy(owner, address(strategy)),
            "Registry should recognize strategy as belonging to owner"
        );

        // Set up event monitoring to check if the registry's updateStrategyOwner is called
        vm.expectCall(
            address(registry), abi.encodeWithSelector(IMamoStrategyRegistry.updateStrategyOwner.selector, newOwner)
        );

        // Transfer ownership
        vm.prank(owner);
        strategy.transferOwnership(newOwner);

        // Verify ownership was transferred
        assertEq(strategy.owner(), newOwner, "Owner should be updated to the new owner");
    }

    function testInitializeWithRewardTokens() public {
        // Deploy a new implementation for testing initialization
        MamoMultiMarketStrategy newImpl = new MamoMultiMarketStrategy();

        // Whitelist the implementation
        vm.prank(admin);
        uint256 _strategyTypeId = registry.whitelistImplementation(address(newImpl), 0);

        // Register markets for the new type (skip if already registered from proposal)
        if (marketRegistry.getMarketCount(address(underlying)) == 0) {
            vm.startPrank(backend);
            marketRegistry.addMarket(address(underlying), address(mToken), MarketType.MTOKEN);
            marketRegistry.addMarket(address(underlying), address(metaMorphoVault), MarketType.ERC4626);
            vm.stopPrank();
        }

        // Create reward tokens array
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(well);

        uint256[] memory initSplits = new uint256[](2);
        initSplits[0] = 5000;
        initSplits[1] = 5000;

        // Initialize with reward tokens
        vm.prank(backend);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(newImpl),
            abi.encodeWithSelector(
                MamoMultiMarketStrategy.initialize.selector,
                MamoMultiMarketStrategy.InitParams({
                    mamoStrategyRegistry: address(registry),
                    mamoBackend: backend,
                    token: address(underlying),
                    slippagePriceChecker: address(slippagePriceChecker),
                    feeRecipient: admin,
                    strategyTypeId: _strategyTypeId,
                    rewardTokens: rewardTokens, // Non-empty reward tokens array
                    owner: owner,
                    hookGasLimit: config.hookGasLimit,
                    allowedSlippageInBps: config.allowedSlippageInBps,
                    compoundFee: config.compoundFee,
                    marketRegistry: address(marketRegistry),
                    defaultSplitBps: initSplits
                })
            )
        );

        MamoMultiMarketStrategy strategyWithRewards = MamoMultiMarketStrategy(payable(address(proxy)));

        // Verify the strategy was initialized properly
        assertEq(strategyWithRewards.owner(), owner);

        // Verify the reward token was approved
        uint256 allowance =
            IERC20(address(well)).allowance(address(strategyWithRewards), strategyWithRewards.VAULT_RELAYER());
        assertEq(allowance, type(uint256).max, "Reward token should be approved for the vault relayer");
    }

    function testRevertIfMTokenRedeemFails() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Mock the redeemUnderlying function to fail
        // We need to mock any redeemUnderlying call since we don't know the exact amount that will be redeemed
        vm.mockCall(
            address(mToken),
            abi.encodeWithSelector(IMToken.redeemUnderlying.selector),
            abi.encode(uint256(1)) // Return 1 instead of 0 to indicate failure
        );

        // Attempt to withdraw should fail
        vm.prank(owner);
        vm.expectRevert("Failed to redeem mToken");
        strategy.withdraw(depositAmount / 2);

        // Clear the mock
        vm.clearMockedCalls();
    }

    function testRevertIfWithdrawAllMTokenRedeemFails() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Get the current mToken balance
        uint256 mTokenBalance = IERC20(address(mToken)).balanceOf(address(strategy));

        // Mock the redeem function with the exact balance to make it fail
        vm.mockCall(
            address(mToken),
            abi.encodeWithSelector(IMToken.redeem.selector, mTokenBalance),
            abi.encode(uint256(1)) // Return 1 instead of 0 to indicate failure
        );

        // Attempt to withdraw all should fail
        vm.prank(owner);
        vm.expectRevert("Failed to redeem mToken");
        strategy.withdrawAll();

        // Clear the mock
        vm.clearMockedCalls();
    }

    function testRevertIfUpdatePositionMTokenRedeemFails() public {
        // First deposit funds
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Mock the redeem function to fail
        vm.mockCall(
            address(mToken),
            abi.encodeWithSelector(IMToken.redeem.selector),
            abi.encode(uint256(1)) // Return 1 instead of 0 to indicate failure
        );

        // Attempt to update position should fail
        vm.prank(multicall);
        vm.expectRevert("Failed to redeem mToken");
        strategy.updatePosition(_buildUpdatePositionArray(6000, 4000));

        // Clear the mock
        vm.clearMockedCalls();
    }

    function testRevertIfMTokenMintFails() public {
        // Prepare for deposit
        uint256 depositAmount = 1000 * 10 ** assetConfig.decimals;
        deal(address(underlying), owner, depositAmount);

        // Mock the mint function to fail
        vm.mockCall(
            address(mToken),
            abi.encodeWithSelector(IMToken.mint.selector, depositAmount),
            abi.encode(uint256(1)) // Return 1 instead of 0 to indicate failure
        );

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);

        // Attempt to deposit should fail
        vm.expectRevert("MToken mint failed");
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Clear the mock
        vm.clearMockedCalls();
    }

    function testRevertIfDepositIdleTokensMTokenMintFails() public {
        // Mint USDC directly to the strategy contract
        uint256 idleAmount = 500 * 10 ** assetConfig.decimals;
        deal(address(underlying), address(strategy), idleAmount);

        // Mock the mint function to fail
        vm.mockCall(
            address(mToken),
            abi.encodeWithSelector(IMToken.mint.selector, uint256(idleAmount)),
            abi.encode(uint256(1)) // Return 1 instead of 0 to indicate failure
        );

        // Attempt to deposit idle tokens should fail
        vm.expectRevert("MToken mint failed");
        strategy.depositIdleTokens();

        // Clear the mock
        vm.clearMockedCalls();
    }

    function testRevertIfUpdatePositionMTokenMintFails() public {
        // First deposit funds
        uint256 depositAmount = 1 * 10 ** (assetConfig.decimals);
        deal(address(underlying), owner, depositAmount);

        vm.startPrank(owner);
        underlying.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);
        vm.stopPrank();

        // Mock the mint function to fail
        vm.mockCall(
            address(mToken),
            abi.encodeWithSelector(IMToken.mint.selector),
            abi.encode(uint256(1)) // Return 1 instead of 0 to indicate failure
        );

        // Now update position should fail on mint
        vm.prank(multicall);
        vm.expectRevert("MToken mint failed");
        strategy.updatePosition(_buildUpdatePositionArray(6000, 4000));

        // Clear the mocks
        vm.clearMockedCalls();
    }

    /**
     * @notice Test that WETH strategy can receive ETH and automatically wraps it
     * @dev When ETH is sent to a WETH strategy, it should:
     *      1. Accept the ETH transfer
     *      2. Automatically wrap it to WETH
     *      3. Increase the contract's WETH balance by the sent amount
     */
    function testReceiveETHAndWrap() public {
        // Skip this test if not testing WETH strategy
        if (keccak256(abi.encodePacked(assetConfig.token)) != keccak256(abi.encodePacked("WETH"))) {
            vm.skip(true);
        }

        uint256 testEthAmount = 1 ether;
        vm.deal(owner, testEthAmount);

        // Record initial WETH balance
        uint256 initialWethBalance = IERC20(WETH_ADDRESS).balanceOf(address(strategy));

        // Send ETH to the strategy
        vm.prank(owner);
        (bool success,) = address(strategy).call{value: testEthAmount}("");
        assertTrue(success, "ETH transfer should succeed");

        // Verify WETH balance increased
        uint256 finalWethBalance = IERC20(WETH_ADDRESS).balanceOf(address(strategy));
        assertEq(
            finalWethBalance - initialWethBalance,
            testEthAmount,
            "WETH balance should increase by the amount of ETH sent"
        );

        // Verify contract has no remaining ETH
        assertEq(address(strategy).balance, 0, "Strategy should have zero ETH balance after wrapping");
    }

    /**
     * @notice Test that owner can withdraw funds from the strategy, when the underlying token is WETH
     */
    function testOwnerCanWithdrawFundsWETH() public {
        // Skip this test if not testing WETH strategy
        if (keccak256(abi.encodePacked(assetConfig.token)) != keccak256(abi.encodePacked("WETH"))) {
            vm.skip(true);
        }

        uint256 depositAmount = 10 ether;
        deal(WETH_ADDRESS, owner, depositAmount);

        vm.startPrank(owner);
        IERC20(WETH_ADDRESS).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount);

        assertEq(IERC20(WETH_ADDRESS).balanceOf(owner), 0, "Owner's WETH balance should be 0 after deposit");
        uint256 strategyBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(strategyBalance, depositAmount, 1e15, "Strategy should have the deposited amount");

        uint256 withdrawAmount = depositAmount / 2;
        uint256 ethBalanceBefore = address(strategy).balance;
        strategy.withdraw(withdrawAmount);
        vm.stopPrank();

        assertApproxEqAbs(
            IERC20(WETH_ADDRESS).balanceOf(owner),
            withdrawAmount,
            1e15,
            "Owner should have received the withdrawn amount in WETH"
        );

        // Verify no ETH is stuck in the contract (all ETH should be wrapped back to WETH)
        uint256 ethBalanceAfter = address(strategy).balance;
        assertEq(ethBalanceAfter, ethBalanceBefore, "Strategy should have no additional ETH after withdrawal");

        // Verify the strategy's balance decreased
        uint256 newStrategyBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(
            newStrategyBalance,
            strategyBalance - withdrawAmount,
            1e15,
            "Strategy balance should decrease by withdrawn amount"
        );

        // Verify the protocol balances reflect the withdrawal
        uint256 expectedMTokenAmount = ((depositAmount - withdrawAmount) * splitMToken) / 10000;
        uint256 expectedVaultAmount = ((depositAmount - withdrawAmount) * splitVault) / 10000;

        // Verify mToken balance
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(strategy));
        assertApproxEqAbs(
            mTokenBalance, expectedMTokenAmount, 1e15, "mToken balance should be updated after withdrawal"
        );

        // Verify vault balance
        uint256 vaultShares = metaMorphoVault.balanceOf(address(strategy));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(vaultShares);
        assertApproxEqAbs(vaultBalance, expectedVaultAmount, 1e15, "Vault balance should be updated after withdrawal");
    }

    function parseUint(string memory json, string memory key) internal pure returns (uint256) {
        bytes memory valueBytes = vm.parseJson(json, key);
        string memory valueString = abi.decode(valueBytes, (string));
        return vm.parseUint(valueString);
    }

    function getTotalBalance(address _strategy) internal returns (uint256) {
        uint256 metaMorphoShares = metaMorphoVault.balanceOf(_strategy);
        uint256 metaMorphoBalance = metaMorphoShares > 0 ? metaMorphoVault.convertToAssets(metaMorphoShares) : 0;
        uint256 mTokenBalance = mToken.balanceOfUnderlying(_strategy);
        uint256 tokenBalance = IERC20(address(well)).balanceOf(_strategy);

        return metaMorphoBalance + mTokenBalance + tokenBalance;
    }

    /**
     * @notice Generates app data hash for CoW Swap orders
     * @param sellToken The address of the token being sold
     * @param _feeRecipient The address that will receive the fee
     * @param sellAmount The amount of tokens being sold
     * @param fromAddress The address the order is from
     * @return bytes32 The app data hash
     */
    function generateAppDataHash(address sellToken, address _feeRecipient, uint256 sellAmount, address fromAddress)
        internal
        returns (bytes32)
    {
        // Use FFI to call our generate-appdata script
        string[] memory ffiCommand = new string[](15);
        ffiCommand[0] = "npx";
        ffiCommand[1] = "ts-node";
        ffiCommand[2] = "test/utils/generate-appdata.ts";
        ffiCommand[3] = "--sell-token";
        ffiCommand[4] = vm.toString(sellToken);
        ffiCommand[5] = "--fee-recipient";
        ffiCommand[6] = vm.toString(_feeRecipient);
        ffiCommand[7] = "--sell-amount";
        ffiCommand[8] = vm.toString(sellAmount);
        ffiCommand[9] = "--compound-fee";
        ffiCommand[10] = vm.toString(assetConfig.strategyParams.compoundFee);
        ffiCommand[11] = "--from";
        ffiCommand[12] = vm.toString(fromAddress);
        ffiCommand[13] = "--hook-gas-limit";
        ffiCommand[14] = vm.toString(assetConfig.strategyParams.hookGasLimit);

        // Execute the command and get the appData
        bytes memory appDataResult = vm.ffi(ffiCommand);

        return bytes32(appDataResult);
    }
}
