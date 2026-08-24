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

import {Test, Vm} from "@forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title Owner-staged venue migration — flatten / stage / migrate / redeploy
 * @notice End-to-end coverage of the in-place pool/pair migration, plus the continuity invariants
 *         (NAV, share balances, pending redeem requests, old-leg rescue) across the whole sequence.
 * @dev Venue A is the TwoLegLifecycle fixture (legB 8dp / legA 18dp, both borrowed). Venue B is a
 *      distinct cross-pair venue reusing A's prices and tick; venue C is asset-mode (`cbBTC` slot ==
 *      usdc), migrate-only. Fees off.
 */
/// @dev Minimal ProtocolConfig. The protocol slice is the only fee leg that moves `navNet` off `nav()`.
contract MockProtocolConfig {
    uint256 public protocolFeeBps;
    address public protocolFeeRecipient;

    constructor(uint256 bps, address recipient) {
        protocolFeeBps = bps;
        protocolFeeRecipient = recipient;
    }
}

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
    /// @dev Centred skew. Not in `VenueParams`, but `applyVenue` re-validates it against the destination.
    uint16 internal constant SKEW_CENTERED = 5000;
    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint256 internal constant P_USDC = 1e8;
    uint256 internal constant SEED = 1_000_000e6;
    /// @dev Venue B reuses venue A's prices/tick so the redeployed lifecycle runs known-good geometry.
    uint256 internal constant P_LEG_B = 1e13; // $100k @ 8dp (legB AND legB2)
    uint256 internal constant P_LEG_A = 3000e8; // $3k @ 18dp (legA AND legA2)
    int24 internal constant TICK = 311_100;

    /// @dev The v2 router `swapAeroToUsdc` hardcodes; a mock is etched there so the reward leg runs for real.
    address internal constant AERO_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    /// @dev Aerodrome v2 PoolFactory, hardcoded in `LeveragedAeroValuation` and probed for a USDC route.
    address internal constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @dev `applyVenue` pins the canonical CLFactory, so every destination pool must be REGISTERED here.
    address internal constant AERODROME_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    function setUp() public {
        vm.warp(1_800_000_000);
        // EXTERNAL self-calls: one flat setUp overflows the Yul stack under via_ir; `this.` forces a frame.
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
        // The reward-route probe reads a HARDCODED v2 factory address; etch code so the route resolves.
        vm.etch(AERO_V2_FACTORY, address(new MockAeroV2Factory(address(aero), address(usdc), address(0xA2F))).code);
        mLegB = new MockLendingMarket(address(legB));
        mLegA = new MockLendingMarket(address(legA));
        legBFeed = new MockChainlinkFeed(int256(P_LEG_B), 8, 1, block.timestamp);
        legAFeed = new MockChainlinkFeed(int256(P_LEG_A), 8, 1, block.timestamp);
        npm = new MockNpm(pool);
        // Real ERC-721 custody: a staked position is owned by the gauge, so a missing unstake reverts.
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
        // `cloneAndBind` is the only init path: `BaseStrategy.initialize` requires `msg.sender == vault_`.
        vm.startPrank(owner);
        strategy = LeveragedAerodromeCLStrategy(
            payable(vault.cloneAndBind(address(new LeveragedAerodromeCLStrategy()), proposer, abi.encode(_paramsA())))
        );
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

    /// @dev Venue A as `VenueParams` so a test can migrate BACK to it; must match `_paramsA()`'s subset.
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

    /// @dev Venue C (asset-mode flip): leg-B slot IS usdc, swap spacing 0, pool {usdc, legA2}.
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

    /// @dev Nonzero `minRewardUsdcOut` because tests arm reward tranches; `minIdleUsdcOut` 0 suits a flat book.
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
        // TIGHT on purpose: the swap mocks fill at exact oracle parity, so only rounding may differ.
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

    // ==================== FUND CAPACITY CAP (real vault + real strategy) ====================

    /// @dev The capacity ceiling is fund-global, not a per-account allocation, and `0` means unlimited.
    function testDepositIsRefusedOnceTheFundReachesCapacity() public {
        _execute(SEED);
        assertEq(vault.maxTotalAssets(), 0, "unlimited by default");

        uint256 navNow = strategy.nav();
        vm.prank(owner);
        vault.setMaxTotalAssets(navNow + 100_000e6);
        assertEq(vault.remainingCapacity(), 100_000e6, "room == cap - nav");

        // A deposit that CROSSES the ceiling is rejected outright, not trimmed.
        usdc.mint(lp, 300_000e6);
        vm.startPrank(lp);
        usdc.approve(address(strategy), 300_000e6);
        vm.expectPartialRevert(LeveragedAerodromeCLStrategy.FundAtCapacity.selector);
        strategy.deposit(150_000e6, 0);

        uint256 shares = strategy.deposit(100_000e6, 0);
        vm.stopPrank();
        assertGt(shares, 0, "the fitting deposit minted");
        assertEq(vault.remainingCapacity(), 0, "fund is now exactly full");

        // Full means full — even a dust deposit, from a different address, is refused.
        usdc.mint(owner, 1e6);
        vm.startPrank(owner);
        usdc.approve(address(strategy), 1e6);
        vm.expectPartialRevert(LeveragedAerodromeCLStrategy.FundAtCapacity.selector);
        strategy.deposit(1e6, 0);
        vm.stopPrank();
    }

    /// @dev `navNet + assets > cap` is strict, so exactly on the ceiling passes. MUTATION: `>=` fails that.
    function testCapacityBoundaryIsStrictlyGreaterThan() public {
        _execute(SEED);

        uint256 navNow = strategy.nav();
        vm.prank(owner);
        vault.setMaxTotalAssets(navNow + 50_000e6);
        assertEq(vault.remainingCapacity(), 50_000e6, "room == cap - nav");

        // One atomic unit (1e-6 USDC) OVER the ceiling: refused.
        usdc.mint(lp, 50_000e6 + 1);
        vm.startPrank(lp);
        usdc.approve(address(strategy), 50_000e6 + 1);
        vm.expectPartialRevert(LeveragedAerodromeCLStrategy.FundAtCapacity.selector);
        strategy.deposit(50_000e6 + 1, 0);

        // Exactly ON the ceiling: allowed. `>` not `>=`.
        uint256 shares = strategy.deposit(50_000e6, 0);
        vm.stopPrank();
        assertGt(shares, 0, "landing exactly on the ceiling is allowed");
        assertEq(vault.remainingCapacity(), 0, "and it consumed the room exactly");
    }

    /// @dev Capacity gates DEPOSITS only, and prices on live NAV rather than a high-water mark.
    function testCapacityGatesDepositsOnlyAndRedeemingFreesRoom() public {
        _execute(SEED);
        usdc.mint(lp, 100_000e6);
        vm.startPrank(lp);
        usdc.approve(address(strategy), 100_000e6);
        uint256 shares = strategy.deposit(100_000e6, 0);
        vm.stopPrank();

        // Lower the ceiling far BELOW the live book: deposits shut, exits unaffected.
        vm.prank(owner);
        vault.setMaxTotalAssets(1e6);
        assertEq(vault.remainingCapacity(), 0, "fund is over its ceiling");

        // A modest slice, so the fast path's own LTV gate stays clear: the ceiling never participates.
        uint256 slice = shares / 50;
        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.startPrank(lp);
        vault.approve(address(strategy), slice);
        strategy.redeem(slice, 0);
        vm.stopPrank();
        assertGt(usdc.balanceOf(lp), lpUsdcBefore, "exit unaffected by the ceiling");
    }

    /// @dev The recipe "deposit exactly `remainingCapacity()`" must hold WITH A FEE PENDING: room is
    ///      priced on raw `nav()` while the guard enforces on `navNet`, which is only ever <= it.
    function testDepositingExactlyRemainingCapacitySucceedsWithAFeePending() public {
        _execute(SEED);

        // A live protocol fee, taken off the GAIN ABOVE THE HWM rather than elapsed time.
        MockProtocolConfig cfg = new MockProtocolConfig(1000, makeAddr("protocolFeeRecipient"));
        vm.prank(owner);
        vault.setFeeConfig(address(cfg));

        // Flatten so NAV is the idle USDC balance — face value, oracle-free and directly controllable.
        _flatten();

        // TWO warm-up deposits: the crystallise runs pre-deposit, so only the second one seeds the HWM.
        usdc.mint(lp, 20_000e6);
        vm.startPrank(lp);
        usdc.approve(address(strategy), 20_000e6);
        strategy.deposit(10_000e6, 0); // supply 0 -> crystallise bails, shares minted
        strategy.deposit(10_000e6, 0); // supply > 0, hwm unset -> HWM seeded here
        vm.stopPrank();

        // Appreciate above the HWM. `_execute` seeds USDC with no genesis shares, so this must be seed-sized.
        usdc.mint(address(strategy), SEED * 2);

        uint256 navNow = strategy.nav();
        vm.prank(owner);
        vault.setMaxTotalAssets(navNow + 250_000e6);

        uint256 room = vault.remainingCapacity();
        assertEq(room, 250_000e6, "room == cap - nav");

        // PASS 1 — the documented recipe: deposit exactly the reported room. This must always work.
        uint256 snap = vm.snapshotState();
        usdc.mint(lp, room);
        vm.startPrank(lp);
        usdc.approve(address(strategy), room);
        uint256 shares = strategy.deposit(room, 0);
        vm.stopPrank();
        assertGt(shares, 0, "the exact-room deposit minted");
        assertLe(strategy.nav(), vault.maxTotalAssets(), "book never crossed the ceiling");

        // ANTI-VACUITY: `nav()` is net of `protocolFeeOwed`, so sub-deposit growth proves the slice was taken.
        uint256 slice = (navNow + room) - strategy.nav();
        assertGt(slice, 0, "protocol fee actually accrued (test is not vacuous)");

        // PASS 2 pins the DIRECTION: an exact-room deposit passes under either basis, so only the window
        // `(room, room + slice]` separates them. MUTATION: the `navPre` mutant survives pass 1, fails here.
        vm.revertToState(snap);
        uint256 overRoom = room + slice;
        usdc.mint(lp, overRoom);
        vm.startPrank(lp);
        usdc.approve(address(strategy), overRoom);
        uint256 shares2 = strategy.deposit(overRoom, 0);
        vm.stopPrank();
        assertGt(shares2, 0, "room is under-reported by exactly the protocol slice, and that slack is real");
        assertLe(strategy.nav(), vault.maxTotalAssets(), "even the slack deposit stays within the ceiling");
    }

    /// @dev The guard approached from ABOVE: a ceiling lowered under a live book must still refuse deposits.
    function testDepositIsRefusedWhenTheCeilingIsLoweredBelowTheLiveBook() public {
        _execute(SEED);

        uint256 navNow = strategy.nav();
        vm.prank(owner);
        vault.setMaxTotalAssets(navNow / 2);
        assertEq(vault.remainingCapacity(), 0, "over the ceiling reports no room");

        usdc.mint(lp, 1_000e6);
        vm.startPrank(lp);
        usdc.approve(address(strategy), 1_000e6);
        vm.expectPartialRevert(LeveragedAerodromeCLStrategy.FundAtCapacity.selector);
        strategy.deposit(1_000e6, 0);
        vm.stopPrank();

        // Nothing moved: the guard runs before the transfer.
        assertEq(usdc.balanceOf(lp), 1_000e6, "rejected deposit moved no USDC");
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

    /// @dev REGRESSION (finding 4) — an unsold auto-claimed reward tranche is invisible to `nav()`.
    function testFlattenSellsTheAutoClaimedRewardTranche() public {
        _execute(SEED);
        uint256 tranche = 1000e18;
        aero.mint(address(gauge), tranche);
        gauge.setAeroToPayOnWithdraw(tranche);

        _flatten();

        assertEq(aero.balanceOf(address(strategy)), 0, "reward tranche sold, not stranded");
        assertEq(strategy.nav(), usdc.balanceOf(address(strategy)), "flat NAV == idle USDC");
        assertGt(strategy.nav(), (SEED * 98) / 100 + 900e6, "reward proceeds landed in NAV");
    }

    /// @dev The reward sale is floored by the L9 oracle read on top of the caller's own bound.
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

    /// @dev F21, the lax direction: the floor divides by the USDC/USD price. MUTATION: `/1e20` clears it.
    function testFlattenRewardFloorPricesThroughTheUsdcPeg() public {
        _execute(SEED);
        aero.mint(address(gauge), 1000e18);
        gauge.setAeroToPayOnWithdraw(1000e18);
        usdcFeed.setAnswer(0.9e8);

        vm.expectRevert(LeveragedAeroVenue.BelowOracleFloor.selector);
        vm.prank(proposer);
        strategy.flatten(1, 0);
    }

    /// @dev F21, the bricking direction: above peg an honest fill pays fewer USDC. MUTATION: `/1e20` reverts.
    function testFlattenIsNotBrickedByAnHonestFillWhenUsdcIsAbovePeg() public {
        _execute(SEED);
        aero.mint(address(gauge), 1000e18);
        gauge.setAeroToPayOnWithdraw(1000e18);
        usdcFeed.setAnswer(1.02e8);
        MockAeroV2Router(AERO_V2_ROUTER).setRateOverrideE18((1e6 * 1e8) / uint256(1.02e8));

        _flatten();

        assertEq(aero.balanceOf(address(strategy)), 0, "the honest fill was accepted, not floored out");
        assertEq(strategy.layout().tokenId, 0, "...and the flatten completed");
    }

    /// @dev A reward balance with no caller floor is rejected; with no reward the call is a clean no-op.
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

    /// @dev REGRESSION (dust-donation deadlock) — a sub-micro-USD reward balance prices to a ZERO floor,
    ///      which made both `0` and any nonzero `minRewardUsdcOut` unsatisfiable and blocked `flatten`.
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

    /// @dev The dust skip must short-circuit BEFORE `readUsd8`, or dust plus a feed outage stalls `flatten`.
    function testFlattenIgnoresDustWithoutConsultingAStaleRewardFeed() public {
        _execute(SEED);
        aero.mint(address(strategy), 1e6);
        aeroFeed.setUpdatedAt(block.timestamp - 2 hours); // past the 1 hour maxDelay

        vm.prank(proposer);
        strategy.flatten(1, 0);

        _assertFlat();
        assertEq(aero.balanceOf(address(strategy)), 1e6, "dust left in place");
        _stage(_venueBParams());
        _migrate(_venueBParams());
        assertEq(strategy.layout().pool, address(poolB), "migration not stalled by a stale feed");
    }

    /// @dev The narrow half: the band comes off a price CEILING, so above it a stale feed still fails closed.
    function testFlattenStillFailsClosedOnAStaleFeedAboveTheOracleFreeBand() public {
        _execute(SEED);
        aero.mint(address(strategy), 1e9); // > 1e20 / REWARD_PRICE_CEILING_USD8 (== 1e8)
        aeroFeed.setUpdatedAt(block.timestamp - 2 hours);

        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        vm.prank(proposer);
        strategy.flatten(1, 0);
    }

    /// @dev The dust skip must NOT widen the guard: a balance with a nonzero oracle floor is still sold.
    function testFlattenStillSellsABalanceJustAboveTheDustThreshold() public {
        _execute(SEED);
        // 1e15 wei AERO leaves a floor that SURVIVES the `maxSlippageBps` haircut — small, not dust.
        aero.mint(address(gauge), 1e15);
        gauge.setAeroToPayOnWithdraw(1e15);

        vm.expectRevert(LeveragedAeroVenue.ZeroMinOut.selector);
        vm.prank(proposer);
        strategy.flatten(0, 0);

        vm.prank(proposer);
        strategy.flatten(1, 0);
        assertEq(aero.balanceOf(address(strategy)), 0, "above-dust balance is still sold");
    }

    /// @dev REGRESSION (finding 7) — the unwind's mins come off the `slot0()` it burns at, so `flatten` gates.
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

    /// @dev REGRESSION (finding 7) — the caller's aggregate floor; per-swap floors bound each leg only.
    function testFlattenHonoursTheCallerIdleFloor() public {
        _execute(SEED);
        uint256 unreachable = SEED * 2;

        // Selector-only: the realised idle depends on the unwind's slippage, not on the guard.
        vm.expectPartialRevert(LeveragedAeroVenue.InsufficientIdleAfterFlatten.selector);
        vm.prank(proposer);
        strategy.flatten(1, unreachable);
    }

    /// @dev REGRESSION for the `_settleRepayDebts` stale-index bug: full-repay vs partial is decided off
    ///      the ACCRUED debt, not the stale `borrowBalanceStored`. The construction below puts each leg's
    ///      held balance in `[stored, accrued)` — the window where the stored read over-pulls and reverts.
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

        // Cushion each leg so the held balance clears STORED but stays under ACCRUED — the bug window.
        legA.mint(address(strategy), storedA * 3 / 100);
        legB.mint(address(strategy), storedB * 3 / 100);

        vm.prank(proposer);
        strategy.flatten(1, 0);

        _assertFlat();
        assertEq(mLegA.borrowBalance(address(strategy)), 0, "leg A debt fully cleared");
        assertEq(mLegB.borrowBalance(address(strategy)), 0, "leg B debt fully cleared");
    }

    // ============ settle: the final reward tranche (finding 9) ============

    /// @dev REGRESSION (finding 9) — an unsold final tranche never joins the pot `redeemSettled` pays from.
    function testSettleSellsTheAutoClaimedRewardTranche() public {
        _execute(SEED);
        uint256 tranche = 1000e18; // 1 AERO == 1 USDC at this fixture's router rate and feed mark
        aero.mint(address(gauge), tranche);
        gauge.setAeroToPayOnWithdraw(tranche);

        vm.prank(address(vault));
        strategy.settle();

        assertEq(aero.balanceOf(address(strategy)), 0, "reward tranche sold, not stranded");
        assertEq(usdc.balanceOf(address(strategy)), 0, "the whole realized balance was pushed to the vault");
        // TIGHT on purpose: the mocks fill at oracle parity, so the pot is the book plus 1000 USDC.
        assertApproxEqRel(
            usdc.balanceOf(address(vault)), SEED + 1000e6, 0.0001e18, "reward proceeds reached the settled pot"
        );
    }

    /// @dev THE DEADMAN PROPERTY: the reward sale must never block terminal `settle()`; the catch swallows it.
    function testSettleSurvivesAStaleRewardFeedAndLeavesTheTrancheRescuable() public {
        _execute(SEED);
        uint256 tranche = 1000e18;
        aero.mint(address(gauge), tranche);
        gauge.setAeroToPayOnWithdraw(tranche);
        aeroFeed.setUpdatedAt(block.timestamp - 2 hours); // past the 1 hour maxDelay

        vm.expectEmit(false, false, false, false, address(strategy));
        emit LeveragedAerodromeCLStrategy.SettleRewardSaleDeferred();
        vm.prank(address(vault));
        strategy.settle();

        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Settled), "settle completed");
        assertEq(aero.balanceOf(address(strategy)), tranche, "tranche untouched, never sold blind");
        assertApproxEqRel(usdc.balanceOf(address(vault)), SEED, 0.0001e18, "the book itself still settled");
        // The residue is still rescuable: the reward-token block is `Executed`-scoped. Caller is the ADMIN.
        vm.prank(owner);
        strategy.rescueToVault(address(aero));
        assertEq(aero.balanceOf(address(vault)), tranche, "residual tranche recovered post-settle");
    }

    /// @dev Same deadman property against a REVERTING reward route rather than a stale feed.
    function testSettleSurvivesARevertingRewardRoute() public {
        _execute(SEED);
        uint256 tranche = 1000e18;
        aero.mint(address(gauge), tranche);
        gauge.setAeroToPayOnWithdraw(tranche);
        // PUSH1 0 PUSH1 0 REVERT — every call into the reward route reverts cleanly.
        vm.etch(AERO_V2_ROUTER, hex"60006000fd");

        vm.expectEmit(false, false, false, false, address(strategy));
        emit LeveragedAerodromeCLStrategy.SettleRewardSaleDeferred();
        vm.prank(address(vault));
        strategy.settle();

        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Settled), "settle completed");
        assertEq(aero.balanceOf(address(strategy)), tranche, "tranche untouched");
    }

    /// @dev Best-effort is NOT "sell at any price": the L9 post-check reverts the sale frame whole.
    function testSettleDoesNotAcceptARewardFillBelowTheOracleFloor() public {
        _execute(SEED);
        uint256 tranche = 1000e18;
        aero.mint(address(gauge), tranche);
        gauge.setAeroToPayOnWithdraw(tranche);
        // Re-etch a router paying 50% under the 1e8 feed mark (immutables => new instance + etch).
        MockAeroV2Router cheap = new MockAeroV2Router(address(aero), address(usdc), 5e5);
        vm.etch(AERO_V2_ROUTER, address(cheap).code);

        vm.prank(address(vault));
        strategy.settle();

        assertEq(aero.balanceOf(address(strategy)), tranche, "under-priced fill rolled back, tranche intact");
        assertApproxEqRel(usdc.balanceOf(address(vault)), SEED, 0.0001e18, "no under-priced proceeds booked");
    }

    /// @dev A zero reward balance skips the sale before the oracle read AND the route — both fatal here.
    function testSettleWithNoRewardBalanceMakesNoRewardSaleCall() public {
        _execute(SEED);
        gauge.setAeroToPayOnWithdraw(0);
        aeroFeed.setUpdatedAt(block.timestamp - 2 hours);
        vm.etch(AERO_V2_ROUTER, hex"60006000fd");

        vm.recordLogs();
        vm.prank(address(vault));
        strategy.settle();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.SettleRewardSaleDeferred.selector,
                "a zero reward balance still reached the oracle or the router"
            );
        }
        assertEq(aero.balanceOf(address(strategy)), 0, "no reward balance to begin with");
        assertApproxEqRel(usdc.balanceOf(address(vault)), SEED, 0.0001e18, "settle unaffected");
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

    /// @dev Both directions are checked: only the pool's own Voter-written `gauge()` is non-forgeable.
    function testMigrateRejectsAGaugeThePoolDoesNotClaim() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        MockCLGauge impostor = new MockCLGauge(address(aero));
        impostor.setPool(address(poolB)); // passes the self-attested direction; poolB.gauge() does not
        v.gauge = address(impostor);
        _expectMigrateRevert(v, LeveragedAeroVenue.VenueMismatch.selector);
    }

    // ==================== CANONICAL FACTORY BINDING (migrate side) ====================

    /// @dev Migrate-side canonical-factory binding: a pool nominating its own registry is rejected.
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

    /// @dev A→B→A. Nothing else migrated OUT of a venue, which is why DERIVED-field staleness mutants lived.
    function testMigrateRoundTripRestoresEveryDerivedField() public {
        _execute(SEED);
        _flatten();

        LeveragedAerodromeCLStrategy.LayoutView memory before = strategy.layout();
        assertFalse(before.wethIsToken0, "venue A sorts leg B first");

        // FLIP THE ORDERING: without it a DELETED `$.wethIsToken0` write looks correct. MUTATION-verified.
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

    /// @dev The shape half: only a migration OUT of asset mode catches a stale `legBIsAsset` write.
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

    /// @dev The decimals half: A/B/C are all 18dp leg A, so venue D's 8dp leg forces 18→8 and back.
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

    /// @dev The reward leg is a THIRD venue: a reward token with no v2/USDC pool bricks compound+flatten.
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

    /// @dev Leg feeds are validated at STAGE time; `readUsd8` fails closed only once the venue is adopted.
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

    /// @dev REGRESSION (finding 8) — the gauge is migratable, so a feed pinned at init prices the wrong token.
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

    /// @dev The L9 scaling assumption (`mulDiv(bal, price8, 1e20)`) is asserted on the staged feed too.
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

    /// @dev `checkRange`'s one-spacing-per-side floor couples the live skew to `(width, tickSpacing)`, which
    ///      a migration rewrites: the SAME destination passes centred below and is rejected at a skew of 1000.
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
        // Move the LIVE skew to the bottom of the band; still valid on venue A, so the rerange sticks.
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

    /// @dev The LOWER twin: `migrateVenue` is the one `targetLtvBps` write path no human types at call time.
    function testMigrateRejectsZeroTargetLtv() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.targetLtvBps = 0;
        _expectMigrateRevert(v, LeveragedAeroVenue.TargetLtvZero.selector);
    }

    /// @dev Only this path can produce it: `applyVenue` re-reads the LIVE CF, so a CF Moonwell has since
    ///      LOWERED lifts the trigger past the liquidation line post-init.
    function testMigrateRejectsADestinationWhoseCollateralFactorSitsUnderTheDeleverageTrigger() public {
        _execute(SEED);
        _flatten();
        comptroller.setCollateralFactorMantissa(0.83e18); // cf 8300; 12000 * 8300 = 9.96e7 <= 1e8
        LeveragedAeroVenue.VenueParams memory v = _venueBParams(); // maxLtv 6000 < 8300: earlier rungs clear
        _expectMigrateRevert(v, LeveragedAeroValuation.DeleverageTriggerAboveCF.selector);
    }

    /// @dev The other knob: a migration may lower minHealth, which RAISES the trigger (11000 -> 9090 > 8800).
    function testMigrateRejectsAMinHealthThatLiftsTheDeleverageTriggerToTheCollateralFactor() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        v.minHealthBps = 11_000; // 11000 * 8800 = 9.68e7 <= 1e8
        _expectMigrateRevert(v, LeveragedAeroValuation.DeleverageTriggerAboveCF.selector);
    }

    /// @dev The positive twin, one bps of CF above the bound: the migration lands. A boundary, not a ban.
    function testMigrateAcceptsACollateralFactorOneBpsAboveTheDeleverageTrigger() public {
        _execute(SEED);
        _flatten();
        comptroller.setCollateralFactorMantissa(0.8334e18); // cf 8334
        LeveragedAeroVenue.VenueParams memory v = _venueBParams();
        _stage(v);
        _migrate(v);
        assertEq(strategy.layout().pool, address(poolB), "venue migrated at the boundary");
        assertEq(strategy.layout().usdcCollateralFactorBps, 8334, "the live CF was re-read and stored");
    }

    // ==================== migrate: the target-LTV write is LOUD ====================

    /// @dev `applyVenue` persists `p.targetLtvBps`, so a migration MOVES THE FUND'S LEVERAGE POLICY.
    function testMigrateEmitsTargetLtvUpdatedWhenTheStagedTargetDiffers() public {
        _execute(SEED);
        _flatten();
        assertEq(strategy.layout().targetLtvBps, TARGET_LTV_BPS, "live target before the migration");

        LeveragedAeroVenue.VenueParams memory v = _venueBParams(); // targetLtvBps 4000 != 5000
        _stage(v);
        vm.expectEmit(false, false, false, true, address(strategy));
        emit LeveragedAerodromeCLStrategy.TargetLtvUpdated(TARGET_LTV_BPS, 4000);
        vm.prank(proposer);
        strategy.migrateVenue(v);

        assertEq(strategy.layout().targetLtvBps, 4000, "the staged target is what got stored");
    }

    /// @dev The other half of the inequality guard: an unchanged target is quiet — the event means "moved".
    function testMigrateDoesNotEmitTargetLtvUpdatedWhenTheStagedTargetIsUnchanged() public {
        _execute(SEED);
        _flatten();

        LeveragedAeroVenue.VenueParams memory v = _venueAParams(); // targetLtvBps == the live one
        _stage(v);
        vm.recordLogs();
        vm.prank(proposer);
        strategy.migrateVenue(v);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawMigrated;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(strategy)) continue;
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.TargetLtvUpdated.selector,
                "an unchanged target must not announce a policy change"
            );
            if (logs[i].topics[0] == LeveragedAeroVenue.VenueMigrated.selector) sawMigrated = true;
        }
        assertTrue(sawMigrated, "the migration itself did run -- the assertion above is not vacuous");
        assertEq(strategy.layout().targetLtvBps, TARGET_LTV_BPS, "target unchanged");
    }

    /// @dev THE SCENARIO THE EVENT EXISTS FOR: a migration RESTORING a target the admin lowered.
    function testMigrateAnnouncesRestoringALoweredTarget() public {
        _execute(SEED);
        vm.prank(owner);
        strategy.setTargetLtv(3000);
        assertEq(strategy.layout().targetLtvBps, 3000, "admin de-risked");

        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueAParams(); // same venue, target back to 5000
        _stage(v);
        vm.expectEmit(false, false, false, true, address(strategy));
        emit LeveragedAerodromeCLStrategy.TargetLtvUpdated(3000, TARGET_LTV_BPS);
        vm.prank(proposer);
        strategy.migrateVenue(v);

        assertEq(strategy.layout().targetLtvBps, TARGET_LTV_BPS, "the staged target won, loudly");
    }

    /// @dev The ceiling and the width band get the SAME inequality-guarded announcement as the target —
    ///      `VenueMigrated` carries only the two pools, so without these a migration moves them in silence.
    function testMigrateAnnouncesTheCeilingAndTheWidthBandItRestores() public {
        _execute(SEED);
        vm.startPrank(owner);
        strategy.setTargetLtv(3000);
        strategy.setMaxLtv(3500);
        strategy.setWidthBounds(400, 8000);
        vm.stopPrank();

        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueAParams(); // restores 6500 and [200, 20000]
        _stage(v);
        vm.expectEmit(false, false, false, true, address(strategy));
        emit LeveragedAerodromeCLStrategy.WidthBoundsUpdated(400, 8000, 200, 20_000);
        vm.expectEmit(false, false, false, true, address(strategy));
        emit LeveragedAerodromeCLStrategy.MaxLtvUpdated(3500, 6500);
        vm.prank(proposer);
        strategy.migrateVenue(v);

        assertEq(strategy.layout().maxLtvBps, 6500, "the staged ceiling won, loudly");
        assertEq(strategy.layout().minWidth, 200, "...and the staged band");
    }

    /// @dev An UNCHANGED ceiling / band stays quiet, so the events mean "it moved", not "a migration ran".
    function testMigrateStaysQuietWhenTheCeilingAndBandAreUnchanged() public {
        _execute(SEED);
        _flatten();
        LeveragedAeroVenue.VenueParams memory v = _venueAParams(); // byte-identical to what is stored
        _stage(v);

        vm.recordLogs();
        vm.prank(proposer);
        strategy.migrateVenue(v);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawMigrated;
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.MaxLtvUpdated.selector,
                "an unchanged ceiling must not announce a change"
            );
            assertTrue(
                logs[i].topics[0] != LeveragedAerodromeCLStrategy.WidthBoundsUpdated.selector,
                "...nor an unchanged band"
            );
            if (logs[i].topics[0] == LeveragedAeroVenue.VenueMigrated.selector) sawMigrated = true;
        }
        assertTrue(sawMigrated, "the migration itself did run -- the assertions above are not vacuous");
    }

    /// @dev THE STALE-AUTHORIZATION CLOSE. An owner stage carries a ceiling picked under the policy standing
    ///      at stage time; an admin ratchet-down moves that policy, so the setter consumes the stage exactly
    ///      as `redeploy` does. Without it the proposer alone could restore the pre-ratchet ceiling.
    function testSetMaxLtvConsumesAStaleVenueStageSoAMigrationCannotUndoTheRatchet() public {
        _execute(SEED);
        LeveragedAeroVenue.VenueParams memory v = _venueAParams(); // carries the init 6500 ceiling
        _stage(v);
        assertEq(strategy.layout().stagedVenueHash, keccak256(abi.encode(v)), "owner authorization armed");

        // Markets turn: the admin ratchets policy and the ceiling down.
        vm.startPrank(owner);
        strategy.setTargetLtv(3000);
        strategy.setMaxLtv(3500);
        vm.stopPrank();
        assertEq(strategy.layout().stagedVenueHash, bytes32(0), "the ratchet consumed the stale authorization");

        // The proposer's migration now has nothing to fire.
        _flatten();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.VenueNotStaged.selector);
        strategy.migrateVenue(v);
        assertEq(strategy.layout().maxLtvBps, 3500, "the ceiling the admin set still stands");

        // The owner can still re-authorize deliberately, under the policy now standing.
        _stage(v);
        _migrate(v);
        assertEq(strategy.layout().maxLtvBps, 6500, "a FRESH owner stage migrates as before");
    }

    /// @dev Same close on the band setter.
    function testSetWidthBoundsConsumesAStaleVenueStage() public {
        _execute(SEED);
        LeveragedAeroVenue.VenueParams memory v = _venueAParams();
        _stage(v);

        vm.prank(owner);
        strategy.setWidthBounds(400, 8000);
        assertEq(strategy.layout().stagedVenueHash, bytes32(0), "the band write consumed the stage");

        _flatten();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.VenueNotStaged.selector);
        strategy.migrateVenue(v);
        assertEq(strategy.layout().minWidth, 400, "the admin's band still stands");
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

    /// @dev Own frame so the assert cascade's locals never share a stack with the driving frame (via_ir).
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
        // CROSS-DECIMAL: 8dp leg B becomes 6dp USDC — a missed rewrite mis-scales the whole book by 100x.
        assertEq(l.cbBTCDecimals, 6, "leg B decimals re-read at migrate (8dp -> 6dp)");
        assertEq(l.wethDecimals, 18, "leg A decimals re-read at migrate");
    }

    /// @dev The scenario the reward feed lives in `VenueParams` FOR: a gauge rewarding a DIFFERENT token.
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

    /// @dev The mint's own mins come off the `slot0()` it executes at; the caller's floor is independent.
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

    /// @dev ROLLBACK (B → A): the staged hash must NOT survive it, or it is a replayable authorization.
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

    /// @dev Plain "unwind, wait, re-enter" — distinct from the rollback above in that nothing was staged.
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

    /// @dev Poke `Layout.tokenId` directly: through the public surface the leg-debt clause masks this one.
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

    /// @dev All three entry points gate on `Executed`; post-`settle` `redeploy` would re-lever a dead fund.
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

    /// @dev The flat-book gate is a CONJUNCTION whose first clauses were masked by the leg-debt clause.
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
        uint256 id = strategy.requestRedeem(shares, 0, address(0));
        vm.stopPrank();

        _flatten();
        _stage(_venueBParams());
        _migrate(_venueBParams());
        npm.setPool(poolB);
        vm.prank(proposer);
        strategy.redeploy(0);

        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.prank(proposer);
        strategy.fulfillRedeem(id, 0);
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
