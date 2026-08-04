// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {MamoVaultConfig} from "@contracts/robinhood/MamoVaultConfig.sol";
import {MorphoVaultsStrategy} from "@contracts/robinhood/MorphoVaultsStrategy.sol";

import {MockERC20} from "@test/MockERC20.sol";
import {
    MockERC4626,
    MockMerkleDistributor,
    MockSlippagePriceChecker,
    MockStrategyRegistry,
    MockSwapRouter
} from "@test/mocks/RobinhoodMocks.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MorphoVaultsStrategyUnitTest is Test {
    uint256 public constant SUPPLY_CAP = 1_000_000e18;
    uint256 public constant STRATEGY_TYPE_ID = 1;
    uint256 public constant SLIPPAGE_BPS = 100; // 1%
    uint256 public constant COMPOUND_FEE_BPS = 500; // 5%

    address public admin = makeAddr("adminMultisig");
    address public backend = makeAddr("backend");
    address public user = makeAddr("user");
    address public feeRecipient = makeAddr("feeRecipient");

    MockERC20 public usdg;
    MockERC20 public morphoToken;
    MockERC4626 public vaultA;
    MockERC4626 public vaultB;
    MockERC4626 public vaultC;
    MockStrategyRegistry public registry;
    MockSlippagePriceChecker public priceChecker;
    MockSwapRouter public router;
    MockMerkleDistributor public distributor;
    MamoVaultConfig public config;
    MorphoVaultsStrategy public strategy;

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG");
        morphoToken = new MockERC20("Morpho", "MORPHO");

        vaultA = new MockERC4626(IERC20(address(usdg)), "Vault A", "vA");
        vaultB = new MockERC4626(IERC20(address(usdg)), "Vault B", "vB");
        vaultC = new MockERC4626(IERC20(address(usdg)), "Vault C", "vC");

        registry = new MockStrategyRegistry(backend);
        priceChecker = new MockSlippagePriceChecker();
        router = new MockSwapRouter();
        distributor = new MockMerkleDistributor();

        config = new MamoVaultConfig(address(usdg), address(registry), admin, SUPPLY_CAP);

        vm.startPrank(admin);
        config.addVault(address(vaultA));
        config.addVault(address(vaultB));
        config.addVault(address(vaultC));
        vm.stopPrank();

        priceChecker.setRewardToken(address(morphoToken), true);
        // oracle: 1 MORPHO = 2 USDG; pool executes at parity with the oracle by default
        priceChecker.setRate(address(morphoToken), address(usdg), 2e18);
        router.setExecRate(address(morphoToken), address(usdg), 2e18);

        strategy = MorphoVaultsStrategy(payable(_deployStrategy(user)));
        registry.setUserStrategy(user, address(strategy), true);

        usdg.mint(user, 10_000_000e18);
        vm.prank(user);
        usdg.approve(address(strategy), type(uint256).max);
    }

    function _defaultVaults() internal view returns (address[] memory vaults, uint256[] memory weights) {
        vaults = new address[](2);
        vaults[0] = address(vaultA);
        vaults[1] = address(vaultB);
        weights = new uint256[](2);
        weights[0] = 6000;
        weights[1] = 4000;
    }

    function _initParams(address owner) internal view returns (MorphoVaultsStrategy.InitParams memory params) {
        (address[] memory vaults, uint256[] memory weights) = _defaultVaults();
        params = MorphoVaultsStrategy.InitParams({
            mamoStrategyRegistry: address(registry),
            token: address(usdg),
            vaultConfig: address(config),
            slippagePriceChecker: address(priceChecker),
            dexRouter: address(router),
            merkleDistributor: address(distributor),
            feeRecipient: feeRecipient,
            strategyTypeId: STRATEGY_TYPE_ID,
            owner: owner,
            allowedSlippageInBps: SLIPPAGE_BPS,
            compoundFee: COMPOUND_FEE_BPS,
            vaults: vaults,
            weightsBps: weights
        });
    }

    function _deployStrategy(address owner) internal returns (address) {
        MorphoVaultsStrategy implementation = new MorphoVaultsStrategy();
        bytes memory initData = abi.encodeCall(MorphoVaultsStrategy.initialize, (_initParams(owner)));
        return address(new ERC1967Proxy(address(implementation), initData));
    }

    // ==================== INITIALIZATION ====================

    function testInitializeSetsState() public view {
        assertEq(address(strategy.token()), address(usdg));
        assertEq(address(strategy.vaultConfig()), address(config));
        assertEq(strategy.owner(), user);
        assertEq(strategy.compoundFee(), COMPOUND_FEE_BPS);

        (address[] memory vaults, uint256[] memory weights) = strategy.getAllocations();
        assertEq(vaults.length, 2);
        assertEq(vaults[0], address(vaultA));
        assertEq(weights[0], 6000);
        assertEq(weights[1], 4000);
    }

    function testInitializeRevertsWhenWeightsDoNotSum() public {
        MorphoVaultsStrategy implementation = new MorphoVaultsStrategy();
        MorphoVaultsStrategy.InitParams memory params = _initParams(user);
        params.weightsBps[0] = 5000; // 5000 + 4000 != 10000

        vm.expectRevert("Weights must add up to SPLIT_TOTAL");
        new ERC1967Proxy(address(implementation), abi.encodeCall(MorphoVaultsStrategy.initialize, (params)));
    }

    function testInitializeRevertsWithNonAllowlistedVault() public {
        MockERC4626 rogueVault = new MockERC4626(IERC20(address(usdg)), "Rogue", "vR");

        MorphoVaultsStrategy implementation = new MorphoVaultsStrategy();
        MorphoVaultsStrategy.InitParams memory params = _initParams(user);
        params.vaults[1] = address(rogueVault);

        vm.expectRevert("Vault not allowlisted");
        new ERC1967Proxy(address(implementation), abi.encodeCall(MorphoVaultsStrategy.initialize, (params)));
    }

    function testInitializeRevertsOnConfigAssetMismatch() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH");

        MorphoVaultsStrategy implementation = new MorphoVaultsStrategy();
        MorphoVaultsStrategy.InitParams memory params = _initParams(user);
        params.token = address(otherToken);

        vm.expectRevert("Config asset mismatch");
        new ERC1967Proxy(address(implementation), abi.encodeCall(MorphoVaultsStrategy.initialize, (params)));
    }

    // ==================== DEPOSITS & SUPPLY CAP ====================

    function testDepositSplitsAcrossVaultsByWeights() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        assertEq(vaultA.convertToAssets(vaultA.balanceOf(address(strategy))), 600e18);
        assertEq(vaultB.convertToAssets(vaultB.balanceOf(address(strategy))), 400e18);
        assertEq(strategy.getTotalBalance(), 1000e18);
        assertEq(config.totalDeposited(), 1000e18);
    }

    function testDepositRevertsOverSupplyCap() public {
        vm.prank(user);
        vm.expectRevert("Supply cap exceeded");
        strategy.deposit(SUPPLY_CAP + 1);

        // exactly at cap is fine
        vm.prank(user);
        strategy.deposit(SUPPLY_CAP);
        assertEq(config.remainingCapacity(), 0);
    }

    function testWithdrawFreesSupplyCapCapacity() public {
        vm.prank(user);
        strategy.deposit(SUPPLY_CAP);

        vm.prank(user);
        strategy.withdraw(400_000e18);
        assertEq(config.remainingCapacity(), 400_000e18);

        vm.prank(user);
        strategy.deposit(400_000e18);
        assertEq(config.remainingCapacity(), 0);
    }

    function testRecordDepositRevertsForNonStrategyCaller() public {
        // a contract with an owner() that is NOT registered in the registry
        MorphoVaultsStrategy impostor = MorphoVaultsStrategy(payable(_deployStrategy(makeAddr("attacker"))));

        vm.expectRevert("Caller is not a registered strategy");
        vm.prank(address(impostor));
        config.recordDeposit(1e18);
    }

    // ==================== WITHDRAWALS ====================

    function testWithdrawPartialPullsFromVaults() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        strategy.withdraw(700e18);

        assertEq(usdg.balanceOf(user) - balanceBefore, 700e18);
        assertEq(strategy.getTotalBalance(), 300e18);
    }

    function testWithdrawRevertsOverBalance() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        vm.prank(user);
        vm.expectRevert("Withdrawal amount exceeds available balance in strategy");
        strategy.withdraw(1001e18);
    }

    function testWithdrawAllEmptiesVaults() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        strategy.withdrawAll();

        assertEq(usdg.balanceOf(user) - balanceBefore, 1000e18);
        assertEq(strategy.getTotalBalance(), 0);
        assertEq(config.totalDeposited(), 0);
    }

    function testWithdrawOnlyOwner() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        vm.prank(backend);
        vm.expectRevert();
        strategy.withdraw(100e18);
    }

    // ==================== REBALANCING ====================

    function testUpdatePositionMovesFundsToNewVaultSet() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        address[] memory newVaults = new address[](1);
        newVaults[0] = address(vaultC);
        uint256[] memory newWeights = new uint256[](1);
        newWeights[0] = 10000;

        vm.prank(backend);
        strategy.updatePosition(newVaults, newWeights);

        assertEq(vaultA.balanceOf(address(strategy)), 0);
        assertEq(vaultB.balanceOf(address(strategy)), 0);
        assertEq(vaultC.convertToAssets(vaultC.balanceOf(address(strategy))), 1000e18);
        assertEq(strategy.getTotalBalance(), 1000e18);
    }

    function testUpdatePositionRevertsForNonAllowlistedVault() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        MockERC4626 rogueVault = new MockERC4626(IERC20(address(usdg)), "Rogue", "vR");
        address[] memory newVaults = new address[](1);
        newVaults[0] = address(rogueVault);
        uint256[] memory newWeights = new uint256[](1);
        newWeights[0] = 10000;

        vm.prank(backend);
        vm.expectRevert("Vault not allowlisted");
        strategy.updatePosition(newVaults, newWeights);
    }

    function testUpdatePositionRevertsForDuplicateVault() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        address[] memory newVaults = new address[](2);
        newVaults[0] = address(vaultA);
        newVaults[1] = address(vaultA);
        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 5000;
        newWeights[1] = 5000;

        vm.prank(backend);
        vm.expectRevert("Duplicate vault");
        strategy.updatePosition(newVaults, newWeights);
    }

    function testUpdatePositionOnlyBackend() public {
        (address[] memory vaults, uint256[] memory weights) = _defaultVaults();

        vm.prank(user);
        vm.expectRevert("Not backend");
        strategy.updatePosition(vaults, weights);
    }

    // ==================== YIELD & COMPOUNDING ====================

    function testYieldAccrualIncreasesTotalBalance() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        // simulate 10% yield in vault A by minting underlying directly to it
        usdg.mint(address(vaultA), 60e18);

        // 1 wei tolerance for ERC4626 virtual-share rounding
        assertApproxEqAbs(strategy.getTotalBalance(), 1060e18, 1);
    }

    function testCompoundRewardsSwapsSkimsFeeAndRedeposits() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        // 100 MORPHO landed from a Merkl claim; oracle says 1 MORPHO = 2 USDG
        morphoToken.mint(address(strategy), 100e18);

        vm.prank(backend);
        strategy.compoundRewards(address(morphoToken), 3000, 0);

        // 200 USDG out, 5% fee = 10 USDG to feeRecipient, 190 USDG redeposited
        assertEq(usdg.balanceOf(feeRecipient), 10e18);
        assertEq(strategy.getTotalBalance(), 1190e18);
        assertEq(morphoToken.balanceOf(address(strategy)), 0);
        // compounded yield does not consume supply cap
        assertEq(config.totalDeposited(), 1000e18);
    }

    function testCompoundRewardsRevertsWhenPoolPriceTooLow() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        morphoToken.mint(address(strategy), 100e18);

        // pool executes 2% below oracle, above the 1% slippage bound
        router.setExecRate(address(morphoToken), address(usdg), 1.96e18);

        vm.prank(backend);
        vm.expectRevert("Too little received");
        strategy.compoundRewards(address(morphoToken), 3000, 0);
    }

    function testCompoundRewardsOnlyBackend() public {
        vm.prank(user);
        vm.expectRevert("Not backend");
        strategy.compoundRewards(address(morphoToken), 3000, 0);
    }

    function testCompoundRewardsRevertsForUnconfiguredToken() public {
        MockERC20 randomToken = new MockERC20("Random", "RND");
        randomToken.mint(address(strategy), 100e18);

        vm.prank(backend);
        vm.expectRevert("Token not configured as reward");
        strategy.compoundRewards(address(randomToken), 3000, 0);
    }

    function testClaimRewardsPullsFromDistributor() public {
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(morphoToken);
        uint256[] memory rewardAmounts = new uint256[](1);
        rewardAmounts[0] = 50e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        vm.prank(backend);
        strategy.claimRewards(rewardTokens, rewardAmounts, proofs);

        assertEq(morphoToken.balanceOf(address(strategy)), 50e18);
    }

    // ==================== CONFIG GOVERNANCE ====================

    function testAddVaultOnlyOwner() public {
        MockERC4626 newVault = new MockERC4626(IERC20(address(usdg)), "New", "vN");

        vm.prank(backend);
        vm.expectRevert();
        config.addVault(address(newVault));

        vm.prank(admin);
        config.addVault(address(newVault));
        assertTrue(config.isAllowedVault(address(newVault)));
    }

    function testAddVaultRevertsOnAssetMismatch() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH");
        MockERC4626 wrongVault = new MockERC4626(IERC20(address(otherToken)), "Wrong", "vW");

        vm.prank(admin);
        vm.expectRevert("Vault asset mismatch");
        config.addVault(address(wrongVault));
    }

    function testRemovedVaultBlocksNewAllocationsButAllowsExit() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        vm.prank(admin);
        config.removeVault(address(vaultA));

        // rebalancing INTO the removed vault fails
        (address[] memory vaults, uint256[] memory weights) = _defaultVaults();
        vm.prank(backend);
        vm.expectRevert("Vault not allowlisted");
        strategy.updatePosition(vaults, weights);

        // but the user can still exit in full
        uint256 balanceBefore = usdg.balanceOf(user);
        vm.prank(user);
        strategy.withdrawAll();
        assertEq(usdg.balanceOf(user) - balanceBefore, 1000e18);
    }

    function testSetSupplyCapBelowCurrentBlocksNewDepositsOnly() public {
        vm.prank(user);
        strategy.deposit(1000e18);

        vm.prank(admin);
        config.setSupplyCap(500e18);

        vm.prank(user);
        vm.expectRevert("Supply cap exceeded");
        strategy.deposit(1e18);

        // existing funds remain withdrawable
        vm.prank(user);
        strategy.withdraw(600e18);
    }
}
