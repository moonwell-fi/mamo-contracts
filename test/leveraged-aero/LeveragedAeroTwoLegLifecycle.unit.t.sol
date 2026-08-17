// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAeroManager} from "@contracts/leveraged-aero/LeveragedAeroManager.sol";
import {LeveragedAeroValuation} from "@contracts/leveraged-aero/LeveragedAeroValuation.sol";
import {LeveragedAeroVenue} from "@contracts/leveraged-aero/LeveragedAeroVenue.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "@contracts/leveraged-aero/sherwood/BaseStrategy.sol";
import {ChainlinkReader} from "@contracts/leveraged-aero/sherwood/libraries/ChainlinkReader.sol";
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

import {Test, Vm, stdError} from "@forge-std/Test.sol";
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

        // Wire the comptroller's hypothetical-liquidity model — priced at its OWN oracle (the raw
        // feed answers, NO staleness gate, exactly the real Moonwell ChainlinkOracle asymmetry the
        // degraded `withdrawIdle` bound leans on) — and put the `redeemAllowed` belt on the
        // collateral market, so both halves of "Moonwell's own check" are representable in this
        // suite rather than assumed.
        comptroller.registerMarket(address(mUsdc), address(usdcFeed), 6, 0.88e18);
        comptroller.registerMarket(address(mLegB), address(legBFeed), 8, 0);
        comptroller.registerMarket(address(mLegA), address(legAFeed), 18, 0);
        mUsdc.setComptroller(address(comptroller));

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
        // `cloneAndBind` is the only path a clone is ever initialized by: `BaseStrategy.initialize`
        // requires `msg.sender == vault_`.
        vm.startPrank(owner);
        strategy = LeveragedAerodromeCLStrategy(
            payable(vault.cloneAndBind(address(new LeveragedAerodromeCLStrategy()), proposer, abi.encode(_params())))
        );
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
        strategy.fulfillRedeem(id, 0);
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

    /**
     * @dev F06, the OTHER one-sided branch. Walk spot clear BELOW the stored band: a CL position priced
     *      under its range holds token0 only (leg B here), so the reopen must place the band STRICTLY
     *      ABOVE spot. The asset-mode suite covers the mirror (token1 only → at/below spot).
     *
     *      Before the fix this reverted inside the pool: `skewedTickRange` returned a band straddling
     *      spot, the mint computed zero liquidity for the leg the book did not hold, and `rerange` was
     *      unusable in exactly the state it exists for.
     */
    function testRerangeReopensAboveSpotWhenPriceHasFallenOutOfTheBand() public {
        _execute(SEED);
        uint256 oldTokenId = strategy.layout().tokenId;
        uint256 stakedBefore = gauge.depositCallCount();

        // Clear the genesis idle remainder on both legs, so the only tokens the re-add sees are the ones
        // THIS unwind collects. The two-leg shape borrows 50/50 by USD — range-blind — so genesis always
        // strands some of one leg, and a book holding both legs is two-sided and takes the recentre
        // branch regardless of where spot is.
        vm.startPrank(address(strategy));
        legB.transfer(address(0xdead), legB.balanceOf(address(strategy)));
        legA.transfer(address(0xdead), legA.balanceOf(address(strategy)));
        vm.stopPrank();

        int24 farTick = strategy.layout().posTickLower - 5000;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(farTick));
        pool.setTick(farTick);
        // `MockNpm` custodies only what it was minted, so after a price move `collect` owes amounts
        // re-priced at the new sqrtP that it never received. Float it, as a real pool's other LPs do.
        legB.mint(address(npm), 1_000_000e8);
        legA.mint(address(npm), 1_000_000e18);

        vm.prank(proposer);
        strategy.rerange(WIDTH, SKEW_CENTERED, 0, 0);

        int24 lower = strategy.layout().posTickLower;
        int24 upper = strategy.layout().posTickUpper;
        assertGt(lower, pool.tick(), "the new band sits STRICTLY above spot");
        assertEq(upper - lower, int24(uint24(WIDTH)), "width honoured exactly (skew is not consulted)");
        assertTrue(strategy.layout().tokenId != oldTokenId, "a fresh tokenId");
        assertGt(npm.liquidityOf(strategy.layout().tokenId), 0, "real liquidity, not an empty position");
        assertEq(gauge.depositCallCount(), stakedBefore + 1, "the new NFT was restaked");
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

    /**
     * @dev THE RATCHET IS CLOSED. `deployIdle`'s funding basis is raw + UN-LEVERED collateral, not
     *      raw + all collateral: funded from collateral that already backs debt, the op would be
     *      redeem → supply-straight-back → borrow — a net debt-only increase that re-levers the same
     *      USDC twice and walks LTV from `targetLtvBps` to `maxLtvBps`, i.e. the exact lever-up-risk
     *      capability the admin-only target split denies the `onlyProposer` key. A book whose
     *      collateral is fully levered at target has NOTHING deployable, typed and loud.
     */
    function testDeployIdleCannotRecycleLeveredCollateral() public {
        _execute(SEED); // at target: every USDC of collateral already backs debt
        uint256 ltvBefore = _ltvBps();

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.deployIdle(20_000e6, 0);
        assertApproxEqAbs(_ltvBps(), ltvBefore, 0, "nothing moved");

        // And the same after a park-then-lever cycle: once `adjustLeverage` has levered the parked
        // slice, it stops being deployable — `deployIdle` cannot run the book above target by
        // "deploying" collateral the retarget already consumed.
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);
        vm.prank(proposer);
        strategy.adjustLeverage(0, 0); // the whole book, parked slice included, is now at target

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.deployIdle(20_000e6, 0);
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "the book stayed at target");
    }

    // ==================== THE INVERSE (`withdrawIdle`) ====================

    /// @dev THE DIAL TURNS BOTH WAYS. Park, then un-park: the raw float — the oracle-free Phase-1
    ///      IL-cover budget — is restorable without levering (`deployIdle`) or exiting the venue
    ///      (`flatten`). Value-neutral in both directions.
    function testWithdrawIdleIsTheInverseOfSupplyIdle() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);
        uint256 navBefore = strategy.nav();

        vm.prank(proposer);
        strategy.withdrawIdle(top);

        assertEq(usdc.balanceOf(address(strategy)), top, "the raw float is back");
        assertEq(_collateralUsdc(), SEED, "the parked slice left the collateral");
        assertApproxEqAbs(strategy.nav(), navBefore, 2, "value-neutral round trip (rounding dust only)");
    }

    /// @dev The mirror of `deployIdle`'s bound: collateral backing debt at target is NOT withdrawable —
    ///      pulling it would raise LTV above the admin-set target with no admin action. Typed refusal.
    function testWithdrawIdleRefusesLeveredCollateral() public {
        _execute(SEED); // at target: no un-levered collateral at all
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.withdrawIdle(20_000e6);
    }

    /// @dev On a FLAT parked book there is no debt, so the WHOLE pot is withdrawable — the deadman
    ///      recovery path: a keeper (or a keeper's successor) can always turn a fully-parked flat book
    ///      back into raw USDC.
    function testWithdrawIdleFreesTheWholeFlatParkedPot() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();
        vm.prank(proposer);
        strategy.withdrawIdle(pot);
        assertEq(usdc.balanceOf(address(strategy)), pot, "the whole flat pot came back raw");
        assertEq(strategy.nav(), pot, "nav unchanged: same value, raw again");
    }

    /**
     * @dev THE RESTORE DIRECTION SURVIVES AN ORACLE OUTAGE — the reviewers' Venue:304 finding. The
     *      policy bound (`_unleveredCollateral`, the un-levered slice) is Chainlink-priced and reads
     *      three feeds whenever there is debt, and each read fail-closes. That made `withdrawIdle`
     *      unavailable in exactly the outage where an operator most wants raw USDC on hand — while
     *      `supplyIdle`, which reads only the raw balance, stayed available. The dial jammed in the
     *      PARK direction.
     *
     *      TWO BELTS, NOT ONE. The Chainlink bound is the STRATEGY'S POLICY (post-op LTV stays at the
     *      admin-set target). Moonwell runs its OWN check underneath on every redeem out of an entered
     *      market with live borrows and refuses at its collateral factor. Solvency never depended on our
     *      feed, so an unreadable feed now degrades the POLICY line rather than blocking the op:
     *      `WithdrawIdleBoundDegraded` is emitted and Moonwell's check is the belt for that call.
     *
     *      Asserted here on a LEVERED book (the only shape that reads feeds at all): stale feeds, the
     *      withdraw goes through, the marker fires, and the value moved is real.
     */
    function testWithdrawIdleDegradesToMoonwellsCheckWhenTheOracleIsDown() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top); // parked on a LEVERED book: the bound reads feeds here
        assertGt(mLegA.borrowBalance(address(strategy)), 0, "precondition: live debt, so the bound prices");
        uint256 collateralBefore = _collateralUsdc();

        // Every feed stale: the policy bound cannot be priced at all.
        vm.warp(block.timestamp + 2 days + 1);

        vm.expectEmit(false, false, false, false, address(strategy));
        emit LeveragedAerodromeCLStrategy.WithdrawIdleBoundDegraded();
        vm.prank(proposer);
        strategy.withdrawIdle(top);

        assertEq(usdc.balanceOf(address(strategy)), top, "the raw float was restored during the outage");
        assertEq(_collateralUsdc(), collateralBefore - top, "...and it really came out of the collateral");
    }

    /**
     * @dev THE DEGRADED PATH STILL HOLDS THE TARGET-LTV LINE — at the venue's oracle. An earlier
     *      revision dropped the policy bound entirely on the catch path, leaving Moonwell's
     *      collateral factor (8800 bps, ABOVE `maxLtvBps`) as the only limit: during an outage the
     *      `onlyProposer` key could walk the book to the CF edge in one call — zero price cushion,
     *      the permissionless `deleverage` valve armed — the exact risk-escalation capability the
     *      admin-only target split denies that key. The bound is now re-derived from
     *      `getAccountLiquidity`, so the SAME un-levered slice is withdrawable during the outage and
     *      anything past it is the same typed refusal, feeds or no feeds.
     */
    function testDegradedWithdrawIdleStillHoldsTheTargetLtvLine() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);
        vm.warp(block.timestamp + 2 days + 1); // every hardened feed refuses

        // Past the venue-derived un-levered slice: refused, typed, even mid-outage. This is the
        // assertion the pre-fix degrade could not make — it let this call through, and 90% of the
        // collateral after it.
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.withdrawIdle(top + 20_000e6);

        // The blast radius, pinned: after the largest permitted degraded withdraw the book sits at
        // the standing target — nowhere near the CF line.
        vm.prank(proposer);
        strategy.withdrawIdle(top - 10); // a few units inside the venue-oracle bound (integer slack)
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 3, "post-degrade LTV pinned at the standing target");
    }

    /// @dev If even the VENUE cannot answer (a comptroller error code), the degraded path fails
    ///      closed — the pre-degrade posture, and the right one when nothing at all can price the book.
    function testDegradedWithdrawIdleFailsClosedWhenTheComptrollerErrors() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);
        vm.warp(block.timestamp + 2 days + 1);
        comptroller.setAccountLiquidityError(2);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.ComptrollerCallFailed.selector);
        strategy.withdrawIdle(1e6);
    }

    /// @dev MOONWELL'S OWN BELT, representable at last (james-saint review): the mock market now
    ///      consults the comptroller's hypothetical liquidity on the way out, so an over-draw against
    ///      live debt answers with the Compound rejection CODE — the shape every production caller
    ///      (`MoonwellRedeemFailed(err)`) is written around — instead of a mock-artifact balance
    ///      underflow.
    function testMoonwellRefusesARedeemPastTheFreeCollateralLine() public {
        _execute(SEED); // levered at target 5000 with CF 8800: ~43% of collateral is free, no more
        uint256 collateral = _collateralUsdc();
        vm.prank(address(strategy));
        uint256 err = mUsdc.redeemUnderlying((collateral * 6) / 10); // 60%: past the free line
        assertEq(err, 4, "refused with the INSUFFICIENT_LIQUIDITY-shaped code, nothing moved");
        assertEq(_collateralUsdc(), collateral, "the refusal is a code, not a partial fill");
    }

    /// @dev THE OTHER HALF, both properties the name claims (an earlier revision duplicated
    ///      `testWithdrawIdleRefusesLeveredCollateral` byte for byte and controlled nothing): with
    ///      READABLE feeds the policy bound refuses past the un-levered slice through the PRIMARY
    ///      read, and a healthy in-bound withdraw emits NO degradation marker — pinned the same way
    ///      the sibling markers pin their no-degradation halves, so the marker cannot become
    ///      free-running.
    function testWithdrawIdleStillEnforcesThePolicyBoundWhenFeedsAreReadable() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.withdrawIdle(top + 20_000e6);

        vm.recordLogs();
        vm.prank(proposer);
        strategy.withdrawIdle(top / 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.WithdrawIdleBoundDegraded.selector,
                "a healthy withdrawIdle must not mark degradation"
            );
        }
        assertEq(usdc.balanceOf(address(strategy)), top / 2, "...and the in-bound withdraw went through");
    }

    /// @dev Same gates as `supplyIdle`: proposer-only, `Executed`-only, fail-closed on the redeem.
    function testWithdrawIdleGatesAndFailureSurface() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.withdrawIdle(1);

        uint256 pot = _flatBookHeldEntirelyAsCollateral();

        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.withdrawIdle(1e6);

        mUsdc.setSupplyErrors(0, 9); // TOKEN_INSUFFICIENT_CASH-shaped code
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(LeveragedAerodromeCLStrategy.MoonwellRedeemFailed.selector, uint256(9)));
        strategy.withdrawIdle(pot);
    }

    /**
     * @dev THE FAILURE MODE THE `nav()` FLAT BRANCH EXISTS TO PREVENT, driven end to end. On a flat
     *      book whose whole pot the keeper parked, a raw-balance-only nav would read 0: the next
     *      depositor would mint against zero NAV (an unbacked claim on the parked pot) and every one
     *      after would revert `NavUnpriceable`. With the collateral term counted, deposits price
     *      against the parked pot exactly as they would against a raw one.
     */
    function testDepositPricesSharesFairlyOnAFlatBookHeldEntirelyAsCollateral() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        uint256 assets = 100_000e6;
        uint256 shares = _deposit(assets);
        assertApproxEqRel(
            shares, (assets * supply) / pot, 1e12, "shares priced against the parked pot, not against zero"
        );

        // And the NEXT depositor still prices — the `NavUnpriceable` cascade cannot start.
        uint256 shares2 = _deposit(assets);
        assertGt(shares2, 0, "the second deposit still prices");
    }

    /// @dev The materialise round trip at a NON-UNIT exchange rate — where Compound's truncating
    ///      divisions actually truncate — AND with a partial raw float, so the SHORTFALL form is the
    ///      branch under test: raw is spent first and only `amount − raw` is redeemed. The pin is on
    ///      the Moonwell side (the only side `_materialiseUsdc` touches): the collateral moves by
    ///      exactly `+amount − shortfall`, bar integer dust. (Whole-book NAV is not asserted here —
    ///      the two-leg fixture's LP add reprices borrowed legs across the pool-vs-feed gap, which is
    ///      `deployIdle`'s pre-existing add path, not the materialise.)
    function testDeployIdleFromCollateralAtANonUnitRateConservesCollateralToADustBound() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        mUsdc.setExchangeRateStored(1.37e18); // the market has accrued supply interest
        vm.prank(proposer);
        strategy.supplyIdle(top / 2); // park half; the other half is the keeper's raw float

        uint256 collateralBefore = _collateralUsdc();
        vm.prank(proposer);
        strategy.deployIdle(top, 0); // raw float first, then materialise ONLY the top/2 shortfall

        assertEq(usdc.balanceOf(address(strategy)), 0, "the raw float was consumed first and in full");
        // -shortfall redeemed out, +full amount supplied back: net +top/2, with each truncating
        // division (redeem burn, mint credit, value read) flooring at most once at rate 1.37.
        assertApproxEqAbs(
            _collateralUsdc(),
            collateralBefore + top / 2,
            4,
            "collateral moved by exactly the supplied-minus-materialised net, bar truncation dust"
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
        strategy.fulfillRedeem(id, 0);

        assertEq(
            usdc.balanceOf(address(strategy)),
            idlePre - Math.mulDiv(idlePre, shares, supply),
            "stayers keep exactly (1-f) of the idle USDC"
        );
        assertGt(usdc.balanceOf(lp) - lpBefore, 0, "redeemer paid");
    }

    /**
     * @dev F15. A PARTIAL ASYNC REDEEM BURNS `f` OF THE cTOKENS, not a stored-rate underlying estimate.
     *      `redeemUnderlying(amt)` accrues and THEN burns `amt / rateFresh`, while `amt` was sized off
     *      `exchangeRateStored` — the last-accrued rate — so the two disagree by the whole rate gap and
     *      the redeemer's own slice of the accrued-but-uncapitalised supply interest stayed with the
     *      stayers. The old note defended that as "the payout was priced off the same stored rate", which
     *      is true of the FAST path but not of this one: `redeemUnwindImpl` is a PHYSICAL proportional
     *      unwind with no price stamped anywhere, so `f` of the cTokens is simply what `f` of the
     *      collateral means.
     *
     *      Armed with the supply-side gap the mock exists to express: views keep reporting 1.37e18 while
     *      the redeem's own mUSDC call accrues to 1.40e18 before it burns. The assertion is exact — a
     *      quarter redeem burns exactly a quarter of the cToken balance — and it is the fix's whole
     *      content: the old form burned `cBal × 1.37/1.40 / 4`, ~2.1% less than the redeemer's share.
     */
    function testPartialRedeemPaysTheRedeemerTheCollateralAccrual() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        mUsdc.setExchangeRateStored(1.37e18);
        mUsdc.setPendingExchangeRate(1.4e18);

        uint256 shares = SUPPLY / 4;
        uint256 cBefore = mUsdc.balanceOf(address(strategy));
        assertGt(cBefore, 0, "premise: the book holds collateral to split");

        uint256 id = _requestRedeem(shares);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        assertEq(
            cBefore - mUsdc.balanceOf(address(strategy)),
            Math.mulDiv(cBefore, shares, SUPPLY),
            "the redeemer burned exactly f of the cTokens, accrual included"
        );
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
        strategy.fulfillRedeem(id, 0);

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

    /// @dev The IL shortfall of `testAsyncFullRedeemCoversAnIlShortfallWithZeroRawIdle`, factored out: a
    ///      live book minted at the oracle-consistent tick, a `deposit` the keeper parks in full (so the
    ///      raw float starts at exactly 0 and the tests below own the whole Phase-1 budget), then the pool
    ///      moved 600 ticks up in lockstep across spot, TWAP, leg B's feed and its swap rate. Leg B is
    ///      token0, so the LP now holds LESS leg B than the leg-B debt and the proportional repay comes up
    ///      short. Returns the depositor's share balance, which IS the whole supply here.
    function _armLegBIlShortfall() internal returns (uint256 shares) {
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK_ORACLE_CONSISTENT));
        pool.setTick(TICK_ORACLE_CONSISTENT);
        _execute(SEED);

        shares = _deposit(250_000e6);
        vm.prank(proposer);
        strategy.supplyIdle(250_000e6);

        int24 newTick = TICK_ORACLE_CONSISTENT + 600;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(newTick));
        pool.setTick(newTick);
        pool.setTwapTick(newTick);
        uint256 newPB = _legBMovedPrice();
        legBFeed.setAnswer(int256(newPB));
        router.setRate(address(legB), address(usdc), (newPB * 1e18) / (100 * 1e8));
        router.setRate(address(usdc), address(legB), (100 * 1e8 * 1e18) / newPB);
        // FIXTURE ONLY (see the sibling test): `MockNpm` custodies exactly what it was minted, so a
        // post-move `collect` owes amounts re-priced at the new sqrtP that it never received.
        legB.mint(address(npm), 100e8);
        legA.mint(address(npm), 100e18);
    }

    /// @dev Request a redeem of `shares` from `lp` and return the request id.
    function _requestRedeem(uint256 shares) internal returns (uint256 id) {
        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        id = strategy.requestRedeem(shares, 0);
        vm.stopPrank();
    }

    /// @dev What an exact-OUTPUT buy of `legBOut` costs in USDC at the router's current rate, rounded up
    ///      exactly as `MockClSwapRouter.exactOutputSingle` rounds it.
    function _legBBuyCost(uint256 legBOut) internal view returns (uint256) {
        uint256 rate = router.rateE18(address(usdc), address(legB));
        return (legBOut * 1e18 + rate - 1) / rate;
    }

    /// @dev Leg B's post-move mark — the feed answer `_armLegBIlShortfall` installs, and therefore the
    ///      price `_settleShortfall` sizes its budget against.
    function _legBMovedPrice() internal pure returns (uint256) {
        return (P_LEG_B * 1_061_837) / 1_000_000; // 1.0001^600
    }

    /// @dev Re-price the USDC→leg B BUY side `worseBps` worse than the mark `_armLegBIlShortfall` left,
    ///      i.e. the cover now costs `(1 + worseBps/10000)×` the oracle value of what it buys. Only the
    ///      buy direction moves, so the leg sweeps are untouched.
    function _worsenLegBBuy(uint256 worseBps) internal {
        uint256 fair = (100 * 1e8 * 1e18) / _legBMovedPrice();
        router.setRate(address(usdc), address(legB), (fair * 10000) / (10000 + worseBps));
    }

    /**
     * @dev F08 (a). THE SETTLE COVER'S BUDGET IS `maxSlippageBps`, NOT A HARDCODED 10%. The old
     *      `_settleShortfall` redeemed `oracleCost × 110%` of collateral and pushed all of it through an
     *      exact-INPUT swap floored only at `debtRem × (1 − maxSlippageBps)`. Those two bounds were
     *      INDEPENDENT, so any router filling between them simply kept the difference — up to ~11% of the
     *      shortfall on this 100bps clone, taken out of the collateral backing every other holder.
     *
     *      A fill 500bps worse than the mark is the witness: comfortably inside the old 10% budget (so it
     *      used to go through and quietly overpay) and outside the configured 100bps band. Now that the
     *      budget IS the bound — one exact-output buy of `debtRem` capped at `oracleCost × (1 + slip)` —
     *      it is refused, and refused FAIL-CLOSED, because a half-cleared debt would only reappear as
     *      dust Moonwell refuses to release the collateral against.
     *
     *      Reached through the full-redeem Phase 2: the keeper parked everything, so Phase 1 has a zero
     *      budget and early-returns, leaving `_settleShortfall` to own the whole cover.
     */
    function testSettleShortfallCoverCannotOverpayPastMaxSlippage() public {
        uint256 shares = _armLegBIlShortfall();
        assertEq(usdc.balanceOf(address(strategy)), 0, "premise: Phase 1 has nothing to spend, so Phase 2 covers");
        _worsenLegBBuy(500);

        uint256 id = _requestRedeem(shares);
        vm.prank(proposer);
        vm.expectRevert(MockClSwapRouter.MockRouterMaxIn.selector);
        strategy.fulfillRedeem(id, 0);
    }

    /**
     * @dev F08 (b). THE BAND, NOT A DEMAND FOR A PERFECT FILL — the companion that stops (a) from passing
     *      on a cover that simply never works. 50bps worse than the mark is inside the clone's 100bps
     *      band and must complete, and the USDC it spent must be inside `oracleValue(bought) × 1.01`.
     *      Together the two tests bracket the settle cover at exactly `maxSlippageBps`.
     */
    function testSettleShortfallCoverAcceptsAFillInsideTheBand() public {
        uint256 shares = _armLegBIlShortfall();
        _worsenLegBBuy(50);

        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 boughtBefore = router.boughtOf(address(legB));
        uint256 id = _requestRedeem(shares);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        uint256 bought = router.boughtOf(address(legB)) - boughtBefore;
        assertGt(bought, 0, "the settle cover really ran");
        assertLe(
            _legBBuyCost(bought),
            (_valueUsdc(bought, _legBMovedPrice(), 8) * 10100) / 10000,
            "spend stayed inside oracle cost x (1 + maxSlippageBps)"
        );
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg-B debt cleared");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared");
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant restored");
        assertGt(usdc.balanceOf(lp) - lpBefore, 0, "the redeemer was paid");
    }

    /**
     * @dev F04. AN EXACT-OUTPUT SWAP HAS NO PARTIAL FILL, so a Phase-1 cover budget anywhere in the band
     *      `0 < idle < needed` used to REVERT the whole redeem — `emergencyRedeem` deadman included. The
     *      `usdcBal == 0` guard covered only the endpoint; every keeper float too small to finish the buy
     *      bricked the exit outright, which is the opposite of what a partial float should do.
     *
     *      Driven in two runs off the SAME armed book. The first has no float at all and exists only to
     *      MEASURE the cover — sizing the budget off a hardcoded guess would let the fixture drift out of
     *      the band and pass vacuously. The second hands the redeem exactly half that, i.e. squarely
     *      inside the band, and must complete: Phase 1's buy reverts in the router's own frame,
     *      `swapExactOut` swallows it as `filled == false`, and the redeem falls through to Phase 2 —
     *      which is precisely the next phase the fall-through exists for.
     *
     *      MUTATION-CHECKED: pass `false` for `bestEffort` at the two Phase-1 call sites and run (ii)
     *      reverts `MockRouterMaxIn`.
     */
    function testFullRedeemSurvivesPartialIdleUsdc() public {
        // (i) Reference run: no float, Phase 2 does all the covering, and the leg B it had to buy tells
        //     us what the buy costs.
        uint256 shares = _armLegBIlShortfall();
        uint256 boughtBefore = router.boughtOf(address(legB));
        uint256 id = _requestRedeem(shares);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
        uint256 needed = _legBBuyCost(router.boughtOf(address(legB)) - boughtBefore);
        assertGt(needed, 0, "premise: the armed book really does carry a leg-B shortfall to cover");

        // (ii) Same book, but the keeper left HALF the cover's cost raw: inside the band, and the exact
        //      band the old code could not survive.
        setUp();
        shares = _armLegBIlShortfall();
        usdc.mint(address(strategy), needed / 2);

        uint256 lpBefore = usdc.balanceOf(lp);
        boughtBefore = router.boughtOf(address(legB));
        id = _requestRedeem(shares);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        assertGt(router.boughtOf(address(legB)) - boughtBefore, 0, "the cover still ran and bought leg B");
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg-B debt cleared despite the partial budget");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared");
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant restored");
        assertGt(usdc.balanceOf(lp) - lpBefore, 0, "the redeemer was paid");
    }

    /**
     * @dev F04, THE OTHER HALF. Best-effort is scoped to the FULL-redeem Phase 1 — the only cover with a
     *      documented next phase. A PARTIAL redeem's cover is the last word: its budget is deliberately
     *      bounded at `balance − stayersIdle` so a shortfall can never be covered out of the stayers'
     *      reserve, and an unaffordable buy must roll the whole redeem back rather than silently leave
     *      the redeemer's debt slice behind on the stayers' book. Modelled with an illiquid buy side
     *      (1000× worse than the mark) so the budget genuinely cannot reach, and bracketed against the
     *      same redeem at the fair rate so the revert is provably the BUY and not the arming.
     */
    function testPartialRedeemCoverStillFailsClosedOnAnUnaffordableBuy() public {
        uint256 shares = _armLegBIlShortfall();
        uint256 snap = vm.snapshotState();

        // Control: at the fair rate this exact quarter redeem goes through.
        uint256 id = _requestRedeem(shares / 4);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
        assertGt(usdc.balanceOf(lp), 0, "control: the quarter redeem completes at the fair buy rate");

        vm.revertToState(snap);
        router.setRate(address(usdc), address(legB), router.rateE18(address(usdc), address(legB)) / 1000);

        id = _requestRedeem(shares / 4);
        vm.prank(proposer);
        vm.expectRevert(MockClSwapRouter.MockRouterMaxIn.selector);
        strategy.fulfillRedeem(id, 0);
    }

    /**
     * @dev F23 (a). THE DEADMAN IS ORACLE-FREE IN THE ORDINARY CASE, and one word in step B is what made
     *      it so. `_repay` accrues the market BEFORE it applies the payment, so a repay sized off
     *      `borrowBalanceStored` always left `current − stored` of interest standing. On a FULL redeem
     *      that dust was the only thing keeping the borrow balance nonzero, so `_settleShortfall` never
     *      took its `debtRem == 0` early return, every full redeem fell through into Phase 2 and read
     *      Chainlink — `emergencyRedeem` included, the one exit built for the state where Chainlink is
     *      exactly what is unavailable.
     *
     *      Armed with interest that has accrued in wall-clock time but that no transaction has folded in
     *      (invisible to `borrowBalanceStored`, which is the whole condition), on a book with surplus on
     *      both legs so the pro-rata repay can genuinely reach the accrued number. Then every feed is
     *      staled by the deadman warp and the exit must still complete.
     *
     *      MUTATION-CHECKED: put `borrowBalanceStored` back in `_redeemRepayFromCollected` and this
     *      reverts `StaleOracle` — from Phase 2's `_readAllPrices`, reached on the interest dust alone.
     */
    function testFullEmergencyRedeemIsOracleFreeOnABalancedBook() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);
        // Surplus on both legs: the repay has to be able to reach the ACCRUED debt out of held tokens,
        // or the shortfall would send the redeem to Phase 2 for a legitimate reason and the test would
        // be measuring the wrong thing.
        legB.mint(address(strategy), IDLE_LEG_B);
        legA.mint(address(strategy), IDLE_LEG_A);

        mLegB.accruePendingBorrowInterest(address(strategy), 1e6); // 0.01 leg B
        mLegA.accruePendingBorrowInterest(address(strategy), 1e16); // 0.01 leg A
        assertGt(
            mLegB.borrowBalanceAccrued(address(strategy)),
            mLegB.borrowBalanceStored(address(strategy)),
            "premise: leg B's stored read is stale-low"
        );
        assertGt(
            mLegA.borrowBalanceAccrued(address(strategy)),
            mLegA.borrowBalanceStored(address(strategy)),
            "premise: leg A's stored read is stale-low"
        );

        uint256 id = _requestRedeem(SUPPLY);
        vm.warp(block.timestamp + 2 days + 1); // deadman window elapsed; every feed now stale
        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        strategy.nav(); // premise: the oracle really is down, and down for THAT reason

        uint256 lpBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        uint256 assetsOut = strategy.emergencyRedeem(id, 0);

        assertGt(assetsOut, 0, "the deadman exit completed with every feed stale");
        assertEq(usdc.balanceOf(lp) - lpBefore, assetsOut, "...and the redeemer was paid");
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg-B debt cleared, accrued interest and all");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared, accrued interest and all");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "collateral fully redeemed: no cToken dust");
    }

    /**
     * @dev F23 (b). DEEP IL, ORACLE DOWN, AND THE SURPLUS LEG FINISHES THE JOB. An IL shortfall is
     *      ASYMMETRIC by construction: one leg over-collects while the other comes up short. The leg sweep
     *      used to run at the very END of the unwind, so that surplus was still sitting there as leg
     *      tokens while Phase 1 hunted for USDC and handed whatever it could not buy to Phase 2's
     *      Chainlink reads. Hoisted above the covers, the surplus leg becomes funding for the deficit
     *      leg's buy and the whole exchange stays oracle-free.
     *
     *      What the surplus leg CANNOT do is close the gap on its own, and that is not a fixture
     *      artifact: the LP sold its leg B into the move at prices below the new mark, so the surplus
     *      leg A is worth strictly LESS than the leg B it stopped holding. That difference IS the
     *      impermanent loss, and something un-levered has to absorb it — raw float here, collateral (and
     *      therefore Chainlink) in Phase 2. So the book is armed with HALF the cover's cost as float: too
     *      little to finish alone, enough once the swept surplus is added to it.
     *
     *      Every feed is staled by the deadman warp, so the sweep floors degrade to 0 and Phase 2 would
     *      revert `StaleOracle` the moment it were reached.
     *
     *      MUTATION-CHECKED: move the step-C sweep block back below the branch and this reverts
     *      `StaleOracle` — the float alone cannot finish the buy.
     */
    function testDeepILFullRedeemSelfFundsFromTheSurplusLeg() public {
        // (i) Reference run: size the cover the same way `testFullRedeemSurvivesPartialIdleUsdc` does.
        uint256 shares = _armLegBIlShortfall();
        uint256 boughtBefore = router.boughtOf(address(legB));
        uint256 id = _requestRedeem(shares);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
        uint256 needed = _legBBuyCost(router.boughtOf(address(legB)) - boughtBefore);
        assertGt(needed, 0, "premise: the armed book carries a leg-B shortfall");

        // (ii) Same book, half the cover's cost as float, and the oracle down.
        setUp();
        shares = _armLegBIlShortfall();
        usdc.mint(address(strategy), needed / 2);

        id = _requestRedeem(shares);
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        strategy.nav(); // premise: Phase 2 would revert if it were reached at all

        uint256 lpBefore = usdc.balanceOf(lp);
        boughtBefore = router.boughtOf(address(legB));
        vm.prank(lp);
        uint256 assetsOut = strategy.emergencyRedeem(id, 0);

        assertGt(
            router.boughtOf(address(legB)) - boughtBefore,
            0,
            "the deficit leg really was bought, out of float plus the swept surplus leg, with no feed read"
        );
        assertGt(assetsOut, 0, "the deep-IL deadman exit completed");
        assertEq(usdc.balanceOf(lp) - lpBefore, assetsOut, "...and the redeemer was paid");
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg-B debt cleared");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared");
    }

    /**
     * @dev F23 (c). THE HOIST STRANDS NOTHING. Sweeping before the covers is only safe because Phase 2
     *      now buys EXACTLY the debt (F08): the old exact-INPUT settle over-bought by its 10% buffer and
     *      relied on the sweep running LAST to turn that excess back into USDC. Above the sweep, the
     *      excess would have stranded as leg tokens on a book that is about to go flat — value left
     *      behind on a fund with zero shares outstanding.
     */
    function testHoistedSweepStrandsNoLegTokens() public {
        uint256 shares = _armLegBIlShortfall();
        uint256 id = _requestRedeem(shares);
        uint256 boughtBefore = router.boughtOf(address(legB));
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        assertGt(router.boughtOf(address(legB)) - boughtBefore, 0, "premise: a cover really ran on this redeem");
        assertEq(legB.balanceOf(address(strategy)), 0, "no leg B stranded above the hoisted sweep");
        assertEq(legA.balanceOf(address(strategy)), 0, "no leg A stranded above the hoisted sweep");
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant restored");
    }

    /**
     * @dev F14 (a). THE PROPOSER GETS TO STATE A FRESH FLOOR. The only bound on the net payout used to be
     *      the `minAssetsOut` the requester fixed at `requestRedeem`, and the 2-day `FULFILL_WINDOW`
     *      means that number can be two days old when the fulfil lands — a long time for a levered book.
     *      Nothing else on the path covers the gap: `redeemUnwindImpl`'s sweep floors bound individual
     *      SWAPS, not the payout, and a full redeem's covers lean on this number alone.
     */
    function testFulfillRedeemEnforcesTheFreshProposerFloor() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        uint256 id = _requestRedeem(SUPPLY / 4); // stored floor 0, as `_requestRedeem` passes
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientAssetsOut.selector);
        strategy.fulfillRedeem(id, type(uint128).max); // an unreachable fresh floor
    }

    /**
     * @dev F14 (b). THE FLOOR IS `max(stored, fresh)`, NEVER `min`. The requester's own guarantee must not
     *      be lowerable by whoever fulfils — that direction would let the proposer choose a worse payout
     *      than the redeemer signed up for. A huge stored floor still binds when the proposer passes 0.
     */
    function testFulfillRedeemCannotLowerTheRequestersFloor() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        uint256 shares = SUPPLY / 4;
        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        uint256 id = strategy.requestRedeem(shares, type(uint128).max); // the requester's own huge floor
        vm.stopPrank();

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientAssetsOut.selector);
        strategy.fulfillRedeem(id, 0); // "no fresh opinion" must not mean "drop the requester's floor"
    }

    /// @dev F14 (c). `0` is the identity: an integrator with nothing fresher to say gets exactly the old
    ///      behaviour, with the stored floor doing all the work.
    function testFulfillRedeemWithZeroFreshFloorIsUnchanged() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        uint256 shares = SUPPLY / 4;
        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 id = _requestRedeem(shares);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        assertGt(usdc.balanceOf(lp) - lpBefore, 0, "the redeem completed and paid out");
        assertTrue(strategy.redeemRequest(id).settled, "the request is settled");
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
        strategy.fulfillRedeem(id, 0);

        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg-B debt cleared");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "collateral fully redeemed");
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant restored");
        assertApproxEqRel(usdc.balanceOf(lp), SEED, 5e16, "redeemer recovered ~the whole book");
    }

    /**
     * @dev THE LAST HOLDER OF A PARKED FLAT BOOK CAN LEAVE THROUGH THE FAST PATH. Zero debt means
     *      there is no LTV to breach, so `fromCollateral == collateralUsdc` (the full-pot draw) is a
     *      legitimate payout, not a gate violation — the `FastRedeemExceedsLtv` guard protects a
     *      division that only exists when debt > 0 and must not fire without any. Before the guard
     *      moved inside the debt branch, this exact call reverted
     *      `FastRedeemExceedsLtv(uint256.max, …)` on a book carrying no debt at all, stranding the
     *      redeemer behind `requestRedeem` + the fulfil window.
     */
    function testFastFullRedeemPaysOutAFlatBookHeldEntirelyAsCollateral() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        uint256 out = strategy.redeem(supply, 0);
        vm.stopPrank();

        assertEq(out, pot, "the whole pot paid out: no debt, no LTV gate");
        assertEq(usdc.balanceOf(lp), pot, "delivered to the redeemer");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "collateral fully drawn");
    }

    /**
     * @dev THE FAST-PATH TWIN of `testFullAsyncRedeemLeavesNoCollateralDustAtANonUnitRate`, and the more
     *      dangerous half. `redeemUnderlying(amt)` accrues and burns at the FRESH rate while `amt` was
     *      sized off `nav()`'s `exchangeRateStored`, so a full fast redeem used to strand
     *      `cBal x (1 - stored/fresh)` cTokens. `_redeemCollateral` fixed exactly this on the ASYNC path;
     *      the fast path never got it, and the parked-flat-book fast full redeem is precisely the state
     *      that makes it reachable.
     *
     *      WHY IT IS WORSE THAN DUST: the redeem burns the LAST shares, so the residue is a fund with
     *      assets and no shares — `nav() > 0` at `totalSupply() == 0`. The next depositor of 1 USDC mints
     *      100% of a book that already holds the stranded collateral. The fix burns the cTOKEN balance
     *      and pays the fresh-rate proceeds to the sole holder they belong to.
     */
    function testFastFullRedeemLeavesNoCollateralDustAtANonUnitRate() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        // Views report 1.37e18; the redeem's own mUSDC call accrues to 1.40e18 before it burns.
        mUsdc.setExchangeRateStored(1.37e18);
        mUsdc.setPendingExchangeRate(1.4e18);
        uint256 quotedAtStoredRate = strategy.nav();

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        uint256 out = strategy.redeem(supply, 0);
        vm.stopPrank();

        assertEq(mUsdc.balanceOf(address(strategy)), 0, "no rate-gap cToken dust after a full fast redeem");
        assertEq(vault.totalSupply(), 0, "the last shares are burnt");
        assertEq(strategy.nav(), 0, "a fund with zero shares outstanding prices at exactly zero");
        assertGt(out, quotedAtStoredRate, "the sole holder is paid the FRESH-rate proceeds, not the stored-rate quote");
        assertEq(usdc.balanceOf(lp), out, "...and it is delivered");
        // The surplus is exactly the rate gap on the parked pot: the pot was supplied at rate 1.0, so
        // `cBal == pot` and the gap is `pot x (1.40 - 1.37)` == 30,000e6 on a 1,000,000e6 park — the
        // precise figure james-saint's repro showed the next depositor would have minted against.
        assertEq(out - quotedAtStoredRate, (pot * 3) / 100, "surplus == pot x (fresh - stored)");
    }

    /// @dev ERC-7201 base of the strategy's diamond storage (`LeveragedAerodromeCLStrategy.STORAGE_SLOT`),
    ///      used to arm `protocolFeeOwed` directly — there is no setter for it and reaching a non-zero
    ///      accrual through the fee machinery would drag HWM/timestamp state into a test about payout
    ///      arithmetic. The write is asserted through `layout()` before it is relied on.
    bytes32 internal constant LAYOUT_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /**
     * @dev THE FEE MUST STAY FUNDED ACROSS THE FULL-REDEEM BURN — the sign-flipped twin of the windfall
     *      bug above, and the reason the surplus is measured against `collateralUsdc` rather than
     *      `fromCollateral`.
     *
     *      `fromCollateral` is already NET of `protocolFeeOwed`: on a full redeem
     *      `assetsOut == navNet == raw + C - owed` and the idle draw is the whole raw balance, so
     *      `fromCollateral == C - owed`. Baselining the fresh-rate surplus there pays out
     *      `(C_fresh - C) + owed` — the rate gap PLUS the accrued fee — and the redeemer walks off with
     *      a liability that has nothing behind it: `protocolFeeOwed` survives the redeem pointing at an
     *      empty book, so the NEXT depositor's capital settles it.
     *
     *      `nav()` cannot see this either way (it floors at `gross > owed ? gross - owed : 0`, so it
     *      reads 0 whether the fee is funded or drained), which is exactly why the dust test above —
     *      which runs with `owed == 0`, where the two baselines coincide — cannot tell them apart. This
     *      one arms a real fee.
     *
     *      REACHABLE ON THIS FIXTURE'S OWN CONFIG: with `performanceFeeBps == 0` and a protocol fee
     *      configured, a crystallise accrues `protocolFeeOwed` while minting NO fee shares, so a sole
     *      holder is still `shares == supply` and takes the full-redeem branch.
     */
    function testFastFullRedeemKeepsTheProtocolFeeFunded() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        mUsdc.setExchangeRateStored(1.37e18);
        mUsdc.setPendingExchangeRate(1.4e18);

        uint256 owed = 50_000e6;
        vm.store(address(strategy), bytes32(uint256(LAYOUT_SLOT) + 22), bytes32(owed));
        assertEq(strategy.layout().protocolFeeOwed, owed, "precondition: the fee liability is armed");
        assertEq(usdc.balanceOf(address(strategy)), 0, "precondition: nothing raw - the fee is not funded yet");

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        uint256 out = strategy.redeem(supply, 0);
        vm.stopPrank();

        // The whole book at the FRESH rate, minus the fee the fund still owes.
        uint256 freshBook = (pot * 140) / 100;
        assertEq(out, freshBook - owed, "redeemer paid the fresh-rate book MINUS the protocol fee");
        assertEq(usdc.balanceOf(address(strategy)), owed, "the fee stays funded in raw USDC, to the wei");
        assertEq(strategy.layout().protocolFeeOwed, owed, "...and the liability still points at real USDC");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "no cToken dust either");
        assertEq(strategy.nav(), 0, "book net of the fee is exactly zero");
    }

    /**
     * @dev THE EARLY-RETURN HOLE, closed: `owed >= collateral`. When the accrued fee exceeds the
     *      parked slice, the raw balance covers the whole FEE-NETTED payout, `fromCollateral == 0`,
     *      and the old early return skipped the burn branch entirely — burning the last shares with
     *      100% of the cToken balance stranded (a strictly LARGER residue than the rate-gap dust the
     *      branch exists to close). A small park under a larger accrued fee is an ordinary operating
     *      state, not a corner: `supplyIdle` is a dial, not a sweep.
     */
    function testFastFullRedeemSweepsTheParkedResidueWhenOwedExceedsTheCollateral() public {
        _execute(SEED);
        vm.prank(proposer);
        strategy.flatten(0, 1);
        uint256 pot = usdc.balanceOf(address(strategy));
        uint256 parked = 10_000e6;
        vm.prank(proposer);
        strategy.supplyIdle(parked); // small park; the rest stays raw
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        mUsdc.setExchangeRateStored(1.37e18); // C = 13,700e6 at the stored rate
        mUsdc.setPendingExchangeRate(1.4e18); // C_fresh = 14,000e6
        uint256 owed = 20_000e6; // owed > C: the early-return state
        vm.store(address(strategy), bytes32(uint256(LAYOUT_SLOT) + 22), bytes32(owed));

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        uint256 out = strategy.redeem(supply, 0);
        vm.stopPrank();

        uint256 raw = pot - parked;
        assertEq(out, raw + (parked * 140) / 100 - owed, "paid the raw float + the FRESH-rate park, minus the fee");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "the parked residue was swept, not stranded");
        assertEq(usdc.balanceOf(address(strategy)), owed, "the fee liability stays funded to the wei");
        assertEq(vault.totalSupply(), 0, "the last shares are burnt");
        assertEq(strategy.nav(), 0, "no assets-with-no-shares fund survives, even after the accrual lands");
    }

    /**
     * @dev THE `isFullRedeem` CONJUNCT, mutation-pinned. A PARTIAL redeem at a non-unit rate must pay
     *      the stored-rate quote and NOTHING more: the fresh-rate surplus on the whole collateral
     *      belongs to ALL holders, and a partial redeemer who triggered the burn-everything branch
     *      would pocket it outright. Deleting the full-redeem condition on the burn branch passed the
     *      entire suite before this test existed — no partial redeem ever ran at a non-unit rate.
     */
    function testPartialFastRedeemAtANonUnitRatePaysTheStoredRateQuoteOnly() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        mUsdc.setExchangeRateStored(1.37e18);
        mUsdc.setPendingExchangeRate(1.4e18);

        uint256 quoted = strategy.nav() / 4; // f = 1/4 of the stored-rate book
        vm.startPrank(lp);
        vault.approve(address(strategy), supply / 4);
        uint256 out = strategy.redeem(supply / 4, 0);
        vm.stopPrank();

        assertEq(out, quoted, "a partial redeemer is paid the stored-rate quote, NOT the rate gap");
        // The stayers keep the accrual: the remaining collateral revalues at the fresh rate the
        // redeem's own accrual just landed, so post-op nav is the fresh book minus the quote paid.
        assertApproxEqAbs(
            strategy.nav(), (pot * 140) / 100 - quoted, 2, "the fresh-rate surplus stays with the stayers"
        );
    }

    /// @dev MIXED FUNDING on the burn branch — the realistic operating shape (a keeper float PLUS a
    ///      parked slice), which both siblings above run with zero raw. Pins that the idle draw, the
    ///      collateral burn and the fee retention compose: retained == owed to the wei, no dust.
    function testFastFullRedeemWithMixedFundingRetainsExactlyTheFee() public {
        _execute(SEED);
        vm.prank(proposer);
        strategy.flatten(0, 1);
        uint256 pot = usdc.balanceOf(address(strategy));
        uint256 parked = (pot * 3) / 4;
        vm.prank(proposer);
        strategy.supplyIdle(parked);
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        mUsdc.setExchangeRateStored(1.37e18);
        mUsdc.setPendingExchangeRate(1.4e18);
        uint256 owed = 50_000e6;
        vm.store(address(strategy), bytes32(uint256(LAYOUT_SLOT) + 22), bytes32(owed));

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        uint256 out = strategy.redeem(supply, 0);
        vm.stopPrank();

        assertEq(out, (pot - parked) + (parked * 140) / 100 - owed, "raw float + fresh-rate park - fee");
        assertEq(usdc.balanceOf(address(strategy)), owed, "retained == the fee liability, to the wei");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "no cToken dust");
        assertEq(strategy.nav(), 0, "zero-share fund prices at zero");
    }

    // ==================== previewRedeem MIRRORS THE EXECUTED redeem ====================
    //
    // `previewRedeem`'s natspec promises it mirrors `redeem` EXACTLY, and a frontend routes on its
    // `fastOk`: false means "do not call redeem, go through requestRedeem + the fulfil window". Nothing
    // pinned that promise, and it drifted — when `fastRedeemImpl` moved its `>= collateralUsdc` guard
    // inside the debt branch, the preview's copy of the same guard stayed outside it, so the preview
    // said `false` for a redeem the executed path pays in full. These three tests pin BOTH halves of
    // the mirror (the routing flag AND the quoted number) on the states where they can disagree.

    /**
     * @dev THE DRIFT, pinned at its worst case: the last holder of a parked flat book. Zero debt, the
     *      whole pot as collateral, a FULL redeem — so `fromCollateral == collateralUsdc` exactly. The
     *      executed `redeem` pays the whole pot (asserted directly above, in
     *      `testFastFullRedeemPaysOutAFlatBookHeldEntirelyAsCollateral`), so a preview answering
     *      `fastOk == false` would route the only remaining holder into `requestRedeem` + the deadman
     *      for no reason. Both halves are asserted, and the quote is checked against the payout the
     *      SAME call actually delivers.
     */
    function testPreviewRedeemMatchesTheExecutedFastRedeemOfAParkedFlatBook() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        (uint256 quoted, bool fastOk) = strategy.previewRedeem(supply);
        assertTrue(fastOk, "zero debt means no LTV gate to breach - the fast path serves this redeem");
        assertEq(quoted, pot, "and it quotes the whole pot");

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        uint256 out = strategy.redeem(supply, 0);
        vm.stopPrank();

        // NOTE the exactness of this mirror is scoped to a book with NO pending accrual: at a unit
        // stored/fresh rate the full-redeem burn realises exactly the quote. With un-accrued interest
        // outstanding the executed payout is LARGER than the quote — the carve-out pinned by
        // `testPreviewUnderQuotesTheFullFlatBookFastRedeem` below.
        assertEq(out, quoted, "quoted == executed: the preview is the mirror it claims to be");
    }

    /**
     * @dev THE DOCUMENTED CARVE-OUT, pinned with its own figures. A full redeem of a flat, zero-debt
     *      book burns the whole cToken balance and pays the FRESH-rate proceeds, while `previewRedeem`
     *      prices the same collateral at `nav()`'s stored (last-accrued) rate. The divergence is in the
     *      SAFE direction only — the preview under-quotes, so a preview-derived `minAssetsOut` cannot
     *      bounce — and `fastOk` stays true. These are the exact numbers the natspec cites.
     */
    function testPreviewUnderQuotesTheFullFlatBookFastRedeem() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        mUsdc.setExchangeRateStored(1.37e18);
        mUsdc.setPendingExchangeRate(1.4e18);

        (uint256 quoted, bool fastOk) = strategy.previewRedeem(supply);
        assertTrue(fastOk, "the fast path serves it");
        assertEq(quoted, (pot * 137) / 100, "quoted at the STORED rate");

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        uint256 out = strategy.redeem(supply, quoted); // the under-quote must clear as minAssetsOut
        vm.stopPrank();

        assertEq(out, (pot * 140) / 100, "paid at the FRESH rate");
        assertGe(out, quoted, "the divergence is one-directional: the preview only ever UNDER-quotes");
    }

    /**
     * @dev THE OTHER SIDE OF THE SAME GUARD — it must still fire where it means something. A LEVERED
     *      book carries debt, so a full redeem's collateral draw genuinely would breach `maxLtvBps`
     *      (the post-draw denominator collapses while the debt stays put). `fastOk == false` here is
     *      correct advice, and the executed fast path agrees by reverting: the flag and the gate are
     *      the same decision, which is the property the zero-debt test above could not show on its own.
     */
    function testPreviewRedeemAdvisesTheAsyncPathWhenTheDrawWouldBreachTheLtvGate() public {
        _execute(SEED);
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        assertGt(mLegA.borrowBalance(address(strategy)), 0, "precondition: the book carries debt");

        (uint256 quoted, bool fastOk) = strategy.previewRedeem(supply);
        assertGt(quoted, 0, "the payout is still quoted - only the ROUTING is negative");
        assertFalse(fastOk, "a full draw against a levered book breaches the LTV gate");

        // ...and that is exactly what the executed path does, which is what makes the advice correct.
        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        // Selector-only: the reverting LTV is whatever the post-draw book computes (here a real,
        // finite number well over `maxLtvBps` — NOT the `uint256.max` sentinel, which is the
        // collateral-exhausted arm). What is being pinned is that the gate fires at all, i.e. that the
        // preview's `false` and the executed revert are the same decision.
        vm.expectPartialRevert(LeveragedAeroVenue.FastRedeemExceedsLtv.selector);
        strategy.redeem(supply, 0);
        vm.stopPrank();
    }

    /**
     * @dev THE OTHER DIRECTION OF THE SAME MIRROR, and the reason the zero-debt branch is a BOUND rather
     *      than an unconditional `true`. A zero-debt book is NOT necessarily a flat one: `repayBorrowBehalf`
     *      is permissionless, so anyone can retire the fund's debt while the LP position stays open (modelled
     *      here by repaying both legs as the strategy). `nav()` then prices LP equity the mUSDC collateral
     *      alone cannot fund, so a full redeem's `fromCollateral` STRICTLY exceeds `collateralUsdc` and the
     *      fast path cannot serve it — the executed redeem refuses at Moonwell.
     *
     *      An unconditional `fastOk = true` on zero debt (the shape this suite briefly shipped) told a
     *      frontend to call a `redeem` that reverts. The bound keeps EXACT cover true — that is the parked
     *      flat-book case above — and flips only the strict over-draw.
     */
    function testPreviewRefusesAZeroDebtOverDrawAgainstALiveLpPosition() public {
        _execute(SEED);
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        // Anyone can retire the debt; the LP position is untouched and stays live.
        _retireAllDebtPermissionlessly();
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt retired");
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg-B debt retired");
        assertGt(strategy.layout().tokenId, 0, "...and the LP position is still live");

        (uint256 quoted, bool fastOk) = strategy.previewRedeem(supply);
        assertGt(quoted, _collateralUsdc(), "precondition: the payout exceeds the collateral that funds it");
        assertFalse(fastOk, "zero debt is not a free pass - the collateral must still COVER the draw");

        // ...and the executed path agrees — with the TYPED refusal now: a full fast redeem of any
        // non-flat book is refused up front (`fastRedeemImpl`'s top guard, the route-to-requestRedeem
        // sentinel), rather than falling through to whatever Moonwell (or the mock's underflow) makes
        // of the over-draw.
        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAeroVenue.FastRedeemExceedsLtv.selector, type(uint256).max, uint256(6500))
        );
        strategy.redeem(supply, 0);
        vm.stopPrank();
    }

    /// @dev Retire BOTH leg debts from outside the strategy's own ops — the reachable-by-anyone state
    ///      `repayBorrowBehalf` creates on a live Compound-fork market. Pranked as the strategy because
    ///      `MockLendingMarket.repayBorrow` is `msg.sender`-scoped; the resulting STATE (zero debt, live
    ///      LP, untouched collateral) is what matters and is identical either way.
    function _retireAllDebtPermissionlessly() internal {
        uint256 debtA = mLegA.borrowBalance(address(strategy));
        uint256 debtB = mLegB.borrowBalance(address(strategy));
        legA.mint(address(strategy), debtA);
        legB.mint(address(strategy), debtB);
        vm.startPrank(address(strategy));
        legA.approve(address(mLegA), debtA);
        mLegA.repayBorrow(debtA);
        legB.approve(address(mLegB), debtB);
        mLegB.repayBorrow(debtB);
        vm.stopPrank();
    }

    /**
     * @dev THE EVERYDAY CASE, so the mirror is pinned where it is exercised most: a small partial
     *      redeem of a levered book routes fast AND quotes the payout to the unit. This is the
     *      assertion that would catch a future divergence in the SHARE-PRICING half of the preview
     *      (fee simulation, idle-first split), which the two guard tests above do not touch.
     */
    function testPreviewRedeemQuotesTheExecutedPayoutOnAPartialFastRedeem() public {
        _execute(SEED);
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        uint256 shares = supply / 20; // 5% - small enough to clear the LTV gate comfortably
        (uint256 quoted, bool fastOk) = strategy.previewRedeem(shares);
        assertTrue(fastOk, "a 5% draw leaves the book well inside maxLtv");
        assertGt(quoted, 0, "and quotes a real payout");

        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        uint256 out = strategy.redeem(shares, 0);
        vm.stopPrank();

        assertEq(out, quoted, "quoted == executed on the everyday path");
    }

    /// @dev A FULL async redeem burns the cTOKEN balance (`redeem(cBal)`, `settleImpl`'s form), so no
    ///      rate-gap dust survives — sized off `exchangeRateStored`, a full `redeemUnderlying` at the
    ///      fresh rate always left a few cTokens behind, and the flat-branch `nav()` now PRICES that
    ///      dust: a zero-share fund would read `nav() > 0` and gift it to the next depositor as a
    ///      share-price discontinuity. The non-unit rate is what makes the two forms differ at all.
    function testFullAsyncRedeemLeavesNoCollateralDustAtANonUnitRate() public {
        _execute(SEED);
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        // The gap the branch exists for: views report 1.37e18, the next MUTATING mUSDC call accrues to
        // 1.40e18 first. Sizing a full draw as an UNDERLYING amount off the stored rate therefore burns
        // `amount x 1e18 / 1.40e18` cTokens and strands `cBal x (1 - 1.37/1.40)`. Without a separate
        // fresh rate this test passed with the branch deleted: one settable rate meant the mock burned
        // at exactly the rate the caller sized with, so the dust could not exist.
        mUsdc.setExchangeRateStored(1.37e18); // stored < fresh is the on-chain norm
        mUsdc.setPendingExchangeRate(1.4e18); // ...and this is the fresh rate the redeem accrues to

        vm.prank(lp);
        vault.approve(address(strategy), supply);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(supply, 0);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        assertEq(mUsdc.balanceOf(address(strategy)), 0, "no rate-gap cToken dust after a full redeem");
        assertEq(strategy.nav(), 0, "a fund with zero shares outstanding prices at exactly zero");
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

    // ========= REDEEM-SWEEP ORACLE FLOORS, DEADMAN-PRESERVING (review finding 4) =========
    //
    // `redeemUnwindImpl` step E sweeps the two residual legs to USDC. Those were the LAST zero-min-out
    // swaps in the system: a hostile router / sandwich could fill them at any price, and the loss landed
    // entirely on the REDEEMER (the stayers' `(1-f)` share is reserved BEFORE the sweep and stays behind
    // as legs). They now carry the same Chainlink floor every sibling sweep does —
    // `oracleValue(amount ACTUALLY SOLD) x (1 - maxSlippageBps)` — derived behind a try-able external hop
    // so `emergencyRedeem`, the deadman for the oracle-down-AND-backend-dead state, still completes with
    // the floors falling back to 0.

    /// @dev A rerange-remainder-shaped idle balance on BOTH legs: $100k of leg B, $30k of leg A. Big
    ///      enough that step E genuinely sells something (without it the unwind's collect is consumed by
    ///      the pro-rata repay and the sweep is ~dust).
    uint256 internal constant IDLE_LEG_B = 1e8;
    uint256 internal constant IDLE_LEG_A = 10e18;

    uint256 internal constant SUPPLY = 1_000_000e12;

    /// @dev Live position + `SUPPLY` shares outstanding + an idle remainder on both legs, then a request
    ///      for `shares`. Returns the request id.
    function _armRedeemWithIdleLegs(uint256 shares) internal returns (uint256 id) {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);
        legB.mint(address(strategy), IDLE_LEG_B);
        legA.mint(address(strategy), IDLE_LEG_A);
        vm.prank(lp);
        vault.approve(address(strategy), shares);
        vm.prank(lp);
        id = strategy.requestRedeem(shares, 0);
    }

    /// @dev Re-price the leg->USDC SELL direction at `bps` of the oracle mark (10000 == the fair rate
    ///      `setUp` installs). The buy direction is untouched, so only the step-E sweeps are affected.
    function _setLegSellRate(uint256 bps) internal {
        router.setRate(address(legB), address(usdc), (P_LEG_B * 1e18 * bps) / (100 * 1e8 * 10000));
        router.setRate(address(legA), address(usdc), (P_LEG_A * 1e18 * bps) / (100 * 1e18 * 10000));
    }

    /// @dev The stayers' reserved leg share: `(1-f)` of the leg balance MEASURED just before the unwind,
    ///      which is exactly what step E must leave behind on that leg. Measured, not assumed off
    ///      `IDLE_LEG_*`: a genesis mint at a skewed/oracle-inconsistent tick already strands a real leg
    ///      remainder (the documented per-borrow ratchet), so the pre-unwind balance is that PLUS the
    ///      idle mint above.
    function _stayerLegOf(uint256 preBal, uint256 shares) internal pure returns (uint256) {
        return preBal - Math.mulDiv(preBal, shares, SUPPLY);
    }

    /**
     * @dev (a) THE FINDING. A fill 2% under the oracle mark — outside the clone's `maxSlippageBps` band
     *      of 100bps — is now REFUSED. Before the floor this filled silently and the redeemer simply got
     *      less USDC, with nothing on-chain to say so.
     */
    function testRedeemLegSweepRefusesAFillBelowTheOracleFloor() public {
        uint256 id = _armRedeemWithIdleLegs(SUPPLY / 4);
        _setLegSellRate(9800); // 200bps under oracle vs. a 100bps floor

        vm.prank(proposer);
        vm.expectRevert(MockClSwapRouter.MockRouterMinOut.selector);
        strategy.fulfillRedeem(id, 0);
    }

    /**
     * @dev (b) BINDING BUT NOT TRIPPING. A fill 50bps under the mark is inside the 100bps band and must
     *      go through — the floor is a slippage bound, not a demand for a perfect fill. Together with (a)
     *      this brackets the floor at `maxSlippageBps`, so the test pins the actual band and not merely
     *      "some floor exists".
     */
    function testRedeemLegSweepAcceptsAFairFillWithTheFloorBinding() public {
        uint256 shares = SUPPLY / 4;
        uint256 id = _armRedeemWithIdleLegs(shares);
        _setLegSellRate(9950); // 50bps under oracle: inside the band

        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 preB = legB.balanceOf(address(strategy));
        uint256 preA = legA.balanceOf(address(strategy));
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        assertGt(usdc.balanceOf(lp) - lpBefore, 0, "the redeem completed and paid out");
        // The sold slice really did clear a floor priced off the SOLD amount, not the raw balance: the
        // stayers' reservation is untouched on both legs (see (d)).
        assertEq(legB.balanceOf(address(strategy)), _stayerLegOf(preB, shares), "leg-B reservation intact");
        assertEq(legA.balanceOf(address(strategy)), _stayerLegOf(preA, shares), "leg-A reservation intact");
    }

    /**
     * @dev (c) THE DEADMAN TEST — the one that matters most. `emergencyRedeem` is the trustless exit for
     *      the state where the ORACLE IS DOWN **and** the backend is dead, and it routes through this
     *      exact sweep. If the floor were derived fail-closed, adding it would have converted a
     *      value-protection guard into a fund freeze in precisely the state the deadman exists for.
     *
     *      Armed as hostilely as the state allows: every feed stale (the 2-day `FULFILL_WINDOW` warp does
     *      that on its own, with `maxDelay` at 1 hour) AND the router filling 200bps under the mark — the
     *      exact combination that reverts in (a). It must complete, at floor 0, paying the redeemer.
     */
    function testEmergencyRedeemStillCompletesWithStaleFeedsAndAHostileFill() public {
        uint256 shares = SUPPLY / 4;
        uint256 id = _armRedeemWithIdleLegs(shares);
        _setLegSellRate(9800);

        vm.warp(block.timestamp + 2 days + 1); // deadman window elapsed; every feed now stale
        // Sanity: the oracle really is down for this book — and down for THAT reason. The specific
        // selector matters: a bare `expectRevert()` would also pass if `nav()` broke for an unrelated
        // reason, quietly turning the premise of this test into a tautology. `nav()` prices its legs
        // through `LeveragedAeroValuation.readUsd8` → `ChainlinkReader.readUsd`, whose `age > maxDelay`
        // branch (the 1-hour `maxDelay` against a 2-day warp) raises `StaleOracle`.
        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        strategy.nav();

        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 preB = legB.balanceOf(address(strategy));
        uint256 preA = legA.balanceOf(address(strategy));
        vm.prank(lp);
        uint256 assetsOut = strategy.emergencyRedeem(id, 0);

        assertGt(assetsOut, 0, "the deadman exit completed with the oracle down");
        assertEq(usdc.balanceOf(lp) - lpBefore, assetsOut, "...and the redeemer was paid");
        // Floor 0 is the PRE-FIX behaviour, reached only here: the swaps ran despite the hostile rate.
        assertEq(legB.balanceOf(address(strategy)), _stayerLegOf(preB, shares), "leg-B swept at floor 0");
        assertEq(legA.balanceOf(address(strategy)), _stayerLegOf(preA, shares), "leg-A swept at floor 0");
    }

    /**
     * @dev (d) INSULATION REGRESSION. The floors must not move the stayer/redeemer boundary: stayers keep
     *      exactly `(1-f)` of every leg and of the idle USDC, whatever the fill was. Asserted in closed
     *      form against the pre-unwind snapshot, and asserted to be the SAME number under a fair fill and
     *      under a hostile-but-floor-0 deadman fill — the floor changes whether a swap is allowed, never
     *      who owns what.
     */
    function testStayerReservationIsIdenticalWithAndWithoutABindingFloor() public {
        uint256 shares = SUPPLY / 4;
        uint256 idleUsdc = 200_000e6;

        uint256 id = _armRedeemWithIdleLegs(shares);
        usdc.mint(address(strategy), idleUsdc);
        uint256 idlePre = usdc.balanceOf(address(strategy));
        uint256 preB = legB.balanceOf(address(strategy));
        uint256 preA = legA.balanceOf(address(strategy));

        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0); // fair fill: the floor binds and is cleared

        uint256 legBKept = legB.balanceOf(address(strategy));
        uint256 legAKept = legA.balanceOf(address(strategy));
        assertEq(legBKept, _stayerLegOf(preB, shares), "stayers keep (1-f) of leg B");
        assertEq(legAKept, _stayerLegOf(preA, shares), "stayers keep (1-f) of leg A");
        assertEq(
            usdc.balanceOf(address(strategy)),
            idlePre - Math.mulDiv(idlePre, shares, SUPPLY),
            "stayers keep (1-f) of the idle USDC"
        );

        // Same book, same f, but reached through the floor-0 deadman path under a hostile fill: the
        // reservation is byte-identical, so the floor moved no value between the two parties.
        setUp();
        id = _armRedeemWithIdleLegs(shares);
        usdc.mint(address(strategy), idleUsdc);
        _setLegSellRate(9800);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(lp);
        strategy.emergencyRedeem(id, 0);

        assertEq(legB.balanceOf(address(strategy)), legBKept, "leg-B reservation byte-identical");
        assertEq(legA.balanceOf(address(strategy)), legAKept, "leg-A reservation byte-identical");
    }

    /**
     * @dev (e) THE FALLBACK IS MARKED ON CHAIN (review round 2, item 3). The `catch {}` that drops the
     *      floors to 0 is deliberate — the deadman in (c) depends on it — but it cannot distinguish a
     *      stale feed / down sequencer from an out-of-gas, and before this it left NO on-chain trace at
     *      all. A monitor could not tell a healthy fulfill from one whose swaps ran unbounded.
     *
     *      Both directions asserted, because an event that always fires says nothing: the healthy fulfill
     *      of (b) must emit NOTHING, and the deadman of (c) must emit `RedeemSweepFloorsDegraded` — FROM
     *      THE STRATEGY ADDRESS, since the manager that raises it is delegatecalled.
     */
    function testTheRedeemFloorFallbackIsMarkedOnChain() public {
        uint256 shares = SUPPLY / 4;

        // HEALTHY: floors derived and cleared — no marker.
        uint256 snap = vm.snapshotState();
        uint256 id = _armRedeemWithIdleLegs(shares);
        _setLegSellRate(9950);
        vm.recordLogs();
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.RedeemSweepFloorsDegraded.selector,
                "a healthy fulfill must not mark a degradation"
            );
        }
        vm.revertToState(snap);

        // DEGRADED: the deadman warp staled every feed, so the derivation reverts and the floors fall
        // back to 0 — the one state that fail-open exists for, now visible.
        id = _armRedeemWithIdleLegs(shares);
        vm.warp(block.timestamp + 2 days + 1);
        vm.recordLogs();
        vm.prank(lp);
        strategy.emergencyRedeem(id, 0);

        bool marked;
        logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(strategy)
                    && logs[i].topics[0] == LeveragedAerodromeCLStrategy.RedeemSweepFloorsDegraded.selector
            ) marked = true;
        }
        assertTrue(marked, "the floor fallback is marked, from the STRATEGY address (manager is delegatecalled)");
    }

    // ============ PRO-RATA INTEREST-HEDGE ALLOCATION (review finding 7) ============

    /// @dev Etch + fund the Aerodrome-v2 router the AERO->USDC harvest leg hardcodes.
    function _armAeroRouter() internal {
        MockAeroV2Router impl = new MockAeroV2Router(address(aero), address(usdc), 1e6);
        vm.etch(AERO_V2_ROUTER, address(impl).code);
        usdc.mint(AERO_V2_ROUTER, 100_000_000e6);
    }

    /// @dev Make `usdcWorth` (6dp) of harvest proceeds claimable at the fixture's $1/AERO mark.
    function _armHarvest(uint256 usdcWorth) internal {
        uint256 aeroAmt = usdcWorth * 1e12;
        aero.mint(address(gauge), aeroAmt);
        gauge.setAeroToPayOnGetReward(aeroAmt);
        gauge.setEarnedAmount(aeroAmt);
    }

    /// @dev THE DRIFT MEASURE the production code uses, per leg: live debt minus the hedged principal.
    function _driftLegA() internal view returns (uint256) {
        (uint128 h,) = strategy.hedgedDebt();
        uint256 d = mLegA.borrowBalance(address(strategy));
        return d > h ? d - h : 0;
    }

    function _driftLegB() internal view returns (uint256) {
        (, uint128 h) = strategy.hedgedDebt();
        uint256 d = mLegB.borrowBalance(address(strategy));
        return d > h ? d - h : 0;
    }

    /**
     * @dev THE FINDING. The harvest budget is ONE ceiling over TWO independent drifts. It used to be
     *      handed to leg A whole, with leg B getting `budget - spentA` — and the spend path returned on
     *      `budget == 0` BEFORE reading its market, so whenever leg A's drift priced at or above the
     *      harvest (the normal state for the larger/faster leg on a thin harvest) leg B was never even
     *      MEASURED. Every harvest in that band closed leg A and left leg B's short untouched, so a
     *      partial hedge ROTATED the residual short onto one leg instead of shrinking it evenly.
     *
     *      Armed exactly in that band: leg A's drift alone costs more than the whole harvest, so the old
     *      allocation gives leg B precisely zero. Both legs must now be hedged, and by the SAME FRACTION
     *      of their own drift — which is what pro-rata means and what keeps a partial hedge leg-neutral.
     */
    function testPartialBudgetHedgesBothLegsProRataInsteadOfStarvingLegB() public {
        _armAeroRouter();
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        // ASYMMETRIC drift on purpose — leg A at 100bps of its debt, leg B at 25bps. A 4:1 cost ratio
        // makes a pro-rata split visibly different from any equal split as well as from "leg A first".
        uint256 iA = mLegA.borrowBalance(address(strategy)) / 100;
        uint256 iB = mLegB.borrowBalance(address(strategy)) / 400;
        assertGt(iA, 0, "fixture must produce a measurable leg-A accrual");
        assertGt(iB, 0, "fixture must produce a measurable leg-B accrual");
        mLegA.accrueBorrowInterest(address(strategy), iA);
        mLegB.accrueBorrowInterest(address(strategy), iB);

        uint256 costA = _valueUsdc(iA, P_LEG_A, 18);
        uint256 costB = _valueUsdc(iB, P_LEG_B, 8);
        uint256 budget = (costA + costB) / 4; // covers a quarter of the total drift...
        assertLt(budget, costA, "...and less than leg A ALONE: the band where leg B used to be starved");
        _armHarvest(budget);

        uint256 driftA0 = _driftLegA();
        uint256 driftB0 = _driftLegB();
        uint256 routerUsdc0 = usdc.balanceOf(address(router));

        vm.prank(proposer);
        strategy.compound(1, 0);

        // THE BOUND: the shared ceiling still holds, and the whole of it was put to work.
        uint256 spent = usdc.balanceOf(address(router)) - routerUsdc0;
        assertLe(spent, budget, "total spend never exceeds the harvest budget");
        assertApproxEqRel(spent, budget, 1e15, "...and no allocation dust was stranded by the division");

        // THE ASSERTION: both legs hedged, at the SAME coverage ratio.
        uint256 closedA = driftA0 - _driftLegA();
        uint256 closedB = driftB0 - _driftLegB();
        assertGt(closedB, 0, "leg B was hedged AT ALL - the finding (pre-fix this is exactly 0)");
        uint256 fracA = Math.mulDiv(closedA, 1e18, driftA0);
        uint256 fracB = Math.mulDiv(closedB, 1e18, driftB0);
        assertApproxEqRel(fracA, fracB, 1e15, "the same FRACTION of each leg's drift was closed");
        assertApproxEqRel(
            fracA, Math.mulDiv(budget, 1e18, costA + costB), 1e15, "...and that fraction is the budget's coverage"
        );

        // GRACEFUL DEGRADATION, both legs: the unfunded remainder stays measured and carries.
        assertGt(_driftLegA(), 0, "leg-A remainder carries");
        assertGt(_driftLegB(), 0, "leg-B remainder carries");
    }

    /**
     * @dev REGRESSION on the full-budget case, stated separately from
     *      `testCompoundRehedgesBorrowInterestOnBOTHLegs` because the pro-rata split is a NO-OP there and
     *      that has to stay true: each leg's spend is capped at its own cost, so an ample budget
     *      neutralises both legs exactly as before and leaves the surplus for the redeploy.
     */
    function testFullBudgetStillNeutralisesBothLegsExactlyAndLeavesTheSurplusToRedeploy() public {
        _armAeroRouter();
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        uint256 iA = mLegA.borrowBalance(address(strategy)) / 100;
        uint256 iB = mLegB.borrowBalance(address(strategy)) / 400;
        mLegA.accrueBorrowInterest(address(strategy), iA);
        mLegB.accrueBorrowInterest(address(strategy), iB);

        uint256 total = _valueUsdc(iA, P_LEG_A, 18) + _valueUsdc(iB, P_LEG_B, 8);
        uint256 budget = total * 5; // 5x the whole drift
        _armHarvest(budget);

        uint256 driftA0 = _driftLegA();
        uint256 driftB0 = _driftLegB();
        uint256 collateralBefore = (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18;
        uint256 routerUsdc0 = usdc.balanceOf(address(router));

        vm.prank(proposer);
        strategy.compound(1, 0);

        // >99.99% of each leg's drift closed. The residue is integer-division dust on the two-way oracle
        // conversion (the spend is floored in 6dp USDC, then the min-out re-derived from it) and is the
        // SAME dust the pre-refactor single-leg-at-a-time path left.
        assertLt(_driftLegA() * 10_000, driftA0, "leg-A drift fully neutralised (to rounding dust)");
        assertLt(_driftLegB() * 10_000, driftB0, "leg-B drift fully neutralised (to rounding dust)");
        assertApproxEqRel(
            usdc.balanceOf(address(router)) - routerUsdc0, total, 1e15, "spent ~the drift and not the budget"
        );
        assertGt(collateralBefore, 0, "sanity");
        assertGt(
            (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18,
            collateralBefore,
            "the surplus was redeployed"
        );
    }

    // ====== A SICK LEG MARKET DEGRADES ITS OWN HEDGE, NOT THE HARVEST (review finding: liveness) ======
    //
    // Measuring both legs unconditionally is what makes the pro-rata split above correct, but it turned
    // `borrowBalanceCurrent` — a STATE-CHANGING Moonwell call that reverts whenever `accrueInterest`
    // fails (a paused / arithmetically-broken market) — into a hard liveness dependency of `compound` on
    // BOTH legs. The old shape returned on a per-leg `budget == 0` BEFORE touching the market, so a
    // budget-starved leg never reached it. In the band armed below (fee + hedge consume the whole
    // harvest, so `deployIdleImpl` is skipped) the hedge measure is the ONLY touch of that leg's market
    // in the call, and one sick market would therefore have reverted the WHOLE harvest — the AERO sale,
    // the fee crystallisation and the OTHER leg's hedge included.
    //
    // `_measureLeg` now degrades that leg's drift to zero instead, marking it with
    // `HedgeLegMeasureDegraded`. Both legs are wrapped, not just leg B: the invariant is that the harvest
    // survives a hedge problem, not that leg B is special — the (b) test below is the leg-A mirror.

    /// @dev Break `market`'s accrual the way Moonwell does — `borrowBalanceCurrent` is
    ///      `require(accrueInterest() == NO_ERROR, "accrue interest failed")`, so the failure surfaces as
    ///      a plain string revert. `borrowBalanceStored` (used by `nav()`, `_assertHealthy` and this
    ///      suite's own helpers) is deliberately left working: the point is a market that cannot ACCRUE,
    ///      not a market that has vanished.
    function _breakAccrual(address market) internal {
        vm.mockCallRevert(
            market,
            abi.encodeWithSelector(MockLendingMarket.borrowBalanceCurrent.selector),
            abi.encodeWithSignature("Error(string)", "accrue interest failed")
        );
    }

    /// @dev Count the degradation markers raised from the STRATEGY's address (both the manager and the
    ///      valuation library are delegatecalled), and return the market named by the last one.
    function _degradations(Vm.Log[] memory logs) internal view returns (uint256 n, address market) {
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(strategy)
                    && logs[i].topics[0] == LeveragedAerodromeCLStrategy.HedgeLegMeasureDegraded.selector
            ) {
                n++;
                market = abi.decode(logs[i].data, (address));
            }
        }
    }

    /// @dev Arm the two-leg book with drift on BOTH legs and a harvest budget SHORT of leg A's drift
    ///      alone — the band where the whole harvest is consumed by the hedge, `deployIdleImpl` is
    ///      skipped, and the measure is consequently the only touch of either leg's market.
    /// @return driftA0 leg-A drift, `driftB0` leg-B drift, `budget` the armed harvest (6dp).
    function _armTwoLegDriftAndAThinHarvest() internal returns (uint256 driftA0, uint256 driftB0, uint256 budget) {
        _armAeroRouter();
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        uint256 iA = mLegA.borrowBalance(address(strategy)) / 100;
        uint256 iB = mLegB.borrowBalance(address(strategy)) / 100;
        mLegA.accrueBorrowInterest(address(strategy), iA);
        mLegB.accrueBorrowInterest(address(strategy), iB);

        driftA0 = _driftLegA();
        driftB0 = _driftLegB();
        assertGt(driftA0, 0, "fixture must arm a leg-A drift");
        assertGt(driftB0, 0, "fixture must arm a leg-B drift");

        // 99% of the SMALLER leg's cost: strictly below either leg's own cost, so whichever leg survives
        // takes the whole budget, spends all of it, and leaves `redeploy == 0`.
        uint256 costA = _valueUsdc(driftA0, P_LEG_A, 18);
        uint256 costB = _valueUsdc(driftB0, P_LEG_B, 8);
        budget = ((costA < costB ? costA : costB) * 99) / 100;
        _armHarvest(budget);
    }

    /**
     * @dev (a) THE REGRESSION, on the leg it bites. Leg B's market cannot accrue; the harvest must still
     *      complete in full and only leg B's hedge may be lost.
     */
    function testABrokenLegBMarketDegradesThatLegAndTheHarvestStillCompletes() public {
        (uint256 driftA0, uint256 driftB0, uint256 budget) = _armTwoLegDriftAndAThinHarvest();
        _breakAccrual(address(mLegB));

        uint256 aeroInRouter0 = aero.balanceOf(AERO_V2_ROUTER);
        uint256 usdcInSwapRouter0 = usdc.balanceOf(address(router));
        uint256 collateral0 = mUsdc.balanceOf(address(strategy));
        assertEq(strategy.layout().hwmPerShare, 0, "no crystallisation has happened on this book yet");

        vm.recordLogs();
        vm.prank(proposer);
        strategy.compound(1, 0); // pre-fix: reverts here, taking the whole harvest with it

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 1. THE DEGRADATION IS MARKED, once, naming leg B's market, from the strategy's own address.
        (uint256 marks, address named) = _degradations(logs);
        assertEq(marks, 1, "exactly one leg degraded");
        assertEq(named, address(mLegB), "...and it is leg B's market that is named");

        // 2. THE REWARD SALE HAPPENED — the AERO left the strategy and reached the v2 router.
        assertEq(aero.balanceOf(address(strategy)), 0, "the whole claim was sold");
        assertEq(aero.balanceOf(AERO_V2_ROUTER) - aeroInRouter0, budget * 1e12, "...to the AERO->USDC router");

        // 3. THE FEE CRYSTALLISATION HAPPENED and its state stuck (it precedes the hedge, so a reverting
        //    hedge would have rolled it back with everything else). No deferral marker either.
        assertGt(strategy.layout().hwmPerShare, 0, "the pre-compound crystallise ran and persisted");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.FeeCrystallizeDeferred.selector,
                "the crystallise was not deferred either"
            );
        }

        // 4. LEG A'S HEDGE HAPPENED, and took the WHOLE budget: with leg B's cost degraded to 0 the
        //    pro-rata split allocates everything to the surviving leg.
        assertEq(usdc.balanceOf(address(router)) - usdcInSwapRouter0, budget, "the whole budget bought leg A");
        assertApproxEqRel(driftA0 - _driftLegA(), (driftA0 * 99) / 100, 1e15, "leg A hedged by ~the budget's coverage");

        // 5. LEG B PAID FOR ITS OWN BROKEN MARKET, AND ONLY THAT: its drift is untouched and carries
        //    whole to the next harvest, exactly as an unfunded remainder does.
        assertEq(_driftLegB(), driftB0, "leg B's drift carries in full");

        // 6. ...and this really WAS the only touch of leg B's market: the hedge consumed the whole
        //    harvest, so `deployIdleImpl` never ran. Nothing else in the call could have covered it.
        assertEq(mUsdc.balanceOf(address(strategy)), collateral0, "redeploy skipped (redeploy == 0)");
    }

    /**
     * @dev (b) THE SYMMETRY, and the reason the fail-open is not leg-B-only. Nothing about the argument
     *      is specific to leg B — it is "the harvest survives a hedge problem", and leg A's market can be
     *      paused just as leg B's can. Same book, same budget, the OTHER market broken: the harvest still
     *      completes and leg B is now the one hedged with the whole budget.
     */
    function testABrokenLegAMarketDegradesThatLegInstead() public {
        (uint256 driftA0, uint256 driftB0, uint256 budget) = _armTwoLegDriftAndAThinHarvest();
        _breakAccrual(address(mLegA));

        uint256 usdcInSwapRouter0 = usdc.balanceOf(address(router));

        vm.recordLogs();
        vm.prank(proposer);
        strategy.compound(1, 0);

        (uint256 marks, address named) = _degradations(vm.getRecordedLogs());
        assertEq(marks, 1, "exactly one leg degraded");
        assertEq(named, address(mLegA), "...and it is leg A's market that is named");

        assertEq(usdc.balanceOf(address(router)) - usdcInSwapRouter0, budget, "the whole budget bought leg B");
        assertApproxEqRel(driftB0 - _driftLegB(), (driftB0 * 99) / 100, 1e15, "leg B hedged by ~the budget's coverage");
        assertEq(_driftLegA(), driftA0, "leg A's drift carries in full");
    }

    /**
     * @dev (c) THE MARKER IS NOT FREE-RUNNING. A healthy two-leg harvest must emit NOTHING — an event
     *      that always fires tells a monitor nothing about a leg that has stopped being hedged.
     */
    function testAHealthyTwoLegHarvestMarksNoDegradation() public {
        _armTwoLegDriftAndAThinHarvest();

        vm.recordLogs();
        vm.prank(proposer);
        strategy.compound(1, 0);

        (uint256 marks,) = _degradations(vm.getRecordedLogs());
        assertEq(marks, 0, "a healthy harvest degrades nothing");
    }

    // ============ THE EMPTY BOOK: DORMANCY AND THE HWM ACROSS A supply == 0 CYCLE (F03) ============
    //
    // `_crystallizeFees` used to `return` outright on `totalSupply() == 0`, writing NEITHER the fee
    // clock nor the HWM. Both omissions bill the reopening depositor for a cycle they were not in.
    // The two tests below pin the two writes independently.
    //
    // FIXTURE NOTE: this suite runs with `managementFeeBps == performanceFeeBps == 0` (see `_params`),
    // so neither leg can be observed as MINTED SHARES here. That does not weaken the assertions — the
    // fee clock and the HWM are written unconditionally by `_crystallizeFees`, regardless of the rates,
    // and they are precisely the state a later non-zero rate would bill against. The assertions are on
    // that state directly, which is also what makes them exact rather than approximate.

    /**
     * @dev THE CLOCK. Drain the book to zero shares, let a YEAR pass, and reopen it. The reopening
     *      deposit's own crystallise must move `lastFeeAccrualTimestamp` to now, so the dormancy is
     *      simply not part of any `dt`. Leaving it frozen at the draining redeem hands the next
     *      crystallise a 365-day window on a fund that held nothing for all of it — a management fee
     *      the reopening depositor pays in full and earned none of.
     */
    function testDormancyIsNotBilledToTheReopeningDepositor() public {
        _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        // Drain: the last redeem burns every share and pays the whole pot out.
        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        strategy.redeem(supply, 0);
        vm.stopPrank();
        assertEq(vault.totalSupply(), 0, "precondition: the book is empty");
        uint256 clockAtDrain = strategy.layout().lastFeeAccrualTimestamp;
        assertEq(clockAtDrain, block.timestamp, "precondition: the draining redeem left the clock at now");

        // ── A YEAR OF DORMANCY. Nobody holds a share; nothing is being managed. ──
        vm.warp(block.timestamp + 365 days);
        _deposit(100_000e6);

        assertEq(
            strategy.layout().lastFeeAccrualTimestamp,
            block.timestamp,
            "the empty-book crystallise advanced the clock past the dormancy"
        );
        assertEq(block.timestamp - clockAtDrain, 365 days, "...and the window skipped really was a full year");
    }

    /**
     * @dev THE HWM. A mark taken against the OLD supply is incommensurable with the basis the reopening
     *      deposit sets: a drained book reopens at `WAD / SHARES_VIRTUAL_OFFSET` (1e12) whatever the dead
     *      cycle traded at. Carrying the dead cycle's peak forward would hand the reopened fund a
     *      fee-free run back up to it. The empty-book branch zeroes the mark, so the next crystallise
     *      re-seeds at the reopened fund's OWN level via the `hwmPerShareX == 0` first-cycle branch.
     */
    function testTheHwmResetsAcrossASupplyZeroCycle() public {
        _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        // Two crystallisation points are needed to MARK the HWM: the first only seeds the clock
        // (`lastFeeAccrualTimestamp == 0` short-circuits ahead of the library), the second marks.
        // A gain lands between them so the mark sits strictly above the unit-rate basis.
        _deposit(1_000e6);
        usdc.mint(address(strategy), 500_000e6); // raw idle is in `nav()` — a 50% gain on the book
        _deposit(1_000e6);
        uint256 hwmHigh = strategy.layout().hwmPerShare;
        assertGt(hwmHigh, 1e12, "precondition: the dead cycle's peak is ABOVE the reopening basis");

        // Drain every share, including the two deposits' (both minted to `lp`).
        uint256 all = vault.totalSupply();
        vm.startPrank(lp);
        vault.approve(address(strategy), all);
        strategy.redeem(all, 0);
        vm.stopPrank();
        assertEq(vault.totalSupply(), 0, "precondition: the book is empty");

        // ── REOPEN. `navNet == 0` and `supply == 0`, so the depositor mints at
        //    `assets x SHARES_VIRTUAL_OFFSET` — a per-share level of exactly 1e12. ──
        _deposit(100_000e6);
        assertEq(strategy.layout().hwmPerShare, 0, "the dead cycle's mark did not survive the empty book");

        // The next crystallise re-seeds at the REOPENED fund's basis, charging nothing (first cycle).
        _deposit(1_000e6);
        assertEq(strategy.layout().hwmPerShare, 1e12, "re-seeded at the new basis, not the dead cycle's peak");
    }
}
