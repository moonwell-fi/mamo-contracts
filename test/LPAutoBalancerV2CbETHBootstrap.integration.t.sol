// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2CbETHBootstrap} from "../multisig/mamo-multisig/014_LPAutoBalancerV2CbETHBootstrap.sol";

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {Test} from "@forge-std/Test.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IPriceFeed} from "@interfaces/IPriceFeed.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";

// ─────────────────────────────────────────────────────────────────────────────
// LPAutoBalancerV2CbETHBootstrapTest — REAL Base-fork exercise of proposal 014.
//
// Mirrors LPAutoBalancerV2Setup.integration.t.sol (the WETH/cbBTC proposal-011 test): PINNED fork
// + the vm.fee(0) op-revm Isthmus workaround, a real Slipstream NFT minted to the F-MAMO Safe as
// the off-chain Phase-B precondition, then deploy/build/simulate/validate followed by proof that
// the registered position is OPERABLE by the granted rebalancer.
//
// What this test adds over the 011 one is the TOTAL ALLOCATION parameter:
//   - the position is minted from the target USD using the handbook's 50/50-by-value sizing recipe,
//     so a passing validate() proves the recipe lands inside the proposal's band rather than
//     proving the band was widened to fit whatever got minted;
//   - test_validate_rejectsWrongAllocation is the non-vacuity control — with the SAME position, a
//     target the position does not meet must FAIL. Without it, an assertion that always passes
//     (e.g. a 100% tolerance, or a principal read that returns 0 on both sides) reads identically
//     to a working one.
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

