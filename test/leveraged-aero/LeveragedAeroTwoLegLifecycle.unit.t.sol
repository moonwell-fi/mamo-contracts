// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAeroManager} from "@contracts/leveraged-aero/LeveragedAeroManager.sol";
import {LeveragedAeroValuation} from "@contracts/leveraged-aero/LeveragedAeroValuation.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "@contracts/leveraged-aero/sherwood/BaseStrategy.sol";
import {LiquidityAmounts} from "@contracts/leveraged-aero/sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {MockCLGauge} from "../mocks/MockCLGauge.sol";
import {MockCLFactory, MockCLPool} from "../mocks/MockCLPool.sol";
import {MockComptroller} from "../mocks/MockMoonwellMarket.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {
    MockAeroV2Factory,
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
    /// @dev The centred skew — `width/2` each side, i.e. the pre-skew behaviour.
    uint16 internal constant SKEW_CENTERED = 5000;
    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint256 internal constant P_USDC = 1e8;
    uint256 internal constant SEED = 1_000_000e6;

    /// @dev legB = $100k @ 8dp, legA = $3k @ 18dp — a cbBTC/WETH-shaped pair.
    uint256 internal constant P_LEG_B = 1e13;
    uint256 internal constant P_LEG_A = 3000e8;

    /// @dev The pool tick whose raw price (legA-units per legB-unit, i.e. 1e18/1e8 scaled) matches the
    ///      two feed prices: raw = P_LEG_B·1e18 / (P_LEG_A·1e8) ≈ 3.33e13 ⇒ tick ≈ ln(raw)/ln(1.0001).
    int24 internal constant TICK = 311_100;

    /// @dev The grid-aligned tick whose RAW price actually equals the two feeds' ratio:
    ///      `raw = (P_LEG_B / P_LEG_A) × 10^(18−8) = 3.333e11`, `ln(raw)/ln(1.0001) ≈ 265_337`. `TICK`
    ///      above is ~97× off that (a long-standing property of this fixture, harmless to the venue-
    ///      mechanics tests that use it, but fatal to any test measuring a POOL-ratio effect in ORACLE
    ///      value — see `testDeployAtASkewedRangeStrandsTheSamePredictedFractionEitherWay`).
    int24 internal constant TICK_ORACLE_CONSISTENT = 265_300;

    /// @dev Aerodrome v2 PoolFactory, hardcoded in `LeveragedAeroValuation` and probed by venue
    ///      validation to prove the reward token has a USDC route. Etched below (no code otherwise).
    address internal constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @dev `LeveragedAeroVenue.applyVenue` pins the canonical Slipstream CLFactory rather than
    ///      trusting `pool.factory()`, so a fork-free test has to place the registry HERE. Etch is
    ///      safe despite `MockCLFactory` being storage-based: only the code is copied, and every
    ///      `setPool` below writes to the etched address's own storage.
    address internal constant AERODROME_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    function setUp() public {
        vm.warp(1_800_000_000);

        usdc = new MockToken("USD Coin", "USDC", 6);
        legB = new MockToken("Leg B", "LEGB", 8);
        legA = new MockToken("Leg A", "LEGA", 18);
        aero = new MockToken("Aerodrome", "AERO", 18);

        pool = new MockCLPool(address(legB), address(legA), SPACING);
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK));
        pool.setTick(TICK);
        clFactory = MockCLFactory(AERODROME_CL_FACTORY);
        vm.etch(AERODROME_CL_FACTORY, address(new MockCLFactory()).code);
        pool.setFactory(AERODROME_CL_FACTORY);
        clFactory.setPool(address(legA), address(legB), SPACING, address(pool));
        clFactory.setPool(address(usdc), address(legB), LEG_B_SWAP_SPACING, makeAddr("legBSwapPool"));
        clFactory.setPool(address(usdc), address(legA), LEG_A_SWAP_SPACING, makeAddr("legASwapPool"));

        gauge = new MockCLGauge(address(aero));
        gauge.setPool(address(pool));
        pool.setGauge(address(gauge));
        // The reward-route probe in venue validation reads a HARDCODED v2 factory address;
        // place code there so the AERO/USDC route resolves in this fork-free suite.
        vm.etch(AERO_V2_FACTORY, address(new MockAeroV2Factory(address(aero), address(usdc), address(0xA2F))).code);
        comptroller = new MockComptroller();
        mUsdc = new MockLendingMarket(address(usdc));
        mLegB = new MockLendingMarket(address(legB));
        mLegA = new MockLendingMarket(address(legA));
        npm = new MockNpm(pool);
        // Real ERC-721 custody: a staked position is OWNED by the gauge, so any liquidity call
        // that forgets to unstake first reverts here exactly as it would on chain.
        gauge.setNpm(address(npm));
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
        p.skewBps = SKEW_CENTERED;
        p.minSkewBps = 1000; // governance band: wide enough for every skew this suite drives
        p.maxSkewBps = 9000;
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

    /// @dev The ADMIN/PROPOSER two-step that replaced the old one-shot `adjustLeverage(target, ...)`:
    ///      the vault owner (multisig) sets POLICY with `setTargetLtv`, then the proposer (rebalancer)
    ///      moves the book to it with `adjustLeverage`. Both roles are required — neither can do the
    ///      other's half — which is exactly what these lifecycle tests exercise implicitly.
    function _retarget(uint16 target) internal {
        vm.prank(owner);
        strategy.setTargetLtv(target);
        vm.prank(proposer);
        strategy.adjustLeverage(0, 0);
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

        (int24 tickLower, int24 tickUpper) =
            LeveragedAeroValuation.skewedTickRange(address(pool), SPACING, WIDTH, SKEW_CENTERED);
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

        _retarget(6000); // lever UP — allowed here
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
        _retarget(3000); // lever DOWN
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

        // Post role-split there is no target argument, so a zero target can only be reached through
        // `setTargetLtv` — where it is rejected one barrier EARLIER than the manager's full-unwind
        // guard. That guard remains the backstop and is exercised by the dust-target test below.
        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvZero.selector);
        strategy.setTargetLtv(0);

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

        vm.prank(owner);
        strategy.setTargetLtv(1); // non-zero, so it clears `TargetLtvZero` and reaches the manager
        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroManager.FullUnwindNotSupported.selector);
        strategy.adjustLeverage(0, 0);
    }

    /// @dev The guard must NOT catch an ordinary lever-down: a partial repay leaves liquidity, so the
    ///      re-stake fires and the invariant holds.
    function testPartialLeverDownKeepsThePositionStaked() public {
        _execute(SEED);
        uint256 tokenId = strategy.layout().tokenId;

        _retarget(3000);

        assertEq(strategy.layout().tokenId, tokenId, "same position");
        assertTrue(gauge.stakedContains(address(strategy), tokenId), "re-staked after a partial unwind");
        assertGt(mLegB.borrowBalance(address(strategy)), 0, "debt reduced, not cleared");
    }

    // ==================== TARGET-LTV PERSISTENCE (two-borrowed-legs) ====================

    /// @dev The persist lives in the ADMIN's `setTargetLtv` and is SHAPE-INDEPENDENT, so it holds in the
    ///      two-borrowed-legs shape exactly as in asset-mode, both directions. `adjustLeverage` no longer
    ///      writes it at all — it CONSUMES it — which is asserted here by taking the position to the
    ///      stored value in both directions with no target argument anywhere. The dedicated getter and
    ///      `layout()` are the same storage read and are asserted together.
    function testSetTargetLtvPersistsTheStandingTargetAndAdjustLeverageConsumesIt() public {
        _execute(SEED);
        assertEq(strategy.targetLtvBps(), TARGET_LTV_BPS, "genesis: the init target IS the standing target");
        assertEq(strategy.layout().targetLtvBps, TARGET_LTV_BPS, "genesis: getter == layout()");

        // Policy alone moves nothing — the write lands before any venue call.
        uint256 debtBAtInit = mLegB.borrowBalance(address(strategy));
        vm.prank(owner);
        strategy.setTargetLtv(6000);
        assertEq(strategy.targetLtvBps(), 6000, "the admin's write IS the new standing target");
        assertEq(strategy.layout().targetLtvBps, 6000, "getter == layout() after setTargetLtv");
        assertEq(mLegB.borrowBalance(address(strategy)), debtBAtInit, "setTargetLtv is policy only: book untouched");

        // The keeper's op then takes the book there, reading the STORED value (self-funding in this shape).
        vm.prank(proposer);
        strategy.adjustLeverage(0, 0);
        assertGt(mLegB.borrowBalance(address(strategy)), debtBAtInit, "lever UP ran off the stored target");
        assertEq(strategy.targetLtvBps(), 6000, "adjustLeverage left the standing target alone");

        uint256 collateral = mUsdc.balanceOf(address(strategy));
        uint256 debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, 6000, 2, "the book landed on the STORED target");

        // Same for lever DOWN.
        _retarget(3000);
        assertEq(strategy.targetLtvBps(), 3000, "the admin re-set the standing target downward");
        assertEq(strategy.layout().targetLtvBps, 3000, "getter == layout() after lever DOWN");
        collateral = mUsdc.balanceOf(address(strategy));
        debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, 3000, 20, "the book followed the stored target down");
    }

    /// @dev The KEEPER-ONLY de-risk, end to end and asserted on the BOOK, not just the getter: the
    ///      proposer lowers policy itself with `lowerTargetLtv` (no multisig, which is the whole point —
    ///      the 2-day `FULFILL_WINDOW` must not depend on a signature) and its own `adjustLeverage` then
    ///      sizes against the NEW stored value. The admin is never involved in this sequence.
    function testProposerLowerTargetLtvThenAdjustLeverageDeleversTheBook() public {
        _execute(SEED);
        uint256 debtBAtInit = mLegB.borrowBalance(address(strategy));

        // Policy alone moves nothing here either — same contract as the admin's setter.
        vm.prank(proposer);
        strategy.lowerTargetLtv(4000);
        assertEq(strategy.targetLtvBps(), 4000, "the keeper's write IS the new standing target");
        assertEq(mLegB.borrowBalance(address(strategy)), debtBAtInit, "lowerTargetLtv is policy only: book untouched");

        vm.prank(proposer);
        strategy.adjustLeverage(0, 0);
        assertLt(mLegB.borrowBalance(address(strategy)), debtBAtInit, "lever DOWN ran off the keeper's target");

        uint256 collateral = mUsdc.balanceOf(address(strategy));
        uint256 debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, 4000, 20, "the book landed on the KEEPER's target");
        assertEq(strategy.targetLtvBps(), 4000, "adjustLeverage left the standing target alone");
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

        _retarget(6000);
        // Deliberately NOT asserting the getter here — that belongs to
        // `testSetTargetLtvPersistsTheStandingTargetAndAdjustLeverageConsumesIt`.
        // This test must fail on the OBSERVABLE BORROW instead, so the regression it guards
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

    /// @dev Out-of-band target: refused at the ADMIN entrypoint, stores nothing, standing target
    ///      untouched. The bound moved to `setTargetLtv` with the parameter — `adjustLeverage` has no
    ///      target argument to bound any more.
    function testSetTargetLtvAboveMaxRevertsAndLeavesTheStoredTargetUntouched() public {
        _execute(SEED);

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvExceedsMax.selector);
        strategy.setTargetLtv(6501); // maxLtvBps == 6500

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

    // ==================== RERANGE SKEW (two borrowed legs) ====================
    //
    // The two-leg shape had NO rerange coverage before the skew work. It is the shape where the skew's
    // one real cost shows up (see `testRerangeSkewedLeavesALargerIdleRemainderThanCentered`), so the
    // whole entrypoint is driven here end to end against the venue mocks.

    /// @dev The re-range mints at the SKEWED range, not the centred one, and persists BOTH knobs. The
    ///      centred range is computed alongside and asserted to differ, so a implementation that ignored
    ///      `skewBps` entirely could not pass.
    function testRerangeSkewedMintsTheSkewedRange() public {
        _execute(SEED);
        uint256 oldTokenId = strategy.layout().tokenId;

        (int24 expLower, int24 expUpper) = LeveragedAeroValuation.skewedTickRange(address(pool), SPACING, WIDTH, 3500);
        (int24 cenLower, int24 cenUpper) =
            LeveragedAeroValuation.skewedTickRange(address(pool), SPACING, WIDTH, SKEW_CENTERED);
        assertTrue(expLower != cenLower && expUpper != cenUpper, "3500 must actually move the range off centre");

        vm.prank(proposer);
        strategy.rerange(WIDTH, 3500, 0, 0);

        assertEq(strategy.layout().posTickLower, expLower, "minted at the SKEWED lower bound");
        assertEq(strategy.layout().posTickUpper, expUpper, "minted at the SKEWED upper bound");
        assertEq(strategy.layout().skewBps, 3500, "the skew is persisted");
        assertEq(strategy.layout().width, WIDTH, "...alongside the width");
        assertTrue(strategy.layout().tokenId != oldTokenId, "a fresh tokenId (Slipstream ticks are immutable)");
        assertEq(gauge.depositCallCount(), 2, "the new NFT was restaked");
        // The range still brackets spot, so the position is genuinely two-sided.
        assertLe(expLower, pool.tick(), "skewed range still brackets spot");
        assertGt(expUpper, pool.tick(), "skewed range still brackets spot");
    }

    /**
     * @dev THE KNOWN UTILISATION COST OF SKEWING — pinned so it is a documented consequence rather than a
     *      surprise. A re-range does NOT swap: it re-adds exactly the two collected leg balances, and
     *      those came from a book whose borrow is range-BLIND (the two-leg shape borrows 50/50 BY USD via
     *      `_borrowHalfEach`, never against the range). Move the range and the mix it WANTS moves with it,
     *      while the mix it is HANDED does not — so more of one leg is left over as an idle remainder.
     *
     *      THE DRAG IS DIRECTIONAL, and this test states both halves rather than the flattering one.
     *      Extending the range further ABOVE spot makes it want more token0 (`amount0 ∝ 1/sqrtP −
     *      1/sqrtUpper`), so an UP-skew here happens to consume MORE of the stranded leg than the centred
     *      range does; the DOWN-skew is the direction that strands more. Which way is which is a property
     *      of the book's current leg mix, not of skewing per se — the operator-facing claim is only that
     *      a re-range cannot re-balance the mix, so any move off the mix the book happens to hold costs
     *      utilisation in one direction.
     *
     *      The remainder is NOT a loss in either direction — `nav()` prices it and it stays redeployable
     *      until the next `deployIdle` / `compound` — which is asserted alongside, so the cost is pinned
     *      as a UTILISATION one and not a value one. All three branches run from the SAME post-genesis
     *      snapshot, so the comparison is apples to apples.
     */
    function testRerangeSkewedLeavesALargerIdleRemainderThanCentered() public {
        _execute(SEED);
        uint256 navBefore = strategy.nav();

        (uint256 centeredRemainder, uint256 centeredNav) = _remainderAfterRerange(SKEW_CENTERED);
        (uint256 downSkewRemainder, uint256 downSkewNav) = _remainderAfterRerange(8000); // 3200 below, 800 above
        (uint256 upSkewRemainder, uint256 upSkewNav) = _remainderAfterRerange(2000); // 800 below, 3200 above

        assertGt(
            downSkewRemainder,
            centeredRemainder,
            "skewing AWAY from the book's leg mix strands MORE of a borrowed leg (range-blind 50/50 borrow)"
        );
        assertLt(
            upSkewRemainder,
            centeredRemainder,
            "...and the opposite skew strands LESS: the drag is directional, not a penalty for skewing"
        );
        // The remainder is unproductive, never lost: NAV prices it wherever it sits.
        assertApproxEqRel(centeredNav, navBefore, 1e16, "NAV indifferent (centred)");
        assertApproxEqRel(downSkewNav, navBefore, 1e16, "NAV indifferent (down-skew)");
        assertApproxEqRel(upSkewNav, navBefore, 1e16, "NAV indifferent (up-skew)");
    }

    /// @dev Re-range at `skewBps_`, measure the idle borrowed-leg remainder and NAV, then roll the whole
    ///      book back — so several skews can be compared against ONE post-genesis state.
    function _remainderAfterRerange(uint16 skewBps_) internal returns (uint256 remainder, uint256 nav_) {
        uint256 snap = vm.snapshotState();
        vm.prank(proposer);
        strategy.rerange(WIDTH, skewBps_, 0, 0);
        remainder = _idleLegValueUsdc();
        nav_ = strategy.nav();
        vm.revertToState(snap);
    }

    /// @dev A re-range on a FLAT book is a venue no-op — but the proposer's `width` AND `skewBps` must
    ///      still land, because the next `deployIdle` / `compound` mint reads them from storage. The
    ///      persists sit in the strategy frame AHEAD of `rerangeImpl`'s `tokenId == 0` bail-out precisely
    ///      so this holds after the write moved out of the library.
    function testRerangeOnFlatBookPersistsSkew() public {
        _execute(SEED);

        // Redeem the whole book: `tokenId` goes to 0 while the strategy stays Executed.
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        vm.prank(lp);
        vault.approve(address(strategy), supply);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(supply, 0);
        vm.prank(proposer);
        strategy.fulfillRedeem(id);
        assertEq(strategy.layout().tokenId, 0, "flat book");

        uint256 stakedBefore = gauge.depositCallCount();
        vm.prank(proposer);
        strategy.rerange(2000, 2500, 0, 0);

        assertEq(strategy.layout().width, 2000, "flat-book rerange still stored the width");
        assertEq(strategy.layout().skewBps, 2500, "...and the skew, for the next redeploy to mint at");
        assertEq(strategy.layout().tokenId, 0, "still flat: no position was opened");
        assertEq(gauge.depositCallCount(), stakedBefore, "nothing was staked");
    }

    /// @dev The calm-gate still fires FIRST on the skewed path: a shoved spot reverts before any venue
    ///      call, and — because the two persists now sit in the strategy frame — the atomic rollback
    ///      leaves the STORED width/skew untouched too. A re-range can never land at a manipulated tick,
    ///      nor half-land its params.
    function testRerangeSkewCalmGateStillGatesFirst() public {
        _execute(SEED);
        uint256 tokenIdBefore = strategy.layout().tokenId;
        uint128 liqBefore = npm.liquidityOf(tokenIdBefore);
        uint256 stakedBefore = gauge.depositCallCount();

        // Shove SPOT well past `calmDeviationTicks = 100` while leaving the TWAP put.
        pool.setTick(TICK + 5000);
        pool.setTwapTick(TICK);
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK + 5000));

        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroValuation.CalmGateBreached.selector);
        strategy.rerange(2000, 3500, 0, 0);

        assertEq(strategy.layout().tokenId, tokenIdBefore, "the position was never touched");
        assertEq(npm.liquidityOf(tokenIdBefore), liqBefore, "no liquidity was removed");
        assertEq(gauge.depositCallCount(), stakedBefore, "nothing was unstaked/restaked");
        assertEq(strategy.layout().width, WIDTH, "the width write rolled back with the op");
        assertEq(strategy.layout().skewBps, SKEW_CENTERED, "...and so did the skew write");
    }

    /// @dev USDC face value of whatever borrowed-leg balance a re-range left sitting idle on the
    ///      strategy — the utilisation drag the skew test compares.
    function _idleLegValueUsdc() internal view returns (uint256) {
        return _valueUsdc(legB.balanceOf(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(legA.balanceOf(address(strategy)), P_LEG_A, 18);
    }

    // ==================== LEVER-DOWN COVER IS NEED-SIZED ====================

    /**
     * @dev THE IDLE REMAINDER A LEVER-DOWN MUST NOT LIQUIDATE. A partial lever-down repays `f` of each
     *      debt from the legs the unwind collected; when a price move has skewed the LP's leg mix, one
     *      leg comes up short and `_rebalanceCover` sells the OTHER leg for USDC to buy the deficit.
     *
     *      The surplus leg's BALANCE is not the same thing as this op's surplus. It can also hold a
     *      pre-existing idle remainder — a skewed `rerange` leaves exactly that (see
     *      `testRerangeSkewedLeavesALargerIdleRemainderThanCentered`) — which is still matched 1:1 by
     *      that leg's Moonwell debt and is therefore DELTA-NEUTRAL where it sits. Selling it converts a
     *      hedged holding into an unrecorded short: `hedgedDebt()` measures interest drift only, and the
     *      repay clamp re-anchors the basis, so nothing downstream surfaces the missing leg.
     *
     *      The cover is therefore need-sized: sell what the shortfall needs (oracle-converted, with
     *      slippage headroom on both legs of the round trip) and keep the rest. Two assertions pin it
     *      from both sides — the remainder SURVIVES, and the proceeds did not pile up as idle USDC.
     */
    function testLeverDownCoverSellsOnlyWhatTheShortfallNeedsAndKeepsTheRest() public {
        // Genesis on the oracle-consistent mark (see `TICK_ORACLE_CONSISTENT`), so the deploy strands
        // essentially nothing and the ONLY idle leg-A in the book is the remainder seeded below. On the
        // suite's default `TICK` the range-blind borrow already strands ~49% of one leg, and that
        // accidental buffer absorbs every shortfall before `_rebalanceCover` is ever reached.
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK_ORACLE_CONSISTENT));
        pool.setTick(TICK_ORACLE_CONSISTENT);

        _execute(SEED);

        // A pre-existing idle leg-A remainder: ~$150k, an order of magnitude more than the shortfall
        // the move below opens, so "kept most of it" is unambiguous.
        uint256 remainder = 50e18;
        legA.mint(address(strategy), remainder);
        uint256 remainderValue = _valueUsdc(remainder, P_LEG_A, 18);

        // Move the pool up (spot AND TWAP together) and keep leg B's oracle + swap rates on the same
        // mark. Leg B is token0, so a higher tick leaves the LP holding LESS leg B than the leg-B debt —
        // the lever-down repay comes up short on leg B and routes through `_rebalanceCover`, whose
        // surplus leg is leg A: the very balance the remainder sits in.
        int24 newTick = TICK_ORACLE_CONSISTENT + 600;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(newTick));
        pool.setTick(newTick);
        pool.setTwapTick(newTick);
        uint256 newPB = (P_LEG_B * 1_061_837) / 1_000_000; // 1.0001^600
        legBFeed.setAnswer(int256(newPB));
        router.setRate(address(legB), address(usdc), (newPB * 1e18) / (100 * 1e8));
        router.setRate(address(usdc), address(legB), (100 * 1e8 * 1e18) / newPB);
        // FIXTURE ONLY: `MockNpm` custodies exactly what it was minted, so a post-move `collect` owes
        // amounts re-priced at the new sqrtP that it never received. Float it, as other LPs would.
        legB.mint(address(npm), 100e8);
        legA.mint(address(npm), 100e18);

        uint256 debtBBefore = mLegB.borrowBalance(address(strategy));

        _retarget(3000); // lever DOWN — repays f of both debts

        // 1. The remainder survived: only a need-sized slice of the leg-A balance was sold.
        assertGt(
            legA.balanceOf(address(strategy)),
            remainder / 2,
            "the delta-neutral leg-A remainder was not liquidated wholesale to cover the leg-B shortfall"
        );
        // 2. ...and the sell was not merely deferred into idle USDC: a wholesale sell would leave the
        //    unspent proceeds sitting there.
        assertLt(
            usdc.balanceOf(address(strategy)),
            remainderValue / 10,
            "the cover raised roughly what it spent -- the sell was need-sized, not wholesale"
        );
        // 3. The shortfall WAS covered: both debts repaid to the new target, so LTV landed on it.
        assertLt(mLegB.borrowBalance(address(strategy)), debtBBefore, "the leg-B debt really was repaid");
        uint256 collateral = (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18;
        uint256 debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), newPB, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, 3000, 20, "LTV landed on the new target");
    }

    // ==================== THE GENESIS DRAG A SKEWED RANGE CANNOT AVOID ====================

    /**
     * @dev THE ALWAYS-ADVERSE HALF of the skew's utilisation cost — the one
     *      `testRerangeSkewedLeavesALargerIdleRemainderThanCentered` cannot show, because a re-range is
     *      handed whatever mix the book already holds and so has a flattering direction.
     *
     *      A DEPLOY has no such luck. `_borrowHalfEach` splits the borrow 50/50 BY USD, range-BLIND,
     *      while the range wants the mix its geometry implies — `w1 = (√P − √Pa) / [(√P − √Pa) + √P(1 −
     *      √P/√Pb)]` of the value in token1 and the complement in token0. Off centre those are not 50/50,
     *      the mint consumes only as much as the SCARCER side allows, and the difference is stranded as
     *      idle borrowed tokens: `stranded = 0.5 − 0.5 · min(w0,w1)/max(w0,w1)` of the borrow.
     *
     *      DIRECTION-INDEPENDENT: skew `s` and skew `10000 − s` produce mirror-image ranges, so `w0` and
     *      `w1` swap and the ratio — hence the stranded fraction — is IDENTICAL. There is no "good"
     *      direction to skew in at deploy time; the drag is the price of expressing the view.
     *
     *      This is a property of the range-blind borrow, NOT a bug in the skew: the follow-up
     *      range-aware-borrow work is expected to size the two borrows at `w0 : w1` instead of 50/50 and
     *      drive this to ~0, at which point this test's assertion FLIPS (assert ~0 stranded, and keep the
     *      direction-independence half as-is).
     */
    function testDeployAtASkewedRangeStrandsTheSamePredictedFractionEitherWay() public {
        // Put the pool on the SAME mark as the two feeds BEFORE genesis. The suite's default `TICK` is
        // only loosely consistent with them, and this test measures a POOL-ratio effect in ORACLE value
        // — a mismatched mark would show up as drag at every skew, centred included, and drown the thing
        // under test. Moving it pre-genesis (rather than after) keeps the mocks self-consistent: nothing
        // is minted at one price and collected at another.
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK_ORACLE_CONSISTENT));
        pool.setTick(TICK_ORACLE_CONSISTENT);

        _execute(SEED);

        (uint256 downStranded, uint256 downPredicted) = _strandedFractionAfterRerangeAndDeploy(8000);
        (uint256 upStranded, uint256 upPredicted) = _strandedFractionAfterRerangeAndDeploy(2000);
        (uint256 centeredStranded,) = _strandedFractionAfterRerangeAndDeploy(SKEW_CENTERED);

        // The closed form is the claim; the measured drag is what the venue actually stranded.
        assertApproxEqRel(downStranded, downPredicted, 2e16, "down-skew: measured drag == the closed form");
        assertApproxEqRel(upStranded, upPredicted, 2e16, "up-skew: measured drag == the closed form");
        // DIRECTION-INDEPENDENCE: mirror skews strand the same fraction (measured: 3669 vs 3678 bps).
        // The residual 0.25% is grid alignment — both bounds round DOWN, so the two ranges are mirror
        // images only up to one `tickSpacing`.
        assertApproxEqRel(downStranded, upStranded, 1e16, "skew 8000 and skew 2000 strand the SAME fraction");
        assertGt(upStranded, 3000, "the up-skew is adverse too -- there is no free direction at deploy");
        // ...and it is a real cost: the centred range strands essentially nothing at the same width.
        assertGt(downStranded, 3000, "a skewed deploy strands >30% of the borrow (range-blind 50/50)");
        assertLt(centeredStranded, 100, "...where the centred range strands ~nothing");
    }

    /// @dev Re-range to `skewBps_`, deploy a fresh top-up into that STORED range, and return
    ///      `(measured, predicted)` stranded fractions of the top-up's borrow, in bps. Rolls the book
    ///      back so several skews compare against ONE post-genesis state.
    function _strandedFractionAfterRerangeAndDeploy(uint16 skewBps_)
        internal
        returns (uint256 measuredBps, uint256 predictedBps)
    {
        uint256 snap = vm.snapshotState();
        vm.prank(proposer);
        strategy.rerange(WIDTH, skewBps_, 0, 0);

        predictedBps = _predictedStrandedBps(strategy.layout().posTickLower, strategy.layout().posTickUpper);

        uint256 idleBefore = _idleLegValueUsdc();
        uint256 topUp = 250_000e6;
        usdc.mint(address(strategy), topUp);
        vm.prank(proposer);
        strategy.deployIdle(topUp, 0);

        // The whole top-up becomes collateral and `topUp × targetLtv` is borrowed 50/50 by USD; whatever
        // of that the mint could not take is the new idle-leg value.
        uint256 borrowed = (topUp * uint256(TARGET_LTV_BPS)) / 10_000;
        measuredBps = ((_idleLegValueUsdc() - idleBefore) * 10_000) / borrowed;
        vm.revertToState(snap);
    }

    /// @dev `0.5 − 0.5 · min(w0,w1)/max(w0,w1)` in bps, where `w0`/`w1` are the VALUE shares the range
    ///      demands at the current `sqrtP`. Derived from a reference-liquidity probe of the realised
    ///      range (the same technique `LeveragedAeroValuation._rangeRatio` uses), so it is a genuinely
    ///      independent prediction rather than a restatement of the implementation.
    function _predictedStrandedBps(int24 tickLower, int24 tickUpper) internal view returns (uint256) {
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            pool.sqrtPriceX96(),
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            uint128(1 << 96)
        );
        uint256 v0 = _valueUsdc(amt0, P_LEG_B, 8); // token0 is leg B in this fixture
        uint256 v1 = _valueUsdc(amt1, P_LEG_A, 18);
        (uint256 lo, uint256 hi) = v0 < v1 ? (v0, v1) : (v1, v0);
        return 5000 - (5000 * lo) / hi;
    }

    // ==================== "NO IDLE USDC SITS DEAD" (the proposer's `supplyIdle`) ====================

    /// @dev Fund a live book with `assets` from `lp` through the real `deposit` entrypoint.
    function _deposit(uint256 assets) internal returns (uint256 shares) {
        usdc.mint(lp, assets);
        vm.startPrank(lp);
        usdc.approve(address(strategy), assets);
        shares = strategy.deposit(assets, 0);
        vm.stopPrank();
    }

    /// @dev USDC collateral (6dp face) on the strategy's own basis.
    function _collateralUsdc() internal view returns (uint256) {
        return (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18;
    }

    /// @dev Chainlink-priced LTV of the live book, on the strategy's own health basis.
    function _ltvBps() internal view returns (uint256) {
        uint256 debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        return (debtUsdc * 10_000) / _collateralUsdc();
    }

    /// @dev The keeper supplies the whole raw balance to Moonwell.
    function _supplyAllIdle() internal returns (uint256 supplied) {
        supplied = usdc.balanceOf(address(strategy));
        vm.prank(proposer);
        strategy.supplyIdle(supplied);
    }

    /// @dev DEPOSIT IS UNTOUCHED. Money-in has no Moonwell dependency: the USDC lands raw and stays
    ///     raw until a keeper decides to park it. This is the assertion that pins the design choice —
    ///     a paused / supply-capped Moonwell USDC market must never be able to refuse a deposit.
    function testDepositLeavesTheUsdcRawAndTouchesNoMoonwellMarket() public {
        _execute(SEED);
        uint256 collateralBefore = _collateralUsdc();
        mUsdc.setSupplyErrors(4, 0); // a market that would refuse every mint

        uint256 top = 250_000e6;
        _deposit(top); // must not revert

        assertEq(usdc.balanceOf(address(strategy)), top, "the deposit is held as RAW USDC");
        assertEq(_collateralUsdc(), collateralBefore, "deposit supplied nothing to Moonwell");
    }

    /**
     * @dev THE INVARIANT, under keeper control. `supplyIdle` moves raw USDC into mUSDC and the move is
     *      value-neutral: NAV is unchanged. That second half is the load-bearing one — `nav()` counts
     *      idle at FACE and collateral at `exchangeRateStored`, so "park it" is only free if those two
     *      agree, which they do at any rate because the mint hands back `amount/rate` cTokens worth
     *      `amount` again.
     */
    function testSupplyIdleMovesRawUsdcIntoMoonwellAndConservesNav() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);

        uint256 collateralBefore = _collateralUsdc();
        uint256 navBefore = strategy.nav();

        vm.prank(proposer);
        strategy.supplyIdle(top);

        assertEq(usdc.balanceOf(address(strategy)), 0, "the raw balance was parked");
        assertEq(_collateralUsdc() - collateralBefore, top, "and it became mUSDC collateral");
        assertApproxEqAbs(strategy.nav(), navBefore, 1, "NAV unchanged by the move (rounding dust only)");
    }

    /// @dev The same, at a non-unit exchange rate — the case where "idle at face vs collateral at
    ///      `exchangeRateStored`" could actually diverge if the accounting were wrong.
    function testSupplyIdleConservesNavAtANonUnitExchangeRate() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        mUsdc.setExchangeRateStored(1.37e18); // the market has accrued supply interest

        uint256 navBefore = strategy.nav();
        vm.prank(proposer);
        strategy.supplyIdle(top);

        assertEq(usdc.balanceOf(address(strategy)), 0, "still nothing raw");
        // `mint` floors `amount/rate` cTokens, so up to one cToken (~1.37 units of USDC) can round away.
        assertApproxEqAbs(strategy.nav(), navBefore, 2, "NAV unchanged, bar mint rounding");
    }

    /// @dev PARTIAL BY DESIGN. The keeper decides how much float to leave un-supplied — that raw slice
    ///      is what keeps the redeemer's ORACLE-FREE Phase-1 IL cover reachable. `supplyIdle` must
    ///      therefore take an amount, not sweep, and must leave the remainder exactly alone.
    function testSupplyIdleLeavesTheKeepersChosenFloatRaw() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        _deposit(250_000e6);

        vm.prank(proposer);
        strategy.supplyIdle(200_000e6); // park most, keep a 50k oracle-free cover float

        assertEq(usdc.balanceOf(address(strategy)), 50_000e6, "the keeper's float is untouched");
        assertEq(_collateralUsdc(), SEED + 200_000e6, "and only the parked slice became collateral");
    }

    /**
     * @dev THE POLICY, ASSERTED. Supplied-but-unlevered USDC is LEVERAGEABLE: there is no buffer/book
     *      distinction in `Layout`, `_readCollateralDebt` sees one collateral base, and so
     *      `adjustLeverage` ALONE levers a freshly-parked balance to `targetLtvBps` — no `deployIdle`
     *      needed. The book-level LTV dips after the supply (collateral grew, debt did not) and the
     *      retarget brings the WHOLE book, the new collateral included, back to target.
     */
    function testSupplyIdleThenAdjustLeverageLeversTheNewCollateralToTarget() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);

        // The supply diluted the leverage: same debt over a bigger base.
        assertApproxEqAbs(_ltvBps(), (uint256(TARGET_LTV_BPS) * SEED) / (SEED + top), 2, "LTV dipped on the supply");

        vm.prank(proposer);
        strategy.adjustLeverage(0, 0); // the STANDING target — no policy change, no deployIdle

        assertEq(_collateralUsdc(), SEED + top, "collateral is the whole book, the parked slice included");
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "adjustLeverage alone levered the new collateral");
    }

    /// @dev Over-asking is a typed refusal against the RAW balance — `supplyIdle` supplies, it does not
    ///      reach into the LP or re-supply collateral, so the raw balance is exactly its budget.
    function testSupplyIdleRevertsInsufficientIdleAboveTheRawBalance() public {
        _execute(SEED);
        _deposit(100_000e6);
        uint256 raw = usdc.balanceOf(address(strategy));
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.supplyIdle(raw + 1);
    }

    /// @dev PROPOSER-ONLY, like every other venue op. The admin (vault owner) holds POLICY, not
    ///      operations — it sets the target LTV and stages venues; it does not move funds on venues.
    function testSupplyIdleRejectsTheAdminAndStrangers() public {
        _execute(SEED);
        _deposit(100_000e6);

        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.supplyIdle(1e6);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.supplyIdle(1e6);
    }

    /// @dev Lifecycle-gated exactly like `deployIdle` / `compound` / `adjustLeverage`.
    function testSupplyIdleRevertsBeforeExecute() public {
        usdc.mint(address(strategy), 100_000e6);
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.supplyIdle(100_000e6);
    }

    /// @dev FAIL-CLOSED on the supply, and harmless: a Moonwell USDC market that refuses to mint
    ///      (paused, at its supply cap) reverts with the market's own code and moves nothing. On a
    ///      keeper op that is a retry — which is precisely why this call is not on the deposit path.
    function testSupplyIdleRevertsMoonwellMintFailedWhenTheMarketRefuses() public {
        _execute(SEED);
        _deposit(100_000e6);
        mUsdc.setSupplyErrors(4, 0); // MARKET_NOT_FRESH-shaped code

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(LeveragedAerodromeCLStrategy.MoonwellMintFailed.selector, uint256(4)));
        strategy.supplyIdle(100_000e6);
    }

    /// @dev `deployIdle` still works when the amount lives in mUSDC rather than as a raw balance: the
    ///      `InsufficientIdle` bound now measures raw + collateral, and `_materialiseUsdc` redeems the
    ///      shortfall before `_supplyAndBorrow` puts it back. End state is identical to the raw case.
    function testDeployIdleWorksFromSuppliedCollateralWithNoRawUsdc() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);

        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);
        assertEq(usdc.balanceOf(address(strategy)), 0, "precondition: nothing raw to deploy");

        uint256 debtBBefore = mLegB.borrowBalance(address(strategy));
        vm.prank(proposer);
        strategy.deployIdle(top, 0);

        assertEq(_collateralUsdc(), SEED + top, "collateral unchanged by the redeem->supply round trip");
        assertGt(mLegB.borrowBalance(address(strategy)), debtBBefore, "the amount was levered");
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "deployIdle landed the book on target");
    }

    /// @dev The bound is still typed and still binding — it just measures the right basis now. Asking
    ///      for one unit more than raw + collateral is `InsufficientIdle`, not a silent cap.
    function testDeployIdleStillRevertsAboveRawPlusCollateral() public {
        _execute(SEED);
        uint256 available = usdc.balanceOf(address(strategy)) + _collateralUsdc();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.deployIdle(available + 1, 0);
    }

    /// @dev `redeploy` re-enters a FLAT book whose whole pot the keeper parked in mUSDC —
    ///      `executeImpl` reads `_usdcAvailable()` and materialises it, where the raw-balance read
    ///      would have seen 0 and refused `ExecuteZeroBalance` on a fully-funded fund.
    function testRedeployReEntersAFlatBookHeldEntirelyAsCollateral() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();

        vm.prank(proposer);
        strategy.redeploy(0);
        assertGt(strategy.layout().tokenId, 0, "redeploy re-entered from collateral alone");
        assertEq(_collateralUsdc(), pot, "the whole pot is back as collateral after the round trip");
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "and landed on target");
    }

    /// @dev Reach a FLAT book whose entire pot sits in mUSDC and NOTHING is raw — `flatten` realises
    ///      the book to raw USDC and the keeper parks it, which is exactly the state `supplyIdle`
    ///      exists for (a flat book is the one holding the most dead USDC).
    /// @return pot The USDC now held entirely as collateral.
    function _flatBookHeldEntirelyAsCollateral() internal returns (uint256 pot) {
        _execute(SEED);
        vm.prank(proposer);
        strategy.flatten(0, 1);
        assertEq(strategy.layout().tokenId, 0, "precondition: flat book");

        pot = _supplyAllIdle();
        assertGt(pot, 0, "flatten realised a pot");
        assertEq(usdc.balanceOf(address(strategy)), 0, "the whole pot is collateral, nothing raw");
        assertEq(_collateralUsdc(), pot, "and it is priced as collateral");
        assertEq(strategy.nav(), pot, "flat-book nav() prices the collateral it now holds");
    }

    /// @dev A failing `redeemUnderlying` surfaces as the typed `MoonwellRedeemFailed` on the paths that
    ///      can NOW reach one — `deployIdle` materialises raw USDC on demand, which it never did while
    ///      idle USDC could only sit raw.
    function testMoonwellRedeemFailedSurfacesOnTheNewlyMaterialisingPaths() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);

        mUsdc.setSupplyErrors(0, 9); // TOKEN_INSUFFICIENT_CASH-shaped code
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(LeveragedAerodromeCLStrategy.MoonwellRedeemFailed.selector, uint256(9)));
        strategy.deployIdle(top, 0);
    }

    /// @dev The other newly-materialising path: `redeploy` on a flat book whose pot is all collateral.
    function testMoonwellRedeemFailedSurfacesOnRedeploy() public {
        _flatBookHeldEntirelyAsCollateral();
        mUsdc.setSupplyErrors(0, 9);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(LeveragedAerodromeCLStrategy.MoonwellRedeemFailed.selector, uint256(9)));
        strategy.redeploy(0);
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

    /**
     * @dev THE FAST PATH WITH NOTHING RAW. `fastRedeemImpl` draws idle first, then collateral; on a
     *      book the keeper has fully parked there is no idle, so it always draws collateral and the
     *      LTV gate — which a fully idle-funded redeem used to skip entirely — is always live. That is
     *      the same economics either way (the USDC being paid out IS collateral now, so paying it out
     *      really does move the LTV), and it is not a tightening in practice: the supply LOWERS the
     *      book's LTV before it can be redeemed, so a supply-then-exit always has headroom. Both
     *      halves asserted here.
     */
    function testFastRedeemDrawsFromCollateralWhenNothingIsRawIdle() public {
        _execute(SEED);
        uint256 top = 250_000e6;
        uint256 shares = _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top); // the keeper left NO float — the tightest case for the fast path
        assertEq(usdc.balanceOf(address(strategy)), 0, "precondition: no raw idle to draw on");

        uint256 collateralBefore = _collateralUsdc();
        uint256 lpBefore = usdc.balanceOf(lp);

        vm.startPrank(lp);
        vault.approve(address(strategy), shares / 4);
        uint256 out = strategy.redeem(shares / 4, 0);
        vm.stopPrank();

        assertGt(out, 0, "the fast path paid out");
        assertEq(usdc.balanceOf(lp) - lpBefore, out, "payout delivered");
        assertEq(collateralBefore - _collateralUsdc(), out, "funded entirely from collateral");
        assertEq(usdc.balanceOf(address(strategy)), 0, "and nothing was left raw behind it");
    }

    /**
     * @dev THE ASYNC PATH WITH NOTHING RAW, AND THE IL COVER. A full redeem repays both debts from the
     *      unwound legs; a price move leaves one leg short, and the shortfall has to be bought. The
     *      redeemer's Phase-1 cover budget IS the raw balance and Phase 1 is ORACLE-FREE; a keeper
     *      that parks everything drives that budget to 0 and the redeem falls through to Phase 2
     *      (`_settleShortfall`), which redeems collateral, buys the deficit off Chainlink and repays.
     *      This pins that the exit still completes and still pays — the failure mode that matters on a
     *      redeem valve — in the WORST case the keeper can create.
     *
     *      AND THAT IS WHY THE FLOAT IS A KEEPER DIAL. Phase 2 reads feeds; Phase 1 does not. Supplying
     *      on deposit would have made this state unavoidable and pushed every shortfall-carrying full
     *      redeem — including the trustless `emergencyRedeem` deadman — onto the oracle. With
     *      `supplyIdle` the operator chooses: leave float, keep Phase 1 reachable, pay the supply APY
     *      on that slice. `testSupplyIdleLeavesTheKeepersChosenFloatRaw` is the other side of this.
     */
    function testAsyncFullRedeemCoversAnIlShortfallWithZeroRawIdle() public {
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK_ORACLE_CONSISTENT));
        pool.setTick(TICK_ORACLE_CONSISTENT);
        _execute(SEED);

        uint256 shares = _deposit(250_000e6);
        vm.prank(proposer);
        strategy.supplyIdle(250_000e6); // keeper leaves NO float: Phase 1 has nothing to spend
        assertEq(usdc.balanceOf(address(strategy)), 0, "precondition: the redeemer's Phase-1 budget is 0");

        // Move the pool up (spot AND TWAP) with leg B's oracle + swap rate: leg B is token0, so the LP
        // now holds LESS leg B than the leg-B debt and the proportional repay comes up short.
        int24 newTick = TICK_ORACLE_CONSISTENT + 600;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(newTick));
        pool.setTick(newTick);
        pool.setTwapTick(newTick);
        uint256 newPB = (P_LEG_B * 1_061_837) / 1_000_000; // 1.0001^600
        legBFeed.setAnswer(int256(newPB));
        router.setRate(address(legB), address(usdc), (newPB * 1e18) / (100 * 1e8));
        router.setRate(address(usdc), address(legB), (100 * 1e8 * 1e18) / newPB);
        // FIXTURE ONLY: `MockNpm` custodies exactly what it was minted, so a post-move `collect` owes
        // amounts re-priced at the new sqrtP that it never received. Float it, as other LPs would.
        legB.mint(address(npm), 100e8);
        legA.mint(address(npm), 100e18);

        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 legBBoughtBefore = router.boughtOf(address(legB));
        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        uint256 id = strategy.requestRedeem(shares, 0);
        vm.stopPrank();
        vm.prank(proposer);
        strategy.fulfillRedeem(id);

        // The cover really ran — without this the test would pass vacuously on a book that had no
        // shortfall to cover in the first place.
        assertGt(
            router.boughtOf(address(legB)),
            legBBoughtBefore,
            "the IL cover actually bought leg B with USDC (the path under test was reached)"
        );
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg-B debt cleared through the IL cover");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared");
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant restored");
        assertGt(usdc.balanceOf(lp) - lpBefore, 0, "the redeemer was paid despite the shortfall");
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
