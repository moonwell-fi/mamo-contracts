// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {BaseStrategy} from "@contracts/BaseStrategy.sol";
import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StrategyFactory} from "@contracts/StrategyFactory.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {WhitelistWETHStrategyImplementation} from "@multisig/mamo-multisig/010_WhitelistWETHStrategyImplementation.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";

/**
 * @title WETHStrategyIntegrationTest
 * @notice Tests for the ETH receiving and auto-wrapping functionality in ERC20MoonwellMorphoStrategy
 */
contract WETHStrategyIntegrationTest is Test {
    address public constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006; // Base WETH

    Addresses public addresses;
    ERC20MoonwellMorphoStrategy public wethStrategy;
    MamoStrategyRegistry public registry;

    address public owner;
    address public backend;
    address public admin;
    address public deployer;

    IMToken public mToken;
    IERC4626 public metaMorphoVault;

    uint256 public splitMToken;
    uint256 public splitVault;

    function setUp() public {
        // workaround to make test contract work with mappings
        vm.makePersistent(DEFAULT_TEST_CONTRACT);

        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Load deployed contracts
        registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        backend = registry.getBackendAddress();
        admin = addresses.getAddress("MAMO_MULTISIG");
        deployer = addresses.getAddress("DEPLOYER_EOA");

        // Setup test accounts
        owner = makeAddr("owner");
        vm.deal(owner, 100 ether);

        // Run deployment script
        WhitelistWETHStrategyImplementation whitelistWETHStrategyImplementation = new WhitelistWETHStrategyImplementation();
        whitelistWETHStrategyImplementation.run();
        addresses = whitelistWETHStrategyImplementation.addresses();

        // Load asset configuration
        string memory assetConfigPath = vm.envString("ASSET_CONFIG_PATH");
        DeployAssetConfig assetConfigDeploy = new DeployAssetConfig(assetConfigPath);
        DeployAssetConfig.Config memory assetConfig = assetConfigDeploy.getConfig();

        // Initialize protocol contracts
        mToken = IMToken(addresses.getAddress(assetConfig.moonwellMarket));
        metaMorphoVault = IERC4626(addresses.getAddress(assetConfig.metamorphoVault));

        // Load split configuration
        splitMToken = assetConfig.strategyParams.splitMToken;
        splitVault = assetConfig.strategyParams.splitVault;

        // Deploy WETH strategy for testing
        address wethStrategyFactory = addresses.getAddress("WETH_STRATEGY_FACTORY");
        vm.prank(owner);
        address wethStrategyProxy = StrategyFactory(wethStrategyFactory).createStrategyForUser(owner);
        wethStrategy = ERC20MoonwellMorphoStrategy(payable(wethStrategyProxy));
    }

    /**
     * @notice Test that WETH wethStrategy can receive ETH and automatically wraps it
     * @dev When ETH is sent to a WETH wethStrategy, it should:
     *      1. Accept the ETH transfer
     *      2. Automatically wrap it to WETH
     *      3. Increase the contract's WETH balance by the sent amount
     */
    function testReceiveETHAndWrap() public {
        uint256 testEthAmount = 1 ether;

        // Record initial WETH balance
        uint256 initialWethBalance = IERC20(WETH_ADDRESS).balanceOf(address(wethStrategy));

        // Send ETH to the wethStrategy
        vm.prank(owner);
        (bool success,) = address(wethStrategy).call{value: testEthAmount}("");
        assertTrue(success, "ETH transfer should succeed");

        // Verify WETH balance increased
        uint256 finalWethBalance = IERC20(WETH_ADDRESS).balanceOf(address(wethStrategy));
        assertEq(
            finalWethBalance - initialWethBalance,
            testEthAmount,
            "WETH balance should increase by the amount of ETH sent"
        );

        // Verify contract has no remaining ETH
        assertEq(address(wethStrategy).balance, 0, "Strategy should have zero ETH balance after wrapping");
    }

    /**
     * @notice Test that owner can withdraw funds from the strategy, when the underlying token is WETH
     */
    function testOwnerCanWithdrawFunds() public {
        uint256 depositAmount = 10 ether;
        deal(WETH_ADDRESS, owner, depositAmount);

        vm.startPrank(owner);
        IERC20(WETH_ADDRESS).approve(address(wethStrategy), depositAmount);
        wethStrategy.deposit(depositAmount);

        assertEq(IERC20(WETH_ADDRESS).balanceOf(owner), 0, "Owner's WETH balance should be 0 after deposit");
        uint256 strategyBalance = mToken.balanceOfUnderlying(address(wethStrategy));
        assertApproxEqAbs(strategyBalance, depositAmount, 1e15, "Strategy should have the deposited amount");

        uint256 withdrawAmount = depositAmount / 2;
        uint256 ethBalanceBefore = address(wethStrategy).balance;
        wethStrategy.withdraw(withdrawAmount);
        vm.stopPrank();

        assertApproxEqAbs(
            IERC20(WETH_ADDRESS).balanceOf(owner),
            withdrawAmount,
            1e15,
            "Owner should have received the withdrawn amount in WETH"
        );

        // Verify no ETH is stuck in the contract (all ETH should be wrapped back to WETH)
        uint256 ethBalanceAfter = address(wethStrategy).balance;
        assertEq(ethBalanceAfter, ethBalanceBefore, "Strategy should have no additional ETH after withdrawal");

        // Verify the strategy's balance decreased
        uint256 newStrategyBalance = mToken.balanceOfUnderlying(address(wethStrategy));
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
        uint256 mTokenBalance = mToken.balanceOfUnderlying(address(wethStrategy));
        assertApproxEqAbs(
            mTokenBalance,
            expectedMTokenAmount,
            1e15,
            "mToken balance should be updated after withdrawal"
        );

        // Verify vault balance
        uint256 vaultShares = metaMorphoVault.balanceOf(address(wethStrategy));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(vaultShares);
        assertApproxEqAbs(
            vaultBalance,
            expectedVaultAmount,
            1e15,
            "Vault balance should be updated after withdrawal"
        );
    }
}
