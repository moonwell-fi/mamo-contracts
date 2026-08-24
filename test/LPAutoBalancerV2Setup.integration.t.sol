// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2Setup} from "../multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol";

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {Test} from "@forge-std/Test.sol";

import {LPGeometryLib} from "@contracts/libraries/LPGeometryLib.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IPriceFeed} from "@interfaces/IPriceFeed.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";

// ─────────────────────────────────────────────────────────────────────────────
// LPAutoBalancerV2SetupTest — REAL Base-fork exercise of the FPS phase-1 setup proposal.
//
// Mirrors LPAutoBalancerV2.integration.t.sol: PINNED fork at block 47_600_000 + the vm.fee(0)
// op-revm Isthmus workaround. setUp mints a REAL WETH/cbBTC Slipstream NFT to the F-MAMO Safe
// (the off-chain Phase-B precondition), then wires the proposal and injects tokenId + a test
// rebalancer EOA. test_proposal_lifecycle runs deploy/build/simulate/validate and then proves
// the registered position is operable: as the granted rebalancer, push the tick out of range and
// rebalanceUsingAlt(), expecting a successful single-sided rebuild with real liquidity.
//
// NO --fork-url on the make target: foundry 1.7.x would init the OP-stack L1Block handler against
// the CLI fork and panic before the in-test vm.fee(0) workaround runs. The fork is created here.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal swap ABI for the CL pool (Uniswap-V3-style swap + uniswapV3SwapCallback).
interface ICLPoolSwap {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract LPAutoBalancerV2SetupTest is Test {
    // Real Base addresses (resolved on-chain at the pinned block; identical to the V2 integration test).
    address constant POOL = 0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1;
    address constant NFPM = 0x827922686190790b37229fd06084350E74485b72;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    uint256 constant PINNED_BLOCK = 47_600_000;
    int24 constant TICK_SPACING = 100;

    /// @dev The allocation this run commits. A ROUND NUMBER chosen up front, not read back from the
    ///      minted position — the point of the parameter is that the position has to match the
    ///      target, not the other way round. Set explicitly (rather than relying on the proposal's
    ///      $50k default) so the setter itself is exercised.
    uint256 constant TARGET_ALLOCATION_USD = 25_000e8;

    uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;

    LPAutoBalancerV2Setup proposal;
    Addresses addresses;

    address safe; // F-MAMO
    address rebalancerEOA = makeAddr("lpRebalancer");
    uint256 tokenId;

    function setUp() public {
        // PIN THE BLOCK (mandatory) — deterministic fork.
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        // op-revm Isthmus operator-fee workaround (see V2 integration test).
        vm.txGasPrice(0);
        vm.fee(0);

        // FPS addresses for this chain.
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));

        safe = addresses.getAddress("F-MAMO");

        // Mint a REAL WETH/cbBTC Slipstream position owned by the F-MAMO Safe (Phase-B precondition),
        // sized from the target USD via the runbook's 50/50-by-value recipe.
        tokenId = _mintAllocationTo(safe, TARGET_ALLOCATION_USD);

