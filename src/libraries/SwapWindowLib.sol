// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SwapWindowLib
/// @notice The swap-rebalance in-flight window as one module: everything alive between
///         unwindForSwap (open) and rebuildAfterSwap/exit (close). The balancer owns the single
///         storage instance; this library defines the shape and the ONLY legal transitions.
///         INTERNAL on purpose (unlike the linked LP libraries): this seam exists for locality of
///         state-machine logic, not EIP-170 offloading — the functions inline into the balancer.
/// @dev WRITE DISCIPLINE: no code outside this library may assign to a SwapWindow field. Reads of
///      `w.inFlight`/`w.startedAt` etc. from balancer views are fine; writes go through
///      open/closeForRebuild/closeForExit only. Solidity cannot enforce this (struct fields have
///      no visibility) — it is a documented convention, kept honest by review.
/// @dev Invariants, by construction:
///      - open() is the ONLY approver and the closers the ONLY revokers of the relayer allowance,
///        so no approval ever outlives a closed window. (Not a biconditional with inFlight:
///        CowSwap settlement legitimately consumes the exact-amount approval mid-window, leaving
///        inFlight == true with allowance 0 until rebuild.)
///      - inFlight == true  ⟹ sellToken != address(0): open() reverts InvalidSellToken on a zero
///        sellToken, so closeForExit's forceApprove(sellToken, 0) can never target address(0) and
///        the escape hatch cannot revert — enforced HERE, independent of any caller prechecks.
///      - inFlight == false ⟺ every field is zero (both closers clear through the shared _wipe;
///        a future struct field is a one-place update there).
///      - The floor snapshot (the `Snapshot` amounts) is only readable through closeForRebuild,
///        which has already revoked and is about to clear — a stale snapshot cannot outlive its
///        window.
/// @dev Errors are redeclared here; a Solidity error's 4-byte selector depends only on its
///      signature, so existing vm.expectRevert(LPAutoBalancerV2.X.selector) matchers keep working.
library SwapWindowLib {
    using SafeERC20 for IERC20;

    error NotInFlight();
    error AlreadyInFlight();
    error InvalidSellToken();

    /// @dev Same address as LPAutoBalancerV2.VAULT_RELAYER — a module-local constant so
    ///      open/close take no relayer parameter (constants inline for free; the balancer already
    ///      duplicates this constant from LPCompoundModule for the same hot-path reason).
    address internal constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    /// @notice The value-floor baseline captured at unwind, in TOKEN AMOUNTS — never USD.
    /// @dev The floor spans two transactions (unwind → settle → rebuild). A USD baseline frozen at
    ///      unwind and compared against a USD `valueAfter` read at rebuild measures the MARKET's
    ///      move, not the rebalance's: both legs of a WETH/cbBTC position are volatile against USD
    ///      with no offsetting leg, so an ordinary decline during settlement reads as rebalance loss
    ///      and reverts an honest rebuild — stranding principal loose and unstaked with only the
    ///      admin exit() as recovery. Storing amounts and pricing them at rebuild time with the SAME
    ///      feed reads that produce `valueAfter` makes the market move cancel on both sides.
    /// @param amount0Pos token0 backing main+alt PRINCIPAL at unwind — the floor's haircut base.
    /// @param amount1Pos token1 backing main+alt PRINCIPAL at unwind.
    /// @param loose0 pre-existing loose token0 — added back un-haircut (H-1).
    /// @param loose1 pre-existing loose token1 — added back un-haircut (H-1).
    struct Snapshot {
        uint256 amount0Pos;
        uint256 amount1Pos;
        uint256 loose0;
        uint256 loose1;
    }

    struct SwapWindow {
        bool inFlight;
        bool wasStaked; // main was staked at unwind; restake at rebuild
        address sellToken; // approved to VAULT_RELAYER while in flight (packs with the bools)
        uint256 amount0Pos; // see Snapshot
        uint256 amount1Pos;
        uint256 loose0;
        uint256 loose1;
        uint256 startedAt; // unwind timestamp (diagnostics / decision snapshot)
    }

    /// @notice Open the window: record the split-value snapshot, approve the relayer for exactly
    ///         `sellAmount` of `sellToken`, flip in-flight. One call — guard, snapshot, approval
    ///         and flag cannot be reordered or partially applied by a call site.
    /// @dev The AlreadyInFlight guard here is a BACKSTOP invariant; the primary fail-fast check
    ///      stays in LPPositionLib.unwindPrecheck, which must reject a duplicate call before the
    ///      calm gate's oracle reads and before _exitAll burns anything.
    /// @dev Caller ordering constraint this module cannot see or enforce: `wasStaked` must be
    ///      captured from p.mainStaked BEFORE the teardown (_exitAll) un-stakes the position.
    function open(SwapWindow storage w, address sellToken, uint256 sellAmount, Snapshot memory snap, bool wasStaked)
        internal
    {
        if (w.inFlight) revert AlreadyInFlight();
        // Guarantees inFlight ⟹ sellToken != 0 by construction (not by caller precheck): the
        // escape hatch's forceApprove(sellToken, 0) must never target address(0) and revert.
        if (sellToken == address(0)) revert InvalidSellToken();
        w.inFlight = true;
        w.wasStaked = wasStaked;
        w.sellToken = sellToken;
        w.amount0Pos = snap.amount0Pos;
        w.amount1Pos = snap.amount1Pos;
        w.loose0 = snap.loose0;
        w.loose1 = snap.loose1;
        w.startedAt = block.timestamp;
        IERC20(sellToken).forceApprove(VAULT_RELAYER, sellAmount);
    }

    /// @notice Success-close (rebuildAfterSwap). Strict: reverts NotInFlight when no window is
    ///         open — a success-close without a window is a caller bug. Revokes the relayer
    ///         approval, returns the snapshot the rebuild needs (floor terms + restake flag),
    ///         and wipes the window, all in one statement: there is no way to read the snapshot
    ///         without also revoking and clearing.
    /// @dev Safe to call at the TOP of rebuildAfterSwap, before mint/floor logic that may still
    ///      revert: reverts are whole-transaction, so a failed rebuild unwinds this close too and
    ///      the window stays open for retry — identical retry semantics to the old late
    ///      _clearInFlight().
    function closeForRebuild(SwapWindow storage w) internal returns (Snapshot memory snap, bool wasStaked) {
        if (!w.inFlight) revert NotInFlight();
        IERC20(w.sellToken).forceApprove(VAULT_RELAYER, 0);
        snap = Snapshot({amount0Pos: w.amount0Pos, amount1Pos: w.amount1Pos, loose0: w.loose0, loose1: w.loose1});
        wasStaked = w.wasStaked;
        _wipe(w);
    }

    /// @notice Escape-close (exit()'s mid-flight branch). Tolerant: a no-op when no window is
    ///         open — the escape hatch must never revert on window state it does not control.
    ///         When open: revoke, clear, discard the snapshot (nothing left to floor-check; the
    ///         caller sweeps all balances regardless).
    /// @dev No sellToken null-guard needed: inFlight ⟹ sellToken != address(0) is enforced by
    ///      open()'s InvalidSellToken revert, so the forceApprove below can never target
    ///      address(0) (the old defensive check in exit() guarded a state this module makes
    ///      unreachable).
    function closeForExit(SwapWindow storage w) internal {
        if (!w.inFlight) return;
        IERC20(w.sellToken).forceApprove(VAULT_RELAYER, 0);
        _wipe(w);
    }

    /// @dev Shared clear tail for both closers. Solidity forbids `delete` on a local storage
    ///      pointer, so the fields are deleted one by one — but only HERE: a future struct field
    ///      is a one-place update.
    function _wipe(SwapWindow storage w) private {
        delete w.inFlight;
        delete w.wasStaked;
        delete w.sellToken;
        delete w.amount0Pos;
        delete w.amount1Pos;
        delete w.loose0;
        delete w.loose1;
        delete w.startedAt;
    }
}
