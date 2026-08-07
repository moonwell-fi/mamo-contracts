// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAeroManager} from "@contracts/leveraged-aero/LeveragedAeroManager.sol";
import {LeveragedAeroValuation} from "@contracts/leveraged-aero/LeveragedAeroValuation.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {LiquidityAmounts} from "@contracts/leveraged-aero/sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {MockCLGauge} from "../mocks/MockCLGauge.sol";
import {MockCLFactory, MockCLPool} from "../mocks/MockCLPool.sol";
import {MockComptroller} from "../mocks/MockMoonwellMarket.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {
    MockAeroV2Router,
    MockChainlinkFeed,
    MockClSwapRouter,
    MockLendingMarket,
    MockNpm
} from "./LeveragedAeroVenuesHarness.sol";

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

    /// @dev The Aerodrome v2 Router address `LeveragedAeroManager` hardcodes for the AERO->USDC swap.
    address internal constant AERO_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

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
        gauge.setPool(address(pool));
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

    // ==================== FULL LEVER-DOWN (the orphaned-NFT guard) ====================

    /**
     * @dev REGRESSION — a lever-down to zero debt must be REJECTED, not executed.
     *
     *      `_unwindLiquidity` unstakes unconditionally but re-stakes only while liquidity remains, and
     *      `_leverDown` is the one 100%-unwind caller that neither clears `$.tokenId` nor mints a
     *      replacement. Executing it therefore left a live `tokenId` pointing at an NFT the gauge no
     *      longer held, and every later `gauge.withdraw` — settle, flatten, rerange, deployIdle,
     *      compound, migrateVenue, redeploy, fulfillRedeem, emergencyRedeem — reverted forever.
     *
     *      Reverting is the fix rather than retiring the position: with the collateral still supplied,
     *      clearing `tokenId` would send `nav()` down its flat-book branch, which counts ONLY idle USDC
     *      and would erase the mUSDC collateral from NAV. A true full unwind has to redeem the
     *      collateral too — that is what `flatten()` is for.
     */
    function testAdjustLeverageToZeroIsRejected() public {
        _execute(SEED);
        uint256 tokenIdBefore = strategy.layout().tokenId;

        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroManager.FullUnwindNotSupported.selector);
        strategy.adjustLeverage(0, 0, 0);

        // Nothing moved, and the position is still staked — the whole point of the guard.
        assertEq(strategy.layout().tokenId, tokenIdBefore, "position untouched");
        assertTrue(gauge.stakedContains(address(strategy), tokenIdBefore), "NFT still staked");
        assertGt(mLegB.borrowBalance(address(strategy)), 0, "leg B debt untouched");
        assertGt(mLegA.borrowBalance(address(strategy)), 0, "leg A debt untouched");
    }

    /// @dev The guard is on the DEBT delta, not on the literal argument: a tiny non-zero target whose
    ///      `targetDebt` floors to 0 against the live collateral reaches the same branch and must be
    ///      rejected identically.
    function testAdjustLeverageToADustTargetThatFloorsToZeroDebtIsRejected() public {
        _execute(SEED);
        // targetDebt = targetLtvBps * collateral / 10000; with collateral < 10000 (USDC 6dp) any
        // targetLtvBps of 1 floors to 0. Shrink the collateral basis to reach that band.
        mUsdc.setExchangeRateStored(1);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroManager.FullUnwindNotSupported.selector);
        strategy.adjustLeverage(1, 0, 0);
    }

    /// @dev The guard must NOT catch an ordinary lever-down: a partial repay leaves liquidity, so the
    ///      re-stake fires and the invariant holds.
    function testPartialLeverDownKeepsThePositionStaked() public {
        _execute(SEED);
        uint256 tokenId = strategy.layout().tokenId;

        vm.prank(proposer);
        strategy.adjustLeverage(3000, 0, 0);

        assertEq(strategy.layout().tokenId, tokenId, "same position");
        assertTrue(gauge.stakedContains(address(strategy), tokenId), "re-staked after a partial unwind");
        assertGt(mLegB.borrowBalance(address(strategy)), 0, "debt reduced, not cleared");
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

    // ==================== BORROW-INTEREST RE-HEDGE (both legs drift here) ====================

    /**
     * @dev THE TWO-LEG FINDING, pinned. This shape borrows BOTH legs and LPs them against each other, so
     *      BOTH accrue interest that the LP never grows to match — the drift is not an asset-mode
     *      peculiarity, it is a property of "borrow a leg, LP the leg". `compound` therefore tracks a
     *      hedged-principal basis per leg (`Layout.hedgedDebtA/B`) and neutralises both out of the one
     *      shared harvest budget.
     *
     *      Treating this shape as a no-op (the tempting reading of "asset-mode bug") would have left the
     *      audited shape with the ORIGINAL bug intact on two legs instead of one.
     */
    function testCompoundRehedgesBorrowInterestOnBOTHLegs() public {
        // Etch + fund the Aerodrome-v2 router the AERO->USDC harvest leg hardcodes.
        MockAeroV2Router aeroRouterImpl = new MockAeroV2Router(address(aero), address(usdc), 1e6);
        vm.etch(AERO_V2_ROUTER, address(aeroRouterImpl).code);
        usdc.mint(AERO_V2_ROUTER, 100_000_000e6);

        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);

        // Genesis is hedged on both legs to the wei.
        (uint128 hedgedA0, uint128 hedgedB0) = strategy.hedgedDebt();
        assertEq(uint256(hedgedA0), mLegA.borrowBalance(address(strategy)), "leg-A basis == leg-A debt");
        assertEq(uint256(hedgedB0), mLegB.borrowBalance(address(strategy)), "leg-B basis == leg-B debt");
        assertGt(uint256(hedgedB0), 0, "leg B really is borrowed in this shape");

        // Interest accrues on BOTH legs (50 bps each), with no LP change on either side.
        uint256 interestA = mLegA.borrowBalance(address(strategy)) / 200;
        uint256 interestB = mLegB.borrowBalance(address(strategy)) / 200;
        mLegA.accrueBorrowInterest(address(strategy), interestA);
        mLegB.accrueBorrowInterest(address(strategy), interestB);
        assertEq(mLegA.borrowBalance(address(strategy)) - hedgedA0, interestA, "leg-A drift armed");
        assertEq(mLegB.borrowBalance(address(strategy)) - hedgedB0, interestB, "leg-B drift armed");

        // Harvest, with proceeds covering both accruals and still leaving something to redeploy.
        uint256 aeroAmt = 40_000e18; // $40k vs two ~$1.25k accruals
        aero.mint(address(gauge), aeroAmt);
        gauge.setAeroToPayOnGetReward(aeroAmt);
        gauge.setEarnedAmount(aeroAmt);

        uint256 collateralBefore = (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18;
        vm.prank(proposer);
        strategy.compound(1, 0);

        // BOTH drifts neutralised (tolerance = integer-division dust on the two-way oracle convert).
        (uint128 hedgedA1, uint128 hedgedB1) = strategy.hedgedDebt();
        assertApproxEqAbs(mLegA.borrowBalance(address(strategy)), uint256(hedgedA1), 1e10, "leg-A drift neutralised");
        assertApproxEqAbs(mLegB.borrowBalance(address(strategy)), uint256(hedgedB1), 100, "leg-B drift neutralised");
        // ...and the harvest still redeployed: the hedge is a cost off the proceeds, not the whole of them.
        assertGt(
            (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18,
            collateralBefore,
            "the remainder of the harvest was still reinvested"
        );
    }

    /// @dev The discrimination property holds in this shape too: with ZERO interest accrued, a price move
    ///      that legitimately shifts the LP's leg mix must not be mistaken for drift and bought back.
    function testTwoLegCompoundDoesNotChaseAPriceDrivenLegDivergence() public {
        MockAeroV2Router aeroRouterImpl = new MockAeroV2Router(address(aero), address(usdc), 1e6);
        vm.etch(AERO_V2_ROUTER, address(aeroRouterImpl).code);
        usdc.mint(AERO_V2_ROUTER, 100_000_000e6);

        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);

        // Move the pool (spot AND twap, so the calm-gate stays open) and re-peg leg B's oracle to it, so
        // the fixture stays internally consistent. Leg B is token0, so a HIGHER tick makes leg B dearer.
        int24 newTick = TICK + 400;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(newTick));
        pool.setTick(newTick);
        pool.setTwapTick(newTick);
        // 1.0001^400 = 1.040807 -- keep the oracle on the SAME mark as the pool, or the fixture would be
        // testing an oracle/pool divergence instead of an LP leg-mix move.
        uint256 newPB = (P_LEG_B * 1_040_807) / 1_000_000;
        legBFeed.setAnswer(int256(newPB));
        router.setRate(address(legB), address(usdc), (newPB * 1e18) / (100 * 1e8));
        router.setRate(address(usdc), address(legB), (100 * 1e8 * 1e18) / newPB);

        uint256 debtA = mLegA.borrowBalance(address(strategy));
        uint256 debtB = mLegB.borrowBalance(address(strategy));

        // The move really did shift the LP's leg mix: leg B rose, so the LP sold leg B into it and now
        // holds materially LESS leg B than the leg-B debt. That is the gap a `debt - lpLeg` measure would
        // have chased. (Leg B is token0 in this fixture.)
        (uint256 lpLegB,) = LiquidityAmounts.getAmountsForLiquidity(
            pool.sqrtPriceX96(),
            TickMath.getSqrtRatioAtTick(strategy.layout().posTickLower),
            TickMath.getSqrtRatioAtTick(strategy.layout().posTickUpper),
            npm.liquidityOf(strategy.layout().tokenId)
        );
        assertGt(debtB - lpLegB, debtB / 100, "the price move opened a MATERIAL leg-B gap (>1% of debt)");
        (uint128 hA, uint128 hB) = strategy.hedgedDebt();
        assertEq(debtA, uint256(hA), "...but leg-A interest drift is exactly zero");
        assertEq(debtB, uint256(hB), "...and so is leg-B's");

        uint256 aeroAmt = 40_000e18;
        aero.mint(address(gauge), aeroAmt);
        gauge.setAeroToPayOnGetReward(aeroAmt);
        gauge.setEarnedAmount(aeroAmt);

        uint256 legAInRouter = legA.balanceOf(address(router));
        uint256 legBInRouter = legB.balanceOf(address(router));
        vm.prank(proposer);
        strategy.compound(1, 0);

        // The CL router pays the bought leg out of its own balance, so unchanged balances prove that no
        // hedge buy was routed on either leg despite the LP's leg mix having moved.
        assertEq(legA.balanceOf(address(router)), legAInRouter, "no leg-A hedge buy on a pure price move");
        assertEq(legB.balanceOf(address(router)), legBInRouter, "no leg-B hedge buy on a pure price move");
        assertGt(mLegA.borrowBalance(address(strategy)), debtA, "leg-A debt only grew (redeploy borrow)");
        assertGt(mLegB.borrowBalance(address(strategy)), debtB, "leg-B debt only grew (redeploy borrow)");
    }
}
