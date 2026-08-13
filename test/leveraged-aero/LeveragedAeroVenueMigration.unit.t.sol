// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAeroValuation} from "@contracts/leveraged-aero/LeveragedAeroValuation.sol";
import {LeveragedAeroVenue} from "@contracts/leveraged-aero/LeveragedAeroVenue.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "@contracts/leveraged-aero/sherwood/BaseStrategy.sol";
import {ChainlinkReader} from "@contracts/leveraged-aero/sherwood/libraries/ChainlinkReader.sol";
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

/**
 * @title Owner-staged venue migration — flatten / stage / migrate / redeploy
 * @notice End-to-end coverage of the in-place pool/pair migration: the proposer flattens the book to
 *         idle USDC (staying `Executed`), the VAULT OWNER stages a hash-committed destination venue,
 *         the proposer executes the byte-exact rewrite on the flat book, and `redeploy` re-opens a
 *         fresh position in the destination venue. Continuity invariants (NAV, share balances,
 *         pending redeem requests, old-leg rescue) are asserted across the whole sequence.
 *
 * @dev Fixture: venue A is the TwoLegLifecycle fixture verbatim (legB 8dp / legA 18dp, both
 *      borrowed, `wethIsToken0 == false`). Venue B is a genuinely distinct cross-pair venue
 *      (fresh tokens/markets/feeds/pool/gauge) that deliberately reuses venue A's PRICES and TICK so
 *      the post-migration lifecycle runs on the same known-good geometry. Venue C is an asset-mode
 *      config (`cbBTC` slot == usdc) used to pin the shape re-derivation; migrate-only (validation
 *      reads no pool price), so it needs no tick setup. Fees off.
 */
