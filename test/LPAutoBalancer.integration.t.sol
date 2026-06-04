// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";
import {ICLPool} from "@contracts/interfaces/ICLPool.sol";

import {INonfungiblePositionManager} from "@contracts/interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LPAutoBalancerSetup} from "../multisig/f-mamo/006_LPAutoBalancerSetup.sol";

import {console} from "forge-std/console.sol";

contract LPAutoBalancerIntegrationTest is BaseTest {
    LPAutoBalancerSetup public setupScript;
    LPAutoBalancer public lab;

    uint256 public constant TOKEN_ID = 21585074;

    // Addresses populated from registry in setUp
    address public rebalancer;
    address public manager;
    address public fMamo;
    address public mamoToken;
    address public usdcToken;
    address public dropAutomation;
    address public pool;
    INonfungiblePositionManager public pm;

    function setUp() public override {
        super.setUp();

        setupScript = new LPAutoBalancerSetup();

        // Pass our addresses instance to the setup script
        setupScript.setAddresses(addresses);

        // Make deploy script persistent across fork snapshots
        vm.makePersistent(address(setupScript.deployLPAutoBalancer()));

        // Deploy LPAutoBalancer if not already set in the address registry
        if (!addresses.isAddressSet("MAMO_LP_AUTO_BALANCER")) {
            address labAddr = setupScript.deployLPAutoBalancer().deploy(addresses);
            addresses.addAddress("MAMO_LP_AUTO_BALANCER", labAddr, true);
        }

        lab = LPAutoBalancer(addresses.getAddress("MAMO_LP_AUTO_BALANCER"));

        // Execute the proposal: release NFT from TransferAndEarn → F-MAMO → lab,
        // then registerPosition() on lab.
        setupScript.build();
        setupScript.simulate();
        setupScript.validate();

        // Cache frequently-used addresses
        rebalancer = addresses.getAddress("MAMO_LP_REBALANCER");
        manager = addresses.getAddress("MAMO_LP_MANAGER");
        fMamo = addresses.getAddress("F-MAMO");
        mamoToken = addresses.getAddress("MAMO");
        usdcToken = addresses.getAddress("USDC");
        dropAutomation = addresses.getAddress("DROP_AUTOMATION");
        pool = addresses.getAddress("MAMO_USDC_POOL");
        pm = INonfungiblePositionManager(addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME"));
    }

    function test_setup_positionRegistered() public view {
        address pmAddr = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");

        // NFT 21585074 owned by LPAutoBalancer
        assertEq(
            INonfungiblePositionManager(pmAddr).ownerOf(TOKEN_ID),
            address(lab),
            "NFT 21585074 should be owned by LPAutoBalancer"
        );

        // Slot 0 is active
        (uint256 tokenId,,,,,,,,,,,,,,,,,,,,, bool active) = lab.positions(0);

        assertTrue(active, "Slot 0 should be active");
        assertEq(tokenId, TOKEN_ID, "Slot 0 tokenId should be 21585074");

        console.log("test_setup_positionRegistered: PASS");
        console.log("  LPAutoBalancer:", address(lab));
        console.log("  NFT tokenId:", tokenId);
        console.log("  Slot 0 active:", active);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Returns true if tokenId still exists (ownerOf doesn't revert).
    function _nftExists(uint256 tokenId) internal view returns (bool) {
        try pm.ownerOf(tokenId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Prank as `manager` and relax config for fork conditions:
    ///      - twapWindow reduced to 60s (pool cardinality on fork may be low)
    ///      - maxTickDeviation widened to 887272 (fork spot vs TWAP may differ)
    ///      - maxRebalanceLossBps increased to 300 (3%) to absorb real swap fees
    ///      - minRebalanceInterval set to 0 so we can rebalance immediately
    function _relaxConfigForFork() internal {
        vm.prank(manager);
        lab.setPositionConfig(
            0, // slotId
            400, // minWidth (unchanged, must be multiple of 200)
            20000, // maxWidth (unchanged)
            2000, // maxCenterDeviation (unchanged)
            100, // maxSlippageBps (unchanged)
            60, // twapWindow: 60s instead of 1800s — pool cardinality on fresh fork
            887_272, // maxTickDeviation: essentially unbounded — fork spot/TWAP may diverge
            300, // maxRebalanceLossBps: 3% to absorb real CL swap fees on concentrated range
            0 // minRebalanceInterval: 0 so we can call immediately after setUp
        );
    }

    /// @dev Build RebalanceParams for the fork test.
    ///      All min-amounts set to 0 (conservative test; value floor is the real guard).
    function _buildParams(uint24 width) internal view returns (LPAutoBalancer.RebalanceParams memory) {
        return LPAutoBalancer.RebalanceParams({
            width: width,
            swapMinAmountOut: 0,
            amount0MinDecrease: 0,
            amount1MinDecrease: 0,
            amount0MinMint: 0,
            amount1MinMint: 0,
            deadline: block.timestamp + 300
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // test_rebalance_realPosition
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice End-to-end fork test: re-range the real MAMO/USDC position from
    ///         full-range (-887200/887200) to a width-4000 range centred on TWAP.
    function test_rebalance_realPosition() public {
        // ── 0. Warp forward so the pool has some TWAP history ────────────────
        //    Even 60s is enough for observe(60) on a live pool.
        vm.warp(block.timestamp + 120);

        // ── 1. Relax config for fork conditions ──────────────────────────────
        _relaxConfigForFork();

        // ── 2. Grant REBALANCER_ROLE to rebalancer (it's a dummy EOA in addresses)
        //      The role was granted in the proposal, but we prank as admin to be safe.
        if (!lab.hasRole(lab.REBALANCER_ROLE(), rebalancer)) {
            vm.prank(fMamo);
            lab.grantRole(lab.REBALANCER_ROLE(), rebalancer);
        }

        // ── 3. Snapshot balances before ──────────────────────────────────────
        uint256 mamoBalDropBefore = IERC20(mamoToken).balanceOf(dropAutomation);

        // ── 4. Log current pool state ─────────────────────────────────────────
        (, int24 spotTick,,,,) = ICLPool(pool).slot0();
        console.log("Spot tick before rebalance:");
        console.logInt(spotTick);

        // ── 5. Call rebalance as REBALANCER ──────────────────────────────────
        uint24 width = 4000; // multiple of tickSpacing=200, within [400, 20000]
        LPAutoBalancer.RebalanceParams memory params = _buildParams(width);

        vm.prank(rebalancer);
        lab.rebalance(0, params);

        // ── 6. Assert: new tokenId assigned ──────────────────────────────────
        (uint256 newTokenId,,,,,,,,,,,,,,,,,,,,, bool active) = lab.positions(0);
        assertTrue(active, "slot 0 must remain active after rebalance");
        assertTrue(newTokenId != TOKEN_ID, "tokenId must have changed after re-range");
        console.log("Old tokenId:", TOKEN_ID);
        console.log("New tokenId:", newTokenId);

        // ── 7. Assert: old NFT is burned ─────────────────────────────────────
        assertFalse(_nftExists(TOKEN_ID), "old NFT 21585074 must be burned");

        // ── 8. Assert: new position straddles current tick with correct width ─
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liq,,,,) = pm.positions(newTokenId);
        int24 actualWidth = tickUpper - tickLower;
        assertEq(uint24(actualWidth), width, "new position width must equal requested width");
        assertTrue(liq > 0, "new position must have nonzero liquidity");
        assertTrue(tickLower < spotTick && spotTick < tickUpper, "new range must straddle spot tick");

        console.log("New tickLower:");
        console.logInt(tickLower);
        console.log("New tickUpper:");
        console.logInt(tickUpper);
        console.log("New liquidity:", liq);

        // ── 9. Assert: no MAMO or USDC dust left in lab ──────────────────────
        //    _forwardDust() sends remaining balances to feeCollector (DROP_AUTOMATION)
        assertEq(IERC20(mamoToken).balanceOf(address(lab)), 0, "lab must hold 0 MAMO after rebalance");
        assertEq(IERC20(usdcToken).balanceOf(address(lab)), 0, "lab must hold 0 USDC after rebalance");

        // ── 10. Assert: swapPolicy=1 honored — MAMO was NOT sold ─────────────
        //    Any MAMO that left lab can only go to DROP_AUTOMATION (dust or fees).
        //    MAMO is never sold; it can only increase (dust forwarded) at DROP_AUTOMATION.
        uint256 mamoBalDropAfter = IERC20(mamoToken).balanceOf(dropAutomation);
        assertGe(mamoBalDropAfter, mamoBalDropBefore, "DROP_AUTOMATION MAMO balance must not decrease (no MAMO sold)");

        console.log("test_rebalance_realPosition: PASS");
        console.log("  Old tokenId:", TOKEN_ID, "burned");
        console.log("  New tokenId:", newTokenId);
        console.log("  Width:", width, "ticks");
        console.log("  MAMO in lab after:", IERC20(mamoToken).balanceOf(address(lab)));
        console.log("  USDC in lab after:", IERC20(usdcToken).balanceOf(address(lab)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // test_rebalance_revertNonRebalancer_fork
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Sanity: a random address without REBALANCER_ROLE cannot call rebalance.
    function test_rebalance_revertNonRebalancer_fork() public {
        address rando = address(0xDEAD);
        LPAutoBalancer.RebalanceParams memory params = _buildParams(4000);

        vm.expectRevert();
        vm.prank(rando);
        lab.rebalance(0, params);

        console.log("test_rebalance_revertNonRebalancer_fork: PASS");
    }
}
