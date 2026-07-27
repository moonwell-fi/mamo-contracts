// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "@contracts/leveraged-aero/sherwood/BaseStrategy.sol";

import {MockCLGauge} from "../mocks/MockCLGauge.sol";
import {MockCLPool} from "../mocks/MockCLPool.sol";
import {MockComptroller, MockMoonwellMarket} from "../mocks/MockMoonwellMarket.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockToken} from "../mocks/MockToken.sol";

import {Test} from "@forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title LeveragedAerodromeCLStrategy init + width-band unit tests
 * @notice Fork-free suite covering the any-pool generalization of the vendored strategy: the init
 *         venue/identity guards, the DERIVED leg config (decimals, pool token ordering), the
 *         separately-configured leg<->USDC swap-pool spacings, and the rerange width band.
 * @dev Venue-mock harness only — the position lifecycle (execute / deployIdle / compound / rerange
 *      bodies) needs real Slipstream + Moonwell venues and is fork-test territory, out of scope
 *      here. What IS covered is everything reachable without opening a position: `_initialize`'s
 *      full validation ladder, what it persists, and the entrypoint gating on `rerange`.
 *
 *      LEG SLOTS: the strategy's `weth*` fields are leg A and its `cbBTC*` fields are leg B; the
 *      names are historical and imply no token. This suite deliberately fills them with generic
 *      `legA`/`legB` mock tokens to prove that.
 */