contract LeveragedAeroVenueMigrationUnitTest is Test {
    address internal owner = makeAddr("owner");
    address internal proposer = makeAddr("proposer");
    address internal lp = makeAddr("lp");

    // ── shared core ──
    MockToken internal usdc;
    MockToken internal aero;
    MockCLFactory internal clFactory;
    MockComptroller internal comptroller;
    MockLendingMarket internal mUsdc;
    MockNpm internal npm;
    MockClSwapRouter internal router;
    MockChainlinkFeed internal usdcFeed;
    MockChainlinkFeed internal aeroFeed;
    MockChainlinkFeed internal sequencerFeed;

    // ── venue A (initial) ──
    MockToken internal legB;
    MockToken internal legA;
    MockCLPool internal pool;
    MockCLGauge internal gauge;
    MockLendingMarket internal mLegB;
    MockLendingMarket internal mLegA;
    MockChainlinkFeed internal legBFeed;
    MockChainlinkFeed internal legAFeed;

    // ── venue B (cross-pair destination) ──
    MockToken internal legB2;
    MockToken internal legA2;
    MockCLPool internal poolB;
    MockCLGauge internal gaugeB;
    MockLendingMarket internal mLegB2;
    MockLendingMarket internal mLegA2;
    MockChainlinkFeed internal legB2Feed;
    MockChainlinkFeed internal legA2Feed;

    // ── venue C (asset-mode destination: {usdc, legA2}) ──
    MockCLPool internal poolC;
    MockCLGauge internal gaugeC;

    LeveragedAeroVault internal vault;
    LeveragedAerodromeCLStrategy internal strategy;

    int24 internal constant SPACING = 100;
    int24 internal constant SPACING_B = 200; // venue B uses a different LP spacing on purpose
    int24 internal constant LEG_B_SWAP_SPACING = 100;
    int24 internal constant LEG_A_SWAP_SPACING = 200;
    int24 internal constant LEG_B2_SWAP_SPACING = 100;
    int24 internal constant LEG_A2_SWAP_SPACING = 200;
    uint24 internal constant WIDTH = 4000;
    /// @dev The centred skew — `width/2` each side, i.e. the pre-skew behaviour. The skew triple is
    ///      NON-migratable core (not in `VenueParams`), but `applyVenue` re-validates the LIVE skew
    ///      against the destination's `(width, tickSpacing)` — see `testMigrateRejectsADestinationThatStarvesTheLiveSkew`.
    uint16 internal constant SKEW_CENTERED = 5000;
    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint256 internal constant P_USDC = 1e8;
    uint256 internal constant SEED = 1_000_000e6;
    /// @dev Venue B reuses venue A's prices/tick so the redeployed lifecycle runs known-good geometry.
    uint256 internal constant P_LEG_B = 1e13; // $100k @ 8dp (legB AND legB2)
    uint256 internal constant P_LEG_A = 3000e8; // $3k @ 18dp (legA AND legA2)
    int24 internal constant TICK = 311_100;

    /// @dev The Aerodrome v2 router address `LeveragedAeroValuation.swapAeroToUsdc` hardcodes for the
    ///      reward sale. `MockAeroV2Router` is etched there so `flatten`'s reward leg is exercised
    ///      for real (immutables live in runtime bytecode, so the etched copy keeps its config).
    address internal constant AERO_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    /// @dev Split into per-venue frames: one flat setUp of this size overflows the Yul stack
    ///      under via_ir (each helper keeps its locals in its own frame).
    /// @dev Aerodrome v2 PoolFactory, hardcoded in `LeveragedAeroValuation` and probed by venue
    ///      validation to prove the reward token has a USDC route. Etched below (no code otherwise).
    address internal constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @dev `LeveragedAeroVenue.applyVenue` pins the canonical Slipstream CLFactory rather than
    ///      trusting `pool.factory()`, so a fork-free test has to place the registry HERE, and every
    ///      destination pool must be REGISTERED at its declared pair + spacing to be adoptable.
    ///      Etch is safe despite `MockCLFactory` being storage-based: only the code is copied, and
    ///      every `setPool` below writes to the etched address's own storage.
    address internal constant AERODROME_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    function setUp() public {
        vm.warp(1_800_000_000);
        // EXTERNAL self-calls, not internal helpers: via_ir re-inlines single-call-site internal
        // functions straight back into setUp, recreating the overflowing frame. `this.` forces a
        // real call frame per stage.
        this.setUpCore();
        this.setUpVenueA();
        this.setUpVenueB();
        this.setUpVenueC();
        this.fundVenues();
        this.deployStack();
    }

    function setUpCore() external {
        usdc = new MockToken("USD Coin", "USDC", 6);
        aero = new MockToken("Aerodrome", "AERO", 18);
        clFactory = MockCLFactory(AERODROME_CL_FACTORY);
        vm.etch(AERODROME_CL_FACTORY, address(new MockCLFactory()).code);
        comptroller = new MockComptroller();
        mUsdc = new MockLendingMarket(address(usdc));
        router = new MockClSwapRouter();
        sequencerFeed = new MockChainlinkFeed(0, 8, 1, block.timestamp - 2 hours);
        usdcFeed = new MockChainlinkFeed(int256(P_USDC), 8, 1, block.timestamp);
        aeroFeed = new MockChainlinkFeed(1e8, 8, 1, block.timestamp);
    }

    function setUpVenueA() external {
        legB = new MockToken("Leg B", "LEGB", 8);
        legA = new MockToken("Leg A", "LEGA", 18);
        pool = new MockCLPool(address(legB), address(legA), SPACING);
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK));
        pool.setTick(TICK);
        pool.setFactory(AERODROME_CL_FACTORY);
        clFactory.setPool(address(legB), address(legA), SPACING, address(pool));
        clFactory.setPool(address(usdc), address(legB), LEG_B_SWAP_SPACING, makeAddr("legBSwapPool"));
        clFactory.setPool(address(usdc), address(legA), LEG_A_SWAP_SPACING, makeAddr("legASwapPool"));
        gauge = new MockCLGauge(address(aero));
        gauge.setPool(address(pool));
        pool.setGauge(address(gauge));
        // The reward-route probe in venue validation reads a HARDCODED v2 factory address;
        // place code there so the AERO/USDC route resolves in this fork-free suite.
        vm.etch(AERO_V2_FACTORY, address(new MockAeroV2Factory(address(aero), address(usdc), address(0xA2F))).code);
        mLegB = new MockLendingMarket(address(legB));
        mLegA = new MockLendingMarket(address(legA));
        legBFeed = new MockChainlinkFeed(int256(P_LEG_B), 8, 1, block.timestamp);
        legAFeed = new MockChainlinkFeed(int256(P_LEG_A), 8, 1, block.timestamp);
        npm = new MockNpm(pool);
        // Real ERC-721 custody: a staked position is OWNED by the gauge, so any liquidity call
        // that forgets to unstake first reverts here exactly as it would on chain.
        gauge.setNpm(address(npm));
    }

    /// @dev Cross-pair destination: same prices/tick as venue A, different spacing.
    function setUpVenueB() external {
        legB2 = new MockToken("Leg B2", "LEGB2", 8);
        legA2 = new MockToken("Leg A2", "LEGA2", 18);
        poolB = new MockCLPool(address(legB2), address(legA2), SPACING_B);
        poolB.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK));
        poolB.setTick(TICK);
        poolB.setFactory(AERODROME_CL_FACTORY);
        clFactory.setPool(address(legB2), address(legA2), SPACING_B, address(poolB));
        clFactory.setPool(address(usdc), address(legB2), LEG_B2_SWAP_SPACING, makeAddr("legB2SwapPool"));
        clFactory.setPool(address(usdc), address(legA2), LEG_A2_SWAP_SPACING, makeAddr("legA2SwapPool"));
        gaugeB = new MockCLGauge(address(aero));
        gaugeB.setPool(address(poolB));
        poolB.setGauge(address(gaugeB));
        gaugeB.setNpm(address(npm));
        mLegB2 = new MockLendingMarket(address(legB2));
        mLegA2 = new MockLendingMarket(address(legA2));
        legB2Feed = new MockChainlinkFeed(int256(P_LEG_B), 8, 1, block.timestamp);
        legA2Feed = new MockChainlinkFeed(int256(P_LEG_A), 8, 1, block.timestamp);
    }

    /// @dev Asset-mode destination {usdc, legA2}: migrate-only, so no price/tick setup needed.
    function setUpVenueC() external {
        poolC = new MockCLPool(address(usdc), address(legA2), SPACING);
        poolC.setFactory(AERODROME_CL_FACTORY);
        clFactory.setPool(address(usdc), address(legA2), SPACING, address(poolC));
        gaugeC = new MockCLGauge(address(aero));
        gaugeC.setPool(address(poolC));
        poolC.setGauge(address(gaugeC));
        gaugeC.setNpm(address(npm));
    }

    function fundVenues() external {
        // Reward-sale venue: 1 AERO -> 1 USDC, matching the 1e8 aeroFeed mark.
        MockAeroV2Router aeroRouterImpl = new MockAeroV2Router(address(aero), address(usdc), 1e6);
        vm.etch(AERO_V2_ROUTER, address(aeroRouterImpl).code);
        usdc.mint(AERO_V2_ROUTER, 100_000_000e6);

        usdc.mint(address(mUsdc), 100_000_000e6);
        legB.mint(address(mLegB), 1_000_000e8);
        legA.mint(address(mLegA), 1_000_000e18);
        legB2.mint(address(mLegB2), 1_000_000e8);
        legA2.mint(address(mLegA2), 1_000_000e18);
        usdc.mint(address(router), 100_000_000e6);
        legB.mint(address(router), 1_000_000e8);
        legA.mint(address(router), 1_000_000e18);
        legB2.mint(address(router), 1_000_000e8);
        legA2.mint(address(router), 1_000_000e18);
        router.setRate(address(legB), address(usdc), (P_LEG_B * 1e18) / (100 * 1e8));
        router.setRate(address(usdc), address(legB), (100 * 1e8 * 1e18) / P_LEG_B);
        router.setRate(address(legA), address(usdc), (P_LEG_A * 1e18) / (100 * 1e18));
        router.setRate(address(usdc), address(legA), (100 * 1e18 * 1e18) / P_LEG_A);
        router.setRate(address(legB2), address(usdc), (P_LEG_B * 1e18) / (100 * 1e8));
        router.setRate(address(usdc), address(legB2), (100 * 1e8 * 1e18) / P_LEG_B);
        router.setRate(address(legA2), address(usdc), (P_LEG_A * 1e18) / (100 * 1e18));
        router.setRate(address(usdc), address(legA2), (100 * 1e18 * 1e18) / P_LEG_A);
    }

    function deployStack() external {
        vault = new LeveragedAeroVault(address(usdc), owner, "Leveraged Aero Vault", "lvAERO");
        strategy = LeveragedAerodromeCLStrategy(payable(Clones.clone(address(new LeveragedAerodromeCLStrategy()))));
        strategy.initialize(address(vault), proposer, abi.encode(_paramsA()));

        vm.startPrank(owner);
        vault.setStrategy(address(strategy));
        vault.setOpenDeposits(true);
        vm.stopPrank();
    }

    // ==================== helpers ====================

    function _paramsA() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
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
        p.skewBps = SKEW_CENTERED;
        p.minSkewBps = 1000;
        p.maxSkewBps = 9000;
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

    /// @dev Venue A as a MIGRATION DESTINATION — the same venue `_baseParams()` initialises with,
    ///      marshalled as `VenueParams` so a test can migrate BACK to it. Every field must match
    ///      `_baseParams()`'s venue subset or the round trip is not a round trip.
    function _venueAParams() internal view returns (LeveragedAeroVenue.VenueParams memory v) {
        v.mCbBTC = address(mLegB);
        v.mWeth = address(mLegA);
        v.cbBTC = address(legB);
        v.weth = address(legA);
        v.pool = address(pool);
        v.gauge = address(gauge);
        v.cbBTCFeed = address(legBFeed);
        v.wethFeed = address(legAFeed);
        v.aeroUsdFeed = address(aeroFeed);
        v.tickSpacing = SPACING;
        v.cbBTCSwapTickSpacing = LEG_B_SWAP_SPACING;
        v.wethSwapTickSpacing = LEG_A_SWAP_SPACING;
        v.wethDeliversNative = false;
        v.width = WIDTH;
        v.minWidth = 200;
        v.maxWidth = 20_000;
        v.targetLtvBps = TARGET_LTV_BPS;
        v.maxLtvBps = 6500;
        v.minHealthBps = 12_000;
    }

    /// @dev Venue B (cross-pair): fresh legs/markets/feeds/pool/gauge, spacing 200, width band on grid.
    function _venueBParams() internal view returns (LeveragedAeroVenue.VenueParams memory v) {
        v.mCbBTC = address(mLegB2);
        v.mWeth = address(mLegA2);
        v.cbBTC = address(legB2);
        v.weth = address(legA2);
        v.pool = address(poolB);
        v.gauge = address(gaugeB);
        v.cbBTCFeed = address(legB2Feed);
        v.wethFeed = address(legA2Feed);
        v.aeroUsdFeed = address(aeroFeed);
        v.tickSpacing = SPACING_B;
        v.cbBTCSwapTickSpacing = LEG_B2_SWAP_SPACING;
        v.wethSwapTickSpacing = LEG_A2_SWAP_SPACING;
        v.wethDeliversNative = false;
        v.width = 4000;
        v.minWidth = 400;
        v.maxWidth = 20_000;
        v.targetLtvBps = 4000;
        v.maxLtvBps = 6000;
        v.minHealthBps = 12_000;
    }

    /// @dev Venue C (asset-mode flip): leg-B slot IS usdc — market pinned to mUsdc, feed to usdcFeed,
    ///      swap spacing 0, pool {usdc, legA2}.
    function _venueCParams() internal view returns (LeveragedAeroVenue.VenueParams memory v) {
        v = _venueBParams();
        v.mCbBTC = address(mUsdc);
        v.cbBTC = address(usdc);
        v.pool = address(poolC);
        v.gauge = address(gaugeC);
        v.cbBTCFeed = address(usdcFeed);
        v.tickSpacing = SPACING;
        v.cbBTCSwapTickSpacing = 0;
        v.minWidth = 200;
    }

    function _execute(uint256 amount) internal {
        usdc.mint(address(strategy), amount);
        vm.prank(address(vault));
        strategy.execute();
    }

    /// @dev `minRewardUsdcOut` is nonzero because several tests arm a gauge reward tranche; the L9
    ///      oracle floor is the binding guard on top of it. `minIdleUsdcOut` is 0 here so the helper
    ///      stays usable on an already-flat book; the dedicated tests below bound it explicitly.
    function _flatten() internal {
        vm.prank(proposer);
        strategy.flatten(1, 0);
    }

    function _stage(LeveragedAeroVenue.VenueParams memory v) internal {
        bytes32 h = keccak256(abi.encode(v));
        vm.prank(owner);
        strategy.stageVenue(h);
    }

    function _migrate(LeveragedAeroVenue.VenueParams memory v) internal {
        vm.prank(proposer);
        strategy.migrateVenue(v);
    }

    function _assertFlat() internal view {
        assertEq(strategy.layout().tokenId, 0, "no CL position");
        (uint128 hA, uint128 hB) = strategy.hedgedDebt();
        assertEq(hA, 0, "hedged basis A zero");
        assertEq(hB, 0, "hedged basis B zero");
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "no leg-B debt");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "no leg-A debt");
        assertEq(mUsdc.balanceOf(address(strategy)), 0, "no collateral");
    }

    // ==================== flatten ====================

    function testFlattenUnwindsWholeBookToIdleUsdcAndStaysExecuted() public {
        _execute(SEED);
        assertGt(strategy.layout().tokenId, 0, "book deployed");

        vm.expectEmit(false, false, false, false, address(strategy));
        emit LeveragedAeroVenue.Flattened(0); // amount unchecked (slippage-dependent)
        _flatten();

        _assertFlat();
        uint256 idle = usdc.balanceOf(address(strategy));
        // TIGHT on purpose: this fixture's swap mocks fill at exact oracle parity, so a lossless
        // unwind is the CORRECT expectation and the only permitted gap is integer rounding. A 2%
        // band here would let a real conservation bug through unnoticed.
        assertApproxEqRel(idle, SEED, 0.0001e18, "whole book realized as idle USDC (lossless fixture)");
        assertEq(strategy.nav(), idle, "flat NAV == idle USDC (oracle-free)");
        // Still Executed: the proposer-gated venue ops remain reachable (settle would brick them).
        vm.prank(proposer);
        strategy.rerange(WIDTH, SKEW_CENTERED, 0, 0); // flat-book no-op that requires State.Executed
    }

    function testFlattenRevertsForNonProposer() public {
        _execute(SEED);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        vm.prank(lp);
        strategy.flatten(1, 0);
    }

    function testFlattenIsIdempotentOnAFlatBook() public {
        _execute(SEED);
        _flatten();
        uint256 idleBefore = usdc.balanceOf(address(strategy));
        _flatten(); // second flatten: unwind/repays are no-ops
        assertEq(usdc.balanceOf(address(strategy)), idleBefore, "idle unchanged");
        _assertFlat();
    }

    function testDepositAndRedeemWorkOnAFlatBook() public {
        _execute(SEED);
        // Seed a depositor while the book is live so supply > 0.
        usdc.mint(lp, 200_000e6);
        vm.startPrank(lp);
        usdc.approve(address(strategy), 200_000e6);
        uint256 shares = strategy.deposit(100_000e6, 0);
        vm.stopPrank();

        _flatten();

        // Deposit prices against idle-USDC NAV.
        uint256 navBefore = strategy.nav();
        vm.prank(lp);
        uint256 shares2 = strategy.deposit(100_000e6, 0);
        assertGt(shares2, 0, "flat-book deposit mints");
        assertEq(strategy.nav(), navBefore + 100_000e6, "NAV grew by exactly the deposit");

        // Fast redeem funds entirely from idle (no collateral, no LTV gate).
        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.startPrank(lp);
        vault.approve(address(strategy), shares);
        uint256 out = strategy.redeem(shares, 0);
        vm.stopPrank();
        assertGt(out, 0, "flat-book redeem pays");
        assertEq(usdc.balanceOf(lp) - lpUsdcBefore, out, "payout delivered");
    }

    // ==================== flatten guards (audit findings 4 + 7) ====================

    /**
     * @dev REGRESSION (finding 4) — the unwind's `gauge.withdraw` auto-claims the pending reward
     *      tranche, and `settleImpl` sweeps only the two LEG tokens. Left unsold, that balance is
     *      invisible to `nav()` (the `tokenId == 0` branch prices idle USDC only), unsellable
     *      (`compound` early-returns on a flat book) and un-rescuable (`rescueToVault` denies the
     *      reward token while Executed) — so every deposit in the flat window buys a free claim on it.
     *      `flatten` must convert it, leaving the flat NAV equal to the whole book.
     */
    function testFlattenSellsTheAutoClaimedRewardTranche() public {
        _execute(SEED);
        // Arm a reward tranche paid out by the gauge on unstake, and a router rate to sell it at.
        uint256 tranche = 1000e18;
        aero.mint(address(gauge), tranche);
        gauge.setAeroToPayOnWithdraw(tranche);

        _flatten();

        assertEq(aero.balanceOf(address(strategy)), 0, "reward tranche sold, not stranded");
        // The proceeds are in the flat-book NAV, which is exactly the idle USDC balance.
        assertEq(strategy.nav(), usdc.balanceOf(address(strategy)), "flat NAV == idle USDC");
        assertGt(strategy.nav(), (SEED * 98) / 100 + 900e6, "reward proceeds landed in NAV");
    }

    /// @dev The reward sale is floored by the L9 oracle read on top of the caller's bound: a router
    ///      paying far under the AERO/USD mark must revert the whole flatten, not sell blind.
    function testFlattenRevertsWhenTheRewardSaleIsBelowTheOracleFloor() public {
        _execute(SEED);
        aero.mint(address(gauge), 1000e18);
        gauge.setAeroToPayOnWithdraw(1000e18);
        // Re-etch a router paying 50% under the 1e8 feed mark (immutables => new instance + etch).
        MockAeroV2Router cheap = new MockAeroV2Router(address(aero), address(usdc), 5e5);
        vm.etch(AERO_V2_ROUTER, address(cheap).code);

        vm.expectRevert(LeveragedAeroVenue.BelowOracleFloor.selector);
        vm.prank(proposer);
        strategy.flatten(1, 0);
    }

    /// @dev A reward balance with no caller floor is rejected (mirrors `compound`'s `ZeroMinOut`
    ///      belt); with NO reward balance the same call is a clean no-op, which is what keeps
    ///      `flatten` idempotent.
    function testFlattenRewardFloorIsRequiredOnlyWhenThereIsAReward() public {
        _execute(SEED);
        aero.mint(address(gauge), 1000e18);
        gauge.setAeroToPayOnWithdraw(1000e18);

        vm.expectRevert(LeveragedAeroVenue.ZeroMinOut.selector);
        vm.prank(proposer);
        strategy.flatten(0, 0);

        // No reward armed -> minRewardUsdcOut == 0 is fine.
        gauge.setAeroToPayOnWithdraw(0);
        vm.prank(proposer);
        strategy.flatten(0, 0);
        _assertFlat();
    }

    /**
     * @dev REGRESSION (dust-donation deadlock) — a reward balance worth under one micro-USD prices to
     *      a ZERO oracle floor and the router fills it at 0 USDC, so BOTH arguments used to be
     *      unsatisfiable: `0` hit `ZeroMinOut` and anything nonzero hit the router's own min-out
     *      check. Since nothing else can clear a reward balance on a live `Executed` book — `compound`
     *      early-returns once flat and reverts identically while live, and `rescueToVault` denies the
     *      reward token until `Settled` — a 1e6-wei donation permanently blocked `flatten`, and with it
     *      `migrateVenue`'s flat-book precondition. The sale is now skipped exactly where the floor
     *      rounds to 0, which is exactly where an unsold balance cannot move a 6dp NAV.
     */
    function testFlattenSurvivesARewardDustDonation() public {
        _execute(SEED);
        aero.mint(address(strategy), 1e6); // sub-micro-USD at the 1e8 (== $1) feed mark

        vm.prank(proposer);
        strategy.flatten(1, 0);

        _assertFlat();
        assertEq(aero.balanceOf(address(strategy)), 1e6, "dust left in place, not force-sold");
        assertEq(strategy.nav(), usdc.balanceOf(address(strategy)), "flat NAV still == idle USDC");
        // And the migration it used to block now completes.
        _stage(_venueBParams());
        _migrate(_venueBParams());
        assertEq(strategy.layout().pool, address(poolB), "migration no longer blocked by dust");
    }

    /// @dev The dust skip used to sit AFTER `readUsd8`, so dust still gated `flatten` on the reward
    ///      feed being healthy — and `flatten` is `migrateVenue`'s own precondition, which made a
    ///      feed outage plus one wei of donated dust enough to stall a migration for the duration of
    ///      the outage, for zero economic benefit. The oracle-free band now short-circuits first.
    function testFlattenIgnoresDustWithoutConsultingAStaleRewardFeed() public {
        _execute(SEED);
        aero.mint(address(strategy), 1e6);
        aeroFeed.setUpdatedAt(block.timestamp - 2 hours); // past the 1 hour maxDelay

        vm.prank(proposer);
        strategy.flatten(1, 0);

        _assertFlat();
        assertEq(aero.balanceOf(address(strategy)), 1e6, "dust left in place");
        // The migration the outage would otherwise have stalled still completes.
        _stage(_venueBParams());
        _migrate(_venueBParams());
        assertEq(strategy.layout().pool, address(poolB), "migration not stalled by a stale feed");
    }

    /// @dev The narrow half of the same branch, and the reason it is safe: the oracle-free band is
    ///      derived from a price CEILING, so anything above it still consults the feed and still
    ///      fails closed when that feed is stale. The band can only ever be narrower than the priced
    ///      `floor == 0` skip, never wider.
    function testFlattenStillFailsClosedOnAStaleFeedAboveTheOracleFreeBand() public {
        _execute(SEED);
        aero.mint(address(strategy), 1e9); // > 1e20 / REWARD_PRICE_CEILING_USD8 (== 1e8)
        aeroFeed.setUpdatedAt(block.timestamp - 2 hours);

        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        vm.prank(proposer);
        strategy.flatten(1, 0);
    }

    /// @dev The dust skip must NOT widen the guard for a real tranche: a balance whose oracle floor is
    ///      nonzero still has to clear both the caller's floor and the L9 post-check.
    function testFlattenStillSellsABalanceJustAboveTheDustThreshold() public {
        _execute(SEED);
        // 1e15 wei AERO × 1e8 / 1e20 == 1000 (6dp), and the `maxSlippageBps` haircut still leaves a
        // NONZERO floor — which is what separates "dust" from "small". (The threshold is the haircut
        // one, not the raw one: at 1e12 the raw floor is 1 unit and the haircut rounds it to 0.)
        aero.mint(address(gauge), 1e15);
        gauge.setAeroToPayOnWithdraw(1e15);

        vm.expectRevert(LeveragedAeroVenue.ZeroMinOut.selector);
        vm.prank(proposer);
        strategy.flatten(0, 0);

        vm.prank(proposer);
        strategy.flatten(1, 0);
        assertEq(aero.balanceOf(address(strategy)), 0, "above-dust balance is still sold");
    }

    /**
     * @dev REGRESSION (finding 7) — `settleImpl` carries no calm gate of its own, and
     *      `_unwindLiquidity` derives its `amount0Min`/`amount1Min` from the same `slot0()` it burns
     *      at, so those mins bind nothing against a shoved tick. `flatten` is proposer-callable and
     *      repeatable (unlike the terminal `settle` whose body it reuses), so it must gate like
     *      `rerange` does.
     */
    function testFlattenCalmGateBlocksAShovedTick() public {
        _execute(SEED);
        pool.setTick(TICK + 5000); // well past calmDeviationTicks = 100
        pool.setTwapTick(TICK);
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK + 5000));

        vm.expectRevert(LeveragedAeroValuation.CalmGateBreached.selector);
        vm.prank(proposer);
        strategy.flatten(1, 0);

        // The gate fired before the burn — the position is untouched and still staked.
        assertGt(strategy.layout().tokenId, 0, "position untouched");
        assertTrue(gauge.stakedContains(address(strategy), strategy.layout().tokenId), "still staked");
    }

    /// @dev REGRESSION (finding 7) — the caller's aggregate floor on the realised unwind. The
    ///      per-swap oracle floors only bound each leg at `maxSlippageBps` (init permits up to 10%);
    ///      this is the proposer's own bound on the total.
    function testFlattenHonoursTheCallerIdleFloor() public {
        _execute(SEED);
        uint256 unreachable = SEED * 2;

        // Selector-only: the realised idle depends on the unwind's slippage, and asserting the exact
        // figure here would pin an unrelated number rather than the guard.
        vm.expectPartialRevert(LeveragedAeroVenue.InsufficientIdleAfterFlatten.selector);
        vm.prank(proposer);
        strategy.flatten(1, unreachable);
    }

    /// @dev REGRESSION for the `_settleRepayDebts` stale-index bug. That function decides full-repay
    ///      (`type(uint256).max`) vs partial off a leg's debt read; the fix reads `borrowBalanceCurrent`
    ///      (which ACCRUES) instead of the stale `borrowBalanceStored`. The bug window: a leg whose
    ///      HELD balance covers the STORED debt but not the ACCRUED debt takes the `>= stored` full-repay
    ///      branch, approves only the held balance, and Moonwell's `repayBorrow` then capitalises and
    ///      pulls the larger ACCRUED debt — reverting the whole flatten, and with it `migrateVenue`'s
    ///      flat-book precondition. Construction: arm PENDING interest (invisible to `borrowBalanceStored`)
    ///      so accrued > stored, and mint a small cushion so each leg's held balance lands in
    ///      `[stored, accrued)`. With the fix, flatten reads the accrued debt, repays what it holds, and
    ///      `_settleShortfall` covers the remainder from collateral. Fails against the stored read.
    function testFlattenSurvivesPendingInterestBetweenStoredAndAccruedDebt() public {
        _execute(SEED);
        uint256 storedA = mLegA.borrowBalance(address(strategy));
        uint256 storedB = mLegB.borrowBalance(address(strategy));
        assertGt(storedA, 0, "leg A borrowed");
        assertGt(storedB, 0, "leg B borrowed");

        // Arm 20% of PENDING (un-capitalised) interest on each borrow: stored stays put, accrued jumps.
        mLegA.accruePendingBorrowInterest(address(strategy), storedA * 20 / 100);
        mLegB.accruePendingBorrowInterest(address(strategy), storedB * 20 / 100);
        assertEq(mLegA.borrowBalance(address(strategy)), storedA, "stored read is still the pre-accrual debt");
        assertGt(mLegA.borrowBalanceAccrued(address(strategy)), storedA, "accrued read reveals the gap");

        // Cushion each leg so the post-unwind held balance robustly clears STORED (genesis rounds the
        // LP down by dust) while staying well under ACCRUED — i.e. squarely inside the bug window.
        legA.mint(address(strategy), storedA * 3 / 100);
        legB.mint(address(strategy), storedB * 3 / 100);

        // With the fix this succeeds; against `borrowBalanceStored` the full-repay branch over-pulls
        // the accrued debt past the held-balance approval and the unwind reverts.
        vm.prank(proposer);
        strategy.flatten(1, 0);

        _assertFlat();
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg A debt fully cleared");
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg B debt fully cleared");
    }

    // ==================== staging ====================

    function testStageVenueIsVaultOwnerOnly() public {
        bytes32 h = keccak256("venue");
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotVaultOwner.selector);
        vm.prank(proposer);
        strategy.stageVenue(h);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotVaultOwner.selector);
        vm.prank(lp);
        strategy.stageVenue(h);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit LeveragedAeroVenue.VenueStaged(h);
        vm.prank(owner);
        strategy.stageVenue(h);
        assertEq(strategy.layout().stagedVenueHash, h, "hash staged");

        // Staging is inert: live venue untouched.
        assertEq(strategy.layout().pool, address(pool), "live venue unchanged");

        // Clear.
        vm.prank(owner);
        strategy.stageVenue(bytes32(0));
        assertEq(strategy.layout().stagedVenueHash, bytes32(0), "hash cleared");
    }

    // ==================== migrate: gates ====================

    function testMigrateRevertsWithoutAStagedHash() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        vm.expectRevert(LeveragedAeroVenue.VenueNotStaged.selector);
        vm.prank(proposer);
        strategy.migrateVenue(v);
    }

    function testMigrateRevertsWhenParamsDoNotMatchTheStagedHash() public {
        _execute(SEED);
        _flatten();
        _stage(_venueBParams());
        LeveragedAeroVenue.VenueParams memory tampered = _venueBParams();
        tampered.targetLtvBps = 5000; // one field off the committed config
        vm.expectRevert(LeveragedAeroVenue.VenueNotStaged.selector);
        vm.prank(proposer);
        strategy.migrateVenue(tampered);
    }

    function testMigrateRevertsWhileThePositionIsLive() public {
        _execute(SEED);
        _stage(_venueBParams());
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        vm.expectRevert(LeveragedAeroVenue.BookNotFlat.selector);
        vm.prank(proposer);
        strategy.migrateVenue(v);
        assertEq(strategy.layout().pool, address(pool), "venue untouched");
    }

    function testMigrateRevertsWhileLegDebtRemains() public {
        _execute(SEED);
        _flatten();
        // Manufacture residual debt on a flat book (donation-style borrow as the strategy).
        vm.prank(address(strategy));
        mLegA.borrow(1e18);
        _stage(_venueBParams());
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        vm.expectRevert(LeveragedAeroVenue.BookNotFlat.selector);
        vm.prank(proposer);
        strategy.migrateVenue(v);
    }

    function testMigrateRevertsForNonProposerIncludingOwner() public {
        _execute(SEED);
        _flatten();
        _stage(_venueBParams());
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        vm.prank(owner);
        strategy.migrateVenue(v);
    }

    // ==================== migrate: destination validation ====================

    function _expectMigrateRevert(LeveragedAeroVenue.VenueParams memory v, bytes4 err) internal {
        _stage(v);
        vm.expectRevert(err);
        vm.prank(proposer);
        strategy.migrateVenue(v);
        assertEq(strategy.layout().pool, address(pool), "venue untouched after rejected config");
    }

    function testMigrateRejectsAPoolThatIsNotTheDeclaredPair() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.cbBTC = address(legB); // old leg B — poolB's token set is {legB2, legA2}
        v.mCbBTC = address(mLegB);
        v.cbBTCFeed = address(legBFeed);
        _expectMigrateRevert(v, LeveragedAeroVenue.VenueMismatch.selector);
    }

    function testMigrateRejectsAGaugeNotBoundToThePool() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        MockCLGauge unbound = new MockCLGauge(address(aero)); // pool() == address(0)
        v.gauge = address(unbound);
        _expectMigrateRevert(v, LeveragedAeroVenue.VenueMismatch.selector);
    }

    /// @dev The gauge↔pool binding is checked in BOTH directions. `gauge.pool()` is self-attested by
    ///      the staged contract, so a hostile gauge returns the real pool for free; only the pool's own
    ///      `gauge()` (Voter-written on a real Slipstream pool) makes the pair non-forgeable.
    function testMigrateRejectsAGaugeThePoolDoesNotClaim() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        MockCLGauge impostor = new MockCLGauge(address(aero));
        impostor.setPool(address(poolB)); // passes the self-attested direction...
        // ...but poolB.gauge() still points at the real gaugeB.
        v.gauge = address(impostor);
        _expectMigrateRevert(v, LeveragedAeroVenue.VenueMismatch.selector);
    }

    // ==================== CANONICAL FACTORY BINDING (migrate side) ====================

    /// @dev The migrate-side half of the init binding: a destination pool is adoptable only if the
    ///      CANONICAL Slipstream factory registers it. A pool that nominates its own registry — the
    ///      self-attestation the binding removes — is rejected even when that registry vouches for
    ///      it completely. This is the seam that mattered most at runtime: init is deployer-driven,
    ///      whereas `migrateVenue` re-points a LIVE fund at a pool chosen months later.
    function testMigrateRejectsADestinationPoolThatNominatesAForeignFactory() public {
        _execute(SEED);
        _flatten();
        MockCLFactory rogue = new MockCLFactory();
        rogue.setPool(address(usdc), address(legB2), LEG_B2_SWAP_SPACING, makeAddr("rogueB2Swap"));
        rogue.setPool(address(usdc), address(legA2), LEG_A2_SWAP_SPACING, makeAddr("rogueA2Swap"));
        rogue.setPool(address(legB2), address(legA2), SPACING_B, address(poolB));
        poolB.setFactory(address(rogue));
        _expectMigrateRevert(_venueBParams(), LeveragedAeroVenue.VenueMismatch.selector);
    }

    /// @dev And the registration itself is load-bearing, not just the factory address.
    function testMigrateRejectsADestinationTheCanonicalFactoryDoesNotRegister() public {
        _execute(SEED);
        _flatten();
        clFactory.setPool(address(legB2), address(legA2), SPACING_B, address(0));
        _expectMigrateRevert(_venueBParams(), LeveragedAeroVenue.VenueMismatch.selector);
    }

    // ==================== ROUND TRIP ====================

    /// @dev A→B→A. Every prior migration test moves the fund ONE way, so nothing ever migrated OUT of
    ///      a venue with a different token ordering or shape — which is exactly why migrate-staleness
    ///      mutants on the DERIVED fields survived: a stale `wethIsToken0` / `legBIsAsset` / leg
    ///      decimals looks identical to a correct one until a second migration has to overwrite it.
    ///      Venue B is deliberately a different pair AND a different spacing, so the return leg has to
    ///      rewrite the derived set rather than leave it alone.
    function testMigrateRoundTripRestoresEveryDerivedField() public {
        _execute(SEED);
        _flatten();

        LeveragedAerodromeCLStrategy.LayoutView memory before = strategy.layout();
        assertFalse(before.wethIsToken0, "venue A sorts leg B first");

        // FLIP THE ORDERING on the destination. Without this the round trip is blind to the mutant
        // it exists to catch: venues A and B both sort leg B into token0, so a DELETED
        // `$.wethIsToken0` write is indistinguishable from a correct one and the mutant survives.
        // Verified: with the flip, deleting that write fails this test.
        poolB.setTokens(address(legA2), address(legB2));
        clFactory.setPool(address(legA2), address(legB2), SPACING_B, address(poolB));

        _stage(_venueBParams());
        _migrate(_venueBParams());
        assertEq(strategy.layout().pool, address(poolB), "outbound leg landed");
        assertTrue(strategy.layout().wethIsToken0, "ordering flipped on the way out");

        _stage(_venueAParams());
        _migrate(_venueAParams());

        LeveragedAerodromeCLStrategy.LayoutView memory afterTrip = strategy.layout();
        assertEq(afterTrip.pool, before.pool, "pool restored");
        assertEq(afterTrip.gauge, before.gauge, "gauge restored");
        assertEq(afterTrip.cbBTC, before.cbBTC, "leg B restored");
        assertEq(afterTrip.weth, before.weth, "leg A restored");
        assertEq(afterTrip.mCbBTC, before.mCbBTC, "leg B market restored");
        assertEq(afterTrip.mWeth, before.mWeth, "leg A market restored");
        assertEq(afterTrip.tickSpacing, before.tickSpacing, "spacing restored");
        // The DERIVED set — the fields a stale-write mutant leaves behind.
        assertEq(afterTrip.wethIsToken0, before.wethIsToken0, "ordering re-derived");
        assertEq(afterTrip.legBIsAsset, before.legBIsAsset, "shape re-derived");
        assertEq(afterTrip.cbBTCDecimals, before.cbBTCDecimals, "leg B decimals re-derived");
        assertEq(afterTrip.wethDecimals, before.wethDecimals, "leg A decimals re-derived");
    }

    /// @dev The shape half of the same gap: venue C is ASSET-MODE (`cbBTC == usdc`), so
    ///      `legBIsAsset` must flip false→true on the way out and true→false on the way back. Only a
    ///      migration OUT of asset mode can catch a stale write to it, and until now nothing migrated
    ///      out of anything.
    function testMigrateRoundTripThroughAssetModeRestoresTheShape() public {
        _execute(SEED);
        _flatten();

        LeveragedAerodromeCLStrategy.LayoutView memory before = strategy.layout();
        assertFalse(before.legBIsAsset, "venue A is the two-borrowed-legs shape");

        _stage(_venueCParams());
        _migrate(_venueCParams());
        assertTrue(strategy.layout().legBIsAsset, "asset mode adopted");

        _stage(_venueAParams());
        _migrate(_venueAParams());
        assertFalse(strategy.layout().legBIsAsset, "shape re-derived on the way back");
        assertEq(strategy.layout().cbBTC, before.cbBTC, "leg B is a real borrowed leg again");
        assertEq(strategy.layout().mCbBTC, before.mCbBTC, "leg B market restored");
        assertEq(strategy.layout().cbBTCSwapTickSpacing, before.cbBTCSwapTickSpacing, "leg B spacing restored");
    }

    /// @dev The leg-A DECIMALS half of the same gap. Venues A/B/C all carry an 18dp leg A, so the
    ///      `wethDecimals` value never changes across any migration among them and a stale
    ///      `$.wethDecimals = wethDec` write is invisible — the A↔B↔C round trips above pass even with
    ///      that write deleted. Venue D is a two-leg destination whose leg A is 8dp, so the migration
    ///      forces `wethDecimals` 18→8 and back, catching the stale write. Migrate-only (no redeploy),
    ///      so venue D needs no tick/price — `applyVenue` reads no pool price.
    function testMigrateRoundTripThroughAnEightDecimalLegARestoresTheDecimals() public {
        _execute(SEED);
        _flatten();

        LeveragedAerodromeCLStrategy.LayoutView memory before = strategy.layout();
        assertEq(before.wethDecimals, 18, "venue A leg A is 18dp");

        // ── Venue D: fresh 8dp leg A, reusing venue B's 8dp leg B + collateral market. ──
        MockToken legAD = new MockToken("Leg A 8dp", "LEGAD", 8);
        MockLendingMarket mLegAD = new MockLendingMarket(address(legAD));
        MockChainlinkFeed legADFeed = new MockChainlinkFeed(int256(P_LEG_A), 8, 1, block.timestamp);
        MockCLPool poolD = new MockCLPool(address(legB2), address(legAD), SPACING);
        poolD.setFactory(AERODROME_CL_FACTORY);
        clFactory.setPool(address(legB2), address(legAD), SPACING, address(poolD));
        clFactory.setPool(address(usdc), address(legAD), LEG_A_SWAP_SPACING, makeAddr("legADSwapPool"));
        MockCLGauge gaugeD = new MockCLGauge(address(aero));
        gaugeD.setPool(address(poolD));
        poolD.setGauge(address(gaugeD));
        gaugeD.setNpm(address(npm));

        LeveragedAeroVenue.VenueParams memory d = _venueBParams();
        d.mWeth = address(mLegAD);
        d.weth = address(legAD);
        d.wethFeed = address(legADFeed);
        d.pool = address(poolD);
        d.gauge = address(gaugeD);
        d.tickSpacing = SPACING;
        d.wethSwapTickSpacing = LEG_A_SWAP_SPACING;

        _stage(d);
        _migrate(d);
        assertEq(strategy.layout().wethDecimals, 8, "leg A decimals re-derived to 8 on the way out");

        _stage(_venueAParams());
        _migrate(_venueAParams());
        assertEq(strategy.layout().wethDecimals, before.wethDecimals, "leg A decimals restored to 18");
    }

    /// @dev The reward leg is a THIRD swap venue (Aerodrome v2, volatile, hardcoded route). Without a
    ///      probe, a gauge whose reward token has no v2/USDC pool passes every other check and then
    ///      reverts inside BOTH `compound` and `flatten` once a tranche accrues — permanently, since
    ///      `flatten` is also the precondition for migrating away.
    function testMigrateRejectsARewardTokenWithNoUsdcRoute() public {
        _execute(SEED);
        _flatten();
        MockToken orphanReward = new MockToken("Orphan", "ORPH", 18); // no pool in the v2 factory mock
        MockCLGauge orphanGauge = new MockCLGauge(address(orphanReward));
        orphanGauge.setPool(address(poolB));
        poolB.setGauge(address(orphanGauge));
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.gauge = address(orphanGauge);
        _expectMigrateRevert(v, LeveragedAeroVenue.VenueMismatch.selector);
    }

    /// @dev Leg feeds are validated at STAGE time, not only at read time. `readUsd8` does fail closed
    ///      on a non-8dp answer, but it fails after the venue is already adopted — bricking `redeploy`
    ///      on a fund that has no way back except re-staging.
    function testMigrateRejectsANonEightDecimalLegFeed() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.wethFeed = address(new MockChainlinkFeed(int256(1e18), 18, 1, block.timestamp));
        _expectMigrateRevert(v, LeveragedAeroVenue.UnexpectedFeedDecimals.selector);
    }

    function testMigrateRejectsAMissingLegSwapPool() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.cbBTCSwapTickSpacing = 300; // no legB2/USDC pool registered at this spacing
        _expectMigrateRevert(v, LeveragedAeroVenue.VenueMismatch.selector);
    }

    /**
     * @dev REGRESSION (finding 8) — the gauge is migratable, so `gauge.rewardToken()` can change. If
     *      the feed that prices that token stayed pinned to its init value, a migration would price
     *      reward token X with AERO's price and mis-scale the L9 harvest floor. The feed therefore
     *      lives in `VenueParams` and is validated + rewritten with the gauge.
     */
    function testMigrateRewritesTheRewardFeedWithTheGauge() public {
        _execute(SEED);
        _flatten();
        MockChainlinkFeed newRewardFeed = new MockChainlinkFeed(2e8, 8, 1, block.timestamp);
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.aeroUsdFeed = address(newRewardFeed);
        _stage(v);
        _migrate(v);
        assertEq(strategy.layout().aeroUsdFeed, address(newRewardFeed), "reward feed migrated with the gauge");
    }

    /// @dev The L9 scaling assumption (`mulDiv(bal, price8, 1e20)`) is asserted on the staged feed,
    ///      exactly as it was at init.
    function testMigrateRejectsANonEightDecimalRewardFeed() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.aeroUsdFeed = address(new MockChainlinkFeed(1e18, 18, 1, block.timestamp));
        _expectMigrateRevert(v, LeveragedAeroVenue.UnexpectedFeedDecimals.selector);
    }

    function testMigrateRejectsAZeroRewardFeed() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.aeroUsdFeed = address(0);
        _expectMigrateRevert(v, LeveragedAeroVenue.ZeroAddress.selector);
    }

    function testMigrateRejectsAnOffGridWidth() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.width = 4100; // off the 200 grid
        _expectMigrateRevert(v, LeveragedAeroValuation.OutOfBounds.selector);
    }

    /// @dev THE SKEW TRIPLE IS NOT IN `VenueParams` — it is venue-independent governance config, so a
    ///      migration never rewrites it. But `checkRange`'s one-spacing-per-side floor COUPLES the live
    ///      skew to `(width, tickSpacing)`, and a migration rewrites BOTH. `applyVenue` therefore
    ///      re-validates the STORED skew against the destination.
    ///
    ///      The pair below is the whole point, and the control half is what makes it a real test: the
    ///      SAME destination (venue B, spacing 200, width 400) is ACCEPTED at the standing centred skew
    ///      — spans 200/200, exactly one spacing each — and REJECTED once the live skew is 1000, where
    ///      the lower span collapses to 40 ticks against a 200 grid. Without the re-validation the
    ///      second case would migrate cleanly and then fail closed as `DegenerateRange` inside
    ///      `redeploy`, with the book already flat on a venue it could not re-enter.
    function testMigrateAcceptsADestinationTheLiveSkewStillFits() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.width = 400; // == minWidth, on the 200 grid; centred => spans 200 / 200
        _stage(v);
        _migrate(v);
        assertEq(strategy.layout().pool, address(poolB), "migrated to venue B");
        assertEq(strategy.layout().skewBps, SKEW_CENTERED, "skew is not venue state - untouched");
    }

    function testMigrateRejectsADestinationThatStarvesTheLiveSkew() public {
        _execute(SEED);
        _flatten();
        // Move the LIVE skew to the bottom of the governance band. Valid on venue A (width 4000,
        // spacing 100 => lower span 400 >= 100); a flat-book `rerange` persists the pair and no-ops.
        vm.prank(proposer);
        strategy.rerange(WIDTH, 1000, 0, 0);
        assertEq(strategy.layout().skewBps, 1000, "live skew persisted");

        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.width = 400; // spacing 200 => lower span 400 * 1000/1e4 = 40 < 200 -> starved
        _expectMigrateRevert(v, LeveragedAeroValuation.OutOfBounds.selector);
        assertEq(strategy.layout().skewBps, 1000, "rejected migrate leaves the skew alone too");
    }

    function testMigrateRejectsTargetLtvAboveMax() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.targetLtvBps = 6100; // > maxLtvBps 6000
        _expectMigrateRevert(v, LeveragedAeroValuation.TargetLtvExceedsMax.selector);
    }

    // ==================== migrate: happy paths ====================

    function testMigratePreservesNavSharesAndHwm() public {
        _execute(SEED);
        usdc.mint(lp, 100_000e6);
        vm.startPrank(lp);
        usdc.approve(address(strategy), 100_000e6);
        uint256 lpShares = strategy.deposit(100_000e6, 0);
        vm.stopPrank();

        _flatten();
        _stage(_venueBParams());

        uint256 navBefore = strategy.nav();
        uint256 hwmBefore = strategy.layout().hwmPerShare;

        vm.expectEmit(true, true, false, true, address(strategy));
        emit LeveragedAeroVenue.VenueMigrated(address(pool), address(poolB));
        _migrate(_venueBParams());

        // NAV + share ledger continuity across the rewrite.
        assertEq(strategy.nav(), navBefore, "NAV identical across the venue rewrite");
        assertEq(vault.balanceOf(lp), lpShares, "share balances untouched");
        assertEq(strategy.layout().hwmPerShare, hwmBefore, "HWM untouched");
        assertEq(strategy.layout().stagedVenueHash, bytes32(0), "staged hash consumed");
    }

    function testMigrateRewritesTheWholeVenueSubset() public {
        _execute(SEED);
        _flatten();
        _stage(_venueBParams());
        _migrate(_venueBParams());
        _assertVenueBApplied();
    }

    /// @dev Own frame (not inlined in the test) so the assert cascade's locals never share a stack
    ///      with the migration-driving frame — via_ir stack-depth hygiene.
    function _assertVenueBApplied() internal view {
        LeveragedAerodromeCLStrategy.LayoutView memory l = strategy.layout();
        assertEq(l.pool, address(poolB), "pool");
        assertEq(l.gauge, address(gaugeB), "gauge");
        assertEq(l.cbBTC, address(legB2), "leg B");
        assertEq(l.weth, address(legA2), "leg A");
        assertEq(l.mCbBTC, address(mLegB2), "market B");
        assertEq(l.mWeth, address(mLegA2), "market A");
        assertEq(l.cbBTCFeed, address(legB2Feed), "feed B");
        assertEq(l.wethFeed, address(legA2Feed), "feed A");
        assertEq(l.tickSpacing, SPACING_B, "spacing");
        assertEq(l.cbBTCSwapTickSpacing, LEG_B2_SWAP_SPACING, "swap spacing B");
        assertEq(l.wethSwapTickSpacing, LEG_A2_SWAP_SPACING, "swap spacing A");
        assertEq(l.width, 4000, "width");
        assertEq(l.minWidth, 400, "minWidth");
        assertEq(l.maxWidth, 20_000, "maxWidth");
        assertEq(l.targetLtvBps, 4000, "targetLtv");
        assertEq(l.maxLtvBps, 6000, "maxLtv");
        assertFalse(l.legBIsAsset, "still two-leg shape");
    }

    function testMigrateToAssetModeRederivesTheShape() public {
        _execute(SEED);
        _flatten();
        _stage(_venueCParams());
        _migrate(_venueCParams());

        LeveragedAerodromeCLStrategy.LayoutView memory l = strategy.layout();
        assertTrue(l.legBIsAsset, "asset-mode derived from config");
        assertEq(l.cbBTC, address(usdc), "leg B slot is the unit of account");
        assertEq(l.mCbBTC, address(mUsdc), "leg B market pinned to mUSDC");
        assertEq(l.cbBTCFeed, address(usdcFeed), "leg B feed pinned to USDC/USD");
        assertEq(l.cbBTCSwapTickSpacing, 0, "leg B swap spacing declared unused");
        assertFalse(l.wethIsToken0, "usdc is token0 in poolC");
        // CROSS-DECIMAL: venue A's leg B is 8dp, venue C's is USDC at 6dp. The stored decimals drive
        // every token↔USDC conversion, so a migration that failed to rewrite them would mis-scale the
        // whole book by 100x while every other assertion above still passed.
        assertEq(l.cbBTCDecimals, 6, "leg B decimals re-read at migrate (8dp -> 6dp)");
        assertEq(l.wethDecimals, 18, "leg A decimals re-read at migrate");
    }

    /**
     * @dev The scenario the reward feed lives in `VenueParams` FOR: a destination gauge that rewards a
     *      DIFFERENT token. Pinning the feed at init would price that token with AERO's mark and
     *      mis-scale the L9 harvest floor. Nothing exercised it end-to-end — both fixture gauges reward
     *      AERO — so this drives the full sequence and then sells a real tranche of the new token
     *      against the new feed.
     */
    function testMigrationToAGaugeWithADifferentRewardTokenHarvestsAgainstTheNewFeed() public {
        _execute(SEED);
        _flatten();

        MockToken newReward = new MockToken("Reward2", "RWD2", 18);
        MockChainlinkFeed newRewardFeed = new MockChainlinkFeed(2e8, 8, 1, block.timestamp); // $2
        MockCLGauge gaugeB2 = new MockCLGauge(address(newReward));
        gaugeB2.setPool(address(poolB));
        poolB.setGauge(address(gaugeB2));
        // The route probe and the sale both key off the destination's reward token now.
        vm.etch(AERO_V2_FACTORY, address(new MockAeroV2Factory(address(newReward), address(usdc), address(0xA2F))).code);

        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.gauge = address(gaugeB2);
        v.aeroUsdFeed = address(newRewardFeed);
        _stage(v);
        _migrate(v);
        assertEq(strategy.layout().aeroUsdFeed, address(newRewardFeed), "feed migrated with the gauge");

        npm.setPool(poolB);
        vm.prank(proposer);
        strategy.redeploy(0);

        // Arm a tranche of the NEW reward token and a router that fills it at the new feed's $2 mark.
        uint256 tranche = 1000e18;
        newReward.mint(address(gaugeB2), tranche);
        gaugeB2.setAeroToPayOnWithdraw(tranche);
        MockAeroV2Router r = new MockAeroV2Router(address(newReward), address(usdc), 2e6);
        vm.etch(AERO_V2_ROUTER, address(r).code);
        usdc.mint(AERO_V2_ROUTER, 100_000_000e6);

        vm.prank(proposer);
        strategy.flatten(1, 0);

        assertEq(newReward.balanceOf(address(strategy)), 0, "new reward token sold, not stranded");
        assertEq(aero.balanceOf(address(strategy)), 0, "old reward token not involved");
        assertEq(strategy.nav(), usdc.balanceOf(address(strategy)), "flat NAV == idle USDC");
    }

    // ==================== redeploy ====================

    function testRedeployOpensAFreshPositionInTheNewVenue() public {
        _execute(SEED);
        _flatten();
        _stage(_venueBParams());
        _migrate(_venueBParams());

        npm.setPool(poolB); // the mock NPM reads geometry off one pool; re-point it at venue B
        uint256 idle = usdc.balanceOf(address(strategy));

        vm.prank(proposer);
        strategy.redeploy(0);

        assertGt(strategy.layout().tokenId, 0, "fresh position minted");
        assertEq(gaugeB.depositCallCount(), 1, "staked in the NEW gauge");
        assertEq(gauge.depositCallCount(), 1, "old gauge untouched since genesis");
        // Whole idle deployed as collateral at the NEW venue's target LTV.
        uint256 collateral = (mUsdc.balanceOf(address(strategy)) * mUsdc.exchangeRateStored()) / 1e18;
        assertEq(collateral, idle, "entire idle became collateral");
        assertGt(mLegB2.borrowBalance(address(strategy)), 0, "borrows in the new leg-B market");
        assertGt(mLegA2.borrowBalance(address(strategy)), 0, "borrows in the new leg-A market");
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "no debt in the old markets");
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "no debt in the old markets");
    }

    function testRedeployRevertsWhileAPositionIsOpen() public {
        _execute(SEED);
        vm.expectRevert(LeveragedAeroVenue.PositionAlreadyOpen.selector);
        vm.prank(proposer);
        strategy.redeploy(0);
    }

    function testRedeployRevertsForNonProposer() public {
        _execute(SEED);
        _flatten();
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        vm.prank(lp);
        strategy.redeploy(0);
    }

    /// @dev `redeploy` is the ONE repeatable value-moving proposer op, and the mint's own §8 mins come
    ///      off the same `slot0()` the mint executes at — self-referential. The caller's floor is the
    ///      only bound that is not derived from the price being bounded.
    function testRedeployHonoursTheCallerLiquidityFloor() public {
        _execute(SEED);
        _flatten();

        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientLiquidity.selector);
        vm.prank(proposer);
        strategy.redeploy(type(uint128).max);

        assertEq(strategy.layout().tokenId, 0, "nothing opened when the floor is unmet");

        // A reachable floor still opens the position.
        vm.prank(proposer);
        strategy.redeploy(1);
        assertGt(strategy.layout().tokenId, 0, "position opened under a satisfiable floor");
    }

    /// @dev ROLLBACK (B → A): `flatten → redeploy` re-enters the ORIGINAL venue with nothing changed,
    ///      and the staged destination hash must NOT survive it. Leaving it armed would let the
    ///      proposer fire an owner authorization months later into conditions nobody re-evaluated —
    ///      the replay the migrate path already closes by consuming on use.
    function testRedeployRollsBackToTheOldVenueAndClearsTheStagedHash() public {
        _execute(SEED);
        _flatten();
        _stage(_venueBParams());
        assertTrue(strategy.layout().stagedVenueHash != bytes32(0), "hash armed");

        vm.prank(proposer);
        strategy.redeploy(0);

        assertEq(strategy.layout().stagedVenueHash, bytes32(0), "staged hash cleared by the rollback");
        assertEq(strategy.layout().pool, address(pool), "still on the ORIGINAL venue");
        assertEq(strategy.layout().gauge, address(gauge), "still on the original gauge");
        assertGt(strategy.layout().tokenId, 0, "position reopened on venue A");
        assertEq(gauge.depositCallCount(), 2, "restaked in the OLD gauge (genesis + rollback)");
        assertEq(gaugeB.depositCallCount(), 0, "venue B never touched");

        // And the abandoned authorization can no longer be executed without a fresh stage.
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        vm.expectRevert(LeveragedAeroVenue.VenueNotStaged.selector);
        vm.prank(proposer);
        strategy.migrateVenue(v);
    }

    /// @dev Same-venue round trip with no migration in between — the plain "unwind, wait, re-enter"
    ///      operation, distinct from the rollback above in that nothing was ever staged.
    function testFlattenThenRedeployRoundTripsOnTheSameVenue() public {
        _execute(SEED);
        uint256 tokenIdBefore = strategy.layout().tokenId;
        uint256 navBefore = strategy.nav();

        _flatten();
        _assertFlat();
        vm.prank(proposer);
        strategy.redeploy(0);

        assertGt(strategy.layout().tokenId, 0, "reopened");
        assertTrue(strategy.layout().tokenId != tokenIdBefore, "a FRESH position, not the old id");
        assertEq(strategy.layout().pool, address(pool), "same venue throughout");
        assertApproxEqRel(strategy.nav(), navBefore, 0.0001e18, "round trip is value-neutral (lossless fixture)");
    }

    // ==================== post-settle gating (mutation survivors) ====================

    /// @dev ERC-7201 base slot, byte-identical to the three `STORAGE_SLOT` copies in `src`.
    bytes32 internal constant LAYOUT_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /// @dev Poke `Layout.tokenId` directly. Needed because the flat-book gate is a conjunction whose
    ///      clauses cannot all be driven through the public surface — a real book with a live `tokenId`
    ///      also carries debt, so the leg-debt clause would mask this one (exactly what let the mutant
    ///      survive). The read-back assert doubles as a check that the slot offset is still correct.
    function _writeTokenId(uint256 id) internal {
        vm.store(address(strategy), bytes32(uint256(LAYOUT_SLOT) + 18), bytes32(id));
        assertEq(strategy.layout().tokenId, id, "tokenId slot offset drifted");
    }

    /// @dev Same, for the packed `hedgedDebtA | hedgedDebtB` slot.
    function _writeHedgedDebt(uint128 a, uint128 b) internal {
        vm.store(address(strategy), bytes32(uint256(LAYOUT_SLOT) + 27), bytes32((uint256(b) << 128) | uint256(a)));
        (uint128 ra, uint128 rb) = strategy.hedgedDebt();
        assertEq(ra, a, "hedgedDebtA slot offset drifted");
        assertEq(rb, b, "hedgedDebtB slot offset drifted");
    }

    /// @dev All three new entry points gate on `Executed`. Nothing covered them post-`settle`, where
    ///      `redeploy` in particular would re-open a levered position on a wound-down fund whose assets
    ///      have already been pushed to the vault.
    function testMigrationEntryPointsAreRejectedAfterSettle() public {
        _execute(SEED);
        vm.prank(address(vault));
        strategy.settle();

        LeveragedAeroVenue.VenueParams memory v = _venueBParams();

        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        vm.prank(proposer);
        strategy.flatten(1, 0);

        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        vm.prank(proposer);
        strategy.migrateVenue(v);

        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        vm.prank(proposer);
        strategy.redeploy(0);
    }

    /// @dev The flat-book gate is a CONJUNCTION, and the mutation sweep found the first two clauses
    ///      masked by the leg-debt clause firing with the same selector. Drive each in isolation.
    function testMigrateFlatBookGateIsCheckedClauseByClause() public {
        _execute(SEED);
        _flatten();
        _stage(_venueBParams());
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();

        // (1) tokenId alone: no debt, no hedged basis, but a live position id.
        _writeTokenId(1234);
        vm.expectRevert(LeveragedAeroVenue.BookNotFlat.selector);
        vm.prank(proposer);
        strategy.migrateVenue(v);
        _writeTokenId(0);

        // (2) hedged basis A alone.
        _writeHedgedDebt(1, 0);
        vm.expectRevert(LeveragedAeroVenue.BookNotFlat.selector);
        vm.prank(proposer);
        strategy.migrateVenue(v);

        // (3) hedged basis B alone.
        _writeHedgedDebt(0, 1);
        vm.expectRevert(LeveragedAeroVenue.BookNotFlat.selector);
        vm.prank(proposer);
        strategy.migrateVenue(v);
        _writeHedgedDebt(0, 0);

        // (4) leg-B debt alone (the leg-A case is `testMigrateRevertsWhileLegDebtRemains`).
        vm.prank(address(strategy));
        mLegB.borrow(1e8);
        vm.expectRevert(LeveragedAeroVenue.BookNotFlat.selector);
        vm.prank(proposer);
        strategy.migrateVenue(v);
    }

    // ==================== continuity across the full sequence ====================

    function testPendingRedeemRequestSurvivesTheFullMigration() public {
        _execute(SEED);
        usdc.mint(lp, 100_000e6);
        vm.startPrank(lp);
        usdc.approve(address(strategy), 100_000e6);
        uint256 shares = strategy.deposit(100_000e6, 0);
        vault.approve(address(strategy), shares);
        uint256 id = strategy.requestRedeem(shares, 0);
        vm.stopPrank();

        _flatten();
        _stage(_venueBParams());
        _migrate(_venueBParams());
        npm.setPool(poolB);
        vm.prank(proposer);
        strategy.redeploy(0);

        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.prank(proposer);
        strategy.fulfillRedeem(id);
        assertGt(usdc.balanceOf(lp) - lpUsdcBefore, 0, "request fulfilled post-migration for the same shares");
        assertTrue(strategy.redeemRequest(id).settled, "request settled");
    }

    function testOldLegDustIsRescuableAfterCrossPairMigrationAndNewLegsAreNot() public {
        _execute(SEED);
        _flatten();
        _stage(_venueBParams());
        _migrate(_venueBParams());

        legA.mint(address(strategy), 1e15); // old-leg unwind dust
        uint256 vaultBefore = legA.balanceOf(address(vault));
        vm.prank(owner);
        strategy.rescueToVault(address(legA));
        assertEq(legA.balanceOf(address(vault)) - vaultBefore, 1e15, "old leg swept to the vault");

        vm.expectRevert(LeveragedAerodromeCLStrategy.CannotRescuePositionToken.selector);
        vm.prank(owner);
        strategy.rescueToVault(address(legA2)); // NEW leg is now a position token
    }
}
