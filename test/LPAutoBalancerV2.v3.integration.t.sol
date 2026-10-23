// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPPositionLib} from "@contracts/libraries/LPPositionLib.sol";
import {Test} from "@forge-std/Test.sol";

import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// LPAutoBalancerV2V3Integration — REAL Base-fork test against Slipstream V3 (WETH/cbBTC CL1).
//
// V3 differs from the V1 gauge the balancer was written against: a new position manager, emissions
// minted by the LeafVoter in a NEW AERO token, no `rewardToken()` / `getReward(uint256)` /
// `earned(address,uint256)`, and a 100% early-withdraw penalty inside `minStakeBlocks` (7).
// This proves registration, staking, claiming, compounding, a no-swap rebalance and exit on the
// real contracts, with the balancer constructed for V3 (V3 NFPM + V3 AERO).
//
// Real Base mainnet addresses (resolved on-chain at block 52_964_000):
//   POOL     0xeC3c3755b9DED4a2960ef50C9b48C1694CE274C2  WETH/cbBTC CL V3, tickSpacing = 1
//   GAUGE    0xAbb3fb6659e05847631896cB87A6D1b8bc0c6D8C  its CLGauge (pool.gauge() == GAUGE)
//   NFPM     0x4857DB576eE0e45F10525eC59527BfD10beeC60b  "Slipstream V3 Deposit" (gauge.nft())
//   AERO_V3  0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee  token the V3 LeafVoter mints as emissions
//   V1_GAUGE 0x61E0B10423a0009C3f83ab4313813d29437d0817  the CL10 V1 gauge (classifier control)
// ─────────────────────────────────────────────────────────────────────────────

