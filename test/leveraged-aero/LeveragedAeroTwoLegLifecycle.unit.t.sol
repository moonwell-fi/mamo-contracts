// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAeroValuation} from "@contracts/leveraged-aero/LeveragedAeroValuation.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {MockCLGauge} from "../mocks/MockCLGauge.sol";
import {MockCLFactory, MockCLPool} from "../mocks/MockCLPool.sol";
import {MockComptroller} from "../mocks/MockMoonwellMarket.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockChainlinkFeed, MockClSwapRouter, MockLendingMarket, MockNpm} from "./LeveragedAeroVenuesHarness.sol";

import {Test} from "@forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TWO-BORROWED-LEGS lifecycle regression
 * @notice The audited shape, driven END-TO-END through the venue paths that the config-emergent branch
 *         touched: `executeImpl` (restructured — the calm-gate and range derivation moved up out of
 *         `_mintAndStake`, and `_supplyCollateral`/`_computeAndBorrow` were folded into
 *         `_supplyAndBorrow`), `deployIdleImpl`, `adjustLeverage` both directions, and a partial redeem.
 *
 *         This is the proof that adding the asset-as-a-leg shape did not disturb the original one. It is
 *         NEW coverage: the pre-existing unit suite stops at `_initialize` and never opened a position
 *         (the lifecycle was fork-test-only), so a regression in the restructured genesis path would
 *         previously have gone unseen off-fork.
 *
 * @dev Fixture mirrors the asset-mode lifecycle suite but with TWO real volatile legs (leg B 8dp,
 *      leg A 18dp) against USDC collateral, both with borrow markets, feeds and leg↔USDC swap venues.
 *      Fees off. `wethIsToken0 == false` (leg B is token0).
 */
