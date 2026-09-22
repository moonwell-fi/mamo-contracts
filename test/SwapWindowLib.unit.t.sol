// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {MockERC20} from "./MockERC20.sol";
import {SwapWindowLib} from "@libraries/SwapWindowLib.sol";

/// @dev Internal-library wrapper: holds the single window and exposes the three transitions.
contract SwapWindowWrapper {
    using SwapWindowLib for SwapWindowLib.SwapWindow;

    SwapWindowLib.SwapWindow public window;

    function open(address sellToken, uint256 sellAmount, SwapWindowLib.Snapshot memory snap, bool staked) external {
        window.open(sellToken, sellAmount, snap, staked);
    }

    function closeForRebuild() external returns (SwapWindowLib.Snapshot memory, bool) {
        return window.closeForRebuild();
    }

    function closeForExit() external {
        window.closeForExit();
    }
}

/// @notice Standalone suite for the swap-window state machine — the invariants the balancer's
///         paths rely on, provable without the full position-manager mock.
contract SwapWindowLibUnitTest is Test {
    SwapWindowWrapper internal w;
    address internal token;

    function setUp() public {
        w = new SwapWindowWrapper();
        token = address(new MockERC20("Sell", "SEL"));
    }

    /// @dev The baseline is TOKEN AMOUNTS, never a frozen USD figure: the floor is compared in a
    ///      later transaction, so a USD baseline would measure the market's move rather than the
    ///      rebalance's (see SwapWindowLib.Snapshot).
    function _snap(uint256 a0, uint256 a1, uint256 l0, uint256 l1)
        internal
        pure
        returns (SwapWindowLib.Snapshot memory)
    {
        return SwapWindowLib.Snapshot({amount0Pos: a0, amount1Pos: a1, loose0: l0, loose1: l1});
    }

    function _fields()
        internal
        view
        returns (
            bool inFlight,
            bool wasStaked,
            address sellToken,
            uint256 amount0Pos,
            uint256 amount1Pos,
            uint256 loose0,
            uint256 loose1,
            uint256 startedAt
        )
    {
        return w.window();
    }

    /// @dev open() records the split amount snapshot, stamps startedAt, flips the flag, and
    ///      approves the relayer for exactly sellAmount.
    function test_open_recordsAndApproves() public {
        w.open(token, 5e17, _snap(111, 222, 22, 33), true);

        (
            bool inFlight,
            bool wasStaked,
            address sellToken,
            uint256 a0,
            uint256 a1,
            uint256 l0,
            uint256 l1,
            uint256 startedAt
        ) = _fields();
        assertTrue(inFlight);
        assertTrue(wasStaked);
        assertEq(sellToken, token);
        assertEq(a0, 111);
        assertEq(a1, 222);
        assertEq(l0, 22);
        assertEq(l1, 33);
        assertEq(startedAt, block.timestamp);
        assertEq(MockERC20(token).allowance(address(w), SwapWindowLib.VAULT_RELAYER), 5e17);
    }

    /// @dev The by-construction guard the escape hatch depends on: a zero sellToken can never
    ///      enter the window, so closeForExit's forceApprove(sellToken, 0) can never target
    ///      address(0) and revert.
    function test_open_revertsZeroSellToken() public {
        vm.expectRevert(SwapWindowLib.InvalidSellToken.selector);
        w.open(address(0), 5e17, _snap(111, 222, 22, 33), false);
    }

    function test_open_revertsWhenAlreadyInFlight() public {
        w.open(token, 5e17, _snap(111, 222, 22, 33), false);
        vm.expectRevert(SwapWindowLib.AlreadyInFlight.selector);
        w.open(token, 1, _snap(1, 1, 1, 1), false);
    }

    /// @dev Success-close returns the snapshot, revokes the approval, and fully clears — a stale
    ///      snapshot cannot outlive its window, and reopening is immediately legal.
    function test_closeForRebuild_returnsRevokesAndWipes() public {
        w.open(token, 5e17, _snap(111, 222, 22, 33), true);
        (SwapWindowLib.Snapshot memory snap, bool wasStaked) = w.closeForRebuild();
        assertEq(snap.amount0Pos, 111);
        assertEq(snap.amount1Pos, 222);
        assertEq(snap.loose0, 22);
        assertEq(snap.loose1, 33);
        assertTrue(wasStaked);
        assertEq(MockERC20(token).allowance(address(w), SwapWindowLib.VAULT_RELAYER), 0);

        (bool inFlight, bool staked, address sellToken, uint256 a0, uint256 a1, uint256 l0, uint256 l1, uint256 s) =
            _fields();
        assertFalse(inFlight);
        assertFalse(staked);
        assertEq(sellToken, address(0));
        assertEq(a0 + a1 + l0 + l1 + s, 0, "every field wiped");

        w.open(token, 1, _snap(1, 1, 1, 1), false); // window reusable after close
    }

    function test_closeForRebuild_revertsNotInFlight() public {
        vm.expectRevert(SwapWindowLib.NotInFlight.selector);
        w.closeForRebuild();
    }

    /// @dev The escape-close is a no-op with no window (exit() must never revert on window state)
    ///      and revokes + wipes when one is open.
    function test_closeForExit_noopWhenClosed_revokesWhenOpen() public {
        w.closeForExit(); // no window: must not revert

        w.open(token, 5e17, _snap(111, 222, 22, 33), false);
        w.closeForExit();
        (bool inFlight,,,,,,,) = _fields();
        assertFalse(inFlight);
        assertEq(MockERC20(token).allowance(address(w), SwapWindowLib.VAULT_RELAYER), 0);
    }
}