contract LPAutoBalancerV2V3Integration is Test {
    address constant POOL = 0xeC3c3755b9DED4a2960ef50C9b48C1694CE274C2;
    address constant GAUGE = 0xAbb3fb6659e05847631896cB87A6D1b8bc0c6D8C;
    address constant NFPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO_V3 = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant V1_GAUGE = 0x61E0B10423a0009C3f83ab4313813d29437d0817;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;

    uint256 constant PINNED_BLOCK = 52_964_000;
    int24 constant TICK_SPACING = 1;
    uint24 constant WIDTH = 800;

    LPAutoBalancerV2 lab;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");
    address feeCollector = makeAddr("feeCollector");
    address moduleSink = makeAddr("moduleSink");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        // See LPAutoBalancerV2Integration.setUp: zero fees dodge op-revm's isthmus operator-fee panic.
        vm.txGasPrice(0);
        vm.fee(0);
        lab = new LPAutoBalancerV2(admin, manager, rebalancer, guardian, NFPM, AERO_V3);
        // Pinned feeds freeze while the tests warp; widen to the contract maximum (see V1 suite).
        uint256 cap = lab.MAX_ORACLE_DELAY();
        vm.prank(admin);
        lab.setMaxOracleDelays(cap, cap);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _straddle(uint24 width) internal view returns (int24 tl, int24 tu) {
        (, int24 spot,,,,) = ICLPool(POOL).slot0();
        tl = spot - int24(width) / 2;
        tu = tl + int24(width);
    }

    function _bootstrap() internal returns (uint256 tokenId) {
        (int24 tl, int24 tu) = _straddle(WIDTH);
        deal(WETH, address(this), 1 ether);
        deal(CBBTC, address(this), 3e6);
        IERC20(WETH).approve(NFPM, 1 ether);
        IERC20(CBBTC).approve(NFPM, 3e6);
        (tokenId,,,) = ICLPositionManager(NFPM)
            .mint(
                ICLPositionManager.MintParams({
                token0: WETH,
                token1: CBBTC,
                tickSpacing: TICK_SPACING,
                tickLower: tl,
                tickUpper: tu,
                amount0Desired: 1 ether,
                amount1Desired: 3e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 1,
                sqrtPriceX96: 0
            })
            );
        INonfungiblePositionManager(NFPM).safeTransferFrom(address(this), address(lab), tokenId);
        vm.prank(admin);
        lab.registerPosition(
            LPAutoBalancerV2.ManagedPositionV2({
                mainTokenId: tokenId,
                altTokenId: 0,
                pool: POOL,
                token0: WETH,
                token1: CBBTC,
                tickSpacing: TICK_SPACING,
                gauge: GAUGE,
                mainStaked: false,
                altStaked: false,
                feeCollector: feeCollector,
                oracle0: ETH_USD,
                oracle1: BTC_USD,
                minWidth: 200,
                maxWidth: 20_000,
                maxCenterDeviation: 200,
                twapWindow: 60,
                maxTickDeviation: 800_000,
                maxRebalanceLossBps: 100,
                minRebalanceInterval: 0,
                lastRebalance: 0,
                active: false
            })
        );
        vm.prank(rebalancer);
        lab.stake();
    }

    /// @dev Let emissions accrue well past the 7-block early-withdraw penalty window.
    function _accrue() internal {
        skip(2 hours);
        vm.roll(block.number + 3_600);
    }

    function test_v3_gaugeClassifier() public view {
        assertTrue(LPPositionLib.isV3Gauge(GAUGE), "CL1 gauge is V3");
        assertFalse(LPPositionLib.isV3Gauge(V1_GAUGE), "CL10 gauge is V1");
    }

    function test_v3_registerAndStake() public {
        uint256 tokenId = _bootstrap();
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(tokenId), GAUGE, "NFT custodied by gauge");
        assertTrue(ICLGauge(GAUGE).stakedContains(address(lab), tokenId), "staked for the balancer");
    }

    function test_v3_setGaugeRejectsV1Gauge() public {
        _bootstrap();
        vm.prank(rebalancer);
        lab.unstake();
        // The CL10 gauge is classified V1, so its rewardToken (legacy AERO) must equal AERO_V3.
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.GaugeRewardMismatch.selector);
        lab.setGauge(V1_GAUGE);
    }

    function test_v3_claimEmissionsPaysV3Aero() public {
        _bootstrap();
        _accrue();
        uint256 earned = lab.getDecisionSnapshot().earnedAero;
        uint256 before = IERC20(AERO_V3).balanceOf(feeCollector);
        vm.prank(rebalancer);
        lab.claimEmissions();
        uint256 paid = IERC20(AERO_V3).balanceOf(feeCollector) - before;
        assertGt(paid, 0, "V3 AERO claimed to feeCollector");
        assertGe(paid, earned, "claim covers the snapshot estimate");
    }

    function test_v3_compoundForwardsToModule() public {
        _bootstrap();
        vm.prank(admin);
        lab.setCompoundModule(moduleSink);
        _accrue();
        vm.prank(rebalancer);
        lab.compound(10_000);
        assertGt(IERC20(AERO_V3).balanceOf(moduleSink), 0, "compound share reached the module");
        assertEq(IERC20(AERO_V3).balanceOf(address(lab)), 0, "balancer keeps no AERO");
    }

    function test_v3_rebalanceUsingAltRestakes() public {
        uint256 oldId = _bootstrap();
        _accrue();
        // In-range re-range to a wider balanced straddle: the full V3 teardown (gauge withdraw with
        // its emission claim), NFPM mint at tickSpacing 1, and restake — without a price-moving
        // swap, which at spacing 1 would cross thousands of initialized ticks over the fork RPC.
        uint24 width = 2 * WIDTH;
        (int24 tl, int24 tu) = _straddle(width);
        uint256 aeroBefore = IERC20(AERO_V3).balanceOf(feeCollector);
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(
            LPAutoBalancerV2.RebalanceParams({
                width: width,
                altWidth: 10,
                amount0MinMain: 0,
                amount1MinMain: 0,
                amount0MinAlt: 0,
                amount1MinAlt: 0,
                amount0MinWithdraw: 0,
                amount1MinWithdraw: 0,
                amount0MinWithdrawAlt: 0,
                amount1MinWithdrawAlt: 0,
                deadline: block.timestamp + 1,
                expectedTickLower: tl,
                expectedTickUpper: tu
            })
        );
        (uint256 newId,,,,,,, bool mainStaked,,,,,,,,,,,,,) = lab.position();
        assertTrue(newId != oldId, "fresh main");
        assertTrue(mainStaked, "restaked");
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(newId), GAUGE, "new main in the V3 gauge");
        (,,,,, int24 newTl, int24 newTu,,,,,) = INonfungiblePositionManager(NFPM).positions(newId);
        assertEq(newTl, tl, "committed lower tick");
        assertEq(newTu, tu, "committed upper tick");
        assertGt(IERC20(AERO_V3).balanceOf(feeCollector), aeroBefore, "withdraw-time claim forwarded");
    }

    function test_v3_exitSweepsPrincipal() public {
        _bootstrap();
        _accrue();
        address to = makeAddr("exitTo");
        vm.prank(admin);
        lab.exit(to);
        assertGt(IERC20(WETH).balanceOf(to), 0, "WETH swept");
        assertGt(IERC20(AERO_V3).balanceOf(feeCollector), 0, "AERO claimed on unstake");
        (,,,,,,,,,,,,,,,,,,,, bool active) = lab.position();
        assertFalse(active, "inactive");
    }
}
