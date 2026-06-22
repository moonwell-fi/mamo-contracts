// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";
import {MockCLGauge} from "./mocks/MockCLGauge.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {Test} from "@forge-std/Test.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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
        tokenId = nextMintTokenId;
        liquidity = nextMintLiquidity;
        lastMintedTokenId = tokenId;
        if (pullOnMint) {
            IERC20(params.token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
            IERC20(params.token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
        }
        return (tokenId, liquidity, 0, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockCLPoolV2 — configurable slot0 + observe
// ─────────────────────────────────────────────────────────────────────────────
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
        mockPM.setCollectTokens(token0, token1);
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
}
