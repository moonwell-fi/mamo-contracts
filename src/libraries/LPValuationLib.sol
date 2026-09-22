// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {LPGeometryLib} from "@libraries/LPGeometryLib.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LPValuationLib
/// @notice USD valuation for LPAutoBalancerV2: Chainlink feed reads and the 1e8-scale pricing of
///         token amounts, position principal, and loose contract balances. Shared invariant of
///         every function here: needs an `OracleConfig` (both feeds, their INDEPENDENT staleness
///         bounds, and the L2 sequencer-uptime guard) + token decimals; an unfunded leg never
///         consults its feed. Deployed as an EXTERNAL (linked) library so its bytecode lives
///         off the balancer — keeping the balancer under the EIP-170 24,576-byte limit. Functions
///         are `public`/`external` on purpose: internal library functions would inline back into
///         the balancer and defeat the size reduction.
/// @dev Errors are redeclared here; a Solidity error's 4-byte selector depends only on its
///      signature, so `LPValuationLib.StaleOracle.selector == LPAutoBalancerV2.StaleOracle.selector`
///      and existing `vm.expectRevert(...)` matchers keep working.
library LPValuationLib {
    error StaleOracle();
    error SequencerDown();
    error SequencerGracePeriod();
    error CenterDeviation();
    error ValueFloor();

    /// @notice Inputs for `mainRange` — grouped so the balancer passes one memory struct instead of
    ///         ten stack slots (the balancer is within a few hundred bytes of EIP-170).
    /// @param holder the account whose loose token0/token1 fund the mint (the balancer).
    /// @param minMainLegUsd the balancer's MIN_MAIN_LEG_USD, passed in rather than duplicated here
    ///        so the constant keeps a single definition site.
    struct RangeParams {
        address token0;
        address token1;
        address holder;
        int24 spotTick;
        uint24 width;
        int24 tickSpacing;
        uint24 maxCenterDeviation;
        uint256 minMainLegUsd;
        uint8 dec0;
        uint8 dec1;
    }

    /// @notice Everything a valuation needs to price the pair.
    /// @param oracle0 token0/USD Chainlink-style feed.
    /// @param oracle1 token1/USD Chainlink-style feed.
    /// @param maxDelay0 staleness bound for `oracle0` ONLY. Per-feed on purpose: the two legs are
    ///        different assets on different heartbeats (Base cbBTC/USD and ETH/USD both publish on
    ///        ~20-minute cadences, while other pairs run 24h), and a single shared bound sized for
    ///        the slowest feed accepts the fastest feed's answers far past their own validity.
    /// @param maxDelay1 staleness bound for `oracle1` ONLY.
    /// @param sequencerUptimeFeed Base sequencer uptime feed (Chainlink L2 uptime aggregator).
    ///        `address(0)` DISABLES the check — the only configuration under which a pre-outage
    ///        report is accepted the instant the sequencer resumes.
    /// @param sequencerGracePeriod Seconds that must elapse after the sequencer comes back up
    ///        before any feed read is accepted, giving oracles time to publish a post-outage round.
    struct OracleConfig {
        address oracle0;
        address oracle1;
        uint256 maxDelay0;
        uint256 maxDelay1;
        address sequencerUptimeFeed;
        uint256 sequencerGracePeriod;
    }

    /// @notice Revert unless the L2 sequencer is up AND has been up for at least `gracePeriod`.
    /// @dev The uptime aggregator answers 0 == up, 1 == down, and `startedAt` is when the CURRENT
    ///      status began. Immediately after a restart the price feeds still carry their last
    ///      pre-outage round, which passes every freshness check while being arbitrarily stale in
    ///      economic terms — the grace period is what rejects that window. A zero `startedAt` is
    ///      the aggregator's "round not started / invalid" sentinel and fails closed. No-op when
    ///      `sequencerUptimeFeed == address(0)` (chains without one, and unit fixtures).
    function checkSequencer(address sequencerUptimeFeed, uint256 gracePeriod) public view {
        if (sequencerUptimeFeed == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = IPriceFeed(sequencerUptimeFeed).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0 || startedAt > block.timestamp) revert SequencerDown();
        if (block.timestamp - startedAt < gracePeriod) revert SequencerGracePeriod();
    }

    /// @dev Read a Chainlink-style feed, validating the L2 sequencer first, then positivity +
    ///      freshness against `maxOracleDelay` (which is THIS feed's bound, never a shared one).
    ///      A future-dated `updatedAt` (misbehaving feed) reverts StaleOracle explicitly rather than
    ///      tripping the 0x11 underflow panic in the staleness subtraction — same fail-closed
    ///      outcome, honest error.
    function readFeed(address feed, uint256 maxOracleDelay, address sequencerUptimeFeed, uint256 gracePeriod)
        public
        view
        returns (uint256 price, uint8 decimals)
    {
        checkSequencer(sequencerUptimeFeed, gracePeriod);
        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(feed).latestRoundData();
        if (answer <= 0) revert StaleOracle();
        if (updatedAt > block.timestamp) revert StaleOracle();
        if (block.timestamp - updatedAt > maxOracleDelay) revert StaleOracle();
        price = uint256(answer);
        decimals = IPriceFeed(feed).decimals();
    }

    /// @notice Value token amounts in USD scaled to 1e8. Only consults a leg's feed when funded,
    ///         and each leg is checked against its OWN staleness bound.
    function valueInUsd(uint256 amount0, uint256 amount1, OracleConfig memory cfg, uint8 dec0, uint8 dec1)
        public
        view
        returns (uint256 usd)
    {
        if (amount0 > 0) {
            (uint256 p0, uint8 fd0) =
                readFeed(cfg.oracle0, cfg.maxDelay0, cfg.sequencerUptimeFeed, cfg.sequencerGracePeriod);
            usd += FullMath.mulDiv(amount0, p0, 10 ** dec0) * (10 ** 8) / (10 ** fd0);
        }
        if (amount1 > 0) {
            (uint256 p1, uint8 fd1) =
                readFeed(cfg.oracle1, cfg.maxDelay1, cfg.sequencerUptimeFeed, cfg.sequencerGracePeriod);
            usd += FullMath.mulDiv(amount1, p1, 10 ** dec1) * (10 ** 8) / (10 ** fd1);
        }
    }

    /// @notice Raw token amounts backing `tokenId`'s liquidity at sqrt price `sqrtP`. Returns
    ///         (0, 0) for tokenId == 0 (no position). Never counts tokensOwed (fees).
    /// @dev Oracle-free on purpose: the swap-rebalance floor snapshots AMOUNTS at unwind and only
    ///      prices them at rebuild, so a market move between the two transactions cancels on both
    ///      sides of the comparison instead of reading as a rebalance loss.
    function principalAmounts(address positionManager, uint256 tokenId, uint160 sqrtP)
        public
        view
        returns (uint256 a0, uint256 a1)
    {
        if (tokenId == 0) return (0, 0);
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);
        return LPGeometryLib.amountsForLiquidityAtTicks(sqrtP, tl, tu, liq);
    }

    /// @notice USD value of the principal tokens locked in `tokenId` at sqrt price `sqrtP`. Returns
    ///         0 for tokenId == 0 (no position). Never counts tokensOwed (fees) — only liquidity.
    function principalValue(
        address positionManager,
        uint256 tokenId,
        uint160 sqrtP,
        OracleConfig memory cfg,
        uint8 dec0,
        uint8 dec1
    ) public view returns (uint256) {
        if (tokenId == 0) return 0;
        (uint256 a0, uint256 a1) = principalAmounts(positionManager, tokenId, sqrtP);
        return valueInUsd(a0, a1, cfg, dec0, dec1);
    }

    /// @notice USD value of `holder`'s current (non-position) balances of `token0`/`token1`.
    function contractPairValue(
        address token0,
        address token1,
        address holder,
        OracleConfig memory cfg,
        uint8 dec0,
        uint8 dec1
    ) public view returns (uint256) {
        return valueInUsd(IERC20(token0).balanceOf(holder), IERC20(token1).balanceOf(holder), cfg, dec0, dec1);
    }

    /// @notice Pick the new main range from `holder`'s current (post-withdraw) balances.
    ///         - Both legs >= minMainLegUsd → spot-centered aligned straddle (the balanced main).
    ///         - Minority leg below it (including exactly one leg funded — a fully out-of-range
    ///           rebalance returns 100%-single-sided principal) → a single-sided `width`-wide range
    ///           on the MAJORITY side, adjacent to spot, so the mint has positive liquidity. NO SWAP
    ///           is ever performed; this only changes WHERE the funded token is parked.
    ///         Orientation (price = token1/token0, ticks rise with price): a range strictly ABOVE
    ///         spot holds only token0; a range at or below spot holds only token1.
    ///           token0-majority: [up, up + width]        where up    = floorAlign(spot) + spacing
    ///           token1-majority: [floor - width, floor]  where floor = floorAlign(spot)
    /// @dev The classifier is VALUE-based, not exact-zero: a 1-wei minority leg would otherwise force
    ///      the straddle branch and compute near-zero (or zero, reverting) liquidity.
    ///      The token1 branch uses PLAIN `floor` even when spot sits exactly on it: a range is
    ///      inactive at tick == tickUpper (activity is tickLower <= tick < tickUpper), so `floor` is
    ///      a valid upper bound and is strictly closer to the market than floor - spacing.
    function mainRange(RangeParams memory rp, OracleConfig memory cfg)
        public
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        // Value each leg independently (pass the other amount as 0), so the minority is the
        // smaller-VALUE leg and never merely the smaller raw balance (the pair's decimals differ).
        uint256 value0 = valueInUsd(IERC20(rp.token0).balanceOf(rp.holder), 0, cfg, rp.dec0, rp.dec1);
        uint256 value1 = valueInUsd(0, IERC20(rp.token1).balanceOf(rp.holder), cfg, rp.dec0, rp.dec1);

        if ((value0 < value1 ? value0 : value1) >= rp.minMainLegUsd) {
            (tickLower, tickUpper) = LPGeometryLib.alignedRange(rp.spotTick, rp.width, rp.tickSpacing, rp.spotTick);
            // Enforce maxCenterDeviation on the BALANCED path only. The range is centered on
            // spotTick, so today the deviation is just the alignment remainder — this guard
            // backstops any future change to the centering reference (e.g. centering on TWAP).
            // The single-sided branch is intentionally off-center and is NOT subject to it.
            int24 center = (tickLower + tickUpper) / 2;
            int24 dev = center > rp.spotTick ? center - rp.spotTick : rp.spotTick - center;
            if (uint24(dev) > rp.maxCenterDeviation) revert CenterDeviation();
            return (tickLower, tickUpper);
        }

        int24 floorTick = LPGeometryLib.floorAlign(rp.spotTick, rp.tickSpacing);
        int24 w = int24(rp.width);
        if (value0 >= value1) {
            tickLower = floorTick + rp.tickSpacing; // first aligned tick strictly ABOVE spot
            tickUpper = tickLower + w;
        } else {
            tickUpper = floorTick;
            tickLower = floorTick - w;
        }
    }

    /// @notice Combined main + alt PRINCIPAL value at `sqrtP` (no loose balances).
    /// @dev One entry point rather than two `principalValue` calls from the balancer: each call site
    ///      there has to build an OracleConfig in memory, and the balancer is within a few hundred
    ///      bytes of EIP-170.
    function positionsValue(
        address positionManager,
        uint256 mainTokenId,
        uint256 altTokenId,
        uint160 sqrtP,
        OracleConfig memory cfg,
        uint8 dec0,
        uint8 dec1
    ) public view returns (uint256) {
        return principalValue(positionManager, mainTokenId, sqrtP, cfg, dec0, dec1)
            + principalValue(positionManager, altTokenId, sqrtP, cfg, dec0, dec1);
    }

    /// @notice Everything the rebalance value floor's "after" side counts: main + alt principal at
    ///         `sqrtP` PLUS `holder`'s loose token0/token1. Counting the loose balance is the key
    ///         invariant — a non-trivial surplus cannot escape the floor by being forwarded as
    ///         "dust", because at floor time it is either in a position (counted) or loose (counted).
    function totalValue(
        address positionManager,
        uint256 mainTokenId,
        uint256 altTokenId,
        uint160 sqrtP,
        address token0,
        address token1,
        address holder,
        OracleConfig memory cfg,
        uint8 dec0,
        uint8 dec1
    ) public view returns (uint256) {
        return positionsValue(positionManager, mainTokenId, altTokenId, sqrtP, cfg, dec0, dec1)
            + contractPairValue(token0, token1, holder, cfg, dec0, dec1);
    }

    /// @notice Shared value-floor gate for both rebalance paths (H-1). Reverts `ValueFloor` when
    ///         `valueAfter` drops below the haircut POSITION floor plus the un-haircut loose balance.
    /// @dev The haircut applies to `valueBeforePos` ONLY; `looseBefore` is added back whole. A loose
    ///      balance that was already on the contract (donated, or un-folded compound proceeds)
    ///      appears on both sides and cancels, so it can never widen the tolerated absolute loss and
    ///      mask a real principal loss.
    /// @param lossBps maxRebalanceLossBps + any path-specific extra (swapLossAllowanceBps on the
    ///        swap rebuild, 0 on rebalanceUsingAlt). The caller has already bounded both.
    function enforceValueFloor(uint256 valueBeforePos, uint256 looseBefore, uint256 valueAfter, uint256 lossBps)
        public
        pure
    {
        uint256 floor = FullMath.mulDiv(valueBeforePos, 10_000 - lossBps, 10_000) + looseBefore;
        if (valueAfter < floor) revert ValueFloor();
    }
}
