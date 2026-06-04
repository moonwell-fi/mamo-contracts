// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {Vm} from "@forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockCLGauge} from "./mocks/MockCLGauge.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

// ─────────────────────────────────────────────────────────────────────────────
// MockPositionManagerV2 — full position lifecycle for rebalance tests
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Extended mock PM that models a two-phase collect lifecycle:
///   Phase A (skimFees): first collect call returns fees; amounts are zeroed after.
///   Phase B (decreaseAll): decreaseLiquidity then a second collect call for principal.
///   The PM auto-zeroes collectAmount after each call so tests configure each phase.
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

    // Position storage
    struct PositionData {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address token0;
        address token1;
    }

    mapping(uint256 => PositionData) internal _positions;

    // Collect sequence: up to 2 staged collect results.
    // Index 0 = first call (skimFees), index 1 = second call (decreaseAll principal).
    address public collectToken0;
    address public collectToken1;
    // Two-slot amounts: [0] for skimFees call, [1] for decreaseAll call.
    uint256[2] public collectAmounts0;
    uint256[2] public collectAmounts1;

    // mint next result
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

    /// @notice Set the tokens used for all collect transfers.
    function setCollectTokens(address t0, address t1) external {
        collectToken0 = t0;
        collectToken1 = t1;
    }

    /// @notice Stage a two-call collect sequence.
    ///   slot=0 → skimFees call amounts; slot=1 → decreaseAll principal amounts.
    function setCollectAmounts(uint8 slot, uint256 a0, uint256 a1) external {
        collectAmounts0[slot] = a0;
        collectAmounts1[slot] = a1;
    }

    /// @notice Convenience: stage both slots at once.
    function setCollectSequence(uint256 fee0, uint256 fee1, uint256 princ0, uint256 princ1) external {
        collectAmounts0[0] = fee0;
        collectAmounts1[0] = fee1;
        collectAmounts0[1] = princ0;
        collectAmounts1[1] = princ1;
    }

    function setNextMintResult(uint256 newTokenId, uint128 liq) external {
        nextMintTokenId = newTokenId;
        nextMintLiquidity = liq;
    }

    // ── INonfungiblePositionManager interface ────────────────────────────────

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
        // Accounting only; tokens flow in the subsequent collect() call.
        return (0, 0);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        lastCollectTokenId = params.tokenId;
        lastCollectRecipient = params.recipient;

        // Use slot 0 for first call, slot 1 for second call.
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

    function mint(INonfungiblePositionManager.MintParams calldata)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        mintCallCount++;
        tokenId = nextMintTokenId;
        liquidity = nextMintLiquidity;
        lastMintedTokenId = tokenId;
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

// ─────────────────────────────────────────────────────────────────────────────
// MockSwapRouterV2 — records calls, returns configured amountOut
// ─────────────────────────────────────────────────────────────────────────────

