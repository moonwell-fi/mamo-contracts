// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "@contracts/leveraged-aero/sherwood/BaseStrategy.sol";

import {MockCLGauge} from "../mocks/MockCLGauge.sol";
import {MockCLFactory, MockCLPool} from "../mocks/MockCLPool.sol";
import {MockComptroller, MockMoonwellMarket} from "../mocks/MockMoonwellMarket.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockAeroV2Factory} from "./LeveragedAeroVenuesHarness.sol";

import {Test, Vm} from "@forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title LeveragedAerodromeCLStrategy init + width-band unit tests
 * @notice Fork-free suite covering `_initialize` in full — every guard in the validation ladder
 *         (zero addresses, feed/asset decimals, venue identity, swap-pool existence, leg support,
 *         width band, risk-param bounds, oracle-param bounds, fee ceilings), the DERIVED leg config
 *         (decimals, pool token ordering) it persists, and the entrypoint gating on `rerange`.
 * @dev Venue-mock harness only — the position lifecycle (execute / deployIdle / compound / rerange
 *      BODIES) needs real Slipstream + Moonwell venues and is fork-test territory, out of scope
 *      here. Coverage stops at what is reachable without opening a position.
 *
 *      Guards are ORDERED, so each negative test starts from a fully valid `_baseParams()` and
 *      perturbs exactly one field — otherwise an earlier guard would mask the one under test.
 *
 *      LEG SLOTS: the strategy's `weth*` fields are leg A and its `cbBTC*` fields are leg B; the
 *      names are historical and imply no token. This suite deliberately fills them with generic
 *      `legA`/`legB` mock tokens to prove that.
 */