contract LeveragedAeroTwoLegLifecycleUnitTest is Test {
    address internal owner = makeAddr("owner");
    address internal proposer = makeAddr("proposer");
    address internal lp = makeAddr("lp");

    MockToken internal usdc; // 6dp collateral / unit of account
    MockToken internal legB; // 8dp borrowed leg (token0)
    MockToken internal legA; // 18dp borrowed leg (token1)
    MockToken internal aero;

    MockCLPool internal pool;
    MockCLFactory internal clFactory;
    MockCLGauge internal gauge;
    MockComptroller internal comptroller;
    MockLendingMarket internal mUsdc;
    MockLendingMarket internal mLegB;
    MockLendingMarket internal mLegA;
    MockNpm internal npm;
    MockClSwapRouter internal router;
    MockChainlinkFeed internal usdcFeed;
    MockChainlinkFeed internal legBFeed;
    MockChainlinkFeed internal legAFeed;
    MockChainlinkFeed internal aeroFeed;
    MockChainlinkFeed internal sequencerFeed;

    LeveragedAeroVault internal vault;
    LeveragedAerodromeCLStrategy internal strategy;

    int24 internal constant SPACING = 100;
    int24 internal constant LEG_B_SWAP_SPACING = 100;
    int24 internal constant LEG_A_SWAP_SPACING = 200;
    uint24 internal constant WIDTH = 4000;
    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint256 internal constant P_USDC = 1e8;
    uint256 internal constant SEED = 1_000_000e6;

    /// @dev legB = $100k @ 8dp, legA = $3k @ 18dp — a cbBTC/WETH-shaped pair.
    uint256 internal constant P_LEG_B = 1e13;
    uint256 internal constant P_LEG_A = 3000e8;

    /// @dev The pool tick whose raw price (legA-units per legB-unit, i.e. 1e18/1e8 scaled) matches the
    ///      two feed prices: raw = P_LEG_B·1e18 / (P_LEG_A·1e8) ≈ 3.33e13 ⇒ tick ≈ ln(raw)/ln(1.0001).
    int24 internal constant TICK = 311_100;

    function setUp() public {
        vm.warp(1_800_000_000);

        usdc = new MockToken("USD Coin", "USDC", 6);
        legB = new MockToken("Leg B", "LEGB", 8);
        legA = new MockToken("Leg A", "LEGA", 18);
        aero = new MockToken("Aerodrome", "AERO", 18);

        pool = new MockCLPool(address(legB), address(legA), SPACING);
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK));
        pool.setTick(TICK);
        clFactory = new MockCLFactory();
        pool.setFactory(address(clFactory));
        clFactory.setPool(address(usdc), address(legB), LEG_B_SWAP_SPACING, makeAddr("legBSwapPool"));
        clFactory.setPool(address(usdc), address(legA), LEG_A_SWAP_SPACING, makeAddr("legASwapPool"));

        gauge = new MockCLGauge(address(aero));
        comptroller = new MockComptroller();
        mUsdc = new MockLendingMarket(address(usdc));
        mLegB = new MockLendingMarket(address(legB));
        mLegA = new MockLendingMarket(address(legA));
        npm = new MockNpm(pool);
        router = new MockClSwapRouter();

        sequencerFeed = new MockChainlinkFeed(0, 8, 1, block.timestamp - 2 hours);
        usdcFeed = new MockChainlinkFeed(int256(P_USDC), 8, 1, block.timestamp);
        legBFeed = new MockChainlinkFeed(int256(P_LEG_B), 8, 1, block.timestamp);
        legAFeed = new MockChainlinkFeed(int256(P_LEG_A), 8, 1, block.timestamp);
        aeroFeed = new MockChainlinkFeed(1e8, 8, 1, block.timestamp);

        usdc.mint(address(mUsdc), 100_000_000e6);
        legB.mint(address(mLegB), 1_000_000e8);
        legA.mint(address(mLegA), 1_000_000e18);
        usdc.mint(address(router), 100_000_000e6);
        legB.mint(address(router), 1_000_000e8);
        legA.mint(address(router), 1_000_000e18);
        // Oracle-consistent router rates in both directions for both legs.
        router.setRate(address(legB), address(usdc), (P_LEG_B * 1e18) / (100 * 1e8));
        router.setRate(address(usdc), address(legB), (100 * 1e8 * 1e18) / P_LEG_B);
        router.setRate(address(legA), address(usdc), (P_LEG_A * 1e18) / (100 * 1e18));
        router.setRate(address(usdc), address(legA), (100 * 1e18 * 1e18) / P_LEG_A);

        vault = new LeveragedAeroVault(address(usdc), owner, "Leveraged Aero Vault", "lvAERO");
        strategy = LeveragedAerodromeCLStrategy(payable(Clones.clone(address(new LeveragedAerodromeCLStrategy()))));
        strategy.initialize(address(vault), proposer, abi.encode(_params()));

        vm.startPrank(owner);
        vault.setStrategy(address(strategy));
        vault.setOpenDeposits(true);
        vm.stopPrank();
    }

    function _params() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        p.usdc = address(usdc);
        p.mUsdc = address(mUsdc);
        p.mCbBTC = address(mLegB);
        p.mWeth = address(mLegA);
        p.comptroller = address(comptroller);
        p.cbBTC = address(legB);
        p.weth = address(legA);
        p.pool = address(pool);
        p.npm = address(npm);
        p.gauge = address(gauge);
        p.swapRouter = address(router);
        p.cbBTCFeed = address(legBFeed);
        p.wethFeed = address(legAFeed);
        p.usdcFeed = address(usdcFeed);
        p.sequencerFeed = address(sequencerFeed);
        p.aeroUsdFeed = address(aeroFeed);
        p.maxDelay = 1 hours;
        p.gracePeriod = 1 hours;
        p.calmDeviationTicks = 100;
        p.twapWindow = 600;
        p.tickSpacing = SPACING;
        p.cbBTCSwapTickSpacing = LEG_B_SWAP_SPACING;
        p.wethSwapTickSpacing = LEG_A_SWAP_SPACING;
        p.wethDeliversNative = false;
        p.width = WIDTH;
        p.minWidth = 200;
        p.maxWidth = 20_000;
        p.targetLtvBps = TARGET_LTV_BPS;
        p.maxLtvBps = 6500;
        p.minHealthBps = 12_000;
        p.maxSlippageBps = 100;
        p.managementFeeBps = 0;
        p.performanceFeeBps = 0;
        p.feeRecipient = address(0);
    }

    function _execute(uint256 amount) internal {
        usdc.mint(address(strategy), amount);
        vm.prank(address(vault));
        strategy.execute();
    }

    function _valueUsdc(uint256 amt, uint256 price8, uint256 dec) internal pure returns (uint256) {
        return (amt * price8 * 1e6) / ((10 ** dec) * P_USDC);
    }

    // ==================== GENESIS (the restructured executeImpl) ====================

    /**
     * @dev The audited shape, unchanged: the WHOLE deposit becomes collateral, BOTH legs are borrowed,
     *      and the borrow splits 50/50 BY USD VALUE — not against the range. Reaching these assertions
     *      means `_assertHealthy` passed inside `execute`.
     */
    function testExecuteSuppliesWholeDepositAndBorrowsBothLegsFiftyFifty() public {
        assertFalse(strategy.layout().legBIsAsset, "two-borrowed-legs shape");

        _execute(SEED);

        // Whole deposit as collateral — the defining difference from asset-mode.
        uint256 collateral = (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18;
        assertEq(collateral, SEED, "the WHOLE deposit is supplied as collateral");

        // BOTH legs borrowed, each worth half of `SEED x targetLtv`.
        uint256 debtB = mLegB.borrowBalance(address(strategy));
        uint256 debtA = mLegA.borrowBalance(address(strategy));
        assertGt(debtB, 0, "leg B borrowed");
        assertGt(debtA, 0, "leg A borrowed");
        uint256 halfTarget = (SEED * TARGET_LTV_BPS) / 10_000 / 2;
        assertApproxEqRel(_valueUsdc(debtB, P_LEG_B, 8), halfTarget, 1e12, "leg B is half the borrow by USD");
        assertApproxEqRel(_valueUsdc(debtA, P_LEG_A, 18), halfTarget, 1e12, "leg A is half the borrow by USD");

        // LTV on target, position minted + staked at the centred range.
        uint256 debtUsdc = _valueUsdc(debtB, P_LEG_B, 8) + _valueUsdc(debtA, P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, uint256(TARGET_LTV_BPS), 1, "LTV == target");

        (int24 tickLower, int24 tickUpper) = LeveragedAeroValuation.centeredTickRange(address(pool), SPACING, WIDTH);
        assertEq(strategy.layout().posTickLower, tickLower, "range persisted");
        assertEq(strategy.layout().posTickUpper, tickUpper, "range persisted");
        assertGt(strategy.layout().tokenId, 0, "position minted");
        assertEq(gauge.depositCallCount(), 1, "staked");
    }

    /// @dev The hoisted calm-gate must still bite at genesis: a spot tick shoved away from the TWAP
    ///      reverts BEFORE any venue call (the gate moved from `_mintAndStake` up into `executeImpl`,
    ///      so this pins that it did not get lost in the move).
    function testExecuteCalmGateStillBlocksAShovedTick() public {
        // Shove SPOT 5000 ticks (well past `calmDeviationTicks = 100`) while leaving the TWAP put.
        // `setTick` moves both, so restore the TWAP afterwards.
        pool.setTick(TICK + 5000);
        pool.setTwapTick(TICK);
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK + 5000));

        usdc.mint(address(strategy), SEED);
        vm.prank(address(vault));
        vm.expectRevert(LeveragedAeroValuation.CalmGateBreached.selector);
        strategy.execute();

        // Nothing was supplied or borrowed — the gate fired before the venue sequence.
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "no collateral supplied");
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "no leg-B borrow");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "no leg-A borrow");
    }

    /// @dev A zero balance at genesis still reverts `ExecuteZeroBalance` (the check moved inline out of
    ///      the deleted `_supplyCollateral`).
    function testExecuteRevertsOnZeroBalance() public {
        vm.prank(address(vault));
        vm.expectRevert(LeveragedAerodromeCLStrategy.ExecuteZeroBalance.selector);
        strategy.execute();
    }

    // ==================== deployIdle / adjustLeverage ====================

    /// @dev `deployIdle` still supplies the whole amount and borrows both legs at target.
    function testDeployIdleSuppliesWholeAmountAndBorrowsBothLegs() public {
        _execute(SEED);
        uint256 collateralBefore = mUsdc.balanceOf(address(strategy));
        uint256 debtBBefore = mLegB.borrowBalance(address(strategy));
        uint256 debtABefore = mLegA.borrowBalance(address(strategy));

        uint256 topUp = 250_000e6;
        usdc.mint(address(strategy), topUp);
        vm.prank(proposer);
        strategy.deployIdle(topUp, 0);

        assertEq(mUsdc.balanceOf(address(strategy)) - collateralBefore, topUp, "whole top-up became collateral");
        assertGt(mLegB.borrowBalance(address(strategy)), debtBBefore, "leg B borrowed more");
        assertGt(mLegA.borrowBalance(address(strategy)), debtABefore, "leg A borrowed more");

        uint256 collateral = mUsdc.balanceOf(address(strategy));
        uint256 debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, uint256(TARGET_LTV_BPS), 2, "LTV still on target");
    }

    /// @dev BOTH leverage directions in the two-leg shape, UNCHANGED by the asset-mode lever-up work:
    ///      a lever-UP is still SELF-FUNDING (both LP sides come from the two borrows — it must consume NO
    ///      idle USDC, unlike asset-mode), splits the delta 50/50 by USD, and lands on the new target.
    function testAdjustLeverageBothDirections() public {
        _execute(SEED);
        uint256 debtBBefore = mLegB.borrowBalance(address(strategy));
        uint256 debtABefore = mLegA.borrowBalance(address(strategy));
        usdc.mint(address(strategy), 100_000e6); // idle that a two-leg lever-up must NOT touch
        uint256 idleBefore = usdc.balanceOf(address(strategy));

        vm.prank(proposer);
        strategy.adjustLeverage(6000, 0, 0); // lever UP — allowed here
        assertGt(mLegB.borrowBalance(address(strategy)), debtBBefore, "lever UP borrowed more leg B");
        assertGt(mLegA.borrowBalance(address(strategy)), debtABefore, "lever UP borrowed more leg A");
        assertEq(usdc.balanceOf(address(strategy)), idleBefore, "two-leg lever UP is self-funding: idle untouched");

        // The delta is still 50/50 by USD, and LTV landed on the new target.
        uint256 collateral = mUsdc.balanceOf(address(strategy));
        uint256 deltaB = _valueUsdc(mLegB.borrowBalance(address(strategy)) - debtBBefore, P_LEG_B, 8);
        uint256 deltaA = _valueUsdc(mLegA.borrowBalance(address(strategy)) - debtABefore, P_LEG_A, 18);
        assertApproxEqRel(deltaB, deltaA, 1e12, "the lever-UP delta split 50/50 by USD");
        uint256 debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, 6000, 2, "LTV == the new target");

        uint256 debtBUp = mLegB.borrowBalance(address(strategy));
        vm.prank(proposer);
        strategy.adjustLeverage(3000, 0, 0); // lever DOWN
        assertLt(mLegB.borrowBalance(address(strategy)), debtBUp, "lever DOWN repaid leg B");
    }

    // ==================== TARGET-LTV PERSISTENCE (two-borrowed-legs) ====================

    /// @dev The persist is SHAPE-INDEPENDENT — it is one write on the shared `adjustLeverageImpl` path,
    ///      so it holds in the two-borrowed-legs shape exactly as in asset-mode, both directions. The
    ///      dedicated getter and `layout()` are the same storage read and are asserted together.
    function testAdjustLeveragePersistsTheStandingTarget() public {
        _execute(SEED);
        assertEq(strategy.targetLtvBps(), TARGET_LTV_BPS, "genesis: the init target IS the standing target");
        assertEq(strategy.layout().targetLtvBps, TARGET_LTV_BPS, "genesis: getter == layout()");

        vm.prank(proposer);
        strategy.adjustLeverage(6000, 0, 0); // lever UP (self-funding in this shape)
        assertEq(strategy.targetLtvBps(), 6000, "lever UP persisted the new standing target");
        assertEq(strategy.layout().targetLtvBps, 6000, "getter == layout() after lever UP");

        vm.prank(proposer);
        strategy.adjustLeverage(3000, 0, 0); // lever DOWN
        assertEq(strategy.targetLtvBps(), 3000, "lever DOWN persisted the new standing target");
        assertEq(strategy.layout().targetLtvBps, 3000, "getter == layout() after lever DOWN");
    }

    /**
     * @dev THE REGRESSION THIS FIXES, END TO END (two-leg shape). Pre-fix the retarget was per-call only,
     *      so the next `deployIdle` re-read the stale stored 5000 and borrowed 50% of the top-up instead
     *      of 60% — blending realized LTV back down off the 6000 the rebalancer had just set.
     *
     *      This shape makes the arithmetic exact and readable: the whole top-up becomes collateral and the
     *      borrow is `topUp × storedTarget`, so the added debt IS the stored target, directly observable.
     */
    function testDeployIdleAfterAdjustLeverageSizesAtTheNewTarget() public {
        _execute(SEED);

        vm.prank(proposer);
        strategy.adjustLeverage(6000, 0, 0);
        // Deliberately NOT asserting the getter here — `testAdjustLeveragePersistsTheStandingTarget`
        // owns that. This test must fail on the OBSERVABLE BORROW instead, so the regression it guards
        // is the economic one (the redeploy sizing) and not merely a storage read.

        uint256 debtBBefore = mLegB.borrowBalance(address(strategy));
        uint256 debtABefore = mLegA.borrowBalance(address(strategy));

        uint256 topUp = 250_000e6;
        usdc.mint(address(strategy), topUp);
        vm.prank(proposer);
        strategy.deployIdle(topUp, 0);

        // The borrow the redeploy added, in USDC face: 60% of the top-up, NOT the stale 50%.
        uint256 addedDebt = _valueUsdc(mLegB.borrowBalance(address(strategy)) - debtBBefore, P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)) - debtABefore, P_LEG_A, 18);
        assertApproxEqRel(addedDebt, (topUp * 6000) / 10_000, 1e12, "the redeploy borrowed at the NEW target");
        assertGt(
            addedDebt,
            (topUp * uint256(TARGET_LTV_BPS)) / 10_000,
            "strictly more than the stale 5000 sizing would have borrowed"
        );

        // And realized LTV held at the new target instead of blending down toward 5800.
        uint256 collateral = mUsdc.balanceOf(address(strategy));
        uint256 debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, 6000, 2, "realized LTV HELD at 6000");
    }

    /// @dev Out-of-band target: refused at the entrypoint, stores nothing, standing target untouched.
    function testAdjustLeverageAboveMaxRevertsAndLeavesTheStoredTargetUntouched() public {
        _execute(SEED);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvExceedsMax.selector);
        strategy.adjustLeverage(6501, 0, 0); // maxLtvBps == 6500

        assertEq(strategy.targetLtvBps(), TARGET_LTV_BPS, "a rejected target stores nothing");
        assertEq(strategy.layout().targetLtvBps, TARGET_LTV_BPS, "layout() agrees: still the init target");

        // A redeploy still borrows at the untouched init target.
        uint256 debtBefore = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        uint256 topUp = 100_000e6;
        usdc.mint(address(strategy), topUp);
        vm.prank(proposer);
        strategy.deployIdle(topUp, 0);
        uint256 addedDebt = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18) - debtBefore;
        assertApproxEqRel(
            addedDebt, (topUp * uint256(TARGET_LTV_BPS)) / 10_000, 1e12, "redeploy sized at the untouched init target"
        );
    }

    // ==================== REDEEM ====================

    /// @dev The stayer reservation in the ORIGINAL shape: with no LP-shed USDC (both LP legs are
    ///      volatile tokens), stayers keep exactly `(1-f)` of the idle USDC — the same rule, and the
    ///      pre-unwind snapshot is a no-op difference here. This is the control for the asset-mode crux.
    function testPartialRedeemReservesStayerIdle() public {
        _execute(SEED);
        uint256 idleSeed = 200_000e6;
        usdc.mint(address(strategy), idleSeed);

        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        uint256 shares = supply / 4;

        uint256 idlePre = usdc.balanceOf(address(strategy));
        vm.prank(lp);
        vault.approve(address(strategy), shares);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(shares, 0);

        uint256 lpBefore = usdc.balanceOf(lp);
        vm.prank(proposer);
        strategy.fulfillRedeem(id);

        assertEq(
            usdc.balanceOf(address(strategy)),
            idlePre - Math.mulDiv(idlePre, shares, supply),
            "stayers keep exactly (1-f) of the idle USDC"
        );
        assertGt(usdc.balanceOf(lp) - lpBefore, 0, "redeemer paid");
    }

    /// @dev Full redeem clears the book with BOTH debts repaid and the flat-book invariant restored.
    function testFullRedeemClearsBothLegs() public {
        _execute(SEED);
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        vm.prank(lp);
        vault.approve(address(strategy), supply);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(supply, 0);
        vm.prank(proposer);
        strategy.fulfillRedeem(id);

        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg-B debt cleared");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "collateral fully redeemed");
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant restored");
        assertApproxEqRel(usdc.balanceOf(lp), SEED, 5e16, "redeemer recovered ~the whole book");
    }

    /// @dev `nav()` in the two-leg shape must still count BOTH idle legs (the asset-mode skip is
    ///      conditional on `cbBTC == usdc`, so it must not fire here).
    function testNavCountsBothIdleLegs() public {
        _execute(SEED);
        uint256 navBefore = strategy.nav();

        legB.mint(address(strategy), 1e8); // 1 legB == $100k
        assertApproxEqRel(strategy.nav(), navBefore + 100_000e6, 1e13, "idle leg B counted");

        navBefore = strategy.nav();
        legA.mint(address(strategy), 1e18); // 1 legA == $3k
        assertApproxEqRel(strategy.nav(), navBefore + 3_000e6, 1e13, "idle leg A counted");
    }
}