contract MockSwapRouterV2 is ISwapRouter {
    uint256 public amountOutToReturn;
    bool public wasCalled;

    function setAmountOutToReturn(uint256 a) external {
        amountOutToReturn = a;
    }

    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256) {
        wasCalled = true;
        return amountOutToReturn;
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256) {
        revert("stub");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256) {
        revert("stub");
    }

    function exactOutput(ExactOutputParams calldata) external payable returns (uint256) {
        revert("stub");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockQuoterV2 — returns configurable quote
// ─────────────────────────────────────────────────────────────────────────────

contract MockQuoterV2 is IQuoter {
    uint256 public quotedOut;

    function setQuotedOut(uint256 a) external {
        quotedOut = a;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory)
        external
        view
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        return (quotedOut, 0, 0, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main test contract
// ─────────────────────────────────────────────────────────────────────────────

contract LPAutoBalancerRebalanceTest is Test {
    LPAutoBalancer lab;
    MockPositionManagerV2 mockPM;
    MockCLPoolV2 mockPool;
    MockCLGauge mockGauge;
    MockSwapRouterV2 mockRouter;
    MockQuoterV2 mockQuoter;
    MockERC20 mockAero;
    MockERC20 tok0;
    MockERC20 tok1;
    MockPriceFeed feed0;
    MockPriceFeed feed1;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");
    address feeCollector = makeAddr("feeCollector");

    // Token IDs
    uint256 constant OLD_TOKEN_ID = 42;
    uint256 constant NEW_TOKEN_ID = 43;

    // Tick geometry (tickSpacing=200, width=400):
    //   twapTick=0, spotTick=100
    //   _alignedRange(0, 400, 200, 100):
    //     half=200; tickLower = floorAlign(0-200, 200) = floorAlign(-200, 200) = -200
    //     tickUpper = -200 + 400 = 200
    //     100 ∈ (-200, 200) ✓
    int24 constant SPOT_TICK = 100;
    int24 constant TWAP_TICK = 0;
    // sqrtPriceX96 at tick=0 (price = 1.0 exactly): 2^96
    uint160 constant SQRT_P = 79_228_162_514_264_337_593_543_950_336;

    // OLD position geometry — same range as rebalance target so value floor is trivially met
    int24 constant OLD_TL = -200;
    int24 constant OLD_TU = 200;
    uint128 constant OLD_LIQ = 1e18;
    uint128 constant NEW_LIQ = 1e18; // same → valueAfter == valueBefore

    function setUp() public {
        tok0 = new MockERC20("Token0", "TK0");
        tok1 = new MockERC20("Token1", "TK1");
        mockAero = new MockERC20("Aerodrome", "AERO");

        mockPool = new MockCLPoolV2();
        mockGauge = new MockCLGauge(address(mockAero));
        mockRouter = new MockSwapRouterV2();
        mockQuoter = new MockQuoterV2();

        mockPM = new MockPositionManagerV2(address(0));

        lab = new LPAutoBalancer(
            admin,
            manager,
            rebalancer,
            guardian,
            address(mockPM),
            address(mockRouter),
            address(mockQuoter),
            address(mockAero)
        );

        mockPM.setMockOwner(address(lab));

        // Price feeds: $1.00, 8 decimals, fresh
        feed0 = new MockPriceFeed(1e8, 8, block.timestamp);
        feed1 = new MockPriceFeed(1e8, 8, block.timestamp);

        // Pool: spot tick=100, sqrtP at tick=0 (close enough for unit test)
        // twapTick=0: cum1-cum0=0, window=1800 → twapTick=0/1800=0
        mockPool.setSlot0(SQRT_P, SPOT_TICK);
        mockPool.setObserve(0, 0);

        // OLD position
        mockPM.setPosition(OLD_TOKEN_ID, OLD_TL, OLD_TU, OLD_LIQ, address(tok0), address(tok1));

        // NEW position (mint result + post-mint principalValue lookup)
        mockPM.setNextMintResult(NEW_TOKEN_ID, NEW_LIQ);
        mockPM.setPosition(NEW_TOKEN_ID, OLD_TL, OLD_TU, NEW_LIQ, address(tok0), address(tok1));

        // Collect tokens setup
        mockPM.setCollectTokens(address(tok0), address(tok1));
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _registerSlot(bool withGauge) internal returns (uint256 slotId) {
        LPAutoBalancer.ManagedPosition memory cfg = LPAutoBalancer.ManagedPosition({
            tokenId: OLD_TOKEN_ID,
            pool: address(mockPool),
            token0: address(tok0),
            token1: address(tok1),
            tickSpacing: 200,
            gauge: withGauge ? address(mockGauge) : address(0),
            staked: false,
            feeCollector: feeCollector,
            oracle0: address(feed0),
            oracle1: address(feed1),
            swapPolicy: 0,
            protectedToken: address(0),
            minWidth: 200,
            maxWidth: 2000,
            // center of [-200,200] = 0, twapTick=0 → dev=0 ≤ 400 ✓
            maxCenterDeviation: 400,
            maxSlippageBps: 100,
            twapWindow: 1800,
            // spotTick=100, twapTick=0 → diff=100 ≤ 200 ✓
            maxTickDeviation: 200,
            maxRebalanceLossBps: 100, // 1% tolerance
            minRebalanceInterval: 0, // no cooldown
            lastRebalance: 0,
            active: false
        });
        vm.prank(admin);
        slotId = lab.registerPosition(cfg);
    }

    function _defaultParams() internal view returns (LPAutoBalancer.RebalanceParams memory) {
        return LPAutoBalancer.RebalanceParams({
            width: 400,
            swapMinAmountOut: 0,
            amount0MinDecrease: 0,
            amount1MinDecrease: 0,
            amount0MinMint: 0,
            amount1MinMint: 0,
            deadline: block.timestamp + 3600
        });
    }

    /// @notice Stage the PM for a standard rebalance: 0 fees, principal=1e18/1e18.
    ///         Mints tok0+tok1 into PM so collect transfers succeed.
    function _stagePrincipal(uint256 princ0, uint256 princ1) internal {
        tok0.mint(address(mockPM), princ0);
        tok1.mint(address(mockPM), princ1);
        // slot 0 (skimFees): 0 fees
        // slot 1 (decreaseAll principal): princ0/princ1
        mockPM.setCollectSequence(0, 0, princ0, princ1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1: Happy path end-to-end (unstaked, no swap)
    // ─────────────────────────────────────────────────────────────────────────

    function test_rebalance_happy() public {
        uint256 slotId = _registerSlot(false);

        // With sqrtP at tick=0, range [-200,200], equal principal → ratio ≈ 50/50.
        // _computeSwap with equal balances at price≈1 in symmetric range → amountIn ≈ 0.
        // If amountIn>0 we'd need the quoter to return a positive value; keep principal equal.
        _stagePrincipal(1e18, 1e18);

        vm.expectEmit(true, false, false, false);
        emit LPAutoBalancer.Rebalanced(slotId, OLD_TOKEN_ID, NEW_TOKEN_ID, -200, 200);

        vm.prank(rebalancer);
        lab.rebalance(slotId, _defaultParams());

        // tokenId updated
        (uint256 storedTokenId,,,,,,,,,,,,,,,,,,,,,) = lab.positions(slotId);
        assertEq(storedTokenId, NEW_TOKEN_ID, "tokenId not updated");

        // old NFT burned
        assertEq(mockPM.lastBurnedTokenId(), OLD_TOKEN_ID, "wrong burned token");
        assertEq(mockPM.burnCallCount(), 1, "burn not called once");

        // lastRebalance = block.timestamp
        (,,,,,,,,,,,,,,,,,,,, uint256 storedLastRebalance,) = lab.positions(slotId);
        assertEq(storedLastRebalance, block.timestamp, "lastRebalance not updated");

        // dust forwarded: lab holds no tok0/tok1
        assertEq(tok0.balanceOf(address(lab)), 0, "lab holds tok0 dust");
        assertEq(tok1.balanceOf(address(lab)), 0, "lab holds tok1 dust");

        // staked stays false
        (,,,,,, bool stakedAfter,,,,,,,,,,,,,,,) = lab.positions(slotId);
        assertFalse(stakedAfter, "should not be staked");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: Staked → unstakes, rebalances, restakes
    // ─────────────────────────────────────────────────────────────────────────

    function test_rebalance_staked_unstakesAndRestakes() public {
        uint256 slotId = _registerSlot(true);

        // Stake the position
        vm.prank(rebalancer);
        lab.stake(slotId);

        {
            (,,,,,, bool stakedBefore,,,,,,,,,,,,,,,) = lab.positions(slotId);
            assertTrue(stakedBefore, "should be staked before rebalance");
        }

        // Gauge pays AERO on withdraw
        uint256 aeroAmount = 5e18;
        mockAero.mint(address(mockGauge), aeroAmount);
        mockGauge.setAeroToPayOnWithdraw(aeroAmount);

        _stagePrincipal(1e18, 1e18);

        vm.prank(rebalancer);
        lab.rebalance(slotId, _defaultParams());

        // AERO forwarded to feeCollector during _unstake
        assertEq(mockAero.balanceOf(feeCollector), aeroAmount, "AERO not forwarded");
        assertEq(mockAero.balanceOf(address(lab)), 0, "lab holds AERO");

        // Re-staked with new tokenId
        {
            (,,,,,, bool stakedAfter,,,,,,,,,,,,,,,) = lab.positions(slotId);
            assertTrue(stakedAfter, "not restaked");
        }
        assertEq(mockGauge.lastDepositedTokenId(), NEW_TOKEN_ID, "gauge deposit wrong tokenId");

        // tokenId updated
        {
            (uint256 storedTokenId,,,,,,,,,,,,,,,,,,,,,) = lab.positions(slotId);
            assertEq(storedTokenId, NEW_TOKEN_ID, "tokenId not updated");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3: Non-rebalancer reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_rebalance_revertNonRebalancer() public {
        uint256 slotId = _registerSlot(false);

        address rando = makeAddr("rando");
        bytes32 rebalancerRole = lab.REBALANCER_ROLE();

        vm.prank(rando);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, rando, rebalancerRole)
        );
        lab.rebalance(slotId, _defaultParams());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4: NotActive guard
    // ─────────────────────────────────────────────────────────────────────────

    function test_rebalance_revertNotActive() public {
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancer.NotActive.selector);
        lab.rebalance(99, _defaultParams());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 5: Cooldown guard
    // ─────────────────────────────────────────────────────────────────────────

    function test_rebalance_revertCooldown() public {
        // Start at a timestamp safely beyond the cooldown window
        vm.warp(10_000);

        // Register with 3600s cooldown
        LPAutoBalancer.ManagedPosition memory cfg = LPAutoBalancer.ManagedPosition({
            tokenId: OLD_TOKEN_ID,
            pool: address(mockPool),
            token0: address(tok0),
            token1: address(tok1),
            tickSpacing: 200,
            gauge: address(0),
            staked: false,
            feeCollector: feeCollector,
            oracle0: address(feed0),
            oracle1: address(feed1),
            swapPolicy: 0,
            protectedToken: address(0),
            minWidth: 200,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            maxSlippageBps: 100,
            twapWindow: 1800,
            maxTickDeviation: 200,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 3600,
            lastRebalance: 0,
            active: false
        });
        vm.prank(admin);
        uint256 slotId = lab.registerPosition(cfg);

        // Refresh oracle timestamps to match warped time
        feed0.setUpdatedAt(block.timestamp);
        feed1.setUpdatedAt(block.timestamp);

        // First rebalance — succeeds (lastRebalance=0, timestamp=10000 > 0+3600)
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.rebalance(slotId, _defaultParams());

        // Update PM to reflect new tokenId
        mockPM.setPosition(NEW_TOKEN_ID, OLD_TL, OLD_TU, NEW_LIQ, address(tok0), address(tok1));
        uint256 nextId = NEW_TOKEN_ID + 1;
        mockPM.setNextMintResult(nextId, NEW_LIQ);
        mockPM.setPosition(nextId, OLD_TL, OLD_TU, NEW_LIQ, address(tok0), address(tok1));

        // Second call immediately (no time advance) → Cooldown
        // block.timestamp=10000, lastRebalance=10000, minInterval=3600 → 10000 < 10000+3600 ✓
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancer.Cooldown.selector);
        lab.rebalance(slotId, _defaultParams());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 6: WidthOutOfBounds
    // ─────────────────────────────────────────────────────────────────────────

    function test_rebalance_revertWidthTooNarrow() public {
        uint256 slotId = _registerSlot(false);
        LPAutoBalancer.RebalanceParams memory p = _defaultParams();
        p.width = 100; // < minWidth=200

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancer.WidthOutOfBounds.selector);
        lab.rebalance(slotId, p);
    }

    function test_rebalance_revertWidthTooWide() public {
        uint256 slotId = _registerSlot(false);
        LPAutoBalancer.RebalanceParams memory p = _defaultParams();
        p.width = 2200; // > maxWidth=2000

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancer.WidthOutOfBounds.selector);
        lab.rebalance(slotId, p);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 7: Rebalanced event args
    // ─────────────────────────────────────────────────────────────────────────

    function test_rebalance_emitsRebalancedEvent() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        // Expected ticks from _alignedRange(twapTick=0, width=400, spacing=200, spotTick=100):
        //   half=200; tickLower = floorAlign(-200, 200) = -200; tickUpper = 200
        vm.expectEmit(true, true, true, true);
        emit LPAutoBalancer.Rebalanced(slotId, OLD_TOKEN_ID, NEW_TOKEN_ID, -200, 200);

        vm.prank(rebalancer);
        lab.rebalance(slotId, _defaultParams());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 8: FeesSkimmed event emitted with correct amounts
    // ─────────────────────────────────────────────────────────────────────────

    function test_rebalance_feesSkimmedEvent() public {
        uint256 slotId = _registerSlot(false);

        uint256 fee0 = 3e17;
        uint256 fee1 = 2e17;
        uint256 princ0 = 1e18;
        uint256 princ1 = 1e18;

        tok0.mint(address(mockPM), fee0 + princ0);
        tok1.mint(address(mockPM), fee1 + princ1);
        mockPM.setCollectSequence(fee0, fee1, princ0, princ1);

        vm.expectEmit(true, false, false, true);
        emit LPAutoBalancer.FeesSkimmed(slotId, fee0, fee1);

        vm.prank(rebalancer);
        lab.rebalance(slotId, _defaultParams());

        // feeCollector received at least the fees (plus any dust from principal)
        assertGe(tok0.balanceOf(feeCollector), fee0, "feeCollector missing fee0");
        assertGe(tok1.balanceOf(feeCollector), fee1, "feeCollector missing fee1");
    }
}
