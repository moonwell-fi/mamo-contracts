// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {GPv2Order} from "@libraries/GPv2Order.sol";

/// @title GPv2OrderChecks
/// @notice The order-class-agnostic CowSwap/GPv2 sell-order validation skeleton shared by every
///         EIP-1271 signer in this repo (LPCompoundModule's compound + rebalance paths and
///         MamoMultiMarketStrategy's reward path). One implementation of the settlement-critical
///         mechanics; each signer stays an adapter supplying only its order-class constraints.
///         INTERNAL on purpose: the checks inline into each caller (no linking/deploy surface) —
///         the point is source-level dedup so a hardening lands in every path by construction,
///         not bytecode sharing.
library GPv2OrderChecks {
    using GPv2Order for GPv2Order.Data;

    /// @notice The three order-binding hashes `validate` pins, grouped so every call site
    ///         constructs them with named fields — a transposed `bytes32` argument is a compile
    ///         error, not a silent mis-binding.
    struct Binding {
        bytes32 orderDigest; // EIP-712 signing digest the order must hash to
        bytes32 domainSeparator; // GPv2 settlement domain separator
        bytes32 expectedAppData; // pinned appData hash
    }

    /// @notice Shared GPv2 sell-order mechanics: digest binding, SELL kind, fill-or-kill, ERC20
    ///         balance flags, receiver pin, zero fee, appData pin, the
    ///         [now+5min, now+maxTimePriceValid(sellToken)] expiry window, and the Chainlink-backed
    ///         price check at `slippageBps`.
    /// @dev Order-CLASS constraints (which tokens may be sold/bought, in-flight gates, direction
    ///      pins) stay in the callers — run them BEFORE this call so a wrong-token order reverts
    ///      with its specific class error instead of a confusing checker revert from inside
    ///      checkPrice (an unconfigured pair reverts there).
    /// @dev Revert strings are the repo-canonical short set, kept stable so the pre-existing
    ///      suites keep matching. The backend decodes errors by custom-error SELECTOR (its spec
    ///      §2.4 tables LPAutoBalancerV2 selectors); it does not match on these require-strings.
    function validate(
        GPv2Order.Data memory o,
        Binding memory b,
        address receiver,
        ISlippagePriceChecker checker,
        uint256 slippageBps
    ) internal view {
        require(o.hash(b.domainSeparator) == b.orderDigest, "bad digest");
        require(o.kind == GPv2Order.KIND_SELL, "must be sell");
        require(!o.partiallyFillable, "must be fill-or-kill");
        require(o.sellTokenBalance == GPv2Order.BALANCE_ERC20, "sell must be erc20");
        require(o.buyTokenBalance == GPv2Order.BALANCE_ERC20, "buy must be erc20");
        require(o.receiver == receiver, "bad receiver");
        require(o.feeAmount == 0, "fee must be zero");
        // Expiry window BEFORE the appData pin: appData can be expensive for callers to compute
        // (the strategy builds a hook JSON), and pre-existing suites construct expiry-violation
        // orders with placeholder appData — window first keeps each check independently testable.
        require(o.validTo >= block.timestamp + 5 minutes, "expires too soon");
        require(o.validTo <= block.timestamp + checker.maxTimePriceValid(address(o.sellToken)), "expires too far");
        require(o.appData == b.expectedAppData, "bad appData");
        require(
            checker.checkPrice(o.sellAmount, address(o.sellToken), address(o.buyToken), o.buyAmount, slippageBps),
            "price check failed"
        );
    }
}