contract LeveragedAeroStrategyInitUnitTest is Test {
    /// @dev Mirrored from {LeveragedAerodromeCLStrategy} for `vm.expectEmit` / topic matching.
    event FeeCrystallizeDeferred(uint8 op, uint256 navPre);
    event TargetLtvUpdated(uint16 previousBps, uint16 newBps);
    event MaxLtvUpdated(uint16 previousBps, uint16 newBps);
    event WidthBoundsUpdated(uint24 previousMinWidth, uint24 previousMaxWidth, uint24 newMinWidth, uint24 newMaxWidth);
    event ProposerUpdated(address indexed oldProposer, address indexed newProposer);

    /// @dev The strategy's `OP_COMPOUND` deferral code (private there).
    uint8 internal constant OP_COMPOUND = 3;

    address public owner = makeAddr("owner");
    address public proposer = makeAddr("proposer");
    address public feeRecipient = makeAddr("feeRecipient");
    address public lp = makeAddr("lp");
    address public attacker = makeAddr("attacker");
    address public npm = makeAddr("npm");
    address public swapRouter = makeAddr("swapRouter");

    MockToken public usdc; // 6dp — unit of account
    MockToken public legA; // 18dp — the natively-wrappable slot
    MockToken public legB; // 8dp
    MockToken public aero; // 18dp — gauge reward token

    LeveragedAeroVault public vault;
    LeveragedAerodromeCLStrategy public template;

    MockCLPool public pool;
    MockCLFactory public clFactory;
    MockCLGauge public gauge;
    MockComptroller public comptroller;
    MockMoonwellMarket public mUsdc;
    MockMoonwellMarket public mLegA;
    MockMoonwellMarket public mLegB;
    MockPriceFeed public feed; // 8dp — shared by every feed slot

    int24 internal constant SPACING = 100;
    int24 internal constant LEG_B_SWAP_SPACING = 100;
    int24 internal constant LEG_A_SWAP_SPACING = 200;

    /// @dev Count of `address` members in `InitParams` — the ZeroAddress ladder walks all of them.
    uint256 internal constant ADDRESS_PARAM_COUNT = 16;

    /// @dev `2 * TickMath.MAX_TICK` — the ceiling `_initialize` enforces on `maxWidth`.
    uint24 internal constant MAX_BAND_WIDTH = 1_774_544;

    /// @dev The strategy's ERC-7201 base slot (private there):
    ///      `keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 internal constant STORAGE_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /// @dev Counted off `Layout`: the packed tail is slot 26, so the hedged principals share slot 27.
    uint256 internal constant TAIL_SLOT_OFFSET = 26;

    /// @dev Aerodrome v2 PoolFactory, hardcoded in `LeveragedAeroValuation`, etched below for the probe.
    address internal constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @dev `applyVenue` pins the canonical Slipstream CLFactory, so the mock registry is etched HERE.
    address internal constant AERODROME_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        legA = new MockToken("Leg A", "LEGA", 18);
        legB = new MockToken("Leg B", "LEGB", 8);
        aero = new MockToken("Aerodrome", "AERO", 18);

        vault = new LeveragedAeroVault(address(usdc), owner, "Leveraged Aero Vault", "lvAERO");
        template = new LeveragedAerodromeCLStrategy();

        // Default ordering: leg B is token0, leg A is token1 (i.e. `wethIsToken0 == false`).
        pool = new MockCLPool(address(legB), address(legA), SPACING);
        clFactory = MockCLFactory(AERODROME_CL_FACTORY);
        vm.etch(AERODROME_CL_FACTORY, address(new MockCLFactory()).code);
        pool.setFactory(AERODROME_CL_FACTORY);
        clFactory.setPool(address(legA), address(legB), SPACING, address(pool));
        // Both leg<->USDC swap venues exist at their configured spacings (init probes for them).
        _registerSwapPools(address(legB), address(legA));

        gauge = new MockCLGauge(address(aero));
        gauge.setPool(address(pool));
        pool.setGauge(address(gauge));
        // The reward-route probe reads a HARDCODED v2 factory address; place code there.
        vm.etch(AERO_V2_FACTORY, address(new MockAeroV2Factory(address(aero), address(usdc), address(0xA2F))).code);
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
        p.cbBTCSwapTickSpacing = LEG_B_SWAP_SPACING;
        p.wethSwapTickSpacing = LEG_A_SWAP_SPACING;
        p.wethDeliversNative = true;
        p.width = 4000;
        p.minWidth = 200; // 2 x SPACING
        p.maxWidth = 20_000;
        p.skewBps = 5000; // centred — the historical behaviour, and the baseline every skew test perturbs
        // The WIDEST LEGAL band `[1, 9999]` == the open `(0, 10000)` interval, so it is a no-op default.
        p.minSkewBps = 1;
        p.maxSkewBps = 9999;
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

    /// @dev The UNBOUND init path: `cloneAndBind` is set-once, so the vault-only `initialize` is pranked.
    function _init(LeveragedAerodromeCLStrategy.InitParams memory p)
        internal
        returns (LeveragedAerodromeCLStrategy s)
    {
        s = _clone();
        vm.prank(address(vault));
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    /// @dev The PRODUCTION path: clone + initialize + bind atomically, for tests needing the share hooks.
    function _initBound(LeveragedAerodromeCLStrategy.InitParams memory p)
        internal
        returns (LeveragedAerodromeCLStrategy s)
    {
        vm.prank(owner);
        s = LeveragedAerodromeCLStrategy(payable(vault.cloneAndBind(address(template), proposer, abi.encode(p))));
    }

    function _expectInitRevert(LeveragedAerodromeCLStrategy.InitParams memory p, bytes4 err) internal {
        LeveragedAerodromeCLStrategy s = _clone();
        vm.prank(address(vault));
        vm.expectRevert(err);
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    /// @dev Register the two leg<->USDC swap venues so the init existence probe finds them.
    function _registerSwapPools(address legB_, address legA_) internal {
        clFactory.setPool(address(usdc), legB_, LEG_B_SWAP_SPACING, makeAddr("legBSwapPool"));
        clFactory.setPool(address(usdc), legA_, LEG_A_SWAP_SPACING, makeAddr("legASwapPool"));
    }

    /// @dev Re-register a rewired LP pool, or `applyVenue` masks every later guard behind `VenueMismatch`.
    function _registerLpPool() internal {
        clFactory.setPool(pool.token0(), pool.token1(), pool.tickSpacing(), address(pool));
    }

    /// @dev Rewire the pool pair + both borrow markets + both swap venues so `legB_`/`legA_` clear
    ///      the venue-identity guards; lets a test reach a LATER guard (leg identity, decimals) with
    ///      a swapped leg.
    function _wireLegs(address legB_, address legA_) internal {
        pool.setTokens(legB_, legA_);
        mLegB.setUnderlying(legB_);
        mLegA.setUnderlying(legA_);
        _registerSwapPools(legB_, legA_);
        // LAST: the leg-B swap key can collide with the LP pool's, and the LP registration must win.
        _registerLpPool();
    }

    /// @dev `_baseParams()` with the `i`-th address member zeroed. An if-ladder rather than a loop
    ///      over a packed array so the mapping index -> field name stays readable and total.
    function _paramsWithZeroedAddress(uint256 i)
        internal
        view
        returns (LeveragedAerodromeCLStrategy.InitParams memory p)
    {
        p = _baseParams();
        if (i == 0) p.usdc = address(0);
        else if (i == 1) p.mUsdc = address(0);
        else if (i == 2) p.mCbBTC = address(0);
        else if (i == 3) p.mWeth = address(0);
        else if (i == 4) p.comptroller = address(0);
        else if (i == 5) p.cbBTC = address(0);
        else if (i == 6) p.weth = address(0);
        else if (i == 7) p.pool = address(0);
        else if (i == 8) p.npm = address(0);
        else if (i == 9) p.gauge = address(0);
        else if (i == 10) p.swapRouter = address(0);
        else if (i == 11) p.cbBTCFeed = address(0);
        else if (i == 12) p.wethFeed = address(0);
        else if (i == 13) p.usdcFeed = address(0);
        else if (i == 14) p.sequencerFeed = address(0);
        else if (i == 15) p.aeroUsdFeed = address(0);
        else revert("index out of range");
    }

    // ==================== INITIALIZE IS VAULT-ONLY (F13) ====================

    /// @dev A bare clone could once be `initialize`d by ANYONE, seizing the operator key and the leverage
    ///      policy. Gated on `msg.sender == vault_` — the ARGUMENT, since `_vault` is not stored yet.
    function testInitializeRejectsANonVaultCaller() public {
        LeveragedAerodromeCLStrategy s = _clone();

        // The attacker: names themselves proposer and picks their own leverage policy.
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.targetLtvBps = 6400;
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        s.initialize(address(vault), attacker, abi.encode(p));

        // Not even the vault's OWNER, which makes `cloneAndBind` the only path.
        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        s.initialize(address(vault), proposer, abi.encode(_baseParams()));

        assertEq(s.vault(), address(0), "nothing was written");
    }

    /// @dev The positive control, so the gate is not just "initialize always reverts".
    function testInitializeAcceptsTheVault() public {
        LeveragedAerodromeCLStrategy s = _clone();

        vm.prank(address(vault));
        s.initialize(address(vault), proposer, abi.encode(_baseParams()));

        assertEq(s.vault(), address(vault), "bound to the caller it names");
        assertEq(s.proposer(), proposer, "proposer wired");
    }

    /// @dev And the production path works end to end: `cloneAndBind` calls `initialize` AS the vault.
    function testCloneAndBindSatisfiesTheVaultOnlyGate() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());

        assertEq(vault.strategy(), address(s), "bound");
        assertEq(s.vault(), address(vault), "and pointed back");
        assertEq(s.proposer(), proposer, "proposer wired atomically");
    }

    // ==================== PROPOSER ROTATION (F26) ====================

    /// @dev VAULT-ONLY: the owner reaches it through the vault's `onlyOwner` `setProposer`, never direct.
    function testSetProposerIsVaultOnly() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());
        address newProposer = makeAddr("newProposer");

        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        s.setProposer(newProposer);

        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        s.setProposer(newProposer);

        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        s.setProposer(newProposer);
    }

    /// @dev The rotation is real on the `onlyProposer` surface: the old key loses `rerange`, the new gets it.
    function testRotationMovesTheOnlyProposerSurface() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());
        _forceState(s, BaseStrategy.State.Executed);
        address newProposer = makeAddr("newProposer");

        vm.expectEmit(true, true, false, false, address(s));
        emit ProposerUpdated(proposer, newProposer);
        vm.prank(owner);
        vault.setProposer(newProposer);
        assertEq(s.proposer(), newProposer, "the role moved");

        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        s.rerange(4000, 5000, 0, 0);

        vm.prank(newProposer);
        s.rerange(4000, 5000, 0, 0);
        assertEq(s.layout().width, 4000, "the new key drives the strategy");
    }

    /// @dev NOT state-gated: a key can be lost in `Pending`, before `execute`, just as easily.
    function testRotationWorksBeforeExecute() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Pending), "precondition: still Pending");

        address newProposer = makeAddr("newProposer");
        vm.prank(owner);
        vault.setProposer(newProposer);

        assertEq(s.proposer(), newProposer, "rotated while Pending");
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
        pool.setTokens(address(legA), address(legB));
        _registerLpPool(); // leg A first
        assertTrue(_init(_baseParams()).layout().wethIsToken0, "leg A sorts first");
    }

    // ==================== ZERO-ADDRESS LADDER ====================

    /// @dev EVERY address member is individually rejected — a gap here means one venue/feed slot can
    ///      be left unset and only surfaces as an unexplained revert on the first live call.
    function testInitRevertsOnEveryZeroAddressParam() public {
        for (uint256 i; i < ADDRESS_PARAM_COUNT; ++i) {
            _expectInitRevert(_paramsWithZeroedAddress(i), BaseStrategy.ZeroAddress.selector);
        }
    }

    // ==================== FEED / ASSET DECIMALS ====================

    /// @dev The AERO/USD floor in `compoundImpl` scales an 8dp price — a non-8dp aggregator would
    ///      mis-scale it silently, so it is pinned at init.
    function testInitRevertsOnNonEightDecimalAeroFeed() public {
        MockPriceFeed odd = new MockPriceFeed(1e18, 18, block.timestamp);
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.aeroUsdFeed = address(odd);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.UnexpectedFeedDecimals.selector);
    }

    /// @dev `cbBTCFeed` is pinned to 8dp at validation time too; only it is odd here, so this clause is
    ///      what fires. MUTATION: deleting the `cbBTCFeed.decimals() != 8` line alone survived before.
    function testInitRevertsOnNonEightDecimalCbBtcFeed() public {
        MockPriceFeed odd = new MockPriceFeed(1e18, 18, block.timestamp);
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTCFeed = address(odd);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.UnexpectedFeedDecimals.selector);
    }

    /// @dev The same floor hardcodes an 18dp reward token (`mulDiv(aeroBal, price8, 1e20)`).
    function testInitRevertsOnNonEighteenDecimalRewardToken() public {
        MockToken sixDpReward = new MockToken("Reward", "RWD", 6);
        MockCLGauge oddGauge = new MockCLGauge(address(sixDpReward));
        // Bind BOTH directions, or the reciprocal gauge↔pool check masks this guard behind VenueMismatch.
        oddGauge.setPool(address(pool));
        pool.setGauge(address(oddGauge));
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.gauge = address(oddGauge);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.UnexpectedFeedDecimals.selector);
    }

    /// @dev The strategy's unit of account MUST be the bound vault's asset.
    function testInitRevertsWhenUsdcIsNotTheVaultAsset() public {
        MockToken foreign = new MockToken("Foreign", "FRN", 6);
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.usdc = address(foreign);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.AssetMismatch.selector);
    }

    /// @dev `SHARES_VIRTUAL_OFFSET = 1e6` hardcodes a 6dp asset — any other denomination is rejected
    ///      even when the vault and the params agree on the token.
    function testInitRevertsOnNonSixDecimalAsset() public {
        MockToken eightDp = new MockToken("Eight", "EIGHT", 8);
        LeveragedAeroVault oddVault = new LeveragedAeroVault(address(eightDp), owner, "n", "s");

        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.usdc = address(eightDp);

        LeveragedAerodromeCLStrategy s = _clone();
        vm.prank(address(oddVault));
        vm.expectRevert(LeveragedAerodromeCLStrategy.UnexpectedAssetDecimals.selector);
        s.initialize(address(oddVault), proposer, abi.encode(p));
    }

    // ==================== GAUGE BINDING — ONE DIRECTION AT A TIME ====================

    /// @dev The two gauge↔pool checks share a selector, so only the GAUGE lies here: `gauge.pool() != pool`.
    function testInitRejectsAGaugeThatMisreportsItsPool() public {
        MockCLGauge liar = new MockCLGauge(address(aero));
        liar.setPool(makeAddr("someOtherPool")); // the lie
        pool.setGauge(address(liar)); // reciprocal AGREES, so it cannot fire
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.gauge = address(liar);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev The mirror: the gauge is truthful and the POOL lies, so only `pool.gauge() != gauge` fires.
    function testInitRejectsAPoolThatNamesADifferentGauge() public {
        MockCLGauge honest = new MockCLGauge(address(aero));
        honest.setPool(address(pool)); // truthful, so its clause passes
        pool.setGauge(makeAddr("someOtherGauge")); // the lie
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.gauge = address(honest);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    // ==================== CANONICAL FACTORY BINDING ====================

    /// @dev `pool.factory()` is SELF-ATTESTED: a pool naming an attacker's "factory" was adopted on its say-so.
    function testInitRejectsAPoolThatNominatesAForeignFactory() public {
        MockCLFactory rogue = new MockCLFactory();
        rogue.setPool(address(usdc), address(legB), LEG_B_SWAP_SPACING, makeAddr("rogueLegBPool"));
        rogue.setPool(address(usdc), address(legA), LEG_A_SWAP_SPACING, makeAddr("rogueLegAPool"));
        rogue.setPool(address(legB), address(legA), SPACING, address(pool));
        // Fully self-consistent under its own registry — and rejected anyway.
        pool.setFactory(address(rogue));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev Claiming the canonical factory is not enough: it must register this pool at pair + spacing.
    function testInitRejectsAPoolTheCanonicalFactoryDoesNotRegister() public {
        clFactory.setPool(address(legB), address(legA), SPACING, address(0));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev And it must be registered as THIS pool — a look-alike at the same key is not the venue.
    function testInitRejectsAnImpostorAtTheRegisteredKey() public {
        clFactory.setPool(address(legB), address(legA), SPACING, makeAddr("someOtherPool"));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    // ==================== TWAP AVAILABILITY (live at init) ====================

    /// @dev REGRESSION: written AFTER `applyVenue`, `$.twapWindow` made the probe the vacuous `observe([0, 0])`.
    function testInitProbesTheTwapWindowAgainstTheRealHistory() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        pool.setMaxObservationAge(p.twapWindow - 1); // history one second short of the window
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev Boundary companion: history exactly spanning the window is adoptable, so the guard is real.
    function testInitAcceptsAPoolWhoseHistoryExactlySpansTheWindow() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        pool.setMaxObservationAge(p.twapWindow);
        LeveragedAerodromeCLStrategy s = _clone();
        vm.prank(address(vault));
        s.initialize(address(vault), proposer, abi.encode(p));
        assertEq(s.layout().twapWindow, p.twapWindow, "twapWindow stored");
    }

    // ==================== VENUE IDENTITY GUARDS ====================

    function testInitRevertsOnPoolTickSpacingMismatch() public {
        pool.setTickSpacing(200);
        _registerLpPool();
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsWhenPoolToken0IsForeign() public {
        pool.setTokens(address(aero), address(legA));
        _registerLpPool();
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsWhenPoolToken1IsForeign() public {
        pool.setTokens(address(legB), address(aero));
        _registerLpPool();
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev Both pool tokens are legs but the SAME leg twice — the set compare must reject it.
    function testInitRevertsWhenPoolIsNotTheLegPair() public {
        pool.setTokens(address(legB), address(legB));
        _registerLpPool();
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

    /// @dev The collateral market must wrap the unit of account, symmetrically with the two borrow
    ///      legs — otherwise every supply/redeem moves a token the NAV never prices.
    function testInitRevertsWhenCollateralMarketWrapsAnotherToken() public {
        mUsdc.setUnderlying(address(aero));
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

    /// @dev `int24` is signed: a negative spacing is not "nonzero and therefore fine". It would be
    ///      handed straight to the swap router as a pool key.
    function testInitRevertsOnNegativeLegBSwapSpacing() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTCSwapTickSpacing = -100;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsOnNegativeLegASwapSpacing() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.wethSwapTickSpacing = -200;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev Positive-and-nonzero is not enough: a spacing with NO pool behind it routes every
    ///      leg<->USDC swap at a nonexistent venue, bricking settle / deleverage / shortfall-cover on
    ///      a live levered book. Init probes the factory for each.
    function testInitRevertsWhenLegBSwapPoolDoesNotExist() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTCSwapTickSpacing = 2000; // valid-looking, but nothing registered at that spacing
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsWhenLegASwapPoolDoesNotExist() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.wethSwapTickSpacing = 2000;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev The probe is a real lookup, not a formality: de-registering an existing venue rejects the
    ///      exact params that pass in `setUp`.
    function testInitRevertsWhenLegBSwapPoolIsDeregistered() public {
        clFactory.setPool(address(usdc), address(legB), LEG_B_SWAP_SPACING, address(0));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    function testInitRevertsWhenLegASwapPoolIsDeregistered() public {
        clFactory.setPool(address(usdc), address(legA), LEG_A_SWAP_SPACING, address(0));
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    // ==================== ASSET-AS-A-LEG (asset-mode) INIT LADDER ====================
    //
    // The shape is EMERGENT FROM CONFIG: `legBIsAsset` is DERIVED as `cbBTC == usdc`, never passed.
    // Only the LEG-B slot may be the unit of account. These tests pin the whole asset-mode ladder.

    /// @dev Wire the venues for asset-mode (a legA/USDC LP pool) and return valid params. `legAFirst`
    ///      selects the pool token ordering so both `wethIsToken0` branches are reachable.
    function _assetModeParams(bool legAFirst) internal returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        pool.setTokens(legAFirst ? address(legA) : address(usdc), legAFirst ? address(usdc) : address(legA));
        _registerLpPool();
        mLegA.setUnderlying(address(legA));
        clFactory.setPool(address(usdc), address(legA), LEG_A_SWAP_SPACING, makeAddr("legASwapPool"));

        p = _baseParams();
        p.cbBTC = address(usdc); // ← the leg-B slot IS the asset; this alone selects the shape
        p.mCbBTC = address(mUsdc); // leg B is never borrowed → pinned to the collateral market
        p.cbBTCFeed = address(feed); // == usdcFeed, so leg B prices at face
        p.cbBTCSwapTickSpacing = 0; // declared UNUSED (no USDC/USDC swap pool exists)
    }

    /// @dev THE headline case: leg B == usdc is ACCEPTED and derives asset-mode, in BOTH orderings.
    function testInitAcceptsLegBAsTheAssetBothOrderings() public {
        LeveragedAerodromeCLStrategy.LayoutView memory v = _init(_assetModeParams(false)).layout();
        assertTrue(v.legBIsAsset, "asset-mode derived from cbBTC == usdc");
        assertFalse(v.wethIsToken0, "leg A sorts second here");
        assertEq(v.cbBTC, address(usdc), "leg-B slot holds the unit of account");
        assertEq(v.cbBTCDecimals, 6, "leg-B decimals are USDC's");
        assertEq(v.cbBTCSwapTickSpacing, 0, "leg-B swap spacing stays unused");

        v = _init(_assetModeParams(true)).layout();
        assertTrue(v.legBIsAsset, "asset-mode derived in the other ordering too");
        assertTrue(v.wethIsToken0, "leg A sorts first here");
    }

    /// @dev The two-borrowed-legs shape must keep deriving `legBIsAsset == false` — the flag is not a
    ///      default-on footgun.
    function testInitDerivesTwoLegShapeWhenNeitherLegIsTheAsset() public {
        assertFalse(_init(_baseParams()).layout().legBIsAsset, "two borrowed legs");
    }

    /// @dev Leg B is never borrowed in asset-mode, so its market slot MUST be the collateral market.
    ///      Pinning it is what makes every `borrowBalanceStored($.mCbBTC)` read structurally 0, which is
    ///      why no debt/health/repay path needs an asset-mode branch.
    function testInitRevertsWhenAssetModeLegBMarketIsNotTheCollateralMarket() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _assetModeParams(false);
        MockMoonwellMarket otherUsdcMarket = new MockMoonwellMarket(address(usdc));
        p.mCbBTC = address(otherUsdcMarket); // wraps usdc, so the underlying check passes...
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector); // ...but it is not mUsdc
    }

    /// @dev The leg-B swap spacing is DECLARED UNUSED in asset-mode: a nonzero value would advertise a
    ///      USDC↔USDC route that must never be taken. (The old sign-check + factory probe would also
    ///      have demanded a nonexistent USDC/USDC pool — this replaces it, it does not skip it.)
    function testInitRevertsWhenAssetModeLegBSwapSpacingIsSet() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _assetModeParams(false);
        p.cbBTCSwapTickSpacing = LEG_B_SWAP_SPACING;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);

        p = _assetModeParams(false);
        p.cbBTCSwapTickSpacing = -100; // negative is no better than positive: it must be exactly 0
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev Leg B must price at FACE. A leg-B feed left pointing at a volatile aggregator would value
    ///      idle USDC at that token's price — a silent NAV blow-up straight into deposit share-pricing.
    function testInitRevertsWhenAssetModeLegBFeedIsNotTheUsdcFeed() public {
        MockPriceFeed volatileFeed = new MockPriceFeed(1e13, 8, block.timestamp);
        LeveragedAerodromeCLStrategy.InitParams memory p = _assetModeParams(false);
        p.cbBTCFeed = address(volatileFeed);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev Leg A's swap venue stays checked UNCONDITIONALLY — it is a real borrowed leg in both shapes,
    ///      and every shortfall-cover / sweep routes through it.
    function testInitRevertsWhenAssetModeLegASwapPoolMissing() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _assetModeParams(false);
        p.wethSwapTickSpacing = 2000; // valid-looking, nothing registered
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);

        p = _assetModeParams(false);
        p.wethSwapTickSpacing = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev The pool's token SET must be exactly {legA, usdc} in asset-mode. A pool holding a foreign
    ///      token — or the degenerate all-USDC pool — is rejected by the same pair check as before.
    function testInitRevertsWhenAssetModePoolIsNotTheLegAUsdcPair() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _assetModeParams(false);
        pool.setTokens(address(usdc), address(legB));
        _registerLpPool(); // legB is a foreign token now, not a slot
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);

        p = _assetModeParams(false);
        pool.setTokens(address(usdc), address(usdc));
        _registerLpPool(); // degenerate USDC/USDC
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.VenueMismatch.selector);
    }

    /// @dev Leg B may be the asset but NEVER the gauge reward token — `compound()` sells that wholesale.
    function testInitRevertsWhenAssetModeLegBIsRewardToken() public {
        // Reward-token-as-leg-B is rejected regardless of shape; assert it from the asset-mode wiring.
        _wireLegs(address(aero), address(legA));
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.cbBTC = address(aero);
        p.mCbBTC = address(mLegB);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.UnsupportedLeg.selector);
    }

    // ==================== UNSUPPORTED LEGS ====================

    /// @dev LEG A may never be the unit of account, in EITHER shape — it is USDC's counterparty and
    ///      owns the `wethDeliversNative` wrap path, so the asymmetry with leg B is deliberate.
    ///      Fully wired as if it were "asset-mode on the wrong slot", to prove the rejection is the leg
    ///      identity itself and not some earlier venue guard.
    function testInitRevertsWhenLegAIsUsdcEvenFullyWired() public {
        pool.setTokens(address(legB), address(usdc));
        mLegB.setUnderlying(address(legB));
        clFactory.setPool(address(usdc), address(legB), LEG_B_SWAP_SPACING, makeAddr("legBSwapPool"));
        clFactory.setPool(address(usdc), address(usdc), LEG_A_SWAP_SPACING, makeAddr("bogusSelfPool"));
        _registerLpPool(); // after the swap pools — same key collision as `_wireLegs`

        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.weth = address(usdc);
        p.mWeth = address(mUsdc);
        p.wethFeed = address(feed);
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
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    function testInitRevertsWhenMinWidthBelowTwoSpacings() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minWidth = 100; // 1 x SPACING
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    function testInitRevertsWhenMinWidthAboveMaxWidth() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minWidth = 30_000;
        p.maxWidth = 20_000;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    function testInitRevertsWhenWidthBelowMinWidth() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.width = 100;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    function testInitRevertsWhenWidthAboveMaxWidth() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.width = 30_000;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    function testInitRevertsWhenBandBoundsOffTheSpacingGrid() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minWidth = 250;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);

        p = _baseParams();
        p.maxWidth = 20_050;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    function testInitRevertsOnNonPositiveTickSpacing() public {
        pool.setTickSpacing(0);
        _registerLpPool();
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.tickSpacing = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    /// @dev A NEGATIVE spacing must fail the same way — `int24` is signed and `<= 0`, not `== 0`, is
    ///      the correct predicate (the pool is rewired so the identity guard passes first).
    function testInitRevertsOnNegativeTickSpacing() public {
        pool.setTickSpacing(-100);
        _registerLpPool();
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.tickSpacing = -100;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    /// @dev A skew can put up to `width` ticks on ONE side, so `maxWidth` is capped at `2 x MAX_TICK`.
    function testInitRevertsWhenMaxWidthExceedsTheTickDomain() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.maxWidth = MAX_BAND_WIDTH + uint24(uint24(SPACING)); // aligned, but past the ceiling
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    function testInitAcceptsMaxWidthAtTheTickDomainEdge() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        // Largest aligned width that still fits under the ceiling.
        p.maxWidth = (MAX_BAND_WIDTH / uint24(uint24(SPACING))) * uint24(uint24(SPACING));
        assertEq(_init(p).layout().maxWidth, p.maxWidth, "band edge accepted");
    }

    // ==================== RISK PARAMS ====================

    /// @dev All three routes to a stored ZERO target are guarded; an init-zero would never lever.
    function testInitRevertsOnZeroTargetLtv() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.targetLtvBps = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.TargetLtvZero.selector);
    }

    function testInitRevertsWhenTargetLtvExceedsMax() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.targetLtvBps = 7000;
        p.maxLtvBps = 6500;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.TargetLtvExceedsMax.selector);
    }

    function testInitRevertsWhenMinHealthBelowFloor() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minHealthBps = 10_499;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.MinHealthTooLow.selector);
    }

    /// @dev The floor triggers at `1e8 / 10500 = 9523`, so it needs a CF above that — hence the raise here.
    function testInitAcceptsMinHealthAtTheFloor() public {
        comptroller.setCollateralFactorMantissa(0.96e18); // cf 9600; 10500 * 9600 = 1.008e8 > 1e8
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minHealthBps = 10_500;
        p.maxLtvBps = 6500; // 10500 * 6500 = 6.825e7 < 1e8, so the L4 conflict guard still clears
        assertEq(_init(p).layout().minHealthBps, 10_500, "floor accepted");
    }

    /// @dev `maxLtvBps` must sit strictly BELOW the Moonwell collateral factor (8800 bps here).
    function testInitRevertsWhenMaxLtvReachesTheCollateralFactor() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minHealthBps = 11_000; // keep 11000 * 8800 = 9.68e7 < 1e8 so THIS guard is the one that fires
        p.maxLtvBps = 8800;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.MaxLtvExceedsCF.selector);
    }

    /// @dev L4: the permissionless-deleverage trigger LTV (`1e8 / minHealthBps`) must sit strictly
    ///      above `maxLtvBps`, else there is an in-band range anyone can grief-deleverage.
    function testInitRevertsOnMinHealthMaxLtvConflict() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.maxLtvBps = 8400; // 12000 * 8400 = 1.008e8 >= 1e8, and 8400 < 8800 so MaxLtvExceedsCF clears
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.MinHealthMaxLtvConflict.selector);
    }

    /// @dev The conflict guard is a strict `>=`: the product landing exactly one bps-product below
    ///      the bound is accepted.
    function testInitAcceptsMinHealthMaxLtvAtTheBoundary() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minHealthBps = 12_500;
        p.maxLtvBps = 8000; // 12500 * 8000 == 1e8 exactly -> rejected
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.MinHealthMaxLtvConflict.selector);

        p = _baseParams();
        p.minHealthBps = 12_500;
        p.maxLtvBps = 7900; // 9.875e7 < 1e8 -> accepted
        assertEq(_init(p).layout().maxLtvBps, 7900, "just under the bound accepted");
    }

    /// @dev L4's other side: trigger below CF, else the book is liquidatable while `deleverage()` reverts.
    function testInitRevertsWhenTheDeleverageTriggerSitsAtOrAboveTheCollateralFactor() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minHealthBps = 10_500; // 10500 * 8800 = 9.24e7 <= 1e8 -> trigger 9523 > CF 8800
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.DeleverageTriggerAboveCF.selector);
    }

    /// @dev Strict `>`: product == 1e8 means trigger == CF and is rejected; one bps of CF more is accepted.
    function testInitDeleverageTriggerCollateralFactorBoundaryIsStrict() public {
        comptroller.setCollateralFactorMantissa(0.8e18); // cf 8000
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minHealthBps = 12_500;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.DeleverageTriggerAboveCF.selector);

        comptroller.setCollateralFactorMantissa(0.8001e18); // cf 8001; 12500 * 8001 = 1.000125e8 > 1e8
        p = _baseParams();
        p.minHealthBps = 12_500;
        assertEq(_init(p).layout().minHealthBps, 12_500, "one bps of CF above the bound accepted");
    }

    /// @dev The same boundary from the other knob: a HIGHER minHealth lowers the trigger LTV.
    function testInitDeleverageTriggerAcceptsTheSmallestMinHealthStepAboveTheBound() public {
        comptroller.setCollateralFactorMantissa(0.8e18); // cf 8000
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minHealthBps = 12_501; // 12501 * 8000 = 1.00008e8 > 1e8 -> accepted
        assertEq(_init(p).layout().minHealthBps, 12_501, "one bps of minHealth above the bound accepted");
    }

    /// @dev `_baseParams()` IS the shipping set, so this pins the ordering `5000 <= 6500 < 8333 < 8800`.
    function testInitAcceptsTheProductionRiskParamsUnderTheDeleverageTriggerRung() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        LeveragedAerodromeCLStrategy s = _init(p);
        assertEq(s.layout().minHealthBps, 12_000, "minHealth stored");
        assertEq(s.layout().usdcCollateralFactorBps, 8800, "CF read from the comptroller");
        assertLt(1e8 / uint256(s.layout().minHealthBps), uint256(s.layout().usdcCollateralFactorBps), "trigger < CF");
        assertLt(uint256(s.layout().maxLtvBps), 1e8 / uint256(s.layout().minHealthBps), "maxLtv < trigger");
    }

    /// @dev A comptroller reporting a zero collateral factor is unusable — the read must fail loudly
    ///      rather than yield `cfBps == 0` and make every `maxLtvBps` look too high.
    function testInitRevertsOnZeroCollateralFactor() public {
        comptroller.setCollateralFactorMantissa(0);
        _expectInitRevert(_baseParams(), LeveragedAerodromeCLStrategy.ComptrollerCallFailed.selector);
    }

    // ==================== ORACLE / CALM-GATE PARAM BOUNDS ====================

    /// @dev `maxDelay` in (0, 7 days] — 0 or a huge value disables staleness detection.
    function testInitMaxDelayBounds() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.maxDelay = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OracleParamOutOfRange.selector);

        p = _baseParams();
        p.maxDelay = 7 days + 1;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OracleParamOutOfRange.selector);

        p = _baseParams();
        p.maxDelay = 7 days;
        assertEq(_init(p).layout().maxDelay, 7 days, "upper edge accepted");
    }

    /// @dev `gracePeriod` in [0, 1 days] — zero IS valid (no sequencer grace).
    function testInitGracePeriodBounds() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.gracePeriod = 1 days + 1;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OracleParamOutOfRange.selector);

        p = _baseParams();
        p.gracePeriod = 0;
        assertEq(_init(p).layout().gracePeriod, 0, "zero grace accepted");

        p = _baseParams();
        p.gracePeriod = 1 days;
        assertEq(_init(p).layout().gracePeriod, 1 days, "upper edge accepted");
    }

    /// @dev `twapWindow` in (0, 1 days] — 0 disables the TWAP and with it the calm-gate.
    function testInitTwapWindowBounds() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.twapWindow = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OracleParamOutOfRange.selector);

        p = _baseParams();
        p.twapWindow = uint32(1 days) + 1;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OracleParamOutOfRange.selector);

        p = _baseParams();
        p.twapWindow = uint32(1 days);
        assertEq(_init(p).layout().twapWindow, uint32(1 days), "upper edge accepted");
    }

    /// @dev `calmDeviationTicks` in (0, 5000] — a huge value disables the calm-gate.
    function testInitCalmDeviationBounds() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.calmDeviationTicks = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OracleParamOutOfRange.selector);

        p = _baseParams();
        p.calmDeviationTicks = 5001;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OracleParamOutOfRange.selector);

        p = _baseParams();
        p.calmDeviationTicks = 5000;
        assertEq(_init(p).layout().calmDeviationTicks, 5000, "upper edge accepted");
    }

    /// @dev `maxSlippageBps` in (0, 1000] — 0 or a huge value disables swap-slippage protection.
    function testInitMaxSlippageBounds() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.maxSlippageBps = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OracleParamOutOfRange.selector);

        p = _baseParams();
        p.maxSlippageBps = 1001;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OracleParamOutOfRange.selector);

        p = _baseParams();
        p.maxSlippageBps = 1000;
        assertEq(_init(p).layout().maxSlippageBps, 1000, "upper edge accepted");
    }

    // ==================== FEE PARAMS ====================

    /// @dev Any nonzero fee requires a recipient — fee-shares have nowhere to go otherwise.
    function testInitRevertsWhenManagementFeeHasNoRecipient() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.performanceFeeBps = 0;
        p.feeRecipient = address(0);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.FeeRecipientRequired.selector);
    }

    function testInitRevertsWhenPerformanceFeeHasNoRecipient() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.managementFeeBps = 0;
        p.feeRecipient = address(0);
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.FeeRecipientRequired.selector);
    }

    /// @dev With BOTH fees off, a zero recipient is legitimate.
    function testInitAcceptsZeroRecipientWhenAllFeesAreZero() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.managementFeeBps = 0;
        p.performanceFeeBps = 0;
        p.feeRecipient = address(0);
        assertEq(_init(p).layout().feeRecipient, address(0), "no recipient needed when fees are off");
    }

    /// @dev Performance fee ceiling: `FeeConstants.MAX_PERFORMANCE_FEE_BPS` (1500 = 15%).
    function testInitPerformanceFeeCeiling() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.performanceFeeBps = 1501;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.PerformanceFeeTooHigh.selector);

        p = _baseParams();
        p.performanceFeeBps = 1500;
        assertEq(_init(p).layout().performanceFeeBps, 1500, "ceiling accepted");
    }

    /// @dev Management fee ceiling: `MAX_MANAGEMENT_FEE_BPS` (500 = 5%/yr).
    function testInitManagementFeeCeiling() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.managementFeeBps = 501;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.ManagementFeeTooHigh.selector);

        p = _baseParams();
        p.managementFeeBps = 500;
        assertEq(_init(p).layout().managementFeeBps, 500, "ceiling accepted");
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
            _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        }
    }

    // ==================== RERANGE ENTRYPOINT ====================

    /// @dev Gates are ordered lifecycle-first: a Pending clone rejects a valid pair with `NotExecuted`.
    function testRerangeRevertsBeforeExecute() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        s.rerange(4000, 5000, 0, 0);
    }

    function testRerangeRevertsForNonProposer() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        s.rerange(4000, 5000, 0, 0);
    }

    // ==================== RERANGE SKEW ====================
    // `skewBps` is the fraction of `width` placed BELOW the pool tick (1e4 scale; 5000 == centred), and the
    // one `_checkSkew` predicate validates it at init and on rerange, both raising the SHARED `OutOfBounds()`.
    // Driven through the LIVE `rerange` on a FLAT book, where only the validation ladder and persists run.

    /// @dev An Executed clone on a flat book: `rerange` validates, then is a persist-only no-op.
    function _executedClone() internal returns (LeveragedAerodromeCLStrategy s) {
        s = _init(_baseParams());
        _forceState(s, BaseStrategy.State.Executed);
    }

    function _expectRerangeOutOfBounds(uint24 width_, uint16 skewBps_) internal {
        LeveragedAerodromeCLStrategy s = _executedClone();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.rerange(width_, skewBps_, 0, 0);
    }

    /// @dev A ZERO skew puts the WHOLE width above the tick: one-sided, unsizeable, and refused.
    function testRerangeRevertsForZeroSkew() public {
        _expectRerangeOutOfBounds(4000, 0);
    }

    /// @dev The mirror: the bound is STRICT (`>= 10000`), so there is no "100% below the tick" range.
    function testRerangeRevertsForFullSkew() public {
        _expectRerangeOutOfBounds(4000, 10_000);
    }

    /// @dev Above the 1e4 scale: a `!= 10000` check would have let this uint16 through into the span math.
    function testRerangeRevertsForSkewAbove10000() public {
        _expectRerangeOutOfBounds(4000, 12_000);
    }

    /// @dev WHY THE GUARD IS SPAN-BASED, NOT A FLAT bps BAND: at the narrowest legal width 1000 bps is a
    ///      fifth of a spacing, so both bounds align onto one grid point — yet it is safe at a wider width.
    function testRerangeRevertsWhenSkewStarvesASideBelowOneSpacing() public {
        uint24 tightWidth = 2 * uint24(uint24(SPACING)); // == minWidth: a legal width with no skew room
        _expectRerangeOutOfBounds(tightWidth, 1000); // lower side starved (20 ticks < 100)
        _expectRerangeOutOfBounds(tightWidth, 9000); // upper side starved, symmetrically

        LeveragedAerodromeCLStrategy s = _executedClone();
        vm.prank(proposer);
        s.rerange(tightWidth, 5000, 0, 0); // one spacing each way — the tightest legal geometry
        assertEq(s.layout().skewBps, 5000, "the centred split spans a full spacing each way and passes");
        assertEq(s.layout().width, tightWidth, "...and the width is persisted with it");

        // The SAME 1000 bps is fine once the width can afford it: the guard bounds the span, not the value.
        s = _executedClone();
        vm.prank(proposer);
        s.rerange(2000, 1000, 0, 0); // 200 ticks below, 1800 above
        assertEq(s.layout().skewBps, 1000, "a hard skew is legal at a width that can carry it");
    }

    /// @dev Gate ORDER: auth, then lifecycle, then range params — a bad skew never explains a refused call.
    function testRerangeSkewGatesAfterLifecycleAndAuth() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams()); // Pending
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        s.rerange(4000, 0, 0, 0); // skew 0 IS OutOfBounds — the lifecycle gate still wins

        _forceState(s, BaseStrategy.State.Executed);
        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        s.rerange(4000, 0, 0, 0); // ...and auth wins over the params too
    }

    /// @dev The genesis skew round-trips into storage: every subsequent mint derives its range from it.
    function testInitPersistsSkew() public {
        uint16[4] memory skews = [uint16(500), 3500, 5000, 9500];
        for (uint256 i; i < skews.length; ++i) {
            LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
            p.skewBps = skews[i];
            assertEq(_init(p).layout().skewBps, skews[i], "genesis skew persisted");
        }
    }

    // ==================== SKEW GOVERNANCE BAND ====================
    // `[minSkewBps, maxSkewBps]` is fixed at init and caps how far off centre a PROPOSER may rerange. Init
    // checks `0 < min <= max < 10000`, so the band can only TIGHTEN the span predicate's open `(0, 1e4)`.

    /// @dev A clone whose band is `[2000, 8000]`, i.e. genuinely narrower than `(0, 1e4)`.
    function _bandedParams() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        p = _baseParams();
        p.minSkewBps = 2000;
        p.maxSkewBps = 8000;
    }

    /// @dev The band round-trips into storage — it is what every later `rerange` is measured against.
    function testInitPersistsTheSkewBand() public {
        LeveragedAerodromeCLStrategy.LayoutView memory v = _init(_bandedParams()).layout();
        assertEq(v.minSkewBps, 2000, "minSkewBps persisted");
        assertEq(v.maxSkewBps, 8000, "maxSkewBps persisted");
    }

    /// @dev A genesis skew outside the band is refused on both sides, at a width whose SPANS carry it.
    function testInitRevertsWhenGenesisSkewIsOutsideTheBand() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _bandedParams();
        p.skewBps = 1999;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        p.skewBps = 8001;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
    }

    /// @dev The band is INCLUSIVE at both ends — a proposer may sit exactly on the governance limit.
    function testInitAcceptsGenesisSkewAtBothBandEdges() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _bandedParams();
        p.skewBps = 2000;
        assertEq(_init(p).layout().skewBps, 2000, "the lower band edge is legal");
        p.skewBps = 8000;
        assertEq(_init(p).layout().skewBps, 8000, "the upper band edge is legal");
    }

    /// @dev An INVERTED band is refused at init; `min == max` is legal — it pins the skew to one value.
    function testInitRevertsOnInvertedSkewBand() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minSkewBps = 6000;
        p.maxSkewBps = 4000;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);

        p.minSkewBps = 4000;
        p.maxSkewBps = 4000;
        p.skewBps = 4000;
        assertEq(_init(p).layout().skewBps, 4000, "a degenerate min == max band pins the skew and is legal");
    }

    /// @dev `minSkewBps == 0` / `maxSkewBps == 10000` would claim to WIDEN `(0, 1e4)`; both are refused.
    function testInitRevertsWhenTheBandWouldWidenTheOpenInterval() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minSkewBps = 0;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);

        p = _baseParams();
        p.maxSkewBps = 10_000;
        _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);

        // ...and the widest LEGAL band is `[1, 9999]`, which is exactly `(0, 1e4)` — the suite default.
        p = _baseParams();
        assertEq(_init(p).layout().maxSkewBps, 9999, "the widest legal band is accepted");
    }

    /// @dev The point of the band: a skew the spans carry is still refused outside it, and both edges pass.
    function testRerangeRefusesASkewOutsideTheBand() public {
        LeveragedAerodromeCLStrategy s = _init(_bandedParams());
        _forceState(s, BaseStrategy.State.Executed);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.rerange(4000, 1000, 0, 0); // legal span, below the band

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.rerange(4000, 9000, 0, 0); // legal span, above the band

        vm.prank(proposer);
        s.rerange(4000, 2000, 0, 0);
        assertEq(s.layout().skewBps, 2000, "the lower band edge reranges");
        vm.prank(proposer);
        s.rerange(4000, 8000, 0, 0);
        assertEq(s.layout().skewBps, 8000, "...and so does the upper one");
    }

    /// @dev THE QUANTIZATION CLIFF: the usable skew set widens with `width / tickSpacing`, so at the width
    ///      floor a band excluding ~5000 refuses every rerange. Independent gates; the narrower one wins.
    function testBandAndSpanGatesAreIndependentAtTheWidthFloor() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.minSkewBps = 2000;
        p.maxSkewBps = 4000;
        p.width = 2000; // 20 x spacing: 4000 bps leaves 800 below / 1200 above — both spans fine
        p.skewBps = 4000;
        LeveragedAerodromeCLStrategy s = _init(p);
        _forceState(s, BaseStrategy.State.Executed);

        // The SAME in-band skew at the narrowest width starves the lower span (80 < 100 ticks).
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.rerange(200, 4000, 0, 0);

        // ...and the centred skew that WOULD clear the spans at that width is outside this band.
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.rerange(200, 5000, 0, 0);
    }

    /// @dev ONE PREDICATE, TWO ENTRYPOINTS: any `(width, skew)` pair init accepts, `rerange` accepts, and
    ///      either's `OutOfBounds()` is the other's. Restated independently here, so it is not a tautology.
    function testFuzzInitSkewBandMirrorsRerange(uint16 skewBps_, uint24 width_, uint16 minSkew_, uint16 maxSkew_)
        public
    {
        skewBps_ = uint16(bound(uint256(skewBps_), 0, 12_000));
        width_ = uint24(bound(uint256(width_), 2, 200)) * uint24(uint24(SPACING)); // aligned, in [200, 20000]
        // A LEGAL band STRADDLING centre, so the mirror clone's centred genesis skew stays in-band.
        minSkew_ = uint16(bound(uint256(minSkew_), 1, 5000));
        maxSkew_ = uint16(bound(uint256(maxSkew_), 5000, 9999));

        uint256 spacing = uint256(uint24(SPACING));
        uint256 lowerSpan = (uint256(width_) * uint256(skewBps_)) / 10_000;
        bool ok = skewBps_ > 0 && skewBps_ < 10_000 && skewBps_ >= minSkew_ && skewBps_ <= maxSkew_
            && lowerSpan >= spacing && (uint256(width_) - lowerSpan) >= spacing;

        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        p.width = width_;
        p.skewBps = skewBps_;
        p.minSkewBps = minSkew_;
        p.maxSkewBps = maxSkew_;

        if (ok) {
            LeveragedAerodromeCLStrategy s = _init(p);
            assertEq(s.layout().skewBps, skewBps_, "init accepted the pair and persisted the skew");
            assertEq(s.layout().width, width_, "...and the width");
            _forceState(s, BaseStrategy.State.Executed);
            vm.prank(proposer);
            s.rerange(width_, skewBps_, 0, 0); // the SAME pair clears the rerange gate
        } else {
            _expectInitRevert(p, LeveragedAerodromeCLStrategy.OutOfBounds.selector);
            // The mirror clone must carry the SAME band, or `rerange` is measured against other bounds.
            LeveragedAerodromeCLStrategy.InitParams memory q = _baseParams();
            q.minSkewBps = minSkew_;
            q.maxSkewBps = maxSkew_;
            LeveragedAerodromeCLStrategy s = _init(q); // valid genesis, then the bad pair
            _forceState(s, BaseStrategy.State.Executed);
            vm.prank(proposer);
            vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
            s.rerange(width_, skewBps_, 0, 0);
        }
    }

    /// @dev THE FREE-PACKING CLAIM, MACHINE-CHECKED: `skewBps` + its band went into the packed tail's spare
    ///      bytes (20 -> 26 used), so `hedgedDebtA`/`hedgedDebtB` keep their slot AND offset — get that wrong
    ///      and every live clone's hedge basis reads garbage. Checked by `vm.load` decode plus a sentinel.
    function testLayoutTailPacksSkewWithoutMovingTheHedgedDebts() public {
        LeveragedAerodromeCLStrategy.InitParams memory p = _baseParams();
        // Distinctive aligned in-band values, so a decode at the wrong offset cannot pass on zeros.
        p.width = 1300;
        p.maxWidth = 12_700;
        p.skewBps = 3500;
        p.minSkewBps = 2000;
        p.maxSkewBps = 8000;
        LeveragedAerodromeCLStrategy s = _init(p);

        uint256 tailSlot = uint256(STORAGE_SLOT) + TAIL_SLOT_OFFSET;
        uint256 tail = uint256(vm.load(address(s), bytes32(tailSlot)));

        assertEq(uint256(uint8(tail)), 8, "cbBTCDecimals at byte 0");
        assertEq(uint256(uint8(tail >> 8)), 18, "wethDecimals at byte 1");
        assertEq(uint256(uint8(tail >> 16)), 0, "wethIsToken0 at byte 2 (leg A is token1 here)");
        assertEq(uint256(uint8(tail >> 24)), 1, "wethDeliversNative at byte 3");
        assertEq(int256(int24(uint24(tail >> 32))), int256(LEG_B_SWAP_SPACING), "cbBTCSwapTickSpacing at byte 4");
        assertEq(int256(int24(uint24(tail >> 56))), int256(LEG_A_SWAP_SPACING), "wethSwapTickSpacing at byte 7");
        assertEq(uint256(uint24(tail >> 80)), 1300, "width at byte 10");
        assertEq(uint256(uint24(tail >> 104)), 200, "minWidth at byte 13");
        assertEq(uint256(uint24(tail >> 128)), 12_700, "maxWidth at byte 16");
        assertEq(uint256(uint8(tail >> 152)), 0, "legBIsAsset at byte 19 (two-borrowed-legs here)");
        assertEq(uint256(uint16(tail >> 160)), 3500, "skewBps FREE-PACKS at byte 20 -- the tail still fits");
        assertEq(uint256(uint16(tail >> 176)), 2000, "minSkewBps FREE-PACKS at byte 22");
        assertEq(uint256(uint16(tail >> 192)), 8000, "maxSkewBps FREE-PACKS at byte 24 -- 26 of 32 bytes used");
        assertEq(tail >> 208, 0, "bytes 26..31 of the tail slot are still SPARE");

        // The decode above must agree with the public view, or it is reading the wrong slot entirely.
        LeveragedAerodromeCLStrategy.LayoutView memory v = s.layout();
        assertEq(v.width, 1300, "layout() agrees on width");
        assertEq(v.skewBps, 3500, "layout() agrees on skewBps");
        assertEq(v.minSkewBps, 2000, "layout() agrees on minSkewBps");
        assertEq(v.maxSkewBps, 8000, "layout() agrees on maxSkewBps");

        // ...so `hedgedDebtA` / `hedgedDebtB` are still the LOW / HIGH halves of the NEXT slot.
        vm.store(address(s), bytes32(tailSlot + 1), bytes32((uint256(7) << 128) | uint256(3)));
        (uint128 legAHedged, uint128 legBHedged) = s.hedgedDebt();
        assertEq(uint256(legAHedged), 3, "hedgedDebtA is STILL slot+1 offset 0 (low 16 bytes)");
        assertEq(uint256(legBHedged), 7, "hedgedDebtB is STILL slot+1 offset 16 (high 16 bytes)");
    }

    // ==================== COMPOUND FEE-CRYSTALLISE ROUTING ====================
    //
    // `compound` runs against a FLAT book here: `nav()` reads its `tokenId == 0` branch (face value
    // of idle USDC, no oracle) and `compoundImpl` returns immediately on the same condition. That
    // leaves the fee crystallise — the part under test — as the only thing that executes, so the
    // routing can be exercised without Slipstream/Moonwell venues.

    /// @dev Force the lifecycle state without running `_execute()` / `_settle()` (both of which need
    ///      live Slipstream + Moonwell venues). `_state` shares slot 1 with `_proposer` (offset 0)
    ///      and `_initialized` (offset 21), so the byte at offset 20 is rewritten in place and the
    ///      neighbours are preserved.
    function _forceState(LeveragedAerodromeCLStrategy s, BaseStrategy.State st) internal {
        uint256 slot1 = uint256(vm.load(address(s), bytes32(uint256(1))));
        slot1 = (slot1 & ~(uint256(0xff) << 160)) | (uint256(st) << 160);
        vm.store(address(s), bytes32(uint256(1)), bytes32(slot1));
        assertEq(uint256(s.state()), uint256(st), "forced state");
    }

    /// @dev Leave `s` (which must be BOUND) Executed with `shares` of supply, `idleUsdc`, and `dt` elapsed.
    function _armForCompound(LeveragedAerodromeCLStrategy s, uint256 shares, uint256 idleUsdc, uint256 dt) internal {
        vm.prank(owner);
        vault.setOpenDeposits(true);

        vm.prank(address(s));
        vault.strategyMint(lp, shares);

        usdc.mint(address(s), idleUsdc);
        _forceState(s, BaseStrategy.State.Executed);
        vm.warp(block.timestamp + dt);
    }

    /**
     * @dev A `compound` WITH NOTHING TO HARVEST MUST HAVE NO SIDE EFFECTS. `compound` is a
     *      keeper-polled entrypoint, and crystallisation is not free: it mints fee-shares, accrues the
     *      protocol slice and ratchets the HWM. This fixture is the maximally-armed no-op — a flat book
     *      (`tokenId == 0`), shares outstanding, a 1%/yr management fee and 30 days of `dt` — so the
     *      management leg alone WOULD mint if the entrypoint crystallised before checking. It must not:
     *      the genuine-no-op probe in `compound` runs ahead of every state write.
     *
     *      (The counterpart positive controls — a REAL harvest crystallising, and a real harvest
     *      DEFERRING the fee when share issuance is shut — need a live position and the AERO→USDC venue,
     *      so they live in `LeveragedAeroCompoundHedge.unit.t.sol`, which etches the Aerodrome-v2 router
     *      and drives the whole claim → swap → re-hedge → redeploy sequence.)
     */
    function testCompoundOnAFlatBookIsATrueNoOp() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());
        _armForCompound(s, 1_000e12, 1_000e6, 30 days);
        assertEq(s.layout().tokenId, 0, "flat book");

        uint256 lastAccrualBefore = s.layout().lastFeeAccrualTimestamp;
        uint256 idleBefore = usdc.balanceOf(address(s));

        vm.recordLogs();
        vm.prank(proposer);
        s.compound(1, 0);

        assertEq(vault.totalSupply(), 1_000e12, "no fee-shares minted");
        assertEq(vault.balanceOf(feeRecipient), 0, "fee recipient untouched");
        assertEq(s.layout().lastFeeAccrualTimestamp, lastAccrualBefore, "fee clock NOT advanced");
        assertEq(s.layout().hwmPerShare, 0, "HWM NOT ratcheted");
        assertEq(usdc.balanceOf(address(s)), idleBefore, "idle USDC byte-identical");
        assertEq(gauge.getRewardCallCount(), 0, "the gauge was never even touched");

        // Not a deferral either — there was simply nothing to crystallise.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != FeeCrystallizeDeferred.selector, "a no-op defers nothing");
        }
    }

    /// @dev The same no-op holds with share issuance SHUT: nothing is minted, nothing is deferred, and
    ///      the call does not revert. (With a live book the fee genuinely defers — see the H3 test in
    ///      `LeveragedAeroCompoundHedge.unit.t.sol`.)
    function testCompoundOnAFlatBookIsANoOpEvenWithIssuanceClosed() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());
        _armForCompound(s, 1_000e12, 1_000e6, 30 days);

        uint256 lastAccrualBefore = s.layout().lastFeeAccrualTimestamp;
        vm.prank(owner);
        vault.setOpenDeposits(false);

        vm.prank(proposer);
        s.compound(1, 0);

        assertEq(vault.totalSupply(), 1_000e12, "no fee-shares minted");
        assertEq(s.layout().lastFeeAccrualTimestamp, lastAccrualBefore, "accrual clock unmoved");
        assertEq(s.layout().hwmPerShare, 0, "HWM unmoved");
    }

    function testCompoundRevertsForNonProposer() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());
        _armForCompound(s, 1_000e12, 1_000e6, 30 days);

        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        s.compound(1, 0);
    }

    function testCompoundRevertsBeforeExecute() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        s.compound(1, 0);
    }

    // ==================== RESCUE-TO-VAULT DENY LIST ====================

    /**
     * @dev The VAULT SHARE token is not rescuable. This strategy custodies live shares
     *      (`requestRedeem` escrows, and the shares pulled mid-`redeem`) — they are depositor claims,
     *      not strays. Sweeping them to the vault would put them behind the vault's owner-only
     *      `rescueERC20`, so the pair `rescueToVault(vault) -> vault.rescueERC20(vault, attacker)`
     *      would exfiltrate every escrowed claim. (The vault refuses its own shares too — belt and
     *      braces on both sides.)
     */
    function testRescueToVaultRefusesTheShareToken() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.CannotRescuePositionToken.selector);
        s.rescueToVault(address(vault));

        // Same answer after settlement.
        _forceState(s, BaseStrategy.State.Settled);
        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.CannotRescuePositionToken.selector);
        s.rescueToVault(address(vault));
    }

    /// @dev Every position / accounting token stays denied in ALL states.
    function testRescueToVaultRefusesPositionTokens() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());

        address[6] memory denied =
            [address(usdc), address(legB), address(legA), address(mUsdc), address(mLegB), address(mLegA)];
        for (uint256 i; i < denied.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(LeveragedAerodromeCLStrategy.CannotRescuePositionToken.selector);
            s.rescueToVault(denied[i]);
        }
    }

    /// @dev While Executed the gauge reward token is denied — a sweep would bypass `compound()`,
    ///      which is the only path that prices the AERO -> USDC leg against its oracle floor.
    function testRescueToVaultRefusesRewardTokenWhileExecuted() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());
        _forceState(s, BaseStrategy.State.Executed);

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.CannotRescuePositionToken.selector);
        s.rescueToVault(address(aero));
    }

    /**
     * @dev ...but once Settled it must be sweepable, or it is stranded forever: the settle unwind's
     *      `gauge.withdraw` auto-claims a final AERO tranche that `settleImpl` never sells (it sweeps
     *      only the two legs), and `compound` — the usual outlet — reverts `NotExecuted` from then on.
     *      Post-settle it is a genuine stray, so it goes to the vault where the owner's non-asset
     *      `rescueERC20` can recover it.
     */
    function testRescueToVaultAllowsRewardTokenOnceSettled() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());

        aero.mint(address(s), 7e18); // the settle-claimed tranche
        _forceState(s, BaseStrategy.State.Settled);

        vm.prank(owner);
        s.rescueToVault(address(aero));

        assertEq(aero.balanceOf(address(s)), 0, "strategy swept");
        assertEq(aero.balanceOf(address(vault)), 7e18, "landed on the vault");

        // And onward: the vault's owner-only rescue accepts it (non-asset, not the share token).
        vm.prank(owner);
        vault.rescueERC20(address(aero), lp, 7e18);
        assertEq(aero.balanceOf(lp), 7e18, "recovered");
    }

    function testRescueToVaultRejectsStrangers() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());

        vm.prank(lp);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        s.rescueToVault(address(aero));
    }

    /// @dev `rescueToVault` is now ADMIN-ONLY: moving tokens out is custody, which the keeper key lacks.
    function testRescueToVaultIsAdminOnlyAndRejectsTheProposer() public {
        LeveragedAerodromeCLStrategy s = _initBound(_baseParams());
        aero.mint(address(s), 3e18);
        _forceState(s, BaseStrategy.State.Settled); // post-settle AERO is a genuine stray

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        s.rescueToVault(address(aero));
        assertEq(aero.balanceOf(address(s)), 3e18, "the proposer's sweep changed nothing");

        // The admin can.
        vm.prank(owner);
        s.rescueToVault(address(aero));
        assertEq(aero.balanceOf(address(vault)), 3e18, "the admin's sweep landed on the vault");
    }

    // ==================== setTargetLtv (ADMIN-ONLY POLICY) ====================

    /// @dev The admin writes the standing target; both getters read it and the event carries (prev, new).
    function testSetTargetLtvPersistsAndEmits() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        assertEq(s.targetLtvBps(), 5000, "the init target is the starting standing target");

        vm.expectEmit(true, true, true, true, address(s));
        emit TargetLtvUpdated(5000, 6200);
        vm.prank(owner);
        s.setTargetLtv(6200);

        assertEq(s.targetLtvBps(), 6200, "the new standing target persisted");
        assertEq(s.layout().targetLtvBps, 6200, "getter == layout()");
    }

    /// @dev THE POINT OF THE SPLIT: a compromised keeper (or stranger) cannot move the target itself.
    function testSetTargetLtvRevertsForProposerAndStrangers() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        s.setTargetLtv(6000);

        vm.prank(lp);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        s.setTargetLtv(6000);

        assertEq(s.targetLtvBps(), 5000, "a refused caller stores nothing");
    }

    /// @dev Zero is refused and stores nothing: it would strip the position and leave `$.tokenId` unstaked.
    function testSetTargetLtvRevertsOnZero() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvZero.selector);
        s.setTargetLtv(0);

        assertEq(s.targetLtvBps(), 5000, "the zero target stored nothing");
    }

    /// @dev The upper bound is `maxLtvBps`, inclusive; one bps past it is refused and stores nothing.
    function testSetTargetLtvRevertsAboveMaxLtv() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvExceedsMax.selector);
        s.setTargetLtv(6501);
        assertEq(s.targetLtvBps(), 5000, "a rejected target stores nothing");

        vm.prank(owner);
        s.setTargetLtv(6500); // the bound is inclusive
        assertEq(s.targetLtvBps(), 6500, "maxLtvBps itself is a legal target");
    }

    /// @dev NOT state-gated: correcting an init-time target before the fund is funded is the sharpest case.
    function testSetTargetLtvIsAllowedWhilePending() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        assertEq(uint8(s.state()), uint8(BaseStrategy.State.Pending), "fixture is Pending");

        vm.prank(owner);
        s.setTargetLtv(4000);
        assertEq(s.targetLtvBps(), 4000, "the target is settable before execute");
    }

    // ==================== setMaxLtv (ADMIN-ONLY OPERATIONAL CEILING) ====================
    // Fixture band: target 5000, max 6500, minHealth 12000, live CF 8800.

    /// @dev The admin writes the ceiling; `layout()` reads it back and the event carries (prev, new).
    function testSetMaxLtvPersistsAndEmits() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        assertEq(s.layout().maxLtvBps, 6500, "the init ceiling is the starting one");
        assertEq(uint8(s.state()), uint8(BaseStrategy.State.Pending), "and NOT state-gated, like setTargetLtv");

        vm.expectEmit(true, true, true, true, address(s));
        emit MaxLtvUpdated(6500, 7000);
        vm.prank(owner);
        s.setMaxLtv(7000);

        assertEq(s.layout().maxLtvBps, 7000, "the new ceiling persisted");
        assertEq(s.targetLtvBps(), 5000, "the standing target is untouched: this knob is the belt, not policy");
    }

    /// @dev THE ROLES SPLIT: the keeper key may de-lever all day but must not raise the fund's risk.
    function testSetMaxLtvRevertsForProposerAndStrangers() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        s.setMaxLtv(7000);

        vm.prank(lp);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        s.setMaxLtv(7000);

        assertEq(s.layout().maxLtvBps, 6500, "a refused caller stores nothing");
    }

    /// @dev Rung 1, the band from BELOW — the same error `setTargetLtv` raises from the other side.
    function testSetMaxLtvRevertsBelowTheStandingTarget() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvExceedsMax.selector);
        s.setMaxLtv(4999); // targetLtvBps == 5000
        assertEq(s.layout().maxLtvBps, 6500, "a rejected ceiling stores nothing");

        vm.prank(owner);
        s.setMaxLtv(5000); // the bound is inclusive, exactly as it is in setTargetLtv
        assertEq(s.layout().maxLtvBps, 5000, "the target itself is a legal ceiling");
    }

    /// @dev Rung 3: STRICTLY below the collateral factor, or the op ceiling IS the liquidation line.
    function testSetMaxLtvRevertsAtOrAboveTheCollateralFactor() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.MaxLtvExceedsCF.selector);
        s.setMaxLtv(8800); // CF is 8800 bps — equality is already refused

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.MaxLtvExceedsCF.selector);
        s.setMaxLtv(9000);

        assertEq(s.layout().maxLtvBps, 6500, "neither attempt stored");
    }

    /// @dev Rung 4, ANTI-GRIEF: `deleverage()` triggers at `1e8 / minHealthBps` — 8333.3 bps here — which
    ///      must stay strictly ABOVE the ceiling or an in-band range is grief-deleverageable.
    function testSetMaxLtvRevertsOnTheMinHealthConflictRung() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.MinHealthMaxLtvConflict.selector);
        s.setMaxLtv(8334); // 12000 * 8334 == 1.00008e8 >= 1e8
        assertEq(s.layout().maxLtvBps, 6500, "the conflicting ceiling stored nothing");

        vm.prank(owner);
        s.setMaxLtv(8333); // 12000 * 8333 == 9.9996e7 — the last legal bps below the trigger
        assertEq(s.layout().maxLtvBps, 8333, "one bps below the conflict is accepted");
    }

    /// @dev WHY THE CF IS READ AT CALL TIME: the same argument, both sides of a governance CF move.
    function testSetMaxLtvReadsTheCollateralFactorLive() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        assertEq(s.layout().usdcCollateralFactorBps, 8800, "init snapshot");

        comptroller.setCollateralFactorMantissa(0.75e18); // Moonwell governance tightens USDC to 75%
        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.MaxLtvExceedsCF.selector);
        s.setMaxLtv(8000); // legal against the 8800 SNAPSHOT, illegal against the 7500 LIVE factor
        assertEq(s.layout().maxLtvBps, 6500, "nothing stored");

        comptroller.setCollateralFactorMantissa(0.88e18); // ...and back
        vm.prank(owner);
        s.setMaxLtv(8000);
        assertEq(s.layout().maxLtvBps, 8000, "the SAME argument now clears the SAME rung");
    }

    /// @dev Lowering tightens the OTHER setter immediately — hence the ordering when ratcheting down.
    function testSetMaxLtvLoweringTightensSetTargetLtv() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(owner);
        s.setMaxLtv(5500);

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvExceedsMax.selector);
        s.setTargetLtv(5501);

        vm.prank(owner);
        s.setTargetLtv(5500); // the new ceiling is reachable, nothing above it is
        assertEq(s.targetLtvBps(), 5500, "policy can meet the lowered ceiling");
    }

    // ==================== setWidthBounds (ADMIN-ONLY RERANGE BAND) ====================
    // Fixture: tickSpacing 100, width 4000, skew 5000, band [200, 20000], skew band [1, 9999].

    /// @dev The admin writes the band; the skew band and the live width are left alone.
    function testSetWidthBoundsPersistsAndEmits() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.expectEmit(true, true, true, true, address(s));
        emit WidthBoundsUpdated(200, 20_000, 400, 8000);
        vm.prank(owner);
        s.setWidthBounds(400, 8000);

        assertEq(s.layout().minWidth, 400, "the new lower bound persisted");
        assertEq(s.layout().maxWidth, 8000, "...and the upper");
        assertEq(s.layout().width, 4000, "the LIVE width is untouched: moving it is the proposer's rerange");
        assertEq(s.layout().minSkewBps, 1, "the skew band stays init-frozen");
        assertEq(s.layout().maxSkewBps, 9999, "...both ends of it");
    }

    /// @dev THE ROLES SPLIT: an operator that can set its own bounds has none.
    function testSetWidthBoundsRevertsForProposerAndStrangers() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        s.setWidthBounds(400, 8000);

        vm.prank(lp);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotAdmin.selector);
        s.setWidthBounds(400, 8000);

        assertEq(s.layout().minWidth, 200, "a refused caller stores nothing");
        assertEq(s.layout().maxWidth, 20_000, "...at either end");
    }

    /// @dev `checkBands` rung 1: BOTH bounds on the tickSpacing grid.
    function testSetWidthBoundsRevertsOnOffGridBounds() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.setWidthBounds(250, 8000); // 250 % 100 != 0

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.setWidthBounds(400, 8050); // 8050 % 100 != 0

        assertEq(s.layout().minWidth, 200, "neither attempt stored");
    }

    /// @dev `checkBands` rung 2: `minWidth >= 2 x tickSpacing`, so an aligned range is never empty.
    function testSetWidthBoundsRevertsWhenMinWidthIsUnderTwoSpacings() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.setWidthBounds(100, 8000); // on-grid, but one spacing — half the floor

        vm.prank(owner);
        s.setWidthBounds(200, 8000); // exactly 2 x spacing is the floor, inclusive
        assertEq(s.layout().minWidth, 200, "the floor itself is legal");
    }

    /// @dev `checkBands` rung 3: an inverted band admits nothing (and `checkRange` catches it too).
    function testSetWidthBoundsRevertsOnAnInvertedBand() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.setWidthBounds(8000, 400);

        assertEq(s.layout().maxWidth, 20_000, "nothing stored");
    }

    /// @dev `checkBands` rung 4: `maxWidth` inside the tick domain. Both probes are on the grid so rung 1
    ///      stays quiet — `MAX_BAND_WIDTH` is itself off-grid at spacing 100, hence the aligned value.
    function testSetWidthBoundsRevertsAboveTheTickDomain() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        uint24 alignedCeiling = (MAX_BAND_WIDTH / 100) * 100; // 1_774_500

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.setWidthBounds(400, alignedCeiling + 100); // one spacing past the domain

        vm.prank(owner);
        s.setWidthBounds(400, alignedCeiling); // the widest aligned band the domain admits
        assertEq(s.layout().maxWidth, alignedCeiling, "the domain edge is admissible");
    }

    /// @dev THE CONTAINMENT RULE: `redeploy` / `rerange` size from the STORED width, so a band excluding it
    ///      from either end is refused.
    function testSetWidthBoundsRefusesABandExcludingTheStoredWidth() public {
        LeveragedAerodromeCLStrategy s = _init(_baseParams());
        assertEq(s.layout().width, 4000, "the stored width the band must admit");

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.setWidthBounds(4100, 8000); // floor above the live width

        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.OutOfBounds.selector);
        s.setWidthBounds(400, 3900); // ceiling below it

        assertEq(s.layout().minWidth, 200, "neither attempt stored");
        assertEq(s.layout().maxWidth, 20_000, "...at either end");

        vm.prank(owner);
        s.setWidthBounds(4000, 4000); // the degenerate band that admits exactly the live width
        assertEq(s.layout().minWidth, 4000, "a band pinned to the live width is legal");
    }
}
