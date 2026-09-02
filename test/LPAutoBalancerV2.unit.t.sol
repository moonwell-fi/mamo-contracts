// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPSequencerFeedMock} from "./LPValuationLib.unit.t.sol";
import {MockERC20} from "./MockERC20.sol";
import {LPAutoBalancerV2Harness} from "./harness/LPAutoBalancerV2Harness.sol";
import {MockCLGauge} from "./mocks/MockCLGauge.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {ILPCompoundModuleRebalance, LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {LPPositionLib} from "@contracts/libraries/LPPositionLib.sol";
import {Test} from "@forge-std/Test.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

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
    // amountMin forwarding recorded per mint call (1-indexed by mintCallCount): call 1 = main,
    // call 2 = alt. Lets tests assert _mintBalanced/_mintAlt zeroed the unfunded leg's min.
    mapping(uint256 => uint256) public mintAmount0MinByCall;
    mapping(uint256 => uint256) public mintAmount1MinByCall;
    uint256 public mintCallCount;
    bool public pullOnMint;
    // tick range of the most recent mint (used to assert which side the alt was placed on).
    int24 public lastMintTickLower;
    int24 public lastMintTickUpper;
    // Per-call tick range (1-indexed by mintCallCount): call 1 = main, call 2 = alt. `lastMint*`
    // only ever shows the ALT when one is minted, so main-range assertions need the per-call map.
    mapping(uint256 => int24) public mintTickLowerByCall;
    mapping(uint256 => int24) public mintTickUpperByCall;

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

    /// @notice Rewind the two-phase collect cursor. `setCollectSequence` stages a FRESH
    ///         fee-then-principal sequence, but the cursor is global to the mock — any collect that
    ///         happened earlier in the test (e.g. stake()'s pre-deposit fee skim) would otherwise
    ///         shift the staged sequence by one and pay principal amounts to the fee skim.
    function resetCollectCount() external {
        collectCallCount = 0;
    }

    /// @notice When true, mint() forwards this contract's ENTIRE native balance to msg.sender,
    ///         reproducing Slipstream's unconditional `refundETH()` at the end of mint(). Any ETH
    ///         donated to the position manager is then pushed onto the minter, which reverts unless
    ///         the minter has a payable receiver.
    bool public refundEthOnMint;

    function setRefundEthOnMint(bool v) external {
        refundEthOnMint = v;
    }
    // Deliberately NO receive()/fallback here: the MOO-723 fixture forces ETH in with selfdestruct,
    // so the donation is unrefusable exactly as it is against the real position manager.

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
            int24 tickSpacing,
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
        // Index 4 carries tickSpacing on Aerodrome Slipstream, as a SIGNED int24 (the interface
        // now declares it that way; it used to be mislabelled `uint24 fee`, Uniswap-style).
        return
            (0, address(0), pd.token0, pd.token1, pd.tickSpacing, pd.tickLower, pd.tickUpper, pd.liquidity, 0, 0, 0, 0);
    }

    /// @notice Trip-wire for ORDERING assertions. When set, the FIRST teardown call the balancer
    ///         makes reverts with a sentinel string instead of doing anything. `_exitAll` skims fees
    ///         through `collect` (step 2) BEFORE `decreaseLiquidity` (step 3), so the wire is armed
    ///         on BOTH and whichever runs first trips it.
    /// @dev    Counters cannot pin ordering: any revert rolls back `burnCallCount`, so a guard moved
    ///         BELOW the teardown still leaves `burnCallCount() == 0` for the test to read. The
    ///         revert REASON survives, though — so arming this sentinel and asserting the tx reverts
    ///         with the guard's selector rather than "TEARDOWN_REACHED" proves the guard ran first.
    bool public revertOnTeardown;

    function setRevertOnTeardown(bool v) external {
        revertOnTeardown = v;
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        require(!revertOnTeardown, "TEARDOWN_REACHED");
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
        // Same trip-wire as decreaseLiquidity: `_exitAll` skims fees through collect() BEFORE the
        // decrease, so the sentinel has to sit on whichever teardown call comes first.
        require(!revertOnTeardown, "TEARDOWN_REACHED");
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
        mintTickLowerByCall[mintCallCount] = params.tickLower;
        mintTickUpperByCall[mintCallCount] = params.tickUpper;
        mintAmount0MinByCall[mintCallCount] = params.amount0Min;
        mintAmount1MinByCall[mintCallCount] = params.amount1Min;
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
        if (refundEthOnMint) {
            // Slipstream's mint() tail: refundETH() pushes the manager's WHOLE native balance to
            // msg.sender and bubbles the failure if the recipient rejects it.
            uint256 bal = address(this).balance;
            if (bal > 0) {
                (bool ok,) = msg.sender.call{value: bal}("");
                require(ok, "STE"); // Slipstream's TransferHelper.safeTransferETH revert string
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

/// @notice Pushes its balance onto `target` with selfdestruct — the one ETH transfer a contract
///         cannot refuse (no receive/fallback is invoked). Models the real MOO-723 setup: anyone
///         can donate ETH to the SHARED Slipstream position manager, whose mint() then forwards
///         that balance to the minter via its unconditional refundETH().
contract ForceEther {
    constructor(address payable target) payable {
        selfdestruct(target);
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
    LPAutoBalancerV2Harness lab;
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
        // Give block.timestamp room: the sequencer-uptime and per-feed-staleness tests express
        // fixtures as `block.timestamp - N`, which underflows at foundry's default timestamp of 1.
        vm.warp(10 days);

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
        // Bind the gauge to this pool so _validateAndStore's gauge->pool check passes.
        mockGauge.setPool(pool);

        // Rich PM mock with full position lifecycle (positions/decrease/collect/mint/burn).
        mockPM = new MockPositionManagerV2(address(0));

        // Real mock feeds: registerPosition probes latestRoundData at set-time
        oracle0 = address(new MockPriceFeed(1e8, 8, block.timestamp));
        oracle1 = address(new MockPriceFeed(1e8, 8, block.timestamp));

        // V2 constructor: no swapRouter, no quoter
        lab = new LPAutoBalancerV2Harness(admin, manager, rebalancer, guardian, address(mockPM), address(mockAero));

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

    /// @dev Default rebalanceUsingAlt params: width 400, all mins 0, deadline now+1, and the tick
    ///      commitment for the BALANCED branch at the shared fixture's geometry (spotTick=100,
    ///      spacing=200, width=400 → alignedRange floors 100-200 to -200, upper 200 — i.e. exactly
    ///      OLD_TL/OLD_TU). Mirrors _defaultRebuildParams: both rebalance entry points carry the same
    ///      commitment, so both default builders pin the same range. Tests that drive
    ///      rebalanceUsingAlt down the SINGLE-SIDED branch must use _rebalanceParamsAt.
    function _defaultRebalanceParams() internal view returns (LPAutoBalancerV2.RebalanceParams memory) {
        return _rebalanceParamsAt(OLD_TL, OLD_TU);
    }

    /// @dev rebalanceUsingAlt params committing to an explicit range.
    function _rebalanceParamsAt(int24 expectedTl, int24 expectedTu)
        internal
        view
        returns (LPAutoBalancerV2.RebalanceParams memory)
    {
        return LPAutoBalancerV2.RebalanceParams({
            width: 400,
            altWidth: 200,
            amount0MinMain: 0,
            amount1MinMain: 0,
            amount0MinAlt: 0,
            amount1MinAlt: 0,
            amount0MinWithdraw: 0,
            amount1MinWithdraw: 0,
            amount0MinWithdrawAlt: 0,
            amount1MinWithdrawAlt: 0,
            deadline: block.timestamp + 1,
            expectedTickLower: expectedTl,
            expectedTickUpper: expectedTu
        });
    }

    /// @dev Default rebuildAfterSwap params: width 400, all mint mins 0, deadline now+1, and the
    ///      tick commitment for the BALANCED branch at the shared fixture's geometry
    ///      (spotTick=100, spacing=200, width=400 → alignedRange floors 100-200 to -200, upper 200).
    ///      Tests that drive rebuild down the SINGLE-SIDED branch must use _rebuildParamsAt.
    function _defaultRebuildParams() internal view returns (LPAutoBalancerV2.RebuildParams memory) {
        return _rebuildParamsAt(OLD_TL, OLD_TU);
    }

    /// @dev rebuildAfterSwap params committing to an explicit range.
    function _rebuildParamsAt(int24 expectedTl, int24 expectedTu)
        internal
        view
        returns (LPAutoBalancerV2.RebuildParams memory)
    {
        LPAutoBalancerV2.RebalanceParams memory p = _defaultRebalanceParams();
        return LPAutoBalancerV2.RebuildParams({
            width: p.width,
            altWidth: p.altWidth,
            amount0MinMain: p.amount0MinMain,
            amount1MinMain: p.amount1MinMain,
            amount0MinAlt: p.amount0MinAlt,
            amount1MinAlt: p.amount1MinAlt,
            deadline: p.deadline,
            expectedTickLower: expectedTl,
            expectedTickUpper: expectedTu
        });
    }

    /// @dev Stage the PM so decreaseLiquidity+collect returns p0/p1 as withdrawn principal
    ///      (0 fees on the first collect). Mints tokens into the PM so collect transfers succeed.
    function _stagePrincipal(uint256 p0, uint256 p1) internal {
        tok0.mint(address(mockPM), p0);
        tok1.mint(address(mockPM), p1);
        // slot 0 (skimFees): 0 fees; slot 1 (decreaseAll principal): p0/p1
        mockPM.setCollectSequence(0, 0, p0, p1);
        // Rewind the cursor: stake()'s pre-deposit fee skim (and any other earlier collect) must not
        // shift this freshly staged sequence.
        mockPM.resetCollectCount();
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
        // Per-feed staleness bounds, both seeded to the pre-split default.
        assertEq(lab.maxOracleDelay0(), lab.DEFAULT_MAX_ORACLE_DELAY());
        assertEq(lab.maxOracleDelay1(), lab.DEFAULT_MAX_ORACLE_DELAY());
        // Sequencer guard is opt-in; disabled until an admin wires it.
        assertEq(lab.sequencerUptimeFeed(), address(0));
        assertEq(lab.sequencerGracePeriod(), 0);
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

        LPAutoBalancerV2.ManagedPositionV2 memory stored = lab.exposed_position();

        assertEq(stored.mainTokenId, TOKEN_ID); // registered tokenId
        assertEq(stored.altTokenId, 0); // forced to 0 by _store
        assertEq(stored.pool, pool);
        assertEq(stored.tickSpacing, 200);
        assertFalse(stored.mainStaked); // forced false
        assertFalse(stored.altStaked); // forced false
        assertEq(stored.lastRebalance, 0); // forced 0 by _store
        assertTrue(stored.active); // forced true by _store
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

    function test_registerPosition_revertsAeroAsToken0() public {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
        cfg.token0 = address(mockAero);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.InvalidConfig.selector);
        lab.registerPosition(cfg);
    }

    function test_registerPosition_revertsAeroAsToken1() public {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
        cfg.token1 = address(mockAero);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.InvalidConfig.selector);
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
        assertTrue(lab.exposed_position().active); // just confirm it registered
    }

    // ─── rebalanceUsingAlt() — Task 2: rebuild balanced main, no swap ────────────────────────

    function test_rebalanceUsingAlt_rebuildsMain_fromWithdrawnBalances() public {
        _register(false);
        _stagePrincipal(1e18, 1e18); // PM returns this principal on decrease+collect

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        // position active, main tokenId updated to the freshly minted NFT, alt cleared
        LPAutoBalancerV2.ManagedPositionV2 memory p = lab.exposed_position();
        assertEq(p.mainTokenId, NEW_TOKEN_ID, "mainTokenId updated to new NFT");
        assertEq(p.altTokenId, 0, "alt cleared (Task 3 adds it)");
        assertTrue(p.active, "position stays active");

        // No-swap property is structural: the new position was rebuilt purely from the
        // withdrawn principal (mint consumed contract-held tokens; nothing was sold).
        // Old NFT burned exactly once.
        assertEq(mockPM.burnCallCount(), 1, "old main burned");
        assertEq(mockPM.lastBurnedTokenId(), TOKEN_ID, "wrong burned token");

        // Balanced principal => ~0 leftover, forwarded to feeCollector (no dust stranded).
        assertEq(tok0.balanceOf(address(lab)), 0, "no token0 dust");
        assertEq(tok1.balanceOf(address(lab)), 0, "no token1 dust");

        // lastRebalance stamped to the current block.
        assertEq(lab.exposed_position().lastRebalance, block.timestamp, "lastRebalance stamped");
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

        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "rebalanceUsingAlt completed with withdraw mins met");
    }

    // ─── rebalanceUsingAlt() — Task 3: single-sided alt mint from leftover ───────────────────

    /// @dev Read (mainTokenId, altTokenId, mainStaked) by name via the harness getter.
    function _readMainAlt() internal view returns (uint256 main, uint256 alt, bool mainStaked) {
        LPAutoBalancerV2.ManagedPositionV2 memory p = lab.exposed_position();
        return (p.mainTokenId, p.altTokenId, p.mainStaked);
    }

    /// @dev Read (mainStaked, altStaked) by name via the harness getter.
    function _readStakeFlags() internal view returns (bool mainStaked, bool altStaked) {
        LPAutoBalancerV2.ManagedPositionV2 memory p = lab.exposed_position();
        return (p.mainStaked, p.altStaked);
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
    LPAutoBalancerV2Harness dLab;
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

        dLab = new LPAutoBalancerV2Harness(admin, manager, rebalancer, guardian, address(dPM), address(mockAero));
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
        dPM.resetCollectCount();
    }

    /// @dev Read (mainTokenId, altTokenId, mainStaked) by name from the mixed-fixture balancer.
    function _readMixedMainAlt() internal view returns (uint256 main, uint256 alt, bool mainStaked) {
        LPAutoBalancerV2.ManagedPositionV2 memory p = dLab.exposed_position();
        return (p.mainTokenId, p.altTokenId, p.mainStaked);
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

    /// @notice Sherlock: the alt width is caller-supplied, not pinned to one tickSpacing. Same fixture
    ///         as above with altWidth = 2 spacings: the anchor stays put, the far bound moves.
    function test_mintAlt_usesCallerAltWidth() public {
        _setupMixed(500);
        _stageMixedPrincipal(1e5, 1e16);

        LPAutoBalancerV2.RebalanceParams memory params = _defaultRebalanceParams();
        params.altWidth = 400;
        vm.prank(rebalancer);
        dLab.rebalanceUsingAlt(params);

        (, uint256 altId,) = _readMixedMainAlt();
        assertEq(altId, D_ALT_ID, "alt minted");
        assertEq(dPM.lastMintTickLower(), OLD_TU, "anchor unchanged: lower == floor + spacing");
        assertEq(dPM.lastMintTickUpper(), OLD_TU + 400, "upper == lower + altWidth");
    }

    /// @notice altWidth must be a nonzero multiple of tickSpacing, else the alt bounds fall off the grid.
    function test_mintAlt_revertsOnMisalignedOrZeroAltWidth() public {
        _setupMixed(500);
        _stageMixedPrincipal(1e5, 1e16);

        LPAutoBalancerV2.RebalanceParams memory params = _defaultRebalanceParams();
        params.altWidth = 300; // spacing is 200
        vm.prank(rebalancer);
        vm.expectRevert(LPPositionLib.InvalidAltWidth.selector);
        dLab.rebalanceUsingAlt(params);

        params.altWidth = 0;
        vm.prank(rebalancer);
        vm.expectRevert(LPPositionLib.InvalidAltWidth.selector);
        dLab.rebalanceUsingAlt(params);
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
        dLab.rebalanceUsingAlt(_rebalanceParamsAt(200, 600));

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
        dLab.rebalanceUsingAlt(_rebalanceParamsAt(200, 600));
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
        dLab.rebalanceUsingAlt(_rebalanceParamsAt(200, 600));
    }

    /// @dev M-2. setGauge must reject when EITHER leg is staked. If a partial unstake ever leaves
    ///      mainStaked=false but altStaked=true, the alt NFT is still custodied by the OLD gauge;
    ///      changing the gauge would strand it. We reach mainStaked=false, altStaked=true (a state the
    ///      public API never produces directly): stake() sets BOTH true, then the harness clears
    ///      ONLY mainStaked via a named-field write. The OLD guard (mainStaked only)
    ///      would have let setGauge through here; the NEW guard (mainStaked || altStaked) reverts.
    function test_setGauge_revertsWhenAltStaked() public {
        _registerWithAlt(true); // gauge set + altTokenId injected
        vm.prank(rebalancer);
        lab.stake(); // sets mainStaked=true AND altStaked=true

        // Reach mainStaked=false / altStaked=true via the harness's named-field write — no packed-
        // word scanning or bit flipping — and read it back by name via exposed_position() below:
        // a struct reorder cannot silently corrupt this state on either side.
        lab.exposed_setStakedFlags(false, true);

        (bool mainStaked, bool altStaked) = _readStakeFlags();
        assertFalse(mainStaked, "main cleared (precondition)");
        assertTrue(altStaked, "alt still staked (precondition)");

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.PositionStaked.selector);
        lab.setGauge(makeAddr("newGauge"));
    }

    // ─── Task 4: stake/unstake/claimEmissions (dual-NFT) + exit() ────────────────

    /// @dev Register a gauged (or gaugeless) position and inject a non-zero altTokenId via the
    ///      harness (named-field write). This bypasses the _store() forced-zero for altTokenId so
    ///      tests can exercise the alt staking paths without running rebalanceUsingAlt().
    function _registerWithAlt(bool withGauge) internal {
        _register(withGauge);
        // Also register ALT_TOKEN_ID with the mock PM so ownerOf returns this contract's address.
        // (mockPM.ownerOf always returns mockOwner, so no extra setup needed.)
        lab.exposed_setAltTokenId(ALT_TOKEN_ID);
    }

    /// @dev Read active flag by name via the harness getter.
    function _readActive() internal view returns (bool active) {
        return lab.exposed_position().active;
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
        vm.prank(rebalancer);
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
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
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
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
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
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
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

        // Stamp lastRebalance via the harness (named-field write) so the cooldown is genuinely
        // active without simulating a prior rebalance.
        lab.exposed_setLastRebalance(block.timestamp);

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
    ///      (see test_rebalanceUsingAlt_revertsBeforeCooldown, which stamps it via the harness).
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
    ///      lastRebalance = now via the harness, so block.timestamp < lastRebalance +
    ///      interval and the Cooldown guard (checked before the deviation gate) fires.
    function test_rebalanceUsingAlt_revertsBeforeCooldown() public {
        _registerWithInterval(3600);
        // _store forces lastRebalance to 0; stamp it to "now" so the cooldown is genuinely active.
        lab.exposed_setLastRebalance(block.timestamp);
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
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector); // caller (this test contract) lacks REBALANCER_ROLE
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
        lab.rebalanceUsingAlt(_rebalanceParamsAt(200, 600));

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
        lab.rebalanceUsingAlt(_rebalanceParamsAt(-400, 0));

        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        // The new main must end at or below spot: range strictly below spot holds only token1.
        assertLe(s.mainTickUpper, SPOT_TICK, "token1-only: main range must end <= spotTick");
        assertGt(s.mainLiquidity, 0, "token1-only: main must have positive liquidity");
    }

    /// @dev When _mainRange returns a single-sided range, _mintBalanced must zero the UNFUNDED
    ///      leg's min before forwarding to the PM — mirroring _mintAlt. token0-only staging puts
    ///      the main strictly ABOVE spot (token0-funded), so a caller-supplied amount1MinMain
    ///      would spuriously revert the mint on the real position manager; the funded leg's
    ///      amount0MinMain must pass through untouched.
    function test_rebalanceUsingAlt_singleSidedMain_zeroesUnfundedLegMin() public {
        _register(false);
        _stagePrincipal(1e18, 0); // token0-only: single-sided branch, range above spot
        mockPM.setPosition(NEW_TOKEN_ID, 200, 600, NEW_LIQ, token0, token1);

        LPAutoBalancerV2.RebalanceParams memory params = _rebalanceParamsAt(200, 600);
        params.amount0MinMain = 123; // funded leg: forwarded as-is
        params.amount1MinMain = 456; // unfunded leg: must be zeroed, not forwarded

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(params);

        // Mint call 1 is the main. The unfunded (token1) min must arrive at the PM as 0.
        assertEq(mockPM.mintAmount0MinByCall(1), 123, "funded leg min must pass through");
        assertEq(mockPM.mintAmount1MinByCall(1), 0, "unfunded leg min must be zeroed");
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
        assertEq(lab.exposed_position().minWidth, 400, "minWidth == 2*tickSpacing accepted");
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

    /// @dev setGauge must enforce the same gauge->pool binding as _validateAndStore: an
    ///      AERO-rewarding gauge bound to a DIFFERENT pool would otherwise be stored and only
    ///      fail later, deep inside stake()/_restakeBoth.
    function test_setGauge_revertPoolMismatch() public {
        _register(false);
        MockCLGauge wrongPoolGauge = new MockCLGauge(address(mockAero)); // rewards AERO...
        wrongPoolGauge.setPool(makeAddr("otherPool")); // ...but is the gauge for another pool
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.PoolMismatch.selector);
        lab.setGauge(address(wrongPoolGauge));
    }

    /// @dev Widths are uint24 but downstream tick math casts them to int24, which bit-reinterprets
    ///      (not reverts) above int24.max. 8_388_800 > int24.max (8_388_607), yet is % 200 == 0 and
    ///      >= minWidth — it passes every pre-existing width check, so registration must bound it.
    function test_registerPosition_revertWidthOutOfBounds_maxWidthAboveInt24Max() public {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _baseConfig();
        cfg.maxWidth = 8_388_800;
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.WidthOutOfBounds.selector);
        lab.registerPosition(cfg);
    }

    /// @dev Same int24 bound on the post-registration config path — setPositionConfig and
    ///      _validateAndStore must enforce identical width invariants.
    function test_setPositionConfig_revertWidthOutOfBounds_maxWidthAboveInt24Max() public {
        _register(false);
        vm.prank(manager);
        vm.expectRevert(LPAutoBalancerV2.WidthOutOfBounds.selector);
        lab.setPositionConfig(400, 8_388_800, 400, 1800, 200, 100, 0);
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
        lab.rebalanceUsingAlt(_rebalanceParamsAt(200, 600)); // must NOT revert StaleOracle

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
        dLab.rebalanceUsingAlt(_rebalanceParamsAt(200, 600));

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

        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "mainTokenId updated after setPool");
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
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
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
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        lab.setSwapLossAllowanceBps(100);
    }

    function test_swapRebalance_stateDefaults() public view {
        assertFalse(lab.rebalanceInFlight());
        (uint256 cA0, uint256 cA1, uint256 cL0, uint256 cL1) = lab.rebalanceAmountsBefore();
        assertEq(cA0 + cA1 + cL0 + cL1, 0, "snapshot wiped");
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

    /// @dev Regression for a whole-feature-review finding: mid-flight, position.mainTokenId/altTokenId
    ///      point at NFTs unwindForSwap already burned. getDecisionSnapshot() must skip the
    ///      POSITION_MANAGER.positions() reads entirely while in flight (they'd revert against the
    ///      real position manager on a burned tokenId) rather than reverting the whole view — the
    ///      off-chain agent needs this exact view to observe rebalanceInFlight and know to wait/rebuild.
    ///      The mock PM doesn't delete burned positions, so it can't reproduce the real revert; this
    ///      test only proves the geometry fields are left at their zero default (i.e. the read was
    ///      skipped, not that stale mock data happened to still resolve) — the fork suite proves the
    ///      call is genuinely revert-free against the real position manager.
    function test_getDecisionSnapshot_callableMidFlight_skipsPositionReads() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertTrue(s.rebalanceInFlight);
        assertGt(s.rebalanceStartedAt, 0);
        assertEq(s.mainTickLower, 0, "position geometry skipped while in flight");
        assertEq(s.mainTickUpper, 0, "position geometry skipped while in flight");
        assertEq(s.mainLiquidity, 0, "position geometry skipped while in flight");
        assertFalse(s.hasAlt);
        assertEq(s.earnedAero, 0, "gauge reads skipped while in flight");
    }

    /// @dev Same in-flight window as above, sibling entry point: collectFees is PERMISSIONLESS and
    ///      p.mainStaked is already false mid-flight, so without a guard it would call
    ///      POSITION_MANAGER.collect() on a burned tokenId — a deep revert on the real PM (the mock
    ///      PM doesn't delete burned positions, so this asserts the fail-fast guard instead).
    function test_collectFees_revertsMidFlight() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        vm.expectRevert(LPAutoBalancerV2.AlreadyInFlight.selector);
        lab.collectFees();
    }

    // ---------- swap-rebalance fixtures ----------

    LPCompoundModule realModule;

    function _setRealModule() internal {
        realModule = new LPCompoundModule(address(lab), address(mockAero), admin);
        vm.prank(admin);
        lab.setCompoundModule(address(realModule));
    }

    function _defaultUnwindParams() internal view returns (LPAutoBalancerV2.UnwindParams memory) {
        return LPAutoBalancerV2.UnwindParams({
            sellToken: token0,
            sellAmount: 5e17,
            amount0MinWithdraw: 0,
            amount1MinWithdraw: 0,
            amount0MinWithdrawAlt: 0,
            amount1MinWithdrawAlt: 0,
            deadline: block.timestamp + 1
        });
    }

    // ---------- unwindForSwap ----------

    function test_unwindForSwap_happyPath_teardownApprovalFlagSnapshot() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);

        vm.expectEmit(true, true, true, true);
        emit LPAutoBalancerV2.RebalanceUnwound(token0, 5e17);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        // teardown happened: old NFT burned, principal loose on the balancer
        assertEq(mockPM.burnCallCount(), 1);
        assertEq(mockPM.lastBurnedTokenId(), TOKEN_ID);
        assertEq(tok0.balanceOf(address(lab)), 1e18);
        assertEq(tok1.balanceOf(address(lab)), 1e18);

        // no mint in phase 1, and the burned ids are CLEARED (MOO-743) rather than left dangling
        // for the whole in-flight window.
        assertEq(lab.exposed_position().mainTokenId, 0, "burned mainTokenId cleared by _exitAll");
        assertEq(lab.exposed_position().altTokenId, 0, "burned altTokenId cleared by _exitAll");

        // approval + in-flight state
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 5e17);
        assertTrue(lab.rebalanceInFlight());
        assertEq(lab.sellTokenInFlight(), token0);
        assertEq(lab.rebalanceStartedAt(), block.timestamp);
        (uint256 snapA0, uint256 snapA1,,) = lab.rebalanceAmountsBefore();
        assertGt(snapA0 + snapA1, 0, "amount snapshot captured");
        assertFalse(lab.rebalanceWasStaked());

        // snapshot view reflects in-flight
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertTrue(s.rebalanceInFlight);
        assertEq(s.rebalanceStartedAt, block.timestamp);
    }

    function test_unwindForSwap_recordsWasStaked() public {
        _register(true); // gauge configured; _register does NOT stake, so stake explicitly:
        vm.prank(rebalancer);
        lab.stake();
        _setRealModule();
        _stagePrincipal(1e18, 1e18);

        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());
        assertTrue(lab.rebalanceWasStaked());
    }

    function test_unwindForSwap_revertsNotActive() public {
        _setRealModule();
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NotActive.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsAlreadyInFlight() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.AlreadyInFlight.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsOnCooldown() public {
        _registerWithInterval(3600); // default config's minRebalanceInterval is 0 (no gate); use a real interval
        _setRealModule();
        // _store forces lastRebalance to 0; stamp it to "now" so the cooldown is genuinely active
        // (harness named-field write, same pattern as test_rebalanceUsingAlt_revertsBeforeCooldown).
        lab.exposed_setLastRebalance(block.timestamp);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.Cooldown.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsOnTwapDeviation() public {
        _register(false);
        _setRealModule();
        // push spot far from twap=0 using the pool mock's real setter (setSlot0), matching the
        // existing TWAP-deviation test convention in this file.
        mockPool.setSlot0(SQRT_P, 5000);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.TwapDeviation.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsBadSellToken() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        LPAutoBalancerV2.UnwindParams memory u = _defaultUnwindParams();
        u.sellToken = address(mockAero);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.InvalidSellToken.selector);
        lab.unwindForSwap(u);
    }

    function test_unwindForSwap_revertsZeroSellAmount() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        LPAutoBalancerV2.UnwindParams memory u = _defaultUnwindParams();
        u.sellAmount = 0;

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.InvalidSellToken.selector);
        lab.unwindForSwap(u);
    }

    function test_unwindForSwap_revertsModuleNotSet() public {
        _register(false); // no module set
        _stagePrincipal(1e18, 1e18);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.ModuleNotSet.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsWhenPaused() public {
        _register(false);
        _setRealModule();
        vm.prank(guardian);
        lab.pause();

        vm.prank(rebalancer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsNonRebalancer() public {
        _register(false);
        _setRealModule();
        vm.prank(manager);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    // ---------- rebuildAfterSwap ----------

    function _unwind() internal {
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_rebuildAfterSwap_happyPath_afterSimulatedSettlement() public {
        _register(false);
        _setRealModule();
        _unwind();

        // simulate CowSwap settlement: relayer pulls 5e17 tok0, delivers tok1 — this leaves the
        // contract imbalanced (5e17 tok0 / 1.5e18 tok1), so a real (non-dust) alt gets minted from
        // the leftover, same as rebalanceUsingAlt's imbalanced-input case.
        vm.prank(address(lab));
        tok0.transfer(makeAddr("solver"), 5e17);
        tok1.mint(address(lab), 5e17);
        mockPM.setNextAltMintResult(ALT_TOKEN_ID, 5e17);

        vm.expectEmit(true, true, true, true);
        emit LPAutoBalancerV2.RebalanceRebuilt(NEW_TOKEN_ID, ALT_TOKEN_ID);
        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebuildParams());

        LPAutoBalancerV2.ManagedPositionV2 memory p = lab.exposed_position();
        assertEq(p.mainTokenId, NEW_TOKEN_ID, "new main minted");
        assertEq(p.altTokenId, ALT_TOKEN_ID, "surplus leg minted as alt");
        assertTrue(p.active);
        assertEq(p.lastRebalance, block.timestamp, "cooldown stamped at rebuild");

        // in-flight state fully cleared + approval revoked
        assertFalse(lab.rebalanceInFlight());
        (uint256 cA0, uint256 cA1, uint256 cL0, uint256 cL1) = lab.rebalanceAmountsBefore();
        assertEq(cA0 + cA1 + cL0 + cL1, 0, "snapshot wiped");
        assertEq(lab.sellTokenInFlight(), address(0));
        assertFalse(lab.rebalanceWasStaked());
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 0, "relayer approval revoked");
    }

    function test_rebuildAfterSwap_unfilledOrder_matchesNoSwapOutcome() public {
        _register(false);
        _setRealModule();
        _unwind();
        // order expired unfilled: balances unchanged (1e18 / 1e18 loose)

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebuildParams());

        assertEq(
            lab.exposed_position().mainTokenId,
            NEW_TOKEN_ID,
            "rebuilt from original balances, identical to rebalanceUsingAlt outcome"
        );
        assertFalse(lab.rebalanceInFlight());
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 0, "stale approval revoked");
    }

    function test_rebuildAfterSwap_restakesWhenWasStaked() public {
        _register(true);
        vm.prank(rebalancer);
        lab.stake(); // _register does NOT stake — stake explicitly
        _setRealModule();
        _unwind();
        assertTrue(lab.rebalanceWasStaked());

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebuildParams());

        assertTrue(lab.exposed_position().mainStaked, "restaked after rebuild");
        assertFalse(lab.rebalanceWasStaked(), "flag cleared");
    }

    function test_rebuildAfterSwap_revertsNotInFlight() public {
        _register(false);
        _setRealModule();
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NotInFlight.selector);
        lab.rebuildAfterSwap(_defaultRebuildParams());
    }

    function test_rebuildAfterSwap_revertsOnValueFloorBreach() public {
        _register(false);
        _setRealModule();
        _unwind();

        // Force the rebuilt main's mocked liquidity/value to zero (same technique the dedicated
        // rebalanceUsingAlt ValueFloor tests use), then drain nearly all loose principal, to
        // simulate a genuine catastrophic loss rather than relying on the mock's fixed principal
        // value (which ignores actual mint amounts).
        mockPM.setNextMintResult(NEW_TOKEN_ID, 0);
        mockPM.setPosition(NEW_TOKEN_ID, OLD_TL, OLD_TU, 0, token0, token1);
        vm.startPrank(address(lab));
        tok0.transfer(makeAddr("solver"), 1e18 - 1);
        tok1.transfer(makeAddr("solver"), 1e18 - 1);
        vm.stopPrank();

        // 1 wei of each leg is far below MIN_MAIN_LEG_USD, so _mainRange takes the SINGLE-SIDED
        // token0 branch: floor(100, 200) = 0, up = 200, range [200, 200 + width] = [200, 600].
        // Commit to that range so the floor — not the tick check — is what reverts.
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.ValueFloor.selector);
        lab.rebuildAfterSwap(_rebuildParamsAt(200, 600));
        assertTrue(lab.rebalanceInFlight(), "still in flight; can retry or exit");
    }

    // ---------- exit() mid-flight (Task 7) ----------

    function test_exit_midFlight_sweepsAndClearsState_noDoubleTeardown() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        assertTrue(lab.rebalanceInFlight());
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 5e17);
        uint256 burnCountBeforeExit = mockPM.burnCallCount();

        address to = makeAddr("exitRecipient");
        vm.prank(admin);
        lab.exit(to); // must NOT revert — this is the whole point of this test

        // no double-teardown: burn count unchanged (unwindForSwap already burned once; exit()
        // must not attempt to burn the same (already-burned) tokenId again)
        assertEq(mockPM.burnCallCount(), burnCountBeforeExit, "exit() did not re-run _exitAll mid-flight");

        // in-flight state fully cleared + approval revoked
        assertFalse(lab.rebalanceInFlight());
        (uint256 cA0, uint256 cA1, uint256 cL0, uint256 cL1) = lab.rebalanceAmountsBefore();
        assertEq(cA0 + cA1 + cL0 + cL1, 0, "snapshot wiped");
        assertEq(lab.sellTokenInFlight(), address(0));
        assertFalse(lab.rebalanceWasStaked());
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 0, "relayer approval revoked");

        // principal swept to recipient, position deactivated
        assertEq(tok0.balanceOf(to), 1e18);
        assertEq(tok1.balanceOf(to), 1e18);
        LPAutoBalancerV2.ManagedPositionV2 memory p = lab.exposed_position();
        assertEq(p.mainTokenId, 0, "mainTokenId zeroed");
        assertEq(p.altTokenId, 0, "altTokenId zeroed");
        assertFalse(p.active);
    }

    function test_exit_midFlight_sweepsPartialSettlementProceeds() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        // simulate a partial/odd settlement state: some tok0 left the contract (pulled by the
        // relayer), some tok1 arrived (delivered by a solver) — exit() must sweep whatever is
        // actually there, not assume the pre-unwind amounts.
        vm.prank(address(lab));
        tok0.transfer(makeAddr("solver"), 2e17);
        tok1.mint(address(lab), 3e17);

        address to = makeAddr("exitRecipient2");
        vm.prank(admin);
        lab.exit(to);

        assertEq(tok0.balanceOf(to), 1e18 - 2e17, "swept actual current tok0 balance");
        assertEq(tok1.balanceOf(to), 1e18 + 3e17, "swept actual current tok1 balance");
    }

    function test_rebuildAfterSwap_lossWithinAllowancePasses() public {
        vm.prank(admin);
        lab.setSwapLossAllowanceBps(500); // default maxRebalanceLossBps is 100 (1%); +500 = 6% tolerance
        _register(false);
        _setRealModule();
        _unwind();

        // small loss: 2% of tok0 gone — within maxRebalanceLossBps(1%) + allowance(5%) = 6%
        vm.prank(address(lab));
        tok0.transfer(makeAddr("solver"), 2e16);

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebuildParams());
        assertFalse(lab.rebalanceInFlight());
    }

    function test_rebuildAfterSwap_looseBalance_notHaircut_matchesRebalanceUsingAltPattern() public {
        _register(false);
        _setRealModule();
        // Donate a loose balance BEFORE unwinding — simulates un-folded AERO-compound proceeds
        // already sitting on the contract when unwindForSwap runs.
        tok0.mint(address(lab), 5e17);

        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        // The POSITION term must hold only the staged 1e18/1e18 principal, and the LOOSE term only
        // the 5e17 donation — the two are tracked separately so the haircut can apply to the
        // position alone (H-1). Exact amounts, not just ordering.
        (uint256 a0, uint256 a1, uint256 l0, uint256 l1) = lab.rebalanceAmountsBefore();
        assertEq(l0, 5e17, "loose token0 snapshotted separately from principal");
        assertEq(l1, 0, "no loose token1 was donated");
        assertGt(a0 + a1, 0, "position principal snapshotted");
        // The old main is [-200, 200] with liquidity 1e18 at sqrtP(tick 0); whatever amounts that
        // implies, the donation is NOT part of them.
        assertTrue(a0 != 5e17 || a1 != 0, "position term is not the donation");
    }

    function test_rebuildAfterSwap_revertsOnTwapDeviation() public {
        _register(false);
        _setRealModule();
        _unwind();
        mockPool.setSlot0(SQRT_P, 5000); // same setter/convention as the unwindForSwap TWAP test

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.TwapDeviation.selector);
        lab.rebuildAfterSwap(_defaultRebuildParams());
    }

    function test_rebuildAfterSwap_noCooldownGate() public {
        _register(false);
        _setRealModule();
        _unwind();
        // do NOT warp past minRebalanceInterval — rebuild must still work
        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebuildParams());
        assertFalse(lab.rebalanceInFlight());
    }

    function test_rebuildAfterSwap_revertsWhenPaused() public {
        _register(false);
        _setRealModule();
        _unwind();
        vm.prank(guardian);
        lab.pause();

        vm.prank(rebalancer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lab.rebuildAfterSwap(_defaultRebuildParams());
    }

    function test_rebuildAfterSwap_revertsNonRebalancer() public {
        _register(false);
        _setRealModule();
        _unwind();
        vm.prank(manager);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        lab.rebuildAfterSwap(_defaultRebuildParams());
    }

    function test_isValidSignature_delegatesToModule() public {
        _register(false);
        address mockModule = makeAddr("mockModule");
        vm.prank(admin);
        lab.setCompoundModule(mockModule);
        bytes32 digest = bytes32(uint256(123));
        bytes memory order = hex"deadbeef";
        vm.mockCall(
            mockModule,
            abi.encodeWithSignature("validateRebalanceOrder(bytes32,bytes)", digest, order),
            abi.encode(bytes4(0x1626ba7e))
        );

        // vm.expectCall pins the EXACT calldata the passthrough forwards — proves digest/order are
        // relayed unmodified, not just that SOME call to compoundModule returns SOMETHING.
        vm.expectCall(mockModule, abi.encodeWithSignature("validateRebalanceOrder(bytes32,bytes)", digest, order));
        bytes4 v = lab.isValidSignature(digest, order);
        assertEq(v, bytes4(0x1626ba7e));
    }

    function test_isValidSignature_interfaceSelectorMatchesModule() public pure {
        // Guards against the local ILPCompoundModuleRebalance interface drifting out of sync with
        // LPCompoundModule's real signature (nothing else enforces this at compile time).
        assertEq(
            ILPCompoundModuleRebalance.validateRebalanceOrder.selector, LPCompoundModule.validateRebalanceOrder.selector
        );
    }

    // ---------- per-call width alignment ----------
    // Config minWidth/maxWidth are enforced to be spacing multiples, but the per-call width is
    // caller-supplied: 500 is inside [400, 2000] yet 500 % 200 != 0, so without the alignment
    // check the mint would only revert deep inside the pool (tick-not-spaced) after teardown.

    function test_rebalanceUsingAlt_revertsUnalignedWidth() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);
        LPAutoBalancerV2.RebalanceParams memory params = _defaultRebalanceParams();
        params.width = 500;

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.InvalidWidth.selector);
        lab.rebalanceUsingAlt(params);
    }

    function test_rebuildAfterSwap_revertsUnalignedWidth() public {
        _register(false);
        _setRealModule();
        _unwind();
        LPAutoBalancerV2.RebuildParams memory params = _defaultRebuildParams();
        params.width = 500;

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.InvalidWidth.selector);
        lab.rebuildAfterSwap(params);
    }

    // ---------- MOO-727 follow-up: width must be an EVEN multiple of tickSpacing ----------
    // A width that is a spacing multiple but an ODD one (600 = 3 * 200 here) leaves the balanced
    // main's spot preimage TWO spacings wide: `alignedRange` floors `spot - width/2` and width/2 is
    // then half a spacing off the grid, so two different spots produce the SAME main range while
    // `floorAlign(spot)` — the anchor `_mintAlt` places the alt from — differs by a full spacing.
    // The tick commitment names only the main bounds, so TickMismatch stays silent and the alt
    // slides. Requiring an even multiple makes `floorAlign(spot) = tickLower + width/2` a function
    // of the committed bounds, which pins the alt transitively. See the TICK COMMITMENT natspec on
    // rebuildAfterSwap and `LPPositionLib.validateRebalanceConfig`.
    //
    // 600 is inside the fixture's [400, 2000] band and IS a multiple of tickSpacing (200), so the
    // pre-fix code accepted it — these four tests fail against the previous revision.

    function test_rebalanceUsingAlt_revertsOddMultipleWidth() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);
        LPAutoBalancerV2.RebalanceParams memory params = _defaultRebalanceParams();
        params.width = 600; // 3 * tickSpacing: aligned, but an ODD multiple

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.InvalidWidth.selector);
        lab.rebalanceUsingAlt(params);
    }

    function test_rebuildAfterSwap_revertsOddMultipleWidth() public {
        _register(false);
        _setRealModule();
        _unwind();
        LPAutoBalancerV2.RebuildParams memory params = _defaultRebuildParams();
        params.width = 600; // 3 * tickSpacing: aligned, but an ODD multiple

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.InvalidWidth.selector);
        lab.rebuildAfterSwap(params);
    }

    /// @dev The config bounds carry the same rule, so an operator learns at registration time rather
    ///      than discovering a whole band of widths is unusable on the next rebalance.
    function test_registerPosition_revertsOddMultipleMinWidth() public {
        LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
        cfg.minWidth = 600; // >= 2*tickSpacing and spacing-aligned, but an ODD multiple

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.InvalidWidth.selector);
        lab.registerPosition(cfg);
    }

    function test_setPositionConfig_revertsOddMultipleMaxWidth() public {
        _register(false);

        vm.prank(manager);
        vm.expectRevert(LPAutoBalancerV2.InvalidWidth.selector);
        // maxWidth 2200 = 11 * tickSpacing — spacing-aligned, odd multiple.
        lab.setPositionConfig(400, 2200, 400, 1800, 200, 100, 0);
    }

    /// @dev The tightest legal width (minWidth == 2 * tickSpacing) is by construction an EVEN
    ///      multiple, so the new rule can never make a config uninhabitable. Pins that the fix did
    ///      not narrow the usable band from below.
    function test_rebalanceUsingAlt_acceptsMinWidthUnderEvenMultipleRule() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);
        LPAutoBalancerV2.RebalanceParams memory params = _defaultRebalanceParams();
        params.width = 400; // == minWidth == 2 * tickSpacing

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(params); // must NOT revert
    }

    // The geometric property the rule buys — the committed main bounds determine floorAlign(spot),
    // i.e. the alt anchor — is pinned in LPGeometryLib.unit.t.sol
    // (testFuzz_alignedRange_evenMultipleWidthPinsFloorAlign and its odd-multiple counterexample).

    // ---------- unwindForSwap with a live alt leg ----------
    // Realistic cycle-N+1 state: a prior rebalanceUsingAlt left an alt NFT and the backend now
    // chooses the swap path. Phase 1 must tear down BOTH legs and count the alt in the snapshot.

    /// @dev Register with a live alt whose range [200,400] sits above spot, holding only token0.
    function _registerWithLiveAlt() internal {
        _register(false);
        lab.exposed_setAltTokenId(ALT_TOKEN_ID);
        mockPM.setPosition(ALT_TOKEN_ID, OLD_TU, OLD_TU + 200, NEW_LIQ, token0, token1);
    }

    function test_unwindForSwap_withLiveAlt_tearsDownBothAndSnapshotsAltValue() public {
        _registerWithLiveAlt();
        _setRealModule();
        // Zero the MAIN's liquidity so the snapshot's position term can only come from the ALT —
        // proving the alt leg is counted, without reproducing the geometry math in the test.
        mockPM.setPosition(TOKEN_ID, OLD_TL, OLD_TU, 0, token0, token1);
        _stagePrincipal(1e18, 1e18);
        // Three slot-1 collects transfer tokens out of the PM here (alt fee skim, main principal
        // collect — the mock pays slot-1 amounts even for the liq-0 main — and alt principal
        // collect); _stagePrincipal funded one, so top the PM up for the other two.
        tok0.mint(address(mockPM), 2e18);
        tok1.mint(address(mockPM), 2e18);

        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        assertTrue(mockPM.wasBurned(TOKEN_ID), "main burned");
        assertTrue(mockPM.wasBurned(ALT_TOKEN_ID), "alt burned");
        assertEq(mockPM.burnCallCount(), 2);
        (uint256 altA0, uint256 altA1,,) = lab.rebalanceAmountsBefore();
        assertGt(altA0 + altA1, 0, "alt principal counted in the unwind snapshot");
        assertTrue(lab.rebalanceInFlight());
    }

    function test_unwindForSwap_altWithdrawMinEnforced() public {
        _registerWithLiveAlt();
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        tok0.mint(address(mockPM), 1e18);
        tok1.mint(address(mockPM), 1e18);

        // Main mins 0 (its decrease passes); alt min above the staged withdraw. The main decrease
        // runs FIRST, so the revert proves the alt mins are threaded to the ALT decrease.
        LPAutoBalancerV2.UnwindParams memory params = _defaultUnwindParams();
        params.amount0MinWithdrawAlt = 2e18;

        vm.prank(rebalancer);
        vm.expectRevert(bytes("Price slippage check"));
        lab.unwindForSwap(params);
    }

    // ---------- pause interactions ----------

    function test_exit_succeedsWhilePaused_midFlight() public {
        // The runbook's documented escape hatch: guardian pauses mid-flight, and the admin's
        // exit() — deliberately NOT whenNotPaused — is the only way to recover unwound principal.
        _register(false);
        _setRealModule();
        _unwind();
        vm.prank(guardian);
        lab.pause();

        address safe = makeAddr("safeExit");
        vm.prank(admin);
        lab.exit(safe);

        assertFalse(lab.rebalanceInFlight(), "in-flight window closed");
        assertEq(lab.sellTokenInFlight(), address(0), "sell token cleared");
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 0, "relayer approval revoked");
        assertEq(tok0.balanceOf(safe), 1e18, "principal token0 recovered while paused");
        assertEq(tok1.balanceOf(safe), 1e18, "principal token1 recovered while paused");
        assertFalse(_readActive(), "position deactivated");
    }

    function test_unpause_restoresRebalance() public {
        _register(false);
        vm.prank(guardian);
        lab.pause();

        vm.prank(rebalancer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        vm.prank(guardian);
        lab.unpause();

        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "rebalance ran after unpause");
    }

    // ---------- admin / lifecycle surface ----------

    function test_deregisterPosition_transfersBothNftsAndDeactivates() public {
        _registerWithAlt(false);
        address to = makeAddr("deregisterTo");

        vm.prank(admin);
        lab.deregisterPosition(to);

        assertFalse(_readActive(), "deactivated");
        assertEq(mockPM.transferCallCount(), 2, "both NFTs transferred");
        assertEq(mockPM.lastTo(), to);
        // NFT ids are NOT zeroed by deregister (only exit() zeroes them), so setPool stays
        // blocked and re-pointing goes through registerPosition — asserted here so the
        // documented asymmetry (spec 3.7) does not silently change.
        LPAutoBalancerV2.ManagedPositionV2 memory p = lab.exposed_position();
        assertEq(p.mainTokenId, TOKEN_ID, "main id kept");
        assertEq(p.altTokenId, ALT_TOKEN_ID, "alt id kept");
    }

    function test_deregisterPosition_revertsNotActive() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.NotActive.selector);
        lab.deregisterPosition(makeAddr("to"));
    }

    function test_deregisterPosition_revertsZeroAddress() public {
        _register(false);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        lab.deregisterPosition(address(0));
    }

    function test_deregisterPosition_revertsWhenStaked() public {
        _register(true);
        vm.prank(rebalancer);
        lab.stake();

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.PositionStaked.selector);
        lab.deregisterPosition(makeAddr("to"));
    }

    function test_withdrawPosition_autoUnstakesAndTransfersBoth() public {
        _registerWithAlt(true);
        vm.prank(rebalancer);
        lab.stake();
        address to = makeAddr("withdrawTo");

        vm.prank(admin);
        lab.withdrawPosition(to);

        assertFalse(_readActive(), "deactivated");
        (bool mainStaked, bool altStaked) = _readStakeFlags();
        assertFalse(mainStaked, "main auto-unstaked");
        assertFalse(altStaked, "alt auto-unstaked");
        assertEq(mockPM.lastTo(), to, "NFTs sent to recipient");
    }

    function test_setFeeCollector_updates() public {
        _register(false);
        address newCollector = makeAddr("newCollector");
        vm.prank(admin);
        lab.setFeeCollector(newCollector);
        assertEq(lab.exposed_position().feeCollector, newCollector);
    }

    function test_setFeeCollector_revertsZeroAddress() public {
        _register(false);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        lab.setFeeCollector(address(0));
    }

    function test_setOracles_updatesAndProbes() public {
        _register(false);
        address newOracle0 = address(new MockPriceFeed(2e8, 8, block.timestamp));
        address newOracle1 = address(new MockPriceFeed(3e8, 8, block.timestamp));

        vm.prank(admin);
        lab.setOracles(newOracle0, newOracle1);
        LPAutoBalancerV2.ManagedPositionV2 memory p = lab.exposed_position();
        assertEq(p.oracle0, newOracle0);
        assertEq(p.oracle1, newOracle1);
    }

    function test_setOracles_revertsZeroOracle() public {
        _register(false);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.OracleRequired.selector);
        lab.setOracles(address(0), oracle1);
    }

    function test_setOracles_revertsOnStaleFeedProbe() public {
        _register(false);
        // Probe must fail in the admin tx, not on the next rebalance: a feed older than the armed
        // per-feed bound (DEFAULT_MAX_ORACLE_DELAY, 1 hour, since this fixture never calls the
        // setter) reverts StaleOracle at set time. The 27h warp below clears it by a wide margin.
        address staleFeed = address(new MockPriceFeed(1e8, 8, block.timestamp));
        vm.warp(block.timestamp + 27 hours);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.StaleOracle.selector);
        lab.setOracles(staleFeed, oracle1);
    }

    /// @dev MOO-740, the part that actually ships: the value seeded by the CONSTRUCTOR is the bound
    ///      that protects a deployment whose setup proposal forgets to tighten it. Splitting one
    ///      loose bound into two loose bounds changes no on-chain state, so the default is asserted
    ///      here directly rather than only through the setter.
    function test_constructor_seedsTightOracleDelayDefaults() public view {
        assertEq(lab.maxOracleDelay0(), lab.DEFAULT_MAX_ORACLE_DELAY(), "oracle0 default");
        assertEq(lab.maxOracleDelay1(), lab.DEFAULT_MAX_ORACLE_DELAY(), "oracle1 default");
        // 3x the ~20-minute heartbeat of the feeds this contract is built for — a real bound, not a
        // day-scale placeholder that accepts answers dozens of heartbeats past their validity.
        assertEq(lab.DEFAULT_MAX_ORACLE_DELAY(), 1 hours, "default is heartbeat-scaled");
        assertTrue(lab.DEFAULT_MAX_ORACLE_DELAY() <= lab.MAX_ORACLE_DELAY(), "default within cap");
    }

    /// @dev MOO-740: each feed gets its own bound. Admin control is not dropped — it is widened.
    function test_setMaxOracleDelays_perFeed() public {
        vm.prank(admin);
        lab.setMaxOracleDelays(20 minutes, 12 hours);
        assertEq(lab.maxOracleDelay0(), 20 minutes);
        assertEq(lab.maxOracleDelay1(), 12 hours);
    }

    function test_setMaxOracleDelays_revertsOutOfBounds() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.InvalidConfig.selector);
        lab.setMaxOracleDelays(0, 1 hours);

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.InvalidConfig.selector);
        lab.setMaxOracleDelays(1 hours, 0);

        // The cap is a DAY, not a week. A 7-day staleness bound on a 20-minute feed validates under
        // the old ceiling while being economically indistinguishable from no bound at all.
        // `overCap` is HOISTED deliberately: a call in ARGUMENT position is evaluated first and
        // would consume the armed one-shot expectRevert, so the real call would run unguarded.
        uint256 overCap = lab.MAX_ORACLE_DELAY() + 1;

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.InvalidConfig.selector);
        lab.setMaxOracleDelays(overCap, 1 hours);

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.InvalidConfig.selector);
        lab.setMaxOracleDelays(1 hours, overCap);

        assertEq(lab.MAX_ORACLE_DELAY(), 1 days, "cap is one day");
    }

    function test_setMaxOracleDelays_revertsNonAdmin() public {
        vm.prank(rebalancer);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        lab.setMaxOracleDelays(1 hours, 1 hours);
    }

    /// @dev MOO-740 end-to-end through the balancer, asserted against the bound that actually SHIPS.
    ///      token0's feed is 2 hours stale while token1's is fresh. The finding was that one loose
    ///      shared bound lets the rebalance proceed on a stale leg — and `_mainRange`/`_mintAlt` both
    ///      pick a SIDE from a value0-vs-value1 comparison, so a stale leg puts principal on the
    ///      wrong side of the market. This asserts the DEFAULT configuration rejects it: no setter
    ///      call, no proposal, nothing but a freshly constructed balancer.
    function test_rebalanceUsingAlt_perFeedDelay_rejectsStaleLeg() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);
        // Age ONLY oracle0 (the shared fixture's feeds are separate MockPriceFeed instances).
        MockPriceFeed(oracle0).setUpdatedAt(block.timestamp - 2 hours);

        // Shipped default (1h) already fails closed on the 2h-old leg — no admin action required.
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.StaleOracle.selector);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        // Per-feed independence, in the direction that proves the split is real: widen ONLY token0
        // past the feed's age and the same call proceeds, while token1 keeps its own tight bound.
        vm.prank(admin);
        lab.setMaxOracleDelays(6 hours, 20 minutes);
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "widened oracle0 bound accepts the 2h-old feed");

        // And the mirror: age token1 instead: its own 20-minute bound rejects it while oracle0's
        // 6-hour bound is untouched, so neither leg can hide behind the other's tolerance.
        MockPriceFeed(oracle1).setUpdatedAt(block.timestamp - 2 hours);
        _stagePrincipal(1e18, 1e18);
        mockPM.setPosition(NEW_TOKEN_ID, OLD_TL, OLD_TU, NEW_LIQ, token0, token1);
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.StaleOracle.selector);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
    }

    // ─── MOO-741: sequencer uptime guard wiring ──────────────────────────────

    function test_setSequencerUptimeFeed_wiresGuard_andBlocksWhileDown() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);

        LPSequencerFeedMock seq = new LPSequencerFeedMock(0, block.timestamp - 2 hours); // up, well past grace
        vm.prank(admin);
        lab.setSequencerUptimeFeed(address(seq), 1 hours);
        assertEq(lab.sequencerUptimeFeed(), address(seq));
        assertEq(lab.sequencerGracePeriod(), 1 hours);

        // Sequencer goes down: every valuation path fails closed, so no rebalance can run against
        // reports that may pre-date the outage.
        seq.set(1, block.timestamp);
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.SequencerDown.selector);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        // Back up, but inside the grace window — the feeds' own updatedAt is untouched and would
        // pass every freshness check, which is exactly the hole this closes.
        seq.set(0, block.timestamp - 30 minutes);
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.SequencerGracePeriod.selector);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        // Past the grace period: normal operation resumes.
        seq.set(0, block.timestamp - 2 hours);
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());
        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "rebalance resumes after grace");
    }

    function test_setSequencerUptimeFeed_rejectsZeroGrace_andProbesFeed() public {
        LPSequencerFeedMock seq = new LPSequencerFeedMock(0, block.timestamp - 2 hours);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.InvalidConfig.selector);
        lab.setSequencerUptimeFeed(address(seq), 0);

        // A DOWN sequencer fails in the admin tx (probe), not silently later.
        LPSequencerFeedMock down = new LPSequencerFeedMock(1, block.timestamp);
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.SequencerDown.selector);
        lab.setSequencerUptimeFeed(address(down), 1 hours);

        // address(0) clears the guard and needs no grace period.
        vm.prank(admin);
        lab.setSequencerUptimeFeed(address(0), 0);
        assertEq(lab.sequencerUptimeFeed(), address(0));
    }

    function test_setSequencerUptimeFeed_revertsNonAdmin() public {
        vm.prank(rebalancer);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        lab.setSequencerUptimeFeed(makeAddr("seq"), 1 hours);
    }

    function test_recoverERC20_sweepsToRecipient() public {
        address to = makeAddr("recoverTo");
        tok0.mint(address(lab), 5e17);

        vm.prank(admin);
        lab.recoverERC20(token0, to, 5e17);
        assertEq(tok0.balanceOf(to), 5e17);
    }

    function test_recoverERC20_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.ZeroAddress.selector);
        lab.recoverERC20(token0, address(0), 1);
    }

    function test_recoverETH_sweepsFullBalance() public {
        address payable to = payable(makeAddr("ethTo"));
        vm.deal(address(lab), 1 ether);

        vm.prank(admin);
        lab.recoverETH(to);
        assertEq(to.balance, 1 ether);
        assertEq(address(lab).balance, 0);
    }

    function test_onERC721Received_rejectsNonPositionManager() public {
        vm.expectRevert(LPAutoBalancerV2.NotPositionManager.selector);
        lab.onERC721Received(address(this), address(this), 1, "");
    }

    function test_stake_revertsNoGauge() public {
        _register(false); // no gauge configured
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NoGauge.selector);
        lab.stake();
    }

    function test_stake_revertsAlreadyStaked() public {
        _register(true);
        vm.prank(rebalancer);
        lab.stake();

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.AlreadyStaked.selector);
        lab.stake();
    }

    function test_stake_revertsNotActive() public {
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NotActive.selector);
        lab.stake();
    }

    function test_unstake_revertsNotStaked() public {
        _register(true);
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NotStaked.selector);
        lab.unstake();
    }

    function test_claimEmissions_revertsNotActive() public {
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NotActive.selector);
        lab.claimEmissions();
    }

    function test_claimEmissions_revertsNotStaked() public {
        _register(true); // registered but never staked
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NotStaked.selector);
        lab.claimEmissions();
    }

    /// @dev MOO-729. claimEmissions() routes 100% of the gauge's pending AERO to the feeCollector,
    ///      and compound() is the ONLY path that ever sends AERO to the compoundModule. While this
    ///      was permissionless, anyone could call it every block to keep the pending balance at ~0,
    ///      so compound(compoundBps) always harvested nothing and the compound share never
    ///      materialised. The role gate is the fix; this pins it.
    function test_claimEmissions_revertsNonRebalancer() public {
        _register(true);
        vm.prank(rebalancer);
        lab.stake();
        mockAero.mint(address(mockGauge), 10e18);
        mockGauge.setAeroToPayOnGetReward(10e18);

        // A griefing bot (and the admin, and the manager) cannot drain the pending emissions.
        address bot = makeAddr("griefBot");
        // Hoist the role read: a call in ARGUMENT position is evaluated first and would consume the
        // one-shot vm.prank, so `bot` would never be the caller.
        bytes32 role = lab.REBALANCER_ROLE();
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, role));
        lab.claimEmissions();

        vm.prank(admin);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        lab.claimEmissions();

        // The rebalancer still can, and compound() still sees the full pending balance because the
        // bot could not front-run it.
        uint256 fcBefore = mockAero.balanceOf(feeCollector);
        vm.prank(rebalancer);
        lab.claimEmissions();
        assertEq(mockAero.balanceOf(feeCollector) - fcBefore, 10e18, "rebalancer claim still works");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Sherlock audit regressions
    // ═══════════════════════════════════════════════════════════════════════

    // ---------- MOO-723: forced ETH on the shared position manager ----------

    /// @dev Slipstream's mint() ends with refundETH(), which pushes the position manager's ENTIRE
    ///      native balance to msg.sender and reverts if the recipient rejects it. The manager is
    ///      shared infrastructure and anyone can force ETH into it with create+selfdestruct — so
    ///      before `receive()` existed on the balancer, 1 wei permanently bricked every mint, i.e.
    ///      BOTH paths that redeploy principal. This test fails (revert "STE") without `receive()`.
    function test_rebalanceUsingAlt_survivesForcedEthOnPositionManager() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);
        mockPM.setRefundEthOnMint(true);

        // Force 1 wei in: selfdestruct-to-target cannot be refused, receive() or not.
        new ForceEther{value: 1}(payable(address(mockPM)));
        assertEq(address(mockPM).balance, 1, "ETH forced into the shared position manager");

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "principal redeployed despite the donation");
        assertEq(address(lab).balance, 1, "refunded wei accepted; sweepable via recoverETH");
    }

    /// @dev Same donation, the other principal-redeploying path. If it lands mid swap-window the
    ///      whole principal is stranded loose and unstaked with only admin exit() as recovery,
    ///      which is why this path is covered separately.
    function test_rebuildAfterSwap_survivesForcedEthOnPositionManager() public {
        _register(false);
        _setRealModule();
        _unwind();
        mockPM.setRefundEthOnMint(true);
        new ForceEther{value: 1}(payable(address(mockPM)));

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebuildParams());

        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "rebuild completed");
        assertFalse(lab.rebalanceInFlight(), "window closed, principal not stranded");
    }

    // ---------- MOO-727: rebuildAfterSwap tick commitment ----------

    /// @dev The searcher pushes spot by exactly one tickSpacing between the rebalancer's decision
    ///      and execution. The calm gate does NOT stop this: it bounds |spot - TWAP| and ACCEPTS
    ///      dev == maxTickDeviation, and it hands LIVE spot to _mainRange for placement. The amount
    ///      minima cannot stop it either — the mint consumes the same balances at either price.
    ///      Only the committed range does.
    function test_rebuildAfterSwap_revertsWhenSpotShiftsOneSpacing() public {
        _register(false);
        _setRealModule();
        _unwind();

        // Caller decided at spotTick=100 → straddle [-200, 200] (the default commitment).
        LPAutoBalancerV2.RebuildParams memory params = _defaultRebuildParams();

        // Searcher moves spot to 200: |200 - 0| == maxTickDeviation(200), which the calm gate's
        // `dev > maxTickDeviation` check ACCEPTS. The derived range becomes [0, 400] — the whole
        // position shifted one spacing onto the manipulated price.
        mockPool.setSlot0(SQRT_P, 200);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.TickMismatch.selector);
        lab.rebuildAfterSwap(params);

        // Still in flight: the rebalancer can re-decide (or exit()), it has not lost the window.
        assertTrue(lab.rebalanceInFlight(), "failed rebuild leaves the window open for retry");
    }

    /// @dev The commitment must not be over-strict: committing to the range that the CONTRACT
    ///      actually derives at the shifted spot succeeds, so an honest re-decision still rebuilds.
    function test_rebuildAfterSwap_shiftedSpot_succeedsWithMatchingCommitment() public {
        _register(false);
        _setRealModule();
        _unwind();

        mockPool.setSlot0(SQRT_P, 200);
        mockPM.setPosition(NEW_TOKEN_ID, 0, 400, NEW_LIQ, token0, token1);

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_rebuildParamsAt(0, 400));
        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "rebuild succeeds on a matching commitment");
    }

    /// @dev A wrong commitment is rejected even when spot never moved — the check compares against
    ///      the derived range, not against a "did spot change" heuristic.
    function test_rebuildAfterSwap_revertsOnMismatchedCommitmentAtStableSpot() public {
        _register(false);
        _setRealModule();
        _unwind();

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.TickMismatch.selector);
        lab.rebuildAfterSwap(_rebuildParamsAt(OLD_TL, OLD_TU + 200));
    }

    // ---------- rebalanceUsingAlt tick commitment (MOO-727, other path) ----------

    /// @dev The same sandwich MOO-727 closed on rebuildAfterSwap, run against rebalanceUsingAlt.
    ///      Being single-transaction is NOT the protection: `calmGate` bounds |spot - TWAP| and
    ///      ACCEPTS dev == maxTickDeviation, then hands LIVE spot to `_mainRange`, which floor-aligns
    ///      it — so one spacing of manipulation shifts the whole range and the tx still commits.
    ///      Neither the withdraw minima, the mint minima, nor the value floor can see it: the floor
    ///      measures at the manipulated sqrtP, where the fresh position holds exactly the tokens just
    ///      deposited. Only the committed range rejects it.
    function test_rebalanceUsingAlt_revertsWhenSpotShiftsOneSpacing() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);

        // Caller decided at spotTick=100 → straddle [-200, 200] (the default commitment).
        LPAutoBalancerV2.RebalanceParams memory params = _defaultRebalanceParams();

        // Searcher moves spot to 200: |200 - 0| == maxTickDeviation(200), which the calm gate
        // ACCEPTS. The derived range becomes [0, 400].
        mockPool.setSlot0(SQRT_P, 200);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.TickMismatch.selector);
        lab.rebalanceUsingAlt(params);

        // Nothing was torn down: the revert unwound the whole transaction, so the position is intact
        // and the rebalancer can re-decide. This is the structural advantage this path DOES have
        // over the two-transaction one — but it is an advantage in RECOVERY, not in prevention.
        assertEq(lab.exposed_position().mainTokenId, TOKEN_ID, "position untouched after TickMismatch");
    }

    /// @dev Not over-strict: committing to the range the CONTRACT derives at the shifted spot
    ///      succeeds, so an honest re-decision still rebalances.
    function test_rebalanceUsingAlt_shiftedSpot_succeedsWithMatchingCommitment() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);

        mockPool.setSlot0(SQRT_P, 200);
        mockPM.setPosition(NEW_TOKEN_ID, 0, 400, NEW_LIQ, token0, token1);

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_rebalanceParamsAt(0, 400));
        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "rebalance succeeds on a matching commitment");
        // "Did not revert" is the weaker half of not-over-strict. The stronger half is that the
        // range actually minted is the committed one — otherwise this would still pass against a
        // check that accepted the commitment and then placed liquidity somewhere else. Mint call 1
        // is the main leg (call 2 is the alt).
        assertEq(int256(mockPM.mintTickLowerByCall(1)), int256(0), "main minted at the committed lower");
        assertEq(int256(mockPM.mintTickUpperByCall(1)), int256(400), "main minted at the committed upper");
    }

    /// @dev A wrong commitment is rejected even when spot never moved — the check compares against
    ///      the derived range, not against a "did spot change" heuristic.
    function test_rebalanceUsingAlt_revertsOnMismatchedCommitmentAtStableSpot() public {
        _register(false);
        _stagePrincipal(1e18, 1e18);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.TickMismatch.selector);
        lab.rebalanceUsingAlt(_rebalanceParamsAt(OLD_TL, OLD_TU + 200));
    }

    // ---------- unwindForSwap oracle precheck ----------

    /// @dev The teardown must not proceed when the matching rebuild provably cannot price itself.
    ///      `_snapshotAmounts` is deliberately oracle-free, so before this check `unwindForSwap` read
    ///      no feed at all: a stale feed let the unwind burn BOTH NFTs and only surfaced as a
    ///      StaleOracle revert in `rebuildAfterSwap`, stranding principal loose and unstaked with
    ///      `exit()` (DEFAULT_ADMIN_ROLE, the timelocked Safe) as the only escape.
    function test_unwindForSwap_revertsOnStaleFeed_beforeBurningAnything() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);

        // oracle0 ages past its bound; oracle1 stays fresh (per-feed bounds, per-feed failure).
        MockPriceFeed(oracle0).setUpdatedAt(block.timestamp - 2 hours);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.StaleOracle.selector);
        lab.unwindForSwap(_defaultUnwindParams());

        // These assertions pin the OUTCOME, not the ordering: the revert rolls back
        // `burnCallCount` regardless of where the guard sits, so a probe moved BELOW `_exitAll`
        // would read identically here. Ordering is pinned separately, and rollback-immune, by
        // test_unwindForSwap_oracleProbePrecedesTeardown below.
        assertEq(mockPM.burnCallCount(), 0, "no NFT burned");
        assertEq(lab.exposed_position().mainTokenId, TOKEN_ID, "position intact");
        assertFalse(lab.rebalanceInFlight(), "no window opened");
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 0, "no relayer approval");
    }

    /// @dev PER-FEED, both legs. The probe is two independent `_readFeed` calls, each against its
    ///      own bound; the test above ages oracle0 only, so deleting the `oracle1` line left it
    ///      green. This is its mirror — oracle1 stale, oracle0 fresh — so dropping either leg of the
    ///      probe now fails a test. Deliberately two tests rather than one parameterised body: a
    ///      regression that drops a leg has to be visible as a NAMED failure.
    function test_unwindForSwap_revertsOnStaleFeed1_beforeBurningAnything() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);

        MockPriceFeed(oracle1).setUpdatedAt(block.timestamp - 2 hours);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.StaleOracle.selector);
        lab.unwindForSwap(_defaultUnwindParams());

        assertEq(mockPM.burnCallCount(), 0, "no NFT burned");
        assertFalse(lab.rebalanceInFlight(), "no window opened");
    }

    /// @dev ORDERING, pinned without relying on post-revert state. Counters cannot do this job:
    ///      `vm.expectRevert` rolls `burnCallCount()` back to 0 whether the probe ran before or
    ///      after `_exitAll`, so the two placements are indistinguishable to the tests above. The
    ///      revert REASON is not rolled back, so the mock's teardown trip-wire discriminates them:
    ///      with the wire armed AND oracle0 stale, the tx must fail with StaleOracle — if the probe
    ///      were moved below `_exitAll` (or below `_window.open`, which is later still) the very
    ///      same tx would fail with "TEARDOWN_REACHED" instead.
    function test_unwindForSwap_oracleProbePrecedesTeardown() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);

        mockPM.setRevertOnTeardown(true);

        // CONTROL (non-vacuity): with both feeds fresh, the probe passes and the trip-wire is
        // genuinely reached. Without this the assertion below would also hold for a mock whose
        // sentinel can never fire, which is exactly the failure mode being guarded against.
        vm.prank(rebalancer);
        vm.expectRevert("TEARDOWN_REACHED");
        lab.unwindForSwap(_defaultUnwindParams());

        // Now age a feed. The probe sits ahead of the teardown, so the ORACLE error wins the race.
        MockPriceFeed(oracle0).setUpdatedAt(block.timestamp - 2 hours);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.StaleOracle.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    /// @dev The same for the L2 sequencer guard, which is the trigger this PR ADDS. `checkSequencer`
    ///      lives inside the feed-read path, so once the guard is armed every Base sequencer recovery
    ///      opens a grace window during which a rebuild reverts SequencerGracePeriod. Without this
    ///      precheck, each recovery is a window where unwind succeeds and its rebuild cannot.
    function test_unwindForSwap_revertsInsideSequencerGrace_beforeBurningAnything() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);

        LPSequencerFeedMock seq = new LPSequencerFeedMock(0, block.timestamp - 2 hours);
        vm.prank(admin);
        lab.setSequencerUptimeFeed(address(seq), 1 hours);

        // Sequencer restarted 30 minutes ago — inside the 1h grace. The price feeds' own updatedAt
        // is untouched and would pass every freshness check, which is the whole point of the guard.
        seq.set(0, block.timestamp - 30 minutes);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.SequencerGracePeriod.selector);
        lab.unwindForSwap(_defaultUnwindParams());

        assertEq(mockPM.burnCallCount(), 0, "no NFT burned inside sequencer grace");
        assertFalse(lab.rebalanceInFlight(), "no window opened inside sequencer grace");

        // Past the grace period the unwind proceeds normally — the guard gates, it does not brick.
        seq.set(0, block.timestamp - 2 hours);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());
        assertTrue(lab.rebalanceInFlight(), "unwind resumes after grace");
    }

    // ---------- MOO-728: pause must stop an in-flight principal swap ----------

    /// @dev unwindForSwap leaves a live VAULT_RELAYER allowance and pause() does not revoke it, so
    ///      the EIP-1271 gate is the ONLY thing that can stop a solver from settling principal
    ///      while the guardian has the contract paused.
    function test_isValidSignature_revertsWhilePaused() public {
        _register(false);
        address mockModule = makeAddr("pauseTestModule");
        vm.prank(admin);
        lab.setCompoundModule(mockModule);
        _unwind(); // real in-flight window + live relayer approval

        bytes32 digest = bytes32(uint256(7));
        bytes memory order = hex"c0ffee";
        vm.mockCall(
            mockModule,
            abi.encodeWithSignature("validateRebalanceOrder(bytes32,bytes)", digest, order),
            abi.encode(bytes4(0x1626ba7e))
        );

        // Control: unpaused, the order validates.
        assertEq(lab.isValidSignature(digest, order), bytes4(0x1626ba7e), "validates while unpaused");
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 5e17, "relayer can pull principal");

        vm.prank(guardian);
        lab.pause();

        // The allowance SURVIVES the pause — that is the whole reason the gate has to exist here.
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 5e17, "pause does not revoke the approval");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lab.isValidSignature(digest, order);

        // Unpause restores it (the gate is a pause, not a permanent block).
        vm.prank(guardian);
        lab.unpause();
        assertEq(lab.isValidSignature(digest, order), bytes4(0x1626ba7e), "restored after unpause");
    }

    // ---------- MOO-730(a): the value floor must not measure the market ----------

    /// @dev Both legs of a WETH/cbBTC position are volatile against USD with no offsetting leg. A
    ///      USD baseline frozen at unwind and compared to a USD valueAfter read at rebuild measures
    ///      the MARKET's move, not the rebalance's: a 30% decline during CowSwap settlement — with a
    ///      completely loss-free round trip — used to read as a 30% rebalance loss and revert,
    ///      stranding the principal loose and unstaked with only admin exit() as recovery.
    ///      Snapshotting AMOUNTS and pricing them at rebuild makes the move cancel on both sides.
    function test_rebuildAfterSwap_marketMove_doesNotFalseTripValueFloor() public {
        _register(false);
        _setRealModule();
        _unwind();

        // Sanity: the snapshot is stored as amounts, and they are the position's, not zero.
        (uint256 a0, uint256 a1,,) = lab.rebalanceAmountsBefore();
        assertGt(a0 + a1, 0, "amount baseline captured");

        // Market declines 30% on BOTH feeds between the two transactions. Balances are untouched:
        // the swap round trip lost nothing.
        MockPriceFeed(oracle0).setAnswer(0.7e8);
        MockPriceFeed(oracle1).setAnswer(0.7e8);

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebuildParams()); // must NOT revert

        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "honest rebuild survived the market move");
        assertFalse(lab.rebalanceInFlight());
    }

    /// @dev The mirror: a market RALLY must not manufacture headroom either. Re-pricing both sides
    ///      with the same feeds means a genuine principal loss still trips the floor while prices
    ///      are up 40%.
    function test_rebuildAfterSwap_marketRally_stillTripsOnRealLoss() public {
        _register(false);
        _setRealModule();
        _unwind();

        MockPriceFeed(oracle0).setAnswer(1.4e8);
        MockPriceFeed(oracle1).setAnswer(1.4e8);

        // Genuine catastrophic loss: rebuilt main holds nothing and the principal left the contract.
        mockPM.setNextMintResult(NEW_TOKEN_ID, 0);
        mockPM.setPosition(NEW_TOKEN_ID, OLD_TL, OLD_TU, 0, token0, token1);
        vm.startPrank(address(lab));
        tok0.transfer(makeAddr("solver"), 1e18 - 1);
        tok1.transfer(makeAddr("solver"), 1e18 - 1);
        vm.stopPrank();

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.ValueFloor.selector);
        lab.rebuildAfterSwap(_rebuildParamsAt(200, 600)); // 1-wei legs → single-sided token0 branch
    }

    // ---------- MOO-736: stake() must skim fees before the gauge sweeps them ----------

    /// @dev Slipstream's CLGauge.deposit() collects all pre-stake fees with recipient == msg.sender
    ///      (this contract). Without a skim first they become loose balances indistinguishable from
    ///      principal — a later rebalance mints them as PRINCIPAL, or exit() pays them to the
    ///      principal recipient, and the feeCollector never sees them.
    function test_stake_skimsAccruedFeesToFeeCollectorBeforeDeposit() public {
        _registerWithAlt(true);
        // Two collects happen (main skim, then alt skim); stage both to pay real fees.
        tok0.mint(address(mockPM), 6e17);
        tok1.mint(address(mockPM), 4e17);
        mockPM.setCollectSequence(3e17, 2e17, 3e17, 2e17);
        mockPM.resetCollectCount();

        uint256 fc0 = tok0.balanceOf(feeCollector);
        uint256 fc1 = tok1.balanceOf(feeCollector);

        vm.prank(rebalancer);
        lab.stake();

        assertEq(tok0.balanceOf(feeCollector) - fc0, 6e17, "pre-stake token0 fees reached the feeCollector");
        assertEq(tok1.balanceOf(feeCollector) - fc1, 4e17, "pre-stake token1 fees reached the feeCollector");
        assertEq(tok0.balanceOf(address(lab)), 0, "no fee residue left on the balancer as loose principal");
        assertEq(tok1.balanceOf(address(lab)), 0, "no fee residue left on the balancer as loose principal");
        assertEq(mockGauge.depositCallCount(), 2, "both legs still staked");
        (bool mainStaked, bool altStaked) = _readStakeFlags();
        assertTrue(mainStaked);
        assertTrue(altStaked);
    }

    // ---------- MOO-742: range placement must not forfeit fees ----------

    /// @dev (a) The alt is anchored to SPOT, not to the main range's bounds. On the straddle branch
    ///      the old anchor put a token0 alt at [mainTu, mainTu + spacing] — width/2 ticks above
    ///      spot — where it earned nothing until price traversed half the main width. With
    ///      width = 2000 and spacing = 200 the two placements are 800 ticks apart, so the assertion
    ///      cleanly discriminates the fix.
    function test_mintAlt_token0Surplus_anchorsToSpot_notMainUpper() public {
        _register(false);
        _stagePrincipal(3e18, 1e18); // in-ratio mint consumes 1e18 each → 2e18 token0 surplus

        // main = alignedRange(100, 2000, 200, 100) = [-1000, 1000]; OLD alt = [1000, 1200].
        mockPM.setPosition(NEW_TOKEN_ID, -1000, 1000, NEW_LIQ, token0, token1);
        mockPM.setNextAltMintResult(ALT_TOKEN_ID, NEW_LIQ);
        mockPM.setPosition(ALT_TOKEN_ID, 200, 400, NEW_LIQ, token0, token1);

        LPAutoBalancerV2.RebalanceParams memory params = _rebalanceParamsAt(-1000, 1000);
        params.width = 2000;

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(params);

        assertEq(mockPM.mintTickLowerByCall(1), -1000, "main straddles spot");
        assertEq(mockPM.mintTickUpperByCall(1), 1000);
        // floorAlign(100, 200) = 0 → the closest token0-only range is [200, 400], NOT [1000, 1200].
        assertEq(mockPM.mintTickLowerByCall(2), 200, "alt anchored one spacing above spot's floor");
        assertEq(mockPM.mintTickUpperByCall(2), 400);
    }

    /// @dev (a) mirrored on the token1 side: [floor - spacing, floor] = [-200, 0], not
    ///      [mainTl - spacing, mainTl] = [-1200, -1000]. tickUpper == floor <= spot keeps the range
    ///      single-token (a range is inactive at tick == tickUpper).
    function test_mintAlt_token1Surplus_anchorsToSpot_notMainLower() public {
        _register(false);
        _stagePrincipal(1e18, 3e18); // 2e18 token1 surplus after the in-ratio main mint

        mockPM.setPosition(NEW_TOKEN_ID, -1000, 1000, NEW_LIQ, token0, token1);
        mockPM.setNextAltMintResult(ALT_TOKEN_ID, NEW_LIQ);
        mockPM.setPosition(ALT_TOKEN_ID, -200, 0, NEW_LIQ, token0, token1);

        LPAutoBalancerV2.RebalanceParams memory params = _rebalanceParamsAt(-1000, 1000);
        params.width = 2000;

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(params);

        assertEq(mockPM.mintTickLowerByCall(2), -200, "alt anchored one spacing below spot's floor");
        assertEq(mockPM.mintTickUpperByCall(2), 0);
    }

    /// @dev (b) The token1-majority single-sided main used `floor == spot ? floor - spacing : floor`,
    ///      pushing the range a whole spacing further from the market whenever spot sat exactly on
    ///      an aligned tick. A range is already inactive at tick == tickUpper, so plain `floor` is
    ///      valid AND strictly closer. With spot = 0 (aligned, spacing 200) and width 400 the old
    ///      code produced [-600, -200] and the new code produces [-400, 0].
    function test_mainRange_token1Majority_alignedSpot_usesPlainFloor() public {
        _register(false);
        mockPool.setSlot0(SQRT_P, 0); // spot exactly on an aligned tick; twap 0 → dev 0
        _stagePrincipal(0, 1e18); // token1-only principal → single-sided branch

        mockPM.setPosition(NEW_TOKEN_ID, -400, 0, NEW_LIQ, token0, token1);
        mockPM.setNextAltMintResult(ALT_TOKEN_ID, NEW_LIQ);
        mockPM.setPosition(ALT_TOKEN_ID, -200, 0, NEW_LIQ, token0, token1);

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_rebalanceParamsAt(-400, 0));

        assertEq(mockPM.mintTickUpperByCall(1), 0, "main upper is spot's aligned floor, adjacent to the market");
        assertEq(mockPM.mintTickLowerByCall(1), -400);
    }

    // ---------- MOO-743: burned ids must not survive as position state ----------

    /// @dev unwindForSwap returns with active == true and no re-mint until a LATER transaction, so
    ///      dangling ids are served by the public getter for the whole window. Complements the
    ///      happy-path assertion above by checking the ALT leg too, and that the rebuild refills
    ///      both fields.
    function test_unwindForSwap_clearsBurnedIds_rebuildRefillsThem() public {
        _registerWithLiveAlt();
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        tok0.mint(address(mockPM), 2e18);
        tok1.mint(address(mockPM), 2e18);
        // The snapshot counts BOTH legs' principal, so the rebuilt main must carry the combined
        // liquidity for the value floor to clear (the mock's collect payout is fixed, so size the
        // fresh NFT rather than the payout).
        mockPM.setNextMintResult(NEW_TOKEN_ID, NEW_LIQ * 3);
        mockPM.setPosition(NEW_TOKEN_ID, OLD_TL, OLD_TU, NEW_LIQ * 3, token0, token1);

        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        assertTrue(mockPM.wasBurned(TOKEN_ID) && mockPM.wasBurned(ALT_TOKEN_ID), "both burned");
        LPAutoBalancerV2.ManagedPositionV2 memory p = lab.exposed_position();
        assertEq(p.mainTokenId, 0, "no burned main id served mid-flight");
        assertEq(p.altTokenId, 0, "no burned alt id served mid-flight");
        assertTrue(p.active, "position stays active: the ids are cleared, not the registration");

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebuildParams());
        assertEq(lab.exposed_position().mainTokenId, NEW_TOKEN_ID, "rebuild repopulates the main id");
    }

    // ---------- constant invariant ----------

    /// @dev CHANGE DETECTOR, not a safety property — the rationale it used to carry was retracted.
    ///      An alt range can never straddle spot regardless of these constants: `floorAlign` gives
    ///      `floor <= spot < floor + spacing` strictly, so a token0 alt opens at `floor + spacing`
    ///      (> spot) and a token1 alt closes at `tickUpper = floor` (<= spot, and range activity is
    ///      `tickLower <= tick < tickUpper`, which puts that boundary OUTSIDE the range). `mintAlt`
    ///      is the only alt-creating path — `_store` force-zeroes `altTokenId` on registration — so
    ///      there is no adoption route either. What this assertion still buys is the coupling: the
    ///      two constants live 15 lines apart and are edited independently, and
    ///      MIN_ALT_VALUE_USD >= MIN_MAIN_LEG_USD is what keeps a sub-main-threshold minority also
    ///      sub-alt-threshold, so an independent bump to one of them has to be deliberate.
    function test_invariant_minAltValueGeMinMainLeg() public view {
        assertGe(lab.MIN_ALT_VALUE_USD(), lab.MIN_MAIN_LEG_USD());
    }
}
