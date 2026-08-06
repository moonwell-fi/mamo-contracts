// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAeroVenue} from "@contracts/leveraged-aero/LeveragedAeroVenue.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "@contracts/leveraged-aero/sherwood/BaseStrategy.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {MockCLGauge} from "../mocks/MockCLGauge.sol";
import {MockCLFactory, MockCLPool} from "../mocks/MockCLPool.sol";
import {MockComptroller} from "../mocks/MockMoonwellMarket.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockChainlinkFeed, MockClSwapRouter, MockLendingMarket, MockNpm} from "./LeveragedAeroVenuesHarness.sol";

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
    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint256 internal constant P_USDC = 1e8;
    uint256 internal constant SEED = 1_000_000e6;
    /// @dev Venue B reuses venue A's prices/tick so the redeployed lifecycle runs known-good geometry.
    uint256 internal constant P_LEG_B = 1e13; // $100k @ 8dp (legB AND legB2)
    uint256 internal constant P_LEG_A = 3000e8; // $3k @ 18dp (legA AND legA2)
    int24 internal constant TICK = 311_100;

    /// @dev Split into per-venue frames: one flat setUp of this size overflows the Yul stack
    ///      under via_ir (each helper keeps its locals in its own frame).
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
        clFactory = new MockCLFactory();
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
        pool.setFactory(address(clFactory));
        clFactory.setPool(address(usdc), address(legB), LEG_B_SWAP_SPACING, makeAddr("legBSwapPool"));
        clFactory.setPool(address(usdc), address(legA), LEG_A_SWAP_SPACING, makeAddr("legASwapPool"));
        gauge = new MockCLGauge(address(aero));
        gauge.setPool(address(pool));
        mLegB = new MockLendingMarket(address(legB));
        mLegA = new MockLendingMarket(address(legA));
        legBFeed = new MockChainlinkFeed(int256(P_LEG_B), 8, 1, block.timestamp);
        legAFeed = new MockChainlinkFeed(int256(P_LEG_A), 8, 1, block.timestamp);
        npm = new MockNpm(pool);
    }

    /// @dev Cross-pair destination: same prices/tick as venue A, different spacing.
    function setUpVenueB() external {
        legB2 = new MockToken("Leg B2", "LEGB2", 8);
        legA2 = new MockToken("Leg A2", "LEGA2", 18);
        poolB = new MockCLPool(address(legB2), address(legA2), SPACING_B);
        poolB.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(TICK));
        poolB.setTick(TICK);
        poolB.setFactory(address(clFactory));
        clFactory.setPool(address(usdc), address(legB2), LEG_B2_SWAP_SPACING, makeAddr("legB2SwapPool"));
        clFactory.setPool(address(usdc), address(legA2), LEG_A2_SWAP_SPACING, makeAddr("legA2SwapPool"));
        gaugeB = new MockCLGauge(address(aero));
        gaugeB.setPool(address(poolB));
        mLegB2 = new MockLendingMarket(address(legB2));
        mLegA2 = new MockLendingMarket(address(legA2));
        legB2Feed = new MockChainlinkFeed(int256(P_LEG_B), 8, 1, block.timestamp);
        legA2Feed = new MockChainlinkFeed(int256(P_LEG_A), 8, 1, block.timestamp);
    }

    /// @dev Asset-mode destination {usdc, legA2}: migrate-only, so no price/tick setup needed.
    function setUpVenueC() external {
        poolC = new MockCLPool(address(usdc), address(legA2), SPACING);
        poolC.setFactory(address(clFactory));
        gaugeC = new MockCLGauge(address(aero));
        gaugeC.setPool(address(poolC));
    }

    function fundVenues() external {
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

    function _flatten() internal {
        vm.prank(proposer);
        strategy.flatten();
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
        assertGt(idle, (SEED * 98) / 100, "essentially the whole book realized as idle USDC");
        assertEq(strategy.nav(), idle, "flat NAV == idle USDC (oracle-free)");
        // Still Executed: the proposer-gated venue ops remain reachable (settle would brick them).
        vm.prank(proposer);
        strategy.rerange(WIDTH, 0, 0); // flat-book no-op that requires State.Executed
    }

    function testFlattenRevertsForNonProposer() public {
        _execute(SEED);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        vm.prank(lp);
        strategy.flatten();
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

    function testMigrateRejectsAMissingLegSwapPool() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.cbBTCSwapTickSpacing = 300; // no legB2/USDC pool registered at this spacing
        _expectMigrateRevert(v, LeveragedAeroVenue.VenueMismatch.selector);
    }

    function testMigrateRejectsAnOffGridWidth() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.width = 4100; // off the 200 grid
        _expectMigrateRevert(v, LeveragedAeroVenue.WidthOutOfBounds.selector);
    }

    function testMigrateRejectsTargetLtvAboveMax() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.targetLtvBps = 6100; // > maxLtvBps 6000
        _expectMigrateRevert(v, LeveragedAeroVenue.TargetLtvExceedsMax.selector);
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
        strategy.redeploy();

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
        strategy.redeploy();
    }

    function testRedeployRevertsForNonProposer() public {
        _execute(SEED);
        _flatten();
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        vm.prank(lp);
        strategy.redeploy();
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
        strategy.redeploy();

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
