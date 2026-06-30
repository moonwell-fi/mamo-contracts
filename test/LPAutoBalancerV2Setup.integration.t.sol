// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2Setup} from "../multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol";

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {Test} from "@forge-std/Test.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";

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
// reset(), expecting a successful single-sided rebuild with real liquidity.
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

        // Mint a REAL WETH/cbBTC Slipstream position owned by the F-MAMO Safe (Phase-B precondition).
        tokenId = _mintMainPositionTo(safe, 2 ether, 0.05e8);

        // Instantiate + wire the proposal.
        proposal = new LPAutoBalancerV2Setup();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
        proposal.setTokenId(tokenId);
        proposal.setRebalancerEOA(rebalancerEOA);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _align(int24 tick) internal pure returns (int24) {
        int24 q = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) q -= 1;
        return q * TICK_SPACING;
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

    function _defaultResetParams() internal view returns (LPAutoBalancerV2.ResetParams memory) {
        return LPAutoBalancerV2.ResetParams({
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

    // ─── test ──────────────────────────────────────────────────────────────────

    function test_proposal_lifecycle() public {
        // Precondition: the Safe holds the freshly minted NFT.
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(tokenId), safe, "Safe owns NFT pre-setup");

        // 1. Deploy LPAutoBalancerV2.
        proposal.deploy();

        address labAddr = addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2");
        assertTrue(labAddr != address(0), "balancer deployed");
        LPAutoBalancerV2 lab = LPAutoBalancerV2(labAddr);

        // 2-3. Build the Safe actions, simulate (Safe executes them atomically), validate.
        proposal.build();
        proposal.simulate();
        proposal.validate();

        // Post-setup sanity: NFT custodied by the balancer, rebalancer granted.
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(tokenId), labAddr, "balancer owns NFT post-setup");
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), rebalancerEOA), "rebalancer granted");

        // ── End-to-end: prove the registered position is OPERABLE by the granted rebalancer. ──
        // Stake the main into the gauge so reset() exercises the unstake/skim/restake path.
        vm.prank(rebalancerEOA);
        lab.stake();

        // Accrue AERO + advance the TWAP observation window.
        skip(2 hours);
        vm.roll(block.number + 1);

        // Drive spot BELOW the main range → single-sided WETH withdrawal on reset. The production
        // config gates reset on |spot - TWAP| <= maxTickDeviation (100), so we cannot do a single
        // huge swap (its instantaneous spot vs the lagging 1800s TWAP would trip TwapDeviation).
        // Instead: do the swap, then skip well past twapWindow (1800s) so the TWAP converges onto
        // the post-swap tick and the deviation gate is back within tolerance at reset time.
        (, int24 spotBefore,,,,) = ICLPool(POOL).slot0();
        _pushTickDown(2_000 ether);
        (, int24 spotOut,,,,) = ICLPool(POOL).slot0();
        assertTrue(spotOut < spotBefore, "swap pushed spot down");
        assertTrue(spotOut < int24(-266600), "main fully out of range, single-sided WETH");

        // Let the TWAP catch up to the new spot (skip >> twapWindow so the post-swap tick dominates).
        skip(2 hours);
        vm.roll(block.number + 1);

        LPAutoBalancerV2.DecisionSnapshotV2 memory snapBefore = lab.getDecisionSnapshot();
        assertFalse(snapBefore.mainInRange, "main driven out of range");
        assertTrue(snapBefore.deviationGateOpen, "TWAP converged: deviation gate open for reset");

        // As the granted rebalancer: reset must succeed (no revert) and rebuild a real position.
        vm.prank(rebalancerEOA);
        lab.reset(_defaultResetParams());

        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertGt(s.mainLiquidity, 0, "rebuilt main has real liquidity (operable, no swap)");
        assertTrue(s.mainStaked, "main restaked after reset (was staked before)");
    }
}
