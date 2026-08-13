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
 * @title compound(): borrow-interest re-hedge, genuine-no-op, and the fee-timing contract
 * @notice The first suite in this tree that drives a REAL `compound` end to end (the pre-existing ones
 *         only reached the flat-book bail, because the AERO→USDC leg routes through a hardcoded mainnet
 *         Aerodrome-v2 router address). `MockAeroV2Router` is etched at that address, so the whole
 *         claim → swap → skim → re-hedge → redeploy sequence runs against custodial venue mocks.
 *
 *         THE THREE THINGS UNDER TEST:
 *
 *         1. RE-HEDGE (the main one). Borrow interest grows the debt leg without growing the LP leg, so
 *            before the fix every harvest left the book a little more SHORT and nothing ever removed it.
 *            `compound` now measures the drift as `borrowBalanceStored − Layout.hedgedDebtA/B`, buys it
 *            back out of harvest proceeds, and repays it.
 *
 *         2. DISCRIMINATION (the test that proves the measure is right). A CL position's leg mix moves
 *            with price by design, so `debt − lpLeg` is NOT the drift: it also contains the LP mechanism
 *            working as intended. `testCompoundDoesNotChaseAPriceDrivenLegDivergence` moves the price
 *            with ZERO interest accrued and pins that `compound` buys nothing — the whole point of using
 *            an accounting basis rather than the live LP composition.
 *
 *         3. NO-OP + FEE TIMING. A keeper-polled `compound` with nothing to harvest must not crystallise
 *            (it would mint fee-shares and ratchet the HWM for free), and a real harvest's performance
 *            fee is DEFERRED to the next crystallisation point by design — proven here, not assumed.
 *
 * @dev Fixture: the asset-as-a-leg shape (leg A is an 8dp volatile token, the pair is legA/USDC), the
 *      shape the live fork run that produced these findings was running. The pool `sqrtP` and the leg-A
 *      Chainlink price are kept mutually consistent by deriving the price from `sqrtP`. Management fee
 *      is OFF and the performance fee is ON, so every fee assertion here is about the HWM leg only.
 */
