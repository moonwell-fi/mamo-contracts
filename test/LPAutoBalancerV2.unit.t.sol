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
// MockPositionManagerV2 — full position lifecycle for reset() tests.
// Ported from V1 (LPAutoBalancerRebalanceTest). Models a two-phase collect:
//   slot 0 (skimFees) → fees; slot 1 (decreaseAll) → principal. Auto-advances.
// NOTE: V2 has NO swap router, so the "no swap" property is structural — reset()
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
    }

    mapping(uint256 => PositionData) internal _positions;

    address public collectToken0;
    address public collectToken1;
    uint256[2] public collectAmounts0;
    uint256[2] public collectAmounts1;

    uint256 public nextMintTokenId;
    uint128 public nextMintLiquidity;

    // Second staged mint result (alt). When set, the 2nd mint() call returns these
    // and any further call falls back to the main result. Lets reset() mint main then alt.
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
        _positions[tokenId] = PositionData({tickLower: tl, tickUpper: tu, liquidity: liq, token0: t0, token1: t1});
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
        return (0, address(0), pd.token0, pd.token1, 0, pd.tickLower, pd.tickUpper, pd.liquidity, 0, 0, 0, 0);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        lastDecreaseTokenId = params.tokenId;
        decreaseCallCount++;
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

    function setSlot0(uint160 sqrtP, int24 tick) external {
        sqrtPX96 = sqrtP;
        currentTick = tick;
    }

    function setObserve(int56 cum0, int56 cum1) external {
        tickCumulative0 = cum0;
        tickCumulative1 = cum1;
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

    function token0() external pure returns (address) {
        return address(0);
    }

    function token1() external pure returns (address) {
        return address(0);
    }

    function tickSpacing() external pure returns (int24) {
        return 200;
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

    // Live mock contracts backing the config (real pool/tokens so reset() can run).
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

        // Configurable pool mock (slot0 + observe) for reset() geometry.
        mockPool = new MockCLPoolV2();
        pool = address(mockPool);

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

    /// @dev Build and register a ManagedPositionV2 slot.
    ///      withGauge=true sets gauge field; false leaves it address(0).
    function _registerSlot(bool withGauge) internal returns (uint256 slotId) {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
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
            minWidth: 200,
            maxWidth: 2000,
            // center of [-200,200] = 0, twapTick=0 → dev=0 ≤ 400 ✓
            maxCenterDeviation: 400,
            twapWindow: 1800,
            // spotTick=100, twapTick=0 → |diff|=100 ≤ 200 ✓
            maxTickDeviation: 200,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 0, // no cooldown so reset() can run immediately
            lastRebalance: 999, // should be forced to 0 by _store
            active: false // should be forced to true by _store
        });
        vm.prank(admin);
        slotId = lab.registerPosition(cfg);
    }

    // ─── reset() helpers ───────────────────────────────────────────────────────

    /// @dev Default reset params: width 400, all mins 0, deadline now+1.
    function _defaultResetParams() internal view returns (LPAutoBalancerV2.ResetParams memory) {
        return LPAutoBalancerV2.ResetParams({
            width: 400,
            amount0MinMain: 0,
            amount1MinMain: 0,
            amount0MinAlt: 0,
            amount1MinAlt: 0,
            amount0MinWithdraw: 0,
            amount1MinWithdraw: 0,
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
        uint256 slotId = _registerSlot(false);

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
        ) = lab.positions(slotId);

        assertEq(slotId, 0);
        assertEq(lab.nextSlotId(), 1);
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
            minWidth: 200,
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
            minWidth: 200,
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
            minWidth: 200,
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
        // Verify struct has no swapPolicy: compile-time check via _registerSlot succeeding
        // and no runtime revert for any "slippage cap exceeded" path
        uint256 slotId = _registerSlot(false);
        assertTrue(slotId == 0); // just confirm it registered
    }

    // ─── reset() — Task 2: rebuild balanced main, no swap ────────────────────────

    function test_reset_rebuildsMain_fromWithdrawnBalances() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18); // PM returns this principal on decrease+collect

        vm.prank(rebalancer);
        lab.reset(slotId, _defaultResetParams());

        // slot active, main tokenId updated to the freshly minted NFT, alt cleared
        (uint256 mainTokenId, uint256 altTokenId,,,,,,,,,,,,,,,,,,, bool active) = lab.positions(slotId);
        assertEq(mainTokenId, NEW_TOKEN_ID, "mainTokenId updated to new NFT");
        assertEq(altTokenId, 0, "alt cleared (Task 3 adds it)");
        assertTrue(active, "slot stays active");

        // No-swap property is structural: the new position was rebuilt purely from the
        // withdrawn principal (mint consumed contract-held tokens; nothing was sold).
        // Old NFT burned exactly once.
        assertEq(mockPM.burnCallCount(), 1, "old main burned");
        assertEq(mockPM.lastBurnedTokenId(), TOKEN_ID, "wrong burned token");

        // Balanced principal => ~0 leftover, forwarded to feeCollector (no dust stranded).
        assertEq(tok0.balanceOf(address(lab)), 0, "no token0 dust");
        assertEq(tok1.balanceOf(address(lab)), 0, "no token1 dust");

        // lastRebalance stamped to the current block.
        (,,,,,,,,,,,,,,,,,,, uint256 lastRebalance,) = lab.positions(slotId);
        assertEq(lastRebalance, block.timestamp, "lastRebalance stamped");
    }

    // ─── reset() — withdraw-min sandwich guard (HIGH defect fix) ─────────────────

    /// @dev The caller's amount{0,1}MinWithdraw must be forwarded to the MAIN decrease so the
    ///      position manager reverts when the withdrawn principal falls below the floor.
    ///      Staged principal is 1e18/1e18; a withdraw-min ABOVE that must revert reset().
    function test_reset_revertsWhenWithdrawMinUnmet() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancerV2.ResetParams memory params = _defaultResetParams();
        params.amount0MinWithdraw = 1e18 + 1; // floor exceeds the staged decrease return

        vm.prank(rebalancer);
        vm.expectRevert("Price slippage check");
        lab.reset(slotId, params);
    }

    /// @dev Mirror of the above: a withdraw-min AT or BELOW the staged return passes the floor
    ///      and reset() succeeds, proving the wiring does not over-reject.
    function test_reset_succeedsWhenWithdrawMinMet() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancerV2.ResetParams memory params = _defaultResetParams();
        params.amount0MinWithdraw = 1e18; // exactly the staged return
        params.amount1MinWithdraw = 1e18;

        vm.prank(rebalancer);
        lab.reset(slotId, params);

        (uint256 mainTokenId,,,,,,,,,,,,,,,,,,,,) = lab.positions(slotId);
        assertEq(mainTokenId, NEW_TOKEN_ID, "reset completed with withdraw mins met");
    }

    // ─── reset() — Task 3: single-sided alt mint from leftover ───────────────────

    /// @dev Read (mainTokenId, altTokenId, mainStaked) from the positions() getter.
    function _readMainAlt(uint256 slotId) internal view returns (uint256 main, uint256 alt, bool mainStaked) {
        (main, alt,,,,,, mainStaked,,,,,,,,,,,,,) = lab.positions(slotId);
    }

    /// @dev Read (mainStaked, altStaked) from the positions() getter.
    function _readStakeFlags(uint256 slotId) internal view returns (bool mainStaked, bool altStaked) {
        (,,,,,,, mainStaked, altStaked,,,,,,,,,,,,) = lab.positions(slotId);
    }

    function test_reset_mintsAltFromLeftover() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(3e18, 1e18); // imbalanced => surplus token0
        mockPM.setNextMintResult(NEW_TOKEN_ID, 1e18); // main
        mockPM.setNextAltMintResult(ALT_TOKEN_ID, 5e17); // alt (single-sided from leftover)
        vm.prank(rebalancer);
        lab.reset(slotId, _defaultResetParams());
        (, uint256 altId,) = _readMainAlt(slotId);
        assertEq(altId, ALT_TOKEN_ID, "alt minted from leftover");
    }

    function test_reset_skipsAltWhenLeftoverDust() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18); // balanced => ~no leftover
        vm.prank(rebalancer);
        lab.reset(slotId, _defaultResetParams());
        (, uint256 altId,) = _readMainAlt(slotId);
        assertEq(altId, 0, "no alt when leftover is dust");
    }

    function test_reset_imbalanced_valueFloorCountsAlt() public {
        // The surplus minted into the alt must be counted in valueAfter, so an
        // imbalanced withdrawal does NOT spuriously trip ValueFloor.
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(3e18, 1e18);
        mockPM.setNextMintResult(NEW_TOKEN_ID, 1e18);
        mockPM.setNextAltMintResult(ALT_TOKEN_ID, 5e17);
        vm.prank(rebalancer);
        lab.reset(slotId, _defaultResetParams()); // must NOT revert ValueFloor
        // both main and alt set; no large dust forwarded as "loss"
        (uint256 mainId, uint256 altId,) = _readMainAlt(slotId);
        assertEq(mainId, NEW_TOKEN_ID, "main set");
        assertEq(altId, ALT_TOKEN_ID, "alt set");
    }

    function test_reset_restakesMain_whenStaked() public {
        uint256 slotId = _registerSlot(true); // gauged
        vm.prank(rebalancer);
        lab.stake(slotId);
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.reset(slotId, _defaultResetParams());
        (bool mainStaked,) = _readStakeFlags(slotId);
        assertTrue(mainStaked, "main restaked after reset"); // covers the wasStaked branch
    }

    // ─── reset() — Task 3 HIGH fix: value-based leg selection + USD dust + floor-counts-loose ──
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

    /// @dev Spin up an independent mixed-decimal fixture (cbBTC/WETH) and register a slot on a
    ///      fresh balancer instance. pullOnMint=false: the main mint consumes nothing, so the
    ///      loose contract balances at _mintAlt time equal exactly the staged principal — giving
    ///      the test direct control over each leg's raw amount (and therefore its USD value).
    function _setupMixedSlot(uint256 lossBps) internal returns (uint256 slotId) {
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
            minWidth: 200,
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
        slotId = dLab.registerPosition(cfg);
    }

    /// @dev Stage the mixed-fixture PM to pay out p0/p1 principal on decrease+collect (0 fees).
    function _stageMixedPrincipal(uint256 p0, uint256 p1) internal {
        dtok0.mint(address(dPM), p0);
        dtok1.mint(address(dPM), p1);
        dPM.setCollectSequence(0, 0, p0, p1);
    }

    /// @dev Read (mainTokenId, altTokenId, mainStaked) from the mixed-fixture balancer.
    function _readMixedMainAlt(uint256 slotId) internal view returns (uint256 main, uint256 alt, bool mainStaked) {
        (main, alt,,,,,, mainStaked,,,,,,,,,,,,,) = dLab.positions(slotId);
    }

    /// @dev DEFECT 1+2: the surplus leg must be chosen by USD VALUE, not raw base units, and the
    ///      mint/skip decision must use a USD threshold. Stage raw bal0 < bal1 (1e5 cbBTC units vs
    ///      1e16 WETH units) but value0 ($65) > value1 ($25). The alt must be minted on the token0
    ///      (cbBTC) side — the range ABOVE the main upper [200,400] — proving value-based selection.
    ///      The OLD raw-unit code (`surplus0 = bal0 >= bal1` → 1e5 >= 1e16 → false) would have placed
    ///      the alt on the token1 side (range BELOW), so the tick assertions discriminate the fix.
    function test_mintAlt_selectsSurplusByValue_notRawUnits() public {
        uint256 slotId = _setupMixedSlot(500);
        // token0 (cbBTC): 1e5 raw = 0.001 cbBTC ≈ $65 (65e8 USD)
        // token1 (WETH):  1e16 raw = 0.01 WETH   ≈ $25 (25e8 USD)
        // raw bal0 (1e5) < bal1 (1e16), but value0 ($65) > value1 ($25).
        _stageMixedPrincipal(1e5, 1e16);

        vm.prank(rebalancer);
        dLab.reset(slotId, _defaultResetParams());

        (uint256 mainId, uint256 altId,) = _readMixedMainAlt(slotId);
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
    function test_reset_forwardedDustCannotBypassValueFloor() public {
        uint256 slotId = _setupMixedSlot(100); // tight 1% loss cap

        // New main holds ~nothing; the alt captures nothing. The entire withdrawn principal comes
        // back as a token0 surplus that stays LOOSE (pullOnMint=false → mint pulls no tokens).
        dPM.setNextMintResult(D_NEW_ID, 0);
        dPM.setPosition(D_NEW_ID, OLD_TL, OLD_TU, 0, address(dtok0), address(dtok1));
        dPM.setPosition(D_ALT_ID, OLD_TU, OLD_TU + 200, 0, address(dtok0), address(dtok1)); // alt holds nothing

        // Withdrawn principal = a big token0 surplus (1e10 raw cbBTC = 100 cbBTC ≈ $6.5M), all loose
        // after the (empty) mints — comfortably above valueBefore so the no-loss rebuild clears the floor.
        _stageMixedPrincipal(1e10, 0);

        vm.prank(rebalancer);
        dLab.reset(slotId, _defaultResetParams());

        // NEW: floor counted the loose surplus → no spurious revert → reset succeeded.
        // (OLD ordering would have to forward that surplus out before the floor — the leak — for the
        // call to survive at all, since the NFTs alone are worth ≈0 here.)
        (uint256 mainId,,) = _readMixedMainAlt(slotId);
        assertEq(mainId, D_NEW_ID, "reset succeeded: loose surplus counted by the value floor");
    }

    /// @dev Counterpart proving the floor still trips on a GENUINE loss (value actually destroyed,
    ///      not merely retained loose). New main and alt both hold ~nothing and only 1 dust unit of
    ///      token0 is loose, so valueAfter collapses far below valueBefore minus the 1% cap.
    function test_reset_valueFloorStillTripsOnRealLoss() public {
        uint256 slotId = _setupMixedSlot(100); // 1% loss cap

        dPM.setPosition(D_ALT_ID, OLD_TU, OLD_TU + 200, 0, address(dtok0), address(dtok1)); // alt holds nothing
        dPM.setNextMintResult(D_NEW_ID, 0); // new main holds ~nothing
        dPM.setPosition(D_NEW_ID, OLD_TL, OLD_TU, 0, address(dtok0), address(dtok1));
        _stageMixedPrincipal(1, 0); // 1 raw cbBTC unit ≈ $0.00065 loose: far below the floor

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.ValueFloor.selector);
        dLab.reset(slotId, _defaultResetParams());
    }

    // ─── Task 4: stake/unstake/claimEmissions (dual-NFT) + exit() ────────────────

    /// @dev Register a gauged (or gaugeless) slot and inject a non-zero altTokenId directly
    ///      into contract storage using stdstore. This bypasses the _store() forced-zero for
    ///      altTokenId so tests can exercise the alt staking paths without running reset().
    function _registerSlotWithAlt(bool withGauge) internal returns (uint256 slotId) {
        slotId = _registerSlot(withGauge);
        // Also register ALT_TOKEN_ID with the mock PM so ownerOf returns this contract's address.
        // (mockPM.ownerOf always returns mockOwner, so no extra setup needed.)
        // Inject altTokenId = ALT_TOKEN_ID into positions[slotId].altTokenId via stdstore.
        stdstore.target(address(lab)).sig("positions(uint256)").with_key(slotId).depth(1) // altTokenId is field index 1
            .checked_write(ALT_TOKEN_ID);
    }

    /// @dev Read active flag from positions() getter.
    function _readActive(uint256 slotId) internal view returns (bool active) {
        (,,,,,,,,,,,,,,,,,,,, active) = lab.positions(slotId);
    }

    function test_stake_main_altFollows() public {
        uint256 slotId = _registerSlotWithAlt(true);
        vm.prank(rebalancer);
        lab.stake(slotId);
        (bool mainStaked, bool altStaked) = _readStakeFlags(slotId);
        assertTrue(mainStaked, "main staked");
        assertTrue(altStaked, "alt follows main");
    }

    function test_unstake_main_altFollows() public {
        uint256 slotId = _registerSlotWithAlt(true);
        vm.prank(rebalancer);
        lab.stake(slotId);
        vm.prank(rebalancer);
        lab.unstake(slotId);
        (bool mainStaked, bool altStaked) = _readStakeFlags(slotId);
        assertFalse(mainStaked, "main unstaked");
        assertFalse(altStaked, "alt unstaked");
    }

    function test_claimEmissions_sumsBothNfts() public {
        uint256 slotId = _registerSlotWithAlt(true);
        vm.prank(rebalancer);
        lab.stake(slotId);
        // Mint AERO into gauge so getReward() can pay out; set payout per call.
        mockAero.mint(address(mockGauge), 14e18);
        mockGauge.setAeroToPayOnGetReward(7e18); // each getReward call pays 7e18
        uint256 before = mockAero.balanceOf(feeCollector);
        lab.claimEmissions(slotId);
        // 2 calls: main (7e18) + alt (7e18) = 14e18 total
        assertGt(mockAero.balanceOf(feeCollector), before, "AERO from both nfts to feeCollector");
        assertEq(mockAero.balanceOf(feeCollector) - before, 14e18, "correct total from both NFTs");
    }

    function test_exit_returnsBothTokensToSafe_andDeactivates() public {
        uint256 slotId = _registerSlotWithAlt(false);
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
        lab.exit(slotId, admin);
        assertEq(mockPM.burnCallCount(), 2, "main + alt burned");
        assertGt(tok0.balanceOf(admin), 0, "token0 to Safe");
        assertGt(tok1.balanceOf(admin), 0, "token1 to Safe");
        assertEq(tok0.balanceOf(address(lab)), 0, "no token0 dust");
        assertEq(tok1.balanceOf(address(lab)), 0, "no token1 dust");
        assertFalse(_readActive(slotId), "slot deactivated");
    }

    function test_exit_onlyAdmin() public {
        uint256 slotId = _registerSlotWithAlt(false);
        vm.prank(rebalancer);
        vm.expectRevert();
        lab.exit(slotId, rebalancer);
    }

    function test_exit_unstakesAndSkimsAero_whenStaked() public {
        uint256 slotId = _registerSlotWithAlt(true);
        vm.prank(rebalancer);
        lab.stake(slotId);
        // Mint AERO into gauge so withdraw() can auto-claim
        mockAero.mint(address(mockGauge), 8e18);
        mockGauge.setAeroToPayOnWithdraw(4e18); // each withdraw call pays 4e18
        uint256 before = mockAero.balanceOf(feeCollector);
        vm.prank(admin);
        lab.exit(slotId, admin);
        assertGt(mockAero.balanceOf(feeCollector), before, "AERO skimmed on exit");
    }
}
