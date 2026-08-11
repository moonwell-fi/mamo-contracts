// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAeroValuation} from "@contracts/leveraged-aero/LeveragedAeroValuation.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {LiquidityAmounts} from "@contracts/leveraged-aero/sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {MockCLGauge} from "../mocks/MockCLGauge.sol";
import {MockCLFactory, MockCLPool} from "../mocks/MockCLPool.sol";
import {MockComptroller} from "../mocks/MockMoonwellMarket.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {
    MockAeroV2Factory,
    MockChainlinkFeed,
    MockClSwapRouter,
    MockLendingMarket,
    MockNpm
} from "./LeveragedAeroVenuesHarness.sol";

import {Test} from "@forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ASSET-AS-A-LEG lifecycle tests (execute / deployIdle / partial redeem)
 * @notice Drives the REAL `LeveragedAerodromeCLStrategy` + `LeveragedAeroManager` venue paths against
 *         custodial mocks, in the asset-mode shape (a legA/USDC pool). Covers the two things the split
 *         math alone cannot prove:
 *
 *           - DEPLOY: `execute` / `deployIdle` supply only `C`, borrow only leg A, LP the remaining `U`
 *             against it, and clear the post-op health gate — with `C + U == amount` on chain.
 *           - THE CRUX INVARIANT: a partial redeem must not pay the redeemer out of the stayers'
 *             reserved idle USDC. In asset-mode the unwind sheds REAL USDC into the very balance the
 *             reservation is computed from, which is precisely what the old `UnsupportedLeg` ban on
 *             `cbBTC == usdc` was protecting. The reservation must come off the PRE-unwind snapshot.
 *
 * @dev Fixture: leg A is an 8dp volatile token (cbBTC-shaped) and the LP pair is legA/USDC. The pool
 *      `sqrtP` and the leg-A Chainlink price are kept mutually consistent by deriving the price from
 *      `sqrtP`, so the oracle-implied mark inside `nav()` agrees with the pool and the deploy split
 *      lands balanced. Fees are OFF so the assertions are about token flows, not fee accounting.
 */
