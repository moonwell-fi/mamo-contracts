// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";

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
 *      batches the three steps the Safe must execute atomically:
 *
 *        1. `upgradeToAndCall(newImplementation, "")` on CHAINLINK_SWAP_CHECKER_PROXY.
 *        2. `setSequencerUptimeFeed(CHAINLINK_L2_SEQUENCER_UPTIME_FEED, 3600)` — Base's Chainlink
 *           "L2 Sequencer Uptime Status Feed" (0xBCF8...6433, verified on chain: answer 0 = up).
 *        3. `backfillPairCount(...)` for every token pair configured BEFORE `configuredPairCount`
 *           existed. The nested `tokenPairOracleData` mapping cannot be enumerated on chain, so
 *           without this step `isRewardToken()` answers for those tokens only through the legacy
 *           `maxTimePriceValid` flag and `removeTokenConfiguration` cannot distinguish "the last
 *           pair was just removed" from "this pair was never counted" (MOO-726 / counter skew).
 *
 *      `validate()` asserts the guard ends up ENABLED, which is the only thing that makes the
 *      MOO-741 claim true on the day this lands.
 */
contract SlippagePriceCheckerOracleHardening is MultisigProposal {
    /// @notice Seconds the sequencer must have been back up before prices are trusted again
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;

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
