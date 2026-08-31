// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAeroManager} from "@contracts/leveraged-aero/LeveragedAeroManager.sol";
import {LeveragedAeroValuation} from "@contracts/leveraged-aero/LeveragedAeroValuation.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {LiquidityAmounts} from "@contracts/leveraged-aero/sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {ChainlinkReader} from "@contracts/leveraged-aero/sherwood/libraries/ChainlinkReader.sol";

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

import {Test, Vm} from "@forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title compound(): borrow-interest re-hedge, genuine-no-op, and the fee-timing contract
 * @notice The first suite in this tree that drives a REAL `compound` end to end (the pre-existing ones
 *         only reached the flat-book bail, because the AERO→USDC leg routes through a hardcoded mainnet
 *         Aerodrome-v2 router address). `MockAeroV2Router` is etched at that address, so the whole
 *         claim → swap → re-hedge → redeploy sequence runs against custodial venue mocks.
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
 *         3. NO-OP + THE IN-KIND HARVEST SKIM. A keeper-polled `compound` with nothing to harvest must
 *            move nothing at all, and a real harvest must skim exactly `compoundFeeBps` of the tranche to
 *            `feeRecipient` IN KIND, ahead of the sale, so both min-out floors bind the post-skim amount.
 *
 * @dev Fixture: the asset-as-a-leg shape (leg A is an 8dp volatile token, the pair is legA/USDC), the
 *      shape the live fork run that produced these findings was running. The pool `sqrtP` and the leg-A
 *      Chainlink price are kept mutually consistent by deriving the price from `sqrtP`. The harvest skim
 *      is OFF in the shared fixture so the hedge arithmetic stays exact; the skim block re-arms it.
 */
