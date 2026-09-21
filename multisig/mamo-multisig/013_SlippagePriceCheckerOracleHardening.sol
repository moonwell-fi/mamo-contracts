// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title SlippagePriceCheckerOracleHardening
 * @notice Ships the Sherlock oracle-hardening fixes to the live SlippagePriceChecker proxy AND turns
 *         them on in the same release.
 * @dev The implementation alone is inert. `_requireSequencerUp()` returns early while
 *      `sequencerUptimeFeed == address(0)`, which is deliberately the state an in-place upgrade lands
 *      in so the upgrade itself cannot brick pricing — but it also means MOO-741 stays exactly as
 *      unmitigated as before unless the same release calls `setSequencerUptimeFeed`. This proposal
 *      batches the four steps the Safe must execute atomically:
 *
 *        1. `upgradeToAndCall(newImplementation, "")` on CHAINLINK_SWAP_CHECKER_PROXY.
 *        2. `setSequencerUptimeFeed(CHAINLINK_L2_SEQUENCER_UPTIME_FEED, 3600)` — Base's Chainlink
 *           "L2 Sequencer Uptime Status Feed" (0xBCF8...6433, verified on chain: answer 0 = up).
 *        3. `backfillPairCount(...)` for every token pair configured BEFORE `configuredPairCount`
 *           existed. The nested `tokenPairOracleData` mapping cannot be enumerated on chain, so
 *           without this step `isRewardToken()` answers for those tokens only through the legacy
 *           `maxTimePriceValid` flag and `removeTokenConfiguration` cannot distinguish "the last
 *           pair was just removed" from "this pair was never counted" (MOO-726 / counter skew).
 *        4. `addTokenConfiguration(...)` for xWELL -> WETH and MORPHO -> WETH, rewriting each pair
 *           with the same two hops but raising the ETH/USD leg's heartbeat from 1200s to 3600s. The
 *           live 1200s bound is below that feed's own ~1230s cadence, so those quotes revert
 *           "Price feed update time exceeds heartbeat" during the tail of every update cycle. This
 *           is a production liveness bug, and it must ship WITH the upgrade: step 3's pairCounted
 *           bookkeeping only exists in the new implementation, so rewriting the pairs beforehand
 *           would not be counted.
 *
 *      `validate()` asserts the guard ends up ENABLED and that both WETH pairs keep exactly their
 *      two hops with the corrected bound — which is what makes the MOO-741 claim true on the day
 *      this lands, and what stops the step-4 rewrite from silently reordering a quote path.
 */
