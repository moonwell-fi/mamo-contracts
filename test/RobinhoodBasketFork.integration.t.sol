// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, Vm, console} from "@forge-std/Test.sol";

import {StockBasketStrategy} from "@contracts/robinhood/StockBasketStrategy.sol";

import {IERC4626} from "@interfaces/IERC4626.sol";
import {IPriceFeed} from "@interfaces/IPriceFeed.sol";

import {MockStrategyRegistry} from "./mocks/RobinhoodMocks.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title ChainlinkPairPriceChecker
 * @notice The smallest honest oracle for a stock/base-asset pair: two live Chainlink USD feeds, crossed.
 * @dev This is deliberately NOT a mock. `StockBasketStrategy` prices its NAV and bounds every swap through
 *      `getExpectedOut`, so pointing it at anything but the real feeds would make a fork suite prove nothing
 *      about the live system. It reads the RAW aggregators deployed on Robinhood Chain (8 decimals,
 *      `latestRoundData()`), crosses `priceIn / priceOut`, and rescales between the tokens' decimals
 *      (stocks 18, USDG 6).
 *
 *      Staleness is the market-hours guard in miniature (`docs/ROBINHOOD_PLAN.md` §5). Equity feeds freeze
 *      Fri ~21:00 UTC -> Mon 00:00 UTC and on market holidays; USDG/USD keeps a strict 24h heartbeat and
 *      updates through weekends. The bounds below (26h equity / 27h USDG) therefore detect "the market is
 *      closed", not intraday latency — exactly the property the product needs: sleeve paths keep working
 *      24/7 while equity paths halt rather than trade against a frozen price.
 *
 *      A production checker would also carry an NYSE calendar, `oraclePaused()` reads and a sequencer-uptime
 *      feed; this one carries only what the fork suite must exercise.
 */
contract ChainlinkPairPriceChecker {
    struct TokenConfig {
        address feed;
        uint8 tokenDecimals;
        uint256 maxStaleness;
    }

    uint256 public constant FEED_DECIMALS = 8;

    mapping(address => TokenConfig) public configOf;

    /// @notice Registers a token's USD feed. Reverts unless the feed reports 8 decimals, since the cross
    ///         rate below relies on both legs sharing a scale.
    function setFeed(address token, address feed, uint256 maxStaleness) external {
        require(feed != address(0), "Invalid feed address");
        require(IPriceFeed(feed).decimals() == FEED_DECIMALS, "Feed must be 8 decimals");

        configOf[token] =
            TokenConfig({feed: feed, tokenDecimals: IERC20Metadata(token).decimals(), maxStaleness: maxStaleness});
    }

    /// @notice Expected output of swapping `amountIn` of `fromToken` into `toToken` at live oracle prices
    function getExpectedOut(uint256 amountIn, address fromToken, address toToken) external view returns (uint256) {
        (uint256 priceIn, uint8 decimalsIn) = _price(fromToken);
        (uint256 priceOut, uint8 decimalsOut) = _price(toToken);

        return (amountIn * priceIn * (10 ** decimalsOut)) / (priceOut * (10 ** decimalsIn));
    }

    /// @notice Latest USD price for a token, reverting when the feed has gone stale (i.e. markets closed)
    function priceOf(address token) external view returns (uint256) {
        (uint256 price,) = _price(token);
        return price;
    }

    function _price(address token) internal view returns (uint256, uint8) {
        TokenConfig memory config = configOf[token];
        require(config.feed != address(0), "No feed configured for token");

        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(config.feed).latestRoundData();
        require(answer > 0, "Invalid oracle answer");
        require(block.timestamp - updatedAt <= config.maxStaleness, "Oracle price is stale");

        return (uint256(answer), config.tokenDecimals);
    }
}