contract LeveragedAeroCompoundHedgeUnitTest is Test {
    /// @dev Mirrored from {LeveragedAeroManager}, which emits it from the STRATEGY's address.
    event CompoundFeePaid(address indexed recipient, uint256 aeroAmount);

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
    /// @dev OFF in the shared fixture (every hedge assertion pins exact AERO amounts); `_rearmWithSkim`
    ///      rebuilds the pair with a live skim for the block that tests it.
    uint16 internal constant COMPOUND_FEE_BPS = 0;
    /// @dev The production skim the fee block arms: 5% of each harvested tranche.
    uint16 internal constant SKIM_BPS = 500;
    uint8 internal constant LEG_A_DECIMALS = 8;
    uint256 internal constant P_USDC = 1e8;
    uint256 internal constant P_AERO = 1e8; // $1/AERO, so USDC out == AERO in / 1e12
    uint256 internal constant Q96 = 1 << 96;

    uint256 internal constant SEED = 1_000_000e6; // $1M genesis
    uint256 internal constant SHARES = 1_000_000e12; // vault shares outstanding (12dp)

    /// @dev Leg-A price (8dp) implied by the pool's `sqrtP` for this fixture's ordering (legA = token1).
    uint256 internal legAPrice8;

    /// @dev Aerodrome v2 PoolFactory, hardcoded in `LeveragedAeroValuation` and probed for a USDC route.
    address internal constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @dev `applyVenue` pins the canonical CLFactory, so a fork-free test must etch the registry HERE.
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
        // The reward-route probe reads a HARDCODED v2 factory address; etch code so the route resolves.
        vm.etch(AERO_V2_FACTORY, address(new MockAeroV2Factory(address(aero), address(usdc), address(0xA2F))).code);
        comptroller = new MockComptroller();
        mUsdc = new MockLendingMarket(address(usdc));
        mLegA = new MockLendingMarket(address(legA));
        npm = new MockNpm(pool);
        // Real ERC-721 custody: a staked position is owned by the gauge, so a missing unstake reverts.
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
        // `cloneAndBind` is the only init path: `BaseStrategy.initialize` requires `msg.sender == vault_`.
        vm.startPrank(owner);
        strategy = LeveragedAerodromeCLStrategy(
            payable(vault.cloneAndBind(address(new LeveragedAerodromeCLStrategy()), proposer, abi.encode(_params())))
        );
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
        p.skewBps = 5000;
        p.minSkewBps = 1000; // governance band (unused here — this suite never reranges)
        p.maxSkewBps = 9000;
        p.targetLtvBps = TARGET_LTV_BPS;
        p.maxLtvBps = 6500;
        p.minHealthBps = 12_000;
        p.maxSlippageBps = MAX_SLIPPAGE_BPS;
        p.compoundFeeBps = COMPOUND_FEE_BPS;
        p.feeRecipient = feeRecipient;
    }

    /// @dev Rebuild the vault + strategy pair with `bps` armed as the harvest skim and `recipient` as its
    ///      payee. Every venue mock is shared, so the rebuilt book is the fixture's twin apart from the fee.
    function _rearmWithSkim(uint16 bps, address recipient) internal {
        LeveragedAerodromeCLStrategy.InitParams memory p = _params();
        p.compoundFeeBps = bps;
        p.feeRecipient = recipient;
        vault = new LeveragedAeroVault(address(usdc), owner, "Leveraged Aero Vault", "lvAERO");
        vm.startPrank(owner);
        strategy = LeveragedAerodromeCLStrategy(
            payable(vault.cloneAndBind(address(new LeveragedAerodromeCLStrategy()), proposer, abi.encode(p)))
        );
        vault.setOpenDeposits(true);
        vm.stopPrank();
    }

    /// @dev Open the position AND put vault shares outstanding, so the book prices like a live fund.
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

    /// @dev Override the etched AERO->USDC router's fill rate (USDC-out per AERO-in, 1e18-scaled).
    function _setAeroRouterRate(uint256 rateE18) internal {
        MockAeroV2Router(AERO_V2_ROUTER).setRateOverrideE18(rateE18);
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
        // an equal slug of debt cancelled), and `navBeforeHarvest` was snapshot after `_armRewards`, when
        // `nav()` already priced `earned()` — so the harvest CONVERTS the proceeds rather than stepping NAV
        // up, and there is no step for a depositor to front-run.
        assertApproxEqRel(strategy.nav(), navBeforeHarvest, 1e15, "harvest CONVERTS priced yield; hedge is NAV-neutral");
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
        uint256 id = strategy.requestRedeem(shares, 0, address(0));
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);

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
        strategy.rerange(WIDTH, 5000, 0, 0);

        assertGt(legA.balanceOf(address(strategy)), 0, "rerange left an idle leg-A remainder");
        assertEq(_driftLegA(), 0, "an idle-leg remainder is NOT interest drift");

        uint256 legAInRouterBefore = legA.balanceOf(address(router));
        _armRewards(20_000e18);
        _compound(1);
        assertEq(legA.balanceOf(address(router)), legAInRouterBefore, "compound bought no leg A");
    }

    // ==================== 2. THE GENUINE NO-OP ====================

    /**
     * @dev A no-AERO `compound` must be a TRUE no-op. It is a keeper-polled entrypoint, so a poll that
     *      finds nothing to harvest must leave the whole book byte-identical — no claim, no skim, no
     *      redeploy. Armed after a real harvest so every piece of state it could touch is non-trivial.
     */
    function testNoAeroCompoundIsATrueNoOp() public {
        _armBook();
        _armRewards(20_000e18);
        _compound(1);
        _clearRewards();
        vm.warp(block.timestamp + 30 days);
        _refreshFeeds();

        uint256 navBefore = strategy.nav();
        uint256 supplyBefore = vault.totalSupply();
        uint256 lpLiqBefore = npm.liquidityOf(strategy.layout().tokenId);
        uint256 debtBefore = _debtLegA();
        uint256 idleBefore = usdc.balanceOf(address(strategy));
        uint256 collateralBefore = _collateralUsdc();
        (uint128 hedgedBefore,) = strategy.hedgedDebt();

        _compound(1);

        assertEq(vault.totalSupply(), supplyBefore, "no shares minted");
        assertEq(aero.balanceOf(feeRecipient), 0, "fee recipient untouched");
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

    /// @dev DUST NO-OP: without the `floor == 0` early return, one dust donation bricks every `compound`.
    function testCompoundNoOpsOnADustRewardInsteadOfBricking() public {
        _armBook();
        _clearRewards();
        aero.mint(address(strategy), 1e6); // sub-micro-USD: floor rounds to 0

        uint256 collateralBefore = _collateralUsdc();
        // A nonzero minUsdcOut is mandatory (ZeroMinOut belt); the dust skip must fire BEFORE the swap.
        _compound(1);

        assertEq(aero.balanceOf(address(strategy)), 1e6, "dust left in place, not force-sold at a loss");
        assertEq(_collateralUsdc(), collateralBefore, "no redeploy: the harvest cleanly no-oped");
        assertEq(aero.balanceOf(feeRecipient), 0, "...and the dust skip precedes the skim, so nothing was paid");
    }

    /// @dev The skip must NOT widen the guard: the smallest balance whose POST-haircut floor is nonzero is
    ///      still SOLD (`1e12` haircuts back to 0 and is skipped; `2e12` is the first that sells).
    function testCompoundStillHarvestsTheSmallestNonDustBalance() public {
        _armBook();
        _clearRewards();
        mLegA.accrueBorrowInterest(address(strategy), _debtLegA() / 100);
        aero.mint(address(strategy), 2e12);

        _compound(1);

        assertEq(aero.balanceOf(address(strategy)), 0, "above-dust balance is sold, not skipped");
    }

    // ==================== 3. THE IN-KIND HARVEST SKIM ====================
    // The fund's ONLY fee: `compoundFeeBps` of each harvested AERO tranche, transferred to `feeRecipient`
    // as AERO before the sale. `_rearmWithSkim` rebuilds the fixture with it live.

    /// @dev The tranche this block harvests, and the exact split a 5% skim produces.
    uint256 internal constant SKIM_TRANCHE = 20_000e18;
    uint256 internal constant SKIM_AMOUNT = 1_000e18; // 5% of SKIM_TRANCHE
    uint256 internal constant SKIM_SELL = 19_000e18; // what actually reaches the router

    /// @dev THE AMOUNT, THE RECIPIENT AND THE BASE, all pinned to literals. MUTATIONS this kills: skimming
    ///      off `usdcOut` instead of the AERO tranche, paying anyone but `feeRecipient`, minting fee-SHARES
    ///      instead of moving tokens, and taking the fee after the sale (the router would receive 20k).
    function testCompoundSkimsExactlyTheConfiguredShareToTheRecipient() public {
        _rearmWithSkim(SKIM_BPS, feeRecipient);
        _armBook();
        _armRewards(SKIM_TRANCHE);

        uint256 supplyBefore = vault.totalSupply();
        uint256 aeroInRouter0 = aero.balanceOf(AERO_V2_ROUTER);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit CompoundFeePaid(feeRecipient, SKIM_AMOUNT);
        _compound(1);

        assertEq(aero.balanceOf(feeRecipient), SKIM_AMOUNT, "5% of the tranche, in AERO");
        assertEq(aero.balanceOf(AERO_V2_ROUTER) - aeroInRouter0, SKIM_SELL, "...and only the 95% was sold");
        assertEq(aero.balanceOf(address(strategy)), 0, "nothing of the tranche is left behind");
        assertEq(vault.totalSupply(), supplyBefore, "an in-kind fee dilutes nobody");
    }

    /// @dev THE CALLER'S FLOOR BINDS THE POST-SKIM SELL. A proposer quotes what the router will actually
    ///      receive, so the exact post-skim proceeds clear and a gross-basis quote cannot.
    function testTheCallerMinOutIsQuotedOnThePostSkimAmount() public {
        _rearmWithSkim(SKIM_BPS, feeRecipient);
        _armBook();
        _armRewards(SKIM_TRANCHE);

        uint256 snap = vm.snapshotState();
        vm.prank(proposer);
        vm.expectRevert(MockAeroV2Router.MockAeroRouterMinOut.selector);
        strategy.compound(_usdcFromAero(SKIM_TRANCHE), 0); // the GROSS quote: 5% too high
        vm.revertToState(snap);

        _compound(_usdcFromAero(SKIM_SELL)); // the post-skim quote: exact, and it clears
        assertEq(aero.balanceOf(feeRecipient), SKIM_AMOUNT, "the skim was paid on the clearing call");
    }

    /// @dev THE ORACLE FLOOR IS ALSO ON THE POST-SKIM AMOUNT. A perfect fill at the fixture's $1 mark pays
    ///      `SKIM_SELL` USDC, which a GROSS-basis floor (`0.99 x 20_000`) would reject outright — so the
    ///      call clearing at the default rate is itself the mutation guard. The boundary is pinned too:
    ///      exactly `0.99 x post-skim` clears, one wei of rate under it does not.
    function testTheOracleFloorIsDerivedFromThePostSkimAmount() public {
        _rearmWithSkim(SKIM_BPS, feeRecipient);
        _armBook();
        _armRewards(SKIM_TRANCHE);

        // `MAX_SLIPPAGE_BPS` is 1%, so the floor sits at 990_000 of the mock router's 1e18-scaled rate.
        uint256 snap = vm.snapshotState();
        _setAeroRouterRate(989_999);
        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroManager.BelowOracleFloor.selector);
        strategy.compound(1, 0);
        vm.revertToState(snap);

        _setAeroRouterRate(990_000);
        _compound(1);
        assertEq(aero.balanceOf(address(strategy)), 0, "a fill exactly at the post-skim floor clears");
    }

    /// @dev A ZERO-SKIM CLONE IS SILENT: the whole tranche is sold, nothing is transferred, and no event is
    ///      emitted (an indexer must not see a 0-AERO fee).
    function testAZeroSkimMovesNothingAndEmitsNothing() public {
        _rearmWithSkim(0, feeRecipient);
        _armBook();
        _armRewards(SKIM_TRANCHE);

        uint256 aeroInRouter0 = aero.balanceOf(AERO_V2_ROUTER);
        vm.recordLogs();
        _compound(1);

        assertEq(aero.balanceOf(feeRecipient), 0, "no skim at 0 bps");
        assertEq(aero.balanceOf(AERO_V2_ROUTER) - aeroInRouter0, SKIM_TRANCHE, "the whole tranche was sold");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != CompoundFeePaid.selector, "a zero skim emits nothing");
        }
    }

    /// @dev THE SKIM IS EXCLUSIVE TO THE HARVEST. `flatten` sells the tranche its own unwind auto-claims
    ///      through `LeveragedAeroVenue._sellRewardBalance`, an EXIT path — it must skim nothing, or the
    ///      same tranche would be charged twice (once on the way in, once on the way out).
    function testAnExitTrancheSaleDoesNotSkim() public {
        _rearmWithSkim(SKIM_BPS, feeRecipient);
        _armBook();
        _armWithdrawAutoClaim(SKIM_TRANCHE);
        // `MockNpm` custodies only what it was minted; float the re-priced remainder as other LPs do.
        usdc.mint(address(npm), 1_000e6);
        legA.mint(address(npm), 1_000e8);

        uint256 aeroInRouter0 = aero.balanceOf(AERO_V2_ROUTER);
        vm.recordLogs();
        vm.prank(proposer);
        strategy.flatten(1, 0);

        assertEq(aero.balanceOf(feeRecipient), 0, "an exit sale pays no fee");
        assertEq(aero.balanceOf(AERO_V2_ROUTER) - aeroInRouter0, SKIM_TRANCHE, "the WHOLE tranche was sold");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != CompoundFeePaid.selector, "...and no fee event was emitted");
        }
    }

    // ====== 4. nav() PRICES THE GAUGE REWARD: HELD BALANCE **AND** earned() (review finding 3) ======
    // Round 1 priced only the CLAIMED-but-unsold balance, but a harvest spends most of its life in the gauge
    // as `earned()`; the two `...NoLongerCapturesTheHarvestStep` tests are the two halves of one proof.

    /// @dev The reward tranche used by this block: $50k of AERO at the fixture's $1 mark.
    uint256 internal constant TRANCHE = 50_000e18;

    /// @dev Arm the gauge's `withdraw` auto-claim: every `_unwindLiquidity` pays the accrued tranche out.
    function _armWithdrawAutoClaim(uint256 amount) internal {
        aero.mint(address(gauge), amount);
        gauge.setAeroToPayOnWithdraw(amount);
    }

    /// @dev USDC face (6dp) `nav()` should credit for `aeroAmt` held AERO at the fixture's $1 mark.
    function _heldAeroValueUsdc(uint256 aeroAmt) internal pure returns (uint256) {
        return aeroAmt / 1e12;
    }

    /// @dev THE TERM ITSELF: a claimed-but-unsold reward balance must show in `nav()`, on the sale-floor mark.
    function testNavPricesTheHeldRewardBalance() public {
        _armBook();
        uint256 navBefore = strategy.nav();

        aero.mint(address(strategy), TRANCHE);

        assertEq(strategy.nav(), navBefore + _heldAeroValueUsdc(TRANCHE), "nav credits the held tranche exactly");
    }

    /// @dev REACHABILITY, not a synthetic balance: `rerange`'s unwind AUTO-CLAIMS the tranche into the wallet.
    function testNavPricesTheTrancheARerangeAutoClaims() public {
        _armBook();
        _armWithdrawAutoClaim(TRANCHE);
        uint256 navBefore = strategy.nav();

        vm.prank(proposer);
        strategy.rerange(WIDTH, 5000, 0, 0);

        assertEq(aero.balanceOf(address(strategy)), TRANCHE, "the unwind auto-claimed a tranche");
        // The recenter is NAV-neutral at an unmoved tick, so the whole delta is the newly-held tranche.
        assertApproxEqAbs(
            strategy.nav(), navBefore + _heldAeroValueUsdc(TRANCHE), 2, "nav grew by the auto-claimed tranche"
        );
    }

    /// @dev THE FINDING, HELD-TRANCHE HALF: a depositor arriving between an unwind's auto-claim and the next
    ///      `compound()` bought in at a NAV that EXCLUDED the tranche, then took a pro-rata slice of the step.
    function testADepositBeforeCompoundNoLongerCapturesAHELDTrancheHarvestStep() public {
        _armBook();
        _armWithdrawAutoClaim(TRANCHE);
        vm.prank(proposer);
        strategy.rerange(WIDTH, 5000, 0, 0); // auto-claims the tranche into the strategy
        gauge.setAeroToPayOnWithdraw(0); // one tranche only — later unwinds claim nothing

        uint256 navWithTranche = strategy.nav();
        uint256 supplyBefore = vault.totalSupply();
        uint256 trancheUsdc = _heldAeroValueUsdc(TRANCHE);

        // The PRE-FIX book: price the deposit against `nav − tranche`, then hand over a share of the step.
        uint256 preFixShares = Math.mulDiv(100_000e6, supplyBefore, navWithTranche - trancheUsdc);
        uint256 preFixCapture = Math.mulDiv(trancheUsdc, preFixShares, supplyBefore + preFixShares);
        assertGt(preFixCapture, 100_000e6 / 100, "the captured slice was material (>1% of the deposit)");

        address newLp = makeAddr("newLp");
        usdc.mint(newLp, 100_000e6);
        vm.prank(newLp);
        usdc.approve(address(strategy), 100_000e6);
        vm.prank(newLp);
        uint256 minted = strategy.deposit(100_000e6, 0);

        // The harvest that used to be a step for them. `earned() == 0`; the HELD balance is the proceeds.
        _clearRewards();
        _compound(1);
        assertEq(aero.balanceOf(address(strategy)), 0, "the tranche was sold");

        uint256 lpValue = Math.mulDiv(minted, strategy.nav(), vault.totalSupply());
        assertApproxEqRel(lpValue, 100_000e6, 1e15, "the depositor holds what they paid - no harvest capture");
        assertLt(lpValue, 100_000e6 + preFixCapture / 2, "...and nothing close to the pre-fix capture");
    }

    /// @dev THE REVIEWER'S PoC WITH THE ASSERTION FLIPPED — the harvest sits where one normally does: UNCLAIMED
    ///      inside the gauge. They measured 4.5% of a 100k deposit captured in one block.
    function testADepositBeforeCompoundNoLongerCapturesAnEARNEDHarvestStep() public {
        _armBook();
        _armRewards(TRANCHE); // claimable, NOT claimed: it lives in `gauge.earned()`
        assertEq(aero.balanceOf(address(strategy)), 0, "nothing HELD - the whole tranche is still earned()");

        uint256 navWithEarned = strategy.nav();
        uint256 supplyBefore = vault.totalSupply();
        uint256 trancheUsdc = _heldAeroValueUsdc(TRANCHE);

        // The ROUND-1 book (`earned()` unpriced): price against `nav − earned`, then hand over the step.
        uint256 preFixShares = Math.mulDiv(100_000e6, supplyBefore, navWithEarned - trancheUsdc);
        uint256 preFixCapture = Math.mulDiv(trancheUsdc, preFixShares, supplyBefore + preFixShares);
        assertGt(preFixCapture, 100_000e6 / 100, "the captured slice was material (>1% of the deposit)");

        address newLp = makeAddr("newLp");
        usdc.mint(newLp, 100_000e6);
        vm.prank(newLp);
        usdc.approve(address(strategy), 100_000e6);
        vm.prank(newLp);
        uint256 minted = strategy.deposit(100_000e6, 0);

        // The harvest that used to be a step. NO `_clearRewards()`: `compound` claims the tranche itself.
        _compound(1);
        assertEq(aero.balanceOf(address(strategy)), 0, "the tranche was claimed and sold");
        assertEq(gauge.earnedAmount(), 0, "...and the gauge accrual it came from is consumed");

        uint256 lpValue = Math.mulDiv(minted, strategy.nav(), vault.totalSupply());
        assertApproxEqRel(lpValue, 100_000e6, 1e15, "the depositor holds what they paid - no harvest capture");
        assertLt(lpValue, 100_000e6 + preFixCapture / 2, "...and nothing close to the pre-fix capture");
    }

    /// @dev THE `earned()` TERM ITSELF, to the unit: nothing is held, the whole credit is the gauge accrual.
    function testNavPricesTheUnclaimedGaugeEarned() public {
        _armBook();
        uint256 navBefore = strategy.nav();

        _armRewards(TRANCHE);

        assertEq(aero.balanceOf(address(strategy)), 0, "nothing held");
        assertEq(strategy.nav(), navBefore + _heldAeroValueUsdc(TRANCHE), "nav credits the gauge accrual exactly");
    }

    /// @dev THE HAND-OFF: the gauge reverts `"NA"` on `earned()` exactly when the held term counts that value.
    function testNavIsContinuousWhenEarnedRevertsBecauseTheTrancheWasClaimed() public {
        _armBook();
        _armRewards(TRANCHE);
        uint256 navEarned = strategy.nav();

        // The unstake moment: the gauge paid the tranche out and now reverts on `earned()`.
        vm.prank(address(gauge));
        aero.transfer(address(strategy), TRANCHE);
        _clearRewards();
        vm.mockCallRevert(address(gauge), abi.encodeWithSelector(gauge.earned.selector), bytes("NA"));

        assertEq(strategy.nav(), navEarned, "nav is continuous across the claim - no double count, no gap");
    }

    /// @dev A FLAT BOOK MAKES NO `earned()` CALL AT ALL. Proven by making every `earned()` call revert.
    function testFlatBookNeverCallsEarned() public {
        _armBook();
        vm.mockCallRevert(address(gauge), abi.encodeWithSelector(gauge.earned.selector), bytes("NA"));

        vm.prank(address(vault));
        strategy.settle();

        assertEq(strategy.layout().tokenId, 0, "flat book");
        strategy.nav(); // no revert: the `earned()` probe was never reached
    }

    /// @dev NO REWARD VALUE AT ALL ⇒ NO ORACLE DEPENDENCY: the read is gated on `held + earned() > 0`.
    function testNavDoesNotReadTheRewardFeedWhenThereIsNoRewardValue() public {
        _armBook();
        assertEq(aero.balanceOf(address(strategy)), 0, "nothing held");
        assertEq(gauge.earnedAmount(), 0, "...and nothing earned");
        uint256 navFresh = strategy.nav();

        aeroFeed.setUpdatedAt(block.timestamp - 2 hours); // well past maxDelay (1 hour)

        assertEq(strategy.nav(), navFresh, "nav is byte-identical and never touched the reward feed");
    }

    /// @dev THE WIDENED SCOPE: a live gauge nearly always carries reward value, so a stale feed shuts `nav()`.
    function testAStaleRewardFeedFailsClosedOnEarnedAloneWithNothingHeld() public {
        _armBook();
        _armRewards(TRANCHE);
        assertEq(aero.balanceOf(address(strategy)), 0, "nothing held - the exposure is the earned() term");

        aeroFeed.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        strategy.nav();

        // The async queue is unaffected: requesting and fulfilling never price through `nav()`.
        uint256 shares = SHARES / 10;
        vm.prank(lp);
        vault.approve(address(strategy), shares);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(shares, 0, address(0));
        uint256 lpBefore = usdc.balanceOf(lp);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
        assertGt(usdc.balanceOf(lp) - lpBefore, 0, "the oracle-free exit still pays");
    }

    /// @dev FAIL-CLOSED: `nav()` REVERTS rather than valuing an unreadable tranche at 0. Accepted consequence:
    ///      deposits and the priced fast redeem are denied while it lasts; the async queue is not.
    function testNavFailsClosedOnAStaleRewardFeedWhileATrancheIsHeld() public {
        _armBook();
        aero.mint(address(strategy), TRANCHE);
        aeroFeed.setUpdatedAt(block.timestamp - 2 hours);

        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        strategy.nav();

        address newLp = makeAddr("newLp");
        usdc.mint(newLp, 10_000e6);
        vm.prank(newLp);
        usdc.approve(address(strategy), 10_000e6);
        vm.prank(newLp);
        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        strategy.deposit(10_000e6, 0);

        // ...and the cure is one proposer call: sell the tranche and the dependency is gone.
        _refreshFeeds();
        _clearRewards();
        _compound(1);
        aeroFeed.setUpdatedAt(block.timestamp - 2 hours);
        strategy.nav(); // no revert: nothing held, so nothing reads the reward feed
    }

    // ====== 5. THE ASYNC REDEEM SELLS THE TRANCHE ITS OWN UNWIND CLAIMS (review round 2, item 2) ======
    // The redeem's own unwind auto-claims a tranche through `gauge.withdraw`, and step E sweeps only the two
    // LEG tokens — so the redeemer used to be paid `f × (assets − reward)` while 100% of the tranche stayed
    // behind, a nav-vs-payout inconsistency. The redeem now sells it best-effort and splits `f / (1−f)`.

    /// @dev Model a gauge that genuinely OWES `amount`: `earned()` reports it AND either claim path pays it.
    function _armGaugeAccrual(uint256 amount) internal {
        aero.mint(address(gauge), amount);
        gauge.setEarnedAmount(amount);
        gauge.setAeroToPayOnWithdraw(amount);
        gauge.setAeroToPayOnGetReward(amount);
    }

    /// @dev Escrow + fulfil a proportional redeem of `shares` for `lp`; returns the USDC they were paid.
    function _asyncRedeem(uint256 shares) internal returns (uint256 paid) {
        vm.prank(lp);
        vault.approve(address(strategy), shares);
        vm.prank(lp);
        uint256 id = strategy.requestRedeem(shares, 0, address(0));
        uint256 before = usdc.balanceOf(lp);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
        return usdc.balanceOf(lp) - before;
    }

    /// @dev THE FINDING: across two runs the payout DIFFERENCE must be the redeemer's pro-rata `f` slice.
    function testAsyncRedeemPaysTheRedeemerTheirProRataShareOfItsOwnAutoClaim() public {
        _armBook();
        uint256 shares = SHARES / 4; // f = 25%
        uint256 supply = vault.totalSupply();

        uint256 snap = vm.snapshotState();
        uint256 paidNoReward = _asyncRedeem(shares);
        vm.revertToState(snap);

        _armGaugeAccrual(TRANCHE);
        uint256 paidWithReward = _asyncRedeem(shares);

        assertEq(aero.balanceOf(address(strategy)), 0, "the auto-claimed tranche was SOLD, not left behind");
        uint256 expected = Math.mulDiv(_heldAeroValueUsdc(TRANCHE), shares, supply);
        assertApproxEqRel(
            paidWithReward - paidNoReward, expected, 1e15, "redeemer paid exactly f x the tranche, no more"
        );
    }

    /// @dev THE OTHER HALF: the stayers keep NAV/share — the sale changes the form of `(1−f)`, not its value.
    function testAsyncRedeemLeavesStayerNavPerShareContinuous() public {
        _armBook();
        _armGaugeAccrual(TRANCHE);
        uint256 shares = SHARES / 4;

        uint256 navPerShareBefore = Math.mulDiv(strategy.nav(), 1e18, vault.totalSupply());
        _asyncRedeem(shares);
        uint256 navPerShareAfter = Math.mulDiv(strategy.nav(), 1e18, vault.totalSupply());

        assertApproxEqRel(navPerShareAfter, navPerShareBefore, 1e15, "stayers' NAV/share unchanged by the redeem");
        // ...and the stayers' `(1-f)` really is sitting in the strategy as USDC, not as an unsold tranche.
        assertEq(aero.balanceOf(address(strategy)), 0, "nothing left unsold");
        assertGt(usdc.balanceOf(address(strategy)), 0, "the stayers' reserved slice stayed behind, in USDC");
    }

    /// @dev THE DEADMAN + THE RESIDUAL: a stale reward feed fails the sale CLOSED in its own frame and the
    ///      redeem still completes — the residual stays with the stayers, MARKED rather than silent.
    function testAStaleRewardFeedDefersTheRedeemSaleWithoutBlockingTheRedeem() public {
        _armBook();
        _armGaugeAccrual(TRANCHE);
        uint256 shares = SHARES / 4;

        // Every feed but the reward feed stays fresh, so ONLY the reward sale is unpriceable.
        aeroFeed.setUpdatedAt(block.timestamp - 2 hours);

        vm.recordLogs();
        uint256 paid = _asyncRedeem(shares);

        assertGt(paid, 0, "the redeem completed and paid - the deadman is intact");
        assertEq(aero.balanceOf(address(strategy)), TRANCHE, "THE RESIDUAL: the tranche stayed, unsold");
        assertTrue(
            _sawFrom(address(strategy), LeveragedAerodromeCLStrategy.RedeemRewardSaleDeferred.selector),
            "the deferral is MARKED on chain, from the strategy address"
        );
    }

    /// @dev True if the recorded logs contain `topic` emitted by `emitter` (libraries emit from the clone).
    function _sawFrom(address emitter, bytes32 topic) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    /// @dev THE OTHER DIRECTION — an event that always fires says nothing: a redeem whose reward sale
    ///      SUCCEEDS must mark no degradation, and neither must the normally-derived sweep floors.
    function testAHealthyRedeemMarksNoDegradation() public {
        _armBook();
        _armGaugeAccrual(TRANCHE);

        vm.recordLogs();
        _asyncRedeem(SHARES / 4);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.RedeemRewardSaleDeferred.selector,
                "the sale succeeded - nothing was deferred"
            );
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.RedeemSweepFloorsDegraded.selector,
                "the floors were derived - nothing was degraded"
            );
        }
        assertEq(aero.balanceOf(address(strategy)), 0, "sanity: the sale really did run");
    }

    /// @dev A FULL redeem (f = 1) takes the WHOLE tranche: the `(1−f)` reservation collapses to 0 by
    ///      construction rather than by a branch.
    function testAFullAsyncRedeemTakesTheWholeAutoClaimedTranche() public {
        _armBook();
        _armGaugeAccrual(TRANCHE);
        uint256 supply = vault.totalSupply();

        uint256 snap = vm.snapshotState();
        uint256 paidNoReward;
        {
            gauge.setEarnedAmount(0);
            gauge.setAeroToPayOnWithdraw(0);
            paidNoReward = _asyncRedeem(supply);
        }
        vm.revertToState(snap);

        uint256 paidWithReward = _asyncRedeem(supply);

        assertApproxEqRel(
            paidWithReward - paidNoReward, _heldAeroValueUsdc(TRANCHE), 1e15, "the sole holder takes all of it"
        );
        assertEq(strategy.layout().tokenId, 0, "flat-book invariant still restored");
    }

    /// @dev A REWARD-FREE REDEEM IS BYTE-IDENTICAL: the sale early-returns on a zero balance, so the common
    ///      redeem gains no behaviour, no oracle dependency and no swap.
    function testARewardFreeAsyncRedeemIsUnchanged() public {
        _armBook();
        uint256 shares = SHARES / 4;

        uint256 routerBefore = usdc.balanceOf(AERO_V2_ROUTER);
        uint256 stayersIdleBefore = usdc.balanceOf(address(strategy));
        uint256 paid = _asyncRedeem(shares);

        assertGt(paid, 0, "redeemer paid");
        assertEq(usdc.balanceOf(AERO_V2_ROUTER), routerBefore, "no reward swap was routed");
        assertLe(usdc.balanceOf(address(strategy)), stayersIdleBefore, "no extra USDC was reserved for stayers");
    }

    // ====== 6. `rewardReadOk()`: THE MARKER ON nav()'s ONE FAIL-OPEN (review round 3, items 1-2) ======
    // `_rewardUsdc`'s `catch {}` is the only fail-open here with no instrumentation and no transaction scope:
    // an `earned()` reverting for a non-`"NA"` reason silently restores the section-4 mis-pricing on every
    // block. `nav()` is a `view` and cannot emit, so the instrumentation is readable state.

    /// @dev Etch a code-less account over the gauge: the venue is "gone" as far as the EVM is concerned.
    ///      Etching is the only way there — `applyVenue` validates the gauge at init and at every migration.
    function _emptyTheGauge() internal {
        vm.etch(address(gauge), "");
    }

    /// @dev THE HEALTHY STAKED BOOK reports `true` with an accrual outstanding AND with it at zero: "OK" is
    ///      about whether the READ ANSWERED, not about the answer being non-zero.
    function testRewardReadOkIsTrueOnAHealthyStakedBook() public {
        _armBook();
        assertGt(strategy.layout().tokenId, 0, "staked book - there is something to read");
        assertEq(gauge.earnedAmount(), 0, "nothing accrued yet");
        assertTrue(strategy.rewardReadOk(), "a zero accrual is still a successful read");

        _armRewards(TRANCHE);
        assertTrue(strategy.rewardReadOk(), "...and so is a non-zero one");
    }

    /// @dev THE FLAT BOOK reports `true`: `tokenId == 0` makes no `earned()` call at all, so there is no
    ///      failing read to report — `false` here would scream through every `settle`→`execute` gap.
    function testRewardReadOkIsTrueOnAFlatBook() public {
        _armBook();
        vm.prank(address(vault));
        strategy.settle();

        assertEq(strategy.layout().tokenId, 0, "flat book");
        // Even with EVERY `earned()` call reverting, the flat book is OK: the call is never made.
        vm.mockCallRevert(address(gauge), abi.encodeWithSelector(gauge.earned.selector), bytes("NA"));
        assertTrue(strategy.rewardReadOk(), "nothing staked, nothing to read, nothing to report");
    }

    /// @dev THE FINDING: a staked tokenId whose `earned()` REVERTS reports `false` — the state `nav()` absorbs
    ///      silently. The marker deliberately does not separate a benign `"NA"` from a real outage.
    function testRewardReadOkIsFalseWhenEarnedRevertsOnAStakedTokenId() public {
        _armBook();
        assertTrue(strategy.rewardReadOk(), "healthy to begin with");

        vm.mockCallRevert(address(gauge), abi.encodeWithSelector(gauge.earned.selector), bytes("NA"));
        assertFalse(strategy.rewardReadOk(), "a staked tokenId whose earned() reverts is NOT ok");

        // Not specific to `"NA"`: ANY revert reason lands in the same catch, which is the whole problem.
        vm.mockCallRevert(
            address(gauge), abi.encodeWithSelector(gauge.earned.selector), abi.encodeWithSignature("Boom()")
        );
        assertFalse(strategy.rewardReadOk(), "a non-NA revert - the case the catch was never written for");
    }

    /// @dev A GAUGE WITHOUT CODE reports `false`, which is what makes the `code.length` precheck LOAD-BEARING:
    ///      solc emits the `extcodesize` guard OUTSIDE the try's protected region, so an empty-code target
    ///      reverts UNCATCHABLY. MUTATION: without the precheck the marker reverts when the venue is gone.
    function testRewardReadOkIsFalseWhenTheGaugeHasNoCode() public {
        _armBook();
        assertTrue(strategy.rewardReadOk(), "healthy to begin with");

        _emptyTheGauge();
        assertEq(address(gauge).code.length, 0, "the venue is gone");
        assertFalse(strategy.rewardReadOk(), "no code, no read, not ok");

        // The ORDER of the two reward reads: `nav()` is unaffected here not because anything absorbed the
        // failure, but because `_rewardUsdc`'s earlier `rewardToken()` read already fail-closes the call.
        vm.expectRevert(bytes(""));
        strategy.nav();
    }

    /// @dev THE BEHAVIOUR-NEUTRALITY CONTRACT, both directions: a REVERTING `earned()` still catches to 0 and
    ///      `nav()` prices the held balance without reverting, and a HEALTHY one is still priced in full. The
    ///      reverting leg holds a tranche too, so the assertion is on a real number, not a reward-free `nav()`.
    function testTheMarkerDoesNotMoveNav() public {
        _armBook();
        uint256 navBare = strategy.nav();

        // Healthy: the accrual is priced, exactly as before the marker existed.
        _armRewards(TRANCHE);
        assertEq(strategy.nav(), navBare + _heldAeroValueUsdc(TRANCHE), "a healthy earned() is still priced");

        // Degraded: a non-`"NA"` revert. The earned term drops to 0 and only the HELD tranche is priced.
        _clearRewards();
        aero.mint(address(strategy), TRANCHE);
        vm.mockCallRevert(
            address(gauge), abi.encodeWithSelector(gauge.earned.selector), abi.encodeWithSignature("Boom()")
        );
        gauge.setEarnedAmount(TRANCHE); // would be priced if the read answered

        assertEq(strategy.nav(), navBare + _heldAeroValueUsdc(TRANCHE), "catch-to-0: held only, and no revert");
        assertFalse(strategy.rewardReadOk(), "...and THAT is the state the marker exists to expose");
    }

    // ====== 7. THE REWARD-SALE FLOOR PRICES THROUGH THE USDC PEG (F21) ======
    // The floor is post-checked against a USDC-FACE fill, so the AERO/USD value has to be divided by the
    // USDC/USD price. The old `/1e20` broke in BOTH directions — lax below peg, unclearable above it.

    /// @dev BELOW PEG, the lax direction: at $0.90/USDC a face-rate fill is ~10% under. MUTATION: `/1e20` clears it.
    function testTheRewardFloorCatchesAnUnderFillWhenUsdcIsBelowPeg() public {
        _armBook();
        _armRewards(20_000e18);
        usdcFeed.setAnswer(0.9e8);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroManager.BelowOracleFloor.selector);
        strategy.compound(1, 0);
    }

    /// @dev BELOW PEG, the control: a peg-aware fair fill clears, so the fix is a re-basing not a tightening.
    function testAPegAwareFairFillClearsTheFloorBelowPeg() public {
        _armBook();
        _armRewards(20_000e18);
        usdcFeed.setAnswer(0.9e8);
        _setAeroRouterRate((1e6 * 1e8) / uint256(0.9e8));

        uint256 collateralBefore = _collateralUsdc();
        _compound(1);

        assertEq(aero.balanceOf(address(strategy)), 0, "the fair fill cleared the floor");
        assertGt(_collateralUsdc(), collateralBefore, "...and the harvest redeployed");
    }

    /// @dev ABOVE PEG, the bricking direction: an honest fill pays FEWER USDC per AERO, which the old floor
    ///      read as an under-fill and stuck `compound`. MUTATION: `/1e20` reverts here.
    function testAnHonestFillIsNotBrickedWhenUsdcIsAbovePeg() public {
        _armBook();
        _armRewards(20_000e18);
        usdcFeed.setAnswer(1.02e8);
        _setAeroRouterRate((1e6 * 1e8) / uint256(1.02e8));

        uint256 collateralBefore = _collateralUsdc();
        _compound(1);

        assertEq(aero.balanceOf(address(strategy)), 0, "the honest fill was accepted");
        assertGt(_collateralUsdc(), collateralBefore, "...and the harvest redeployed");
    }

    // ====== 8. THE FULL-REDEEM cTOKEN BURN PAYS THE FRESH-RATE SURPLUS (F16) ======

    /// @dev Fast-path exit of `shares` for `lp`; returns the USDC they were paid.
    function _fastRedeem(uint256 shares) internal returns (uint256 paid) {
        vm.prank(lp);
        vault.approve(address(strategy), shares);
        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        strategy.redeem(shares, 0);
        return usdc.balanceOf(lp) - before;
    }

    /// @dev `redeemUnderlying(amt)` accrues, then burns `amt / freshRate` — leaving `cBal x (1 − stored/fresh)`
    ///      behind as assets with no shares. The full-redeem branch burns the whole cTOKEN balance instead and
    ///      pays the surplus over `collateralUsdc`. MUTATION: `redeemUnderlying` on this branch strands the
    ///      rate gap in the strategy and leaves a cToken residue; both are pinned below.
    function testTheFullRedeemBurnsTheWholeCTokenBalanceAndPaysTheRateGap() public {
        _armBook();
        // `MockNpm` custodies only what it was minted; float the re-priced remainder as other LPs do.
        usdc.mint(address(npm), 1_000e6);
        legA.mint(address(npm), 1_000e8);
        vm.prank(proposer);
        strategy.flatten(0, 1); // flat, zero debt -- the burn branch's gate
        uint256 pot = usdc.balanceOf(address(strategy));
        vm.prank(proposer);
        strategy.supplyIdle(pot); // whole pot as collateral, nothing raw

        uint256 cBal = mUsdc.balanceOf(address(strategy));
        mUsdc.setExchangeRateStored(1.37e18); // C at the stored rate -- what the quote prices
        mUsdc.setPendingExchangeRate(1.4e18); // ...which the burn accrues past
        uint256 cStored = (cBal * 1.37e18) / 1e18;
        uint256 cFresh = (cBal * 1.4e18) / 1e18;

        (uint256 quoted,) = strategy.previewRedeem(SHARES);
        assertEq(quoted, cStored, "the quote prices the stored rate");

        uint256 out = _fastRedeem(SHARES);

        assertEq(out, cFresh, "the redeemer was paid the whole fresh-rate book, quote plus the gap");
        assertEq(out, quoted + (cFresh - cStored), "...which is exactly the surplus formula");
        assertEq(usdc.balanceOf(address(strategy)), 0, "nothing stranded behind the last shares");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "no cToken residue either");
    }

    // ====== 9. THE REDEPLOY IS ATOMIC WITH THE HARVEST (F20) ======

    /// @dev A blocked redeploy unwinds the WHOLE `compound` — claim, sale and hedge — deliberately: a
    ///      best-effort catch would turn `minLiquidity`, the calm gate and the health assert into no-ops on
    ///      the one path that adds leverage. Recovery after F06 needs a `rerange` AND price entering the band.
    function testCompoundIsAtomicWithTheRedeployAndRerangeRestoresIt() public {
        _armBook();
        mLegA.accrueBorrowInterest(address(strategy), _debtLegA() / 100);
        _armRewards(20_000e18);
        uint256 driftBefore = _driftLegA();
        assertGt(driftBefore, 0, "fixture: there is a drift for the harvest to hedge");

        // `MockNpm` custodies only what it was minted, so float the re-priced remainder as other LPs do.
        legA.mint(address(npm), 1_000_000e8);
        usdc.mint(address(npm), 100_000_000e6);
        _movePriceTo(strategy.layout().posTickUpper + 5000);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroValuation.DegenerateRange.selector);
        strategy.compound(1, 0);

        // NOTHING happened. Not a partial harvest — the claim and the sale rolled back with the redeploy.
        assertEq(gauge.earnedAmount(), 20_000e18, "the tranche is untouched, still accruing in the gauge");
        assertEq(aero.balanceOf(address(strategy)), 0, "nothing was claimed");
        assertEq(_driftLegA(), driftBefore, "and the hedge did not happen either");

        // Recovery: reopen the range, then let price come into it. The rerange's unwind auto-claims the
        // tranche as a HELD balance (arm that, then clear the gauge — once paid there is nothing left).
        gauge.setAeroToPayOnWithdraw(20_000e18);
        vm.prank(proposer);
        strategy.rerange(WIDTH, 5000, 0, 0);
        gauge.setAeroToPayOnWithdraw(0);
        _clearRewards();
        assertEq(aero.balanceOf(address(strategy)), 20_000e18, "the tranche survived as a held balance");

        int24 lower = strategy.layout().posTickLower;
        int24 upper = strategy.layout().posTickUpper;
        _movePriceTo(lower + (upper - lower) / 2);

        _compound(1);

        assertEq(aero.balanceOf(address(strategy)), 0, "the harvest went through this time");
        assertLt(_driftLegA(), driftBefore, "...and the carried drift was hedged");
    }
}