        // Instantiate + wire the proposal.
        proposal = new LPAutoBalancerV2Setup();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
        proposal.setTokenId(tokenId);
        proposal.setRebalancerEOA(rebalancerEOA);
        proposal.setTotalAllocation(TARGET_ALLOCATION_USD, 500);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _align(int24 tick) internal pure returns (int24) {
        int24 q = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) q -= 1;
        return q * TICK_SPACING;
    }

    /// @dev Chainlink answer, 8-decimal, for a feed name in the address book.
    function _price(string memory feedName) internal view returns (uint256) {
        (, int256 answer,,,) = IPriceFeed(addresses.getAddress(feedName)).latestRoundData();
        require(answer > 0, "feed answer non-positive");
        return uint256(answer);
    }

    /// @dev Mint a real WETH/cbBTC CL position worth ~`targetUsd` (1e8) straddling spot.
    /// @dev Sized from the RANGE GEOMETRY, not from a 50/50 value split. A 50/50 split is only right
    ///      when spot sits at the range's centre, and at `tickSpacing` 100 the aligned centre can be
    ///      up to 99 ticks away from spot — at which point the legs bind ~25/75 and the NFPM refunds
    ///      a third of the intended size, putting the mint far outside the proposal's 500 bps band.
    ///      So: price one unit of liquidity across the actual `[tl, tu]` at the live `sqrtPriceX96`,
    ///      then scale to the target. Both legs bind together by construction.
    ///      NOTE the asymmetric decimals — WETH (token0) is 18dp, cbBTC (token1) is 8dp.
    function _mintAllocationTo(address recipient, uint256 targetUsd) internal returns (uint256 id) {
        (uint160 sqrtP, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        int24 tl = center - 200;
        int24 tu = center + 200;

        // Value of one reference unit of liquidity across this exact range, 1e8 USD.
        uint128 refLiq = 1e18;
        (uint256 r0, uint256 r1) = LPGeometryLib.amountsForLiquidityAtTicks(sqrtP, tl, tu, refLiq);
        uint256 refUsd = (r0 * _price("CHAINLINK_ETH_USD")) / 1e18 + (r1 * _price("CHAINLINK_BTC_USD")) / 1e8;
        require(refUsd > 0, "reference liquidity prices to zero");

        // Scale to the target, with a small headroom on the desired amounts so rounding in the
        // NFPM's own conversion cannot leave the mint a wei short of the band.
        uint256 amt0 = (r0 * targetUsd * 10_050) / (refUsd * 10_000);
        uint256 amt1 = (r1 * targetUsd * 10_050) / (refUsd * 10_000);
        return _mintMainPositionTo(recipient, amt0, amt1);
    }

    /// @dev Mint a real WETH/cbBTC CL position straddling spot, owned by `recipient`.
    function _mintMainPositionTo(address recipient, uint256 amt0, uint256 amt1) internal returns (uint256 id) {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        int24 tl = center - 200;
        int24 tu = center + 200;
        require(tl < spotTick && spotTick < tu, "setup: main must straddle spot");

        deal(WETH, address(this), amt0);
        deal(CBBTC, address(this), amt1);
        IERC20(WETH).approve(NFPM, amt0);
        IERC20(CBBTC).approve(NFPM, amt1);

        ICLPositionManager.MintParams memory mp = ICLPositionManager.MintParams({
            token0: WETH,
            token1: CBBTC,
            tickSpacing: TICK_SPACING,
            tickLower: tl,
            tickUpper: tu,
            amount0Desired: amt0,
            amount1Desired: amt1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp + 1,
            sqrtPriceX96: 0
        });
        (id,,,) = ICLPositionManager(NFPM).mint(mp);
    }

    /// @dev Push the pool tick DOWN (WETH in, cbBTC out) to drive the main fully out of range.
    function _pushTickDown(uint256 wethIn) internal {
        deal(WETH, address(this), wethIn);
        ICLPoolSwap(POOL).swap(address(this), true, int256(wethIn), MIN_SQRT_RATIO_PLUS_ONE, "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == POOL, "cb: bad caller");
        if (amount0Delta > 0) IERC20(WETH).transfer(POOL, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(CBBTC).transfer(POOL, uint256(amount1Delta));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @dev The single test below drives the main FULLY out of range on the token0 (WETH) side, so
    ///      the teardown returns 100% token0 and `_mainRange` takes the token0-majority single-sided
    ///      branch: [floorAlign(spot) + spacing, +width]. That is the range committed to here — the
    ///      off-chain half of the tick commitment a real rebalancer computes from a decision-time
    ///      snapshot before submitting.
    function _defaultRebalanceParams() internal view returns (LPAutoBalancerV2.RebalanceParams memory) {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 expectedTl = _align(spotTick) + TICK_SPACING;
        return LPAutoBalancerV2.RebalanceParams({
            width: 400,
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
            expectedTickUpper: expectedTl + 400
        });
    }

    // ─── test ──────────────────────────────────────────────────────────────────

    function test_proposal_lifecycle() public {
        // Precondition: the Safe holds the freshly minted NFT.
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(tokenId), safe, "Safe owns NFT pre-setup");

        // 1. Deploy LPAutoBalancerV2.
        proposal.deploy();

        address labAddr = addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2");
        assertTrue(labAddr != address(0), "balancer deployed");
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(labAddr));

        // 2-3. Build the Safe actions, simulate (Safe executes them atomically), validate.
        proposal.build();
        proposal.simulate();
        proposal.validate();

        // Post-setup sanity: NFT custodied by the balancer, rebalancer granted.
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(tokenId), labAddr, "balancer owns NFT post-setup");
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), rebalancerEOA), "rebalancer granted");

        // ── End-to-end: prove the registered position is OPERABLE by the granted rebalancer. ──
        // Stake the main into the gauge so rebalanceUsingAlt() exercises the unstake/skim/restake path.
        vm.prank(rebalancerEOA);
        lab.stake();

        // Accrue AERO + advance the TWAP observation window.
        skip(2 hours);
        vm.roll(block.number + 1);

        // Drive spot BELOW the main range → single-sided WETH withdrawal on rebalanceUsingAlt. The production
        // config gates rebalanceUsingAlt on |spot - TWAP| <= maxTickDeviation (100), so we cannot do a single
        // huge swap (its instantaneous spot vs the lagging 1800s TWAP would trip TwapDeviation).
        // Instead: do the swap, then skip well past twapWindow (1800s) so the TWAP converges onto
        // the post-swap tick and the deviation gate is back within tolerance at rebalanceUsingAlt time.
        (, int24 spotBefore,,,,) = ICLPool(POOL).slot0();
        _pushTickDown(2_000 ether);
        (, int24 spotOut,,,,) = ICLPool(POOL).slot0();
        assertTrue(spotOut < spotBefore, "swap pushed spot down");
        assertTrue(spotOut < int24(-266600), "main fully out of range, single-sided WETH");

        // Let the TWAP catch up to the new spot (skip >> twapWindow so the post-swap tick dominates).
        skip(2 hours);
        vm.roll(block.number + 1);

        // The fork PINS the block, so both Chainlink feeds' `updatedAt` is frozen while this test
        // warps 4 hours forward to accrue AERO and let the TWAP converge. On a live chain ETH/USD
        // and BTC/USD would each have published a dozen times across that window; on a pinned fork
        // they cannot, so the bound the proposal arms (3600s) correctly reads the warp as stale.
        // FREEZE both feeds' `updatedAt` at the current timestamp, preserving their real answers.
        // Not a re-publish: the mock encodes `updatedAt` once, here, and never tracks "now" — any
        // skip() past the armed bound AFTER this call goes stale exactly as the real feed would.
        // Deliberately NOT "widen the bound to make the test pass": the entire point of this test is
        // to assert the values the proposal actually ships, and loosening them here would hollow it
        // out into a test of a configuration nobody deploys.
        _refreshPriceFeeds();

        LPAutoBalancerV2.DecisionSnapshotV2 memory snapBefore = lab.getDecisionSnapshot();
        assertFalse(snapBefore.mainInRange, "main driven out of range");
        assertTrue(snapBefore.deviationGateOpen, "TWAP converged: deviation gate open for rebalanceUsingAlt");

        // As the granted rebalancer: rebalanceUsingAlt must succeed (no revert) and rebuild a real position.
        // HOISTED: _defaultRebalanceParams reads live spot (an external call). In ARGUMENT position
        // it would be evaluated first and consume the one-shot vm.prank, so the call would run as
        // this test contract and fail the REBALANCER_ROLE check.
        LPAutoBalancerV2.RebalanceParams memory rebalParams = _defaultRebalanceParams();
        vm.prank(rebalancerEOA);
        lab.rebalanceUsingAlt(rebalParams);

        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertGt(s.mainLiquidity, 0, "rebuilt main has real liquidity (operable, no swap)");
        assertTrue(s.mainStaked, "main restaked after rebalanceUsingAlt (was staked before)");
    }

    /// @dev The allocation assertion's non-vacuity control. Same chain state, same position, same
    ///      tolerance — only the TARGET moves, and validate() must fail. Without it, a band that
    ///      accepts everything (a 100% tolerance, a principal read returning 0, a validate() that
    ///      never reaches the check) is indistinguishable from a working one.
    function test_validate_rejectsWrongAllocation() public {
        proposal.deploy();
        proposal.build();
        proposal.simulate();

        // Sanity: at the committed target it passes. If this ever fails the mint recipe drifted and
        // the rejections below would prove nothing.
        proposal.validate();

        // 2x the real size, same 500 bps band → the position is ~50% under target.
        proposal.setTotalAllocation(TARGET_ALLOCATION_USD * 2, 500);
        vm.expectRevert("position under-allocated vs totalAllocationUsd");
        proposal.validate();

        // Half the real size → ~2x over target.
        proposal.setTotalAllocation(TARGET_ALLOCATION_USD / 2, 500);
        vm.expectRevert("position over-allocated vs totalAllocationUsd");
        proposal.validate();
    }

    // ─── MOO-741: the setup proposal must leave the L2 sequencer guard ENABLED ──────────────────
    //
    // `sequencerUptimeFeed` defaults to address(0) and `LPValuationLib.checkSequencer` early-returns
    // while it is unset, so a deployment that never runs the setter ships with the guard OFF and the
    // balancer is exactly as exposed as before MOO-741. This test pins the wiring (feed + non-zero
    // grace period) AND proves the guard is LIVE — not merely stored — by driving the real
    // `_readFeed` path with the uptime aggregator mocked into each failure state.

    function test_proposal_armsSequencerUptimeGuard() public {
        proposal.deploy();
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2")));

        // Pre-condition: a freshly deployed balancer has the guard DISABLED. If this ever starts
        // failing, the default changed and the rest of this test is measuring the wrong thing.
        assertEq(lab.sequencerUptimeFeed(), address(0), "guard disabled before the proposal runs");
        assertEq(lab.sequencerGracePeriod(), 0, "grace period unset before the proposal runs");

        proposal.build();
        proposal.simulate();
        proposal.validate();

        address feed = addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED");
        assertEq(lab.sequencerUptimeFeed(), feed, "sequencer uptime feed armed by the proposal");
        assertEq(lab.sequencerGracePeriod(), proposal.sequencerGracePeriod(), "grace period armed");
        assertTrue(lab.sequencerGracePeriod() != 0, "grace period is non-zero (guard not neutered)");

        address eth = addresses.getAddress("CHAINLINK_ETH_USD");
        address btc = addresses.getAddress("CHAINLINK_BTC_USD");

        // Control: with the real (up, long past its grace window) feed, the oracle path still works.
        vm.prank(safe);
        lab.setOracles(eth, btc);

        // 1. Sequencer reported DOWN (answer == 1) → every feed read fails closed.
        _mockSequencer(feed, 1, block.timestamp - 10 days);
        vm.prank(safe);
        vm.expectRevert(LPAutoBalancerV2.SequencerDown.selector);
        lab.setOracles(eth, btc);

        // 2. Sequencer back UP but still inside the grace window → reads stay rejected. This is the
        //    case a plain "answer == 0" check would wave through while the price feeds still carry
        //    their pre-outage round.
        _mockSequencer(feed, 0, block.timestamp - 60);
        vm.prank(safe);
        vm.expectRevert(LPAutoBalancerV2.SequencerGracePeriod.selector);
        lab.setOracles(eth, btc);

        // 3. Up and past the grace window → accepted again.
        _mockSequencer(feed, 0, block.timestamp - 2 hours);
        vm.prank(safe);
        lab.setOracles(eth, btc);
    }

    // ─── MOO-740: the setup proposal must ARM both staleness bounds, and arm them before it registers
    //
    // Same lens as the sequencer test above, and the same trap MOO-741 fell into. The values the
    // proposal ships (3600/3600) are byte-identical to the balancer's constructor default
    // (DEFAULT_MAX_ORACLE_DELAY == 1 hours == 3600), so `validate()`'s
    // `assertEq(lab.maxOracleDelay0(), 3600)` passes whether `setMaxOracleDelays` actually ran or the
    // default was silently inherited — deleting `_wireOracleDelays` from build() leaves the
    // lifecycle test green. The two tests below arm NON-default values so the action is observable.

    function test_proposal_armsNonDefaultMaxOracleDelays() public {
        // Distinct from each other AND from the constructor default, so this also pins that the two
        // bounds are wired per-feed rather than both taking delay0 (the flattening MOO-740 is about).
        proposal.setMaxOracleDelays(1800, 2700);

        proposal.deploy();
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2")));

        // Pre-condition: a fresh balancer carries the constructor default on both legs. If this ever
        // fails, the default moved and the "non-default" values below may no longer be non-default.
        uint256 dflt = lab.DEFAULT_MAX_ORACLE_DELAY();
        assertEq(lab.maxOracleDelay0(), dflt, "oracle0 bound is the ctor default before the proposal");
        assertEq(lab.maxOracleDelay1(), dflt, "oracle1 bound is the ctor default before the proposal");
        assertTrue(dflt != 1800 && dflt != 2700, "test values must differ from the default to be observable");

        proposal.build();
        proposal.simulate();
        proposal.validate();

        assertEq(lab.maxOracleDelay0(), 1800, "oracle0 bound armed by the proposal, not inherited");
        assertEq(lab.maxOracleDelay1(), 2700, "oracle1 bound armed by the proposal, not inherited");
    }

    /// @dev ORDERING: the bounds must be armed BEFORE `registerPosition`, which probes both feeds.
    ///      At the shipped values that ordering is unobservable for the same reason as above — armed
    ///      == default makes the probe behave identically either way. So arm a bound TIGHTER than
    ///      the pinned fork's actual feed age: if `_wireOracleDelays` runs first, the registration
    ///      probe must fail StaleOracle; moved after `registerPosition`, the registration would pass
    ///      under the looser default and build() would succeed.
    ///
    ///      Both bounds are derived from live state rather than hardcoded, so re-pinning PINNED_BLOCK
    ///      cannot silently turn this into a vacuous test: leg 0 is tightened relative to the ETH/USD
    ///      feed's own age, leg 1 is opened to the contract's own ceiling so it can never be the
    ///      thing that reverts, and BOTH feeds are asserted fresh under the constructor default — the
    ///      counterfactual placement has to SUCCEED for the revert to mean "the arming ran first".
    ///      A hardcoded leg-1 bound would break silently at a future block where either feed is older
    ///      than it: build() would revert StaleOracle under both placements and pin nothing.
    function test_proposal_armsMaxOracleDelaysBeforeRegisterPosition() public {
        proposal.deploy();
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2")));

        (,,, uint256 updatedAt0,) = IPriceFeed(addresses.getAddress("CHAINLINK_ETH_USD")).latestRoundData();
        (,,, uint256 updatedAt1,) = IPriceFeed(addresses.getAddress("CHAINLINK_BTC_USD")).latestRoundData();
        uint256 age0 = block.timestamp - updatedAt0;
        uint256 age1 = block.timestamp - updatedAt1;
        assertGt(age0, 1, "fork feed must be non-trivially old for this test to bite");

        // Non-vacuity: under the MOVED placement the registration probe runs on the constructor
        // default, and this test only discriminates if that placement would have PASSED. Assert it
        // rather than assume it — both feeds must be fresh under the default at the pinned block.
        uint256 dflt = lab.DEFAULT_MAX_ORACLE_DELAY();
        assertLt(age0, dflt, "ETH/USD must be fresh under the ctor default, else both placements revert");
        assertLt(age1, dflt, "BTC/USD must be fresh under the ctor default, else both placements revert");

        // Leg 0 tighter than the feed's own age → the registration probe cannot pass under it.
        // Leg 1 opened to the contract's ceiling → it can never be the leg that reverts.
        proposal.setMaxOracleDelays(age0 - 1, lab.MAX_ORACLE_DELAY());

        vm.expectRevert(LPAutoBalancerV2.StaleOracle.selector);
        proposal.build();
    }

    /// @dev FREEZE both price feeds' `updatedAt` at the current block timestamp, keeping their real
    ///      answers, so a pinned fork that warps forward still reads as fresh.
    /// @dev Deliberately NOT a re-publish: `vm.mockCall` encodes its return data ONCE, when this
    ///      runs, and never clears — `updatedAt` is frozen at call time, it does not track "now" at
    ///      read time. That suffices here only because nothing warps between this call and the
    ///      rebalance it enables; insert any `skip()` past the armed bound in between and the mock
    ///      goes stale exactly as the real feed would.
    function _refreshPriceFeeds() internal {
        _refreshPriceFeed(addresses.getAddress("CHAINLINK_ETH_USD"));
        _refreshPriceFeed(addresses.getAddress("CHAINLINK_BTC_USD"));
    }

    function _refreshPriceFeed(address feed) internal {
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) = IPriceFeed(feed).latestRoundData();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
            abi.encode(roundId, answer, block.timestamp, block.timestamp, answeredInRound)
        );
    }

    /// @dev Force the uptime aggregator's answer/startedAt. `answer` 0 == up, 1 == down.
    function _mockSequencer(address feed, int256 answer, uint256 startedAt) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
            abi.encode(uint80(1), answer, startedAt, block.timestamp, uint80(1))
        );
    }
}