/**
 * @title RobinhoodBasketForkIntegrationTest
 * @notice The live-market fork suite for `StockBasketStrategy`: the basket product run against the REAL
 *         Robinhood-issued stock tokens, their REAL Chainlink feeds, the REAL Uniswap V3 pools and the REAL
 *         Steakhouse USDG vault on Robinhood Chain (chain id 4663).
 *
 * @dev WHY THIS EXISTS ALONGSIDE THE UNIT SUITE
 *      `test/StockBasketStrategy.unit.t.sol` already proves the mechanics — buy-to-target, trim-the-winner,
 *      mandate enforcement, sleeve-first exits, oracle-deviation reverts — against mocks where the router
 *      fills at whatever price the test says. None of that touches the three things that can only be wrong
 *      on-chain, which is what this file is for:
 *
 *      1. IDENTITY. The stock tokens must be the genuine Jersey-issued Robinhood tokens. Impostor ERC-20s
 *         with copied symbols exist on this chain, so the suite asserts on `name()` ("… • Robinhood Token")
 *         rather than trusting a symbol, and checks the ERC-8056 `uiMultiplier()`. It also logs CRWD's
 *         multiplier (4e18 — a real 4:1 split) as the standing evidence that corporate actions happen and
 *         that oracle-NAV accounting must never multiply by it.
 *      2. PRICE. `getExpectedOut` is served here by live Chainlink aggregators, not a stub, so NAV, the
 *         rebalance targets and every `amountOutMinimum` are derived from the same prices production would
 *         use — including their staleness behaviour when equity markets close.
 *      3. LIQUIDITY. The oracle bound is only meaningful if real pools can actually fill inside it. The
 *         swap tests execute against the live 0.30% USDG pools, and `testForkOracleBoundBitesAgainstLivePool`
 *         proves the bound BINDS by pricing a trade the live pool provably cannot fill.
 *
 *      WHY IT IS ENV-GATED (same contract as `test/RobinhoodFork.integration.t.sol`)
 *      Every test needs an RPC to chain 4663; sandboxes without egress would otherwise fail CI for an
 *      environmental reason. The suite skips itself unless an RPC is reachable and lights up untouched when
 *      one is.
 *
 *      HOW TO RUN
 *          export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
 *          make robinhood-fork      # runs this suite and the chassis fork suite
 *
 *      It also picks up an already-active fork:
 *          forge test --fork-url https://rpc.mainnet.chain.robinhood.com \
 *              --match-path "test/RobinhoodBasketFork.integration.t.sol" -vv
 *
 *      MARKET HOURS
 *      Tests that must trade equities skip themselves (with a log) when any equity feed is stale, because a
 *      revert there is the CORRECT behaviour, not a failure. The sleeve-only paths — deposit, NAV, ground
 *      truths — run every day of the week, which is precisely the graceful degradation the product claims.
 */