contract LeveragedAeroCompoundHedgeUnitTest is Test {
    // ── Roles ──
    address internal owner = makeAddr("owner");
    address internal proposer = makeAddr("proposer");
    address internal lp = makeAddr("lp");
    address internal feeRecipient = makeAddr("feeRecipient");

    // ── Tokens ──
    MockToken internal usdc; // 6dp — unit of account AND the leg-B slot (asset-mode)
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
    LeveragedAerodromeCLStrategy internal strategy;

    /// @dev The Aerodrome v2 Router address `LeveragedAeroManager` hardcodes for the AERO→USDC swap.
    address internal constant AERO_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    int24 internal constant SPACING = 100;
    int24 internal constant LEG_A_SWAP_SPACING = 200;
    /// @dev Leg A is token1, so the raw pool price is "leg-A units per USDC unit" — a ~$100k token needs
    ///      a negative tick (`ln(1e-3)/ln(1.0001) ≈ -69078`), aligned to the grid.
    int24 internal constant TICK = -69_100;
    uint24 internal constant WIDTH = 4000;
    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;
    uint16 internal constant PERF_FEE_BPS = 1000; // 10% — the only fee armed
    uint8 internal constant LEG_A_DECIMALS = 8;
    uint256 internal constant P_USDC = 1e8;
    uint256 internal constant P_AERO = 1e8; // $1/AERO, so USDC out == AERO in / 1e12
    uint256 internal constant Q96 = 1 << 96;

    uint256 internal constant SEED = 1_000_000e6; // $1M genesis
    uint256 internal constant SHARES = 1_000_000e12; // vault shares outstanding (12dp)

    /// @dev Leg-A price (8dp) implied by the pool's `sqrtP` for this fixture's ordering (legA = token1).
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
        vm.warp(1_800_000_000);

        usdc = new MockToken("USD Coin", "USDC", 6);
        legA = new MockToken("Leg A", "LEGA", LEG_A_DECIMALS);
        aero = new MockToken("Aerodrome", "AERO", 18);

        pool = new MockCLPool(address(usdc), address(legA), SPACING);
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK));
        pool.setTick(TICK);
        clFactory = MockCLFactory(AERODROME_CL_FACTORY);
        vm.etch(AERODROME_CL_FACTORY, address(new MockCLFactory()).code);
        pool.setFactory(AERODROME_CL_FACTORY);
        clFactory.setPool(address(legA), address(usdc), SPACING, address(pool));
        clFactory.setPool(address(usdc), address(legA), LEG_A_SWAP_SPACING, makeAddr("legASwapPool"));

        legAPrice8 = _legAPriceFromSqrtP(pool.sqrtPriceX96());

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

        sequencerFeed = new MockChainlinkFeed(0, 8, 1, block.timestamp - 2 hours);
        usdcFeed = new MockChainlinkFeed(int256(P_USDC), 8, 1, block.timestamp);
        legAFeed = new MockChainlinkFeed(int256(legAPrice8), 8, 1, block.timestamp);
        aeroFeed = new MockChainlinkFeed(int256(P_AERO), 8, 1, block.timestamp);

        // Venue float.
        usdc.mint(address(mUsdc), 100_000_000e6);
        legA.mint(address(mLegA), 1_000_000e8);
        usdc.mint(address(router), 100_000_000e6);
        legA.mint(address(router), 1_000_000e8);
        _setClRouterRates();

        // Place the Aerodrome-v2 router mock at the address the manager hardcodes, and fund it.
        // All of its config is `immutable`, so it survives the code copy (see the harness note).
        MockAeroV2Router aeroRouterImpl = new MockAeroV2Router(address(aero), address(usdc), 1e6);
        vm.etch(AERO_V2_ROUTER, address(aeroRouterImpl).code);
        usdc.mint(AERO_V2_ROUTER, 100_000_000e6);

        vault = new LeveragedAeroVault(address(usdc), owner, "Leveraged Aero Vault", "lvAERO");
        strategy = LeveragedAerodromeCLStrategy(payable(Clones.clone(address(new LeveragedAerodromeCLStrategy()))));
        strategy.initialize(address(vault), proposer, abi.encode(_params()));

        vm.startPrank(owner);
        vault.setStrategy(address(strategy));
        vault.setOpenDeposits(true);
        vm.stopPrank();
    }

    // ==================== FIXTURE HELPERS ====================

    /// @dev Inverse of `oracleSqrtPriceX96` for this fixture (leg A is token1, the asset is token0/6dp):
    ///      `raw = pUsdc·10^dA / (pA·1e6)` ⇒ `pA = 100·10^dA / raw`.
    function _legAPriceFromSqrtP(uint160 sqrtP) internal pure returns (uint256) {
        uint256 rawQ96 = Math.mulDiv(sqrtP, sqrtP, Q96);
        return Math.mulDiv(100 * (10 ** uint256(LEG_A_DECIMALS)), Q96, rawQ96);
    }

    /// @dev Oracle-consistent CL-router rates in BOTH directions at the CURRENT `legAPrice8`. Re-called
    ///      after a price move so the hedge buy is priced at the same mark the oracle floor uses.
    function _setClRouterRates() internal {
        router.setRate(address(legA), address(usdc), (legAPrice8 * 1e18) / (100 * 10 ** uint256(LEG_A_DECIMALS)));
        router.setRate(address(usdc), address(legA), (100 * 10 ** uint256(LEG_A_DECIMALS) * 1e18) / legAPrice8);
    }

    /// @dev USDC face (6dp) of `amt` leg-A units, on the manager's own `_tokenToUsdc` basis.
    function _legAValueUsdc(uint256 amt) internal view returns (uint256) {
        return (amt * legAPrice8 * 1e6) / ((10 ** uint256(LEG_A_DECIMALS)) * P_USDC);
    }

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
        p.cbBTCFeed = address(usdcFeed);
        p.wethFeed = address(legAFeed);
        p.usdcFeed = address(usdcFeed);
        p.sequencerFeed = address(sequencerFeed);
        p.aeroUsdFeed = address(aeroFeed);
        p.maxDelay = 1 hours;
        p.gracePeriod = 1 hours;
        p.calmDeviationTicks = 100;
        p.twapWindow = 600;
        p.tickSpacing = SPACING;
        p.cbBTCSwapTickSpacing = 0;
        p.wethSwapTickSpacing = LEG_A_SWAP_SPACING;
        p.wethDeliversNative = false;
        p.width = WIDTH;
        p.minWidth = 200;
        p.maxWidth = 20_000;
        p.targetLtvBps = TARGET_LTV_BPS;
        p.maxLtvBps = 6500;
        p.minHealthBps = 12_000;
        p.maxSlippageBps = MAX_SLIPPAGE_BPS;
        p.managementFeeBps = 0; // OFF — every fee assertion here is about the HWM leg
        p.performanceFeeBps = PERF_FEE_BPS;
        p.feeRecipient = feeRecipient;
    }

    /// @dev Open the position AND put vault shares outstanding, so `_crystallizeFees` is live (it
    ///      early-returns on a zero supply).
    function _armBook() internal {
        usdc.mint(address(strategy), SEED);
        vm.prank(address(vault));
        strategy.execute();
        vm.prank(address(strategy));
        vault.strategyMint(lp, SHARES);
    }

    /// @dev Make `aeroAmt` of AERO claimable AND payable: `earned()` is what the strategy's no-op probe
    ///      reads, `aeroToPayOnGetReward` is what the claim actually transfers. They must agree.
    function _armRewards(uint256 aeroAmt) internal {
        aero.mint(address(gauge), aeroAmt);
        gauge.setAeroToPayOnGetReward(aeroAmt);
        gauge.setEarnedAmount(aeroAmt);
    }

    function _clearRewards() internal {
        gauge.setAeroToPayOnGetReward(0);
        gauge.setEarnedAmount(0);
    }

    /// @dev USDC the AERO→USDC leg realises for `aeroAmt`: $1/AERO, 18dp → 6dp.
    function _usdcFromAero(uint256 aeroAmt) internal pure returns (uint256) {
        return aeroAmt / 1e12;
    }

    /// @dev Leg-A units the live CL position holds, at the pool `sqrtP` and the STORED range (leg A is
    ///      token1 in this fixture, so it is the `amount1` side).
    function _lpLegAAmount() internal view returns (uint256 legAAmt) {
        (, legAAmt) = LiquidityAmounts.getAmountsForLiquidity(
            pool.sqrtPriceX96(),
            TickMath.getSqrtRatioAtTick(strategy.layout().posTickLower),
            TickMath.getSqrtRatioAtTick(strategy.layout().posTickUpper),
            npm.liquidityOf(strategy.layout().tokenId)
        );
    }

    function _debtLegA() internal view returns (uint256) {
        return mLegA.borrowBalance(address(strategy));
    }

    /// @dev THE DRIFT MEASURE the production code uses: live debt minus the hedged principal basis.
    ///      This is the number that must return to ~0 after a harvest, and must stay 0 across a pure
    ///      price move.
    function _driftLegA() internal view returns (uint256) {
        (uint128 hedgedA,) = strategy.hedgedDebt();
        uint256 debt = _debtLegA();
        return debt > hedgedA ? debt - hedgedA : 0;
    }

    /// @dev THE TRUE DRIFT: the FULLY ACCRUED debt (including interest that no transaction has folded into
    ///      the market's `borrowIndex` yet) minus the hedged basis. `_driftLegA` above is the same measure
    ///      on the STALE stored basis. The two are equal except while un-accrued interest is outstanding,
    ///      and that gap is exactly what `testCompoundHedgesInterestTheStoredIndexCannotYetSee` is about.
    function _trueDriftLegA() internal view returns (uint256) {
        (uint128 hedgedA,) = strategy.hedgedDebt();
        uint256 debt = mLegA.borrowBalanceAccrued(address(strategy));
        return debt > hedgedA ? debt - hedgedA : 0;
    }

    function _collateralUsdc() internal view returns (uint256) {
        return (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18;
    }

    /// @dev Move the pool (spot AND twap, so the calm-gate stays open) to `newTick` and re-derive the
    ///      leg-A oracle price + router rates from the new `sqrtP`, keeping the whole fixture mutually
    ///      consistent exactly as `setUp` does.
    function _movePriceTo(int24 newTick) internal {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(newTick);
        pool.setSqrtPriceX96(sqrtP);
        pool.setTick(newTick);
        pool.setTwapTick(newTick);
        legAPrice8 = _legAPriceFromSqrtP(sqrtP);
        legAFeed.setAnswer(int256(legAPrice8));
        _setClRouterRates();
    }

    /// @dev Re-stamp every feed as fresh. Needed after any `vm.warp` past `maxDelay` (1 hour here),
    ///      otherwise the hardened reader correctly fails closed with `StaleOracle`.
    function _refreshFeeds() internal {
        usdcFeed.setUpdatedAt(block.timestamp);
        legAFeed.setUpdatedAt(block.timestamp);
        aeroFeed.setUpdatedAt(block.timestamp);
        sequencerFeed.setStartedAt(block.timestamp - 2 hours);
    }

    function _compound(uint256 minUsdcOut) internal {
        vm.prank(proposer);
        strategy.compound(minUsdcOut, 0);
    }

    // ==================== 1. THE RE-HEDGE ====================

    /**
     * @dev THE CORE ASSERTION. Accrue borrow interest on the leg-A market (debt grows, the LP does not),
     *      then harvest. Before the fix the hedge gap widened by the full accrual on every single
     *      harvest and nothing removed it; now `compound` buys the accrual back and repays it, so the
     *      gap returns to ~0 and the LP leg matches the debt leg again.
     */
    function testCompoundRehedgesAccruedBorrowInterest() public {
        _armBook();

        // A genesis book is hedged to the wei: the LP holds exactly what was borrowed.
        assertEq(_driftLegA(), 0, "genesis book carries no interest drift");
        (uint128 hedgedAtGenesis,) = strategy.hedgedDebt();
        assertEq(uint256(hedgedAtGenesis), _debtLegA(), "hedged basis == debt at genesis");
        assertApproxEqRel(_lpLegAAmount(), _debtLegA(), 1e15, "LP leg A == leg-A debt at genesis (delta-neutral)");

        // ── Interest accrues: 50 bps of the debt, with NO token movement and NO LP change ──
        uint256 interest = _debtLegA() / 200;
        assertGt(interest, 0, "fixture must produce a measurable accrual");
        mLegA.accrueBorrowInterest(address(strategy), interest);

        // The gap is now exactly the accrual, and it is a real unintended SHORT.
        assertEq(_driftLegA(), interest, "drift == the accrued interest, exactly");
        // (Tolerance 2 units = 1e-8 leg-A tokens: the genesis mint rounds the LP leg down by dust.)
        assertApproxEqAbs(_debtLegA() - _lpLegAAmount(), interest, 2, "the book is short by the accrual");
        uint256 interestValueUsdc = _legAValueUsdc(interest);

        // ── Harvest, with proceeds comfortably larger than the accrual ──
        uint256 aeroAmt = 20_000e18; // $20k of AERO vs a ~$1k accrual
        _armRewards(aeroAmt);
        uint256 proceeds = _usdcFromAero(aeroAmt);
        assertGt(proceeds, interestValueUsdc * 2, "fixture must fund the whole hedge and still redeploy");

        uint256 navBeforeHarvest = strategy.nav();
        uint256 routerUsdcBefore = usdc.balanceOf(address(router));
        _compound(1);

        // THE ASSERTION: the gap is closed. Tolerance is integer-division dust on the two-way oracle
        // conversion (spend is floored, then the min-out re-derived from it) — 1e-6 of a leg-A token.
        assertApproxEqAbs(_driftLegA(), 0, 100, "interest drift neutralised");
        (uint128 hedgedAfter,) = strategy.hedgedDebt();
        assertApproxEqAbs(_debtLegA(), uint256(hedgedAfter), 100, "debt back down onto the hedged basis");
        // ...and the debt leg matches the LP leg again, which is what delta-neutral MEANS here.
        assertApproxEqRel(
            _lpLegAAmount() + legA.balanceOf(address(strategy)),
            _debtLegA(),
            1e15,
            "LP leg A (+ any idle dust) == leg-A debt: the hedge is restored"
        );

        // THE COST IS NAV DRAG, NOT EXPOSURE. The buy-and-repay is itself equity-neutral (USDC out,
        // an equal slug of debt cancelled), so NAV lands at `pre + proceeds`: the accrual's cost was
        // already taken when the debt grew, and the harvest simply reinvested less.
        assertApproxEqRel(
            strategy.nav(), navBeforeHarvest + proceeds, 1e15, "harvest adds proceeds; hedge is NAV-neutral"
        );
        // The USDC that funded the hedge left the book through the leg-A buy, bounded by the oracle.
        uint256 hedgeSpend = usdc.balanceOf(address(router)) - routerUsdcBefore;
        assertApproxEqRel(hedgeSpend, interestValueUsdc, 1e15, "spend == the oracle value of the accrual");
        assertLt(hedgeSpend, proceeds, "the hedge is funded ENTIRELY out of harvest proceeds");
    }

    /**
     * @dev REGRESSION — THE STALE-INDEX HEDGE. Identical in shape to the test above, with ONE difference
     *      that is the entire point: the interest is armed as UN-ACCRUED
     *      (`accruePendingBorrowInterest`, not `accrueBorrowInterest`). It exists in wall-clock time, but
     *      no transaction has folded it into the leg market's `borrowIndex` yet — which is the NORMAL state
     *      of that market at the top of a `compound` tx, because nothing earlier in the tx accrues it:
     *      `nav()` is a view, and neither the gauge claim nor the AERO→USDC swap touches Moonwell.
     *
     *      A hedge that measured `borrowBalanceStored` therefore saw a drift of ~0 and bought ~nothing,
     *      while the interest was capitalised moments LATER — by the hedge's own `repayBorrow` and by
     *      `deployIdleImpl`'s borrow, both strictly after the measurement. Live-fork numbers behind this
     *      test: `borrowBalanceStored` 76,853,210 vs `borrowBalanceCurrent` 76,868,617, so 15,407 of 15,412
     *      accrued sats were invisible and that harvest hedged 4 of them. The residual was bounded at one
     *      inter-harvest period (harvest #2 saw the by-then-capitalised interest and hedged it exactly), so
     *      it did not grow without bound — but "drift ≈ 0 after a harvest" was false, and the first harvest
     *      after any quiet period hedged essentially nothing.
     *
     *      THIS TEST FAILS ON THE PRE-FIX CODE (`borrowBalanceStored` in `LeveragedAeroValuation._hedgeLeg`)
     *      and passes with `borrowBalanceCurrent`. The suite could not previously express the condition at
     *      all: the market mock stored a single debt scalar, so stored and current were equal by
     *      construction — see the header on `MockLendingMarket`.
     */
    function testCompoundHedgesInterestTheStoredIndexCannotYetSee() public {
        _armBook();
        uint256 debtAtGenesis = _debtLegA();
        assertEq(_driftLegA(), 0, "genesis book carries no interest drift");

        // ── Interest accrues in WALL-CLOCK time; nothing has accrued the market ──
        uint256 interest = debtAtGenesis / 200; // 50 bps of the debt
        assertGt(interest, 0, "fixture must produce a measurable accrual");
        mLegA.accruePendingBorrowInterest(address(strategy), interest);

        // THE SETUP THE OLD MOCK COULD NOT EXPRESS. The debt is really there, and the stored read cannot
        // see it: `_driftLegA()` is what the pre-fix `_hedgeLeg` measured, `_trueDriftLegA()` is the truth.
        assertEq(_debtLegA(), debtAtGenesis, "borrowBalanceStored is UNCHANGED - the index is stale");
        assertEq(_driftLegA(), 0, "...so the stale drift measure sees NOTHING to hedge");
        assertApproxEqAbs(_trueDriftLegA(), interest, 2, "...but the TRUE drift is the whole accrual");
        uint256 interestValueUsdc = _legAValueUsdc(interest);

        // ── Harvest, with proceeds comfortably larger than the accrual ──
        uint256 aeroAmt = 20_000e18; // $20k of AERO vs a ~$1.6k accrual
        _armRewards(aeroAmt);
        assertGt(_usdcFromAero(aeroAmt), interestValueUsdc * 2, "fixture must fund the whole hedge");

        uint256 routerUsdcBefore = usdc.balanceOf(address(router));
        uint256 legAInRouterBefore = legA.balanceOf(address(router));
        _compound(1);

        // THE ASSERTION: the FULL accrued drift was neutralised, not merely the capitalised part. By now the
        // hedge's repay and the redeploy's borrow have both capitalised, so stored == accrued and the two
        // measures agree; PRE-FIX both land at ~`interest` instead of ~0.
        assertApproxEqAbs(_trueDriftLegA(), 0, 100, "the FULL accrued drift was hedged");
        assertApproxEqAbs(_driftLegA(), 0, 100, "...and the now-capitalised book agrees");

        // The spend proves it independently: ~the oracle value of the WHOLE accrual left the book through
        // the leg-A buy, and leg A really was bought. Pre-fix BOTH of these are zero.
        uint256 hedgeSpend = usdc.balanceOf(address(router)) - routerUsdcBefore;
        assertApproxEqRel(hedgeSpend, interestValueUsdc, 1e15, "spend == the oracle value of the FULL accrual");
        assertLt(legA.balanceOf(address(router)), legAInRouterBefore, "the router paid out leg A: a buy happened");

        // ...and the delta-hedge is restored: the LP leg (plus any idle dust) matches the debt leg again.
        assertApproxEqRel(
            _lpLegAAmount() + legA.balanceOf(address(strategy)),
            _debtLegA(),
            1e15,
            "LP leg A (+ idle dust) == leg-A debt: the hedge is restored"
        );
    }

    /**
     * @dev THE DISCRIMINATION TEST — the single most important one here. With ZERO interest accrued,
     *      move the price so the CL position legitimately sheds leg A (it sold into the rise). That
     *      makes `debt − lpLegA` large and positive, which is the LP mechanism working as intended, NOT
     *      a hedge error. A `compound` that closed `debt − lpLegA` would buy leg A precisely as leg A
     *      rises — a momentum-chasing delta rebalancer fighting its own LP. It must buy NOTHING.
     */
    function testCompoundDoesNotChaseAPriceDrivenLegDivergence() public {
        _armBook();
        assertEq(_driftLegA(), 0, "no interest accrued");

        // Leg A APPRECIATES. Leg A is token1 and the raw pool price is "leg-A units per USDC unit", so
        // a LOWER tick means fewer leg-A units per USDC, i.e. a dearer leg A. The LP sells leg A into
        // that rise and its leg-A amount falls; `debt` is untouched.
        _movePriceTo(TICK - 400);

        uint256 debtBefore = _debtLegA();
        uint256 lpLegABefore = _lpLegAAmount();
        uint256 priceGap = debtBefore - lpLegABefore;
        assertGt(priceGap, debtBefore / 100, "the price move opened a MATERIAL leg gap (>1% of debt)");
        assertEq(_driftLegA(), 0, "...but the INTEREST drift is still exactly zero");

        // Harvest with proceeds sized at TWICE the cost of closing that whole gap (derived, not
        // hardcoded, so the fixture cannot drift into under-funding it) — the only reason not to close it
        // is then that the code correctly refuses to.
        uint256 aeroAmt = _legAValueUsdc(priceGap) * 2 * 1e12;
        _armRewards(aeroAmt);
        assertGt(_usdcFromAero(aeroAmt), _legAValueUsdc(priceGap), "budget could have closed the whole gap");

        uint256 legAInRouterBefore = legA.balanceOf(address(router));
        _compound(1);

        // NOT ONE UNIT OF LEG A WAS BOUGHT. The CL router pays leg A out of its own balance on a
        // USDC→legA fill, so an unchanged balance is proof no hedge buy was routed.
        assertEq(legA.balanceOf(address(router)), legAInRouterBefore, "compound bought NO leg A");
        // Debt only ever went UP (the redeploy's new borrow) — never repaid down toward the LP.
        assertGt(_debtLegA(), debtBefore, "debt grew by the redeploy borrow only");
        assertEq(_driftLegA(), 0, "drift still zero: the price gap was never mistaken for interest");
        // The price-driven gap is still there, and CARRIED THROUGH EXACTLY: the redeploy borrows `x` of
        // leg A and pairs exactly `x` of it into the LP, so it moves both sides of the gap equally and
        // leaves the LP's own price response untouched — neither chased nor amplified.
        assertApproxEqAbs(
            _debtLegA() - _lpLegAAmount(), priceGap, 2, "the LP's own price response was carried through untouched"
        );
    }

    /**
     * @dev GRACEFUL DEGRADATION. Proceeds smaller than the accrual must hedge what they can and CARRY
     *      the rest — never revert the harvest (a bricked harvest on a live levered book is far worse
     *      than a partial hedge) and never reach past the harvest into stayers' idle USDC.
     */
    function testCompoundPartiallyHedgesWhenProceedsAreShortAndCarriesTheRemainder() public {
        _armBook();

        uint256 interest = _debtLegA() / 200;
        mLegA.accrueBorrowInterest(address(strategy), interest);
        uint256 interestValueUsdc = _legAValueUsdc(interest);

        // Park a large idle USDC balance in the book. It is NOT harvest proceeds, so the hedge must not
        // touch it even though it would easily cover the shortfall.
        uint256 stayerIdle = 500_000e6;
        usdc.mint(address(strategy), stayerIdle);

        // Proceeds worth ~20% of the accrual.
        uint256 aeroAmt = (interestValueUsdc / 5) * 1e12;
        _armRewards(aeroAmt);
        uint256 proceeds = _usdcFromAero(aeroAmt);
        assertLt(proceeds, interestValueUsdc, "fixture must under-fund the hedge");

        uint256 routerUsdcBefore = usdc.balanceOf(address(router));
        _compound(1); // must NOT revert

        uint256 hedgeSpend = usdc.balanceOf(address(router)) - routerUsdcBefore;
        assertApproxEqAbs(hedgeSpend, proceeds, 2, "spent the WHOLE budget and not one unit more");
        assertLe(hedgeSpend, proceeds, "bounded by harvest proceeds - stayers' idle untouched");

        // ~80% of the drift survives and is still MEASURED, so the next harvest resumes here.
        uint256 driftLeft = _driftLegA();
        assertGt(driftLeft, 0, "the unfunded remainder carries");
        assertApproxEqRel(driftLeft, (interest * 4) / 5, 1e16, "carried drift == the unfunded ~80%");

        // A second, well-funded harvest finishes the job — proving the carry is real, not written off.
        _armRewards(20_000e18);
        _compound(1);
        assertApproxEqAbs(_driftLegA(), 0, 100, "the carried remainder is cleared by the next harvest");
    }

    /**
     * @dev The basis must be SCALED, not re-anchored, by a partial redeem. A redeem sheds `f` of the LP
     *      and repays `f` of the debt, so `(1−f)` of the drift SURVIVES as real exposure. Re-anchoring
     *      the basis to the post-repay debt would zero the measure and silently forgive that survivor —
     *      an accumulating short again, just slower.
     */
    function testPartialRedeemScalesTheHedgedBasisSoSurvivingDriftStaysMeasured() public {
        _armBook();
        uint256 interest = _debtLegA() / 200;
        mLegA.accrueBorrowInterest(address(strategy), interest);
        assertEq(_driftLegA(), interest, "drift armed");

        // A quarter of the book, through the PRO-RATA UNWIND path (`requestRedeem`/`fulfillRedeem`) —
        // the one that repays `f` of the debt and sheds `f` of the LP, and therefore the one the basis
        // scaling exists for. (`redeem` is the collateral-funded fast path: it touches neither.)
        uint256 shares = SHARES / 4;
        vm.prank(lp);
        vault.approve(address(strategy), shares);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(shares, 0);
        vm.prank(proposer);
        strategy.fulfillRedeem(id);

        // Three quarters of the drift survived, and all of it is still measured.
        assertApproxEqRel(_driftLegA(), (interest * 3) / 4, 1e16, "surviving drift == (1-f) x drift, still measured");

        // ...and the next harvest clears it.
        _armRewards(20_000e18);
        _compound(1);
        assertApproxEqAbs(_driftLegA(), 0, 100, "harvest clears the surviving drift");
    }

    /// @dev A rerange leaves part of the hedge as an IDLE leg-A remainder rather than inside the LP. The
    ///      accounting basis is indifferent to that (it tracks principal, not composition), so the drift
    ///      measure stays 0 — which an `lpLegA`-based measure would have mis-read as a huge short.
    function testRerangeRemainderDoesNotLookLikeInterestDrift() public {
        _armBook();
        _movePriceTo(TICK - 400);
        // HARNESS NOTE: `MockNpm` is geometry, not an AMM — it never swaps between its own legs, so
        // after a price move the amounts a 100% withdrawal is owed no longer match what it happens to
        // custody. Top up both sides so the rerange's remove+collect can settle, exactly as a real pool
        // (which would have accumulated the other leg through the swaps that moved the price) could.
        usdc.mint(address(npm), SEED);
        legA.mint(address(npm), 1_000e8);

        vm.prank(proposer);
        strategy.rerange(WIDTH, 0, 0);

        assertGt(legA.balanceOf(address(strategy)), 0, "rerange left an idle leg-A remainder");
        assertEq(_driftLegA(), 0, "an idle-leg remainder is NOT interest drift");

        uint256 legAInRouterBefore = legA.balanceOf(address(router));
        _armRewards(20_000e18);
        _compound(1);
        assertEq(legA.balanceOf(address(router)), legAInRouterBefore, "compound bought no leg A");
    }

    // ==================== 2. THE GENUINE NO-OP ====================

    /**
     * @dev A no-AERO `compound` must be a TRUE no-op. Live, it minted fee-shares and ratcheted the HWM
     *      while moving no funds — a keeper polling the entrypoint was silently diluting holders and
     *      advancing the fee clock. Armed here in the state where the old code was guaranteed to charge:
     *      HWM already seeded by a real harvest, NAV grown above it, and a positive `dt`.
     */
    function testNoAeroCompoundIsATrueNoOp() public {
        _armBook();
        // Harvest #1: seeds the HWM and grows NAV above it — so a crystallise now WOULD mint.
        _armRewards(20_000e18);
        _compound(1);
        _clearRewards();
        vm.warp(block.timestamp + 30 days);
        _refreshFeeds();

        uint256 navBefore = strategy.nav();
        uint256 supplyBefore = vault.totalSupply();
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        uint256 hwmBefore = strategy.layout().hwmPerShare;
        uint256 lastAccrualBefore = strategy.layout().lastFeeAccrualTimestamp;
        uint256 lpLiqBefore = npm.liquidityOf(strategy.layout().tokenId);
        uint256 debtBefore = _debtLegA();
        uint256 idleBefore = usdc.balanceOf(address(strategy));
        uint256 collateralBefore = _collateralUsdc();
        (uint128 hedgedBefore,) = strategy.hedgedDebt();

        // Sanity: a crystallise at this point would genuinely have charged something.
        assertGt(Math.mulDiv(navBefore, 1e18, supplyBefore), hwmBefore, "NAV/share is above the HWM");

        _compound(1);

        assertEq(vault.totalSupply(), supplyBefore, "no fee-shares minted");
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore, "fee recipient untouched");
        assertEq(strategy.layout().hwmPerShare, hwmBefore, "HWM NOT ratcheted");
        assertEq(strategy.layout().lastFeeAccrualTimestamp, lastAccrualBefore, "fee clock NOT advanced");
        assertEq(strategy.nav(), navBefore, "NAV byte-identical");
        assertEq(npm.liquidityOf(strategy.layout().tokenId), lpLiqBefore, "LP byte-identical");
        assertEq(_debtLegA(), debtBefore, "debt byte-identical");
        assertEq(usdc.balanceOf(address(strategy)), idleBefore, "idle byte-identical");
        assertEq(_collateralUsdc(), collateralBefore, "collateral byte-identical");
        (uint128 hedgedAfter,) = strategy.hedgedDebt();
        assertEq(hedgedAfter, hedgedBefore, "hedged basis byte-identical");
        assertEq(gauge.getRewardCallCount(), 1, "only harvest #1 ever claimed");
    }

    /// @dev The `minUsdcOut == 0` belt must stay AHEAD of the reward probe, so a careless caller gets a
    ///      loud refusal on a live book whether or not AERO happens to be claimable.
    function testCompoundRejectsZeroMinOutEvenWithNoRewards() public {
        _armBook();
        _clearRewards();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroManager.ZeroMinOut.selector);
        strategy.compound(0, 0);

        // ...and with rewards claimable, same answer, same selector.
        _armRewards(20_000e18);
        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroManager.ZeroMinOut.selector);
        strategy.compound(0, 0);
    }

    /// @dev A stray AERO balance with `earned() == 0` (a donation, or a previous partial fill) is STILL
    ///      real yield: the probe must not mistake it for a no-op and skip the harvest.
    function testStrayAeroBalanceIsStillHarvested() public {
        _armBook();
        _clearRewards();
        aero.mint(address(strategy), 20_000e18); // held, but not "earned"
        assertEq(gauge.earnedAmount(), 0, "nothing claimable from the gauge");

        uint256 collateralBefore = _collateralUsdc();
        _compound(1);
        assertGt(_collateralUsdc(), collateralBefore, "the stray balance was harvested and redeployed");
    }

    /// @dev DUST NO-OP, the compound-side twin of `flatten`'s `_sellRewardBalance` skip. A reward
    ///      balance worth under one micro-USD prices to a ZERO oracle floor, and the router fills it
    ///      at 0 USDC — so the nonzero `minUsdcOut` compound is FORCED to demand (the `ZeroMinOut`
    ///      belt rejects 0) makes the AERO→USDC swap revert on the router's own min-out check. Without
    ///      the `floor == 0` early return, a single dust donation to the gauge bricks every subsequent
    ///      `compound`. `1e6` wei AERO × `$1` (1e8) / 1e20 == 0 (6dp), so it lands in the dust band.
    function testCompoundNoOpsOnADustRewardInsteadOfBricking() public {
        _armBook();
        _clearRewards();
        aero.mint(address(strategy), 1e6); // sub-micro-USD: floor rounds to 0

        uint256 collateralBefore = _collateralUsdc();
        // A nonzero minUsdcOut is mandatory (ZeroMinOut belt); the dust skip must fire BEFORE the swap.
        _compound(1);

        assertEq(aero.balanceOf(address(strategy)), 1e6, "dust left in place, not force-sold at a loss");
        assertEq(_collateralUsdc(), collateralBefore, "no redeploy: the harvest cleanly no-oped");
    }

    /// @dev The skip must NOT widen the guard for a real tranche: the smallest balance whose HAIRCUT
    ///      floor is nonzero still swaps and redeploys. The threshold is the post-`maxSlippageBps`
    ///      floor, not the raw one — at `1e12` the raw floor is 1 unit and the 100bps haircut rounds
    ///      it back to 0 (still skipped); `2e12` gives raw 2, haircut floor 1, the first that sells.
    function testCompoundStillHarvestsTheSmallestNonDustBalance() public {
        _armBook();
        _clearRewards();
        aero.mint(address(strategy), 2e12);

        uint256 collateralBefore = _collateralUsdc();
        _compound(1);

        assertEq(aero.balanceOf(address(strategy)), 0, "above-dust balance is sold, not skipped");
        assertGt(_collateralUsdc(), collateralBefore, "the tranche was harvested and redeployed");
    }

    // ==================== 3. FEE TIMING (findings 3 + 4) ====================

    /**
     * @dev THE FEE-TIMING CONTRACT, asserted rather than assumed. Gauge rewards are not in `nav()`, so
     *      the pre-harvest crystallise cannot see the value the harvest is about to add: harvest #1
     *      charges NO performance fee on its own yield, and harvest #2's crystallise charges it. That is
     *      DEFERRAL, not leakage — and it is deliberate (see the `compound` header: every crystallisation
     *      point precedes share issuance/burn, so the fee lands on exactly the holders who held while the
     *      yield accrued, and adding a second harvest-timed crystallisation point would raise the
     *      expected fee under an HWM rather than correct anything).
     */
    function testHarvestYieldIsFeedAtTheNextCrystallisationPointNotItsOwn() public {
        _armBook();

        uint256 supply0 = vault.totalSupply();
        uint256 nav0 = strategy.nav();
        assertEq(strategy.layout().hwmPerShare, 0, "HWM unset before the first crystallise");

        // ── Harvest #1: crystallise SEEDS the HWM at the PRE-harvest level and charges nothing ──
        _armRewards(20_000e18);
        _compound(1);

        assertEq(vault.totalSupply(), supply0, "harvest #1 charged NO performance fee on its own yield");
        assertEq(vault.balanceOf(feeRecipient), 0, "fee recipient paid nothing yet");
        uint256 hwm1 = strategy.layout().hwmPerShare;
        assertEq(hwm1, Math.mulDiv(nav0, 1e18, supply0), "HWM seeded at the PRE-harvest NAV/share");
        // The yield is in NAV, un-crystallised — carrying the fee liability, not escaping it.
        uint256 nav1 = strategy.nav();
        assertGt(Math.mulDiv(nav1, 1e18, supply0), hwm1, "the un-fee'd gain is sitting in NAV/share");

        // ── Harvest #2: the SAME gain is now visible to the crystallise and IS charged ──
        _armRewards(20_000e18);
        _compound(1);

        assertGt(vault.totalSupply(), supply0, "harvest #2 crystallised harvest #1's gain");
        assertGt(vault.balanceOf(feeRecipient), 0, "fee recipient paid, one point late");
        assertGt(strategy.layout().hwmPerShare, hwm1, "HWM ratcheted at the crystallisation point");

        // The charge is ~10% of harvest #1's gain, i.e. the fee schedule as quoted — nothing is lost to
        // the lag, and nothing is double-charged.
        uint256 gain = nav1 - nav0;
        uint256 feeValue = Math.mulDiv(vault.balanceOf(feeRecipient), strategy.nav(), vault.totalSupply());
        assertApproxEqRel(feeValue, (gain * PERF_FEE_BPS) / 10_000, 5e16, "fee ~= perfBps x the deferred gain");
    }

    /// @dev A DEPOSIT is also a crystallisation point, and it runs BEFORE the new shares are minted —
    ///      which is what makes the deferral fair. The entering depositor must not be diluted by the
    ///      performance fee on a gain that accrued before they arrived.
    function testADepositCrystallisesTheDeferredFeeBeforeMintingTheNewShares() public {
        _armBook();
        _armRewards(20_000e18); // harvest #1: seeds the HWM, adds un-fee'd yield
        _compound(1);
        uint256 hwm1 = strategy.layout().hwmPerShare;

        address newLp = makeAddr("newLp");
        usdc.mint(newLp, 100_000e6);
        vm.prank(newLp);
        usdc.approve(address(strategy), 100_000e6);
        vm.prank(newLp);
        uint256 minted = strategy.deposit(100_000e6, 0);

        assertGt(vault.balanceOf(feeRecipient), 0, "the deferred fee crystallised ON the deposit");
        assertGt(strategy.layout().hwmPerShare, hwm1, "HWM ratcheted at the deposit");
        // The depositor's shares were priced against the POST-crystallise book, so their per-share value
        // is (within rounding) exactly what they paid — no phantom fee.
        uint256 lpValue = Math.mulDiv(minted, strategy.nav(), vault.totalSupply());
        assertApproxEqRel(lpValue, 100_000e6, 1e15, "depositor did not pay a fee on a pre-arrival gain");
    }

    /// @dev `compound` still defers the fee (rather than bricking the harvest) when share issuance is
    ///      closed — the H3 best-effort path, now proven on a REAL harvest instead of a flat book.
    function testCompoundDefersFeeCrystalliseWhenIssuanceIsClosed() public {
        _armBook();
        _armRewards(20_000e18);
        _compound(1); // seeds the HWM, adds un-fee'd yield
        uint256 hwm1 = strategy.layout().hwmPerShare;
        uint256 lastAccrual1 = strategy.layout().lastFeeAccrualTimestamp;
        uint256 supply1 = vault.totalSupply();

        vm.prank(owner);
        vault.setOpenDeposits(false);

        uint256 collateralBefore = _collateralUsdc();
        _armRewards(20_000e18);
        _compound(1); // must NOT revert — the harvest proceeds, the fee defers

        assertEq(vault.totalSupply(), supply1, "no fee-shares minted (issuance shut)");
        assertEq(strategy.layout().hwmPerShare, hwm1, "HWM unmoved (fee deferred, not lost)");
        assertEq(strategy.layout().lastFeeAccrualTimestamp, lastAccrual1, "accrual clock unmoved");
        assertGt(_collateralUsdc(), collateralBefore, "...but the HARVEST itself went through");
    }
}
