// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockConfigurableSwapRouter
 * @notice A swap router that can be made to behave in the specific ways the real Aerodrome router
 *         cannot, so that MamoStakingStrategy.compound()'s own guards become observable.
 * @dev The real router makes three of compound()'s properties untestable, because it happens to be
 *      well behaved:
 *        - it pulls EXACTLY amountIn, so the trailing `forceApprove(dexRouter, 0)` is a no-op and a
 *          test asserting "allowance is zero afterwards" passes with or without it;
 *        - its return value equals the balance delta it produced, so a test cannot tell the emitted
 *          `actualAmountOut` from the measured `received`;
 *        - it never records the deadline it was handed, so a compound() that ignores the caller's
 *          deadline and substitutes `block.timestamp + 300` is indistinguishable from one that
 *          forwards it.
 *      This router records what it was called with and lets each of those behaviours be dialled in.
 *      It must be funded with `tokenOut` up front (`deal`), and it only implements
 *      `exactInputSingle`; every other ISwapRouter entry point reverts.
 */
contract MockConfigurableSwapRouter is ISwapRouter {
    /// @notice Basis points of `amountIn` actually pulled from the caller (10_000 = all of it)
    uint256 public pullBps = 10_000;

    /// @notice Extra `tokenOut` delivered on top of `amountOutMinimum`
    uint256 public deliverExtra;

    /// @notice Amount ADDED to the return value beyond what was really delivered
    uint256 public overReportBy;

    /// @notice The deadline field of the last `exactInputSingle` call
    uint256 public lastDeadline;

    /// @notice The amountIn field of the last `exactInputSingle` call
    uint256 public lastAmountIn;

    /// @notice The amountOutMinimum field of the last `exactInputSingle` call
    uint256 public lastAmountOutMinimum;

    /// @notice How much `tokenIn` was actually pulled on the last call
    uint256 public lastPulled;

    /// @notice How much `tokenOut` was actually delivered on the last call
    uint256 public lastDelivered;

    /// @notice The value the last call returned to its caller
    uint256 public lastReported;

    /// @notice Number of `exactInputSingle` calls served
    uint256 public callCount;

    function setPullBps(uint256 bps) external {
        require(bps <= 10_000, "pullBps > 100%");
        pullBps = bps;
    }

    function setDeliverExtra(uint256 amount) external {
        deliverExtra = amount;
    }

    function setOverReportBy(uint256 amount) external {
        overReportBy = amount;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        lastDeadline = params.deadline;
        lastAmountIn = params.amountIn;
        lastAmountOutMinimum = params.amountOutMinimum;
        callCount++;

        // A real router would refuse a stale deadline; keep that behaviour so a caller that forwards
        // a genuinely expired deadline fails here rather than silently succeeding.
        require(block.timestamp <= params.deadline, "Transaction too old");

        uint256 pull = (params.amountIn * pullBps) / 10_000;
        if (pull > 0) {
            IERC20(params.tokenIn).transferFrom(msg.sender, address(this), pull);
        }
        lastPulled = pull;

        uint256 deliver = params.amountOutMinimum + deliverExtra;
        if (deliver > 0) {
            IERC20(params.tokenOut).transfer(params.recipient, deliver);
        }
        lastDelivered = deliver;

        amountOut = deliver + overReportBy;
        lastReported = amountOut;
    }

    function exactInput(ExactInputParams calldata) external payable override returns (uint256) {
        revert("not implemented");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable override returns (uint256) {
        revert("not implemented");
    }

    function exactOutput(ExactOutputParams calldata) external payable override returns (uint256) {
        revert("not implemented");
    }
}