contract LeveragedAeroStrategyInitUnitTest is Test {
    address public owner = makeAddr("owner");
    address public proposer = makeAddr("proposer");
    address public feeRecipient = makeAddr("feeRecipient");
    address public npm = makeAddr("npm");
    address public swapRouter = makeAddr("swapRouter");

    MockToken public usdc; // 6dp — unit of account
    MockToken public legA; // 18dp — the natively-wrappable slot
    MockToken public legB; // 8dp
    MockToken public aero; // 18dp — gauge reward token

    LeveragedAeroVault public vault;
    LeveragedAerodromeCLStrategy public template;

    MockCLPool public pool;
    MockCLGauge public gauge;
    MockComptroller public comptroller;
    MockMoonwellMarket public mUsdc;
    MockMoonwellMarket public mLegA;
    MockMoonwellMarket public mLegB;
    MockPriceFeed public feed; // 8dp — shared by every feed slot

    int24 internal constant SPACING = 100;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        legA = new MockToken("Leg A", "LEGA", 18);
        legB = new MockToken("Leg B", "LEGB", 8);
        aero = new MockToken("Aerodrome", "AERO", 18);

        vault = new LeveragedAeroVault(address(usdc), owner, "Leveraged Aero Vault", "lvAERO");
        template = new LeveragedAerodromeCLStrategy();

        // Default ordering: leg B is token0, leg A is token1 (i.e. `wethIsToken0 == false`).
        pool = new MockCLPool(address(legB), address(legA), SPACING);
        gauge = new MockCLGauge(address(aero));
        comptroller = new MockComptroller();
        mUsdc = new MockMoonwellMarket(address(usdc));
        mLegA = new MockMoonwellMarket(address(legA));
        mLegB = new MockMoonwellMarket(address(legB));
        feed = new MockPriceFeed(1e8, 8, block.timestamp);
    }

    // ==================== HELPERS ====================

    /// @dev A fully valid `InitParams`. Field-by-field (not a struct literal) to keep the Yul IR
    ///      off the 16-live-variable cliff, mirroring the source's own builders.
    function _baseParams() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        p.usdc = address(usdc);
        p.mUsdc = address(mUsdc);
        p.mCbBTC = address(mLegB);
        p.mWeth = address(mLegA);
        p.comptroller = address(comptroller);
        p.cbBTC = address(legB);
        p.weth = address(legA);
        p.pool = address(pool);
        p.npm = npm;
        p.gauge = address(gauge);
        p.swapRouter = swapRouter;
        p.cbBTCFeed = address(feed);
        p.wethFeed = address(feed);
        p.usdcFeed = address(feed);
        p.sequencerFeed = address(feed);
        p.aeroUsdFeed = address(feed);
        p.maxDelay = 1 hours;
        p.gracePeriod = 1 hours;
        p.calmDeviationTicks = 100;
        p.twapWindow = 600;
        p.tickSpacing = SPACING;
        p.cbBTCSwapTickSpacing = 100;
        p.wethSwapTickSpacing = 200;
        p.wethDeliversNative = true;
        p.width = 4000;
        p.minWidth = 200; // 2 x SPACING
        p.maxWidth = 20_000;
        p.targetLtvBps = 5000;
        p.maxLtvBps = 6500;
        p.minHealthBps = 12_000;
        p.maxSlippageBps = 100;
        p.managementFeeBps = 100;
        p.performanceFeeBps = 1000;
        p.feeRecipient = feeRecipient;
    }

    function _clone() internal returns (LeveragedAerodromeCLStrategy) {
        return LeveragedAerodromeCLStrategy(payable(Clones.clone(address(template))));
    }

    function _init(LeveragedAerodromeCLStrategy.InitParams memory p)
        internal
        returns (LeveragedAerodromeCLStrategy s)
    {
        s = _clone();
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function _expectInitRevert(LeveragedAerodromeCLStrategy.InitParams memory p, bytes4 err) internal {
        LeveragedAerodromeCLStrategy s = _clone();
        vm.expectRevert(err);
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    /// @dev Rewire the pool pair + both borrow markets so `legB_`/`legA_` clear the venue-identity
    ///      guards; lets a test reach a LATER guard (leg identity, decimals) with a swapped leg.
    function _wireLegs(address legB_, address legA_) internal {
        pool.setTokens(legB_, legA_);
        mLegB.setUnderlying(legB_);
        mLegA.setUnderlying(legA_);
    }

    // ==================== HAPPY PATH ====================

    function testInitStoresDerivedLegConfig() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        LeveragedAerodromeCLStrategy.LayoutView memory v = s.layout();

        assertEq(v.cbBTCDecimals, 8, "leg B decimals read from the token");
        assertEq(v.wethDecimals, 18, "leg A decimals read from the token");
        assertFalse(v.wethIsToken0, "leg A is token1 in this wiring");
        assertTrue(v.wethDeliversNative, "native-delivery flag");
        assertEq(v.cbBTCSwapTickSpacing, 100, "leg B swap-pool spacing");
        assertEq(v.wethSwapTickSpacing, 200, "leg A swap-pool spacing");
        assertEq(v.tickSpacing, SPACING, "LP pool spacing");
        assertEq(v.width, 4000, "genesis width");
        assertEq(v.minWidth, 200, "min width");
        assertEq(v.maxWidth, 20_000, "max width");
    }

    /// @dev Leg decimals are READ, not assumed 8/18 — a 6dp/12dp pair stores exactly what it reports.
    function testInitStoresArbitraryLegDecimals() public {
        MockToken six = new MockToken("Six", "SIX", 6);
        MockToken twelve = new MockToken("Twelve", "TWELVE", 12);
        _wireLegs(address(six), address(twelve));

        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTC = address(six);
        p.weth = address(twelve);

        LeveragedAerodromeCLStrategy.LayoutView memory v = _init(p).layout();
        assertEq(v.cbBTCDecimals, 6, "leg B decimals");
        assertEq(v.wethDecimals, 12, "leg A decimals");
    }

    function testInitNonNativeLegStoresFlagFalse() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.wethDeliversNative = false;
        assertFalse(_init(p).layout().wethDeliversNative, "plain ERC-20 borrow leg");
    }

    // ==================== POOL TOKEN ORDERING (both branches) ====================

    function testInitDerivesWethIsToken0False() public {
        _wireLegs(address(legB), address(legA)); // leg B first
        assertFalse(_init(_baseParams()).layout().wethIsToken0, "leg A sorts second");
    }

    function testInitDerivesWethIsToken0True() public {
        pool.setTokens(address(legA), address(legB)); // leg A first
        assertTrue(_init(_baseParams()).layout().wethIsToken0, "leg A sorts first");
    }

    // ==================== VENUE IDENTITY GUARDS ====================

    function testInitRevertsOnPoolTickSpacingMismatch() public {
        pool.setTickSpacing(200);
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsWhenPoolToken0IsForeign() public {
        pool.setTokens(address(aero), address(legA));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsWhenPoolToken1IsForeign() public {
        pool.setTokens(address(legB), address(aero));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev Both pool tokens are legs but the SAME leg twice — the set compare must reject it.
    function testInitRevertsWhenPoolIsNotTheLegPair() public {
        pool.setTokens(address(legB), address(legB));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsWhenLegBMarketWrapsAnotherToken() public {
        mLegB.setUnderlying(address(aero));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsWhenLegAMarketWrapsAnotherToken() public {
        mLegA.setUnderlying(address(aero));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsOnZeroLegBSwapSpacing() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTCSwapTickSpacing = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsOnZeroLegASwapSpacing() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.wethSwapTickSpacing = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    // ==================== UNSUPPORTED LEGS ====================

    function testInitRevertsWhenLegBIsUsdc() public {
        _wireLegs(address(usdc), address(legA));
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTC = address(usdc);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.UnsupportedLeg.selector);
    }

    function testInitRevertsWhenLegAIsUsdc() public {
        _wireLegs(address(legB), address(usdc));
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.weth = address(usdc);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.UnsupportedLeg.selector);
    }

    function testInitRevertsWhenLegBIsGaugeRewardToken() public {
        _wireLegs(address(aero), address(legA));
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTC = address(aero);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.UnsupportedLeg.selector);
    }

    function testInitRevertsWhenLegAIsGaugeRewardToken() public {
        _wireLegs(address(legB), address(aero));
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.weth = address(aero);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.UnsupportedLeg.selector);
    }

    // ==================== LEG DECIMALS BAND ====================

    function testInitRevertsWhenLegDecimalsTooHigh() public {
        MockToken big = new MockToken("Nineteen", "N19", 19);
        _wireLegs(address(big), address(legA));
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTC = address(big);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.LegDecimalsOutOfRange.selector);
    }

    function testInitRevertsWhenLegDecimalsTooLow() public {
        MockToken tiny = new MockToken("One", "N1", 1);
        _wireLegs(address(legB), address(tiny));
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.weth = address(tiny);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.LegDecimalsOutOfRange.selector);
    }

    function testInitAcceptsLegDecimalsAtBandEdges() public {
        MockToken two = new MockToken("Two", "N2", 2);
        MockToken eighteen = new MockToken("Eighteen", "N18", 18);
        _wireLegs(address(two), address(eighteen));

        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTC = address(two);
        p.weth = address(eighteen);

        LeveragedAerodromeCLStrategy.LayoutView memory v = _init(p).layout();
        assertEq(v.cbBTCDecimals, 2, "lower edge accepted");
        assertEq(v.wethDecimals, 18, "upper edge accepted");
    }

    // ==================== WIDTH BAND ====================

    function testInitRevertsWhenWidthOffTheSpacingGrid() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.width = 4050; // not a multiple of SPACING
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
    }

    function testInitRevertsWhenMinWidthBelowTwoSpacings() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minWidth = 100; // 1 x SPACING
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
    }

    function testInitRevertsWhenMinWidthAboveMaxWidth() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minWidth = 30_000;
        p.maxWidth = 20_000;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
    }

    function testInitRevertsWhenWidthBelowMinWidth() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.width = 100;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
    }

    function testInitRevertsWhenWidthAboveMaxWidth() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.width = 30_000;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
    }

    function testInitRevertsWhenBandBoundsOffTheSpacingGrid() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minWidth = 250;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);

        p = _baseParams();
        p.maxWidth = 20_050;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
    }

    function testInitRevertsOnNonPositiveTickSpacing() public {
        pool.setTickSpacing(0);
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.tickSpacing = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
    }

    /// @dev The aligned/in-band matrix: every width that is a multiple of the spacing and lands
    ///      inside `[minWidth, maxWidth]` is accepted at the band edges included.
    function testInitAcceptsWidthMatrix() public {
        uint24[4] memory widths = [uint24(200), 1000, 12_300, 20_000];
        for (uint256 i; i < widths.length; ++i) {
            LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
            p.width = widths[i];
            assertEq(_init(p).layout().width, widths[i], "aligned in-band width accepted");
        }
    }

    /// @dev Fuzz the shared width predicate through init: aligned + in-band accepts, and every
    ///      other combination reverts with the same typed error.
    function testFuzzInitWidthBand(uint24 width_) public {
        width_ = uint24(bound(uint256(width_), 0, 40_000));
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.width = width_;

        bool ok = width_ % uint24(SPACING) == 0 && width_ >= p.minWidth && width_ <= p.maxWidth;
        if (ok) {
            assertEq(_init(p).layout().width, width_, "accepted width persisted");
        } else {
            _expectInitRevert(p, LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
        }
    }

    // ==================== RERANGE ENTRYPOINT ====================

    /// @dev The new 3-arg signature is live and its gates are ordered lifecycle-first: a Pending
    ///      clone rejects an otherwise-valid width with `NotExecuted`, before any width check.
    function testRerangeRevertsBeforeExecute() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        s.rerange(4000, 0, 0);
    }

    function testRerangeRevertsForNonProposer() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        s.rerange(4000, 0, 0);
    }
}
