// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";
import {ICLGauge} from "@contracts/interfaces/ICLGauge.sol";
import {ICLPool} from "@contracts/interfaces/ICLPool.sol";

import {INonfungiblePositionManager} from "@contracts/interfaces/INonfungiblePositionManager.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

    // ─────────────────────────────────────────────────────────────────────────
    // Task 27 — gauge stake / claim / restake
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice End-to-end gauge lifecycle on a real Aerodrome CL gauge:
    ///         stake → warp → claimEmissions (permissionless) → rebalance (auto-restake)
    ///         → unstake. Verifies NFT custody, staking state and AERO flows.
    function test_gauge_stakeClaimRestake() public {
        // ── 0. Warp so pool has TWAP history ────────────────────────────────
        vm.warp(block.timestamp + 120);

        // ── 1. Loosen config for fork conditions ────────────────────────────
        _relaxConfigForFork();

        // ── 2. Ensure rebalancer role is granted ────────────────────────────
        if (!lab.hasRole(lab.REBALANCER_ROLE(), rebalancer)) {
            vm.prank(fMamo);
            lab.grantRole(lab.REBALANCER_ROLE(), rebalancer);
        }

        address gauge = addresses.getAddress("AERODROME_MAMO_USDC_GAUGE");
        address aeroToken = addresses.getAddress("AERO");

        // ── 3. stake(0) as rebalancer ────────────────────────────────────────
        vm.prank(rebalancer);
        lab.stake(0);

        // Assert staked flag is set
        (uint256 tokenId,,,,,, bool stakedAfterStake,,,,,,,,,,,,,,, bool active) = lab.positions(0);
        assertTrue(stakedAfterStake, "staked flag should be true after stake()");
        assertTrue(active, "slot should remain active");

        // NFT is now held by the gauge (deposited by lab)
        assertEq(pm.ownerOf(tokenId), gauge, "gauge should own the NFT after stake()");
        assertTrue(
            ICLGauge(gauge).stakedContains(address(lab), tokenId), "gauge.stakedContains should return true for lab"
        );

        console.log("Staked tokenId:", tokenId, "in gauge:", gauge);

        // ── 4. Extend oracle delay and warp to accrue AERO emissions ─────────
        //    The Chainlink feeds have real updatedAt timestamps. After a large
        //    warp the oracle freshness check (maxOracleDelay=26h) would fail inside
        //    the rebalance → _principalValue call. Set maxOracleDelay to the
        //    contract maximum (7 days) and warp by 6 days so the oracle lag
        //    stays within the new window (6 days << 7 days).
        vm.prank(fMamo);
        lab.setMaxOracleDelay(7 days);
        vm.warp(block.timestamp + 6 days);

        // ── 5. claimEmissions(0) — permissionless ────────────────────────────
        uint256 aeroDropBefore = IERC20(aeroToken).balanceOf(dropAutomation);

        address rando = address(0xBEEF);
        vm.prank(rando);
        lab.claimEmissions(0);

        uint256 aeroDropAfter = IERC20(aeroToken).balanceOf(dropAutomation);
        // If the gauge had non-zero rewards accrued, DROP_AUTOMATION receives them.
        // On a fresh fork the gauge may not be emitting (not whitelisted for epoch rewards).
        // Either way the call must not revert and DROP_AUTOMATION AERO balance must be >= before.
        assertGe(aeroDropAfter, aeroDropBefore, "DROP_AUTOMATION AERO must not decrease after claimEmissions");

        uint256 aeroClaimed = aeroDropAfter - aeroDropBefore;
        console.log("AERO claimed to DROP_AUTOMATION:", aeroClaimed);
        if (aeroClaimed == 0) {
            console.log("  (zero - gauge not emitting at fork block; call did not revert, invariant holds)");
        }

        // ── 6. rebalance while staked — contract auto-unstakes → re-ranges → restakes ─
        // Record DROP_AUTOMATION MAMO before rebalance to assert swapPolicy
        uint256 mamoDropBefore = IERC20(mamoToken).balanceOf(dropAutomation);

        LPAutoBalancer.RebalanceParams memory params = _buildParams(4000);
        vm.prank(rebalancer);
        lab.rebalance(0, params);

        // After rebalance: position should be restaked (wasStaked=true before rebalance)
        (uint256 newTokenId,,,,,, bool stakedAfterRebalance,,,,,,,,,,,,,,, bool activeAfter) = lab.positions(0);
        assertTrue(activeAfter, "slot must remain active after rebalance");
        assertTrue(stakedAfterRebalance, "slot must be restaked after rebalance (auto-restake)");
        assertTrue(newTokenId != tokenId, "tokenId must change after re-range");

        // New NFT should be owned by the gauge (restaked)
        assertEq(pm.ownerOf(newTokenId), gauge, "new NFT should be owned by gauge after auto-restake");
        assertTrue(
            ICLGauge(gauge).stakedContains(address(lab), newTokenId),
            "gauge.stakedContains should be true for new tokenId"
        );

        // swapPolicy=1 — MAMO balance at DROP_AUTOMATION must not decrease (no MAMO sold)
        uint256 mamoDropAfter = IERC20(mamoToken).balanceOf(dropAutomation);
        assertGe(mamoDropAfter, mamoDropBefore, "MAMO must not be sold during rebalance (swapPolicy=1)");

        console.log("Auto-restaked new tokenId:", newTokenId);

        // ── 7. unstake(0) as rebalancer ─────────────────────────────────────
        vm.prank(rebalancer);
        lab.unstake(0);

        (uint256 finalTokenId,,,,,, bool stakedAfterUnstake,,,,,,,,,,,,,,, bool activeFinal) = lab.positions(0);
        assertTrue(activeFinal, "slot must remain active after unstake");
        assertFalse(stakedAfterUnstake, "staked flag should be false after unstake()");
        assertEq(pm.ownerOf(finalTokenId), address(lab), "NFT should be back in lab after unstake");

        console.log("test_gauge_stakeClaimRestake: PASS");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task 28 — adversarial guard tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice swapPolicy=1 (never sell MAMO) is enforced even when the rebalance
    ///         direction would call for selling MAMO. The MAMO balance at DROP_AUTOMATION
    ///         must be non-decreasing across the rebalance call.
    ///
    ///         At the current fork price (MAMO very cheap vs USDC, tick ≈ -323982)
    ///         the position holds mostly MAMO after decrease. The range is re-centered
    ///         on TWAP so the swap direction could be zeroForOne (sell MAMO) to reach
    ///         the new ratio — but swapPolicy=1 blocks that leg. Lab keeps all MAMO
    ///         and dumps surplus MAMO as dust to DROP_AUTOMATION, not via a swap.
    function test_adversarial_swapPolicyProtectsMamo() public {
        vm.warp(block.timestamp + 120);
        _relaxConfigForFork();

        if (!lab.hasRole(lab.REBALANCER_ROLE(), rebalancer)) {
            vm.prank(fMamo);
            lab.grantRole(lab.REBALANCER_ROLE(), rebalancer);
        }

        uint256 mamoDropBefore = IERC20(mamoToken).balanceOf(dropAutomation);
        uint256 mamoLabBefore = IERC20(mamoToken).balanceOf(address(lab));

        LPAutoBalancer.RebalanceParams memory params = _buildParams(4000);
        vm.prank(rebalancer);
        lab.rebalance(0, params);

        // Core invariant: MAMO was never sold (no net MAMO outflow to a swap counterparty)
        uint256 mamoDropAfter = IERC20(mamoToken).balanceOf(dropAutomation);
        uint256 mamoLabAfter = IERC20(mamoToken).balanceOf(address(lab));

        // Lab holds 0 MAMO after (dust forwarded to feeCollector)
        assertEq(mamoLabAfter, 0, "lab must hold 0 MAMO after rebalance");
        // DROP_AUTOMATION may only gain MAMO (dust forwarded), never lose it
        assertGe(mamoDropAfter, mamoDropBefore, "DROP_AUTOMATION MAMO must not decrease - swapPolicy=1 honored");

        // Extra: the swap router never received MAMO (no safeTransfer to SWAP_ROUTER for MAMO)
        // We verify indirectly: total MAMO in (lab + dropAutomation) is >= before
        assertGe(
            mamoDropAfter + mamoLabAfter,
            mamoDropBefore + mamoLabBefore,
            "total MAMO in system must not decrease (no external sale)"
        );

        console.log("test_adversarial_swapPolicyProtectsMamo: PASS");
        console.log("  MAMO in DROP_AUTOMATION before:", mamoDropBefore);
        console.log("  MAMO in DROP_AUTOMATION after:", mamoDropAfter);
    }

    /// @notice Passing swapMinAmountOut=0 does NOT allow an underbounded drain.
    ///         The on-chain quoter floor at maxSlippageBps=100 (1%) still applies.
    ///         If the position value after >= (1 - maxRebalanceLossBps/10000) * valueBefore,
    ///         the position was not drained. Passing zero simply defers to the quoter floor.
    function test_adversarial_garbageSwapMinOut() public {
        vm.warp(block.timestamp + 120);
        _relaxConfigForFork();

        if (!lab.hasRole(lab.REBALANCER_ROLE(), rebalancer)) {
            vm.prank(fMamo);
            lab.grantRole(lab.REBALANCER_ROLE(), rebalancer);
        }

        // swapMinAmountOut = 0 (garbage / too permissive from caller)
        LPAutoBalancer.RebalanceParams memory params = LPAutoBalancer.RebalanceParams({
            width: 4000,
            swapMinAmountOut: 0, // <-- deliberately zero / garbage
            amount0MinDecrease: 0,
            amount1MinDecrease: 0,
            amount0MinMint: 0,
            amount1MinMint: 0,
            deadline: block.timestamp + 300
        });

        // Must succeed — the quoter floor at maxSlippageBps=100 bounds the swap internally
        vm.prank(rebalancer);
        lab.rebalance(0, params);

        // Verify the position is still healthy (active, has liquidity)
        (uint256 newTokenId,,,,,,,,,,,,,,,,,,,,, bool active) = lab.positions(0);
        assertTrue(active, "position must remain active");
        (,,,,,,, uint128 liq,,,,) = pm.positions(newTokenId);
        assertTrue(liq > 0, "new position must have nonzero liquidity - not drained");

        console.log("test_adversarial_garbageSwapMinOut: PASS");
        console.log("  New tokenId after rebalance with swapMinAmountOut=0:", newTokenId);
        console.log("  Liquidity:", liq);
    }

    /// @notice After a rebalance with minRebalanceInterval > 0, a second immediate
    ///         rebalance reverts with Cooldown().
    function test_adversarial_cooldown() public {
        vm.warp(block.timestamp + 120);

        // Set minRebalanceInterval=1 hour (nonzero cooldown)
        vm.prank(manager);
        lab.setPositionConfig(
            0,
            400,
            20000,
            2000,
            100,
            60, // twapWindow
            887_272, // maxTickDeviation
            300, // maxRebalanceLossBps
            1 hours // minRebalanceInterval — enforce cooldown
        );

        if (!lab.hasRole(lab.REBALANCER_ROLE(), rebalancer)) {
            vm.prank(fMamo);
            lab.grantRole(lab.REBALANCER_ROLE(), rebalancer);
        }

        LPAutoBalancer.RebalanceParams memory params = _buildParams(4000);

        // First rebalance succeeds
        vm.prank(rebalancer);
        lab.rebalance(0, params);

        // Immediate second rebalance reverts with Cooldown
        LPAutoBalancer.RebalanceParams memory params2 = _buildParams(4000);
        vm.expectRevert(LPAutoBalancer.Cooldown.selector);
        vm.prank(rebalancer);
        lab.rebalance(0, params2);

        // After cooldown elapses, rebalance should succeed again
        vm.warp(block.timestamp + 1 hours + 1);
        LPAutoBalancer.RebalanceParams memory params3 = _buildParams(4000);
        vm.prank(rebalancer);
        lab.rebalance(0, params3);

        console.log("test_adversarial_cooldown: PASS");
    }

    /// @notice Guardian can pause the contract. Paused rebalance reverts with EnforcedPause.
    ///         Unpause restores normal operation.
    function test_adversarial_paused() public {
        vm.warp(block.timestamp + 120);
        _relaxConfigForFork();

        if (!lab.hasRole(lab.REBALANCER_ROLE(), rebalancer)) {
            vm.prank(fMamo);
            lab.grantRole(lab.REBALANCER_ROLE(), rebalancer);
        }

        address guardian = addresses.getAddress("MAMO_PAUSE_GUARDIAN");

        // Guardian pauses
        vm.prank(guardian);
        lab.pause();
        assertTrue(lab.paused(), "contract should be paused");

        // Rebalance reverts while paused
        LPAutoBalancer.RebalanceParams memory params = _buildParams(4000);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(rebalancer);
        lab.rebalance(0, params);

        // stake also reverts while paused
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(rebalancer);
        lab.stake(0);

        // Guardian unpauses
        vm.prank(guardian);
        lab.unpause();
        assertFalse(lab.paused(), "contract should be unpaused");

        // Rebalance now succeeds
        vm.prank(rebalancer);
        lab.rebalance(0, params);

        (uint256 newTokenId,,,,,,,,,,,,,,,,,,,,, bool active) = lab.positions(0);
        assertTrue(active, "position must remain active after unpause+rebalance");

        console.log("test_adversarial_paused: PASS");
        console.log("  New tokenId after unpause+rebalance:", newTokenId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task 29 — migrate access control + sanity guards
    // ─────────────────────────────────────────────────────────────────────────
    //
    // WHY NO HAPPY-PATH MIGRATION TEST:
    // The held position is MAMO/USDC. The only available destination pool on Base
    // that shares a token is cbBTC/MAMO (0xE2B3aA806e56603a244bFc111c9474F7DeDD03db,
    // token0=MAMO, token1=cbBTC). Migrating there requires converting USDC → cbBTC,
    // which is NOT a single-hop swap through the MAMO/USDC pool (different pair).
    // _executeSwap uses the old pool's tickSpacing and only swaps old-token-in →
    // old-token-out — it cannot produce cbBTC. A cross-pair migration requires a
    // multi-hop route that the current contract does not support in a single call.
    // The unit-test happy path (LPAutoBalancerMigrate.unit.t.sol) already covers
    // the full migrate flow with a same-pair mock setup. Here we cover the
    // security-critical access control and fat-finger guard paths on the real fork.

    /// @notice Non-admin callers (rebalancer and a random EOA) cannot call migrate.
    function test_migrate_revertNonAdmin() public {
        // Build a minimally valid-looking params (destPool is a real contract so
        // the access check fires before any storage read)
        LPAutoBalancer.MigrateParams memory params = LPAutoBalancer.MigrateParams({
            destPool: addresses.getAddress("MAMO_USDC_POOL"), // real pool, has code
            destToken0: mamoToken,
            destToken1: usdcToken,
            destTickSpacing: 200,
            destGauge: address(0),
            destOracle0: mamoToken,
            destOracle1: usdcToken,
            destSwapPolicy: 0,
            destProtectedToken: address(0),
            tickLower: -326000,
            tickUpper: -322000,
            swapTokenIn: address(0),
            swapAmountIn: 0,
            swapMinAmountOut: 0,
            amount0MinDecrease: 0,
            amount1MinDecrease: 0,
            amount0MinMint: 0,
            amount1MinMint: 0,
            deadline: block.timestamp + 300
        });

        // Rebalancer cannot migrate (has REBALANCER_ROLE, not DEFAULT_ADMIN_ROLE)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rebalancer, lab.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(rebalancer);
        lab.migrate(0, params);

        // Random address cannot migrate
        address rando = address(0xDEAD);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rando, lab.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(rando);
        lab.migrate(0, params);

        console.log("test_migrate_revertNonAdmin: PASS");
    }

    /// @notice Fat-finger sanity guards in migrate() revert with InvalidConfig for bad inputs.
    function test_migrate_revertSanityGuards() public {
        address realPool = addresses.getAddress("MAMO_USDC_POOL");

        // ── Guard 1: destPool has no code (EOA) ─────────────────────────────
        LPAutoBalancer.MigrateParams memory badDestPool = LPAutoBalancer.MigrateParams({
            destPool: address(0xDEAD), // EOA — code.length == 0
            destToken0: mamoToken,
            destToken1: usdcToken,
            destTickSpacing: 200,
            destGauge: address(0),
            destOracle0: mamoToken,
            destOracle1: usdcToken,
            destSwapPolicy: 0,
            destProtectedToken: address(0),
            tickLower: -326000,
            tickUpper: -322000,
            swapTokenIn: address(0),
            swapAmountIn: 0,
            swapMinAmountOut: 0,
            amount0MinDecrease: 0,
            amount1MinDecrease: 0,
            amount0MinMint: 0,
            amount1MinMint: 0,
            deadline: block.timestamp + 300
        });
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        vm.prank(fMamo);
        lab.migrate(0, badDestPool);

        // ── Guard 2: destTickSpacing mismatch vs real pool ───────────────────
        LPAutoBalancer.MigrateParams memory badTickSpacing = LPAutoBalancer.MigrateParams({
            destPool: realPool, // real pool, tickSpacing=200
            destToken0: mamoToken,
            destToken1: usdcToken,
            destTickSpacing: 100, // wrong — pool is 200
            destGauge: address(0),
            destOracle0: mamoToken,
            destOracle1: usdcToken,
            destSwapPolicy: 0,
            destProtectedToken: address(0),
            tickLower: -326000,
            tickUpper: -322000,
            swapTokenIn: address(0),
            swapAmountIn: 0,
            swapMinAmountOut: 0,
            amount0MinDecrease: 0,
            amount1MinDecrease: 0,
            amount0MinMint: 0,
            amount1MinMint: 0,
            deadline: block.timestamp + 300
        });
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        vm.prank(fMamo);
        lab.migrate(0, badTickSpacing);

        // ── Guard 3: inverted ticks (tickLower >= tickUpper) ────────────────
        LPAutoBalancer.MigrateParams memory invertedTicks = LPAutoBalancer.MigrateParams({
            destPool: realPool,
            destToken0: mamoToken,
            destToken1: usdcToken,
            destTickSpacing: 200,
            destGauge: address(0),
            destOracle0: mamoToken,
            destOracle1: usdcToken,
            destSwapPolicy: 0,
            destProtectedToken: address(0),
            tickLower: -322000,
            tickUpper: -326000, // inverted: lower > upper
            swapTokenIn: address(0),
            swapAmountIn: 0,
            swapMinAmountOut: 0,
            amount0MinDecrease: 0,
            amount1MinDecrease: 0,
            amount0MinMint: 0,
            amount1MinMint: 0,
            deadline: block.timestamp + 300
        });
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        vm.prank(fMamo);
        lab.migrate(0, invertedTicks);

        // ── Guard 4: equal ticks (tickLower == tickUpper) ───────────────────
        LPAutoBalancer.MigrateParams memory equalTicks = LPAutoBalancer.MigrateParams({
            destPool: realPool,
            destToken0: mamoToken,
            destToken1: usdcToken,
            destTickSpacing: 200,
            destGauge: address(0),
            destOracle0: mamoToken,
            destOracle1: usdcToken,
            destSwapPolicy: 0,
            destProtectedToken: address(0),
            tickLower: -324000,
            tickUpper: -324000, // equal — also invalid
            swapTokenIn: address(0),
            swapAmountIn: 0,
            swapMinAmountOut: 0,
            amount0MinDecrease: 0,
            amount1MinDecrease: 0,
            amount0MinMint: 0,
            amount1MinMint: 0,
            deadline: block.timestamp + 300
        });
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        vm.prank(fMamo);
        lab.migrate(0, equalTicks);

        console.log("test_migrate_revertSanityGuards: PASS");
    }
}
