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

    /// @dev Mirrored from the strategy for `vm.expectEmit`.
    event RedeemRequested(uint256 indexed id, address indexed owner, address indexed recipient, uint256 shares);
    event RedeemFulfilled(uint256 indexed id, address indexed owner, address indexed recipient, uint256 assetsOut);

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
    ///      `raw = (P_LEG_B / P_LEG_A) x 10^(18-8) = 3.333e11`, so `ln(raw)/ln(1.0001) ~ 265_337`; `TICK` is ~97x off.
    int24 internal constant TICK_ORACLE_CONSISTENT = 265_300;

    /// @dev Aerodrome v2 PoolFactory, hardcoded in `LeveragedAeroValuation`; etched below (no code otherwise).
    address internal constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @dev `applyVenue` pins the canonical Slipstream CLFactory, so a fork-free test must etch the registry HERE.
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
        // Venue validation probes a HARDCODED v2 factory for the AERO/USDC route; etch code there.
        vm.etch(AERO_V2_FACTORY, address(new MockAeroV2Factory(address(aero), address(usdc), address(0xA2F))).code);
        comptroller = new MockComptroller();
        mUsdc = new MockLendingMarket(address(usdc));
        mLegB = new MockLendingMarket(address(legB));
        mLegA = new MockLendingMarket(address(legA));
        npm = new MockNpm(pool);
        // Real ERC-721 custody: a staked position is OWNED by the gauge, so a missing unstake reverts here.
        gauge.setNpm(address(npm));
        router = new MockClSwapRouter();

        sequencerFeed = new MockChainlinkFeed(0, 8, 1, block.timestamp - 2 hours);
        usdcFeed = new MockChainlinkFeed(int256(P_USDC), 8, 1, block.timestamp);
        legBFeed = new MockChainlinkFeed(int256(P_LEG_B), 8, 1, block.timestamp);
        legAFeed = new MockChainlinkFeed(int256(P_LEG_A), 8, 1, block.timestamp);
        aeroFeed = new MockChainlinkFeed(1e8, 8, 1, block.timestamp);

        // The comptroller prices at its OWN oracle -- raw answers, no staleness gate -- which is the asymmetry the
        // degraded `withdrawIdle` bound leans on.
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
        // `cloneAndBind` is the only init path: `BaseStrategy.initialize` requires `msg.sender == vault_`.
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

    /// @dev The admin sets POLICY with `setTargetLtv`; the proposer then moves the book with `adjustLeverage`.
    function _retarget(uint16 target) internal {
        vm.prank(owner);
        strategy.setTargetLtv(target);
        _adjustToPolicy();
    }

    /// @dev `adjustLeverage` at the STANDING target. The read is hoisted ABOVE the prank on purpose: it is an
    ///      external call, so leaving it in the argument list would consume the `vm.prank` meant for the op.
    function _adjustToPolicy() internal {
        uint16 policy = strategy.targetLtvBps();
        vm.prank(proposer);
        strategy.adjustLeverage(policy, 0, 0);
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

    /// @dev REGRESSION -- a lever-down to zero debt must be REJECTED: `_leverDown` neither clears `$.tokenId` nor
    ///      re-mints after its 100% unwind, orphaning the NFT and bricking every later `gauge.withdraw`.
    function testAdjustLeverageToZeroIsRejected() public {
        _execute(SEED);
        uint256 tokenIdBefore = strategy.layout().tokenId;

        // A zero target is rejected at `setTargetLtv`, one barrier before the manager's full-unwind guard.
        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvZero.selector);
        strategy.setTargetLtv(0);

        assertEq(strategy.layout().tokenId, tokenIdBefore, "position untouched");
        assertTrue(gauge.stakedContains(address(strategy), tokenIdBefore), "NFT still staked");
        assertGt(mLegB.borrowBalance(address(strategy)), 0, "leg B debt untouched");
        assertGt(mLegA.borrowBalance(address(strategy)), 0, "leg A debt untouched");
    }

    /// @dev The guard is on the DEBT delta: a dust target whose `targetDebt` floors to 0 is rejected identically.
    function testAdjustLeverageToADustTargetThatFloorsToZeroDebtIsRejected() public {
        _execute(SEED);
        // `targetDebt = targetLtvBps * collateral / 10000` floors to 0 once collateral < 10000; shrink the basis.
        mUsdc.setExchangeRateStored(1);

        vm.prank(owner);
        strategy.setTargetLtv(1); // non-zero, so it clears `TargetLtvZero` and reaches the manager
        uint16 policy = strategy.targetLtvBps();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroManager.FullUnwindNotSupported.selector);
        strategy.adjustLeverage(policy, 0, 0);
    }

    /// @dev An ordinary partial lever-down leaves liquidity, so the re-stake fires and the position stays staked.
    function testPartialLeverDownKeepsThePositionStaked() public {
        _execute(SEED);
        uint256 tokenId = strategy.layout().tokenId;

        _retarget(3000);

        assertEq(strategy.layout().tokenId, tokenId, "same position");
        assertTrue(gauge.stakedContains(address(strategy), tokenId), "re-staked after a partial unwind");
        assertGt(mLegB.borrowBalance(address(strategy)), 0, "debt reduced, not cleared");
    }

    // ==================== TARGET-LTV PERSISTENCE (two-borrowed-legs) ====================

    /// @dev The standing target lives in the ADMIN's `setTargetLtv` and is SHAPE-INDEPENDENT; `adjustLeverage`
    ///      CONSUMES it rather than writing it.
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
        _adjustToPolicy();
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

    /// @dev The KEEPER-ONLY de-risk, asserted on the BOOK: the pre-`fulfillRedeem` lever-down needs no multisig,
    ///      because the 2-day `FULFILL_WINDOW` must not depend on a signature — and it does NOT touch policy.
    function testProposerAdjustLeverageBelowPolicyDeleversTheBookWithoutMovingTheTarget() public {
        _execute(SEED);
        uint256 debtBAtInit = mLegB.borrowBalance(address(strategy));

        vm.prank(proposer);
        strategy.adjustLeverage(4000, 0, 0);
        assertLt(mLegB.borrowBalance(address(strategy)), debtBAtInit, "lever DOWN ran off the per-call target");
        assertEq(strategy.targetLtvBps(), 5000, "the per-call target is NOT policy: the standing target stands");

        uint256 collateral = mUsdc.balanceOf(address(strategy));
        uint256 debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, 4000, 20, "the book landed on the KEEPER's target");

        // AND THE DE-LEVER IS REVERSIBLE BY THE SAME KEY: passing the untouched standing target back re-levers
        // the book to policy, which is what keeps the multisig off the post-fulfil path as well as the pre one.
        _adjustToPolicy();
        assertApproxEqAbs(
            (
                (
                    _valueUsdc(mLegB.borrowBalance(address(strategy)), P_LEG_B, 8)
                        + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18)
                ) * 10_000
            ) / mUsdc.balanceOf(address(strategy)),
            uint256(TARGET_LTV_BPS),
            20,
            "restored to the standing target with no admin signature"
        );
    }

    /// @dev THE BOUND: the per-call target may reach policy but never pass it, so the `onlyProposer` key cannot
    ///      raise fund risk. One bps over the standing target is refused and the book is untouched.
    function testAdjustLeverageAbovePolicyReverts() public {
        _execute(SEED);
        uint256 debtBBefore = mLegB.borrowBalance(address(strategy));

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                LeveragedAerodromeCLStrategy.TargetLtvExceedsPolicy.selector, TARGET_LTV_BPS + 1, TARGET_LTV_BPS
            )
        );
        strategy.adjustLeverage(TARGET_LTV_BPS + 1, 0, 0);

        assertEq(mLegB.borrowBalance(address(strategy)), debtBBefore, "a refused target moves no debt");
        assertEq(strategy.targetLtvBps(), TARGET_LTV_BPS, "and stores nothing");
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
        // Deliberately NOT asserting the getter: this must fail on the OBSERVABLE BORROW, i.e. the sizing.

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

    /// @dev An out-of-band target is refused at the ADMIN entrypoint and stores nothing.
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

    /// @dev THE RATCHET-DOWN, on a live levered book: the ceiling drops under the book's own LTV, ops that
    ///      end in `_assertHealthy` fail until a lever-DOWN — which is not blocked — brings it back inside.
    function testLoweringMaxLtvBlocksDebtAddingOpsUntilTheBookDeLevers() public {
        _execute(SEED);
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "the book opens on the init target");

        // Policy first (the band is checked from both sides), then the ceiling, through the live 5000 LTV.
        vm.startPrank(owner);
        strategy.setTargetLtv(4000);
        strategy.setMaxLtv(4500);
        vm.stopPrank();
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "lowering the ceiling moved no debt");

        // A 100k tranche at the new 4000 target still blends to ~4909 bps, above the fresh 4500 ceiling.
        uint256 topUp = 100_000e6;
        usdc.mint(address(strategy), topUp);
        vm.prank(proposer);
        vm.expectPartialRevert(LeveragedAerodromeCLStrategy.UnhealthyPosition.selector);
        strategy.deployIdle(topUp, 0);
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "the refused op rolled back whole");

        // The way out: a lever-DOWN, bounded by the stored POLICY target, ending under the new ceiling.
        vm.prank(proposer);
        strategy.adjustLeverage(4000, 0, 0);
        assertApproxEqAbs(_ltvBps(), 4000, 2, "the keeper de-levered to the new policy with no admin signature");

        vm.prank(proposer);
        strategy.deployIdle(topUp, 0);
        assertApproxEqAbs(_ltvBps(), 4000, 2, "the redeployed book sits on the new target, under the ceiling");
    }

    /// @dev `compound` is the OTHER debt-adding op the ceiling gates: its redeployed harvest borrows at the
    ///      target, and the blended book is still over the fresh ceiling, so the same post-op gate fires.
    function testLoweringMaxLtvAlsoBlocksCompoundUntilTheBookDeLevers() public {
        _execute(SEED);

        vm.startPrank(owner);
        strategy.setTargetLtv(4000);
        strategy.setMaxLtv(4500);
        vm.stopPrank();

        _armAeroRouter();
        _armHarvest(40_000e6);

        vm.prank(proposer);
        vm.expectPartialRevert(LeveragedAerodromeCLStrategy.UnhealthyPosition.selector);
        strategy.compound(1, 0);
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "the refused harvest rolled back whole");

        vm.prank(proposer);
        strategy.adjustLeverage(4000, 0, 0);
        vm.prank(proposer);
        strategy.compound(1, 0); // inside the band the same harvest lands
        assertLe(_ltvBps(), 4500, "the compounded book sits under the ceiling");
    }

    /// @dev The FAST-REDEEM gate reads `$.maxLtvBps` LIVE: the same draw flips from allowed to refused when
    ///      the admin lowers the ceiling under it, and back when the ceiling is raised again. An init-cached
    ///      copy would give the same answer all three times.
    function testLoweringMaxLtvTightensTheFastRedeemGateImmediately() public {
        _execute(SEED);
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        vm.prank(lp);
        vault.approve(address(strategy), supply);
        uint256 shares = supply / 10; // a draw that lands the post-redeem LTV around 5263 bps

        uint256 snapA = vm.snapshotState();
        vm.prank(lp);
        strategy.redeem(shares, 0); // ceiling 6500: the fast path is open
        vm.revertToState(snapA);

        vm.prank(owner);
        strategy.setMaxLtv(5100); // still above the book's live 5000, below the POST-draw LTV
        uint256 snapB = vm.snapshotState();
        vm.prank(lp);
        vm.expectPartialRevert(LeveragedAeroVenue.FastRedeemExceedsLtv.selector);
        strategy.redeem(shares, 0);

        // ...and the documented fallback is open: the same shares still queue.
        vm.prank(lp);
        strategy.requestRedeem(shares, 0, address(0)); // recipient 0 == the redeemer
        vm.revertToState(snapB);

        vm.prank(owner);
        strategy.setMaxLtv(5500); // back above the post-draw LTV
        vm.prank(lp);
        strategy.redeem(shares, 0);
    }

    /// @dev The keeper's three closed doors after a ratchet-down: re-lever, raise policy, raise the ceiling.
    function testLoweredMaxLtvKeepsTheKeeperFromLeveringBackUp() public {
        _execute(SEED);

        vm.startPrank(owner);
        strategy.setTargetLtv(3000);
        strategy.setMaxLtv(3500);
        vm.stopPrank();

        // Down to the new policy first, so only the re-lever is under test.
        vm.prank(proposer);
        strategy.adjustLeverage(3000, 0, 0);
        assertApproxEqAbs(_ltvBps(), 3000, 2, "de-levered");

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                LeveragedAerodromeCLStrategy.TargetLtvExceedsPolicy.selector, uint16(5000), uint16(3000)
            )
        );
        strategy.adjustLeverage(5000, 0, 0);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        strategy.setTargetLtv(5000);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        strategy.setMaxLtv(6500);

        assertEq(strategy.layout().maxLtvBps, 3500, "the ceiling the admin set is the ceiling that stands");
    }

    // ==================== RERANGE SKEW (two borrowed legs) ====================

    /// @dev A tightened band binds the proposer's `rerange` immediately, at both ends.
    function testSetWidthBoundsTightensWhatTheProposerMayRerangeTo() public {
        _execute(SEED);

        vm.prank(owner);
        strategy.setWidthBounds(2000, 6000);

        // 1000 was legal under the init band [200, 20000]; it is not under [2000, 6000].
        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroValuation.OutOfBounds.selector);
        strategy.rerange(1000, SKEW_CENTERED, 0, 0);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroValuation.OutOfBounds.selector);
        strategy.rerange(8000, SKEW_CENTERED, 0, 0);

        assertEq(strategy.layout().width, WIDTH, "a refused rerange stored no width");

        vm.prank(proposer);
        strategy.rerange(6000, SKEW_CENTERED, 0, 0);
        assertEq(strategy.layout().width, 6000, "the band's own ceiling is reachable");
        assertGt(npm.liquidityOf(strategy.layout().tokenId), 0, "and it minted a real position");
    }

    /// @dev THE CONTAINMENT RULE on a live book: gated until the proposer reranges into the target width.
    function testSetWidthBoundsRefusesToStrandTheStoredWidthUntilARerange() public {
        _execute(SEED);
        assertEq(strategy.layout().width, WIDTH, "stored width is 4000");

        vm.prank(owner);
        vm.expectRevert(LeveragedAeroValuation.OutOfBounds.selector);
        strategy.setWidthBounds(5000, 8000); // would exclude the live 4000
        assertEq(strategy.layout().minWidth, 200, "the refused band stored nothing");

        // Still legal under the OLD band — which is why the ordering works and this is not a deadlock.
        vm.prank(proposer);
        strategy.rerange(6000, SKEW_CENTERED, 0, 0);

        vm.prank(owner);
        strategy.setWidthBounds(5000, 8000);
        assertEq(strategy.layout().minWidth, 5000, "the same band change now lands");
        assertEq(strategy.layout().maxWidth, 8000, "...both ends");
    }

    /// @dev The re-range mints at the SKEWED range, not the centred one, and persists BOTH knobs.
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
        assertLe(expLower, pool.tick(), "skewed range still brackets spot");
        assertGt(expUpper, pool.tick(), "skewed range still brackets spot");
    }

    /// @dev THE KNOWN UTILISATION COST OF SKEWING. A re-range does NOT swap -- it re-adds the two collected legs of
    ///      a range-BLIND 50/50-by-USD borrow -- so moving off that mix strands more of one leg. Directional, and a
    ///      utilisation cost only: `nav()` prices the remainder.
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
        assertApproxEqRel(centeredNav, navBefore, 1e16, "NAV indifferent (centred)");
        assertApproxEqRel(downSkewNav, navBefore, 1e16, "NAV indifferent (down-skew)");
        assertApproxEqRel(upSkewNav, navBefore, 1e16, "NAV indifferent (up-skew)");
    }

    /// @dev Re-range at `skewBps_`, measure the idle leg remainder and NAV, then roll the whole book back.
    function _remainderAfterRerange(uint16 skewBps_) internal returns (uint256 remainder, uint256 nav_) {
        uint256 snap = vm.snapshotState();
        vm.prank(proposer);
        strategy.rerange(WIDTH, skewBps_, 0, 0);
        remainder = _idleLegValueUsdc();
        nav_ = strategy.nav();
        vm.revertToState(snap);
    }

    /// @dev A re-range on a FLAT book is a venue no-op, but `width` AND `skewBps` must still land for the next
    ///      mint: the persists sit in the strategy frame AHEAD of `rerangeImpl`'s `tokenId == 0` bail-out.
    function testRerangeOnFlatBookPersistsSkew() public {
        _execute(SEED);

        // Redeem the whole book: `tokenId` goes to 0 while the strategy stays Executed.
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        vm.prank(lp);
        vault.approve(address(strategy), supply);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(supply, 0, address(0));
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

    /// @dev The calm-gate fires FIRST on the skewed path, and the atomic rollback leaves the STORED knobs alone.
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

    /// @dev F06, the OTHER one-sided branch. Below its band a CL position holds token0 only (leg B here), so the
    ///      reopen must place the band STRICTLY ABOVE spot; pre-fix the straddling band minted zero liquidity.
    function testRerangeReopensAboveSpotWhenPriceHasFallenOutOfTheBand() public {
        _execute(SEED);
        uint256 oldTokenId = strategy.layout().tokenId;
        uint256 stakedBefore = gauge.depositCallCount();

        // Clear the genesis idle remainder: a book holding both legs is two-sided and takes the recentre branch.
        vm.startPrank(address(strategy));
        legB.transfer(address(0xdead), legB.balanceOf(address(strategy)));
        legA.transfer(address(0xdead), legA.balanceOf(address(strategy)));
        vm.stopPrank();

        int24 farTick = strategy.layout().posTickLower - 5000;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(farTick));
        pool.setTick(farTick);
        // FIXTURE: `MockNpm` custodies only what it was minted, so float what a post-move `collect` owes.
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

    /// @dev USDC face value of the borrowed-leg balances left idle -- the utilisation drag the skew test compares.
    function _idleLegValueUsdc() internal view returns (uint256) {
        return _valueUsdc(legB.balanceOf(address(strategy)), P_LEG_B, 8)
            + _valueUsdc(legA.balanceOf(address(strategy)), P_LEG_A, 18);
    }

    // ==================== LEVER-DOWN COVER IS NEED-SIZED ====================

    /// @dev THE IDLE REMAINDER A LEVER-DOWN MUST NOT LIQUIDATE. `_rebalanceCover` sells the surplus leg to buy the
    ///      deficit, but an idle remainder is matched 1:1 by that leg's debt and so DELTA-NEUTRAL: selling it makes an
    ///      unrecorded short nothing downstream surfaces. Hence need-sized.
    function testLeverDownCoverSellsOnlyWhatTheShortfallNeedsAndKeepsTheRest() public {
        // Genesis on the oracle-consistent mark: on the default `TICK` the range-blind borrow already strands ~49%
        // of one leg and that buffer absorbs the shortfall.
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK_ORACLE_CONSISTENT));
        pool.setTick(TICK_ORACLE_CONSISTENT);

        _execute(SEED);

        // A pre-existing idle leg-A remainder ~$150k: an order of magnitude above the shortfall opened below.
        uint256 remainder = 50e18;
        legA.mint(address(strategy), remainder);
        uint256 remainderValue = _valueUsdc(remainder, P_LEG_A, 18);

        // Move the pool up (spot AND TWAP) with leg B's oracle + swap rates: leg B is token0, so the LP holds LESS
        // leg B than its debt and the repay shorts it, covering out of leg A.
        int24 newTick = TICK_ORACLE_CONSISTENT + 600;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(newTick));
        pool.setTick(newTick);
        pool.setTwapTick(newTick);
        uint256 newPB = (P_LEG_B * 1_061_837) / 1_000_000; // 1.0001^600
        legBFeed.setAnswer(int256(newPB));
        router.setRate(address(legB), address(usdc), (newPB * 1e18) / (100 * 1e8));
        router.setRate(address(usdc), address(legB), (100 * 1e8 * 1e18) / newPB);
        // FIXTURE ONLY: float `MockNpm` for what a post-move `collect` owes but was never minted.
        legB.mint(address(npm), 100e8);
        legA.mint(address(npm), 100e18);

        uint256 debtBBefore = mLegB.borrowBalance(address(strategy));

        _retarget(3000); // lever DOWN — repays f of both debts

        assertGt(
            legA.balanceOf(address(strategy)),
            remainder / 2,
            "the delta-neutral leg-A remainder was not liquidated wholesale to cover the leg-B shortfall"
        );
        assertLt(
            usdc.balanceOf(address(strategy)),
            remainderValue / 10,
            "the cover raised roughly what it spent -- the sell was need-sized, not wholesale"
        );
        assertLt(mLegB.borrowBalance(address(strategy)), debtBBefore, "the leg-B debt really was repaid");
        uint256 collateral = (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18;
        uint256 debtUsdc = _valueUsdc(mLegB.borrowBalance(address(strategy)), newPB, 8)
            + _valueUsdc(mLegA.borrowBalance(address(strategy)), P_LEG_A, 18);
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, 3000, 20, "LTV landed on the new target");
    }

    // ==================== THE GENESIS DRAG A SKEWED RANGE CANNOT AVOID ====================

    /// @dev THE ALWAYS-ADVERSE HALF of the skew's cost, which the re-range test cannot show. A DEPLOY borrows 50/50
    ///      BY USD, range-BLIND, while the range wants `w1 = (sqrtP - sqrtPa) / [(sqrtP - sqrtPa) + sqrtP(1 -
    ///      sqrtP/sqrtPb)]` in token1, so `stranded = 0.5 - 0.5 * min(w0,w1)/max(w0,w1)` -- and mirror skews match.
    function testDeployAtASkewedRangeStrandsTheSamePredictedFractionEitherWay() public {
        // The pool must be on the SAME mark as the two feeds BEFORE genesis: a mismatch would show as drag at every
        // skew, centred included, and drown the effect under test.
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK_ORACLE_CONSISTENT));
        pool.setTick(TICK_ORACLE_CONSISTENT);

        _execute(SEED);

        (uint256 downStranded, uint256 downPredicted) = _strandedFractionAfterRerangeAndDeploy(8000);
        (uint256 upStranded, uint256 upPredicted) = _strandedFractionAfterRerangeAndDeploy(2000);
        (uint256 centeredStranded,) = _strandedFractionAfterRerangeAndDeploy(SKEW_CENTERED);

        assertApproxEqRel(downStranded, downPredicted, 2e16, "down-skew: measured drag == the closed form");
        assertApproxEqRel(upStranded, upPredicted, 2e16, "up-skew: measured drag == the closed form");
        // DIRECTION-INDEPENDENCE (measured 3669 vs 3678 bps; the 0.25% residual is grid alignment).
        assertApproxEqRel(downStranded, upStranded, 1e16, "skew 8000 and skew 2000 strand the SAME fraction");
        assertGt(upStranded, 3000, "the up-skew is adverse too -- there is no free direction at deploy");
        assertGt(downStranded, 3000, "a skewed deploy strands >30% of the borrow (range-blind 50/50)");
        assertLt(centeredStranded, 100, "...where the centred range strands ~nothing");
    }

    /// @dev Re-range to `skewBps_`, deploy a top-up into that STORED range, and return `(measured, predicted)`
    ///      stranded fractions of its borrow in bps. Rolls the book back.
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

        // `topUp x targetLtv` is borrowed 50/50 by USD; whatever the mint could not take is the new idle value.
        uint256 borrowed = (topUp * uint256(TARGET_LTV_BPS)) / 10_000;
        measuredBps = ((_idleLegValueUsdc() - idleBefore) * 10_000) / borrowed;
        vm.revertToState(snap);
    }

    /// @dev `0.5 - 0.5 * min(w0,w1)/max(w0,w1)` in bps, with `w0`/`w1` the VALUE shares the range demands at the
    ///      current `sqrtP`, from a reference-liquidity probe -- a genuinely independent prediction.
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

    /// @dev DEPOSIT IS UNTOUCHED: money-in has no Moonwell dependency, so a paused / capped market cannot refuse it.
    function testDepositLeavesTheUsdcRawAndTouchesNoMoonwellMarket() public {
        _execute(SEED);
        uint256 collateralBefore = _collateralUsdc();
        mUsdc.setSupplyErrors(4, 0); // a market that would refuse every mint

        uint256 top = 250_000e6;
        _deposit(top); // must not revert

        assertEq(usdc.balanceOf(address(strategy)), top, "the deposit is held as RAW USDC");
        assertEq(_collateralUsdc(), collateralBefore, "deposit supplied nothing to Moonwell");
    }

    /// @dev `supplyIdle` is value-neutral: `nav()` counts idle at FACE and collateral at `exchangeRateStored`, and
    ///      the mint hands back `amount/rate` cTokens worth `amount` again.
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

    /// @dev The same at a non-unit exchange rate -- where idle-at-face vs collateral-at-rate could diverge.
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

    /// @dev PARTIAL BY DESIGN: the un-supplied slice keeps the redeemer's ORACLE-FREE Phase-1 IL cover reachable.
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

    /// @dev Supplied-but-unlevered USDC is LEVERAGEABLE -- there is no buffer/book distinction in `Layout` -- so
    ///      `adjustLeverage` ALONE levers a freshly-parked balance to `targetLtvBps`, with no `deployIdle`.
    function testSupplyIdleThenAdjustLeverageLeversTheNewCollateralToTarget() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);

        assertApproxEqAbs(_ltvBps(), (uint256(TARGET_LTV_BPS) * SEED) / (SEED + top), 2, "LTV dipped on the supply");

        _adjustToPolicy(); // the STANDING target — no policy change, no deployIdle

        assertEq(_collateralUsdc(), SEED + top, "collateral is the whole book, the parked slice included");
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "adjustLeverage alone levered the new collateral");
    }

    /// @dev Over-asking is a typed refusal against the RAW balance, which is exactly `supplyIdle`'s budget.
    function testSupplyIdleRevertsInsufficientIdleAboveTheRawBalance() public {
        _execute(SEED);
        _deposit(100_000e6);
        uint256 raw = usdc.balanceOf(address(strategy));
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.supplyIdle(raw + 1);
    }

    /// @dev PROPOSER-ONLY, like every other venue op: the admin holds POLICY, not operations.
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

    /// @dev FAIL-CLOSED on the supply: a market that refuses to mint reverts with its own code and moves nothing --
    ///      a keeper retry, which is why this call is not on the deposit path.
    function testSupplyIdleRevertsMoonwellMintFailedWhenTheMarketRefuses() public {
        _execute(SEED);
        _deposit(100_000e6);
        mUsdc.setSupplyErrors(4, 0); // MARKET_NOT_FRESH-shaped code

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(LeveragedAerodromeCLStrategy.MoonwellMintFailed.selector, uint256(4)));
        strategy.supplyIdle(100_000e6);
    }

    /// @dev `deployIdle` also works from mUSDC: the `InsufficientIdle` bound measures raw + collateral and
    ///      `_materialiseUsdc` redeems the shortfall before `_supplyAndBorrow` puts it back.
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

    /// @dev The bound still binds, on the right basis: one unit above raw + collateral is `InsufficientIdle`.
    function testDeployIdleStillRevertsAboveRawPlusCollateral() public {
        _execute(SEED);
        uint256 available = usdc.balanceOf(address(strategy)) + _collateralUsdc();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.deployIdle(available + 1, 0);
    }

    /// @dev `redeploy` re-enters a FLAT book parked entirely in mUSDC: `executeImpl` reads `_usdcAvailable()`,
    ///      where the raw-balance read would have refused `ExecuteZeroBalance`.
    function testRedeployReEntersAFlatBookHeldEntirelyAsCollateral() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();

        vm.prank(proposer);
        strategy.redeploy(0);
        assertGt(strategy.layout().tokenId, 0, "redeploy re-entered from collateral alone");
        assertEq(_collateralUsdc(), pot, "the whole pot is back as collateral after the round trip");
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "and landed on target");
    }

    /// @dev Reach a FLAT book whose entire pot sits in mUSDC and NOTHING is raw.
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

    /// @dev A failing `redeemUnderlying` surfaces as the typed `MoonwellRedeemFailed` on the paths that can NOW
    ///      reach one -- `deployIdle` materialises raw USDC on demand.
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

    /// @dev THE RATCHET IS CLOSED. `deployIdle`'s basis is raw + UN-LEVERED collateral: off levered collateral the
    ///      op is redeem -> supply-back -> borrow, walking LTV to `maxLtvBps` on the `onlyProposer` key alone.
    function testDeployIdleCannotRecycleLeveredCollateral() public {
        _execute(SEED); // at target: every USDC of collateral already backs debt
        uint256 ltvBefore = _ltvBps();

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.deployIdle(20_000e6, 0);
        assertApproxEqAbs(_ltvBps(), ltvBefore, 0, "nothing moved");

        // And the same after a park-then-lever cycle: once levered, the parked slice stops being deployable.
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);
        _adjustToPolicy(); // the whole book, parked slice included, is now at target

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.deployIdle(20_000e6, 0);
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 2, "the book stayed at target");
    }

    // ==================== THE INVERSE (`withdrawIdle`) ====================

    /// @dev THE DIAL TURNS BOTH WAYS: the raw float (the oracle-free Phase-1 cover budget) is restorable without
    ///      levering or exiting the venue, and value-neutral either way.
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

    /// @dev The mirror bound: collateral backing debt at target is NOT withdrawable, since pulling it would raise
    ///      LTV above the admin-set target with no admin action.
    function testWithdrawIdleRefusesLeveredCollateral() public {
        _execute(SEED); // at target: no un-levered collateral at all
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.withdrawIdle(20_000e6);
    }

    /// @dev On a FLAT parked book there is no debt, so the WHOLE pot is withdrawable -- the recovery path.
    function testWithdrawIdleFreesTheWholeFlatParkedPot() public {
        uint256 pot = _flatBookHeldEntirelyAsCollateral();
        vm.prank(proposer);
        strategy.withdrawIdle(pot);
        assertEq(usdc.balanceOf(address(strategy)), pot, "the whole flat pot came back raw");
        assertEq(strategy.nav(), pot, "nav unchanged: same value, raw again");
    }

    /// @dev THE RESTORE DIRECTION SURVIVES AN ORACLE OUTAGE. The policy bound (`_unleveredCollateral`) is
    ///      Chainlink-priced and fail-closed, so the dial jammed in the PARK direction. Solvency never depended on
    ///      our feed -- Moonwell checks its own CF on every redeem -- so it now degrades: the event fires instead.
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

        vm.warp(block.timestamp + 2 days + 1);

        vm.expectEmit(false, false, false, false, address(strategy));
        emit LeveragedAerodromeCLStrategy.WithdrawIdleBoundDegraded();
        vm.prank(proposer);
        strategy.withdrawIdle(top);

        assertEq(usdc.balanceOf(address(strategy)), top, "the raw float was restored during the outage");
        assertEq(_collateralUsdc(), collateralBefore - top, "...and it really came out of the collateral");
    }

    /// @dev THE DEGRADED PATH STILL HOLDS THE TARGET-LTV LINE, at the venue's oracle. An earlier revision dropped
    ///      the bound entirely, leaving Moonwell's 8800bps CF (above `maxLtvBps`) as the only limit.
    function testDegradedWithdrawIdleStillHoldsTheTargetLtvLine() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, 1_000_000e12);
        uint256 top = 250_000e6;
        _deposit(top);
        vm.prank(proposer);
        strategy.supplyIdle(top);
        vm.warp(block.timestamp + 2 days + 1); // every hardened feed refuses

        // Past the venue-derived un-levered slice: refused, typed, even mid-outage.
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientIdle.selector);
        strategy.withdrawIdle(top + 20_000e6);

        // The blast radius: after the largest permitted degraded withdraw the book sits at the standing target.
        vm.prank(proposer);
        strategy.withdrawIdle(top - 10); // a few units inside the venue-oracle bound (integer slack)
        assertApproxEqAbs(_ltvBps(), uint256(TARGET_LTV_BPS), 3, "post-degrade LTV pinned at the standing target");
    }

    /// @dev If even the VENUE cannot answer (a comptroller error code), the degraded path fails closed.
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

    /// @dev MOONWELL'S OWN BELT, representable at last: the mock market consults the comptroller on the way out,
    ///      so an over-draw answers with the Compound rejection CODE, not a mock-artifact underflow.
    function testMoonwellRefusesARedeemPastTheFreeCollateralLine() public {
        _execute(SEED); // levered at target 5000 with CF 8800: ~43% of collateral is free, no more
        uint256 collateral = _collateralUsdc();
        vm.prank(address(strategy));
        uint256 err = mUsdc.redeemUnderlying((collateral * 6) / 10); // 60%: past the free line
        assertEq(err, 4, "refused with the INSUFFICIENT_LIQUIDITY-shaped code, nothing moved");
        assertEq(_collateralUsdc(), collateral, "the refusal is a code, not a partial fill");
    }

    /// @dev THE OTHER HALF: with READABLE feeds the bound still refuses through the PRIMARY read, and a healthy
    ///      in-bound withdraw emits NO marker -- so the marker cannot become free-running.
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

    /// @dev THE FAILURE MODE THE `nav()` FLAT BRANCH PREVENTS: on a fully parked flat book a raw-balance-only nav
    ///      reads 0, so the next depositor mints against zero NAV and every one after reverts `NavUnpriceable`.
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

        uint256 shares2 = _deposit(assets);
        assertGt(shares2, 0, "the second deposit still prices");
    }

    /// @dev The materialise round trip at a NON-UNIT rate with a partial raw float, so the SHORTFALL form is the
    ///      branch under test: raw is spent first and only `amount - raw` is redeemed. Pinned Moonwell-side only.
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
        // Net +top/2, with each truncating division (redeem burn, mint credit, value read) flooring once at 1.37.
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
        uint256 id = strategy.requestRedeem(shares, 0, address(0));

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

    /// @dev F15. A PARTIAL ASYNC REDEEM BURNS `f` OF THE cTOKENS, not a stored-rate underlying estimate:
    ///      `redeemUnderlying` burns at the fresh rate, leaving ~2.1% of the redeemer's accrual with the stayers.
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

    /// @dev `redeemUnwindImpl` repays `f = shares/supply` of each leg's debt and redeems `f` of the collateral,
    ///      so post-LTV cannot exceed pre-LTV. `fulfillRedeem` has NO max-LTV revert (unlike the fast path's
    ///      `FastRedeemExceedsLtv`): the property holds by mechanism, pinned here. Tolerance is one-sided.
    function testPartialFulfillRedeemNeverRaisesTheBookLtv() public {
        _execute(SEED);
        // Non-unit basis, and stored == pending so no accrual fires mid-fulfil: the delta below is the
        // unwind's own rounding, nothing else.
        mUsdc.setExchangeRateStored(1.37e18);
        mUsdc.setPendingExchangeRate(1.37e18);
        // THEN lever up near the 6500 ceiling on that basis, so a rise of a few bps would be material.
        _retarget(6000);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        uint256 ltvBefore = _ltvBps();
        assertApproxEqAbs(ltvBefore, 6000, 50, "premise: the book starts just under the 6500 ceiling");
        uint256 collateralBefore = _collateralUsdc();

        uint256 shares = SUPPLY / 4; // a PARTIAL fulfil — the only branch that can move the ratio
        uint256 id = _requestRedeem(shares);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        uint256 ltvAfter = _ltvBps();
        assertLt(_collateralUsdc(), collateralBefore, "the fulfil actually withdrew collateral");
        assertGt(mLegA.borrowBalance(address(strategy)), 0, "leg A still levered after the partial");
        assertGt(mLegB.borrowBalance(address(strategy)), 0, "leg B still levered after the partial");
        assertGt(ltvAfter, 0, "post-LTV is a real levered reading");

        // THE PROPERTY. No epsilon upward; measured drift here and on-chain is <= 0.02 bps, always down.
        assertLe(ltvAfter, ltvBefore, "a partial fulfillRedeem never RAISES the book LTV");
        assertApproxEqAbs(ltvAfter, ltvBefore, 2, "and it stays within rounding of it: a true pro-rata unwind");
        assertLe(ltvAfter, 6500, "post-fulfil LTV is still inside maxLtvBps");
    }

    /// @dev The accrual sibling: the basis itself moves, so only the one-sided property is claimable here.
    function testPartialFulfillRedeemUnderCollateralAccrualStillOnlyMovesTheLtvDown() public {
        _execute(SEED);
        _retarget(6000);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        mUsdc.setExchangeRateStored(1.37e18);
        mUsdc.setPendingExchangeRate(1.4e18); // accrual fires inside the fulfil

        uint256 ltvBefore = _ltvBps();
        uint256 id = _requestRedeem(SUPPLY / 4);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        uint256 ltvAfter = _ltvBps();
        assertGt(ltvAfter, 0, "post-LTV is a real levered reading");
        assertLe(ltvAfter, ltvBefore, "accrual can only move the LTV DOWN, never up");
        assertLe(ltvAfter, 6500, "post-fulfil LTV is still inside maxLtvBps");
    }

    /// @dev THE FAST PATH WITH NOTHING RAW: idle is drawn first, so a fully parked book always draws collateral and
    ///      the LTV gate is always live -- no tightening, since the supply lowers LTV before the exit.
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

    /// @dev THE ASYNC PATH WITH NOTHING RAW, AND THE IL COVER. The ORACLE-FREE Phase-1 budget IS the raw balance,
    ///      so parking everything drives it to 0 and Phase 2 (`_settleShortfall`) has to buy off Chainlink.
    function testAsyncFullRedeemCoversAnIlShortfallWithZeroRawIdle() public {
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK_ORACLE_CONSISTENT));
        pool.setTick(TICK_ORACLE_CONSISTENT);
        _execute(SEED);

        uint256 shares = _deposit(250_000e6);
        vm.prank(proposer);
        strategy.supplyIdle(250_000e6); // keeper leaves NO float: Phase 1 has nothing to spend
        assertEq(usdc.balanceOf(address(strategy)), 0, "precondition: the redeemer's Phase-1 budget is 0");

        // Move the pool up (spot AND TWAP) with leg B's oracle + swap rate: leg B is token0, so the repay shorts it.
        int24 newTick = TICK_ORACLE_CONSISTENT + 600;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(newTick));
        pool.setTick(newTick);
        pool.setTwapTick(newTick);
        uint256 newPB = (P_LEG_B * 1_061_837) / 1_000_000; // 1.0001^600
        legBFeed.setAnswer(int256(newPB));
        router.setRate(address(legB), address(usdc), (newPB * 1e18) / (100 * 1e8));
        router.setRate(address(usdc), address(legB), (100 * 1e8 * 1e18) / newPB);
        // FIXTURE ONLY: float `MockNpm` for what a post-move `collect` owes but was never minted.
        legB.mint(address(npm), 100e8);
        legA.mint(address(npm), 100e18);

        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 legBBoughtBefore = router.boughtOf(address(legB));
        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        uint256 id = strategy.requestRedeem(shares, 0, address(0));
        vm.stopPrank();
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        // The cover really ran -- without this the test would pass vacuously on a book with no shortfall.
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

    /// @dev The IL shortfall factored out: genesis at the oracle-consistent tick, a deposit the keeper parks in full
    ///      (raw float 0), then 600 ticks up in lockstep across spot, TWAP, leg B's feed and its swap rate.
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
        // FIXTURE ONLY (see the sibling test): float `MockNpm` for what a post-move `collect` owes.
        legB.mint(address(npm), 100e8);
        legA.mint(address(npm), 100e18);
    }

    /// @dev Request a redeem of `shares` from `lp` and return the request id.
    function _requestRedeem(uint256 shares) internal returns (uint256 id) {
        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        id = strategy.requestRedeem(shares, 0, address(0));
        vm.stopPrank();
    }

    /// @dev What an exact-OUTPUT buy of `legBOut` costs in USDC, rounded up as `exactOutputSingle` rounds it.
    function _legBBuyCost(uint256 legBOut) internal view returns (uint256) {
        uint256 rate = router.rateE18(address(usdc), address(legB));
        return (legBOut * 1e18 + rate - 1) / rate;
    }

    /// @dev Leg B's post-move mark -- the answer `_armLegBIlShortfall` installs, so also what `_settleShortfall`
    ///      sizes its budget against.
    function _legBMovedPrice() internal pure returns (uint256) {
        return (P_LEG_B * 1_061_837) / 1_000_000; // 1.0001^600
    }

    /// @dev Re-price the USDC->leg B BUY side `worseBps` worse than the mark; the sell direction is untouched.
    function _worsenLegBBuy(uint256 worseBps) internal {
        uint256 fair = (100 * 1e8 * 1e18) / _legBMovedPrice();
        router.setRate(address(usdc), address(legB), (fair * 10000) / (10000 + worseBps));
    }

    /// @dev F08 (a). THE SETTLE COVER'S BUDGET IS `maxSlippageBps`, NOT A HARDCODED 10%. The old `_settleShortfall`
    ///      redeemed `oracleCost x 110%` and floored the exact-INPUT swap only at `debtRem x (1 - maxSlippageBps)`;
    ///      independent bounds, so any fill between them kept the difference. Refused FAIL-CLOSED at 500bps worse.
    function testSettleShortfallCoverCannotOverpayPastMaxSlippage() public {
        uint256 shares = _armLegBIlShortfall();
        assertEq(usdc.balanceOf(address(strategy)), 0, "premise: Phase 1 has nothing to spend, so Phase 2 covers");
        _worsenLegBBuy(500);

        uint256 id = _requestRedeem(shares);
        vm.prank(proposer);
        vm.expectRevert(MockClSwapRouter.MockRouterMaxIn.selector);
        strategy.fulfillRedeem(id, 0);
    }

    /// @dev F08 (b). THE BAND, NOT A DEMAND FOR A PERFECT FILL: 50bps worse than the mark is inside the clone's
    ///      100bps band, must complete, and must spend inside `oracleValue(bought) x 1.01`.
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

    /// @dev F04. AN EXACT-OUTPUT SWAP HAS NO PARTIAL FILL, so a Phase-1 budget anywhere in `0 < idle < needed` used
    ///      to REVERT the whole redeem, `emergencyRedeem` included -- the `usdcBal == 0` guard covered only the
    ///      endpoint. Run (i) MEASURES the cover; (ii) hands it half, where the buy fails as `filled == false`.
    ///      MUTATION: pass `false` for `bestEffort` at the two Phase-1 call sites and (ii) reverts `MockRouterMaxIn`.
    function testFullRedeemSurvivesPartialIdleUsdc() public {
        // (i) Reference run: no float, so Phase 2 does all the covering and the leg B it bought sizes the cost.
        uint256 shares = _armLegBIlShortfall();
        uint256 boughtBefore = router.boughtOf(address(legB));
        uint256 id = _requestRedeem(shares);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
        uint256 needed = _legBBuyCost(router.boughtOf(address(legB)) - boughtBefore);
        assertGt(needed, 0, "premise: the armed book really does carry a leg-B shortfall to cover");

        // (ii) Same book, the keeper left HALF the cover's cost raw: the exact band the old code could not survive.
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

    /// @dev F04, THE OTHER HALF. Best-effort is scoped to the FULL-redeem Phase 1, the only cover with a next phase.
    ///      A PARTIAL redeem's cover is bounded at `balance - stayersIdle`, so an unaffordable buy must roll the whole
    ///      redeem back. Bracketed against the fair rate, so the revert is provably the BUY and not the arming.
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

    /// @dev F23 (a). THE DEADMAN IS ORACLE-FREE IN THE ORDINARY CASE. `_repay` accrues BEFORE applying the payment,
    ///      so a repay sized off `borrowBalanceStored` left `current - stored` standing -- and on a FULL redeem that
    ///      dust kept the borrow nonzero, so every full redeem fell into Phase 2 and read Chainlink.
    ///      MUTATION: put `borrowBalanceStored` back in `_redeemRepayFromCollected` and this reverts `StaleOracle`.
    function testFullEmergencyRedeemIsOracleFreeOnABalancedBook() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);
        // Surplus on both legs, so the pro-rata repay can reach the ACCRUED debt without a legitimate Phase-2 trip.
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

    /// @dev F23 (b). DEEP IL, ORACLE DOWN, AND THE SURPLUS LEG FINISHES THE JOB. The leg sweep used to run at the
    ///      very END of the unwind, so the surplus sat idle while Phase 1 hunted USDC; hoisted above the covers it
    ///      funds the deficit leg oracle-free. It cannot close the IL gap alone, hence half the cost as float.
    ///      MUTATION: move the step-C sweep back below the branch and this reverts `StaleOracle`.
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

    /// @dev F23 (c). THE HOIST STRANDS NOTHING, but only because Phase 2 now buys EXACTLY the debt (F08): the old
    ///      exact-INPUT settle over-bought by its 10% buffer and relied on the sweep running LAST to recover it.
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

    /// @dev F14 (a). THE PROPOSER GETS TO STATE A FRESH FLOOR: the requester's `minAssetsOut` can be two days old
    ///      by the fulfil, and nothing else bounds the payout -- the sweep floors bound individual SWAPS, not it.
    function testFulfillRedeemEnforcesTheFreshProposerFloor() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        uint256 id = _requestRedeem(SUPPLY / 4); // stored floor 0, as `_requestRedeem` passes
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientAssetsOut.selector);
        strategy.fulfillRedeem(id, type(uint128).max); // an unreachable fresh floor
    }

    /// @dev F14 (b). THE FLOOR IS `max(stored, fresh)`, NEVER `min`: the fulfiller must not be able to choose a
    ///      worse payout than the redeemer signed up for.
    function testFulfillRedeemCannotLowerTheRequestersFloor() public {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        uint256 shares = SUPPLY / 4;
        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        uint256 id = strategy.requestRedeem(shares, type(uint128).max, address(0)); // the requester's own huge floor
        vm.stopPrank();

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientAssetsOut.selector);
        strategy.fulfillRedeem(id, 0); // "no fresh opinion" must not mean "drop the requester's floor"
    }

    /// @dev F14 (c). `0` is the identity: the stored floor does all the work, exactly as before.
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

    // ==================== THE REQUEST'S RECIPIENT ====================
    // A fulfil pays the recipient named at request time; the requester keeps cancel and the deadman.

    /// @dev Live position + `SUPPLY` shares held by `lp`, then a request for `shares` paying `to`.
    function _requestRedeemTo(uint256 shares, address to) internal returns (uint256 id) {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);
        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        id = strategy.requestRedeem(shares, 0, to);
        vm.stopPrank();
    }

    /// @dev (1) THE FIX: `fulfillRedeem` pays the stored recipient; the requester receives nothing.
    function testFulfillRedeemPaysTheStoredRecipientAndNotTheRequester() public {
        address payee = makeAddr("payee");
        uint256 id = _requestRedeemTo(SUPPLY / 4, payee);

        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        assertGt(usdc.balanceOf(payee) - payeeBefore, 0, "the recipient was paid the whole payout");
        assertEq(usdc.balanceOf(lp), lpBefore, "the REQUESTER received nothing");
        assertTrue(strategy.redeemRequest(id).settled, "and the request settled");
    }

    /// @dev (2) `address(0)` means "pay me", so the stored recipient is never zero.
    function testRequestRedeemDefaultsTheRecipientToTheRequester() public {
        uint256 id = _requestRedeemTo(SUPPLY / 4, address(0));

        LeveragedAerodromeCLStrategy.RedeemRequest memory r = strategy.redeemRequest(id);
        assertEq(r.recipient, lp, "a zero recipient was substituted with msg.sender");
        assertEq(r.owner, lp, "...and the requester is unchanged");

        uint256 lpBefore = usdc.balanceOf(lp);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
        assertGt(usdc.balanceOf(lp) - lpBefore, 0, "so the requester is paid, as before");
    }

    /// @dev (3) A cancel reverses the escrow, so shares return to `owner` even with a differing recipient
    ///      — otherwise a request could hand a third party the position itself.
    function testCancelRedeemReturnsSharesToTheRequesterEvenWhenTheRecipientDiffers() public {
        address payee = makeAddr("payee");
        uint256 shares = SUPPLY / 4;
        uint256 id = _requestRedeemTo(shares, payee);
        assertEq(vault.balanceOf(lp), SUPPLY - shares, "premise: the shares are escrowed");

        vm.prank(lp);
        strategy.cancelRedeem(id);

        assertEq(vault.balanceOf(lp), SUPPLY, "the REQUESTER got the shares back");
        assertEq(vault.balanceOf(payee), 0, "the recipient got no shares");
        assertEq(usdc.balanceOf(payee), 0, "and no USDC");
    }

    /// @dev (4) THE DEADMAN STILL PAYS ITS CALLER: it returns `assetsOut` for a contract requester to
    ///      forward, so paying `recipient` would leave it nothing to forward.
    function testEmergencyRedeemPaysTheRequesterNotTheRecipient() public {
        address payee = makeAddr("payee");
        uint256 id = _requestRedeemTo(SUPPLY / 4, payee);

        vm.warp(block.timestamp + 2 days + 1); // deadman window elapsed
        uint256 lpBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        uint256 assetsOut = strategy.emergencyRedeem(id, 0);

        assertGt(assetsOut, 0, "the deadman exit completed");
        assertEq(usdc.balanceOf(lp) - lpBefore, assetsOut, "the REQUESTER was paid, as its caller");
        assertEq(usdc.balanceOf(payee), 0, "the recipient was not paid on this path");
    }

    /// @dev (5) The recipient is a payee, not an authority: it can neither cancel nor drive the deadman.
    function testTheRecipientHasNoAuthorityOverTheRequest() public {
        address payee = makeAddr("payee");
        uint256 id = _requestRedeemTo(SUPPLY / 4, payee);

        vm.prank(payee);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotRequestOwner.selector);
        strategy.cancelRedeem(id);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(payee);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotRequestOwner.selector);
        strategy.emergencyRedeem(id, 0);
    }

    /// @dev (6) The payee is observable on-chain, with the REQUESTER still in topic2 for indexers.
    function testRedeemEventsExposeTheRecipientWithoutMovingTheOwnerTopic() public {
        address payee = makeAddr("payee");
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        uint256 shares = SUPPLY / 4;
        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        vm.expectEmit(true, true, true, true, address(strategy));
        emit RedeemRequested(0, lp, payee, shares);
        uint256 id = strategy.requestRedeem(shares, 0, payee);
        vm.stopPrank();

        // The fulfil's own topic order, checked against the payout it actually made: `owner` (the
        // requester) must stay in topic2 for account-keyed indexers, `recipient` in topic3.
        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.recordLogs();
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
        uint256 paid = usdc.balanceOf(payee) - payeeBefore;
        assertGt(paid, 0, "premise: the fulfil paid the recipient");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != RedeemFulfilled.selector || logs[i].emitter != address(strategy)) continue;
            seen = true;
            assertEq(uint256(logs[i].topics[1]), id, "topic1 = id");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), lp, "topic2 = the REQUESTER");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), payee, "topic3 = the recipient");
            assertEq(abi.decode(logs[i].data, (uint256)), paid, "the one data word is the payout made");
        }
        assertTrue(seen, "RedeemFulfilled was emitted by the strategy");
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
        uint256 id = strategy.requestRedeem(supply, 0, address(0));
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg-B debt cleared");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "collateral fully redeemed");
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant restored");
        assertApproxEqRel(usdc.balanceOf(lp), SEED, 5e16, "redeemer recovered ~the whole book");
    }

    /// @dev THE LAST HOLDER OF A PARKED FLAT BOOK CAN LEAVE THROUGH THE FAST PATH: zero debt means no LTV to breach,
    ///      but before the guard moved inside the debt branch this reverted `FastRedeemExceedsLtv(uint256.max, ...)`.
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

    /// @dev THE FAST-PATH TWIN of `testFullAsyncRedeemLeavesNoCollateralDustAtANonUnitRate`, and the more dangerous
    ///      half: the burn happens at the FRESH rate while `amt` was sized off `exchangeRateStored`, so a full fast
    ///      redeem stranded `cBal x (1 - stored/fresh)` -- a fund with assets and no shares. Now burns the cTokens.
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
        // The surplus is the rate gap on the parked pot: supplied at rate 1.0, so `cBal == pot`.
        assertEq(out - quotedAtStoredRate, (pot * 3) / 100, "surplus == pot x (fresh - stored)");
    }

    /// @dev THE `fromCollateral == 0` ESCAPE, re-pinned fee-free: a cToken balance whose STORED value floors
    ///      to 0 makes `nav()` the idle pot alone, so a full redeem is funded entirely from idle and
    ///      `fromCollateral == 0` — yet the balance is real and must not be stranded on a zero-share book.
    ///      MUTATION: deleting or inverting the `!(isFullRedeem && cToken balance > 0)` conjunct early-returns
    ///      before the burn and leaves the dust behind.
    function testFastFullRedeemSweepsDustWhoseStoredValueFloorsToZero() public {
        _execute(SEED);
        vm.prank(proposer);
        strategy.flatten(0, 1);
        // A sub-unit exchange rate (one cToken worth less than one USDC unit -- the REAL Compound shape;
        // 1e18 is the mock's simplification), so a 1-unit park prices at 0 while minting live cTokens.
        mUsdc.setExchangeRateStored(0.4e18);
        uint256 pot = usdc.balanceOf(address(strategy));
        vm.prank(proposer);
        strategy.supplyIdle(1);

        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        assertGt(mUsdc.balanceOf(address(strategy)), 0, "precondition: the cToken balance is live");
        assertEq(_collateralUsdc(), 0, "...but its stored value floors to 0");
        assertEq(strategy.nav(), pot - 1, "so nav() is the idle pot alone");

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        uint256 out = strategy.redeem(supply, 0);
        vm.stopPrank();

        assertEq(out, pot - 1, "the redeemer is paid the whole priced book");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "the dust was swept, not stranded on a zero-share book");
        assertEq(vault.totalSupply(), 0, "the last shares are burnt");
    }

    /// @dev `vault.previewSharesForAssets` is documented as THE canonical assets->shares conversion, and the
    ///      strategy's `deposit` mints from an expression-identical formula. Nothing pinned the two together.
    ///      MUTATION: a changed offset or rounding direction on either side breaks this equality.
    function testPreviewSharesForAssetsEqualsTheSharesDepositMints() public {
        _execute(SEED);
        uint256 assets = 25_000e6;

        uint256 quoted = vault.previewSharesForAssets(assets);
        uint256 minted = _deposit(assets); // same block, so no management-fee dt intervenes

        assertGt(quoted, 0, "the preview quotes a real number");
        assertEq(minted, quoted, "the vault's canonical conversion is what deposit actually mints");
    }

    /// @dev THE `isFullRedeem` CONJUNCT, mutation-pinned: a PARTIAL redeem at a non-unit rate must pay the
    ///      stored-rate quote and NOTHING more. Deleting the conjunct passed the whole suite before this test.
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
        // The stayers keep the accrual: the remaining collateral revalues at the fresh rate the redeem just landed.
        assertApproxEqAbs(
            strategy.nav(), (pot * 140) / 100 - quoted, 2, "the fresh-rate surplus stays with the stayers"
        );
    }

    /// @dev MIXED FUNDING on the burn branch -- the realistic shape the sibling skips. Pins that the idle draw
    ///      and the collateral burn compose: the redeemer takes the raw float plus the FRESH-rate park, nothing
    ///      is retained and no cToken dust is left.
    function testFastFullRedeemWithMixedFundingPaysTheWholeBook() public {
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

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        uint256 out = strategy.redeem(supply, 0);
        vm.stopPrank();

        assertEq(out, (pot - parked) + (parked * 140) / 100, "raw float + fresh-rate park");
        assertEq(usdc.balanceOf(address(strategy)), 0, "nothing retained");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "no cToken dust");
        assertEq(strategy.nav(), 0, "zero-share fund prices at zero");
    }

    // ==================== previewRedeem MIRRORS THE EXECUTED redeem ====================
    // A frontend routes on `fastOk`, and the mirror drifted: `fastRedeemImpl` moved its `>= collateralUsdc` guard
    // inside the debt branch while the preview's copy stayed outside it.

    /// @dev THE DRIFT at its worst case, the last holder of a parked flat book: zero debt, whole pot as collateral,
    ///      `fromCollateral == collateralUsdc`, so `fastOk == false` would route the only holder into the deadman.
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

        // The exact mirror is scoped to a book with NO pending accrual (see the under-quote test below).
        assertEq(out, quoted, "quoted == executed: the preview is the mirror it claims to be");
    }

    /// @dev THE DOCUMENTED CARVE-OUT: a full redeem of a flat book pays the FRESH-rate proceeds while
    ///      `previewRedeem` prices at the stored rate. SAFE direction only -- it under-quotes, so it cannot bounce.
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

    /// @dev THE OTHER SIDE OF THE SAME GUARD -- it must still fire where it means something. On a LEVERED book a
    ///      full draw breaches `maxLtvBps`, and the executed path agrees by reverting: the same decision.
    function testPreviewRedeemAdvisesTheAsyncPathWhenTheDrawWouldBreachTheLtvGate() public {
        _execute(SEED);
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        assertGt(mLegA.borrowBalance(address(strategy)), 0, "precondition: the book carries debt");

        (uint256 quoted, bool fastOk) = strategy.previewRedeem(supply);
        assertGt(quoted, 0, "the payout is still quoted - only the ROUTING is negative");
        assertFalse(fastOk, "a full draw against a levered book breaches the LTV gate");

        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        // Selector-only: the reverting LTV is finite here, NOT the `uint256.max` collateral-exhausted arm.
        vm.expectPartialRevert(LeveragedAeroVenue.FastRedeemExceedsLtv.selector);
        strategy.redeem(supply, 0);
        vm.stopPrank();
    }

    /// @dev THE OTHER DIRECTION, and why the zero-debt branch is a BOUND rather than an unconditional `true`:
    ///      `repayBorrowBehalf` is permissionless, so debt can be retired while the LP position stays open, and
    ///      `nav()` then prices LP equity the collateral cannot fund -- a `true` would advise a reverting `redeem`.
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

        // ...and the executed path agrees with the TYPED refusal: `fastRedeemImpl`'s route-to-request sentinel.
        vm.startPrank(lp);
        vault.approve(address(strategy), supply);
        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAeroVenue.FastRedeemExceedsLtv.selector, type(uint256).max, uint256(6500))
        );
        strategy.redeem(supply, 0);
        vm.stopPrank();
    }

    /// @dev Retire BOTH leg debts from outside the strategy's own ops, the state `repayBorrowBehalf` allows anyone.
    ///      Pranked as the strategy only because `MockLendingMarket.repayBorrow` is `msg.sender`-scoped.
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

    /// @dev THE EVERYDAY CASE: a small partial redeem of a levered book routes fast AND quotes to the unit -- the
    ///      SHARE-PRICING half of the preview, which the two guard tests do not touch.
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

    /// @dev A FULL async redeem burns the cTOKEN balance (`redeem(cBal)`), so no rate-gap dust survives: the
    ///      flat-branch `nav()` prices such dust and a zero-share fund would gift it to the next depositor.
    function testFullAsyncRedeemLeavesNoCollateralDustAtANonUnitRate() public {
        _execute(SEED);
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        // The gap: views report 1.37e18 while the next MUTATING call accrues to 1.40e18, so an UNDERLYING-sized full
        // draw off the stored rate strands `cBal x (1 - 1.37/1.40)`. One settable rate hid the branch entirely.
        mUsdc.setExchangeRateStored(1.37e18); // stored < fresh is the on-chain norm
        mUsdc.setPendingExchangeRate(1.4e18); // ...and this is the fresh rate the redeem accrues to

        vm.prank(lp);
        vault.approve(address(strategy), supply);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(supply, 0, address(0));
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
    // Step E's two leg sweeps were the LAST zero-min-out swaps in the system, with the loss landing on the REDEEMER.
    // They now floor at `oracleValue(sold) x (1 - maxSlippageBps)`, derived behind a try-able hop so the floors fall
    // back to 0 rather than freezing `emergencyRedeem`.

    /// @dev A rerange-remainder-shaped idle balance on both legs ($100k leg B, $30k leg A), big enough to sell.
    uint256 internal constant IDLE_LEG_B = 1e8;
    uint256 internal constant IDLE_LEG_A = 10e18;

    uint256 internal constant SUPPLY = 1_000_000e12;

    /// @dev Live position + `SUPPLY` shares + an idle remainder on both legs, then a request for `shares`.
    function _armRedeemWithIdleLegs(uint256 shares) internal returns (uint256 id) {
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);
        legB.mint(address(strategy), IDLE_LEG_B);
        legA.mint(address(strategy), IDLE_LEG_A);
        vm.prank(lp);
        vault.approve(address(strategy), shares);
        vm.prank(lp);
        id = strategy.requestRedeem(shares, 0, address(0));
    }

    /// @dev Re-price the leg->USDC SELL direction at `bps` of the oracle mark (10000 == the fair rate); buys untouched.
    function _setLegSellRate(uint256 bps) internal {
        router.setRate(address(legB), address(usdc), (P_LEG_B * 1e18 * bps) / (100 * 1e8 * 10000));
        router.setRate(address(legA), address(usdc), (P_LEG_A * 1e18 * bps) / (100 * 1e18 * 10000));
    }

    /// @dev The stayers' reserved leg share: `(1-f)` of the leg balance MEASURED just before the unwind -- measured,
    ///      because genesis already strands a real leg remainder on top of `IDLE_LEG_*`.
    function _stayerLegOf(uint256 preBal, uint256 shares) internal pure returns (uint256) {
        return preBal - Math.mulDiv(preBal, shares, SUPPLY);
    }

    /// @dev (a) THE FINDING. A fill 2% under the mark -- outside the clone's 100bps band -- is now REFUSED; before
    ///      the floor it filled silently and the redeemer simply got less USDC.
    function testRedeemLegSweepRefusesAFillBelowTheOracleFloor() public {
        uint256 id = _armRedeemWithIdleLegs(SUPPLY / 4);
        _setLegSellRate(9800); // 200bps under oracle vs. a 100bps floor

        vm.prank(proposer);
        vm.expectRevert(MockClSwapRouter.MockRouterMinOut.selector);
        strategy.fulfillRedeem(id, 0);
    }

    /// @dev (b) BINDING BUT NOT TRIPPING. 50bps under the mark is inside the band and must go through, so (a) and
    ///      (b) together bracket the floor at `maxSlippageBps`.
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
        // The sold slice cleared a floor priced off the SOLD amount, not the raw balance: the reservation is intact.
        assertEq(legB.balanceOf(address(strategy)), _stayerLegOf(preB, shares), "leg-B reservation intact");
        assertEq(legA.balanceOf(address(strategy)), _stayerLegOf(preA, shares), "leg-A reservation intact");
    }

    /// @dev (c) THE DEADMAN TEST. `emergencyRedeem` routes through this sweep, so a fail-closed floor would freeze
    ///      the exit built for oracle-down. Armed with every feed stale AND the fill that reverts in (a).
    function testEmergencyRedeemStillCompletesWithStaleFeedsAndAHostileFill() public {
        uint256 shares = SUPPLY / 4;
        uint256 id = _armRedeemWithIdleLegs(shares);
        _setLegSellRate(9800);

        vm.warp(block.timestamp + 2 days + 1); // deadman window elapsed; every feed now stale
        // Sanity, on the specific selector: a bare `expectRevert()` would also pass on an unrelated `nav()` break.
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

    /// @dev (d) INSULATION REGRESSION. The floors must not move the stayer/redeemer boundary: stayers keep exactly
    ///      `(1-f)` of every leg and of the idle USDC, the SAME number under a fair fill and a floor-0 deadman fill.
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

        // Same book, same f, through the floor-0 deadman path under a hostile fill: byte-identical either way.
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

    /// @dev (e) THE FALLBACK IS MARKED ON CHAIN. The `catch {}` dropping the floors to 0 is deliberate -- (c) needs
    ///      it -- but it cannot tell a stale feed from an out-of-gas. Healthy emits NOTHING; the deadman emits.
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

        // DEGRADED: the deadman warp staled every feed, so the derivation reverts and the floors fall back to 0.
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

    /// @dev THE FINDING. The harvest budget is ONE ceiling over TWO independent drifts. It used to go to leg A whole
    ///      with leg B getting `budget - spentA`, and the spend path returned on `budget == 0` BEFORE reading its
    ///      market -- so on a thin harvest leg B was never even MEASURED and a partial hedge ROTATED the short.
    function testPartialBudgetHedgesBothLegsProRataInsteadOfStarvingLegB() public {
        _armAeroRouter();
        _execute(SEED);
        vm.prank(address(strategy));
        vault.strategyMint(lp, SUPPLY);

        // ASYMMETRIC on purpose -- leg A 100bps of debt, leg B 25bps: a 4:1 ratio separates pro-rata from either.
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

        uint256 spent = usdc.balanceOf(address(router)) - routerUsdc0;
        assertLe(spent, budget, "total spend never exceeds the harvest budget");
        assertApproxEqRel(spent, budget, 1e15, "...and no allocation dust was stranded by the division");

        uint256 closedA = driftA0 - _driftLegA();
        uint256 closedB = driftB0 - _driftLegB();
        assertGt(closedB, 0, "leg B was hedged AT ALL - the finding (pre-fix this is exactly 0)");
        uint256 fracA = Math.mulDiv(closedA, 1e18, driftA0);
        uint256 fracB = Math.mulDiv(closedB, 1e18, driftB0);
        assertApproxEqRel(fracA, fracB, 1e15, "the same FRACTION of each leg's drift was closed");
        assertApproxEqRel(
            fracA, Math.mulDiv(budget, 1e18, costA + costB), 1e15, "...and that fraction is the budget's coverage"
        );

        assertGt(_driftLegA(), 0, "leg-A remainder carries");
        assertGt(_driftLegB(), 0, "leg-B remainder carries");
    }

    /// @dev REGRESSION on the full-budget case, separate because the pro-rata split is a NO-OP there and must stay
    ///      one: each leg's spend is capped at its own cost, so an ample budget neutralises both exactly as before.
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

        // >99.99% of each leg's drift closed; the residue is the same two-way-oracle rounding dust as before.
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
    // Measuring both legs unconditionally is what makes the pro-rata split correct, but it turned
    // `borrowBalanceCurrent` -- a STATE-CHANGING call that reverts whenever `accrueInterest` fails -- into a liveness
    // dependency of `compound` on BOTH legs, and in the band armed below it is the only touch of that leg's market.
    // `_measureLeg` now degrades that leg's drift to zero, marked with `HedgeLegMeasureDegraded`.

    /// @dev Break `market`'s accrual the way Moonwell does: `borrowBalanceCurrent` is a
    ///      `require(accrueInterest() == NO_ERROR, ...)`, so it reverts as a string. `borrowBalanceStored` still works.
    function _breakAccrual(address market) internal {
        vm.mockCallRevert(
            market,
            abi.encodeWithSelector(MockLendingMarket.borrowBalanceCurrent.selector),
            abi.encodeWithSignature("Error(string)", "accrue interest failed")
        );
    }

    /// @dev Count `HedgeLegMeasureDegraded` markers raised from the STRATEGY's address; returns the last one named.
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

    /// @dev Arm drift on BOTH legs plus a harvest budget SHORT of either leg's own drift -- the band where the hedge
    ///      consumes the whole harvest, `deployIdleImpl` is skipped, and the measure is the only market touch.
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

        // 99% of the SMALLER leg's cost: below either leg's own cost, so the surviving leg spends the whole budget.
        uint256 costA = _valueUsdc(driftA0, P_LEG_A, 18);
        uint256 costB = _valueUsdc(driftB0, P_LEG_B, 8);
        budget = ((costA < costB ? costA : costB) * 99) / 100;
        _armHarvest(budget);
    }

    /// @dev (a) THE REGRESSION, on the leg it bites: leg B's market cannot accrue, the harvest must still complete
    ///      in full, and only leg B's hedge may be lost.
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

        (uint256 marks, address named) = _degradations(logs);
        assertEq(marks, 1, "exactly one leg degraded");
        assertEq(named, address(mLegB), "...and it is leg B's market that is named");

        assertEq(aero.balanceOf(address(strategy)), 0, "the whole claim was sold");
        assertEq(aero.balanceOf(AERO_V2_ROUTER) - aeroInRouter0, budget * 1e12, "...to the AERO->USDC router");

        // 3. THE FEE CRYSTALLISATION HAPPENED and stuck -- it precedes the hedge, so a revert would have undone it.
        assertGt(strategy.layout().hwmPerShare, 0, "the pre-compound crystallise ran and persisted");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.FeeCrystallizeDeferred.selector,
                "the crystallise was not deferred either"
            );
        }

        // 4. LEG A'S HEDGE HAPPENED and took the WHOLE budget: leg B's cost degraded to 0, so pro-rata gives it all.
        assertEq(usdc.balanceOf(address(router)) - usdcInSwapRouter0, budget, "the whole budget bought leg A");
        assertApproxEqRel(driftA0 - _driftLegA(), (driftA0 * 99) / 100, 1e15, "leg A hedged by ~the budget's coverage");

        assertEq(_driftLegB(), driftB0, "leg B's drift carries in full");

        // 6. ...and this really WAS the only touch of leg B's market: the harvest was fully consumed by the hedge.
        assertEq(mUsdc.balanceOf(address(strategy)), collateral0, "redeploy skipped (redeploy == 0)");
    }

    /// @dev (b) THE SYMMETRY, and why the fail-open is not leg-B-only: same book, same budget, the OTHER market
    ///      broken -- the harvest still completes and leg B is the one hedged in full.
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

    /// @dev (c) THE MARKER IS NOT FREE-RUNNING: a healthy two-leg harvest must emit NOTHING, or the event says
    ///      nothing about a leg that has stopped being hedged.
    function testAHealthyTwoLegHarvestMarksNoDegradation() public {
        _armTwoLegDriftAndAThinHarvest();

        vm.recordLogs();
        vm.prank(proposer);
        strategy.compound(1, 0);

        (uint256 marks,) = _degradations(vm.getRecordedLogs());
        assertEq(marks, 0, "a healthy harvest degrades nothing");
    }

    // ============ THE EMPTY BOOK: DORMANCY AND THE HWM ACROSS A supply == 0 CYCLE (F03) ============
    // `_crystallizeFees` used to `return` outright on `totalSupply() == 0`, writing NEITHER the fee clock nor the HWM;
    // both bill the reopening depositor for a cycle they were not in. FIXTURE: fees are 0 here, so the writes are
    // asserted as state rather than as minted shares.

    /// @dev THE CLOCK. Drain to zero shares, let a YEAR pass, reopen: the reopening crystallise must move
    ///      `lastFeeAccrualTimestamp` to now, or the next one bills 365 days of fee on a dormant fund.
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

    /// @dev THE HWM. A mark taken against the OLD supply is incommensurable with the reopening basis
    ///      (`WAD / SHARES_VIRTUAL_OFFSET` == 1e12), so the empty-book branch zeroes it and the next cycle reseeds.
    function testTheHwmResetsAcrossASupplyZeroCycle() public {
        _flatBookHeldEntirelyAsCollateral();
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);

        // Two crystallisation points are needed to MARK the HWM: the first only seeds the clock, the second marks.
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

        // REOPEN. `nav() == 0` and `supply == 0`, so the depositor mints at `assets x SHARES_VIRTUAL_OFFSET` == 1e12.
        _deposit(100_000e6);
        assertEq(strategy.layout().hwmPerShare, 0, "the dead cycle's mark did not survive the empty book");

        // The next crystallise re-seeds at the REOPENED fund's basis, charging nothing (first cycle).
        _deposit(1_000e6);
        assertEq(strategy.layout().hwmPerShare, 1e12, "re-seeded at the new basis, not the dead cycle's peak");
    }
}
