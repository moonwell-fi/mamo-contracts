// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console} from "@forge-std/Test.sol";

import {BoostedUsdgVault} from "@contracts/robinhood/BoostedUsdgVault.sol";
import {Id, MarketParams, MarketParamsLib} from "@contracts/robinhood/interfaces/IMorphoBlue.sol";

import {
    MockIrm,
    MockMintableERC20,
    MockMorphoBlue,
    MockMorphoOracle,
    MockYieldBearingVault
} from "./mocks/MorphoBlueMocks.sol";
import {MockSwapRouter} from "./mocks/RobinhoodMocks.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BoostedUsdgVaultUnitTest
 * @notice Mechanics of the pooled Boosted USDG loop against a faithful Morpho Blue mock
 * @dev The default fixture mirrors the live spUSDG market: a 6-decimal loan asset (USDG), a 6-decimal
 *      ERC-4626 collateral over that same asset (Spark Savings USDG), a 1e36 oracle reading the vault's
 *      exchange rate, and 91.5% LLTV. That combination is the interesting one for a loop, because entry and
 *      exit are exact — which means every LTV number below is arithmetic the tests can assert on the nose
 *      rather than a tolerance around a swap.
 *
 *      A second fixture (`_useDexMarket`) swaps in an 18-decimal collateral behind a Uniswap-style router,
 *      to exercise the swap route and the oracle floor that bounds it.
 */
contract BoostedUsdgVaultUnitTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 internal constant SUPPLY_CAP = 1_000_000e6;
    uint256 internal constant MAX_LTV_BPS = 8000;
    uint256 internal constant MAX_SLIPPAGE_BPS = 100;
    uint256 internal constant PERFORMANCE_FEE_BPS = 1000; // 10%
    uint256 internal constant LLTV = 0.915e18;
    uint256 internal constant LENDER_LIQUIDITY = 50_000_000e6;
    uint256 internal constant DEPOSIT = 1000e6;

    address public admin = makeAddr("adminMultisig");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");
    address public feeRecipient = makeAddr("feeRecipient");
    address public user = makeAddr("user");
    address public user2 = makeAddr("user2");
    address public lender = makeAddr("lender");

    MockMintableERC20 public usdg;
    MockYieldBearingVault public spUsdg;
    MockMintableERC20 public dexCollateral;
    MockMorphoOracle public oracle;
    MockMorphoOracle public dexOracle;
    MockIrm public irm;
    MockMorphoBlue public morpho;
    MockSwapRouter public router;
    BoostedUsdgVault public vault;

    MarketParams public marketParams;
    MarketParams public dexMarketParams;

    function setUp() public {
        usdg = new MockMintableERC20("Global Dollar", "USDG", 6);
        spUsdg = new MockYieldBearingVault(address(usdg), "Spark Savings USDG", "spUSDG", 6);
        dexCollateral = new MockMintableERC20("Wrapped Yield USDG", "wyUSDG", 18);

        // 6dp collateral over a 6dp loan asset at par: collateral * 1e36 / 1e36 == value
        oracle = new MockMorphoOracle(1e36);
        // 18dp collateral over a 6dp loan asset at par: 1e18 * 1e24 / 1e36 == 1e6
        dexOracle = new MockMorphoOracle(1e24);

        irm = new MockIrm(0);
        morpho = new MockMorphoBlue();
        router = new MockSwapRouter();

        // the router fills at oracle parity by default; 1e6 USDG in -> 1e18 collateral out
        router.setExecRate(address(usdg), address(dexCollateral), 1e30);
        router.setExecRate(address(dexCollateral), address(usdg), 1e6);

        marketParams = MarketParams({
            loanToken: address(usdg),
            collateralToken: address(spUsdg),
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });
        dexMarketParams = MarketParams({
            loanToken: address(usdg),
            collateralToken: address(dexCollateral),
            oracle: address(dexOracle),
            irm: address(irm),
            lltv: LLTV
        });

        morpho.createMarket(marketParams);
        morpho.createMarket(dexMarketParams);
        _seedLenderLiquidity(marketParams);
        _seedLenderLiquidity(dexMarketParams);

        vault = new BoostedUsdgVault(address(usdg), address(morpho), admin, "Mamo Boosted USDG", "bUSDG");

        vm.startPrank(admin);
        vault.addMarket(marketParams, BoostedUsdgVault.CollateralRoute.ERC4626, 0);
        vault.addMarket(dexMarketParams, BoostedUsdgVault.CollateralRoute.DEX, 3000);
        vault.setActiveMarket(marketParams.id());
        vault.setMaxLtv(MAX_LTV_BPS);
        vault.setMaxSlippage(MAX_SLIPPAGE_BPS);
        vault.setPerformanceFee(PERFORMANCE_FEE_BPS);
        vault.setFeeRecipient(feeRecipient);
        vault.setBackend(backend);
        vault.setGuardian(guardian);
        vault.setDexRouter(address(router));
        vault.setSupplyCap(SUPPLY_CAP);
        vm.stopPrank();

        usdg.mint(user, 10_000_000e6);
        usdg.mint(user2, 10_000_000e6);

        vm.prank(user);
        usdg.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        usdg.approve(address(vault), type(uint256).max);
    }

    // ==================== CONFIGURATION & GOVERNANCE ====================

    function testConstructorAndConfiguration() public view {
        assertEq(address(vault.asset()), address(usdg), "asset");
        assertEq(address(vault.morpho()), address(morpho), "morpho");
        assertEq(vault.owner(), admin, "owner");
        assertEq(vault.decimals(), 18, "shares are 18 decimals over a 6 decimal asset");
        assertEq(vault.maxLtvBps(), MAX_LTV_BPS, "max ltv");
        assertEq(vault.lltvBps(), 9150, "market lltv in bps");
        assertEq(vault.listedMarketsLength(), 2, "two allowlisted markets");
        assertEq(Id.unwrap(vault.activeMarketId()), Id.unwrap(marketParams.id()), "active market");
    }

    function testAddMarketRevertsOnLoanTokenMismatch() public {
        MockMintableERC20 other = new MockMintableERC20("Other", "OTH", 6);
        MarketParams memory bad = marketParams;
        bad.loanToken = address(other);

        vm.prank(admin);
        vm.expectRevert("Loan token mismatch");
        vault.addMarket(bad, BoostedUsdgVault.CollateralRoute.ERC4626, 0);
    }

    function testAddMarketRevertsForUnknownMarket() public {
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.86e18; // never created on the singleton

        vm.prank(admin);
        vm.expectRevert("Market does not exist on Morpho");
        vault.addMarket(unknown, BoostedUsdgVault.CollateralRoute.ERC4626, 0);
    }

    function testAddMarketRevertsWhenCollateralVaultAssetMismatches() public {
        MockMintableERC20 other = new MockMintableERC20("Other", "OTH", 6);
        MockYieldBearingVault wrongVault = new MockYieldBearingVault(address(other), "Wrong", "wV", 6);

        MarketParams memory bad = marketParams;
        bad.collateralToken = address(wrongVault);
        morpho.createMarket(bad);

        vm.prank(admin);
        vm.expectRevert("Collateral vault asset mismatch");
        vault.addMarket(bad, BoostedUsdgVault.CollateralRoute.ERC4626, 0);
    }

    function testSetMaxLtvRevertsTooCloseToLltv() public {
        // LLTV is 9150; the 500bps buffer means 8650 is the highest legal ceiling
        vm.prank(admin);
        vm.expectRevert("Max LTV too close to LLTV");
        vault.setMaxLtv(8651);

        vm.prank(admin);
        vault.setMaxLtv(8650);
        assertEq(vault.maxLtvBps(), 8650, "ceiling at the buffer edge is allowed");
    }

    function testLoweringMaxLtvPullsTheTargetDownWithIt() public {
        _depositAndLever(DEPOSIT, 7000);
        assertEq(vault.targetLtvBps(), 7000, "target set");

        vm.prank(admin);
        vault.setMaxLtv(5000);

        assertEq(vault.targetLtvBps(), 5000, "target clamped to the new ceiling");
        assertGt(vault.ltvBps(), 5000, "the position itself is untouched until a keeper adjusts");
    }

    function testSetActiveMarketRequiresFlatPosition() public {
        _depositAndLever(DEPOSIT, 7000);

        vm.prank(admin);
        vm.expectRevert("Position not flat");
        vault.setActiveMarket(dexMarketParams.id());

        vm.prank(backend);
        vault.deleverage(8, 0);

        vm.prank(admin);
        vault.setActiveMarket(dexMarketParams.id());
        assertEq(Id.unwrap(vault.activeMarketId()), Id.unwrap(dexMarketParams.id()), "venue switched");
        assertEq(vault.targetLtvBps(), 0, "switching venues resets the target");
    }

    function testAccessControlOnAdminAndBackendSurfaces() public {
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, backend));
        vault.setSupplyCap(1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.addMarket(marketParams, BoostedUsdgVault.CollateralRoute.ERC4626, 0);

        vm.prank(user);
        vm.expectRevert("Not backend");
        vault.openLeverage(5000, 8, 0);

        vm.prank(admin);
        vm.expectRevert("Not backend");
        vault.adjustLeverage(8, 0);

        vm.prank(user);
        vm.expectRevert("Not guardian");
        vault.pause();
    }

    // ==================== DEPOSITS & SHARE MATH ====================

    function testDepositMintsSharesAtNav() public {
        vm.prank(user);
        uint256 shares = vault.deposit(DEPOSIT, user);

        assertEq(shares, DEPOSIT * 1e12, "6dp asset mints 18dp shares 1:1 at par");
        assertEq(vault.balanceOf(user), shares, "shares credited");
        assertEq(vault.totalAssets(), DEPOSIT, "NAV equals the deposit");
        assertEq(vault.idleAssets(), DEPOSIT, "deposits land idle, not in the loop");
        assertEq(vault.sharePrice(), 1e6, "one 1e18 share unit is worth 1 USDG");
    }

    function testSecondDepositorPaysTheCurrentSharePrice() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        // realized yield lands as idle assets: NAV +10%, share price +10%
        usdg.mint(address(vault), 100e6);
        assertEq(vault.totalAssets(), 1100e6, "NAV after yield");

        vm.prank(user2);
        uint256 shares2 = vault.deposit(DEPOSIT, user2);

        assertLt(shares2, vault.balanceOf(user), "later depositor buys fewer shares at a higher price");
        assertApproxEqRel(vault.convertToAssets(shares2), DEPOSIT, 1e12, "but the same value");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(user)), 1100e6, 1e12, "first depositor keeps the gain");
    }

    function testDepositRevertsOverSupplyCap() public {
        vm.prank(user);
        vm.expectRevert("Supply cap exceeded");
        vault.deposit(SUPPLY_CAP + 1, user);

        vm.prank(user);
        vault.deposit(SUPPLY_CAP, user);
        assertEq(vault.remainingCapacity(), 0, "cap consumed");

        vm.prank(user2);
        vm.expectRevert("Supply cap exceeded");
        vault.deposit(1, user2);
    }

    function testDepositRevertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert("Amount must be greater than 0");
        vault.deposit(0, user);
    }

    // ==================== LEVERAGE: OPENING AND CONVERGENCE ====================

    function testOpenLeverageReachesTheTargetLtv() public {
        _depositAndLever(DEPOSIT, 7000);

        // 1 bps of tolerance: Blue rounds debt UP against the borrower on every borrow
        assertApproxEqAbs(vault.ltvBps(), 7000, 1, "levered to target on an exact-conversion venue");
        assertEq(vault.targetLtvBps(), 7000, "target persisted");
        assertEq(vault.idleAssets(), 0, "everything deployed");

        // equity is preserved: NAV = collateral value - debt
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT, 2, "leverage does not create or destroy NAV");
        // 1000 equity at 70% LTV => 3333 of collateral, 2333 of debt
        assertApproxEqAbs(vault.collateralValue(), 3333e6, 1e6, "collateral value");
        assertApproxEqAbs(vault.debtAssets(), 2333e6, 1e6, "debt");
        assertGt(vault.healthFactor(), 1e18, "position healthy");
    }

    function testOpenLeverageRevertsAboveMaxLtv() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        vm.prank(backend);
        vm.expectRevert("Target LTV above maximum");
        vault.openLeverage(MAX_LTV_BPS + 1, 8, 0);
    }

    function testAdjustLeverageConvergesAcrossCalls() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        // two iterations is deliberately not enough to reach 70%
        vm.prank(backend);
        vault.openLeverage(7000, 2, 0);

        uint256 ltvAfterFirst = vault.ltvBps();
        assertLt(ltvAfterFirst, 7000, "a bounded loop lands short of the target");
        assertEq(vault.targetLtvBps(), 7000, "TARGET PERSISTENCE: the shortfall does not redefine the target");

        // the keeper simply calls again; no target is re-supplied
        vm.prank(backend);
        vault.adjustLeverage(8, 0);

        assertGt(vault.ltvBps(), ltvAfterFirst, "second call moves further toward the target");
        assertApproxEqAbs(vault.ltvBps(), 7000, 1, "and converges");
        assertEq(vault.targetLtvBps(), 7000, "target unchanged throughout");
    }

    /// @dev At a target equal to the vault's own ceiling the loop is asymptotic: each iteration can only
    ///      close 1 - maxLtv of the remaining gap, so it approaches but never touches. Documented behaviour,
    ///      and the reason a product target should sit meaningfully below the ceiling.
    function testAdjustLeverageAtTheCeilingIsAsymptotic() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        vm.prank(backend);
        vault.openLeverage(MAX_LTV_BPS, 8, 0);

        uint256 first = vault.ltvBps();
        assertLt(first, MAX_LTV_BPS, "never reaches the ceiling in one call");

        vm.prank(backend);
        vault.adjustLeverage(8, 0);

        assertGt(vault.ltvBps(), first, "keeps converging");
        assertLe(vault.ltvBps(), MAX_LTV_BPS, "and never breaches the ceiling");
    }

    function testAdjustLeverageDownReducesTowardTheNewTarget() public {
        _depositAndLever(DEPOSIT, 7000);
        uint256 navBefore = vault.totalAssets();

        vm.prank(backend);
        vault.setTargetLtv(4000);

        vm.prank(backend);
        vault.adjustLeverage(8, 0);

        assertApproxEqAbs(vault.ltvBps(), 4000, 1, "unwound to the new target");
        assertApproxEqAbs(vault.totalAssets(), navBefore, 2, "delevering is NAV neutral at oracle parity");
        assertEq(vault.idleAssets(), 0, "surplus is repaid rather than parked, since the target is still levered");
    }

    function testDeleverageUnwindsToFlat() public {
        _depositAndLever(DEPOSIT, 7000);

        vm.prank(backend);
        vault.deleverage(8, 0);

        assertEq(vault.debtAssets(), 0, "no debt left");
        assertEq(vault.collateralBalance(), 0, "no collateral left");
        assertEq(vault.ltvBps(), 0, "flat");
        assertEq(vault.targetLtvBps(), 0, "target zeroed");
        assertApproxEqAbs(vault.idleAssets(), DEPOSIT, 2, "NAV recovered as idle assets");
    }

    function testBackendCannotLoosenTheSlippageCeiling() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        vm.prank(backend);
        vm.expectRevert("Slippage exceeds maximum");
        vault.openLeverage(7000, 8, MAX_SLIPPAGE_BPS + 1);
    }

    // ==================== NAV UNDER PRICE AND INTEREST ====================

    function testNavRisesWithCollateralAppreciation() public {
        _depositAndLever(DEPOSIT, 7000);

        uint256 collateralValueBefore = vault.collateralValue();

        // the collateral earns 5%; the market oracle reads the same exchange rate
        spUsdg.setExchangeRate(1.05e18);
        oracle.setPrice(1.05e36);

        // levered 3.33x, a 5% collateral move is a ~16.7% move on NAV
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT + (collateralValueBefore * 5) / 100, 2, "levered NAV gain");
        assertLt(vault.ltvBps(), 7000, "appreciation deleverages the position");

        console.log("NAV after +5%% collateral: %s (from %s)", vm.toString(vault.totalAssets()), vm.toString(DEPOSIT));
    }

    function testNavFallsWithBorrowInterestWithoutPokingTheMarket() public {
        _depositAndLever(DEPOSIT, 7000);

        uint256 debtBefore = vault.debtAssets();

        // ~5% APR, expressed per second, exactly as AdaptiveCurveIRM quotes it
        irm.setRatePerSecond(uint256(0.05e18) / 365 days);
        vm.warp(block.timestamp + 365 days);

        // nobody has called accrueInterest: this is purely the view-side accrual
        uint256 debtAfter = vault.debtAssets();
        assertGt(debtAfter, debtBefore, "debt accrues between blocks");
        assertApproxEqRel(debtAfter, (debtBefore * 10513) / 10000, 0.01e18, "~e^0.05 - 1 of interest");

        assertApproxEqAbs(vault.totalAssets(), DEPOSIT - (debtAfter - debtBefore), 2, "interest comes straight off NAV");
        assertGt(vault.ltvBps(), 7000, "and drifts the position up toward the ceiling");

        console.log("LTV drift after a year of unpaid interest: %s bps", vm.toString(vault.ltvBps()));
    }

    /// @dev A position that has drifted above the ceiling must still be fixable. The invariant is "at or
    ///      below the ceiling, OR strictly improved" precisely so this call is not rejected.
    function testAdjustLeverageRescuesAPositionAboveTheCeiling() public {
        _depositAndLever(DEPOSIT, 7900);

        irm.setRatePerSecond(uint256(0.1e18) / 365 days);
        vm.warp(block.timestamp + 365 days);

        uint256 driftedLtv = vault.ltvBps();
        assertGt(driftedLtv, MAX_LTV_BPS, "test premise: interest pushed the position above the ceiling");

        vm.prank(backend);
        vault.setTargetLtv(5000);

        vm.prank(backend);
        vault.adjustLeverage(8, 0);

        assertLt(vault.ltvBps(), driftedLtv, "the rescue is allowed even though it starts out of bounds");
        assertLe(vault.ltvBps(), MAX_LTV_BPS, "and lands back inside the ceiling");
    }

    // ==================== PERFORMANCE FEE (HIGH-WATER MARK) ====================

    function testHarvestChargesFeeOnlyOnGrowthAboveHighWaterMark() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        uint256 hwmBefore = vault.highWaterMark();
        assertEq(hwmBefore, 1e6, "HWM seeded at par on the first deposit");

        // no growth yet
        vm.prank(backend);
        assertEq(vault.harvest(), 0, "nothing to crystallize");
        assertEq(vault.balanceOf(feeRecipient), 0, "no fee shares minted");

        // +100 USDG of realized yield on a 1000 USDG book
        usdg.mint(address(vault), 100e6);

        vm.prank(backend);
        uint256 feeShares = vault.harvest();

        assertGt(feeShares, 0, "fee crystallized");
        // 10% of the 100 USDG gain
        assertApproxEqAbs(vault.convertToAssets(feeShares), 10e6, 1e4, "fee is 10% of the gain");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(user)), 1090e6, 1e4, "depositor keeps the other 90%");
        assertGt(vault.highWaterMark(), hwmBefore, "HWM advanced");
    }

    function testHarvestDoesNotChargeTwiceForTheSameGain() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);
        usdg.mint(address(vault), 100e6);

        vm.prank(backend);
        vault.harvest();
        uint256 feeSharesAfterFirst = vault.balanceOf(feeRecipient);
        uint256 hwmAfterFirst = vault.highWaterMark();

        vm.prank(backend);
        assertEq(vault.harvest(), 0, "a second harvest with no new growth charges nothing");
        assertEq(vault.balanceOf(feeRecipient), feeSharesAfterFirst, "no extra fee shares");
        assertEq(vault.highWaterMark(), hwmAfterFirst, "HWM unchanged");
    }

    function testHarvestChargesNothingAfterADrawdownUntilTheMarkIsRegained() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);
        usdg.mint(address(vault), 200e6);

        vm.prank(backend);
        vault.harvest();
        uint256 feeSharesAfterFirst = vault.balanceOf(feeRecipient);

        // drawdown: the position loses value (modelled as assets leaving the idle balance)
        vm.prank(address(vault));
        usdg.burn(address(vault), 150e6);

        vm.prank(backend);
        assertEq(vault.harvest(), 0, "no fee below the mark");

        // partial recovery, still under the mark
        usdg.mint(address(vault), 100e6);
        vm.prank(backend);
        assertEq(vault.harvest(), 0, "still no fee below the mark");
        assertEq(vault.balanceOf(feeRecipient), feeSharesAfterFirst, "fee shares unchanged through the round trip");

        // and above it again, the fee resumes on the NEW growth only
        usdg.mint(address(vault), 200e6);
        vm.prank(backend);
        assertGt(vault.harvest(), 0, "fee resumes above the mark");
    }

    function testHarvestOnlyBackend() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        vm.prank(user);
        vm.expectRevert("Not backend");
        vault.harvest();
    }

    // ==================== REDEMPTIONS ====================

    function testRedeemPartialUnwindsProRataAndKeepsLtv() public {
        _depositAndLever(DEPOSIT, 7000);

        uint256 shares = vault.balanceOf(user);
        uint256 navBefore = vault.totalAssets();
        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        uint256 assets = vault.redeem(shares / 2, user, 0);

        assertApproxEqRel(assets, navBefore / 2, 0.001e18, "half the NAV paid out");
        assertEq(usdg.balanceOf(user) - balanceBefore, assets, "user actually received it");
        assertApproxEqAbs(vault.ltvBps(), 7000, 5, "remaining holders keep the same leverage");
        assertApproxEqRel(vault.totalAssets(), navBefore / 2, 0.001e18, "half the book remains");
    }

    function testRedeemFullExitSettlesAndClosesThePosition() public {
        _depositAndLever(DEPOSIT, 7000);

        uint256 balanceBefore = usdg.balanceOf(user);

        uint256 shares = vault.balanceOf(user);

        vm.prank(user);
        uint256 assets = vault.redeem(shares, user, 0);

        assertApproxEqAbs(assets, DEPOSIT, 2, "the whole deposit comes back");
        assertEq(usdg.balanceOf(user) - balanceBefore, assets, "paid out");
        assertEq(vault.totalSupply(), 0, "all shares burnt");
        assertEq(vault.debtAssets(), 0, "position closed");
        assertEq(vault.collateralBalance(), 0, "collateral released");
    }

    function testRedeemRevertsBelowMinAssetsOut() public {
        _depositAndLever(DEPOSIT, 7000);

        uint256 half = vault.balanceOf(user) / 2;

        vm.prank(user);
        vm.expectRevert("Insufficient assets out");
        vault.redeem(half, user, DEPOSIT);
    }

    function testRedeemOfAnUnleveredVaultPaysFromIdle() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        uint256 balanceBefore = usdg.balanceOf(user);

        uint256 quarter = vault.balanceOf(user) / 4;

        vm.prank(user);
        uint256 assets = vault.redeem(quarter, user, 0);

        assertEq(assets, DEPOSIT / 4, "quarter of the idle balance");
        assertEq(usdg.balanceOf(user) - balanceBefore, assets, "paid out");
    }

    function testRedeemDoesNotDiluteTheHoldersWhoStay() public {
        vm.prank(user);
        vault.deposit(DEPOSIT, user);
        vm.prank(user2);
        vault.deposit(DEPOSIT, user2);

        vm.prank(backend);
        vault.openLeverage(7000, 8, 0);

        uint256 user2ValueBefore = vault.convertToAssets(vault.balanceOf(user2));

        uint256 shares = vault.balanceOf(user);

        vm.prank(user);
        vault.redeem(shares, user, 0);

        assertApproxEqRel(
            vault.convertToAssets(vault.balanceOf(user2)), user2ValueBefore, 0.001e18, "the stayer is unaffected"
        );
    }

    // ==================== PAUSE SEMANTICS ====================

    function testPauseBlocksDepositsAndLeverageButNeverExits() public {
        _depositAndLever(DEPOSIT, 7000);

        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused(), "paused");

        vm.prank(user);
        vm.expectRevert("Vault is paused");
        vault.deposit(1e6, user);

        vm.prank(backend);
        vm.expectRevert("Vault is paused");
        vault.adjustLeverage(8, 0);

        // the two things a pause must never block
        uint256 half = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 assets = vault.redeem(half, user, 0);
        assertGt(assets, 0, "redemptions keep working while paused");

        vm.prank(backend);
        vault.deleverage(8, 0);
        assertEq(vault.debtAssets(), 0, "risk-off keeps working while paused");
    }

    function testOnlyOwnerCanUnpause() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpause();

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused(), "unpaused");
    }

    // ==================== DEX ROUTE & THE ORACLE FLOOR ====================

    function testDexRouteLeversThroughTheRouter() public {
        _useDexMarket();

        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        vm.prank(backend);
        vault.openLeverage(7000, 8, 0);

        assertApproxEqAbs(vault.ltvBps(), 7000, 1, "levered through the swap route");
        assertGt(vault.collateralBalance(), 0, "collateral acquired via the router");
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT, 2, "no NAV lost at oracle parity");
    }

    function testDexRouteRevertsWhenThePoolFillsBelowTheOracleFloor() public {
        _useDexMarket();

        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        // the pool now fills 2% below oracle, outside the 100bps ceiling
        router.setExecRate(address(usdg), address(dexCollateral), 0.98e30);

        vm.prank(backend);
        vm.expectRevert("Too little received");
        vault.openLeverage(7000, 8, MAX_SLIPPAGE_BPS);

        assertEq(vault.collateralBalance(), 0, "no leg executed");
        assertEq(vault.totalAssets(), DEPOSIT, "NAV untouched by the rejected loop");
    }

    function testBackendCanTightenTheSlippageBoundBelowTheAdminCeiling() public {
        _useDexMarket();

        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        // a 50bps-worse pool clears the admin's 100bps ceiling but not a 10bps backend tolerance
        router.setExecRate(address(usdg), address(dexCollateral), 0.995e30);

        vm.prank(backend);
        vm.expectRevert("Too little received");
        vault.openLeverage(7000, 8, 10);

        vm.prank(backend);
        vault.openLeverage(7000, 8, MAX_SLIPPAGE_BPS);
        assertGt(vault.collateralBalance(), 0, "the same loop clears at the admin ceiling");
    }

    // ==================== HELPERS ====================

    function _depositAndLever(uint256 amount, uint256 targetBps) internal {
        vm.prank(user);
        vault.deposit(amount, user);

        vm.prank(backend);
        vault.openLeverage(targetBps, 8, 0);
    }

    /// @dev Flattens the position and points the vault at the swap-routed market
    function _useDexMarket() internal {
        vm.prank(admin);
        vault.setActiveMarket(dexMarketParams.id());

        vm.prank(admin);
        vault.setMaxLtv(MAX_LTV_BPS);
    }

    function _seedLenderLiquidity(MarketParams memory params) internal {
        usdg.mint(lender, LENDER_LIQUIDITY);

        vm.startPrank(lender);
        usdg.approve(address(morpho), type(uint256).max);
        morpho.supply(params, LENDER_LIQUIDITY, 0, lender, "");
        vm.stopPrank();
    }
}
