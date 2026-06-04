// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {MockERC20} from "./MockERC20.sol";
import {LPAutoBalancerHarness} from "./harness/LPAutoBalancerHarness.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockQuoter} from "./mocks/MockQuoter.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

/// @notice Unit tests for LPAutoBalancer._executeSwap (Task 12 — dual-layer quoter+slippage guard).
contract LPAutoBalancerSwapTest is Test {
    LPAutoBalancerHarness harness;
    MockPositionManager mockPM;
    MockQuoter mockQuoter;
    MockSwapRouter mockRouter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address admin = makeAddr("admin");
    address aero = makeAddr("aero");

    int24 constant TICK_SPACING = 100;

    function setUp() public {
        mockPM = new MockPositionManager(address(0));
        mockQuoter = new MockQuoter();
        mockRouter = new MockSwapRouter();
        tokenIn = new MockERC20("TokenIn", "TIN");
        tokenOut = new MockERC20("TokenOut", "TOUT");

        harness = new LPAutoBalancerHarness(
            admin,
            address(0), // manager (optional)
            address(0), // rebalancer (optional)
            address(0), // guardian (optional)
            address(mockPM),
            address(mockRouter),
            address(mockQuoter),
            aero
        );

        // Give the harness tokenIn balance so forceApprove has something to approve
        tokenIn.mint(address(harness), 10_000 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Happy-path: correct amountOutMinimum passed to router
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice quoter returns 1000, slippage=100bps (1%) → quoterMin=990.
    ///         callerMinOut=0 → effective min = max(990, 0) = 990.
    ///         Router must receive amountOutMinimum == 990.
    function test_executeSwap_usesQuoterFloorWhenCallerMinZero() public {
        mockQuoter.setQuotedOut(1000);
        mockRouter.setAmountOutToReturn(990); // meets the floor exactly

        harness.executeSwap(
            address(tokenIn),
            address(tokenOut),
            500, // amountIn
            TICK_SPACING,
            0, // callerMinOut = 0
            100 // maxSlippageBps = 1%
        );

        assertEq(mockRouter.lastAmountOutMinimum(), 990, "router should get quoter floor 990");
    }

    /// @notice quotedOut=1000, slippage=100bps → quoterMin=990; callerMinOut=995 > 990
    ///         → effective min = max(990, 995) = 995.
    function test_executeSwap_usesCallerMinWhenHigher() public {
        mockQuoter.setQuotedOut(1000);
        mockRouter.setAmountOutToReturn(995); // meets caller min exactly

        harness.executeSwap(
            address(tokenIn),
            address(tokenOut),
            500,
            TICK_SPACING,
            995, // callerMinOut higher than quoterMin
            100
        );

        assertEq(mockRouter.lastAmountOutMinimum(), 995, "router should get caller min 995");
    }

    /// @notice callerMinOut=500 < quoterMin=990 → router should get 990 (quoter floor wins).
    function test_executeSwap_quoterFloorWhenCallerLower() public {
        mockQuoter.setQuotedOut(1000);
        mockRouter.setAmountOutToReturn(990);

        harness.executeSwap(
            address(tokenIn),
            address(tokenOut),
            500,
            TICK_SPACING,
            500, // callerMinOut lower than quoterMin
            100
        );

        assertEq(mockRouter.lastAmountOutMinimum(), 990, "quoter floor should win over lower callerMin");
    }

    /// @notice Verify router is actually called and amountOut returned matches mock.
    function test_executeSwap_returnsRouterAmountOut() public {
        mockQuoter.setQuotedOut(1000);
        mockRouter.setAmountOutToReturn(995);

        uint256 out = harness.executeSwap(address(tokenIn), address(tokenOut), 500, TICK_SPACING, 0, 100);

        assertTrue(mockRouter.wasCalled(), "router must be called");
        assertEq(out, 995);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Revert cases
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice quoter returns 0 → must revert "Invalid quote".
    function test_executeSwap_revertInvalidQuote() public {
        mockQuoter.setQuotedOut(0);
        mockRouter.setAmountOutToReturn(0);

        vm.expectRevert(bytes("Invalid quote"));
        harness.executeSwap(address(tokenIn), address(tokenOut), 500, TICK_SPACING, 0, 100);
    }

    /// @notice Router returns amountOut BELOW minOut → must revert "Received less than min amount".
    ///         quotedOut=1000, slippage=100bps → quoterMin=990; router returns 980 < 990.
    function test_executeSwap_revertReceivedLessThanMin() public {
        mockQuoter.setQuotedOut(1000);
        mockRouter.setAmountOutToReturn(980); // below floor of 990

        vm.expectRevert(bytes("Received less than min amount"));
        harness.executeSwap(address(tokenIn), address(tokenOut), 500, TICK_SPACING, 0, 100);
    }

    /// @notice quotedOut=1, maxSlippageBps=100 → quoterMin = 1*9900/10000 = 0 → SlippageTooHigh.
    function test_executeSwap_revertSlippageTooHigh() public {
        mockQuoter.setQuotedOut(1);
        mockRouter.setAmountOutToReturn(0);

        vm.expectRevert(LPAutoBalancer.SlippageTooHigh.selector);
        harness.executeSwap(
            address(tokenIn),
            address(tokenOut),
            500,
            TICK_SPACING,
            0,
            100 // 1% slippage on quotedOut=1 → floor rounds to 0
        );
    }
}
