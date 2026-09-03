// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployLeveragedAeroAccountSystem} from "../multisig/mamo-multisig/012_DeployLeveragedAeroAccountSystem.sol";
import {DeployLeveragedAeroPooledSystem} from "../multisig/mamo-multisig/015_DeployLeveragedAeroPooledSystem.sol";

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {MamoLeveragedAeroStrategy} from "@contracts/MamoLeveragedAeroStrategy.sol";
import {MamoLeveragedAeroStrategyFactory} from "@contracts/MamoLeveragedAeroStrategyFactory.sol";
import {LeveragedAeroManager} from "@contracts/leveraged-aero/LeveragedAeroManager.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// LeveragedAeroSystemSetupTest — REAL Base-fork exercise of the two leveraged-Aero deployment
// proposals, in the order mainnet will run them, followed by a user lifecycle on the result.
//
// Mirrors LPAutoBalancerV2Setup.integration.t.sol: PINNED fork + the vm.fee(0) op-revm Isthmus
// workaround, the test owns the FPS `Addresses` book and injects what mainnet has not committed
// yet (MAMO_REBALANCER — an ops-held EOA the deploy PR deliberately leaves out).
//
// NO --fork-url on the make target: foundry 1.7.x would init the OP-stack L1Block handler against
// the CLI fork and panic before the in-test vm.fee(0) workaround runs. The fork is created here.
//
// WHAT THIS DRIVES, END TO END, AGAINST REAL VENUES
//   1. proposal 015 — template + vault deploy, then the multisig's approve / cloneAndBind /
//      setMaxTotalAssets / activateStrategy. The clone really supplies mUSDC, borrows cbBTC, swaps,
//      mints the Slipstream LP and stakes it in the live gauge.
//   2. proposal 012 — account implementation + factory, whitelist type 5, grant the factory
//      BACKEND_ROLE, open vault deposits. Its typeId-5 preconditions hold unmodified at the pinned
//      block (latestImplementationById(5) == 0, nextStrategyTypeId() == 4).
//   3. a user account: create -> deposit -> previewWithdraw -> fast withdraw -> requestWithdraw ->
//      (as the rebalancer) fulfillRedeem -> claimWithdrawnUsdc.
//
// WHAT THIS DELIBERATELY DOES NOT DRIVE
//   A GREEN HARVEST. `compound()` needs accrued gauge emissions, which need either a time warp
//   past the AERO accrual (which also ages the Chainlink answers toward the 48h maxDelay and
//   leaves the pool's TWAP ring extrapolating) or a mocked gauge. Faking either would prove
//   nothing about the fee wiring that `layout()` does not already state. So the fee leg asserts
//   the WIRING (compoundFeeBps, feeRecipient), that the zero-floor belt really fires on a live book,
//   and that `compound` from the granted rebalancer is a clean no-op on a freshly minted, reward-free
//   book — i.e. the proposer role and the entrypoint are live — and stops there. The skim arithmetic
//   itself is covered by test/leveraged-aero/LeveragedAeroCompoundHedge.unit.t.sol against venue mocks.
// ─────────────────────────────────────────────────────────────────────────────

