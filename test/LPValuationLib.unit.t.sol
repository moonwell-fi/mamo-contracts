// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {LPGeometryLib} from "@libraries/LPGeometryLib.sol";
import {LPValuationLib} from "@libraries/LPValuationLib.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";

/// @dev Minimal positions() surface for principalValue: one configurable position.
contract MiniPositionManager {
    int24 internal tl;
    int24 internal tu;
    uint128 internal liq;

    function set(int24 tl_, int24 tu_, uint128 liq_) external {
        tl = tl_;
        tu = tu_;
        liq = liq_;
    }

    function positions(uint256)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), address(0), address(0), 0, tl, tu, liq, 0, 0, 0, 0);
    }
}

/// @notice Standalone unit suite for LPValuationLib — feed staleness, mixed-decimal USD scaling,
///         and the funded-leg-only feed-consultation invariant, previously only reachable through
///         the balancer's full mock stack.
contract LPValuationLibUnitTest is Test {
    uint256 internal constant MAX_DELAY = 1 hours;

    MockPriceFeed internal feed0; // 8-dec USD feed, price 1.00
    MockPriceFeed internal feed1;
    address internal token0;
    address internal token1;

    function setUp() public {
        vm.warp(10 days); // give block.timestamp room for staleness arithmetic
        feed0 = new MockPriceFeed(1e8, 8, block.timestamp);
        feed1 = new MockPriceFeed(1e8, 8, block.timestamp);
        token0 = address(new MockERC20("Token0", "TK0"));
        token1 = address(new MockERC20("Token1", "TK1"));
    }

    // ─── readFeed ────────────────────────────────────────────────────────────

    function test_readFeed_freshFeed_returnsPriceAndDecimals() public view {
        (uint256 price, uint8 dec) = LPValuationLib.readFeed(address(feed0), MAX_DELAY);
        assertEq(price, 1e8);
        assertEq(dec, 8);
    }

    /// @dev updatedAt exactly at the delay boundary passes (check is strict >); one second past reverts.
    function test_readFeed_staleness_boundary() public {
        feed0.setUpdatedAt(block.timestamp - MAX_DELAY);
        (uint256 price,) = LPValuationLib.readFeed(address(feed0), MAX_DELAY);
        assertEq(price, 1e8);

        feed0.setUpdatedAt(block.timestamp - MAX_DELAY - 1);
        vm.expectRevert(LPValuationLib.StaleOracle.selector);
        LPValuationLib.readFeed(address(feed0), MAX_DELAY);
    }

    function test_readFeed_nonPositiveAnswer_reverts() public {
        feed0.setAnswer(0);
        vm.expectRevert(LPValuationLib.StaleOracle.selector);
        LPValuationLib.readFeed(address(feed0), MAX_DELAY);

        feed0.setAnswer(-1);
        vm.expectRevert(LPValuationLib.StaleOracle.selector);
        LPValuationLib.readFeed(address(feed0), MAX_DELAY);
    }

    /// @dev A FUTURE-dated feed (misbehaving oracle) must revert StaleOracle explicitly, not trip
    ///      the 0x11 underflow panic in the staleness subtraction.
    function test_readFeed_futureDatedFeed_revertsStaleOracle() public {
        feed0.setUpdatedAt(block.timestamp + 1);
        vm.expectRevert(LPValuationLib.StaleOracle.selector);
        LPValuationLib.readFeed(address(feed0), MAX_DELAY);
    }

    // ─── valueInUsd ──────────────────────────────────────────────────────────

    /// @dev 1 token (18-dec) at $1.00 (8-dec feed) = 1e8 USD units (1e8 scale).
    function test_valueInUsd_18decLeg_at1Dollar() public view {
        uint256 usd = LPValuationLib.valueInUsd(1e18, 0, address(feed0), address(feed1), 18, 18, MAX_DELAY);
        assertEq(usd, 1e8);
    }

    /// @dev Mixed decimals (phase-1 pair shape: 18-dec WETH / 8-dec cbBTC): 1 unit of an 8-dec token
    ///      at $100,000 = 1e13 USD units; sums with the 18-dec leg.
    function test_valueInUsd_mixedDecimals_sumsLegs() public {
        feed1.setAnswer(100_000e8);
        uint256 usd = LPValuationLib.valueInUsd(2e18, 1e8, address(feed0), address(feed1), 18, 8, MAX_DELAY);
        assertEq(usd, 2e8 + 100_000e8);
    }

    /// @dev The funded-leg-only invariant: a zero amount must NOT consult its feed. Proven by
    ///      passing address(0) as the unfunded leg's oracle — any consultation would revert.
    function test_valueInUsd_zeroLeg_neverConsultsItsFeed() public view {
        uint256 usd = LPValuationLib.valueInUsd(0, 1e18, address(0), address(feed1), 18, 18, MAX_DELAY);
        assertEq(usd, 1e8);

        usd = LPValuationLib.valueInUsd(1e18, 0, address(feed0), address(0), 18, 18, MAX_DELAY);
        assertEq(usd, 1e8);
    }

    /// @dev DISTINCT per-leg prices ($1 vs $3) so wiring a leg to the wrong feed changes the
    ///      result, plus real amount-scaling (f(2a) == 2·f(a)) and additivity assertions. Amounts
    ///      are whole tokens so every expectation is exact (no floor-loss tautology).
    function testFuzz_valueInUsd_scalingAndDistinctFeeds(uint64 tokens) public {
        feed1.setAnswer(3e8); // $3.00 — distinct from feed0's $1.00
        uint256 n = bound(tokens, 1, 1e10);
        uint256 a = n * 1e18;

        uint256 leg0 = LPValuationLib.valueInUsd(a, 0, address(feed0), address(feed1), 18, 18, MAX_DELAY);
        assertEq(leg0, n * 1e8, "leg0 priced by feed0 at $1");

        uint256 leg1 = LPValuationLib.valueInUsd(0, a, address(feed0), address(feed1), 18, 18, MAX_DELAY);
        assertEq(leg1, 3 * n * 1e8, "leg1 must consult ITS OWN feed ($3), not feed0");

        assertEq(
            LPValuationLib.valueInUsd(2 * a, 0, address(feed0), address(feed1), 18, 18, MAX_DELAY),
            2 * leg0,
            "linear in amount"
        );
        assertEq(
            LPValuationLib.valueInUsd(a, a, address(feed0), address(feed1), 18, 18, MAX_DELAY),
            leg0 + leg1,
            "legs additive under distinct prices"
        );
    }

    /// @dev Edge (upstream-guarded caller contract documented here): a nonzero tokenId with ZERO
    ///      liquidity values to 0 — and consults no feed (proven with address(0) oracles).
    function test_principalValue_zeroLiquidity_isZeroWithoutFeedConsult() public {
        MiniPositionManager pm = new MiniPositionManager();
        pm.set(-400, 400, 0);
        uint256 v = LPValuationLib.principalValue(
            address(pm), 77, TickMath.getSqrtRatioAtTick(0), address(0), address(0), 18, 18, MAX_DELAY
        );
        assertEq(v, 0);
    }

    // ─── principalValue ──────────────────────────────────────────────────────

    function test_principalValue_zeroTokenId_isZero() public {
        MiniPositionManager pm = new MiniPositionManager();
        uint256 v = LPValuationLib.principalValue(
            address(pm), 0, TickMath.getSqrtRatioAtTick(0), address(feed0), address(feed1), 18, 18, MAX_DELAY
        );
        assertEq(v, 0);
    }

    /// @dev Happy path: principal value equals valueInUsd over the position's liquidity-implied
    ///      amounts at the same sqrtP — the composition principalValue promises.
    function test_principalValue_matchesAmountsValuation() public {
        MiniPositionManager pm = new MiniPositionManager();
        pm.set(-400, 400, 1e18);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);

        (uint256 a0, uint256 a1) = LPGeometryLib.amountsForLiquidityAtTicks(sqrtP, -400, 400, 1e18);
        uint256 expected = LPValuationLib.valueInUsd(a0, a1, address(feed0), address(feed1), 18, 18, MAX_DELAY);

        uint256 v =
            LPValuationLib.principalValue(address(pm), 77, sqrtP, address(feed0), address(feed1), 18, 18, MAX_DELAY);
        assertEq(v, expected);
        assertGt(v, 0);
    }

    // ─── contractPairValue ───────────────────────────────────────────────────

    function test_contractPairValue_valuesHolderBalances() public {
        address holder = makeAddr("holder");
        MockERC20(token0).mint(holder, 3e18);
        MockERC20(token1).mint(holder, 1e18);

        uint256 v =
            LPValuationLib.contractPairValue(token0, token1, holder, address(feed0), address(feed1), 18, 18, MAX_DELAY);
        assertEq(v, 4e8);
    }
}