contract SlippagePriceCheckerOracleHardening is MultisigProposal {
    /// @notice Seconds the sequencer must have been back up before prices are trusted again
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;

    /// @notice Corrected max age for the ETH/USD leg of the WETH reward pairs
    /// @dev The live configuration allows 1200s, which is BELOW that feed's own update cadence:
    ///      CHAINLINK_ETH_USD (0x71041ddd…) was measured on 2026-08-14 producing five consecutive
    ///      gaps of ~1230s. A bound under the cadence means the tail of every cycle is stale by
    ///      configuration, so getExpectedOut for xWELL -> WETH and MORPHO -> WETH reverts
    ///      "Price feed update time exceeds heartbeat" intermittently — a liveness bug for WETH
    ///      reward pricing, not merely a test flake. 3600 restores headroom and matches what
    ///      cbBTCStrategyConfig already uses for its own second leg.
    uint256 public constant WETH_PAIR_QUOTE_HEARTBEAT = 3600;

    /// @notice Max age for a reward token's own USD feed, carried over from the live configuration
    uint256 public constant REWARD_TOKEN_USD_HEARTBEAT = 86400;

    function _initializeAddresses() internal {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }

    function run() public override {
        _initializeAddresses();

        if (DO_DEPLOY) {
            deploy();
            addresses.updateJson();
            addresses.printJSONChanges();
        }

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
        if (DO_UPDATE_ADDRESS_JSON) addresses.updateJson();
    }

    function name() public pure override returns (string memory) {
        return "013_SlippagePriceCheckerOracleHardening";
    }

    function description() public pure override returns (string memory) {
        return
        "Upgrade SlippagePriceChecker and enable the L2 sequencer uptime guard and pair-count backfill in the same release";
    }

    function deploy() public override {
        address slippagePriceCheckerImplementation = address(new SlippagePriceChecker());
        addresses.changeAddress("CHAINLINK_SWAP_CHECKER_IMPLEMENTATION", slippagePriceCheckerImplementation, true);
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        address proxy = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        address implementation = addresses.getAddress("CHAINLINK_SWAP_CHECKER_IMPLEMENTATION");

        UUPSUpgradeable(proxy).upgradeToAndCall(implementation, "");

        SlippagePriceChecker priceChecker = SlippagePriceChecker(proxy);

        // Turn the guard ON in the same batch as the upgrade.
        priceChecker.setSequencerUptimeFeed(
            addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"), SEQUENCER_GRACE_PERIOD
        );

        // Register pre-upgrade pairs into configuredPairCount. backfillPairCount skips any pair with
        // no oracle data and any pair already counted, so an over-broad candidate list is harmless.
        address[] memory sellTokens = _sellTokens();
        address[] memory buyTokens = _buyTokens();
        for (uint256 i = 0; i < sellTokens.length; i++) {
            priceChecker.backfillPairCount(sellTokens[i], buyTokens);
        }

        // Correct the WETH reward pairs' quote-leg heartbeat. addTokenConfiguration replaces the
        // pair's feed array wholesale (it deletes before pushing), so each pair is rewritten with the
        // same two feeds in the same order and only the ETH/USD bound changes. Runs after the
        // backfill so the pairCounted bookkeeping is already in place; these pairs are counted by
        // then, so the rewrite cannot double-count them.
        priceChecker.addTokenConfiguration(
            addresses.getAddress("xWELL_PROXY"),
            addresses.getAddress("WETH"),
            _wethPairFeeds(addresses.getAddress("CHAINLINK_WELL_USD"))
        );
        priceChecker.addTokenConfiguration(
            addresses.getAddress("MORPHO"),
            addresses.getAddress("WETH"),
            _wethPairFeeds(addresses.getAddress("CHAINLINK_MORPHO_USD"))
        );
    }

    /// @dev The two-hop path a reward token takes to WETH: rewardToken/USD, then USD/ETH inverted.
    ///      Mirrors the live on-chain configuration exactly apart from the corrected quote heartbeat
    ///      (verified on chain: both pairs are [<token>/USD, false, 86400], [ETH/USD, true, 1200]).
    function _wethPairFeeds(address rewardTokenUsdFeed)
        internal
        view
        returns (ISlippagePriceChecker.TokenFeedConfiguration[] memory feeds)
    {
        feeds = new ISlippagePriceChecker.TokenFeedConfiguration[](2);
        feeds[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: rewardTokenUsdFeed,
            reverse: false,
            heartbeat: REWARD_TOKEN_USD_HEARTBEAT
        });
        feeds[1] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: addresses.getAddress("CHAINLINK_ETH_USD"),
            reverse: true,
            heartbeat: WETH_PAIR_QUOTE_HEARTBEAT
        });
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("MAMO_MULTISIG"));
    }

    function validate() public view override {
        address proxy = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");
        SlippagePriceChecker priceChecker = SlippagePriceChecker(proxy);

        // 1. The guard is ENABLED, not merely deployed.
        assertEq(
            priceChecker.sequencerUptimeFeed(),
            addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"),
            "Sequencer uptime feed must be wired by this release"
        );
        assertEq(priceChecker.sequencerGracePeriod(), SEQUENCER_GRACE_PERIOD, "Grace period must be set");

        // 2. Pricing still works with the guard on (the sequencer is up on Base).
        address well = addresses.getAddress("xWELL_PROXY");
        address morpho = addresses.getAddress("MORPHO");
        address usdc = addresses.getAddress("USDC");
        address cbBTC = addresses.getAddress("cbBTC");

        assertGt(priceChecker.getExpectedOut(1e18, well, usdc), 0, "WELL -> USDC should still quote");
        assertGt(priceChecker.getExpectedOut(1e18, morpho, cbBTC), 0, "MORPHO -> cbBTC should still quote");

        // 3. Pre-upgrade pairs are now represented in the counter, so isRewardToken() no longer
        //    depends on the legacy flag alone and removals stay accurate.
        assertGt(priceChecker.configuredPairCount(well), 0, "WELL pairs should be backfilled");
        assertGt(priceChecker.configuredPairCount(morpho), 0, "MORPHO pairs should be backfilled");
        assertTrue(priceChecker.pairCounted(well, usdc), "WELL -> USDC should be counted");
        assertTrue(priceChecker.pairCounted(morpho, cbBTC), "MORPHO -> cbBTC should be counted");
        assertTrue(priceChecker.isRewardToken(well), "WELL must remain a reward token");
        assertTrue(priceChecker.isRewardToken(morpho), "MORPHO must remain a reward token");

        // 4. The WETH pairs' quote leg now allows more than the ETH/USD feed's own cadence, and the
        //    rest of each pair is untouched. Asserting the first leg too is the guard against the
        //    rewrite silently dropping or reordering a hop, which would repoint the whole quote.
        address weth = addresses.getAddress("WETH");
        _assertWethPairFeeds(priceChecker, well, weth, addresses.getAddress("CHAINLINK_WELL_USD"));
        _assertWethPairFeeds(priceChecker, morpho, weth, addresses.getAddress("CHAINLINK_MORPHO_USD"));

        // And they still quote, which the 1200s bound could not be relied on to do.
        assertGt(priceChecker.getExpectedOut(1e18, well, weth), 0, "WELL -> WETH should quote");
        assertGt(priceChecker.getExpectedOut(1e18, morpho, weth), 0, "MORPHO -> WETH should quote");
    }

    function _assertWethPairFeeds(
        SlippagePriceChecker priceChecker,
        address rewardToken,
        address weth,
        address expectedRewardTokenUsdFeed
    ) internal view {
        ISlippagePriceChecker.TokenFeedConfiguration[] memory feeds =
            priceChecker.tokenPairOracleInformation(rewardToken, weth);

        assertEq(feeds.length, 2, "WETH pair must keep both hops");

        assertEq(feeds[0].chainlinkFeed, expectedRewardTokenUsdFeed, "First hop must stay the token's USD feed");
        assertFalse(feeds[0].reverse, "First hop must stay non-reversed");
        assertEq(feeds[0].heartbeat, REWARD_TOKEN_USD_HEARTBEAT, "First hop heartbeat must be unchanged");

        assertEq(feeds[1].chainlinkFeed, addresses.getAddress("CHAINLINK_ETH_USD"), "Second hop must stay ETH/USD");
        assertTrue(feeds[1].reverse, "Second hop must stay reversed");
        assertEq(feeds[1].heartbeat, WETH_PAIR_QUOTE_HEARTBEAT, "Second hop heartbeat must be corrected to 3600");
    }

    /// @dev Every token that may already have oracle pairs configured against it.
    function _sellTokens() internal view returns (address[] memory sellTokens) {
        sellTokens = new address[](6);
        sellTokens[0] = addresses.getAddress("xWELL_PROXY");
        sellTokens[1] = addresses.getAddress("MORPHO");
        sellTokens[2] = addresses.getAddress("AERO");
        sellTokens[3] = addresses.getAddress("cbBTC");
        sellTokens[4] = addresses.getAddress("WETH");
        sellTokens[5] = addresses.getAddress("VIRTUALS");
    }

    /// @dev Every token those pairs may quote into.
    function _buyTokens() internal view returns (address[] memory buyTokens) {
        buyTokens = new address[](4);
        buyTokens[0] = addresses.getAddress("USDC");
        buyTokens[1] = addresses.getAddress("cbBTC");
        buyTokens[2] = addresses.getAddress("WETH");
        buyTokens[3] = addresses.getAddress("MAMO");
    }
}
