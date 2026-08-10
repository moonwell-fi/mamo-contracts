// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {Test, Vm} from "@forge-std/Test.sol";

import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// LPAutoBalancerV2Integration — REAL Base-fork WETH/cbBTC no-swap rebalanceUsingAlt test.
//
// Proves the V2 rebalanceUsingAlt() rebuilds a dual position from REAL Aerodrome Slipstream
// liquidity, conserving principal WITHOUT any swap (V2 has no router/quoter — the
// only way principal moves is in/out of the position manager, never sold).
//
// PINNED BLOCK (mandatory): an unpinned `latest` fork drifts live spot, which breaks
// the slippage floors / value floor non-deterministically. Block 47_600_000 was
// selected because its WETH/USD + cbBTC/USD Chainlink feeds are fresh (< maxOracleDelay)
// at the fork timestamp and the WETH/cbBTC tickSpacing-100 pool holds real liquidity.
//
// Real Base mainnet addresses (resolved on-chain at block 47_600_000):
//   POOL    0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1  WETH/cbBTC CL, tickSpacing=100
//   GAUGE   0x41b2126661C673C2beDd208cC72E85DC51a5320a  CL gauge for that pool (rewardToken = AERO)
//   NFPM    0x827922686190790b37229fd06084350E74485b72  Slipstream NonfungiblePositionManager
//                                                        (this is the NFPM the gauge accepts —
//                                                         gauge.nft() == this address, NOT the
//                                                         0xc741... entry in addresses/8453.json)
//   WETH    0x4200000000000000000000000000000000000006  token0
//   cbBTC   0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf  token1
//   AERO    0x940181a94A35A4569E4529A3CDfB74e38FD98631  gauge reward token
//   ETH/USD 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70  Chainlink, 8-dec, token0 oracle
//   BTC/USD 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F  Chainlink, 8-dec, token1 oracle (cbBTC≈BTC)
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

