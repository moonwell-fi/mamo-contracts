// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title FreshFeed
 * @notice VNET-ONLY Chainlink `AggregatorV3Interface`-shaped stand-in whose `updatedAt` tracks
 *         `block.timestamp`, so the feed is never stale no matter how far the vnet clock advances.
 * @dev WHY THIS EXISTS. On a raw Base fork the Chainlink answers are frozen at the fork block, so
 *      `block.timestamp - updatedAt` grows without bound and every priced path in
 *      {LeveragedAerodromeCLStrategy} bricks with `StaleOracle` in about a day (`maxDelay` is an init
 *      param, bounded to `(0, 7 days]`). The fix — the "FreshFeed pattern", see
 *      `docs/LEVERAGED_AERO_VNET_RUNBOOK.md` Phase B.0 — is:
 *
 *        1. read the LIVE aggregator's `decimals()` and `latestRoundData().answer` off the fork;
 *        2. deploy a `FreshFeed` carrying that answer/decimals as IMMUTABLES;
 *        3. copy its RUNTIME code onto the canonical mainnet feed address with
 *           `tenderly_setCode`, so the strategy can be initialized against the real feed addresses.
 *
 *      Storage-free by construction (immutables only, no constructor-written slots), which is what
 *      makes step 3 sound: the runtime code carries the answer inline, so it behaves identically at
 *      any address and no storage has to be migrated.
 *
 *      SERVES BOTH FEED SHAPES the strategy consumes:
 *        - PRICE feeds (leg A/USD, leg B/USD, USDC/USD, AERO/USD) — 8dp answers. `decimals()` must
 *          match the real aggregator: `_initialize` asserts `aeroUsdFeed.decimals() == 8`
 *          (`UnexpectedFeedDecimals`) and `_readUsd8` re-checks the others at read time.
 *        - the L2 SEQUENCER UPTIME feed — deploy with `answer_ = 0` ("sequencer up"); `startedAt` is
 *          reported 30 days in the past so any `gracePeriod` (bounded to `<= 1 day`) is cleared.
 *
 *      The answer is frozen but MOVABLE: to simulate a price move, deploy a second `FreshFeed` with
 *      the new answer and `tenderly_setCode` it over the same address again.
 *
 *      NOT FOR MAINNET, and never imported by `src/`. Real Chainlink feeds are genuinely fresh on
 *      Base and the `tenderly_*` cheat-RPCs do not exist there.
 */
contract FreshFeed {
    /// @dev Frozen answer, in `DECIMALS` fixed point. `0` for the sequencer-uptime shape (= up).
    int256 private immutable ANSWER;

    /// @dev Mirrors the replaced aggregator's `decimals()` — load-bearing, see the contract docs.
    uint8 private immutable DECIMALS;

    /// @param answer_   The frozen answer to report (a price at `decimals_`, or `0` for "sequencer up").
    /// @param decimals_ The replaced aggregator's decimals (8 for every price feed the strategy reads).
    constructor(int256 answer_, uint8 decimals_) {
        ANSWER = answer_;
        DECIMALS = decimals_;
    }

    function decimals() external view returns (uint8) {
        return DECIMALS;
    }

    function description() external pure returns (string memory) {
        return "vnet FreshFeed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestAnswer() external view returns (int256) {
        return ANSWER;
    }

    /// @dev A 60-second lag rather than exactly `block.timestamp`: it is what a healthy feed looks
    ///      like, and it keeps any consumer that computes `block.timestamp - updatedAt` off the
    ///      zero/underflow edge if it reads at a block older than the one it prices against.
    function latestTimestamp() external view returns (uint256) {
        return block.timestamp - 60;
    }

    function latestRound() external pure returns (uint256) {
        return 1000;
    }

    /// @return roundId         Constant `1000` — no round history is simulated.
    /// @return answer          The frozen `ANSWER`.
    /// @return startedAt       `block.timestamp - 30 days`, so a sequencer `gracePeriod` always clears.
    /// @return updatedAt       `block.timestamp - 60` — always fresh (see {latestTimestamp}).
    /// @return answeredInRound Constant `1000`.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1000, ANSWER, block.timestamp - 30 days, block.timestamp - 60, 1000);
    }

    /// @dev Round-agnostic: any `roundId` returns the same tuple as {latestRoundData}.
    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1000, ANSWER, block.timestamp - 30 days, block.timestamp - 60, 1000);
    }
}