contract LPAutoBalancerV2CbETHBootstrapTest is Test {
    // Real Base addresses, resolved on-chain at the pinned block.
    address constant POOL = 0x47cA96Ea59C13F72745928887f84C9F52C3D7348;
    address constant NFPM = 0x827922686190790b37229fd06084350E74485b72;
    address constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22; // token0
    address constant WETH = 0x4200000000000000000000000000000000000006; // token1

    uint256 constant PINNED_BLOCK = 50_200_000;
    int24 constant TICK_SPACING = 1;

    /// @dev Deliberately STRICTLY INSIDE [MIN_WIDTH, MAX_WIDTH] rather than equal to MIN_WIDTH (50,
    ///      the handbook's recommended operating width): a regression that silently clamps the
    ///      submitted width to minWidth would be invisible at width == minWidth. Legal: a multiple
    ///      of 2*tickSpacing, inside the band.
    uint24 constant WIDTH = 100;

    /// @dev The allocation this run commits. Deliberately a ROUND NUMBER chosen up front, not read
    ///      back from the minted position — the point of the parameter is that the position has to
    ///      match the target, not the other way round.
    uint256 constant TARGET_ALLOCATION_USD = 25_000e8;

    LPAutoBalancerV2CbETHBootstrap proposal;
    Addresses addresses;

    address safe; // F-MAMO
    address rebalancerEOA = makeAddr("cbEthLpRebalancer");
    uint256 tokenId;

    function setUp() public {
        // PIN THE BLOCK (mandatory) — deterministic fork.
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        // op-revm Isthmus operator-fee workaround (see the V2 integration test).
        vm.txGasPrice(0);
        vm.fee(0);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));

        safe = addresses.getAddress("F-MAMO");

        // Mint a REAL cbETH/WETH Slipstream position owned by the Safe, sized from the target USD
        // (the off-chain Phase-B2 precondition the proposal assumes).
        tokenId = _mintAllocationTo(safe, TARGET_ALLOCATION_USD);

        proposal = new LPAutoBalancerV2CbETHBootstrap();
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

    /// @dev Mint a real cbETH/WETH CL position of ~`targetUsd` (1e8) straddling spot, owned by
    ///      `recipient`, using the handbook §2 sizing recipe: half the target's USD value in each
    ///      leg. For a TICK-symmetric range that is log-price-symmetric, so the two legs bind within
    ///      a few tenths of a percent of each other and the NFPM consumes essentially all of both.
    ///      Both tokens are 18-decimal.
    function _mintAllocationTo(address recipient, uint256 targetUsd) internal returns (uint256 id) {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        int24 tl = center - int24(WIDTH) / 2;
        int24 tu = tl + int24(WIDTH);
        require(tl < spotTick && spotTick < tu, "setup: main must straddle spot");

        uint256 halfUsd = targetUsd / 2;
        uint256 amt0 = (halfUsd * 1e18) / _price("CHAINLINK_CBETH_USD");
        uint256 amt1 = (halfUsd * 1e18) / _price("CHAINLINK_ETH_USD");

        deal(CBETH, address(this), amt0);
        deal(WETH, address(this), amt1);
        IERC20(CBETH).approve(NFPM, amt0);
        IERC20(WETH).approve(NFPM, amt1);

        ICLPositionManager.MintParams memory mp = ICLPositionManager.MintParams({
            token0: CBETH,
            token1: WETH,
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

    /// @dev Push spot DOWN to `sqrtLimit` (cbETH in, WETH out) so the main goes fully out of range
    ///      on the token0 side. Bounded by the sqrtPriceLimit rather than by the input amount, so
    ///      the displacement is exact and does not depend on the pool's depth at the pinned block.
    function _pushTickDownTo(uint160 sqrtLimit) internal {
        uint256 cbEthIn = 1_000_000 ether;
        deal(CBETH, address(this), cbEthIn);
        ICLPoolSwap(POOL).swap(address(this), true, int256(cbEthIn), sqrtLimit, "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == POOL, "cb: bad caller");
        if (amount0Delta > 0) IERC20(CBETH).transfer(POOL, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(WETH).transfer(POOL, uint256(amount1Delta));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @dev The rebalance below drives the main FULLY out of range on the token0 (cbETH) side, so
    ///      the teardown returns 100% token0 and `_mainRange` takes the token0-majority single-sided
    ///      branch: [floorAlign(spot) + spacing, +width]. That is the range committed to here — the
    ///      off-chain half of the tick commitment a real rebalancer computes from its snapshot.
    function _defaultRebalanceParams() internal view returns (LPAutoBalancerV2.RebalanceParams memory) {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 expectedTl = _align(spotTick) + TICK_SPACING;
        return LPAutoBalancerV2.RebalanceParams({
            width: WIDTH,
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
            expectedTickUpper: expectedTl + int24(WIDTH)
        });
    }

    /// @dev FREEZE both price feeds' `updatedAt` at the current block timestamp, keeping their real
    ///      answers, so a pinned fork that warps forward still reads as fresh. Deliberately NOT a
    ///      re-publish: `vm.mockCall` encodes its return data ONCE and never tracks "now", so any
    ///      skip() past the armed bound AFTER this call goes stale exactly as the real feed would.
    ///      Deliberately NOT "widen the bound to make the test pass" either — the whole point is to
    ///      assert the values the proposal actually ships.
    function _refreshPriceFeeds() internal {
        _refreshPriceFeed(addresses.getAddress("CHAINLINK_CBETH_USD"));
        _refreshPriceFeed(addresses.getAddress("CHAINLINK_ETH_USD"));
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

    // ─── tests ────────────────────────────────────────────────────────────────

    function test_proposal_lifecycle() public {
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(tokenId), safe, "Safe owns NFT pre-setup");

        proposal.deploy();

        address labAddr = addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2_CBETH");
        assertTrue(labAddr != address(0), "balancer deployed");
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(labAddr));

        // The 011 balancer must NOT be what this proposal touched: one balancer, one pool.
        assertTrue(
            !addresses.isAddressSet("MAMO_LP_AUTO_BALANCER_V2")
                || addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2") != labAddr,
            "cbETH bootstrap deploys its OWN balancer, not 011's"
        );

        proposal.build();
        proposal.simulate();
        proposal.validate();

        assertEq(INonfungiblePositionManager(NFPM).ownerOf(tokenId), labAddr, "balancer owns NFT post-setup");
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), rebalancerEOA), "rebalancer granted");

        // ── Prove the registered position is OPERABLE by the granted rebalancer. ──
        vm.prank(rebalancerEOA);
        lab.stake();

        skip(2 hours);
        vm.roll(block.number + 1);

        // Drive spot ~1% below (>= 100 ticks, i.e. past the whole 100-tick main) → single-sided
        // cbETH withdrawal on rebalanceUsingAlt. The config gates on |spot - TWAP| <= 20 ticks, so
        // a single big swap would trip TwapDeviation against the lagging 1800s TWAP; skip well past
        // twapWindow afterwards so the TWAP converges onto the post-swap tick.
        LPAutoBalancerV2.DecisionSnapshotV2 memory pre = lab.getDecisionSnapshot();
        assertTrue(pre.mainInRange, "main starts in range");

        (uint160 sqrtBefore,,,,,) = ICLPool(POOL).slot0();
        _pushTickDownTo(uint160((uint256(sqrtBefore) * 990) / 1000));
        (, int24 spotOut,,,,) = ICLPool(POOL).slot0();
        // Compare against the REGISTERED main's own lower tick, not against a width offset from the
        // pre-swap spot: the two coincide only when spot sits exactly at the range's center, and at
        // tickSpacing 1 that off-by-one is the difference between out-of-range and on the boundary.
        assertLt(spotOut, pre.mainTickLower, "main fully out of range below, single-sided cbETH");

        skip(2 hours);
        vm.roll(block.number + 1);

        // The fork PINS the block, so both feeds' `updatedAt` is frozen while this test warps 4h.
        // On a live chain each would have published ~12 times; on a pinned fork they cannot, so the
        // bound the proposal arms (3600s) correctly reads the warp as stale. Freeze, don't loosen.
        _refreshPriceFeeds();

        LPAutoBalancerV2.DecisionSnapshotV2 memory snapBefore = lab.getDecisionSnapshot();
        assertFalse(snapBefore.mainInRange, "main driven out of range");
        assertTrue(snapBefore.deviationGateOpen, "TWAP converged: deviation gate open");

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
    ///      tolerance — only the TARGET moves, and validate() must fail. Without this, a band that
    ///      accepts everything (a 100% tolerance, a principal read that returns 0, a validate() that
    ///      never reaches the check) is indistinguishable from a working one.
    function test_validate_rejectsWrongAllocation() public {
        proposal.deploy();
        proposal.build();
        proposal.simulate();

        // Sanity: at the committed target it passes. If this ever fails, the mint recipe drifted and
        // the rejection below would prove nothing.
        proposal.validate();

        // 2x the real size, same 500 bps band → the position is ~50% under target.
        proposal.setTotalAllocation(TARGET_ALLOCATION_USD * 2, 500);
        vm.expectRevert("position under-allocated vs totalAllocationUsd");
        proposal.validate();

        // Half the real size → the position is ~2x over target.
        proposal.setTotalAllocation(TARGET_ALLOCATION_USD / 2, 500);
        vm.expectRevert("position over-allocated vs totalAllocationUsd");
        proposal.validate();
    }

    /// @dev The sequencer guard must be ENABLED when this proposal lands, and LIVE — not merely
    ///      stored. Same lens as the 011 test: `sequencerUptimeFeed` defaults to address(0) and
    ///      `checkSequencer` early-returns while unset, so a deployment that never runs the setter
    ///      ships as exposed as one that never heard of the guard.
    function test_proposal_armsSequencerUptimeGuard() public {
        proposal.deploy();
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2_CBETH")));

        assertEq(lab.sequencerUptimeFeed(), address(0), "guard disabled before the proposal runs");
        assertEq(lab.sequencerGracePeriod(), 0, "grace period unset before the proposal runs");

        proposal.build();
        proposal.simulate();
        proposal.validate();

        address feed = addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED");
        assertEq(lab.sequencerUptimeFeed(), feed, "sequencer uptime feed armed by the proposal");
        assertEq(lab.sequencerGracePeriod(), proposal.sequencerGracePeriod(), "grace period armed");
        assertTrue(lab.sequencerGracePeriod() != 0, "grace period is non-zero (guard not neutered)");

        address cbEth = addresses.getAddress("CHAINLINK_CBETH_USD");
        address eth = addresses.getAddress("CHAINLINK_ETH_USD");

        // Control: with the real (up, long past its grace window) feed, the oracle path works.
        vm.prank(safe);
        lab.setOracles(cbEth, eth);

        // 1. Sequencer reported DOWN → every feed read fails closed.
        _mockSequencer(feed, 1, block.timestamp - 10 days);
        vm.prank(safe);
        vm.expectRevert(LPAutoBalancerV2.SequencerDown.selector);
        lab.setOracles(cbEth, eth);

        // 2. Back UP but inside the grace window → reads stay rejected. This is the case a plain
        //    "answer == 0" check waves through while the price feeds still carry a pre-outage round.
        _mockSequencer(feed, 0, block.timestamp - 60);
        vm.prank(safe);
        vm.expectRevert(LPAutoBalancerV2.SequencerGracePeriod.selector);
        lab.setOracles(cbEth, eth);

        // 3. Up and past the grace window → accepted again.
        _mockSequencer(feed, 0, block.timestamp - 2 hours);
        vm.prank(safe);
        lab.setOracles(cbEth, eth);
    }

    /// @dev The shipped bounds (3600/3600) are byte-identical to the balancer's constructor default
    ///      (DEFAULT_MAX_ORACLE_DELAY == 1 hours), so validate()'s assertEq passes whether
    ///      `setMaxOracleDelays` ran or the default was inherited — deleting `_wireOracleDelays`
    ///      leaves the lifecycle test green. Arm NON-default, mutually distinct values so the action
    ///      is observable AND so a regression that writes delay0 to both legs fails.
    function test_proposal_armsNonDefaultMaxOracleDelays() public {
        proposal.setMaxOracleDelays(1800, 2700);

        proposal.deploy();
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2_CBETH")));

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
    ///      At the shipped values that ordering is unobservable (armed == default). So arm a bound
    ///      TIGHTER than the fork's actual feed age: if `_wireOracleDelays` runs first, registration
    ///      must revert StaleOracle; moved after `registerPosition`, registration would pass under
    ///      the looser default and build() would succeed.
    ///
    ///      Both bounds are derived from LIVE state so re-pinning PINNED_BLOCK cannot silently make
    ///      this vacuous: leg 0 is tightened relative to the cbETH/USD feed's own age, leg 1 is
    ///      opened to the contract's ceiling so it can never be the thing that reverts, and BOTH
    ///      feeds are asserted fresh under the default — the counterfactual placement has to SUCCEED
    ///      for the revert to mean "the arming ran first".
    function test_proposal_armsMaxOracleDelaysBeforeRegisterPosition() public {
        proposal.deploy();
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2_CBETH")));

        (,,, uint256 updatedAt0,) = IPriceFeed(addresses.getAddress("CHAINLINK_CBETH_USD")).latestRoundData();
        (,,, uint256 updatedAt1,) = IPriceFeed(addresses.getAddress("CHAINLINK_ETH_USD")).latestRoundData();
        uint256 age0 = block.timestamp - updatedAt0;
        uint256 age1 = block.timestamp - updatedAt1;
        assertGt(age0, 1, "fork feed must be non-trivially old for this test to bite");

        uint256 dflt = lab.DEFAULT_MAX_ORACLE_DELAY();
        assertLt(age0, dflt, "cbETH/USD must be fresh under the ctor default, else both placements revert");
        assertLt(age1, dflt, "ETH/USD must be fresh under the ctor default, else both placements revert");

        proposal.setMaxOracleDelays(age0 - 1, lab.MAX_ORACLE_DELAY());

        vm.expectRevert(LPAutoBalancerV2.StaleOracle.selector);
        proposal.build();
    }
}