/// @notice Pushes its balance onto `target` with selfdestruct — the one ETH transfer a contract
///         cannot refuse. Used to donate to the SHARED, real Slipstream position manager.
contract ForceEtherFork {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract LPAutoBalancerV2Integration is Test {
    // ─── real addresses ──────────────────────────────────────────────────────
    address constant POOL = 0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1;
    address constant GAUGE = 0x41b2126661C673C2beDd208cC72E85DC51a5320a;
    address constant NFPM = 0x827922686190790b37229fd06084350E74485b72;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;

    uint256 constant PINNED_BLOCK = 47_600_000;
    int24 constant TICK_SPACING = 100;

    // Uniswap V3 sqrtPrice bounds (TickMath MIN/MAX +/- 1) for effectively-unbounded swaps.
    uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
    uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    LPAutoBalancerV2 lab;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");
    address feeCollector = makeAddr("feeCollector");

    function setUp() public {
        // PIN THE BLOCK (mandatory): deterministic fork at PINNED_BLOCK.
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        // Zero the gas price + base fee so op-revm's post-execution OPERATOR-FEE REFUND path is a
        // no-op. Without this, forking a historical post-Isthmus Base block under foundry 1.7.x
        // panics with "Missing operator fee scalar for isthmus L1 Block" inside operator_fee_refund
        // on the very first transact (the constructor below). Zero fee → no refund → no decode of the
        // missing scalar. Gas accounting is irrelevant to this principal-conservation test.
        vm.txGasPrice(0);
        vm.fee(0);
        lab = new LPAutoBalancerV2(admin, manager, rebalancer, guardian, NFPM, AERO);
    }

    // ─── CL pool swap callback (this contract is the swapper) ──────────────────
    /// @notice Pay the pool whatever it asks for during swap (this contract is pre-funded by deal).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == POOL, "cb: bad caller");
        if (amount0Delta > 0) IERC20(WETH).transfer(POOL, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(CBBTC).transfer(POOL, uint256(amount1Delta));
    }

    // ─── helpers ───────────────────────────────────────────────────────────────

    /// @dev Floor-align a tick toward -inf to a multiple of TICK_SPACING.
    function _align(int24 tick) internal pure returns (int24) {
        int24 q = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) q -= 1;
        return q * TICK_SPACING;
    }

    /// @dev Mint a real WETH/cbBTC CL position straddling spot, owned by this test contract.
    function _mintMainPosition(int24 tl, int24 tu, uint256 amt0, uint256 amt1)
        internal
        returns (uint256 tokenId, uint128 liq)
    {
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
            recipient: address(this),
            deadline: block.timestamp + 1,
            sqrtPriceX96: 0
        });
        (tokenId, liq,,) = ICLPositionManager(NFPM).mint(mp);
    }

    function _register(uint256 tokenId) internal {
        // Transfer the freshly minted NFT to the balancer, then registerPosition (admin only).
        INonfungiblePositionManager(NFPM).safeTransferFrom(address(this), address(lab), tokenId);

        LPAutoBalancerV2.ManagedPositionV2 memory cfg = LPAutoBalancerV2.ManagedPositionV2({
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
            minWidth: 200, // 2 * tickSpacing: guarantees a straddle
            maxWidth: 200_000,
            maxCenterDeviation: 800_000,
            twapWindow: 60,
            // Deviation gate is exercised in the unit suite; here we keep it wide so a
            // deliberate large swap (to push the main out of range) doesn't block rebalanceUsingAlt.
            maxTickDeviation: 800_000,
            maxRebalanceLossBps: 500, // 5% — covers concentrated→tight rebuild rounding headroom
            minRebalanceInterval: 0,
            lastRebalance: 0,
            active: false
        });
        vm.prank(admin);
        lab.registerPosition(cfg);
    }

    /// @dev Push the pool tick DOWN (WETH in, cbBTC out): zeroForOne=true lowers price → tick falls.
    function _pushTickDown(uint256 wethIn) internal {
        deal(WETH, address(this), wethIn);
        ICLPoolSwap(POOL).swap(address(this), true, int256(wethIn), MIN_SQRT_RATIO_PLUS_ONE, "");
    }

    /// @dev Push the pool tick UP (cbBTC in, WETH out): zeroForOne=false raises price → tick rises.
    function _pushTickUp(uint256 cbBtcIn) internal {
        deal(CBBTC, address(this), cbBtcIn);
        ICLPoolSwap(POOL).swap(address(this), false, int256(cbBtcIn), MAX_SQRT_RATIO_MINUS_ONE, "");
    }

    function _readSlot() internal view returns (uint256 mainId, uint256 altId, bool mainStaked) {
        (mainId, altId,,,,,, mainStaked,,,,,,,,,,,,,) = lab.position();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _defaultParams() internal view returns (LPAutoBalancerV2.RebalanceParams memory) {
        // Width 400 (= 4 * spacing); mins 0 (fork is deterministic, pinned).
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
            deadline: block.timestamp + 1
        });
    }

    /// @dev The BALANCED main range the contract will derive at the CURRENT live spot, reproducing
    ///      LPGeometryLib.alignedRange: tickLower = floorAlign(spot - width/2), upper = lower+width.
    ///      This is the off-chain half of the MOO-727 tick commitment — a real caller computes the
    ///      same thing from a decision-time snapshot.
    function _expectedStraddle(uint24 width) internal view returns (int24 tl, int24 tu) {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        tl = _align(spotTick - int24(width) / 2);
        tu = tl + int24(width);
    }

    function _defaultRebuildParams() internal view returns (LPAutoBalancerV2.RebuildParams memory) {
        (int24 tl, int24 tu) = _expectedStraddle(400);
        return _rebuildParamsAt(tl, tu);
    }

    function _rebuildParamsAt(int24 expectedTl, int24 expectedTu)
        internal
        view
        returns (LPAutoBalancerV2.RebuildParams memory)
    {
        LPAutoBalancerV2.RebalanceParams memory p = _defaultParams();
        return LPAutoBalancerV2.RebuildParams({
            width: p.width,
            amount0MinMain: p.amount0MinMain,
            amount1MinMain: p.amount1MinMain,
            amount0MinAlt: p.amount0MinAlt,
            amount1MinAlt: p.amount1MinAlt,
            deadline: p.deadline,
            expectedTickLower: expectedTl,
            expectedTickUpper: expectedTu
        });
    }

    /// @dev Bootstrap a real, staked WETH/cbBTC main position straddling spot and return the tokenId.
    function _bootstrap(int24 tl, int24 tu, uint256 amt0, uint256 amt1) internal returns (uint256 tokenId) {
        (tokenId,) = _mintMainPosition(tl, tu, amt0, amt1);
        _register(tokenId);
        vm.prank(rebalancer);
        lab.stake();
        // Accrue AERO so the unstake/skim/restake path runs on rebalanceUsingAlt.
        skip(2 hours);
        vm.roll(block.number + 1);
    }

    /// @dev Common post-rebalanceUsingAlt invariants shared by both scenarios: dual position rebuilt, NO SWAP /
    ///      principal conserved (only fees/AERO/dust leave to feeCollector — V2 has no router), AERO
    ///      forwarded, old NFT burned, RebalancedUsingAlt emitted. Returns the new main id for caller assertions.
    function _assertNoSwapRebuild(
        uint256 oldTokenId,
        uint256 feeColl0Before,
        uint256 feeColl1Before,
        uint256 aeroBefore
    ) internal returns (uint256 newMain, uint256 altId) {
        bool mainStaked;
        (newMain, altId, mainStaked) = _readSlot();
        assertGt(newMain, 0, "new main tokenId set");
        assertTrue(newMain != oldTokenId, "main is a fresh NFT");
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(newMain), GAUGE, "new main staked into gauge");
        assertTrue(mainStaked, "main restaked (old main was staked)");

        // alt — if a surplus leg existed it is a real NFT held by the contract or gauge.
        if (altId != 0) {
            address altOwner = INonfungiblePositionManager(NFPM).ownerOf(altId);
            assertTrue(altOwner == address(lab) || altOwner == GAUGE, "alt held by contract or gauge");
        }

        // NO SWAP / principal conserved. The value floor inside rebalanceUsingAlt() already enforced
        // valueAfter >= valueBefore*(1 - 5%) on the SAME oracles. Beyond that: V2 has NO router, so
        // principal can never be converted between tokens — the only outflows are to the feeCollector
        // (skimmed fees + AERO + sub-threshold dust). Those outflows must be a tiny fraction of the
        // deposited principal, never the bulk of a leg (which would mean principal escaped as "dust").
        //
        // Bounds are fee/dust-sized, calibrated against observed values at pinned block 47_600_000:
        //   balanced rebuild:     WETH = 182 wei,     cbBTC = 0 sat
        //   single-sided rebuild: WETH = 11_940 wei,  cbBTC = 0 sat
        // 50_000 wei WETH (~4.2x headroom over 11_940) and 5_000 sat cbBTC absorb minor rounding
        // shifts across forge versions without masking any principal-sized outflow.
        uint256 toFeeColl0 = IERC20(WETH).balanceOf(feeCollector) - feeColl0Before;
        uint256 toFeeColl1 = IERC20(CBBTC).balanceOf(feeCollector) - feeColl1Before;
        assertLt(toFeeColl0, 50_000, "WETH to feeCollector is fees/dust only, not principal");
        assertLt(toFeeColl1, 5_000, "cbBTC to feeCollector is fees/dust only, not principal");

        // AERO emissions forwarded to feeCollector (position was staked ~2h).
        assertGt(
            IERC20(AERO).balanceOf(feeCollector),
            aeroBefore,
            "AERO emissions skimmed to feeCollector on rebalanceUsingAlt"
        );

        // Old NFT burned (ownerOf reverts on a burned token).
        vm.expectRevert("ERC721: owner query for nonexistent token");
        INonfungiblePositionManager(NFPM).ownerOf(oldTokenId);

        // RebalancedUsingAlt event emitted with the new main id.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawRebalance;
        bytes32 rebalanceSig = keccak256("RebalancedUsingAlt(uint256,uint256,int24,int24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(lab) && logs[i].topics[0] == rebalanceSig) {
                sawRebalance = true;
                (uint256 emittedMain,,,) = abi.decode(logs[i].data, (uint256, uint256, int24, int24));
                assertEq(emittedMain, newMain, "RebalancedUsingAlt event main id matches");
            }
        }
        assertTrue(sawRebalance, "RebalancedUsingAlt event emitted");
    }

    // ─── tests ─────────────────────────────────────────────────────────────────

    /// @notice BALANCED rebuild. The main is driven out of range (rebalanceUsingAlt candidacy), then price
    ///         oscillates back so the withdrawn principal is TWO-sided. The no-swap rebalanceUsingAlt rebuilds a
    ///         spot-straddling balanced main → getDecisionSnapshot.mainInRange == true. Proves the
    ///         core conservation path on REAL WETH/cbBTC liquidity with no swap.
    function test_rebalanceUsingAlt_conservesPrincipal_balancedRebuild() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        assertEq(ICLPool(POOL).tickSpacing(), TICK_SPACING, "pool tickSpacing");

        int24 center = _align(spotTick);
        int24 tl = center - 200; // width = 4 * spacing
        int24 tu = center + 200;
        require(tl < spotTick && spotTick < tu, "setup: main must straddle spot");

        uint256 tokenId = _bootstrap(tl, tu, 2 ether, 0.05e8);

        // Push spot OUT of the main range (rebalanceUsingAlt would be offered)... 1500 WETH-in moves spot from
        // ~-266368 to ~-266663, below tl=-266600 (amounts tuned to the pinned-block pool state).
        _pushTickDown(1_500 ether);
        (, int24 spotOut,,,,) = ICLPool(POOL).slot0();
        assertTrue(spotOut < tl || spotOut >= tu, "swap should push main out of range");

        // ...then push it BACK so spot re-straddles the main. Now the withdrawn principal is
        // two-sided and the rebuild can form a balanced straddle on the (re-)current spot.
        // ~30 cbBTC-in lifts spot to ~-266417, back inside [tl, tu] = [-266600, -266200].
        _pushTickUp(30e8);
        (, int24 spotBack,,,,) = ICLPool(POOL).slot0();
        assertTrue(tl < spotBack && spotBack < tu, "spot pushed back inside main range");

        // Let observations advance past the swaps so observe() has a window to average.
        skip(120);
        vm.roll(block.number + 1);

        uint256 feeColl0Before = IERC20(WETH).balanceOf(feeCollector);
        uint256 feeColl1Before = IERC20(CBBTC).balanceOf(feeCollector);
        uint256 aeroBefore = IERC20(AERO).balanceOf(feeCollector);

        vm.prank(rebalancer);
        vm.recordLogs();
        lab.rebalanceUsingAlt(_defaultParams());

        (uint256 newMain,) = _assertNoSwapRebuild(tokenId, feeColl0Before, feeColl1Before, aeroBefore);

        // The defining assertion of the balanced path: the spot-centered rebuild is IN RANGE.
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertTrue(s.mainInRange, "balanced main is in range after spot-centered rebalanceUsingAlt");
        assertGt(s.mainLiquidity, 0, "rebuilt main has liquidity");
        newMain; // used via the snapshot above
    }

    /// @notice SINGLE-SIDED rebuild (the real-mint edge the fork test surfaced and the contract now
    ///         handles). The main is driven FULLY out of range and STAYS out → 100%-single-sided
    ///         withdrawal. A spot-straddling balanced mint with one desired leg == 0 computes ZERO
    ///         liquidity and the position manager reverts; with NO SWAP the missing leg cannot be
    ///         manufactured. The contract's `_mainRange` fix parks the funded token in a single-sided
    ///         range adjacent to spot — valid liquidity, nothing sold, principal fully redeployed.
    function test_rebalanceUsingAlt_singleSidedWithdrawal_noSwap() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();

        int24 center = _align(spotTick);
        int24 tl = center - 200;
        int24 tu = center + 200;
        require(tl < spotTick && spotTick < tu, "setup: main must straddle spot");

        uint256 tokenId = _bootstrap(tl, tu, 2 ether, 0.05e8);

        // Push spot decisively BELOW the main and leave it there → the main holds 100% WETH (token0).
        _pushTickDown(2_000 ether);
        (, int24 spotOut,,,,) = ICLPool(POOL).slot0();
        assertTrue(spotOut < tl, "main fully out of range, single-sided WETH");

        skip(120);
        vm.roll(block.number + 1);

        uint256 feeColl0Before = IERC20(WETH).balanceOf(feeCollector);
        uint256 feeColl1Before = IERC20(CBBTC).balanceOf(feeCollector);
        uint256 aeroBefore = IERC20(AERO).balanceOf(feeCollector);

        vm.prank(rebalancer);
        vm.recordLogs();
        // Without the _mainRange fix this reverts inside the position manager (0-liquidity straddle).
        lab.rebalanceUsingAlt(_defaultParams());

        (uint256 newMain,) = _assertNoSwapRebuild(tokenId, feeColl0Before, feeColl1Before, aeroBefore);

        // The rebuilt single-sided main is a VALID position with real liquidity, parked on the funded
        // (token0/WETH) side strictly above spot — so it is intentionally NOT in range yet; it waits
        // for price to oscillate back. No swap occurred; the WETH principal was fully redeployed.
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertGt(s.mainLiquidity, 0, "single-sided main has real liquidity (no revert, no swap)");
        assertTrue(s.mainTickLower > spotOut, "single-sided main parked strictly above spot (token0 side)");
        newMain; // consumed via the snapshot above
    }

    // ─── compound() + module split (real gauge AERO harvest) ─────────────────────

    /// @dev Real AERO accrues on the staked position; compound() harvests it, drops the
    ///      (1 - compoundBps) share to feeCollector, and forwards the compoundBps share to the
    ///      LPCompoundModule (which owns the CowSwap orders). Settling a real CowSwap order is not
    ///      possible on a fork, so the swap leg is covered by the module unit tests.
    function test_compound_forwardsAeroToModule() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        _bootstrap(center - 200, center + 200, 2 ether, 0.05e8); // stakes + skips 2h → AERO accrues

        LPCompoundModule module = new LPCompoundModule(address(lab), AERO, admin);
        vm.prank(admin);
        lab.setCompoundModule(address(module));

        uint256 fcAeroBefore = IERC20(AERO).balanceOf(feeCollector);

        vm.prank(rebalancer);
        lab.compound(7_000); // 70% compound / 30% drop

        uint256 dropped = IERC20(AERO).balanceOf(feeCollector) - fcAeroBefore;
        uint256 forwarded = IERC20(AERO).balanceOf(address(module));
        uint256 total = dropped + forwarded;

        assertGt(total, 0, "AERO harvested from gauge");
        assertEq(dropped, total * 3_000 / 10_000, "30% dropped to feeCollector");
        assertEq(forwarded, total - total * 3_000 / 10_000, "70% forwarded to module");
        assertEq(IERC20(AERO).balanceOf(address(lab)), 0, "balancer retains no AERO");
    }

    /// @dev Settled compound proceeds arrive as loose WETH + cbBTC on the balancer (receiver ==
    ///      balancer). rebalanceUsingAlt() mints from balanceOf(this), folding them into the rebuilt position.
    function test_looseProceeds_foldAtRebalanceUsingAlt() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        _bootstrap(center - 200, center + 200, 2 ether, 0.05e8);

        // Simulate solver-delivered compound proceeds sitting loose on the contract.
        deal(WETH, address(lab), 0.1 ether);
        deal(CBBTC, address(lab), 0.002e8);
        uint256 looseBefore = IERC20(WETH).balanceOf(address(lab)) + IERC20(CBBTC).balanceOf(address(lab));
        assertGt(looseBefore, 0, "loose proceeds staged");

        skip(120);
        vm.roll(block.number + 1);
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultParams());

        (uint256 newMain,,) = _readSlot();
        assertGt(newMain, 0, "new main minted");
        uint256 looseAfter = IERC20(WETH).balanceOf(address(lab)) + IERC20(CBBTC).balanceOf(address(lab));
        assertLt(looseAfter, looseBefore, "loose compound proceeds folded into the rebuilt position");
    }

    // ─── two-phase swap rebalance (unwindForSwap / rebuildAfterSwap) ─────────────

    function _defaultUnwindParams(address sellToken, uint256 sellAmount)
        internal
        view
        returns (LPAutoBalancerV2.UnwindParams memory)
    {
        return LPAutoBalancerV2.UnwindParams({
            sellToken: sellToken,
            sellAmount: sellAmount,
            amount0MinWithdraw: 0,
            amount1MinWithdraw: 0,
            amount0MinWithdrawAlt: 0,
            amount1MinWithdrawAlt: 0,
            deadline: block.timestamp + 300
        });
    }

    function _ensureModule() internal returns (LPCompoundModule m) {
        if (lab.compoundModule() != address(0)) {
            return LPCompoundModule(lab.compoundModule());
        }
        m = new LPCompoundModule(address(lab), AERO, admin);
        vm.prank(admin);
        lab.setCompoundModule(address(m));
    }

    /// @notice Full two-phase cycle on a REAL Base-fork pool: unwindForSwap tears down both
    ///         positions and approves the CowSwap vault relayer for the sell leg; the test then
    ///         simulates a CowSwap settlement (relayer pulls the sell token, solver delivers the
    ///         buy token); rebuildAfterSwap mints + restakes a fresh main from the resulting
    ///         balances and closes the in-flight window.
    function test_fork_swapRebalance_fullTwoPhaseCycle() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        uint256 tokenId = _bootstrap(center - 200, center + 200, 1 ether, 0.03e8);
        _ensureModule();
        vm.prank(admin);
        lab.setSwapLossAllowanceBps(300); // headroom for the simulated fill's real-world slippage

        // ---- phase 1: unwind, selling 0.2 WETH ----
        uint256 sellAmount = 0.2 ether;
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams(WETH, sellAmount));

        assertTrue(lab.rebalanceInFlight());
        assertEq(lab.sellTokenInFlight(), WETH);
        assertEq(IERC20(WETH).allowance(address(lab), lab.VAULT_RELAYER()), sellAmount);
        (uint256 snapA0, uint256 snapA1,,) = lab.rebalanceAmountsBefore();
        assertGt(snapA0 + snapA1, 0, "amount baseline captured");
        assertGt(IERC20(WETH).balanceOf(address(lab)), 0, "principal loose on balancer");

        // ---- simulate the NET EFFECT of CowSwap settlement (not the transferFrom mechanics: this
        // pushes WETH out and deals cbBTC in directly, rather than pranking VAULT_RELAYER to pull via
        // the allowance unwindForSwap set). rebuildAfterSwap force-zeroes that allowance unconditionally
        // regardless of whether a real pull happened, so "approval revoked" below asserts rebuildAfterSwap's
        // cleanup, not that a transferFrom actually consumed it. 0.006e8 cbBTC approximates the pool's
        // fair rate for 0.2 WETH at the pinned block, comfortably inside the 300bps swapLossAllowanceBps set above ----
        vm.prank(address(lab));
        IERC20(WETH).transfer(makeAddr("cowSolver"), sellAmount);
        deal(CBBTC, address(lab), IERC20(CBBTC).balanceOf(address(lab)) + 0.006e8);

        // ---- phase 2: rebuild ----
        // Hoist: _defaultRebuildParams reads live spot (an EXTERNAL call), which would consume the
        // one-shot vm.prank and leave the rebuild un-pranked.
        LPAutoBalancerV2.RebuildParams memory rp = _defaultRebuildParams();
        vm.prank(rebalancer);
        lab.rebuildAfterSwap(rp);

        (uint256 mainTokenId,,,,,,, bool mainStaked,,,,,,,,,,,,,) = lab.position();
        assertTrue(mainTokenId != 0 && mainTokenId != tokenId, "new main minted");
        assertFalse(lab.rebalanceInFlight(), "window closed");
        assertEq(lab.sellTokenInFlight(), address(0));
        (uint256 clearedA0, uint256 clearedA1, uint256 clearedL0, uint256 clearedL1) = lab.rebalanceAmountsBefore();
        assertEq(clearedA0 + clearedA1 + clearedL0 + clearedL1, 0, "snapshot wiped");
        assertEq(IERC20(WETH).allowance(address(lab), lab.VAULT_RELAYER()), 0, "approval revoked");
        assertTrue(mainStaked, "restaked (bootstrap stakes)");
    }

    /// @notice Order expires unfilled on CowSwap: no balance changes occur between the two phases.
    ///         rebuildAfterSwap must still succeed, rebuilding from the untouched original balances.
    function test_fork_swapRebalance_unfilledOrder_rebuildStillWorks() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        _bootstrap(center - 200, center + 200, 1 ether, 0.03e8);
        _ensureModule();

        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams(WETH, 0.2 ether));

        // order expires unfilled: NO balance changes at all. Rebuild immediately.
        // Hoist: _defaultRebuildParams reads live spot (an EXTERNAL call), which would consume the
        // one-shot vm.prank and leave the rebuild un-pranked.
        LPAutoBalancerV2.RebuildParams memory rp = _defaultRebuildParams();
        vm.prank(rebalancer);
        lab.rebuildAfterSwap(rp);

        (uint256 mainTokenId,,,,,,,,,,,,,,,,,,,,) = lab.position();
        assertTrue(mainTokenId != 0, "rebuilt from original balances, identical outcome to rebalanceUsingAlt");
        assertFalse(lab.rebalanceInFlight());
        assertEq(IERC20(WETH).allowance(address(lab), lab.VAULT_RELAYER()), 0, "stale approval revoked");
    }

    /// @notice Regression for the exit() mid-flight fix: calling exit() while a swap rebalance is
    ///         in flight (both NFTs torn down, sell-token approval outstanding) must not revert and
    ///         must recover all principal to the given recipient, closing the in-flight window and
    ///         revoking the stale CowSwap approval.
    function test_fork_swapRebalance_exitMidFlight_recoversAllFunds() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        _bootstrap(center - 200, center + 200, 1 ether, 0.03e8);
        _ensureModule();

        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams(WETH, 0.2 ether));
        assertTrue(lab.rebalanceInFlight());

        uint256 wethOnContract = IERC20(WETH).balanceOf(address(lab));
        uint256 cbbtcOnContract = IERC20(CBBTC).balanceOf(address(lab));
        address safe = makeAddr("safeRecipient");

        vm.prank(admin);
        lab.exit(safe); // must NOT revert — this proves the exit() mid-flight fix from Task 7

        assertEq(IERC20(WETH).balanceOf(safe), wethOnContract, "principal recovered mid-flight");
        assertEq(IERC20(CBBTC).balanceOf(safe), cbbtcOnContract, "principal recovered mid-flight");
        assertFalse(lab.rebalanceInFlight());
        assertEq(IERC20(WETH).allowance(address(lab), lab.VAULT_RELAYER()), 0, "approval revoked on exit");
    }

    /// @notice MOO-723 against the REAL Slipstream NonfungiblePositionManager. Its mint() ends with
    ///         an unconditional refundETH(), which forwards the manager's ENTIRE native balance to
    ///         msg.sender (this balancer) and bubbles the failure if the recipient rejects it. The
    ///         manager is shared infrastructure, so anyone can force ETH into it via
    ///         create+selfdestruct. Without `receive()` on the balancer this reverts and every
    ///         principal-redeployment path is permanently bricked; the mock suite reproduces the
    ///         mechanism, but only this test exercises the real refundETH.
    function test_fork_rebalanceUsingAlt_survivesForcedEthOnRealPositionManager() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        _bootstrap(center - 200, center + 200, 2 ether, 0.05e8);
        skip(120);
        vm.roll(block.number + 1);

        uint256 labEthBefore = address(lab).balance;
        vm.deal(address(this), 1 wei);
        new ForceEtherFork{value: 1}(payable(NFPM));
        assertGt(NFPM.balance, 0, "ETH forced into the shared position manager");

        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultParams());

        (uint256 newMain,,) = _readSlot();
        assertGt(newMain, 0, "principal redeployed despite the donation");
        assertGt(address(lab).balance, labEthBefore, "refundETH proceeds accepted, not reverted");
    }

    /// @dev Regression for a whole-feature-review finding: unwindForSwap burns both real NFTs and
    ///      leaves position.mainTokenId/altTokenId pointing at them until rebuildAfterSwap re-mints.
    ///      getDecisionSnapshot() calling POSITION_MANAGER.positions() on a burned tokenId reverts
    ///      against the REAL Aerodrome position manager — the mock PM can't reproduce this since it
    ///      never deletes burned positions. This fork test is the only thing that actually proves the
    ///      off-chain agent's primary read interface stays callable for the whole in-flight window.
    function test_fork_getDecisionSnapshot_callableMidFlight() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        _bootstrap(center - 200, center + 200, 1 ether, 0.03e8);
        _ensureModule();

        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams(WETH, 0.2 ether));

        // must NOT revert against the real position manager, even though the burned mainTokenId is
        // still what `position.mainTokenId` points at.
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertTrue(s.rebalanceInFlight);
        assertGt(s.rebalanceStartedAt, 0);
        assertEq(s.mainLiquidity, 0, "position geometry skipped while in flight");
    }
}
