// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";
import {MockCLGauge} from "./mocks/MockCLGauge.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {StdStorage, Test, stdStorage} from "@forge-std/Test.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// MockPositionManagerV2 — full position lifecycle for rebalanceUsingAlt() tests.
// Ported from V1 (LPAutoBalancerRebalanceTest). Models a two-phase collect:
//   slot 0 (skimFees) → fees; slot 1 (decreaseAll) → principal. Auto-advances.
// NOTE: V2 has NO swap router, so the "no swap" property is structural — rebalanceUsingAlt()
// rebuilds the position purely from the principal this mock pays out on collect.
// ─────────────────────────────────────────────────────────────────────────────
contract MockPositionManagerV2 {
    using SafeERC20 for IERC20;

    address public mockOwner;

    // approve
    address public lastApprovedTo;
    uint256 public lastApprovedTokenId;
    uint256 public approveCallCount;

    // safeTransferFrom
    address public lastFrom;
    address public lastTo;
    uint256 public lastTransferTokenId;
    uint256 public transferCallCount;

    // burn
    uint256 public lastBurnedTokenId;
    uint256 public burnCallCount;
    mapping(uint256 => bool) public wasBurned;

    // decreaseLiquidity
    uint256 public lastDecreaseTokenId;
    uint256 public decreaseCallCount;

    // collect
    uint256 public lastCollectTokenId;
    address public lastCollectRecipient;
    uint256 public collectCallCount;

    // mint
    uint256 public lastMintedTokenId;
    uint256 public mintCallCount;
    bool public pullOnMint;
    // tick range of the most recent mint (used to assert which side the alt was placed on).
    int24 public lastMintTickLower;
    int24 public lastMintTickUpper;

    struct PositionData {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address token0;
        address token1;
        int24 tickSpacing;
    }

    mapping(uint256 => PositionData) internal _positions;

    address public collectToken0;
    address public collectToken1;
    uint256[2] public collectAmounts0;
    uint256[2] public collectAmounts1;

    uint256 public nextMintTokenId;
    uint128 public nextMintLiquidity;

    // Second staged mint result (alt). When set, the 2nd mint() call returns these
    // and any further call falls back to the main result. Lets rebalanceUsingAlt() mint main then alt.
    uint256 public nextAltMintTokenId;
    uint128 public nextAltMintLiquidity;
    bool public hasAltMintResult;

    constructor(address owner_) {
        mockOwner = owner_;
    }

    function setMockOwner(address owner_) external {
        mockOwner = owner_;
    }

    function setPosition(uint256 tokenId, int24 tl, int24 tu, uint128 liq, address t0, address t1) external {
        // Default tickSpacing to 200 (the unit-test pool's spacing) so registerPosition's
        // NFT-to-pool binding check passes for all existing 6-arg callers.
        _positions[tokenId] =
            PositionData({tickLower: tl, tickUpper: tu, liquidity: liq, token0: t0, token1: t1, tickSpacing: 200});
    }

    /// @notice Overload that sets an explicit tickSpacing (to drive registerPosition's
    ///         NFT-to-pool binding check, including the mismatch case).
    function setPosition(uint256 tokenId, int24 tl, int24 tu, uint128 liq, address t0, address t1, int24 ts) external {
        _positions[tokenId] =
            PositionData({tickLower: tl, tickUpper: tu, liquidity: liq, token0: t0, token1: t1, tickSpacing: ts});
    }

    function setCollectTokens(address t0, address t1) external {
        collectToken0 = t0;
        collectToken1 = t1;
    }

    function setCollectAmounts(uint8 slot, uint256 a0, uint256 a1) external {
        collectAmounts0[slot] = a0;
        collectAmounts1[slot] = a1;
    }

    function setCollectSequence(uint256 fee0, uint256 fee1, uint256 princ0, uint256 princ1) external {
        collectAmounts0[0] = fee0;
        collectAmounts1[0] = fee1;
        collectAmounts0[1] = princ0;
        collectAmounts1[1] = princ1;
    }

    function setPullOnMint(bool v) external {
        pullOnMint = v;
    }

    function setNextMintResult(uint256 newTokenId, uint128 liq) external {
        nextMintTokenId = newTokenId;
        nextMintLiquidity = liq;
    }

    /// @notice Stage the SECOND mint result (alt). With this set, the first mint() returns the
    ///         main result and the second returns this alt result (subsequent calls reuse main).
    function setNextAltMintResult(uint256 altTokenId, uint128 liq) external {
        nextAltMintTokenId = altTokenId;
        nextAltMintLiquidity = liq;
        hasAltMintResult = true;
    }

    function ownerOf(uint256) external view returns (address) {
        return mockOwner;
    }

    function approve(address to, uint256 tokenId) external {
        lastApprovedTo = to;
        lastApprovedTokenId = tokenId;
        approveCallCount++;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        lastFrom = from;
        lastTo = to;
        lastTransferTokenId = tokenId;
        transferCallCount++;
    }

    function burn(uint256 tokenId) external {
        lastBurnedTokenId = tokenId;
        burnCallCount++;
        wasBurned[tokenId] = true;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        PositionData storage pd = _positions[tokenId];
        // Index 4 carries tickSpacing on Aerodrome Slipstream (the interface labels it `fee`).
        return (
            0,
            address(0),
            pd.token0,
            pd.token1,
            uint24(pd.tickSpacing),
            pd.tickLower,
            pd.tickUpper,
            pd.liquidity,
            0,
            0,
            0,
            0
        );
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        lastDecreaseTokenId = params.tokenId;
        decreaseCallCount++;
        // Enforce the deadline exactly like the real position manager (so the threaded deadline,
        // F8, is exercised): revert if the block time is past the supplied deadline.
        require(block.timestamp <= params.deadline, "Transaction too old");
        // Model the principal returned by the decrease as the staged "principal" collect
        // amounts (slot 1). Enforce the caller-supplied sandwich floor exactly like the real
        // position manager: revert if the withdrawn amount is below the requested minimum.
        amount0 = collectAmounts0[1];
        amount1 = collectAmounts1[1];
        require(amount0 >= params.amount0Min, "Price slippage check");
        require(amount1 >= params.amount1Min, "Price slippage check");
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        lastCollectTokenId = params.tokenId;
        lastCollectRecipient = params.recipient;

        uint256 slot = collectCallCount < 2 ? collectCallCount : 1;
        collectCallCount++;

        amount0 = collectAmounts0[slot];
        amount1 = collectAmounts1[slot];

        if (amount0 > 0 && collectToken0 != address(0)) {
            IERC20(collectToken0).safeTransfer(params.recipient, amount0);
        }
        if (amount1 > 0 && collectToken1 != address(0)) {
            IERC20(collectToken1).safeTransfer(params.recipient, amount1);
        }
    }

    function mint(ICLPositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        mintCallCount++;
        // 1st mint => main result; 2nd mint => alt result (if staged); else fall back to main.
        if (mintCallCount == 2 && hasAltMintResult) {
            tokenId = nextAltMintTokenId;
            liquidity = nextAltMintLiquidity;
        } else {
            tokenId = nextMintTokenId;
            liquidity = nextMintLiquidity;
        }
        lastMintedTokenId = tokenId;
        lastMintTickLower = params.tickLower;
        lastMintTickUpper = params.tickUpper;
        if (pullOnMint) {
            // Model a price-1 in-ratio mint: consume min(desired0, desired1) of BOTH tokens.
            // The balanced main mint then leaves only the genuine surplus leg behind, which the
            // single-sided alt mint (called next) parks. Matches how the real PM consumes only the
            // in-ratio portion and returns the remainder to the caller.
            uint256 consume =
                params.amount0Desired < params.amount1Desired ? params.amount0Desired : params.amount1Desired;
            if (consume > 0) {
                IERC20(params.token0).safeTransferFrom(msg.sender, address(this), consume);
                IERC20(params.token1).safeTransferFrom(msg.sender, address(this), consume);
            }
        }
        return (tokenId, liquidity, 0, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockCLPoolV2 — configurable slot0 + observe
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// MockERC20Decimals — ERC20 with a configurable decimals() (default OZ MockERC20 is
// fixed at 18). Used to model the real phase-1 pair: cbBTC (8-dec) / WETH (18-dec),
// so the value-based leg selection and USD dust threshold can be exercised.
// ─────────────────────────────────────────────────────────────────────────────
contract MockERC20Decimals is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCLPoolV2 is ICLPool {
    uint160 public sqrtPX96;
    int24 public currentTick;
    int56 public tickCumulative0;
    int56 public tickCumulative1;

    // Configurable pool descriptor so registerPosition's pool cross-validation (token0/token1/
    // tickSpacing must match the config) can pass — and be made to FAIL in a dedicated test.
    address private _token0;
    address private _token1;
    int24 private _tickSpacing = 200;

    function setSlot0(uint160 sqrtP, int24 tick) external {
        sqrtPX96 = sqrtP;
        currentTick = tick;
    }

    function setObserve(int56 cum0, int56 cum1) external {
        tickCumulative0 = cum0;
        tickCumulative1 = cum1;
    }

    function setTokens(address t0, address t1) external {
        _token0 = t0;
        _token1 = t1;
    }

    function setTickSpacing(int24 ts) external {
        _tickSpacing = ts;
    }

    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool unlocked) {
        return (sqrtPX96, currentTick, 0, 0, 0, true);
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulative0;
        tickCumulatives[1] = tickCumulative1;
        secondsPerLiquidityCumulativeX128 = new uint160[](2);
    }

    function token0() external view returns (address) {
        return _token0;
    }

    function token1() external view returns (address) {
        return _token1;
    }

    function tickSpacing() external view returns (int24) {
        return _tickSpacing;
    }

    function liquidity() external pure returns (uint128) {
        return 0;
    }
}

contract LPAutoBalancerV2UnitTest is Test {
    using stdStorage for StdStorage;

    LPAutoBalancerV2 lab;
    MockPositionManagerV2 mockPM;
    MockCLPoolV2 mockPool;
    MockERC20 mockAero;
    MockCLGauge mockGauge;
    MockERC20 tok0;
    MockERC20 tok1;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");

    // Live mock contracts backing the config (real pool/tokens so rebalanceUsingAlt() can run).
    address pool; // address(mockPool)
    address token0; // address(tok0)
    address token1; // address(tok1)
    address gauge; // set in setUp to address(mockGauge)
    address feeCollector = makeAddr("feeCollector");
    address oracle0; // set in setUp to a MockPriceFeed (registerPosition probes feeds)
    address oracle1;

    uint256 constant TOKEN_ID = 42;
    uint256 constant NEW_TOKEN_ID = 43;
    uint256 constant ALT_TOKEN_ID = 44;

    // Tick geometry (tickSpacing=200, width=400): twapTick=0, spotTick=100 →
    //   _alignedRange(0,400,200,100): tickLower=floorAlign(-200,200)=-200, tickUpper=200; 100∈(-200,200) ✓
    int24 constant SPOT_TICK = 100;
    int24 constant OLD_TL = -200;
    int24 constant OLD_TU = 200;
    uint128 constant OLD_LIQ = 1e18;
    uint128 constant NEW_LIQ = 1e18;
    // sqrtPriceX96 at tick=0 (price = 1.0): 2^96
    uint160 constant SQRT_P = 79_228_162_514_264_337_593_543_950_336;

    function setUp() public {
        // Real ERC20 pair tokens so SafeERC20 transfers (collect/dust/mint) work.
        tok0 = new MockERC20("Token0", "TK0");
        tok1 = new MockERC20("Token1", "TK1");
        token0 = address(tok0);
        token1 = address(tok1);

        // Deploy mock AERO token (real ERC20 so SafeERC20 transfers work)
        mockAero = new MockERC20("Aerodrome", "AERO");

        // Deploy mock gauge backed by mockAero
        mockGauge = new MockCLGauge(address(mockAero));
        gauge = address(mockGauge);

        // Configurable pool mock (slot0 + observe) for rebalanceUsingAlt() geometry.
        mockPool = new MockCLPoolV2();
        pool = address(mockPool);
        // registerPosition cross-validates the pool descriptor: token0/token1/tickSpacing must match.
        mockPool.setTokens(token0, token1);
        mockPool.setTickSpacing(200);

        // Rich PM mock with full position lifecycle (positions/decrease/collect/mint/burn).
        mockPM = new MockPositionManagerV2(address(0));

        // Real mock feeds: registerPosition probes latestRoundData at set-time
        oracle0 = address(new MockPriceFeed(1e8, 8, block.timestamp));
        oracle1 = address(new MockPriceFeed(1e8, 8, block.timestamp));

        // V2 constructor: no swapRouter, no quoter
        lab = new LPAutoBalancerV2(admin, manager, rebalancer, guardian, address(mockPM), address(mockAero));

        // Now that lab is deployed, point mockPM owner to lab so ownerOf checks pass
        mockPM.setMockOwner(address(lab));

        // Pool geometry: spotTick=100, sqrtP at tick=0; twapTick=0 (observe cumulatives 0,0).
        mockPool.setSlot0(SQRT_P, SPOT_TICK);
        mockPool.setObserve(0, 0);

        // OLD (main) position + NEW mint result, both same range so the value floor is met.
        mockPM.setPosition(TOKEN_ID, OLD_TL, OLD_TU, OLD_LIQ, token0, token1);
        mockPM.setNextMintResult(NEW_TOKEN_ID, NEW_LIQ);
        mockPM.setPosition(NEW_TOKEN_ID, OLD_TL, OLD_TU, NEW_LIQ, token0, token1);
        // Alt range sits one tickSpacing ABOVE main upper ([200,400]); at spot tick 0 it holds
        // only token0, so _altValue counts the surplus token0 minted into it. Stored so the
        // value-floor read after the alt mint sees a non-zero alt principal.
        mockPM.setPosition(ALT_TOKEN_ID, OLD_TU, OLD_TU + 200, NEW_LIQ, token0, token1);
        mockPM.setCollectTokens(token0, token1);
        // Model real PM behavior: mint consumes the in-ratio (price-1) portion of contract balances,
        // leaving only a genuine surplus leg behind. Without this the mock would leave the full
        // balanced principal on the contract and spuriously mint an alt from it.
        mockPM.setPullOnMint(true);
    }

    // ─── helper ─────────────────────────────────────────────────────────────

    /// @dev Build the default ManagedPositionV2 config.
    ///      withGauge=true sets gauge field; false leaves it address(0).
    function _defaultConfig(bool withGauge) internal view returns (LPAutoBalancerV2.ManagedPositionV2 memory) {
        return LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: withGauge ? gauge : address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 400,
            maxWidth: 2000,
            // center of [-200,200] = 0, twapTick=0 → dev=0 ≤ 400 ✓
            maxCenterDeviation: 400,
            twapWindow: 1800,
            // spotTick=100, twapTick=0 → |diff|=100 ≤ 200 ✓
            maxTickDeviation: 200,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 0, // no cooldown so rebalanceUsingAlt() can run immediately
            lastRebalance: 999, // should be forced to 0 by _store
            active: false // should be forced to true by _store
        });
    }

    /// @dev Register a position using the default config.
    function _register(bool withGauge) internal {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(withGauge);
        vm.prank(admin);
        lab.registerPosition(cfg);
    }

    // ─── rebalanceUsingAlt() helpers ───────────────────────────────────────────────────────

    /// @dev Default rebalanceUsingAlt params: width 400, all mins 0, deadline now+1.
    function _defaultRebalanceParams() internal view returns (LPAutoBalancerV2.RebalanceParams memory) {
        return LPAutoBalancerV2.RebalanceParams({
            width: 400,
            amount0MinMain: 0,
            amount1MinMain: 0,
            amount0MinAlt: 0,
            amount1MinAlt: 0,
            amount0MinWithdraw: 0,
            amount1MinWithdraw: 0,
            amount0MinWithdrawAlt: 0,
            amount1MinWithdrawAlt: 0,
            deadline: block.timestamp + 1
        });
    }

    /// @dev Stage the PM so decreaseLiquidity+collect returns p0/p1 as withdrawn principal
    ///      (0 fees on the first collect). Mints tokens into the PM so collect transfers succeed.
    function _stagePrincipal(uint256 p0, uint256 p1) internal {
        tok0.mint(address(mockPM), p0);
        tok1.mint(address(mockPM), p1);
        // slot 0 (skimFees): 0 fees; slot 1 (decreaseAll principal): p0/p1
        mockPM.setCollectSequence(0, 0, p0, p1);
    }

    // ─── constructor tests ───────────────────────────────────────────────────

    function test_rolesGranted() public view {
        assertTrue(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(lab.hasRole(lab.MANAGER_ROLE(), manager));
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), rebalancer));
        assertTrue(lab.hasRole(lab.GUARDIAN_ROLE(), guardian));
    }

    function test_immutablesWired() public view {
        assertEq(address(lab.POSITION_MANAGER()), address(mockPM));
        assertEq(lab.AERO(), address(mockAero));
        assertEq(lab.maxOracleDelay(), 26 hours);
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        new LPAutoBalancerV2(address(0), manager, rebalancer, guardian, address(mockPM), address(mockAero));
    }

    function test_constructorRejectsZeroPositionManager() public {
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        new LPAutoBalancerV2(admin, manager, rebalancer, guardian, address(0), address(mockAero));
    }

    function test_constructorRejectsZeroAero() public {
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        new LPAutoBalancerV2(admin, manager, rebalancer, guardian, address(mockPM), address(0));
    }

    // ─── smoke test ──────────────────────────────────────────────────────────

    function test_deploys_and_registers() public {
        _register(false);

        // ManagedPositionV2 public getter tuple — 21 fields in declaration order:
        // mainTokenId, altTokenId, pool, token0, token1, tickSpacing,
        // gauge, mainStaked, altStaked, feeCollector, oracle0, oracle1,
        // minWidth, maxWidth, maxCenterDeviation, twapWindow, maxTickDeviation,
        // maxRebalanceLossBps, minRebalanceInterval, lastRebalance, active
        (
            uint256 storedMainTokenId,
            uint256 storedAltTokenId,
            address storedPool,,,
            int24 storedTickSpacing,,
            bool storedMainStaked,
            bool storedAltStaked,,,,,,,,,,,
            uint256 storedLastRebalance,
            bool storedActive
        ) = lab.position();

        assertEq(storedMainTokenId, TOKEN_ID); // registered tokenId
        assertEq(storedAltTokenId, 0); // forced to 0 by _store
        assertEq(storedPool, pool);
        assertEq(storedTickSpacing, 200);
        assertFalse(storedMainStaked); // forced false
        assertFalse(storedAltStaked); // forced false
        assertEq(storedLastRebalance, 0); // forced 0 by _store
        assertTrue(storedActive); // forced true by _store
    }

    // ─── registerPosition validation ─────────────────────────────────────────

    function test_registerPosition_revertsWhenAlreadyActive() public {
        _register(false); // first registration succeeds
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.AlreadyRegistered.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertNonAdmin() public {
        address caller = makeAddr("nonAdmin");
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 400,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 100,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 3600,
            lastRebalance: 0,
            active: false
        });
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertLossCap() public {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 400,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 100,
            maxRebalanceLossBps: 501, // exceeds MAX_LOSS_CAP_BPS=500
            minRebalanceInterval: 3600,
            lastRebalance: 0,
            active: false
        });
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.LossCapExceeded.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertNotHeld() public {
        mockPM.setMockOwner(makeAddr("someoneElse"));
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 400,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 100,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 3600,
            lastRebalance: 0,
            active: false
        });
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.NotHeld.selector);
        lab.registerPosition(cfg);
    }

    // ─── no swapPolicy / no slippage cap ─────────────────────────────────────

    function test_noSwapPolicyField() public {
        // Verify struct has no swapPolicy: compile-time check via _register succeeding
        // and no runtime revert for any "slippage cap exceeded" path
        _register(false);
        (,,,,,,,,,,,,,,,,,,,, bool active) = lab.position();
        assertTrue(active); // just confirm it registered
    }

    // ─── rebalanceUsingAlt() — Task 2: rebuild balanced main, no swap ────────────────────────

    function test_rebalanceUsingAlt_rebuildsMain_fromWithdrawnBalances() public {
        _register(false);
        _stagePrincipal(1e18, 1e18); // PM returns this principal on decrease+collect

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        // position active, main tokenId updated to the freshly minted NFT, alt cleared
        (uint256 mainTokenId, uint256 altTokenId,,,,,,,,,,,,,,,,,,, bool active) = lab.position();
        assertEq(mainTokenId, NEW_TOKEN_ID, "mainTokenId updated to new NFT");
        assertEq(altTokenId, 0, "alt cleared (Task 3 adds it)");
        assertTrue(active, "position stays active");

        // No-swap property is structural: the new position was rebuilt purely from the
        // withdrawn principal (mint consumed contract-held tokens; nothing was sold).
        // Old NFT burned exactly once.
        assertEq(mockPM.burnCallCount(), 1, "old main burned");
        assertEq(mockPM.lastBurnedTokenId(), TOKEN_ID, "wrong burned token");

        // Balanced principal => ~0 leftover, forwarded to feeCollector (no dust stranded).
        assertEq(tok0.balanceOf(address(lab)), 0, "no token0 dust");
        assertEq(tok1.balanceOf(address(lab)), 0, "no token1 dust");

        // lastRebalance stamped to the current block.
        (,,,,,,,,,,,,,,,,,,, uint256 lastRebalance,) = lab.position();
        assertEq(lastRebalance, block.timestamp, "lastRebalance stamped");
    }

    /// @dev Settled CowSwap compound proceeds arrive as loose token0+token1 on the contract.
    ///      rebalanceUsingAlt() mints from balanceOf(this), so the loose proceeds fold into the new main with
    ///      no extra code. Prove the loose balance is consumed by the mint (not left idle).
    function test_rebalanceUsingAlt_foldsLooseCompoundProceeds_bothLegs() public {
        _register(false);
        _stagePrincipal(1e18, 1e18); // PM returns this principal on decrease+collect during rebalanceUsingAlt

        // The new main absorbs both the withdrawn principal AND the loose proceeds, so it holds
        // MORE liquidity than the old position. Model that: stage the fresh NFT at 2x liquidity so
        // the post-rebalanceUsingAlt value floor (1% max loss) reflects the folded-in proceeds.
        mockPM.setNextMintResult(NEW_TOKEN_ID, NEW_LIQ * 2);
        mockPM.setPosition(NEW_TOKEN_ID, OLD_TL, OLD_TU, NEW_LIQ * 2, token0, token1);

        // Simulate settled compound proceeds: drop loose token0 AND token1 onto the contract.
        // Kept small vs the principal valuation so the 1% value floor has headroom.
        tok0.mint(address(lab), 1e12);
        tok1.mint(address(lab), 1e12);
        uint256 looseBefore = tok0.balanceOf(address(lab)) + tok1.balanceOf(address(lab));
        assertGt(looseBefore, 0, "loose proceeds staged");

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        // The loose proceeds (plus withdrawn principal) were pulled into the fresh main mint.
        uint256 looseAfter = tok0.balanceOf(address(lab)) + tok1.balanceOf(address(lab));
        assertLt(looseAfter, looseBefore, "loose compound proceeds folded into main");
    }

    // ─── rebalanceUsingAlt() — withdraw-min sandwich guard (HIGH defect fix) ─────────────────

    /// @dev The caller's amount{0,1}MinWithdraw must be forwarded to the MAIN decrease so the
    ///      position manager reverts when the withdrawn principal falls below the floor.
    ///      Staged principal is 1e18/1e18; a withdraw-min ABOVE that must revert rebalanceUsingAlt().
    function test_rebalanceUsingAlt_revertsWhenWithdrawMinUnmet() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancerV2.RebalanceParams memory params = _defaultRebalanceParams();
        params.amount0MinWithdraw = 1e18 + 1; // floor exceeds the staged decrease return

        vm.prank(rebalancer);
        vm.expectRevert("Price slippage check");
        lab.rebalanceUsingAlt(params);
    }

    /// @dev Mirror of the above: a withdraw-min AT or BELOW the staged return passes the floor
    ///      and rebalanceUsingAlt() succeeds, proving the wiring does not over-reject.
    function test_rebalanceUsingAlt_succeedsWhenWithdrawMinMet() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancerV2.RebalanceParams memory params = _defaultRebalanceParams();
        params.amount0MinWithdraw = 1e18; // exactly the staged return
        params.amount1MinWithdraw = 1e18;

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(params);

        (uint256 mainTokenId,,,,,,,,,,,,,,,,,,,,) = lab.position();
        assertEq(mainTokenId, NEW_TOKEN_ID, "rebalanceUsingAlt completed with withdraw mins met");
    }

    // ─── rebalanceUsingAlt() — Task 3: single-sided alt mint from leftover ───────────────────

    /// @dev Read (mainTokenId, altTokenId, mainStaked) from the position() getter.
    function _readMainAlt() internal view returns (uint256 main, uint256 alt, bool mainStaked) {
        (main, alt,,,,,, mainStaked,,,,,,,,,,,,,) = lab.position();
    }

    /// @dev Read (mainStaked, altStaked) from the position() getter.
    function _readStakeFlags() internal view returns (bool mainStaked, bool altStaked) {
        (,,,,,,, mainStaked, altStaked,,,,,,,,,,,,) = lab.position();
    }

    function test_rebalanceUsingAlt_mintsAltFromLeftover() public {
        _register(false);
        _stagePrincipal(3e18, 1e18); // imbalanced => surplus token0
        mockPM.setNextMintResult(NEW_TOKEN_ID, 1e18); // main
        mockPM.setNextAltMintResult(ALT_TOKEN_ID, 5e17); // alt (single-sided from leftover)
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
        (, uint256 altId,) = _readMainAlt();
        assertEq(altId, ALT_TOKEN_ID, "alt minted from leftover");
    }

    function test_rebalanceUsingAlt_skipsAltWhenLeftoverDust() public {
        _register(false);
        _stagePrincipal(1e18, 1e18); // balanced => ~no leftover
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
        (, uint256 altId,) = _readMainAlt();
        assertEq(altId, 0, "no alt when leftover is dust");
    }

    /// @dev FIX 8 dust-forward coverage. The mock uses pullOnMint=true (in-ratio consumption:
    ///      mint consumes min(desired0, desired1) of both tokens, leaving only the genuine surplus
    ///      leg). Stage a minimally-imbalanced principal so the surplus after the main mint is a
    ///      single wei — far below MIN_ALT_VALUE_USD ($0.01) — and verify:
    ///        1. No alt is minted (surplus sub-threshold).
    ///        2. Contract holds ~0 loose after rebalanceUsingAlt (surplus forwarded, not stranded).
    ///        3. The 1-wei surplus landed on feeCollector (not destroyed, not on contract).
    ///      This exercises the sub-threshold dust-forward path end-to-end with the in-ratio mock.
    function test_rebalanceUsingAlt_subThresholdSurplus_forwardedToFeeCollector() public {
        _register(false);
        // Stage p0 = 1e18 + 1, p1 = 1e18. pullOnMint=true: main mint consumes min(1e18+1, 1e18)
        // = 1e18 of each token, leaving 1 wei of tok0 as a one-sided surplus.
        // At oracle price $1/unit (18-dec), 1 wei = $1e-18 << MIN_ALT_VALUE_USD ($0.01) → no alt.
        _stagePrincipal(1e18 + 1, 1e18);

        uint256 feeCollBefore = tok0.balanceOf(feeCollector);

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        // No alt minted: surplus is sub-threshold.
        (, uint256 altId,) = _readMainAlt();
        assertEq(altId, 0, "no alt: surplus below MIN_ALT_VALUE_USD");

        // Contract holds no loose tokens after rebalanceUsingAlt (dust was forwarded, not stranded).
        assertEq(tok0.balanceOf(address(lab)), 0, "no tok0 dust stranded on contract");
        assertEq(tok1.balanceOf(address(lab)), 0, "no tok1 dust stranded on contract");

        // The 1-wei surplus reached feeCollector.
        assertEq(tok0.balanceOf(feeCollector) - feeCollBefore, 1, "1-wei surplus forwarded to feeCollector");
    }

    function test_rebalanceUsingAlt_imbalanced_valueFloorCountsAlt() public {
        // The surplus minted into the alt must be counted in valueAfter, so an
        // imbalanced withdrawal does NOT spuriously trip ValueFloor.
        _register(false);
        _stagePrincipal(3e18, 1e18);
        mockPM.setNextMintResult(NEW_TOKEN_ID, 1e18);
        mockPM.setNextAltMintResult(ALT_TOKEN_ID, 5e17);
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams()); // must NOT revert ValueFloor
        // both main and alt set; no large dust forwarded as "loss"
        (uint256 mainId, uint256 altId,) = _readMainAlt();
        assertEq(mainId, NEW_TOKEN_ID, "main set");
        assertEq(altId, ALT_TOKEN_ID, "alt set");
    }

    function test_rebalanceUsingAlt_restakesMain_whenStaked() public {
        _register(true); // gauged
        vm.prank(rebalancer);
        lab.stake();
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
        (bool mainStaked,) = _readStakeFlags();
        assertTrue(mainStaked, "main restaked after rebalanceUsingAlt"); // covers the wasStaked branch
    }

    /// @dev Review fix #3: when a staked position is rebalanced and a NEW alt is minted, the alt must be
    ///      staked alongside the restaked main. Otherwise it is stranded — stake() and collectFees()
    ///      both revert AlreadyStaked once the main is staked, so the alt's emissions/fees could never
    ///      be collected until the next rebalanceUsingAlt.
    function test_rebalanceUsingAlt_restakesAlt_whenStakedAndAltMinted() public {
        _register(true); // gauged
        vm.prank(rebalancer);
        lab.stake();
        _stagePrincipal(3e18, 1e18); // imbalanced => surplus token0 => alt minted
        mockPM.setNextMintResult(NEW_TOKEN_ID, 1e18); // main
        mockPM.setNextAltMintResult(ALT_TOKEN_ID, 5e17); // alt
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        (uint256 mainId, uint256 altId,) = _readMainAlt();
        assertEq(mainId, NEW_TOKEN_ID, "main rebuilt");
        assertEq(altId, ALT_TOKEN_ID, "alt minted");
        (bool mainStaked, bool altStaked) = _readStakeFlags();
        assertTrue(mainStaked, "main restaked after rebalanceUsingAlt");
        assertTrue(altStaked, "alt also staked after rebalanceUsingAlt (not stranded)");
    }

    /// @dev Review fix #2: registerPosition must reject an NFT whose own tickSpacing disagrees with
    ///      the config, EVEN when the live pool descriptor matches. The descriptor check alone does
    ///      not bind the NFT to the pool; the NFT's positions() tickSpacing must also match.
    function test_registerPosition_revertNftPoolMismatch_tickSpacing() public {
        // Descriptor matches (pool says 200, config says 200) but the NFT itself reports spacing 100.
        mockPM.setPosition(TOKEN_ID, OLD_TL, OLD_TU, OLD_LIQ, token0, token1, int24(100));
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _baseConfig(); // tickSpacing 200
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.PoolMismatch.selector);
        lab.registerPosition(cfg);
    }

    /// @dev Review fix #2: registerPosition must reject an NFT whose own token0 disagrees with the
    ///      config, even when the live pool descriptor matches.
    function test_registerPosition_revertNftPoolMismatch_token() public {
        // Descriptor matches, but the NFT was minted against a different token0.
        mockPM.setPosition(TOKEN_ID, OLD_TL, OLD_TU, OLD_LIQ, makeAddr("wrongNftToken0"), token1, int24(200));
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _baseConfig();
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.PoolMismatch.selector);
        lab.registerPosition(cfg);
    }

    // ─── rebalanceUsingAlt() — Task 3 HIGH fix: value-based leg selection + USD dust + floor-counts-loose ──
    //
    // These tests model the REAL phase-1 pair: token0 = cbBTC-like (8-dec, high $/unit) and
    // token1 = WETH-like (18-dec, lower $/unit). Dedicated tokens/pool/PM/oracles are spun up so
    // the shared price-1 fixtures (and the tests above) are untouched.

    MockERC20Decimals dtok0; // cbBTC-like, 8 decimals
    MockERC20Decimals dtok1; // WETH-like, 18 decimals
    MockPositionManagerV2 dPM;
    MockCLPoolV2 dPool;
    LPAutoBalancerV2 dLab;
    address dOracle0; // cbBTC/USD: $65,000 (8-dec)
    address dOracle1; // WETH/USD:  $2,500  (8-dec)

    uint256 constant D_MAIN_ID = 100;
    uint256 constant D_NEW_ID = 101;
    uint256 constant D_ALT_ID = 102;

    /// @dev Spin up an independent mixed-decimal fixture (cbBTC/WETH) and register a position on a
    ///      fresh balancer instance. pullOnMint=false: the main mint consumes nothing, so the
    ///      loose contract balances at _mintAlt time equal exactly the staged principal — giving
    ///      the test direct control over each leg's raw amount (and therefore its USD value).
    function _setupMixed(uint256 lossBps) internal {
        dtok0 = new MockERC20Decimals("cbBTC", "cbBTC", 8);
        dtok1 = new MockERC20Decimals("WETH", "WETH", 18);
        dPM = new MockPositionManagerV2(address(0));
        dPool = new MockCLPoolV2();
        // $65,000 cbBTC and $2,500 WETH, both 8-decimal feeds (Chainlink convention).
        dOracle0 = address(new MockPriceFeed(65_000e8, 8, block.timestamp));
        dOracle1 = address(new MockPriceFeed(2_500e8, 8, block.timestamp));

        dLab = new LPAutoBalancerV2(admin, manager, rebalancer, guardian, address(dPM), address(mockAero));
        dPM.setMockOwner(address(dLab));

        dPool.setSlot0(SQRT_P, SPOT_TICK); // spot tick 100, twap 0 (same geometry as shared fixture)
        dPool.setObserve(0, 0);
        // Pool cross-validation: descriptor must match the live pool.
        dPool.setTokens(address(dtok0), address(dtok1));
        dPool.setTickSpacing(200);

        // OLD main: small liquidity so valueBefore is modest and the floor is easy to clear.
        dPM.setPosition(D_MAIN_ID, OLD_TL, OLD_TU, 1e12, address(dtok0), address(dtok1));
        dPM.setNextMintResult(D_NEW_ID, 1e12);
        dPM.setPosition(D_NEW_ID, OLD_TL, OLD_TU, 1e12, address(dtok0), address(dtok1));
        // alt parked one spacing ABOVE main upper: [200,400]; at spot it holds only token0 (cbBTC).
        dPM.setPosition(D_ALT_ID, OLD_TU, OLD_TU + 200, 1e12, address(dtok0), address(dtok1));
        dPM.setNextAltMintResult(D_ALT_ID, 1e12);
        dPM.setCollectTokens(address(dtok0), address(dtok1));
        dPM.setPullOnMint(false); // loose balances at alt time == staged principal exactly

        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: D_MAIN_ID,
            altTokenId: 0,
            pool: address(dPool),
            token0: address(dtok0),
            token1: address(dtok1),
            tickSpacing: 200,
            gauge: address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: dOracle0,
            oracle1: dOracle1,
            minWidth: 400,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 200,
            maxRebalanceLossBps: uint16(lossBps),
            minRebalanceInterval: 0,
            lastRebalance: 999,
            active: false
        });
        vm.prank(admin);
        dLab.registerPosition(cfg);
    }

    /// @dev Stage the mixed-fixture PM to pay out p0/p1 principal on decrease+collect (0 fees).
    function _stageMixedPrincipal(uint256 p0, uint256 p1) internal {
        dtok0.mint(address(dPM), p0);
        dtok1.mint(address(dPM), p1);
        dPM.setCollectSequence(0, 0, p0, p1);
    }

    /// @dev Read (mainTokenId, altTokenId, mainStaked) from the mixed-fixture balancer.
    function _readMixedMainAlt() internal view returns (uint256 main, uint256 alt, bool mainStaked) {
        (main, alt,,,,,, mainStaked,,,,,,,,,,,,,) = dLab.position();
    }

    /// @dev DEFECT 1+2: the surplus leg must be chosen by USD VALUE, not raw base units, and the
    ///      mint/skip decision must use a USD threshold. Stage raw bal0 < bal1 (1e5 cbBTC units vs
    ///      1e16 WETH units) but value0 ($65) > value1 ($25). The alt must be minted on the token0
    ///      (cbBTC) side — the range ABOVE the main upper [200,400] — proving value-based selection.
    ///      The OLD raw-unit code (`surplus0 = bal0 >= bal1` → 1e5 >= 1e16 → false) would have placed
    ///      the alt on the token1 side (range BELOW), so the tick assertions discriminate the fix.
    function test_mintAlt_selectsSurplusByValue_notRawUnits() public {
        _setupMixed(500);
        // token0 (cbBTC): 1e5 raw = 0.001 cbBTC ≈ $65 (65e8 USD)
        // token1 (WETH):  1e16 raw = 0.01 WETH   ≈ $25 (25e8 USD)
        // raw bal0 (1e5) < bal1 (1e16), but value0 ($65) > value1 ($25).
        _stageMixedPrincipal(1e5, 1e16);

        vm.prank(rebalancer);
        dLab.rebalanceUsingAlt(_defaultRebalanceParams());

        (uint256 mainId, uint256 altId,) = _readMixedMainAlt();
        assertEq(mainId, D_NEW_ID, "main rebuilt");
        assertEq(altId, D_ALT_ID, "alt minted (surplus value above USD threshold)");
        // token0-surplus => range ABOVE main upper: [mainTu, mainTu + tickSpacing] = [200, 400].
        // (OLD raw code would have chosen token1-surplus => range BELOW: [mainTl - spacing, mainTl].)
        assertEq(dPM.lastMintTickLower(), OLD_TU, "alt on token0 side: lower == mainTu");
        assertEq(dPM.lastMintTickUpper(), OLD_TU + 200, "alt on token0 side: upper == mainTu + spacing");
    }

    /// @dev DEFECT 3 (the floor bypass). The value floor must count LOOSE contract balances. We stage
    ///      a position whose value is overwhelmingly the loose surplus leg (real principal the alt
    ///      does NOT capture), and a fresh main that holds almost nothing.
    ///
    ///      OLD code: `_mintAlt` forwards the loose surplus to the feeCollector BEFORE the floor, and
    ///      the floor reads only the position NFTs. valueAfter = new main (≈0) << floor → the OLD code
    ///      would REVERT here EXCEPT it already shipped the principal out as "dust" — i.e. the only way
    ///      a real surplus survives the floor under OLD code is by being dusted out first, which is the
    ///      leak. (Verified empirically: an old-ordering build forwards the full surplus to feeCollector.)
    ///
    ///      NEW code: the loose surplus is counted by `_contractPairValue` at floor time, so the floor
    ///      sees the FULL value (new main + loose surplus). The position did not actually lose value —
    ///      it was merely rebuilt imbalanced — so the floor correctly PASSES, and only the genuine
    ///      remainder is forwarded AFTER the check. This proves the floor can no longer be bypassed by
    ///      routing principal out as dust: the value is on the books when the floor runs.
    ///
    ///      The discriminator vs OLD: if the floor did NOT count loose (OLD ordering), valueAfter would
    ///      be ≈0 against a large valueBefore → ValueFloor revert. Counting loose is what lets the
    ///      legitimate (no-loss) imbalanced rebuild pass — and simultaneously closes the leak.
    function test_rebalanceUsingAlt_forwardedDustCannotBypassValueFloor() public {
        _setupMixed(100); // tight 1% loss cap

        // New main holds ~nothing; the alt captures nothing. The entire withdrawn principal comes
        // back as a token0 surplus that stays LOOSE (pullOnMint=false → mint pulls no tokens).
        dPM.setNextMintResult(D_NEW_ID, 0);
        dPM.setPosition(D_NEW_ID, OLD_TL, OLD_TU, 0, address(dtok0), address(dtok1));
        dPM.setPosition(D_ALT_ID, OLD_TU, OLD_TU + 200, 0, address(dtok0), address(dtok1)); // alt holds nothing

        // Withdrawn principal = a big token0 surplus (1e10 raw cbBTC = 100 cbBTC ≈ $6.5M), all loose
        // after the (empty) mints — comfortably above valueBefore so the no-loss rebuild clears the floor.
        _stageMixedPrincipal(1e10, 0);

        vm.prank(rebalancer);
        dLab.rebalanceUsingAlt(_defaultRebalanceParams());

        // NEW: floor counted the loose surplus → no spurious revert → rebalanceUsingAlt succeeded.
        // (OLD ordering would have to forward that surplus out before the floor — the leak — for the
        // call to survive at all, since the NFTs alone are worth ≈0 here.)
        (uint256 mainId,,) = _readMixedMainAlt();
        assertEq(mainId, D_NEW_ID, "rebalanceUsingAlt succeeded: loose surplus counted by the value floor");
    }

    /// @dev Counterpart proving the floor still trips on a GENUINE loss (value actually destroyed,
    ///      not merely retained loose). New main and alt both hold ~nothing and only 1 dust unit of
    ///      token0 is loose, so valueAfter collapses far below valueBefore minus the 1% cap.
    function test_rebalanceUsingAlt_valueFloorStillTripsOnRealLoss() public {
        _setupMixed(100); // 1% loss cap

        dPM.setPosition(D_ALT_ID, OLD_TU, OLD_TU + 200, 0, address(dtok0), address(dtok1)); // alt holds nothing
        dPM.setNextMintResult(D_NEW_ID, 0); // new main holds ~nothing
        dPM.setPosition(D_NEW_ID, OLD_TL, OLD_TU, 0, address(dtok0), address(dtok1));
        _stageMixedPrincipal(1, 0); // 1 raw cbBTC unit ≈ $0.00065 loose: far below the floor

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.ValueFloor.selector);
        dLab.rebalanceUsingAlt(_defaultRebalanceParams());
    }

    /// @dev H-1 (accounting asymmetry). A loose token0/token1 balance ALREADY on the contract before
    ///      rebalanceUsingAlt (donated via a plain ERC20 transfer, or leftover from a prior reverted flow) must be
    ///      counted in BOTH valueBefore and valueAfter, so it cancels and cannot create headroom that
    ///      masks a real position loss.
    ///
    ///      Stage: new main + alt hold ~nothing, withdrawn principal = 1 dust unit. The position
    ///      round-trip destroys essentially all value (same skeleton as the real-loss test above, which
    ///      reverts with NO donation). Then DONATE a large token0 balance to the contract before rebalanceUsingAlt.
    ///
    ///      OLD asymmetric code: valueBefore = positions only (large old main), valueAfter = positions
    ///      (≈0) + loose (donation + 1 dust). With the donation sized >= valueBefore, valueAfter clears
    ///      the floor → rebalanceUsingAlt PASSES → the donation silently absorbed the entire position loss. That is
    ///      the bug.
    ///      NEW symmetric code: the donation is in valueBefore too, so it cancels; valueAfter_position
    ///      (≈0) << valueBefore_position → rebalanceUsingAlt REVERTS ValueFloor. This assertion proves H-1 is closed.
    function test_rebalanceUsingAlt_donatedBalanceCannotMaskLoss() public {
        _setupMixed(100); // 1% loss cap

        // New main + alt both hold ~nothing; withdrawn principal is 1 dust unit (same skeleton as
        // test_rebalanceUsingAlt_valueFloorStillTripsOnRealLoss, which reverts with no donation).
        dPM.setNextMintResult(D_NEW_ID, 0);
        dPM.setPosition(D_NEW_ID, OLD_TL, OLD_TU, 0, address(dtok0), address(dtok1));
        dPM.setPosition(D_ALT_ID, OLD_TU, OLD_TU + 200, 0, address(dtok0), address(dtok1));
        _stageMixedPrincipal(1, 0);

        // DONATE a large cbBTC balance directly to the contract BEFORE rebalanceUsingAlt (1e10 raw = 100 cbBTC ≈
        // $6.5M, vastly larger than the old main's principal value). Under OLD code this donation would
        // sit only in valueAfter and clear the floor; under NEW code it is netted out of both sides.
        dtok0.mint(address(dLab), 1e10);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.ValueFloor.selector);
        dLab.rebalanceUsingAlt(_defaultRebalanceParams());
    }

    /// @dev M-2. setGauge must reject when EITHER leg is staked. If a partial unstake ever leaves
    ///      mainStaked=false but altStaked=true, the alt NFT is still custodied by the OLD gauge;
    ///      changing the gauge would strand it. We reach mainStaked=false, altStaked=true (a state the
    ///      public API never produces directly): stake() sets BOTH true, then we clear ONLY the
    ///      mainStaked bit in the packed storage word with vm.store. The OLD guard (mainStaked only)
    ///      would have let setGauge through here; the NEW guard (mainStaked || altStaked) reverts.
    function test_setGauge_revertsWhenAltStaked() public {
        _registerWithAlt(true); // gauge set + altTokenId injected
        vm.prank(rebalancer);
        lab.stake(); // sets mainStaked=true AND altStaked=true

        // Locate the storage word packing (gauge | mainStaked | altStaked) and clear only mainStaked,
        // leaving altStaked set. Scan the struct words of position for the one whose decoded
        // (mainStaked, altStaked) round-trips through the getter, then flip the mainStaked bit.
        bytes32 base = bytes32(_positionBaseSlot());
        bool flipped = false;
        for (uint256 w = 0; w < 24 && !flipped; w++) {
            bytes32 slot = bytes32(uint256(base) + w);
            bytes32 word = vm.load(address(lab), slot);
            // Try clearing the mainStaked bit at each byte offset where gauge (20 bytes) ends.
            // gauge occupies offset 0..19; mainStaked is the byte at offset 20, altStaked at 21.
            uint256 mainBit = uint256(20) * 8;
            uint256 altBit = uint256(21) * 8;
            bool mainSet = (uint256(word) >> mainBit) & 0xff == 1;
            bool altSet = (uint256(word) >> altBit) & 0xff == 1;
            if (mainSet && altSet) {
                // clear mainStaked byte, keep altStaked
                uint256 cleared = uint256(word) & ~(uint256(0xff) << mainBit);
                vm.store(address(lab), slot, bytes32(cleared));
                flipped = true;
            }
        }
        assertTrue(flipped, "located packed staked flags");

        (bool mainStaked, bool altStaked) = _readStakeFlags();
        assertFalse(mainStaked, "main cleared (precondition)");
        assertTrue(altStaked, "alt still staked (precondition)");

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.PositionStaked.selector);
        lab.setGauge(makeAddr("newGauge"));
    }

    /// @dev Recover the absolute base slot of the `position` storage variable (layout-robust).
    ///      stdstore.find() returns the absolute slot of position.mainTokenId directly.
    function _positionBaseSlot() internal returns (uint256) {
        return stdstore.target(address(lab)).sig("position()").depth(0).find();
    }

    // ─── Task 4: stake/unstake/claimEmissions (dual-NFT) + exit() ────────────────

    /// @dev Register a gauged (or gaugeless) position and inject a non-zero altTokenId directly
    ///      into contract storage using stdstore. This bypasses the _store() forced-zero for
    ///      altTokenId so tests can exercise the alt staking paths without running rebalanceUsingAlt().
    function _registerWithAlt(bool withGauge) internal {
        _register(withGauge);
        // Also register ALT_TOKEN_ID with the mock PM so ownerOf returns this contract's address.
        // (mockPM.ownerOf always returns mockOwner, so no extra setup needed.)
        // Inject altTokenId = ALT_TOKEN_ID into position.altTokenId via stdstore.
        stdstore.target(address(lab)).sig("position()").depth(1) // altTokenId is field index 1
            .checked_write(ALT_TOKEN_ID);
    }

    /// @dev Read active flag from position() getter.
    function _readActive() internal view returns (bool active) {
        (,,,,,,,,,,,,,,,,,,,, active) = lab.position();
    }

    function test_stake_main_altFollows() public {
        _registerWithAlt(true);
        vm.prank(rebalancer);
        lab.stake();
        (bool mainStaked, bool altStaked) = _readStakeFlags();
        assertTrue(mainStaked, "main staked");
        assertTrue(altStaked, "alt follows main");
    }

    function test_unstake_main_altFollows() public {
        _registerWithAlt(true);
        vm.prank(rebalancer);
        lab.stake();
        vm.prank(rebalancer);
        lab.unstake();
        (bool mainStaked, bool altStaked) = _readStakeFlags();
        assertFalse(mainStaked, "main unstaked");
        assertFalse(altStaked, "alt unstaked");
    }

    function test_claimEmissions_sumsBothNfts() public {
        _registerWithAlt(true);
        vm.prank(rebalancer);
        lab.stake();
        // Mint AERO into gauge so getReward() can pay out; set payout per call.
        mockAero.mint(address(mockGauge), 14e18);
        mockGauge.setAeroToPayOnGetReward(7e18); // each getReward call pays 7e18
        uint256 before = mockAero.balanceOf(feeCollector);
        lab.claimEmissions();
        // 2 calls: main (7e18) + alt (7e18) = 14e18 total
        assertGt(mockAero.balanceOf(feeCollector), before, "AERO from both nfts to feeCollector");
        assertEq(mockAero.balanceOf(feeCollector) - before, 14e18, "correct total from both NFTs");
    }

    // ─── compound() — harvest, drop, forward to module ───────────────────────────

    address moduleSink = makeAddr("moduleSink");

    function _setModule() internal {
        vm.prank(admin);
        lab.setCompoundModule(moduleSink);
    }

    function test_token0_token1_getters() public {
        _register(true);
        assertEq(lab.token0(), token0);
        assertEq(lab.token1(), token1);
    }

    function test_setCompoundModule_revertsZero() public {
        _register(true);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        lab.setCompoundModule(address(0));
    }

    function test_setCompoundModule_onlyAdmin() public {
        _register(true);
        vm.prank(rebalancer);
        vm.expectRevert();
        lab.setCompoundModule(moduleSink);
    }

    function test_compound_revertsAboveMaxBps() public {
        _register(true);
        _setModule();
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.CompoundBpsTooHigh.selector);
        lab.compound(10_001);
    }

    function test_compound_revertsNoModule() public {
        _register(true); // module unset
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.ModuleNotSet.selector);
        lab.compound(5_000);
    }

    function test_compound_onlyRebalancer() public {
        _register(true);
        _setModule();
        vm.prank(admin);
        vm.expectRevert();
        lab.compound(5_000);
    }

    function test_compound_dropsAndForwardsToModule() public {
        _register(true);
        _setModule();
        vm.prank(rebalancer);
        lab.stake();
        mockAero.mint(address(mockGauge), 1_000e18);
        mockGauge.setAeroToPayOnGetReward(1_000e18); // 1000 AERO harvested
        uint256 fcBefore = mockAero.balanceOf(feeCollector);

        vm.prank(rebalancer);
        lab.compound(7_000); // 70% compound / 30% drop

        assertEq(mockAero.balanceOf(feeCollector) - fcBefore, 300e18, "30% dropped to feeCollector");
        assertEq(mockAero.balanceOf(moduleSink), 700e18, "70% forwarded to module");
        assertEq(mockAero.balanceOf(address(lab)), 0, "balancer keeps no AERO");
    }

    function test_compound_revertsWhenNothingHarvested() public {
        _register(true);
        _setModule();
        vm.prank(rebalancer);
        lab.stake();
        // aeroToPayOnGetReward defaults 0 => nothing harvested
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NothingToCompound.selector);
        lab.compound(5_000);
    }

    function test_exit_returnsBothTokensToSafe_andDeactivates() public {
        _registerWithAlt(false);
        // MockPositionManagerV2.collect auto-advances: call 0 → slot 0 (fees=0), calls 1+ → slot 1.
        // With a non-zero alt, _exitAll issues 4 collects total:
        //   call 0: skim-main  (slot 0) → 0, 0
        //   call 1: skim-alt   (slot 1) → 2e18/1e18 → feeCollector
        //   call 2: collect-main after decrease (slot 1) → 2e18/1e18 → lab
        //   call 3: collect-alt  after decrease (slot 1) → 2e18/1e18 → lab
        // Slot 1 fires 3 times: mint 3×principal into PM so every collect succeeds.
        tok0.mint(address(mockPM), 6e18);
        tok1.mint(address(mockPM), 3e18);
        mockPM.setCollectSequence(0, 0, 2e18, 1e18);
        vm.prank(admin);
        lab.exit(admin);
        assertEq(mockPM.burnCallCount(), 2, "main + alt burned");
        // Verify the two DISTINCT NFTs that were registered are the ones that got burned,
        // not the same tokenId burned twice.
        assertTrue(mockPM.wasBurned(TOKEN_ID), "main tokenId burned");
        assertTrue(mockPM.wasBurned(ALT_TOKEN_ID), "alt tokenId burned");
        assertGt(tok0.balanceOf(admin), 0, "token0 to Safe");
        assertGt(tok1.balanceOf(admin), 0, "token1 to Safe");
        assertEq(tok0.balanceOf(address(lab)), 0, "no token0 dust");
        assertEq(tok1.balanceOf(address(lab)), 0, "no token1 dust");
        assertFalse(_readActive(), "position deactivated");
    }

    function test_exit_onlyAdmin() public {
        _registerWithAlt(false);
        vm.prank(rebalancer);
        vm.expectRevert();
        lab.exit(rebalancer);
    }

    function test_exit_unstakesAndSkimsAero_whenStaked() public {
        _registerWithAlt(true);
        vm.prank(rebalancer);
        lab.stake();
        // Mint AERO into gauge so withdraw() can auto-claim
        mockAero.mint(address(mockGauge), 8e18);
        mockGauge.setAeroToPayOnWithdraw(4e18); // each withdraw call pays 4e18
        uint256 before = mockAero.balanceOf(feeCollector);
        vm.prank(admin);
        lab.exit(admin);
        assertGt(mockAero.balanceOf(feeCollector), before, "AERO skimmed on exit");
    }

    // ─── Task 5: getDecisionSnapshot ─────────────────────────────────────────────

    function test_getDecisionSnapshotV2_fields() public {
        // _registerWithAlt: main=TOKEN_ID (range [-200,200], liq=OLD_LIQ),
        //                    alt=ALT_TOKEN_ID (range [200,400], liq=NEW_LIQ)
        // Both are set in setUp() via mockPM.setPosition(). Not staked, no gauge (withGauge=false).
        _registerWithAlt(false);
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();

        // spot tick from MockCLPoolV2.slot0(): SPOT_TICK = 100
        assertEq(s.spotTick, SPOT_TICK, "spot");

        // main range [-200, 200]: spotTick=100 ∈ [-200, 200) → in range
        assertTrue(s.mainInRange, "main in range");

        // alt was injected
        assertTrue(s.hasAlt, "alt present");

        // main liquidity from positions(TOKEN_ID): OLD_LIQ
        assertEq(s.mainLiquidity, OLD_LIQ, "main liq");

        // alt liquidity from positions(ALT_TOKEN_ID): NEW_LIQ (set in setUp)
        assertGt(s.altLiquidity, 0, "alt liq");

        // not staked (registered with withGauge=false, stake() never called)
        assertFalse(s.mainStaked, "not staked");

        // deviation gate: spotTick=100, twapTick=0 (cumulatives 0,0), |diff|=100 ≤ maxTickDeviation=200
        assertTrue(s.deviationGateOpen, "calm");
    }

    function test_getDecisionSnapshotV2_earnedAero_tryCatch() public {
        _registerWithAlt(true); // gauged
        vm.prank(rebalancer);
        lab.stake();
        mockGauge.setEarnedAmount(3e18);
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertGt(s.earnedAero, 0, "earned summed over staked nfts");
    }

    function test_getDecisionSnapshotV2_revertsOnInactive() public {
        // No position registered: getDecisionSnapshot() reverts NotActive.
        vm.expectRevert(LPAutoBalancerV2.NotActive.selector);
        lab.getDecisionSnapshot();
    }

    function test_getDecisionSnapshotV2_cooldownAndGate() public {
        // Register with a non-zero cooldown interval, then warp partway through it.
        // After warp, cooldownRemaining should be > 0.
        // Also push spot far from twap to trip the deviation gate.
        _register(false);

        // Set a 1-hour cooldown via setPositionConfig (manager role)
        vm.prank(manager);
        lab.setPositionConfig(
            400, // minWidth (>= 2*tickSpacing)
            2000, // maxWidth
            400, // maxCenterDeviation
            1800, // twapWindow
            200, // maxTickDeviation
            100, // maxRebalanceLossBps
            3600 // minRebalanceInterval = 1 hour
        );

        // Simulate a prior rebalance by warping forward 30 min, then trigger a rebalanceUsingAlt to stamp lastRebalance.
        // Easier: write lastRebalance directly via stdstore (field index 19 in the struct).
        // ManagedPositionV2 field order: 0=mainTokenId, 1=altTokenId, 2=pool, 3=token0, 4=token1,
        // 5=tickSpacing, 6=gauge, 7=mainStaked, 8=altStaked, 9=feeCollector, 10=oracle0, 11=oracle1,
        // 12=minWidth, 13=maxWidth, 14=maxCenterDeviation, 15=twapWindow, 16=maxTickDeviation,
        // 17=maxRebalanceLossBps, 18=minRebalanceInterval, 19=lastRebalance, 20=active
        stdstore.target(address(lab)).sig("position()").depth(19).checked_write(block.timestamp);

        // Warp 30 min: cooldownRemaining should be ~1800 s
        vm.warp(block.timestamp + 1800);

        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertGt(s.cooldownRemaining, 0, "cooldown still running");

        // Push spot far from twap: set spot to twap + maxTickDeviation + 1 = 201 ticks from 0.
        // twapTick = 0 (cumulatives 0,0); set spotTick = 201 > maxTickDeviation=200 → gate closed.
        mockPool.setSlot0(SQRT_P, 201);
        s = lab.getDecisionSnapshot();
        assertFalse(s.deviationGateOpen, "deviation gate closed when spot >> twap");
        assertFalse(s.mainInRange, "spot=201 is outside main range [-200,200)");
    }

    // ─── Task 6: adversarial rebalanceUsingAlt() guards ──────────────────────────────────────

    /// @dev Register a position with a non-zero cooldown interval. `lastRebalance` is forced to 0
    ///      by _store, so callers that need an ACTIVE cooldown must also stamp lastRebalance
    ///      (see test_rebalanceUsingAlt_revertsBeforeCooldown, which writes it via stdstore).
    function _registerWithInterval(uint256 interval) internal {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 400,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 200,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: interval,
            lastRebalance: 0,
            active: false
        });
        vm.prank(admin);
        lab.registerPosition(cfg);
    }

    /// @dev A manipulated spot (far from the TWAP) must trip the deviation gate, blocking rebalanceUsingAlt.
    ///      spotTick=5000 vs twapTick=0 → |dev|=5000 > maxTickDeviation=200 → TwapDeviation.
    function test_rebalanceUsingAlt_revertsOnManipulatedSpot() public {
        _register(false);
        mockPool.setSlot0(SQRT_P, 5000); // far from twap 0 => |dev| > maxTickDeviation
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.TwapDeviation.selector);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
    }

    /// @dev rebalanceUsingAlt must revert while the cooldown is active. Register with a 1h interval and stamp
    ///      lastRebalance = now via stdstore (field index 19), so block.timestamp < lastRebalance +
    ///      interval and the Cooldown guard (checked before the deviation gate) fires.
    function test_rebalanceUsingAlt_revertsBeforeCooldown() public {
        _registerWithInterval(3600);
        // _store forces lastRebalance to 0; stamp it to "now" so the cooldown is genuinely active.
        stdstore.target(address(lab)).sig("position()").depth(19).checked_write(block.timestamp);
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.Cooldown.selector);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
    }

    /// @dev A width below minWidth (or above maxWidth) must trip the width-bounds guard.
    ///      The guard runs after _exitAll, so stage principal so the teardown collect succeeds.
    function test_rebalanceUsingAlt_revertsOnWidthOutOfBounds() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);
        LPAutoBalancerV2.RebalanceParams memory pr = _defaultRebalanceParams();
        pr.width = 1; // below minWidth (200)
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.WidthOutOfBounds.selector);
        lab.rebalanceUsingAlt(pr);
    }

    /// @dev rebalanceUsingAlt is REBALANCER_ROLE-gated: a caller without the role must revert (no prank).
    function test_rebalanceUsingAlt_onlyRebalancer() public {
        _register(false);
        vm.expectRevert(); // caller (this test contract) lacks REBALANCER_ROLE
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
    }

    // ─── _mainRange single-sided geometry (deterministic, no fork) ───────────────
    //
    // These tests verify the token0→above-spot / token1→below-spot decision in _mainRange
    // without relying on a fork. They stage exactly one non-zero leg so the bal0>0&&bal1>0
    // straddle branch is skipped and the single-sided branch runs. The new tokenId's tick
    // range is read back via getDecisionSnapshot() so the assertion is end-to-end.

    /// @dev token0-only principal (bal1 == 0 after decrease): _mainRange must place the main
    ///      strictly ABOVE spot so the position holds only token0 (CL range orientation).
    ///      With spotTick=100, spacing=200: floor=_floorAlign(100,200)=0, up=0+200=200.
    ///      Expected new main: tickLower=200, tickUpper=200+400=600 (width=400).
    ///      Assertion: mainTickLower >= spotTick (range starts at or above spot).
    function test_rebalanceUsingAlt_singleSided_token0_rangeAboveSpot() public {
        _register(false);
        // Stage token0-only: bal0=1e18, bal1=0.
        _stagePrincipal(1e18, 0);

        // Configure the minted main position at the expected above-spot range [200, 600].
        // pullOnMint=true on the shared mockPM; with bal1=0, consume=min(1e18,0)=0 so no pull
        // actually happens — both cases produce the same result with only token0 available.
        mockPM.setPosition(NEW_TOKEN_ID, 200, 600, NEW_LIQ, token0, token1);

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        // The new main must start at or above spot: range strictly above spot holds only token0.
        assertGe(s.mainTickLower, SPOT_TICK, "token0-only: main range must start >= spotTick");
        assertGt(s.mainLiquidity, 0, "token0-only: main must have positive liquidity");
    }

    /// @dev token1-only principal (bal0 == 0 after decrease): _mainRange must place the main
    ///      strictly BELOW spot so the position holds only token1 (CL range orientation).
    ///      With spotTick=100, spacing=200: floor=_floorAlign(100,200)=0 (unaligned → down=floor=0).
    ///      Expected new main: tickUpper=0, tickLower=0-400=-400 (width=400).
    ///      Assertion: mainTickUpper <= spotTick (range ends at or below spot).
    function test_rebalanceUsingAlt_singleSided_token1_rangeBelowSpot() public {
        _register(false);
        // Stage token1-only: bal0=0, bal1=1e18.
        _stagePrincipal(0, 1e18);

        // Configure the minted main position at the expected below-spot range [-400, 0].
        mockPM.setPosition(NEW_TOKEN_ID, -400, 0, NEW_LIQ, token0, token1);

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        // The new main must end at or below spot: range strictly below spot holds only token1.
        assertLe(s.mainTickUpper, SPOT_TICK, "token1-only: main range must end <= spotTick");
        assertGt(s.mainLiquidity, 0, "token1-only: main must have positive liquidity");
    }

    // ─── Review fixes F1/F5/F6: registerPosition validation ──────────────────────

    /// @dev Build a valid base config on the shared fixtures. Tests mutate one field then register.
    function _baseConfig() internal view returns (LPAutoBalancerV2.ManagedPositionV2 memory cfg) {
        cfg = LPAutoBalancerV2.ManagedPositionV2({
            mainTokenId: TOKEN_ID,
            altTokenId: 0,
            pool: pool,
            token0: token0,
            token1: token1,
            tickSpacing: 200,
            gauge: address(0),
            mainStaked: false,
            altStaked: false,
            feeCollector: feeCollector,
            oracle0: oracle0,
            oracle1: oracle1,
            minWidth: 400,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            twapWindow: 1800,
            maxTickDeviation: 200,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 0,
            lastRebalance: 0,
            active: false
        });
    }

    /// @dev F1: minWidth == tickSpacing (one spacing) can never straddle an aligned spot → reverts.
    function test_registerPosition_revertWidthTooNarrow() public {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _baseConfig();
        cfg.minWidth = 200; // == tickSpacing, below the 2*tickSpacing floor
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.WidthTooNarrow.selector);
        lab.registerPosition(cfg);
    }

    /// @dev F1: minWidth == 2*tickSpacing is the smallest accepted width and must succeed.
    function test_registerPosition_acceptsMinWidthTwoSpacings() public {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _baseConfig();
        cfg.minWidth = 400; // == 2*tickSpacing
        vm.prank(admin);
        lab.registerPosition(cfg);
        (,,,,,,,,,,,, uint24 storedMinWidth,,,,,,,,) = lab.position();
        assertEq(storedMinWidth, 400, "minWidth == 2*tickSpacing accepted");
    }

    /// @dev F1: setPositionConfig must enforce the same 2*tickSpacing floor.
    function test_setPositionConfig_revertWidthTooNarrow() public {
        _register(false);
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancerV2.WidthTooNarrow.selector);
        lab.setPositionConfig(200, 2000, 400, 1800, 200, 100, 0); // minWidth == tickSpacing
    }

    /// @dev F5: a gauge whose rewardToken != AERO must be rejected at registration.
    function test_registerPosition_revertGaugeRewardMismatch() public {
        MockCLGauge badGauge = new MockCLGauge(makeAddr("notAero")); // rewardToken != AERO
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _baseConfig();
        cfg.gauge = address(badGauge);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.GaugeRewardMismatch.selector);
        lab.registerPosition(cfg);
    }

    /// @dev F5: setGauge must reject a gauge whose rewardToken != AERO.
    function test_setGauge_revertGaugeRewardMismatch() public {
        _register(false);
        MockCLGauge badGauge = new MockCLGauge(makeAddr("notAero"));
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.GaugeRewardMismatch.selector);
        lab.setGauge(address(badGauge));
    }

    /// @dev F6: a config whose tickSpacing disagrees with the live pool must be rejected.
    function test_registerPosition_revertPoolMismatch_tickSpacing() public {
        mockPool.setTickSpacing(100); // live pool says 100, config says 200
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _baseConfig(); // tickSpacing 200
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.PoolMismatch.selector);
        lab.registerPosition(cfg);
    }

    /// @dev F6: a config whose token0 disagrees with the live pool must be rejected.
    function test_registerPosition_revertPoolMismatch_token() public {
        mockPool.setTokens(makeAddr("wrongToken0"), token1); // live pool token0 != config token0
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _baseConfig();
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.PoolMismatch.selector);
        lab.registerPosition(cfg);
    }

    // ─── Review fix F2: single-leg valuation ignores the unused (stale) feed ─────

    /// @dev F2: valuing a SINGLE leg must not read the other (unused) feed. Stage a fully token0-sided
    ///      rebalanceUsingAlt, then make oracle1 stale. Under the old code _valueInUsd read BOTH feeds
    ///      unconditionally and would revert StaleOracle on the token1 leg even though amount1 == 0.
    ///      With the fix, the zero leg's stale feed is skipped and rebalanceUsingAlt succeeds.
    ///      NOTE: the staleness gate only bites once block.timestamp is realistic, so EVERY valuation
    ///      that touches token1 must have amount1 == 0 — including the OLD main's valueBefore
    ///      principal valuation. The OLD main is therefore placed single-sided ABOVE spot (token0 only)
    ///      too; a straddling OLD main would legitimately hold token1 and reading its (stale) feed
    ///      would NOT be a bug. (This previously passed only off-fork, where block.timestamp == 1
    ///      masks the staleness check.)
    function test_rebalanceUsingAlt_singleLegValuation_ignoresStaleUnusedFeed() public {
        _register(false);
        _stagePrincipal(1e18, 0); // token0-only principal → every _valueInUsd call passes amount1 == 0

        // Make the (unused) token1 feed stale far in the past.
        MockPriceFeed(oracle1).setUpdatedAt(1);

        // OLD main single-sided ABOVE spot (tick 0): valueBefore principal is token0-only, so the
        // stale token1 feed is never read for it either.
        mockPM.setPosition(TOKEN_ID, 200, 600, OLD_LIQ, token0, token1);
        // NEW main also single-sided on the token0 side so the rebuilt mint has liquidity.
        mockPM.setPosition(NEW_TOKEN_ID, 200, 600, NEW_LIQ, token0, token1);

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams()); // must NOT revert StaleOracle

        (uint256 mainId,,) = _readMainAlt();
        assertEq(mainId, NEW_TOKEN_ID, "single-leg valuation skipped the stale unused feed");
    }

    // ─── Review fix F4: dust-minority leg classified single-sided (value threshold) ──

    /// @dev F4: a tiny minority leg (sub-threshold USD value) must NOT force the straddle branch.
    ///      Stage a majority token0 leg and a dust token1 leg worth far below MIN_MAIN_LEG_USD; the
    ///      rebuilt main must be SINGLE-SIDED on the token0 (majority) side — range entirely ABOVE
    ///      spot — not a degenerate straddle. Uses the mixed-decimal fixture so the dust leg's USD
    ///      value is unambiguous. token0 = cbBTC ($65k), token1 = WETH ($2.5k).
    function test_rebalanceUsingAlt_dustMinorityLeg_classifiedSingleSided() public {
        _setupMixed(500);
        // token0: 1e8 raw cbBTC = 1 cbBTC ≈ $65,000 (majority).
        // token1: 1e6 raw WETH = 1e-12 WETH ≈ $0.0000000025 — far below MIN_MAIN_LEG_USD ($0.01).
        _stageMixedPrincipal(1e8, 1e6);

        // Main minted on the token0 side, strictly ABOVE spot ([200,400]); positive liquidity.
        dPM.setPosition(D_NEW_ID, OLD_TU, OLD_TU + 200, 1e12, address(dtok0), address(dtok1));
        dPM.setNextMintResult(D_NEW_ID, 1e12);

        vm.prank(rebalancer);
        dLab.rebalanceUsingAlt(_defaultRebalanceParams());

        // The MAIN mint (1st mint) must be single-sided above spot — lower >= spotTick (100).
        // _mainRange: spotTick=100, spacing=200 → floor=0, up=200 → [200, 600].
        // Discriminator vs straddle: a straddle would center on spot ([-200,200]) with lower < spot.
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = dLab.getDecisionSnapshot();
        assertGe(s.mainTickLower, SPOT_TICK, "dust minority: main is single-sided above spot (lower >= spot)");
        assertGt(s.mainLiquidity, 0, "dust minority: main has positive liquidity (not a degenerate straddle)");
    }

    // ─── Review fix F7: maxCenterDeviation enforced on the balanced path ─────────

    /// @dev F7: a balanced rebalanceUsingAlt whose center is within maxCenterDeviation passes. The straddle is
    ///      spot-centered, so |center - spot| is just the alignment remainder (here 100 ticks, well
    ///      within 400). Asserts the happy path does not spuriously revert CenterDeviation; the guard
    ///      is a backstop for any future change to the centering reference (single-sided path is
    ///      intentionally off-center and exempt).
    function test_rebalanceUsingAlt_balancedCenterWithinDeviation_passes() public {
        _register(false);
        _stagePrincipal(1e18, 1e18); // balanced → straddle path
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams()); // must NOT revert CenterDeviation
        (uint256 mainId,,) = _readMainAlt();
        assertEq(mainId, NEW_TOKEN_ID, "balanced rebalanceUsingAlt within center bound succeeded");
    }

    // ─── Review fix F8: deadline threaded into the withdraw leg ──────────────────

    /// @dev F8: a rebalanceUsingAlt with deadline < block.timestamp must revert at the MAIN decrease (the PM
    ///      enforces the deadline). The old code hardcoded deadline = block.timestamp on the decrease,
    ///      so an expired caller deadline had no effect on the withdraw leg.
    function test_rebalanceUsingAlt_revertsOnExpiredDeadline() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);
        vm.warp(block.timestamp + 100);
        LPAutoBalancerV2.RebalanceParams memory pr = _defaultRebalanceParams();
        pr.deadline = block.timestamp - 1; // expired
        vm.prank(rebalancer);
        vm.expectRevert("Transaction too old");
        lab.rebalanceUsingAlt(pr);
    }

    // ─── setPool: re-point an emptied contract ───────────────────────────────────

    function test_setPool_revertsWhenActive() public {
        _register(false);
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.NotEmpty.selector);
        lab.setPool(cfg);
    }

    function test_setPool_repointsAfterExit() public {
        _register(false);
        vm.prank(admin);
        lab.exit(admin); // active=false, mainTokenId=0, altTokenId=0

        // NEW_TOKEN_ID (43) is already wired in setUp:
        //   mockPM.setPosition(43, ..., token0, token1) → tickSpacing defaults to 200
        //   mockPM.ownerOf(43) returns address(lab) (mockOwner)
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
        cfg.mainTokenId = NEW_TOKEN_ID;

        vm.prank(admin);
        vm.expectEmit(true, true, false, false, address(lab));
        emit LPAutoBalancerV2.PoolChanged(cfg.pool, NEW_TOKEN_ID);
        lab.setPool(cfg);

        (uint256 mainTokenId,,,,,,,,,,,,,,,,,,,,) = lab.position();
        assertEq(mainTokenId, NEW_TOKEN_ID, "mainTokenId updated after setPool");
    }

    /// @dev Prove setPool reverts NotEmpty when active=false but mainTokenId is still set
    ///      (the state left by withdrawPosition/deregisterPosition). This exercises the
    ///      `|| position.mainTokenId != 0` branch of the empty-guard: a mutation that drops
    ///      that clause would let this call through instead of reverting.
    function test_setPool_revertsAfterWithdraw_tokenIdStillSet() public {
        _register(false);
        vm.prank(admin);
        lab.withdrawPosition(admin); // sets active=false but leaves mainTokenId=TOKEN_ID (42)
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.NotEmpty.selector);
        lab.setPool(cfg);
    }

    /// @dev setPool is DEFAULT_ADMIN_ROLE-gated: a caller with only REBALANCER_ROLE must revert.
    function test_setPool_revertNonAdmin() public {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
        vm.prank(rebalancer);
        vm.expectRevert();
        lab.setPool(cfg);
    }

    // ─── Review fix F9: collectFees skims BOTH main and alt ──────────────────────

    /// @dev F9: collectFees on a position with a live alt must skim BOTH NFTs' fees to the feeCollector.
    ///      The mock collect auto-advances slots; we stage non-zero fees and assert both legs forward.
    function test_collectFees_skimsBothMainAndAlt() public {
        _registerWithAlt(false); // not staked, alt injected
        // collect call 0 → slot 0 (main fees), calls 1+ → slot 1 (alt fees). Stage both non-zero.
        tok0.mint(address(mockPM), 5e18);
        tok1.mint(address(mockPM), 5e18);
        mockPM.setCollectSequence(2e18, 1e18, 1e18, 5e17); // main: 2e18/1e18 ; alt: 1e18/5e17

        uint256 before0 = tok0.balanceOf(feeCollector);
        uint256 before1 = tok1.balanceOf(feeCollector);

        lab.collectFees();

        // Two collects fired (main + alt); both legs' fees landed on the feeCollector.
        assertEq(mockPM.collectCallCount(), 2, "collectFees skimmed both main and alt NFTs");
        assertGt(tok0.balanceOf(feeCollector) - before0, 0, "token0 fees forwarded from both legs");
        assertGt(tok1.balanceOf(feeCollector) - before1, 0, "token1 fees forwarded from both legs");
    }

    // ---------- swap-loss allowance setter ----------

    function test_setSwapLossAllowanceBps_adminSets_andEmits() public {
        vm.expectEmit(true, true, true, true);
        emit LPAutoBalancerV2.SwapLossAllowanceUpdated(0, 300);
        vm.prank(admin);
        lab.setSwapLossAllowanceBps(300);
        assertEq(lab.swapLossAllowanceBps(), 300);
    }

    function test_setSwapLossAllowanceBps_revertsAboveCap() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.SwapLossAllowanceTooHigh.selector);
        lab.setSwapLossAllowanceBps(501);
    }

    function test_setSwapLossAllowanceBps_capValueAllowed() public {
        vm.prank(admin);
        lab.setSwapLossAllowanceBps(500);
        assertEq(lab.swapLossAllowanceBps(), 500);
    }

    function test_setSwapLossAllowanceBps_revertsNonAdmin() public {
        vm.prank(rebalancer);
        vm.expectRevert();
        lab.setSwapLossAllowanceBps(100);
    }

    function test_swapRebalance_stateDefaults() public view {
        assertFalse(lab.rebalanceInFlight());
        assertEq(lab.rebalanceValueBefore(), 0);
        assertEq(lab.rebalanceStartedAt(), 0);
        assertEq(lab.sellTokenInFlight(), address(0));
        assertFalse(lab.rebalanceWasStaked());
        assertEq(lab.swapLossAllowanceBps(), 0);
        assertEq(lab.MAX_SWAP_LOSS_ALLOWANCE_BPS(), 500);
        assertEq(lab.VAULT_RELAYER(), 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110);
    }

    function test_getDecisionSnapshot_includesInFlightFields() public {
        _register(false);

        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertFalse(s.rebalanceInFlight, "not in flight by default");
        assertEq(s.rebalanceStartedAt, 0, "no unwind yet");
    }
}