contract RobinhoodBasketForkIntegrationTest is Test {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    // ==================== LIVE ADDRESSES (verified on-chain) ====================

    /// @dev Paxos-issued Global Dollar, the chain's base asset (6 decimals)
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev Steakhouse USDG Vault V2, the yield sleeve behind Robinhood Earn
    address internal constant STEAKHOUSE_USDG_VAULT = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;

    /// @dev Uniswap SwapRouter02 — dispatches only the no-deadline `exactInputSingle` (selector 0x04e45aaf)
    address internal constant UNISWAP_SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    /// @dev Uniswap QuoterV2, used by the test (never by the strategy) to read what a pool would really fill
    address internal constant UNISWAP_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;

    /// @dev The genuine Robinhood stock tokens (18 decimals, `uiMultiplier() == 1e18`)
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    /// @dev Corporate-action evidence only — never traded here. 4:1 split => `uiMultiplier() == 4e18`.
    address internal constant CRWD = 0xea72Ecca2d0f6bFA1394DBBCff85b52CD4233931;

    /// @dev Chainlink RAW aggregators (8 decimals, AggregatorV3-compatible)
    address internal constant USDG_USD_FEED = 0x8bEeE3503F6860D5dac4cE26b5eEe92982951c2e;
    address internal constant AAPL_USD_FEED = 0xBb11A21267cFDb63d4935d99a499133DD1744ACb;
    address internal constant NVDA_USD_FEED = 0xC9d16E4f2569b9E3ea0468fD85844953713DC2a2;
    address internal constant TSLA_USD_FEED = 0x7A6b81ba7FbCB90104d8C496158Cf383cD7233b1;

    // ==================== PRODUCT PARAMETERS ====================

    uint256 internal constant STRATEGY_TYPE_ID = 3;

    /// @dev All three stocks quote against USDG in the 0.30% tier; the strategy has one pool fee for the basket
    uint24 internal constant POOL_FEE = 3000;

    /// @dev 3% — comfortably above the ~32-55bps of fee + impact + oracle deviation measured at these sizes
    uint256 internal constant SLIPPAGE_BPS = 300;

    /// @dev The mandate: equities may never exceed 60% of NAV
    uint256 internal constant MAX_TOTAL_STOCK_BPS = 6000;

    /// @dev 20% NVDA / 15% AAPL / 10% TSLA => 45% equities, 55% earning in the sleeve
    uint256 internal constant NVDA_WEIGHT_BPS = 2000;
    uint256 internal constant AAPL_WEIGHT_BPS = 1500;
    uint256 internal constant TSLA_WEIGHT_BPS = 1000;
    uint256 internal constant TOTAL_STOCK_BPS = NVDA_WEIGHT_BPS + AAPL_WEIGHT_BPS + TSLA_WEIGHT_BPS;

    /// @dev 2000 USDG: large enough for three meaningful legs, small enough to stay <1% of the thinnest pool
    uint256 internal constant DEPOSIT_AMOUNT = 2000e6;

    /// @dev Dust filter for rebalance legs
    uint256 internal constant MIN_TRADE_VALUE = 10e6;

    /// @dev Withdrawal covered entirely by the ~1100 USDG sleeve, so stocks must not be touched
    uint256 internal constant SLEEVE_ONLY_WITHDRAWAL = 500e6;

    /// @dev Trade size used to prove the oracle bound binds against real liquidity
    uint256 internal constant PROBE_TRADE_SIZE = 500e6;

    // ==================== STALENESS / MARKET-HOURS BOUNDS ====================

    /// @dev USDG/USD keeps a strict 24h heartbeat and updates on weekends; 27h is "the feed is broken"
    uint256 internal constant USDG_MAX_STALENESS = 27 hours;

    /// @dev Equity feeds update every ~20-30min while markets are open; 26h means "markets are closed"
    uint256 internal constant EQUITY_MAX_STALENESS = 26 hours;

    address public backend = makeAddr("backend");
    address public user = makeAddr("user");

    bool public forkEnabled;

    MockStrategyRegistry public registry;
    ChainlinkPairPriceChecker public priceChecker;
    StockBasketStrategy public strategy;

    address[3] internal stocks = [NVDA, AAPL, TSLA];
    address[3] internal stockFeeds = [NVDA_USD_FEED, AAPL_USD_FEED, TSLA_USD_FEED];
    string[3] internal stockSymbols = ["NVDA", "AAPL", "TSLA"];

    /// @dev Skips the body (marking the test skipped) when no Robinhood Chain RPC is reachable.
    modifier onlyFork() {
        if (!forkEnabled) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));

        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
            forkEnabled = true;
        } else if (block.chainid == ROBINHOOD_CHAIN_ID) {
            // already forked via --fork-url
            forkEnabled = true;
        } else {
            console.log("RobinhoodBasketFork: ROBINHOOD_RPC_URL not set and no 4663 fork active - skipping suite");
            return;
        }

        assertEq(block.chainid, ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (expected chain id 4663)");

        registry = new MockStrategyRegistry(backend);

        priceChecker = new ChainlinkPairPriceChecker();
        priceChecker.setFeed(USDG, USDG_USD_FEED, USDG_MAX_STALENESS);
        for (uint256 i = 0; i < stocks.length; i++) {
            priceChecker.setFeed(stocks[i], stockFeeds[i], EQUITY_MAX_STALENESS);
        }

        strategy = StockBasketStrategy(payable(_deployStrategy(user)));
        registry.setUserStrategy(user, address(strategy), true);
    }

    // ==================== 1. GROUND TRUTHS ====================

    /// @notice The identity checks that a mock can never make: genuine tokens, sane feeds, live prices.
    /// @dev Runs regardless of market hours — it reads feeds directly rather than through the staleness guard.
    function testForkStockTokensAndFeedsGroundTruths() public onlyFork {
        console.log("--- block %s, timestamp %s ---", vm.toString(block.number), vm.toString(block.timestamp));

        for (uint256 i = 0; i < stocks.length; i++) {
            address stock = stocks[i];

            assertGt(stock.code.length, 0, "stock token has no code at the documented address");
            assertEq(IERC20Metadata(stock).decimals(), 18, "stock tokens are 18 decimals");

            string memory name = IERC20Metadata(stock).name();
            string memory symbol = IERC20Metadata(stock).symbol();

            console.log("%s: name '%s'", stockSymbols[i], name);
            console.log(
                "%s: symbol '%s', totalSupply %s", stockSymbols[i], symbol, vm.toString(IERC20(stock).totalSupply())
            );

            // Impostor guard: symbols are free to copy, the issuer's naming is the distinguishing mark.
            assertTrue(_contains(name, "Robinhood Token"), "not a genuine Robinhood-issued token (name mismatch)");
            assertEq(symbol, stockSymbols[i], "unexpected symbol at the documented address");

            // ERC-8056: raw balances are stable, so NAV must never be multiplied by this. 1e18 = no action yet.
            uint256 multiplier = _uiMultiplier(stock);
            console.log("%s: uiMultiplier %s", symbol, vm.toString(multiplier));
            assertEq(multiplier, 1e18, "unexpected corporate-action multiplier for this token");

            // live feed sanity
            (int256 answer, uint256 updatedAt) = _readFeed(stockFeeds[i]);
            assertGt(answer, 0, "equity feed returned a non-positive price");
            console.log(
                "%s: oracle $%s, feed age %ss", symbol, _usdString(uint256(answer)), vm.toString(_age(updatedAt))
            );
        }

        // Standing evidence that corporate actions are real on this chain: CRWD did a 4:1 split.
        uint256 crwdMultiplier = _uiMultiplier(CRWD);
        console.log("CRWD ('%s'): uiMultiplier %s", IERC20Metadata(CRWD).name(), vm.toString(crwdMultiplier));
        assertEq(crwdMultiplier, 4e18, "CRWD should still show its 4:1 split multiplier");

        // The base asset's feed: everything in the basket is crossed through this one.
        (int256 usdgAnswer, uint256 usdgUpdatedAt) = _readFeed(USDG_USD_FEED);
        console.log(
            "USDG: oracle %s (8dp raw), feed age %ss",
            vm.toString(uint256(usdgAnswer)),
            vm.toString(_age(usdgUpdatedAt))
        );
        assertGe(usdgAnswer, int256(0.98e8), "USDG/USD below the peg band");
        assertLe(usdgAnswer, int256(1.02e8), "USDG/USD above the peg band");

        console.log("markets open (all equity feeds fresh):", _marketOpen());
    }

    // ==================== 2. DEPOSIT (SLEEVE-ONLY PATH, RUNS 24/7) ====================

    /// @notice "Deposit is cheap": user funds land wholly in the live Steakhouse vault, no equity trade.
    /// @dev The product claim this proves is availability — a deposit must work at 3am on a Sunday, when
    ///      every equity feed is frozen and no stock could be priced at all.
    function testForkDepositLandsEntirelyInSleeve() public onlyFork {
        _fundUser(DEPOSIT_AMOUNT);

        vm.startPrank(user);
        IERC20(USDG).approve(address(strategy), type(uint256).max);
        strategy.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        for (uint256 i = 0; i < stocks.length; i++) {
            assertEq(IERC20(stocks[i]).balanceOf(address(strategy)), 0, "deposit must not buy stocks");
        }

        uint256 sleeveShares = IERC20(STEAKHOUSE_USDG_VAULT).balanceOf(address(strategy));
        uint256 sleeveAssets = IERC4626(STEAKHOUSE_USDG_VAULT).convertToAssets(sleeveShares);

        console.log("sleeve shares:  %s", vm.toString(sleeveShares));
        console.log("sleeve assets:  %s USDG (6dp)", vm.toString(sleeveAssets));
        console.log("getTotalBalance: %s", vm.toString(strategy.getTotalBalance()));

        assertGt(sleeveShares, 0, "deposit should mint real Steakhouse vault shares");
        assertEq(IERC20(USDG).balanceOf(address(strategy)), 0, "nothing should sit idle after a deposit");
        // Vault V2 rounds share issuance down; a couple of units of drift is rounding, not loss.
        assertApproxEqAbs(strategy.getTotalBalance(), DEPOSIT_AMOUNT, 2, "NAV should track the deposit");
    }

    // ==================== 3. REBALANCE THROUGH LIVE POOLS ====================

    /// @notice The agent's buy-to-target pass, executed against the live 0.30% USDG pools.
    /// @dev Every `amountOutMinimum` here comes from the live Chainlink cross rate, so a fill only happens
    ///      if the real pool price sits inside 300bps of the real oracle. That coupling is the whole product.
    function testForkRebalanceBuysBasketThroughLivePools() public onlyFork {
        _skipIfMarketClosed("rebalance buys equities");

        _depositAll();

        uint256 navBefore = strategy.getTotalBalance();

        vm.recordLogs();
        vm.prank(backend);
        strategy.rebalance(MIN_TRADE_VALUE);
        _logSwaps();

        uint256 navAfter = strategy.getTotalBalance();
        uint256 stockValue;

        for (uint256 i = 0; i < stocks.length; i++) {
            uint256 balance = IERC20(stocks[i]).balanceOf(address(strategy));
            assertGt(balance, 0, "every basket leg should have been bought");

            uint256 value = priceChecker.getExpectedOut(balance, stocks[i], USDG);
            stockValue += value;

            console.log(
                "%s: balance %s, oracle value %s USDG", stockSymbols[i], vm.toString(balance), vm.toString(value)
            );
        }

        uint256 sleeveValue =
            IERC4626(STEAKHOUSE_USDG_VAULT).convertToAssets(IERC20(STEAKHOUSE_USDG_VAULT).balanceOf(address(strategy)));

        console.log("NAV before %s -> after %s", vm.toString(navBefore), vm.toString(navAfter));
        console.log("NAV drift: %s bps", vm.toString(_driftBps(navBefore, navAfter)));
        console.log(
            "stock value %s (%s bps of NAV)", vm.toString(stockValue), vm.toString(stockValue * 10000 / navAfter)
        );
        console.log(
            "sleeve value %s (%s bps of NAV)", vm.toString(sleeveValue), vm.toString(sleeveValue * 10000 / navAfter)
        );

        // NAV is measured at oracle prices, so this drift is pure trading cost: 30bps of pool fee plus impact
        // plus however far the pool sits from the oracle, applied to the 45% that traded.
        assertApproxEqRel(navAfter, navBefore, 0.02e18, "rebalance should not bleed more than 2% of NAV");

        // The mandate and the target mix, measured against live oracle valuations
        assertApproxEqRel(stockValue, (navAfter * TOTAL_STOCK_BPS) / 10000, 0.05e18, "equity share off target");
        assertApproxEqRel(
            sleeveValue, (navAfter * (10000 - TOTAL_STOCK_BPS)) / 10000, 0.05e18, "sleeve share off target"
        );
        assertLe(stockValue * 10000 / navAfter, MAX_TOTAL_STOCK_BPS, "equity exposure breached the mandate");
        assertEq(IERC20(USDG).balanceOf(address(strategy)), 0, "leftover base asset should be parked in the sleeve");
    }

    // ==================== 4. SLEEVE-FIRST WITHDRAWAL ====================

    /// @notice A funded basket must still pay ordinary withdrawals out of the sleeve without selling equity.
    /// @dev This is what makes the market-hours guard survivable: the common exit path never touches a pool.
    function testForkSleeveFirstWithdrawalNeverTouchesStocks() public onlyFork {
        _skipIfMarketClosed("setup requires a rebalance");

        _depositAll();

        vm.prank(backend);
        strategy.rebalance(MIN_TRADE_VALUE);

        uint256[3] memory balancesBefore;
        for (uint256 i = 0; i < stocks.length; i++) {
            balancesBefore[i] = IERC20(stocks[i]).balanceOf(address(strategy));
        }

        uint256 sleeveBefore =
            IERC4626(STEAKHOUSE_USDG_VAULT).convertToAssets(IERC20(STEAKHOUSE_USDG_VAULT).balanceOf(address(strategy)));
        assertGt(sleeveBefore, SLEEVE_ONLY_WITHDRAWAL, "test premise: the sleeve alone covers the withdrawal");

        uint256 userBefore = IERC20(USDG).balanceOf(user);

        vm.prank(user);
        strategy.withdraw(SLEEVE_ONLY_WITHDRAWAL);

        uint256 sleeveAfter =
            IERC4626(STEAKHOUSE_USDG_VAULT).convertToAssets(IERC20(STEAKHOUSE_USDG_VAULT).balanceOf(address(strategy)));

        console.log("sleeve %s -> %s USDG", vm.toString(sleeveBefore), vm.toString(sleeveAfter));
        console.log("user received: %s USDG", vm.toString(IERC20(USDG).balanceOf(user) - userBefore));

        assertEq(IERC20(USDG).balanceOf(user) - userBefore, SLEEVE_ONLY_WITHDRAWAL, "withdrawal must pay in full");

        for (uint256 i = 0; i < stocks.length; i++) {
            assertEq(
                IERC20(stocks[i]).balanceOf(address(strategy)), balancesBefore[i], "sleeve-covered exit sold equity"
            );
        }
        assertApproxEqAbs(
            sleeveBefore - sleeveAfter, SLEEVE_ONLY_WITHDRAWAL, 2, "the sleeve should fund exactly the withdrawal"
        );
    }

    // ==================== 5. FULL EXIT THROUGH LIVE POOLS ====================

    /// @notice The complete round trip: USDG in, basket bought, basket sold, USDG out — all on live venues.
    /// @dev The number this test exists to produce is the round-trip cost in bps: two swap legs (buy + sell)
    ///      on 45% of NAV, plus the sleeve's rounding. That is the real drag a user pays for the product.
    function testForkFullExitSellsBasketThroughLivePools() public onlyFork {
        _skipIfMarketClosed("full exit sells equities");

        _depositAll();

        vm.prank(backend);
        strategy.rebalance(MIN_TRADE_VALUE);

        vm.recordLogs();
        vm.prank(user);
        strategy.withdrawAll();
        _logSwaps();

        uint256 received = IERC20(USDG).balanceOf(user);
        uint256 roundTripCostBps =
            received >= DEPOSIT_AMOUNT ? 0 : ((DEPOSIT_AMOUNT - received) * 10000) / DEPOSIT_AMOUNT;

        console.log("deposited %s USDG -> returned %s USDG", vm.toString(DEPOSIT_AMOUNT), vm.toString(received));
        console.log("ROUND-TRIP COST: %s bps", vm.toString(roundTripCostBps));

        for (uint256 i = 0; i < stocks.length; i++) {
            assertEq(IERC20(stocks[i]).balanceOf(address(strategy)), 0, "full exit must sell the entire basket");
        }

        assertEq(IERC20(STEAKHOUSE_USDG_VAULT).balanceOf(address(strategy)), 0, "sleeve should be fully redeemed");
        assertEq(strategy.getTotalBalance(), 0, "position fully closed");
        assertApproxEqRel(received, DEPOSIT_AMOUNT, 0.04e18, "round trip should cost less than 4% of NAV");
    }

    // ==================== 6. THE ORACLE BOUND vs REAL LIQUIDITY ====================

    /// @notice Proves the oracle bound actually binds against real pool liquidity, not just against a mock.
    /// @dev The unit suite shows the strategy reverts when a MOCK router underfills. That is a statement
    ///      about the mock. Here the tolerance is tightened to 1bp — below the pool's own 30bps fee — and the
    ///      live QuoterV2 is asked what the pool would really fill. When the quote lands under the oracle
    ///      minimum (the normal case), the rebalance must revert rather than trade: the bound is load-bearing
    ///      against genuine liquidity, which is the guarantee the product sells.
    function testForkOracleBoundBitesAgainstLivePool() public onlyFork {
        _skipIfMarketClosed("probe trades against live pools");

        uint256 quotedOut = _quoteExactInputSingle(USDG, NVDA, PROBE_TRADE_SIZE, POOL_FEE);
        uint256 expectedOut = priceChecker.getExpectedOut(PROBE_TRADE_SIZE, USDG, NVDA);
        uint256 minOut = (expectedOut * (10000 - 1)) / 10000; // 1bp tolerance

        console.log("probe: %s USDG -> NVDA", vm.toString(PROBE_TRADE_SIZE));
        console.log("  pool quote:    %s", vm.toString(quotedOut));
        console.log("  oracle expects:%s", vm.toString(expectedOut));
        console.log("  minOut @ 1bp:  %s", vm.toString(minOut));
        console.log("  pool vs oracle: %s bps worse", vm.toString(_driftBps(expectedOut, quotedOut)));

        if (quotedOut >= minOut) {
            console.log("live pool currently beats the oracle by more than 1bp - nothing to prove, skipping");
            vm.skip(true);
            return;
        }

        vm.prank(user);
        strategy.setSlippage(1);
        assertEq(strategy.allowedSlippageInBps(), 1, "slippage should be tightened to 1bp");

        _depositAll();

        // SwapRouter02's own guard fires on the oracle-derived amountOutMinimum
        vm.prank(backend);
        vm.expectRevert("Too little received");
        strategy.rebalance(MIN_TRADE_VALUE);

        // and the position is untouched: no partial fills, no equity bought at a bad price
        for (uint256 i = 0; i < stocks.length; i++) {
            assertEq(IERC20(stocks[i]).balanceOf(address(strategy)), 0, "no leg should have executed");
        }
        assertApproxEqAbs(strategy.getTotalBalance(), DEPOSIT_AMOUNT, 2, "NAV untouched by the rejected rebalance");
    }

    // ==================== HELPERS ====================

    function _deployStrategy(address owner) internal returns (address) {
        address[] memory stockTokens = new address[](3);
        stockTokens[0] = NVDA;
        stockTokens[1] = AAPL;
        stockTokens[2] = TSLA;

        uint256[] memory weights = new uint256[](3);
        weights[0] = NVDA_WEIGHT_BPS;
        weights[1] = AAPL_WEIGHT_BPS;
        weights[2] = TSLA_WEIGHT_BPS;

        StockBasketStrategy.InitParams memory params = StockBasketStrategy.InitParams({
            mamoStrategyRegistry: address(registry),
            token: USDG,
            yieldVault: STEAKHOUSE_USDG_VAULT,
            slippagePriceChecker: address(priceChecker),
            dexRouter: UNISWAP_SWAP_ROUTER_02,
            strategyTypeId: STRATEGY_TYPE_ID,
            owner: owner,
            allowedSlippageInBps: SLIPPAGE_BPS,
            maxTotalStockBps: MAX_TOTAL_STOCK_BPS,
            poolFee: POOL_FEE,
            stockTokens: stockTokens,
            stockWeightsBps: weights
        });

        StockBasketStrategy implementation = new StockBasketStrategy();
        return
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(StockBasketStrategy.initialize, (params))));
    }

    /// @dev Funds the user and deposits the whole balance, so post-exit balances read as pure round-trip P&L.
    function _depositAll() internal {
        _fundUser(DEPOSIT_AMOUNT);

        vm.startPrank(user);
        IERC20(USDG).approve(address(strategy), type(uint256).max);
        strategy.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    /// @dev `deal` rewrites USDG's balance storage on this chain (verified by the chassis fork suite); the
    ///      `ROBINHOOD_USDG_WHALE` fallback covers a future Paxos implementation change.
    function _fundUser(uint256 amount) internal {
        try this.dealExternal(USDG, user, amount) {} catch {}

        if (IERC20(USDG).balanceOf(user) < amount) {
            address whale = vm.envOr("ROBINHOOD_USDG_WHALE", address(0));
            require(whale != address(0), "deal() failed on USDG - set ROBINHOOD_USDG_WHALE and rerun");
            vm.prank(whale);
            IERC20(USDG).transfer(user, amount);
        }

        assertGe(IERC20(USDG).balanceOf(user), amount, "could not source USDG for the test user");
    }

    /// @dev `deal` is internal to StdCheats; this wrapper makes it try/catch-able.
    function dealExternal(address token, address to, uint256 give) external {
        deal(token, to, give);
    }

    /// @notice True when every equity feed has updated inside the equity staleness bound.
    /// @dev A 26h bound detects "the market is closed" (Fri ~21:00 UTC -> Mon 00:00 UTC, plus holidays),
    ///      not intraday latency — mid-week these feeds move every ~20-30 minutes.
    function _marketOpen() internal view returns (bool) {
        for (uint256 i = 0; i < stockFeeds.length; i++) {
            (, uint256 updatedAt) = _readFeed(stockFeeds[i]);
            if (_age(updatedAt) > EQUITY_MAX_STALENESS) return false;
        }
        return true;
    }

    /// @dev Equity paths must halt when markets are closed; skipping mirrors that, since a revert there is
    ///      the designed behaviour rather than a defect.
    function _skipIfMarketClosed(string memory what) internal {
        if (_marketOpen()) return;

        for (uint256 i = 0; i < stockFeeds.length; i++) {
            (, uint256 updatedAt) = _readFeed(stockFeeds[i]);
            console.log("%s feed age: %ss", stockSymbols[i], vm.toString(_age(updatedAt)));
        }
        console.log("EQUITY MARKETS CLOSED - skipping '%s' (the oracle guard would correctly revert)", what);
        vm.skip(true);
    }

    function _readFeed(address feed) internal view returns (int256 answer, uint256 updatedAt) {
        (, answer,, updatedAt,) = IPriceFeed(feed).latestRoundData();
    }

    function _age(uint256 updatedAt) internal view returns (uint256) {
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }

    function _uiMultiplier(address stock) internal view returns (uint256) {
        (bool ok, bytes memory ret) = stock.staticcall(abi.encodeWithSignature("uiMultiplier()"));
        require(ok && ret.length == 32, "token does not expose uiMultiplier()");
        return abi.decode(ret, (uint256));
    }

    /// @dev QuoterV2 is state-mutating by design (it reverts inside the swap and decodes the revert data), so
    ///      it is called here through the test's own external call rather than as a `view`.
    function _quoteExactInputSingle(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        internal
        returns (uint256 amountOut)
    {
        (bool ok, bytes memory ret) = UNISWAP_QUOTER_V2.call(
            abi.encodeWithSignature(
                "quoteExactInputSingle((address,address,uint256,uint24,uint160))",
                tokenIn,
                tokenOut,
                amountIn,
                fee,
                uint160(0)
            )
        );
        require(ok, "QuoterV2 call failed");
        (amountOut,,,) = abi.decode(ret, (uint256, uint160, uint32, uint256));
    }

    /// @dev Drift of `actual` below `reference`, in basis points (0 when actual >= reference).
    function _driftBps(uint256 baseline, uint256 actual) internal pure returns (uint256) {
        if (actual >= baseline || baseline == 0) return 0;
        return ((baseline - actual) * 10000) / baseline;
    }

    /// @notice Prints every StockBought / StockSold emitted by the last recorded call, with effective prices.
    function _logSwaps() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 bought = keccak256("StockBought(address,uint256,uint256)");
        bytes32 sold = keccak256("StockSold(address,uint256,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(strategy)) continue;

            bool isBuy = logs[i].topics[0] == bought;
            if (!isBuy && logs[i].topics[0] != sold) continue;

            address stock = address(uint160(uint256(logs[i].topics[1])));
            (uint256 amountIn, uint256 amountOut) = abi.decode(logs[i].data, (uint256, uint256));

            if (isBuy) {
                // amountIn is USDG (6dp), amountOut is stock (18dp): effective price in USDG per share
                uint256 effective = amountOut == 0 ? 0 : (amountIn * 1e18) / amountOut;
                console.log(
                    "BUY  %s: %s USDG -> %s shares", _symbol(stock), vm.toString(amountIn), vm.toString(amountOut)
                );
                console.log("     effective $%s vs oracle $%s", _usdString(effective * 100), _oracleUsd(stock));
            } else {
                // amountIn is stock (18dp), amountOut is USDG (6dp): effective price in USDG per share
                uint256 effective = amountIn == 0 ? 0 : (amountOut * 1e18) / amountIn;
                console.log(
                    "SELL %s: %s shares -> %s USDG", _symbol(stock), vm.toString(amountIn), vm.toString(amountOut)
                );
                console.log("     effective $%s vs oracle $%s", _usdString(effective * 100), _oracleUsd(stock));
            }
        }
    }

    function _symbol(address token) internal view returns (string memory) {
        return IERC20Metadata(token).symbol();
    }

    function _oracleUsd(address stock) internal view returns (string memory) {
        return _usdString(priceChecker.priceOf(stock));
    }

    /// @dev Formats an 8-decimal USD price as "305.29" for readable logs.
    function _usdString(uint256 price8) internal pure returns (string memory) {
        uint256 cents = ((price8 % 1e8) * 100) / 1e8;
        string memory fraction = cents < 10 ? string.concat("0", vm.toString(cents)) : vm.toString(cents);
        return string.concat(vm.toString(price8 / 1e8), ".", fraction);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;

        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
