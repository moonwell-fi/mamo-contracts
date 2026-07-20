// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {MockERC20} from "./MockERC20.sol";
import {SwapWindowLib} from "@libraries/SwapWindowLib.sol";

/// @dev Internal-library wrapper: holds the single window and exposes the three transitions.
contract SwapWindowWrapper {
    using SwapWindowLib for SwapWindowLib.SwapWindow;

    SwapWindowLib.SwapWindow public window;

    function open(address sellToken, uint256 sellAmount, uint256 posV, uint256 looseV, bool staked) external {
        window.open(sellToken, sellAmount, posV, looseV, staked);
    }

    function closeForRebuild() external returns (uint256, uint256, bool) {
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

    function _fields()
        internal
        view
        returns (bool inFlight, bool wasStaked, address sellToken, uint256 posV, uint256 looseV, uint256 startedAt)
    {
        return w.window();
    }

    /// @dev open() records the split snapshot, stamps startedAt, flips the flag, and approves the
    ///      relayer for exactly sellAmount.
    function test_open_recordsAndApproves() public {
        w.open(token, 5e17, 111, 22, true);

        (bool inFlight, bool wasStaked, address sellToken, uint256 posV, uint256 looseV, uint256 startedAt) = _fields();
        assertTrue(inFlight);
        assertTrue(wasStaked);
        assertEq(sellToken, token);
        assertEq(posV, 111);
        assertEq(looseV, 22);
        assertEq(startedAt, block.timestamp);
        assertEq(MockERC20(token).allowance(address(w), SwapWindowLib.VAULT_RELAYER), 5e17);
    }

    /// @dev The by-construction guard the escape hatch depends on: a zero sellToken can never
    ///      enter the window, so closeForExit's forceApprove(sellToken, 0) can never target
    ///      address(0) and revert.
    function test_open_revertsZeroSellToken() public {
        vm.expectRevert(SwapWindowLib.InvalidSellToken.selector);
        w.open(address(0), 5e17, 111, 22, false);
    }

    function test_open_revertsWhenAlreadyInFlight() public {
        w.open(token, 5e17, 111, 22, false);
        vm.expectRevert(SwapWindowLib.AlreadyInFlight.selector);
        w.open(token, 1, 1, 1, false);
    }

    /// @dev Success-close returns the snapshot, revokes the approval, and fully clears — a stale
    ///      snapshot cannot outlive its window, and reopening is immediately legal.
    function test_closeForRebuild_returnsRevokesAndWipes() public {
        w.open(token, 5e17, 111, 22, true);
        (uint256 posV, uint256 looseV, bool wasStaked) = w.closeForRebuild();
        assertEq(posV, 111);
        assertEq(looseV, 22);
        assertTrue(wasStaked);
        assertEq(MockERC20(token).allowance(address(w), SwapWindowLib.VAULT_RELAYER), 0);

        (bool inFlight, bool staked, address sellToken, uint256 p, uint256 l, uint256 s) = _fields();
        assertFalse(inFlight);
        assertFalse(staked);
        assertEq(sellToken, address(0));
        assertEq(p + l + s, 0);

        w.open(token, 1, 1, 1, false); // window reusable after close
    }

    function test_closeForRebuild_revertsNotInFlight() public {
        vm.expectRevert(SwapWindowLib.NotInFlight.selector);
        w.closeForRebuild();
    }

    /// @dev The escape-close is a no-op with no window (exit() must never revert on window state)
    ///      and revokes + wipes when one is open.
    function test_closeForExit_noopWhenClosed_revokesWhenOpen() public {
        w.closeForExit(); // no window: must not revert

        w.open(token, 5e17, 111, 22, false);
        w.closeForExit();
        (bool inFlight,,,,,) = _fields();
        assertFalse(inFlight);
        assertEq(MockERC20(token).allowance(address(w), SwapWindowLib.VAULT_RELAYER), 0);
    }
}