contract LeveragedAeroSystemSetupTest is Test {
    /// @dev Pinned for determinism (2026-08-27 00:09 UTC). At this block registry type id 5 is free and
    ///      `nextStrategyTypeId()` reads 4, so 012's availability guard passes as written.
    ///
    ///      THIS BLOCK IS DELIBERATELY BEFORE 50_519_338. At that block (2026-08-27 10:53 UTC) Moonwell
    ///      set `borrowCaps(MOONWELL_cbBTC)` on Base from 9e9 to **1**, which Compound-v2's
    ///      `borrowAllowed` reads as "no new borrowing at any size" — so on HEAD-of-chain Base the
    ///      strategy's cbBTC borrow inside `activateStrategy` reverts "market borrow cap reached" and
    ///      015 CANNOT EXECUTE. That is a live external blocker on the mainnet deploy, not a test
    ///      artifact, and it is recorded here rather than papered over: the alternative — pinning HEAD
    ///      and raising the cap as the `borrowCapGuardian` — would make this suite green over a
    ///      deployment that reverts on the real chain. Before signing 015, ops must confirm
    ///      `borrowCaps(MOONWELL_cbBTC) - totalBorrows() > seed x targetLtvBps` in cbBTC terms.
    uint256 constant PINNED_BLOCK = 50_500_000;

    uint256 constant USER_DEPOSIT = 5_000e6;

    DeployLeveragedAeroPooledSystem pooled;
    DeployLeveragedAeroAccountSystem account;
    Addresses addresses;

    address multisig;
    address usdc;
    address rebalancer = makeAddr("leveragedAeroRebalancer");
    address user = makeAddr("leveragedAeroUser");

    function setUp() public {
        // PIN THE BLOCK (mandatory) — deterministic fork.
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        // op-revm Isthmus operator-fee workaround (see LPAutoBalancerV2.integration.t.sol).
        vm.txGasPrice(0);
        vm.fee(0);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));

        // MAMO_REBALANCER is an ops-held EOA, not committed by the deploy PR (see 015's NatSpec).
        // isContract = false: it is a signer key, and FPS validates that eagerly.
        addresses.addAddress("MAMO_REBALANCER", rebalancer, false);

        multisig = addresses.getAddress("MAMO_MULTISIG");
        usdc = addresses.getAddress("USDC");

        pooled = new DeployLeveragedAeroPooledSystem();
        pooled.setPrimaryForkId(vm.activeFork());
        pooled.setAddresses(addresses);

        account = new DeployLeveragedAeroAccountSystem();
        account.setPrimaryForkId(vm.activeFork());
        account.setAddresses(addresses);
    }

    /// @dev One test, not three: the two proposals and the user lifecycle are strictly sequential and
    ///      each stage's preconditions ARE the previous stage's post-conditions. Splitting them would
    ///      re-run the (expensive) template + library deploy per case and prove nothing extra.
    function test_pooledThenAccountSetup_andUserLifecycle() public {
        _runPooledProposal();
        _runAccountProposal();
        _proveUserLifecycle();
        _proveCompoundWiring();
    }

    function _clone() internal view returns (LeveragedAerodromeCLStrategy) {
        return LeveragedAerodromeCLStrategy(payable(addresses.getAddress("LEVERAGED_AERO_STRATEGY")));
    }

    // ─── stage 1: proposal 015 (pooled layer) ────────────────────────────────

    function _runPooledProposal() internal {
        pooled.deploy();
        pooled.preBuildMock();
        pooled.build();
        pooled.simulate();
        pooled.validate();

        // Post-conditions the account layer rests on, restated here so a 015 regression fails in this
        // test's own body rather than only inside the proposal's validate().
        LeveragedAeroVault vault = LeveragedAeroVault(addresses.getAddress("LEVERAGED_AERO_VAULT"));
        address clone = addresses.getAddress("LEVERAGED_AERO_STRATEGY");
        assertEq(vault.strategy(), clone, "vault bound to the clone");
        assertGt(LeveragedAerodromeCLStrategy(payable(clone)).nav(), 0, "seeded book has NAV");
        assertFalse(vault.depositsOpen(), "deposits still closed before 012");
    }

    // ─── stage 2: proposal 012 (account layer) ───────────────────────────────

    function _runAccountProposal() internal {
        account.deploy();
        account.preBuildMock();
        account.build();
        account.simulate();
        account.validate();

        assertTrue(
            LeveragedAeroVault(addresses.getAddress("LEVERAGED_AERO_VAULT")).depositsOpen(),
            "012 should have opened deposits"
        );
    }

    // ─── stage 3: a real user, real venues ───────────────────────────────────

    function _proveUserLifecycle() internal {
        MamoLeveragedAeroStrategyFactory factory =
            MamoLeveragedAeroStrategyFactory(addresses.getAddress("MAMO_LEVERAGED_AERO_STRATEGY_FACTORY"));

        vm.prank(user);
        MamoLeveragedAeroStrategy acct = MamoLeveragedAeroStrategy(payable(factory.createStrategyForUser(user)));
        assertEq(acct.owner(), user, "account owned by the user");

        // Deposit: real mUSDC supply + cbBTC borrow + swap + LP mint on the live venues.
        deal(usdc, user, USER_DEPOSIT);
        vm.startPrank(user);
        IERC20(usdc).approve(address(acct), USER_DEPOSIT);
        uint256 shares = acct.deposit(USER_DEPOSIT, 0);
        vm.stopPrank();
        assertGt(shares, 0, "deposit minted shares");
        assertEq(acct.sharesBalance(), shares, "account custodies the shares");

        // Fast path on half the position. The fast path's LTV gate is size-dependent, so assert the
        // preview agrees it is open before using it rather than discovering a revert.
        uint256 fastShares = shares / 2;
        (uint256 previewOut, bool fastOk) = acct.previewWithdraw(fastShares);
        assertTrue(fastOk, "fast path open for half the position");
        assertGt(previewOut, 0, "preview quotes a payout");

        uint256 userBefore = IERC20(usdc).balanceOf(user);
        vm.prank(user);
        uint256 fastOut = acct.withdraw(fastShares, 0);
        assertGt(fastOut, 0, "fast withdraw paid out");
        assertEq(IERC20(usdc).balanceOf(user) - userBefore, fastOut, "fast withdraw forwarded to the owner");

        // Async path on the remainder: escrow, then fulfil as the rebalancer the proposal granted.
        // `fulfillRedeem` pays the request's RECIPIENT (the owner, captured at request time) directly —
        // the account is not an intermediary, and there is no account-side fulfilment event.
        uint256 rest = acct.sharesBalance();
        vm.prank(user);
        uint256 id = acct.requestWithdraw(rest, 0);
        assertEq(acct.openRequestIds().length, 1, "request tracked");

        // Resolve the clone BEFORE pranking: `getAddress` is an external call and would consume the
        // prank, leaving `fulfillRedeem` to revert NotProposer() under the test contract's identity.
        LeveragedAerodromeCLStrategy clone = _clone();
        userBefore = IERC20(usdc).balanceOf(user);
        vm.prank(rebalancer);
        clone.fulfillRedeem(id, 0);
        assertGt(IERC20(usdc).balanceOf(user), userBefore, "fulfil paid the recipient");
        assertEq(acct.sharesBalance(), 0, "position fully exited");

        // claimWithdrawnUsdc is the stray-USDC sweep, NOT the withdrawal claim (the fulfil above paid
        // the user directly). Prove the sweep on a plain transfer, which is the state it exists for.
        deal(usdc, address(acct), 25e6);
        userBefore = IERC20(usdc).balanceOf(user);
        vm.prank(user);
        assertEq(acct.claimWithdrawnUsdc(), 25e6, "sweep returns the idle balance");
        assertEq(IERC20(usdc).balanceOf(user) - userBefore, 25e6, "sweep forwarded to the owner");
        // The fulfilled request is pruned by the sweep's `_pruneSettled`.
        assertEq(acct.openRequestIds().length, 0, "settled request pruned");
    }

    // ─── stage 4: the compound-fee wiring (see the header for what is NOT driven) ──

    function _proveCompoundWiring() internal {
        LeveragedAerodromeCLStrategy clone = _clone();
        LeveragedAerodromeCLStrategy.LayoutView memory v = clone.layout();

        assertEq(uint256(v.compoundFeeBps), 500, "5% in-kind AERO skim");
        assertEq(v.feeRecipient, multisig, "fee recipient is the multisig");
        assertEq(clone.proposer(), rebalancer, "rebalancer holds the proposer role");

        // The min-out belt is live on a real (non-flat) book: `compound` rejects a zero floor BEFORE it
        // probes for rewards, so this reverts whether or not AERO happens to be claimable.
        vm.prank(rebalancer);
        vm.expectRevert(LeveragedAeroManager.ZeroMinOut.selector);
        clone.compound(0, 0);

        // With a real floor the entrypoint is a clean no-op on a reward-free book: the position is
        // minutes old in fork time, so `earned()` and the held AERO balance are both 0 and `compound`
        // takes its "is there any reward" bail-out. No harvest is faked, so no skim is asserted.
        IERC20 aero = IERC20(addresses.getAddress("AERO"));
        uint256 feeAeroBefore = aero.balanceOf(v.feeRecipient);
        assertEq(aero.balanceOf(address(clone)), 0, "no AERO held yet");
        vm.prank(rebalancer);
        clone.compound(1, 0);
        assertEq(aero.balanceOf(v.feeRecipient), feeAeroBefore, "no skim without a harvest");
    }
}