contract LeveragedAeroAssetModeLifecycleUnitTest is Test {
    // ── Roles ──
    address internal owner = makeAddr("owner");
    address internal proposer = makeAddr("proposer");
    address internal lp = makeAddr("lp");

    // ── Tokens ──
    MockToken internal usdc; // 6dp — unit of account AND the leg-B slot (this is asset-mode)
    MockToken internal legA; // 8dp volatile borrowed leg
    MockToken internal aero; // 18dp gauge reward

    // ── Venues ──
    MockCLPool internal pool;
    MockCLFactory internal clFactory;
    MockCLGauge internal gauge;
    MockComptroller internal comptroller;
    MockLendingMarket internal mUsdc;
    MockLendingMarket internal mLegA;
    MockNpm internal npm;
    MockClSwapRouter internal router;
    MockChainlinkFeed internal usdcFeed;
    MockChainlinkFeed internal legAFeed;
    MockChainlinkFeed internal aeroFeed;
    MockChainlinkFeed internal sequencerFeed;

    LeveragedAeroVault internal vault;
    LeveragedAerodromeCLStrategy internal template;
    LeveragedAerodromeCLStrategy internal strategy;

    int24 internal constant SPACING = 100;
    int24 internal constant LEG_A_SWAP_SPACING = 200;
    /// @dev Leg A is token1 here, so the pool's raw price is "leg-A units per USDC unit" — a token
    ///      worth ~$100k needs a NEGATIVE tick (`ln(1e-3)/ln(1.0001) ~ -69078`, aligned to the grid).
    int24 internal constant TICK = -69_100;
    uint24 internal constant WIDTH = 4000;
    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint8 internal constant LEG_A_DECIMALS = 8;
    uint256 internal constant P_USDC = 1e8;
    uint256 internal constant Q96 = 1 << 96;

    uint256 internal constant SEED = 1_000_000e6; // $1M genesis deposit

    /// @dev Leg-A price (8dp) implied by the pool's sqrtP, for THIS fixture's ordering (legA = token1).
    uint256 internal legAPrice8;

    /// @dev Aerodrome v2 PoolFactory, hardcoded in `LeveragedAeroValuation` and probed by venue
    ///      validation to prove the reward token has a USDC route. Etched below (no code otherwise).
    address internal constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @dev `LeveragedAeroVenue.applyVenue` pins the canonical Slipstream CLFactory rather than
    ///      trusting `pool.factory()`, so a fork-free test has to place the registry HERE. Etch is
    ///      safe despite `MockCLFactory` being storage-based: only the code is copied, and every
    ///      `setPool` below writes to the etched address's own storage.
    address internal constant AERODROME_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    function setUp() public {
        vm.warp(1_800_000_000); // a sane clock for feed freshness / sequencer grace

        usdc = new MockToken("USD Coin", "USDC", 6);
        legA = new MockToken("Leg A", "LEGA", LEG_A_DECIMALS);
        aero = new MockToken("Aerodrome", "AERO", 18);

        // Pool: USDC is token0, leg A is token1 → `wethIsToken0 == false`.
        pool = new MockCLPool(address(usdc), address(legA), SPACING);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(TICK);
        pool.setSqrtPriceX96(sqrtP);
        pool.setTick(TICK); // also pins the TWAP tick → calm-gate passes
        clFactory = MockCLFactory(AERODROME_CL_FACTORY);
        vm.etch(AERODROME_CL_FACTORY, address(new MockCLFactory()).code);
        pool.setFactory(AERODROME_CL_FACTORY);
        clFactory.setPool(address(legA), address(usdc), SPACING, address(pool));
        clFactory.setPool(address(usdc), address(legA), LEG_A_SWAP_SPACING, makeAddr("legASwapPool"));

        legAPrice8 = _legAPriceFromSqrtP(sqrtP);

        gauge = new MockCLGauge(address(aero));
        gauge.setPool(address(pool));
        pool.setGauge(address(gauge));
        // The reward-route probe in venue validation reads a HARDCODED v2 factory address;
        // place code there so the AERO/USDC route resolves in this fork-free suite.
        vm.etch(AERO_V2_FACTORY, address(new MockAeroV2Factory(address(aero), address(usdc), address(0xA2F))).code);
        comptroller = new MockComptroller();
        mUsdc = new MockLendingMarket(address(usdc));
        mLegA = new MockLendingMarket(address(legA));
        npm = new MockNpm(pool);
        // Real ERC-721 custody: a staked position is OWNED by the gauge, so any liquidity call
        // that forgets to unstake first reverts here exactly as it would on chain.
        gauge.setNpm(address(npm));
        router = new MockClSwapRouter();

        sequencerFeed = new MockChainlinkFeed(0, 8, 1, block.timestamp - 2 hours); // 0 == sequencer up
        usdcFeed = new MockChainlinkFeed(int256(P_USDC), 8, 1, block.timestamp);
        legAFeed = new MockChainlinkFeed(int256(legAPrice8), 8, 1, block.timestamp);
        aeroFeed = new MockChainlinkFeed(1e8, 8, 1, block.timestamp);

        // Venue float: markets must be able to pay borrows/redemptions, the router to fill swaps.
        usdc.mint(address(mUsdc), 100_000_000e6);
        legA.mint(address(mLegA), 1_000_000e8);
        usdc.mint(address(router), 100_000_000e6);
        legA.mint(address(router), 1_000_000e8);
        // Router rates, both directions, consistent with the oracle price.
        router.setRate(address(legA), address(usdc), (legAPrice8 * 1e18) / (100 * 10 ** uint256(LEG_A_DECIMALS)));
        router.setRate(address(usdc), address(legA), (100 * 10 ** uint256(LEG_A_DECIMALS) * 1e18) / legAPrice8);

        vault = new LeveragedAeroVault(address(usdc), owner, "Leveraged Aero Vault", "lvAERO");
        template = new LeveragedAerodromeCLStrategy();
        strategy = LeveragedAerodromeCLStrategy(payable(Clones.clone(address(template))));
        strategy.initialize(address(vault), proposer, abi.encode(_params()));

        vm.startPrank(owner);
        vault.setStrategy(address(strategy));
        vault.setOpenDeposits(true);
        vm.stopPrank();
    }

    // ==================== HELPERS ====================

    /// @dev Inverse of `oracleSqrtPriceX96` for this fixture (leg A is token1, asset is token0/6dp):
    ///      `raw = pUsdc·10^dA / (pA·1e6)` ⇒ `pA = 100·10^dA / raw`.
    function _legAPriceFromSqrtP(uint160 sqrtP) internal pure returns (uint256) {
        uint256 rawQ96 = Math.mulDiv(sqrtP, sqrtP, Q96);
        return Math.mulDiv(100 * (10 ** uint256(LEG_A_DECIMALS)), Q96, rawQ96);
    }

    /// @dev USDC face (6dp) value of `amt` leg-A units, on the manager's `_tokenToUsdc` basis.
    function _legAValueUsdc(uint256 amt) internal view returns (uint256) {
        return (amt * legAPrice8 * 1e6) / ((10 ** uint256(LEG_A_DECIMALS)) * P_USDC);
    }

    /// @dev A valid ASSET-MODE `InitParams`. The leg-B slot holds USDC — that alone derives the shape.
    function _params() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        p.usdc = address(usdc);
        p.mUsdc = address(mUsdc);
        p.mCbBTC = address(mUsdc); // leg B is never borrowed → pinned to the collateral market
        p.mWeth = address(mLegA);
        p.comptroller = address(comptroller);
        p.cbBTC = address(usdc); // ← ASSET-MODE
        p.weth = address(legA);
        p.pool = address(pool);
        p.npm = address(npm);
        p.gauge = address(gauge);
        p.swapRouter = address(router);
        p.cbBTCFeed = address(usdcFeed); // leg B prices at face
        p.wethFeed = address(legAFeed);
        p.usdcFeed = address(usdcFeed);
        p.sequencerFeed = address(sequencerFeed);
        p.aeroUsdFeed = address(aeroFeed);
        p.maxDelay = 1 hours;
        p.gracePeriod = 1 hours;
        p.calmDeviationTicks = 100;
        p.twapWindow = 600;
        p.tickSpacing = SPACING;
        p.cbBTCSwapTickSpacing = 0; // declared unused in asset-mode
        p.wethSwapTickSpacing = LEG_A_SWAP_SPACING;
        p.wethDeliversNative = false;
        p.width = WIDTH;
        p.minWidth = 200;
        p.maxWidth = 20_000;
        p.targetLtvBps = TARGET_LTV_BPS;
        p.maxLtvBps = 6500;
        p.minHealthBps = 12_000;
        p.maxSlippageBps = 100;
        p.managementFeeBps = 0; // fees off — these tests are about token flows
        p.performanceFeeBps = 0;
        p.feeRecipient = address(0);
    }

    /// @dev Fund the strategy with `amount` USDC and run the vault-driven `execute()`.
    function _execute(uint256 amount) internal {
        usdc.mint(address(strategy), amount);
        vm.prank(address(vault));
        strategy.execute();
    }

    /// @dev The collateral / LP-USDC / borrow triple the split would return for `amount` at the range
    ///      the production path will use — recomputed independently so the tests can assert against it.
    function _expectedSplit(uint256 amount, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 c, uint256 u, uint256 a)
    {
        return _expectedSplitAtLtv(amount, tickLower, tickUpper, TARGET_LTV_BPS);
    }

    /// @dev Same, at an ARBITRARY target LTV — the target-persistence tests need to size the SAME
    ///      deployment two ways (at the new standing target vs. at the stale init one) to show which
    ///      value the production path actually used.
    function _expectedSplitAtLtv(uint256 amount, int24 tickLower, int24 tickUpper, uint16 ltvBps)
        internal
        view
        returns (uint256 c, uint256 u, uint256 a)
    {
        return LeveragedAeroValuation.assetModeSplit(
            address(pool), tickLower, tickUpper, amount, uint256(ltvBps), LEG_A_DECIMALS, false, legAPrice8
        );
    }

    function _centeredRange() internal view returns (int24, int24) {
        return LeveragedAeroValuation.centeredTickRange(address(pool), SPACING, WIDTH);
    }

    /// @dev On-chain collateral (USDC face) and leg-A debt, on the strategy's own health basis.
    function _collateralAndDebt() internal view returns (uint256 collateral, uint256 debtUsdc) {
        collateral = (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18;
        debtUsdc = _legAValueUsdc(mLegA.borrowBalance(address(strategy)));
    }

    /// @dev The `(A, U′)` pair an asset-mode lever-up to `targetLtvBps_` will size, recomputed
    ///      independently from the SAME inputs the manager derives on chain: collateral is untouched by
    ///      the op, so `targetDebt = collateral × targetLtv / 1e4`, the delta is `targetDebt − debt`, and
    ///      `U′` is that delta's leg-A borrow paired at the STORED range's required ratio.
    /// @dev `idleUsdc` is passed as `type(uint256).max` so the helper only ever reports the SIZE — the
    ///      funding bound is what the production call (with the real balance) is under test for.
    function _expectedLeverUpPair(uint16 targetLtvBps_) internal view returns (uint256 legABorrow, uint256 lpUsdc) {
        (uint256 collateral, uint256 debtUsdc) = _collateralAndDebt();
        uint256 targetDebt = (uint256(targetLtvBps_) * collateral) / 10_000;
        assertGt(targetDebt, debtUsdc, "helper is only meaningful for a lever-UP target");
        return LeveragedAeroValuation.assetModeLeverUpPair(
            address(pool),
            strategy.layout().posTickLower,
            strategy.layout().posTickUpper,
            targetDebt - debtUsdc,
            type(uint256).max,
            LEG_A_DECIMALS,
            false, // leg A is token1 in this fixture
            legAPrice8
        );
    }

    /// @dev The leg-A units the live CL position currently holds, at the pool's `sqrtP` and the STORED
    ///      range — leg A is token1 in this fixture, so it is the `amount1` side.
    function _lpLegAAmount() internal view returns (uint256 legAAmt) {
        (, legAAmt) = LiquidityAmounts.getAmountsForLiquidity(
            pool.sqrtPriceX96(),
            TickMath.getSqrtRatioAtTick(strategy.layout().posTickLower),
            TickMath.getSqrtRatioAtTick(strategy.layout().posTickUpper),
            npm.liquidityOf(strategy.layout().tokenId)
        );
    }

    // ==================== DEPLOY: execute ====================

    /**
     * @dev Genesis in asset-mode: only the solved `C` is supplied as collateral (NOT the whole deposit,
     *      which is what the two-borrowed-legs shape does), only leg A is borrowed, and the remaining
     *      `U` goes into the LP as the pool's USDC side. `_assertHealthy` ran inside `execute`, so
     *      reaching these assertions at all is the post-op health gate passing.
     */
    function testExecuteSuppliesOnlyTheSolvedCollateralAndBorrowsOnlyLegA() public {
        (int24 tickLower, int24 tickUpper) = _centeredRange();
        (uint256 expC, uint256 expU, uint256 expA) = _expectedSplit(SEED, tickLower, tickUpper);

        _execute(SEED);

        // Collateral is C — strictly less than the deposit. This is THE asset-mode difference.
        (uint256 collateral, uint256 debtUsdc) = _collateralAndDebt();
        assertEq(collateral, expC, "only the solved collateral portion C was supplied");
        assertLt(collateral, SEED, "asset-mode must NOT supply the whole deposit as collateral");

        // C + U == amount, on chain: collateral plus what the LP took plus any dust equals the seed.
        uint256 lpUsdc = usdc.balanceOf(address(npm));
        uint256 dustUsdc = usdc.balanceOf(address(strategy));
        assertEq(collateral + lpUsdc + dustUsdc, SEED, "C + U == amount (nothing leaked)");
        assertApproxEqRel(lpUsdc + dustUsdc, expU, 1e15, "the LP-side USDC portion is U");

        // Exactly ONE borrow, and it is leg A.
        assertEq(mLegA.borrowBalance(address(strategy)), expA, "leg-A borrow matches the split");
        assertEq(mUsdc.borrowBalance(address(strategy)), 0, "leg B (the asset) is never borrowed");

        // LTV landed on target, and the position is staked and live.
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, uint256(TARGET_LTV_BPS), 1, "LTV == target");
        assertEq(strategy.layout().posTickLower, tickLower, "range persisted");
        assertEq(strategy.layout().posTickUpper, tickUpper, "range persisted");
        assertGt(strategy.layout().tokenId, 0, "position minted");
        assertEq(gauge.depositCallCount(), 1, "position staked in the gauge");
    }

    /// @dev The mint must consume (essentially) BOTH sides — the point of the closed-form split. A
    ///      mis-sized pair would strand a large fraction of one side in the strategy wallet.
    function testExecuteMintConsumesBothSidesOfThePair() public {
        (int24 tickLower, int24 tickUpper) = _centeredRange();
        (, uint256 expU, uint256 expA) = _expectedSplit(SEED, tickLower, tickUpper);

        _execute(SEED);

        assertLe(usdc.balanceOf(address(strategy)), expU / 1000, "<=0.1% of the USDC side left unconsumed");
        assertLe(legA.balanceOf(address(strategy)), expA / 1000 + 1, "<=0.1% of the leg-A side left unconsumed");
        assertGt(usdc.balanceOf(address(npm)), 0, "USDC really went into the LP");
        assertGt(legA.balanceOf(address(npm)), 0, "leg A really went into the LP");
    }

    /// @dev `nav()` must price the asset-mode book WITHOUT double-counting: the leg-B slot IS USDC, so
    ///      valuation must not add the idle-USDC balance twice. Post-genesis NAV ~= the deposit.
    function testNavDoesNotDoubleCountIdleUsdcInAssetMode() public {
        _execute(SEED);
        assertApproxEqRel(strategy.nav(), SEED, 2e16, "NAV ~= seed (no double-counted idle USDC)");

        // Add idle USDC and assert NAV rises by exactly that, ONCE.
        uint256 navBefore = strategy.nav();
        usdc.mint(address(strategy), 100_000e6);
        assertApproxEqAbs(strategy.nav(), navBefore + 100_000e6, 2, "idle USDC counted exactly once");
    }

    // ==================== DEPLOY: deployIdle ====================

    /// @dev `deployIdle` sizes against the STORED range and preserves the shape: collateral grows by the
    ///      new `C`, the single leg-A borrow grows, LTV stays on target.
    function testDeployIdleKeepsShapeAndTarget() public {
        _execute(SEED);
        (uint256 collateralBefore,) = _collateralAndDebt();
        uint256 debtBefore = mLegA.borrowBalance(address(strategy));

        uint256 topUp = 250_000e6;
        usdc.mint(address(strategy), topUp);
        uint256 idleBefore = usdc.balanceOf(address(strategy));

        (uint256 expC,, uint256 expA) =
            _expectedSplit(topUp, strategy.layout().posTickLower, strategy.layout().posTickUpper);

        vm.prank(proposer);
        strategy.deployIdle(topUp, 0);

        (uint256 collateralAfter, uint256 debtAfter) = _collateralAndDebt();
        assertEq(collateralAfter - collateralBefore, expC, "only C of the top-up became collateral");
        assertEq(mLegA.borrowBalance(address(strategy)) - debtBefore, expA, "single leg-A borrow grew by A");
        assertEq(mUsdc.borrowBalance(address(strategy)), 0, "still no leg-B borrow");
        assertApproxEqAbs((debtAfter * 10_000) / collateralAfter, uint256(TARGET_LTV_BPS), 2, "LTV still on target");
        assertLt(usdc.balanceOf(address(strategy)), idleBefore, "idle USDC was actually deployed");
    }

    /// @dev A STORED range the price has since left is one-sided, so the split cannot balance and
    ///      `deployIdle` fails closed. This is the documented `rerange`-first case — and it must be a
    ///      clean typed revert, not a divide-by-zero or a silently unhedged add.
    function testDeployIdleFailsClosedWhenStoredRangeIsOneSided() public {
        _execute(SEED);

        // Walk the price clear above the stored range (and drag the TWAP with it, so the calm-gate is
        // not what fires — the degenerate range is).
        int24 farTick = strategy.layout().posTickUpper + 5000;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(farTick));
        pool.setTick(farTick);
        legAFeed.setAnswer(int256(_legAPriceFromSqrtP(pool.sqrtPriceX96())));

        usdc.mint(address(strategy), 100_000e6);
        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        strategy.deployIdle(100_000e6, 0);
    }

    // ==================== ASSET-MODE LEVER UP (idle-funded) ====================

    /**
     * @dev THE ASSERTION THAT PICKS DESIGN (a) OVER (b). An asset-mode lever-up borrows ΔB of leg A and
     *      pairs it with `U′` USDC drawn from IDLE (a), so the LP's leg-A amount still equals the leg-A
     *      debt: net leg-A exposure stays 0 and the delta-hedge is preserved. Design (b) — borrowing ΔB
     *      and swapping part of it to USDC to self-fund the pair — would leave the LP holding LESS leg A
     *      than the debt, i.e. the book net SHORT the swapped amount. The test states both the hedge
     *      identity and the fact that it was already true at genesis, so "preserved" is a real claim.
     *
     *      Tolerance: the hedge is exact in the sizing math and inexact only in CL integer rounding —
     *      `getLiquidityForAmounts` truncates to a uint128 L and `getAmountsForLiquidity` truncates each
     *      leg back out, so the realised LP leg can sit a few wei-in-L under the desired pair. 0.1% rel
     *      is orders of magnitude above that and far below any economically meaningful drift.
     */
    function testAssetModeLeverUpReachesTargetAndPreservesDeltaNeutrality() public {
        _execute(SEED);

        // Genesis is already delta-neutral — the baseline the lever-up must preserve.
        assertApproxEqRel(
            _lpLegAAmount() + legA.balanceOf(address(strategy)),
            mLegA.borrowBalance(address(strategy)),
            1e15,
            "genesis: LP leg-A == leg-A debt (delta-neutral)"
        );

        uint16 newTarget = 6000;
        (uint256 expBorrow, uint256 expLpUsdc) = _expectedLeverUpPair(newTarget);
        assertGt(expLpUsdc, 0, "the op must actually need pairing USDC, or the test proves nothing");

        uint256 debtLegABefore = mLegA.borrowBalance(address(strategy));
        (uint256 collateralBefore,) = _collateralAndDebt();
        usdc.mint(address(strategy), expLpUsdc); // fund the draw

        vm.prank(proposer);
        strategy.adjustLeverage(newTarget, 0, 0);

        // 1. LTV reached the requested target. Tolerance 2 bps, and it is PHYSICAL, not slack: the debt
        //    delta is floor-divided into leg-A units at the 8dp feed price and the LTV is itself a floor
        //    division, so the realised LTV lands at or just under target (measured: 5999 for 6000).
        (uint256 collateralAfter, uint256 debtUsdcAfter) = _collateralAndDebt();
        assertEq(collateralAfter, collateralBefore, "collateral is untouched by a leverage retarget");
        assertApproxEqAbs((debtUsdcAfter * 10_000) / collateralAfter, uint256(newTarget), 2, "LTV == new target");

        // 2. Exactly the sized single leg-A borrow happened; leg B is still never borrowed.
        assertEq(mLegA.borrowBalance(address(strategy)) - debtLegABefore, expBorrow, "leg-A debt grew by exactly A");
        assertEq(mUsdc.borrowBalance(address(strategy)), 0, "leg B (the asset) is still never borrowed");

        // 3. DELTA-NEUTRALITY PRESERVED — the (a)-vs-(b) discriminator.
        uint256 lpLegA = _lpLegAAmount() + legA.balanceOf(address(strategy));
        uint256 debtLegA = mLegA.borrowBalance(address(strategy));
        assertApproxEqRel(lpLegA, debtLegA, 1e15, "post-lever-up: LP leg-A == leg-A debt (hedge preserved)");

        // 3b. Design (b) would have put only `debtLegA - swapped` of leg A into the LP. Pin that the
        //     realised LP leg is NOT short of the debt by anything like a funded fraction of ΔB.
        assertGt(lpLegA * 10_000, debtLegA * 9_990, "LP leg-A is not short of the debt (would be net short under (b))");
    }

    /// @dev The funding accounting: every USDC that left idle went into the LP (nothing leaked), the draw
    ///      is the derived `U′` (never more), and NAV is conserved — value MOVED from idle into the LP,
    ///      it was neither created nor destroyed. This is the "shrinks the redeem cover budget" property
    ///      the operator note is about, stated numerically.
    function testAssetModeLeverUpDrawsExactlyTheDerivedIdleAndConservesNav() public {
        _execute(SEED);

        (, uint256 expLpUsdc) = _expectedLeverUpPair(6000);
        usdc.mint(address(strategy), expLpUsdc + 500_000e6); // generous idle, so the draw is what bounds it

        uint256 idleBefore = usdc.balanceOf(address(strategy));
        uint256 npmUsdcBefore = usdc.balanceOf(address(npm));
        uint256 navBefore = strategy.nav();

        vm.prank(proposer);
        strategy.adjustLeverage(6000, 0, 0);

        uint256 drawn = idleBefore - usdc.balanceOf(address(strategy));
        assertEq(drawn, usdc.balanceOf(address(npm)) - npmUsdcBefore, "every drawn USDC went into the LP");
        assertLe(drawn, expLpUsdc, "the draw never exceeds the derived U'");
        assertApproxEqRel(drawn, expLpUsdc, 1e15, "the draw IS the derived U'");
        assertApproxEqRel(strategy.nav(), navBefore, 1e15, "NAV conserved: value moved from idle into the LP");
    }

    /// @dev Insufficient idle is a LOUD, DIAGNOSABLE refusal: the exact `(needed, available)` pair, the
    ///      whole op rolled back — never a partial fill and never a silent cap. One wei more idle and the
    ///      same call succeeds, which pins the boundary to the derived `U′` itself.
    function testAssetModeLeverUpRevertsWhenIdleIsInsufficientAndLeavesStateUntouched() public {
        _execute(SEED);

        (, uint256 needed) = _expectedLeverUpPair(6000);
        // Top idle up to exactly `needed - 1`.
        uint256 idle = usdc.balanceOf(address(strategy));
        assertLt(idle, needed, "genesis dust must be short of the draw");
        usdc.mint(address(strategy), needed - 1 - idle);

        uint256 debtBefore = mLegA.borrowBalance(address(strategy));
        uint256 collateralCBefore = mUsdc.balanceOf(address(strategy));
        uint256 tokenIdBefore = strategy.layout().tokenId;
        uint128 liqBefore = npm.liquidityOf(tokenIdBefore);

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAerodromeCLStrategy.InsufficientIdleForLeverUp.selector, needed, needed - 1)
        );
        strategy.adjustLeverage(6000, 0, 0);

        // State untouched — the check runs BEFORE the borrow, and the revert rolls back regardless.
        assertEq(mLegA.borrowBalance(address(strategy)), debtBefore, "no borrow happened");
        assertEq(mUsdc.balanceOf(address(strategy)), collateralCBefore, "collateral untouched");
        assertEq(usdc.balanceOf(address(strategy)), needed - 1, "idle untouched");
        assertEq(strategy.layout().tokenId, tokenIdBefore, "position untouched");
        assertEq(npm.liquidityOf(tokenIdBefore), liqBefore, "LP liquidity untouched");

        // One more wei of idle clears the bound — the boundary is exactly the derived U'.
        usdc.mint(address(strategy), 1);
        vm.prank(proposer);
        strategy.adjustLeverage(6000, 0, 0);
        assertGt(mLegA.borrowBalance(address(strategy)), debtBefore, "lever UP went through at exactly U' idle");
    }

    /// @dev A STORED range the price has since left is one-sided, so the lever-up pairing ratio cannot be
    ///      formed and it fails closed — the same `rerange`-first contract `deployIdle` has, and NOT an
    ///      unhedged single-sided add.
    function testAssetModeLeverUpFailsClosedWhenStoredRangeIsOneSided() public {
        _execute(SEED);
        usdc.mint(address(strategy), 500_000e6); // idle is NOT what blocks it

        int24 farTick = strategy.layout().posTickUpper + 5000;
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(farTick));
        pool.setTick(farTick);
        legAFeed.setAnswer(int256(_legAPriceFromSqrtP(pool.sqrtPriceX96())));

        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        strategy.adjustLeverage(6000, 0, 0);
    }

    // ==================== TARGET-LTV PERSISTENCE (asset-mode) ====================

    /// @dev `adjustLeverage` sets the fund's STANDING target, both directions — the same contract
    ///      `rerange` has for `width`. The dedicated getter and `layout()` are the same storage read,
    ///      so they are asserted together at every step: they can never legitimately disagree.
    function testAdjustLeveragePersistsTheStandingTarget() public {
        _execute(SEED);
        assertEq(strategy.targetLtvBps(), TARGET_LTV_BPS, "genesis: the init target IS the standing target");
        assertEq(strategy.layout().targetLtvBps, TARGET_LTV_BPS, "genesis: getter == layout()");

        // Lever UP persists.
        (, uint256 needed) = _expectedLeverUpPair(6000);
        usdc.mint(address(strategy), needed);
        vm.prank(proposer);
        strategy.adjustLeverage(6000, 0, 0);
        assertEq(strategy.targetLtvBps(), 6000, "lever UP persisted the new standing target");
        assertEq(strategy.layout().targetLtvBps, 6000, "getter == layout() after lever UP");

        // Lever DOWN persists too — the write is on the shared path, not the up-branch.
        vm.prank(proposer);
        strategy.adjustLeverage(3000, 0, 0);
        assertEq(strategy.targetLtvBps(), 3000, "lever DOWN persisted the new standing target");
        assertEq(strategy.layout().targetLtvBps, 3000, "getter == layout() after lever DOWN");
    }

    /**
     * @dev THE REGRESSION THIS FIXES, END TO END (asset-mode). Pre-fix, `adjustLeverage` consumed the
     *      target as a per-call parameter and never stored it, so the retarget held only until the next
     *      redeploy: `deployIdle` re-read the STALE stored 5000, sized its collateral/borrow split at
     *      5000, and silently dragged realized LTV back down off the 6000 the rebalancer had just set.
     *
     *      The discriminator is the sizing itself, not just the end LTV: `C` at 6000 (`topUp/1.6`) and
     *      `C` at 5000 (`topUp/1.5`) are different numbers, and the test pins which one the chain used.
     *      It then computes the LTV the stale sizing WOULD have produced and asserts it is materially
     *      lower — so a future regression can't pass by accident on a loose tolerance.
     */
    function testDeployIdleAfterAdjustLeverageSizesAtTheNewTarget() public {
        _execute(SEED);

        // 1. Retarget to 6000 and confirm the position really got there.
        (, uint256 needed) = _expectedLeverUpPair(6000);
        usdc.mint(address(strategy), needed);
        vm.prank(proposer);
        strategy.adjustLeverage(6000, 0, 0);

        (uint256 collateralBefore, uint256 debtBefore) = _collateralAndDebt();
        assertApproxEqAbs((debtBefore * 10_000) / collateralBefore, 6000, 2, "the retarget landed at 6000");

        // 2. Redeploy fresh idle. The two candidate sizings must differ, or this proves nothing.
        uint256 topUp = 250_000e6;
        usdc.mint(address(strategy), topUp);
        int24 tickLower = strategy.layout().posTickLower;
        int24 tickUpper = strategy.layout().posTickUpper;
        (uint256 expCNew,,) = _expectedSplitAtLtv(topUp, tickLower, tickUpper, 6000);
        (uint256 expCStale,,) = _expectedSplitAtLtv(topUp, tickLower, tickUpper, TARGET_LTV_BPS);
        assertTrue(expCNew != expCStale, "the new-target and stale-target sizings must differ");

        vm.prank(proposer);
        strategy.deployIdle(topUp, 0);

        // 3. The redeploy sized off the PERSISTED 6000 — this is the assertion that fails pre-fix.
        (uint256 collateralAfter, uint256 debtAfter) = _collateralAndDebt();
        assertEq(collateralAfter - collateralBefore, expCNew, "deployIdle sized C at the NEW standing target");
        assertApproxEqAbs(
            (debtAfter * 10_000) / collateralAfter, 6000, 3, "realized LTV HELD at 6000 (not dragged back to 5000)"
        );

        // 4. The pre-fix drag as a number: sizing this same top-up at the stale 5000 would have blended
        //    realized LTV down to ~5800, i.e. ~200 bps of silent fight with the rebalancer.
        uint256 staleLtv =
            ((debtBefore + (uint256(TARGET_LTV_BPS) * expCStale) / 10_000) * 10_000) / (collateralBefore + expCStale);
        assertLt(staleLtv, 5900, "the stale-target sizing really would have dragged realized LTV down");
    }

    /// @dev An out-of-band target is refused at the entrypoint and stores NOTHING — the persist sits
    ///      behind the `targetLtvBps_ <= maxLtvBps` gate, so a rejected value can never become the
    ///      standing target that later redeploys size at.
    function testAdjustLeverageAboveMaxRevertsAndLeavesTheStoredTargetUntouched() public {
        _execute(SEED);
        usdc.mint(address(strategy), 500_000e6); // idle is NOT what blocks it

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvExceedsMax.selector);
        strategy.adjustLeverage(6501, 0, 0); // maxLtvBps == 6500

        assertEq(strategy.targetLtvBps(), TARGET_LTV_BPS, "a rejected target stores nothing");
        assertEq(strategy.layout().targetLtvBps, TARGET_LTV_BPS, "layout() agrees: still the init target");

        // And the standing target is still what a redeploy sizes at.
        uint256 topUp = 100_000e6;
        usdc.mint(address(strategy), topUp);
        (uint256 expC,,) =
            _expectedSplitAtLtv(topUp, strategy.layout().posTickLower, strategy.layout().posTickUpper, TARGET_LTV_BPS);
        (uint256 collateralBefore,) = _collateralAndDebt();
        vm.prank(proposer);
        strategy.deployIdle(topUp, 0);
        (uint256 collateralAfter,) = _collateralAndDebt();
        assertEq(collateralAfter - collateralBefore, expC, "redeploy still sized at the untouched init target");
    }

    // ==================== ASSET-MODE LEVER DOWN / DELEVERAGE (regression) ====================

    /// @dev Lever DOWN in asset-mode is unchanged by the lever-up work: the leg-B residual IS USDC and
    ///      flows straight into the leg-A cover, no idle is required, and the LTV falls.
    function testAdjustLeverageLeverDownStillWorksInAssetMode() public {
        _execute(SEED);

        uint256 debtBefore = mLegA.borrowBalance(address(strategy));
        vm.prank(proposer);
        strategy.adjustLeverage(3000, 0, 0);
        assertLt(mLegA.borrowBalance(address(strategy)), debtBefore, "lever DOWN reduced the leg-A debt");

        (uint256 collateral, uint256 debtUsdc) = _collateralAndDebt();
        assertLt((debtUsdc * 10_000) / collateral, uint256(TARGET_LTV_BPS), "LTV fell below the old target");
        assertApproxEqAbs((debtUsdc * 10_000) / collateral, 3000, 20, "LTV landed ~on the lower target");
    }

    /// @dev The PERMISSIONLESS safety valve still works in asset-mode. Health is pushed under
    ///      `minHealthBps` by halving the Moonwell collateral basis (prices untouched, so the LP stays
    ///      two-sided and the unwind's collected leg A covers the repay), then ANY address may rescue.
    function testPermissionlessDeleverageStillWorksInAssetMode() public {
        _execute(SEED);
        mUsdc.setExchangeRateStored(0.5e18);

        (uint256 collateralBefore, uint256 debtBefore) = _collateralAndDebt();
        uint256 healthBefore = (collateralBefore * 10_000) / debtBefore;
        assertLt(healthBefore, 12_000, "fixture must actually be unhealthy, or the valve would refuse");

        uint256 debtLegABefore = mLegA.borrowBalance(address(strategy));
        vm.prank(makeAddr("keeper")); // NOT the proposer — this path is permissionless by design
        strategy.deleverage(0);

        assertLt(mLegA.borrowBalance(address(strategy)), debtLegABefore, "the keeper repaid leg-A debt");
        (uint256 collateralAfter, uint256 debtAfter) = _collateralAndDebt();
        uint256 healthAfter = (collateralAfter * 10_000) / debtAfter;
        assertGt(healthAfter, healthBefore, "health strictly improved");
        assertGe(healthAfter, 12_000, "health restored above the minimum");
    }

    // ==================== THE CRUX INVARIANT ====================

    /**
     * @dev THE CRUX. A partial redeem in asset-mode must not pay the redeemer out of the stayers'
     *      reserved idle USDC.
     *
     *      In this shape the unwind sheds REAL USDC (the LP's USDC leg) straight into the balance the
     *      reservation is computed from. That LP-shed USDC is 100% the redeemer's — only their `f` of the
     *      liquidity was removed — so the reservation MUST be `(1-f) x idle_BEFORE_the_unwind`. Taking it
     *      after the unwind would reserve `(1-f)` of the LP-shed USDC for stayers too and silently
     *      under-pay the redeemer.
     *
     *      The test pins the retained balance to the wei and then proves it is DISCRIMINATING: the
     *      post-unwind rule would have retained strictly more.
     */
    function testPartialRedeemReservesStayerIdleOffThePreUnwindSnapshot() public {
        _execute(SEED);

        // Give the book undeployed idle USDC (an un-deployed deposit) — the balance under contention.
        uint256 idleSeed = 200_000e6;
        usdc.mint(address(strategy), idleSeed);

        // Shares: mint supply through the vault hook, escrow a quarter of it for redemption.
        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        uint256 shares = supply / 4; // f = 1/4

        // Snapshot the pre-redeem state the invariant is stated over.
        uint256 idlePre = usdc.balanceOf(address(strategy));
        uint256 lpShedUsdc = _lpShedUsdc(shares, supply);
        assertGt(lpShedUsdc, 0, "fixture must actually shed LP USDC, or the test proves nothing");

        vm.prank(lp);
        vault.approve(address(strategy), shares);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(shares, 0);

        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.prank(proposer);
        strategy.fulfillRedeem(id);
        uint256 paid = usdc.balanceOf(lp) - lpUsdcBefore;

        // 1. EXACT reservation off the PRE-unwind snapshot.
        uint256 reservedExpected = idlePre - Math.mulDiv(idlePre, shares, supply);
        assertEq(
            usdc.balanceOf(address(strategy)),
            reservedExpected,
            "stayers must retain exactly (1-f) x PRE-unwind idle USDC"
        );

        // 2. The test DISCRIMINATES: the post-unwind rule would have retained strictly more, i.e. it
        //    would have skimmed (1-f) of the redeemer's own LP-shed USDC into the stayer reserve.
        uint256 reservedIfPostUnwindSnapshot =
            (idlePre + lpShedUsdc) - Math.mulDiv(idlePre + lpShedUsdc, shares, supply);
        assertGt(
            reservedIfPostUnwindSnapshot,
            reservedExpected,
            "fixture must separate the two rules (LP-shed USDC inflates the post-unwind balance)"
        );

        // 3. The redeemer therefore received the FULL LP-shed USDC, not just f of it.
        assertGt(paid, Math.mulDiv(idlePre, shares, supply), "payout exceeds the redeemer's idle share alone");
        assertGt(
            paid,
            reservedIfPostUnwindSnapshot - reservedExpected,
            "payout includes the LP-shed USDC the wrong rule would have withheld"
        );
    }

    /**
     * @dev Companion to the crux: every leg-B (== USDC) swap must be the IDENTITY, i.e. never routed.
     *      Without the early-returns in `_sweepLegToUsdc` / `_swapUsdcExactIn` / `_redeemCoverShortfall`
     *      the redeem would look up a USDC/USDC swap pool — which does not exist — and either revert or
     *      route at an unrelated venue.
     *
     *      The proof is airtight by CONSTRUCTION rather than by balance-watching: no USDC→USDC rate is
     *      ever registered on the router, and an unregistered pair REVERTS (`MockRouterNoRate`, asserted
     *      directly below). A full partial-redeem cycle therefore completing is proof that no USDC→USDC
     *      leg was attempted. The leg-A legs are separately shown to have really happened, so the test
     *      cannot pass by the router simply going unused.
     */
    function testAssetLegSwapsAreTheIdentityAndNeverRouted() public {
        // The router rejects the pair the guards must never request.
        assertEq(router.rateE18(address(usdc), address(usdc)), 0, "no USDC->USDC rate is configured");
        vm.expectRevert(MockClSwapRouter.MockRouterNoRate.selector);
        router.exactInputSingle(
            MockClSwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(usdc),
                tickSpacing: LEG_A_SWAP_SPACING,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: 1e6,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        _execute(SEED);
        usdc.mint(address(strategy), 200_000e6);

        uint256 supply = 1_000_000e12;
        vm.prank(address(strategy));
        vault.strategyMint(lp, supply);
        uint256 shares = supply / 4;

        uint256 routerLegABefore = legA.balanceOf(address(router));

        vm.prank(lp);
        vault.approve(address(strategy), shares);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(shares, 0);
        vm.prank(proposer);
        strategy.fulfillRedeem(id); // completes ⇒ no USDC->USDC leg was ever requested

        // The router WAS exercised on the leg-A side, so the pass above is not vacuous.
        assertTrue(legA.balanceOf(address(router)) != routerLegABefore, "the leg-A swap leg really executed");
        assertEq(usdc.allowance(address(strategy), address(router)), 0, "no dangling USDC approval to the router");
    }

    /// @dev A FULL redeem in asset-mode must clear the book: leg-A debt to zero, collateral to zero, and
    ///      the flat-book invariant (`tokenId == 0`) restored so `nav()` takes its oracle-free branch.
    function testFullRedeemClearsTheBookInAssetMode() public {
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

        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "collateral fully redeemed");
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant restored");
        assertApproxEqRel(usdc.balanceOf(lp), SEED, 5e16, "redeemer recovered ~the whole book");
    }

    /**
     * @dev The vault-driven full exit (`settle`) in asset-mode. Its residual sweep asks for BOTH legs,
     *      and the leg-B ask is USDC→USDC: it must no-op rather than route (no USDC/USDC rate is
     *      registered on the router, so a routed attempt would revert). Everything realised must land on
     *      the VAULT, with the book flat.
     */
    function testSettleClearsTheBookAndSweepsOnlyTheRealLeg() public {
        _execute(SEED);
        usdc.mint(address(strategy), 50_000e6); // some undeployed idle to be swept out too

        vm.prank(address(vault));
        strategy.settle(); // completes ⇒ the leg-B (USDC→USDC) sweep no-opped

        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg-A debt cleared");
        assertEq(mUsdc.borrowBalance(address(strategy)), 0, "no leg-B debt ever existed");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "collateral fully redeemed");
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant restored");
        assertEq(usdc.balanceOf(address(strategy)), 0, "everything pushed to the vault");
        assertApproxEqRel(usdc.balanceOf(address(vault)), SEED + 50_000e6, 5e16, "vault received ~the whole book");
    }

    /// @dev The USDC the unwind of `f` of the liquidity will shed into the strategy — computed from the
    ///      same geometry the production path uses, so the crux test can state the two competing rules.
    function _lpShedUsdc(uint256 shares, uint256 supply) internal view returns (uint256 shed0) {
        uint128 liq = npm.liquidityOf(strategy.layout().tokenId);
        uint128 toRemove = uint128(Math.mulDiv(uint256(liq), shares, supply));
        (shed0,) = LiquidityAmounts.getAmountsForLiquidity(
            pool.sqrtPriceX96(),
            TickMath.getSqrtRatioAtTick(strategy.layout().posTickLower),
            TickMath.getSqrtRatioAtTick(strategy.layout().posTickUpper),
            toRemove
        );
    }
}
