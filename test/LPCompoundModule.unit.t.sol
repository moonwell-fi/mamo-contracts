// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {GPv2Order} from "@libraries/GPv2Order.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockSlippagePriceChecker} from "./mocks/MockSlippagePriceChecker.sol";

/// @notice Minimal balancer stub exposing the token0()/token1() the module reads live.
contract StubBalancer {
    address public token0;
    address public token1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function setTokens(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    bool public rebalanceInFlight;

    function setInFlight(bool v) external {
        rebalanceInFlight = v;
    }

    address public sellTokenInFlight;

    function setSellTokenInFlight(address t) external {
        sellTokenInFlight = t;
    }
}

contract LPCompoundModuleUnitTest is Test {
    using GPv2Order for GPv2Order.Data;

    LPCompoundModule module;
    StubBalancer bal;
    MockSlippagePriceChecker spc;

    address admin = address(0xA11CE);
    address aero;
    address token0;
    address token1;

    bytes4 constant MAGIC = 0x1626ba7e;
    bytes32 appData = keccak256("mamo-lpv2-compound");

    function setUp() public {
        aero = address(new MockERC20("Aerodrome", "AERO"));
        token0 = address(new MockERC20("Wrapped Ether", "WETH"));
        token1 = address(new MockERC20("Coinbase BTC", "cbBTC"));

        bal = new StubBalancer(token0, token1);
        module = new LPCompoundModule(address(bal), aero, admin);
        spc = new MockSlippagePriceChecker();
        spc.setRewardToken(aero, true);

        vm.startPrank(admin);
        module.setSlippagePriceChecker(address(spc));
        module.setSlippage(100);
        module.setCompoundAppData(appData);
        module.approveCowSwap();
        vm.stopPrank();
    }

    function _order(address sell, address buy, address receiver, uint32 validTo)
        internal
        view
        returns (GPv2Order.Data memory o)
    {
        o = GPv2Order.Data({
            sellToken: IERC20(sell),
            buyToken: IERC20(buy),
            receiver: receiver,
            sellAmount: 1e18,
            buyAmount: 1e18,
            validTo: validTo,
            appData: appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _sig(GPv2Order.Data memory o) internal view returns (bytes32 digest, bytes memory enc) {
        digest = o.hash(module.DOMAIN_SEPARATOR());
        enc = abi.encode(o);
    }

    // --- constructor guards ---

    function test_constructor_revertsZeroBalancer() public {
        vm.expectRevert(LPCompoundModule.ZeroAddress.selector);
        new LPCompoundModule(address(0), aero, admin);
    }

    function test_constructor_revertsZeroAero() public {
        vm.expectRevert(LPCompoundModule.ZeroAddress.selector);
        new LPCompoundModule(address(bal), address(0), admin);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert(LPCompoundModule.ZeroAddress.selector);
        new LPCompoundModule(address(bal), aero, address(0));
    }

    function test_immutables() public view {
        assertEq(module.balancer(), address(bal));
        assertEq(module.AERO(), aero);
        assertTrue(module.hasRole(module.DEFAULT_ADMIN_ROLE(), admin));
    }

    // --- isValidSignature happy paths ---

    function test_isValidSignature_validAeroToToken0() public view {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        assertEq(module.isValidSignature(d, e), MAGIC);
    }

    function test_isValidSignature_validAeroToToken1() public view {
        GPv2Order.Data memory o = _order(aero, token1, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        assertEq(module.isValidSignature(d, e), MAGIC);
    }

    // --- MOO-730(b): compound settlement must not overlap a swap rebalance ---

    /// @dev The swap-rebalance value floor compares a snapshot taken at unwindForSwap against a
    ///      valueAfter measured at rebuildAfterSwap. Compound proceeds settle to the BALANCER
    ///      (receiver == balancer), so an AERO order filling inside that window inflates valueAfter
    ///      without inflating either snapshot term — free headroom that a real rebalance loss can
    ///      hide behind. validateRebalanceOrder already REQUIRES rebalanceInFlight; this asserts the
    ///      complementary exclusion on the compound class, so exactly one of the two can settle at
    ///      any time.
    function test_isValidSignature_rejectedWhileRebalanceInFlight() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);

        // Control: identical order settles fine outside the window.
        assertEq(module.isValidSignature(d, e), MAGIC, "valid outside the window");

        bal.setInFlight(true);
        vm.expectRevert(bytes("rebalance in flight"));
        module.isValidSignature(d, e);

        // Window closes → the same order is valid again (deferral, not permanent rejection).
        bal.setInFlight(false);
        assertEq(module.isValidSignature(d, e), MAGIC, "valid again once the window closes");
    }

    /// @dev The two order classes are mutually exclusive by construction: exactly one of them
    ///      validates for any given value of rebalanceInFlight.
    function test_orderClasses_areMutuallyExclusiveOnInFlight() public {
        GPv2Order.Data memory compoundOrder = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 cd, bytes memory ce) = _sig(compoundOrder);

        bal.setSellTokenInFlight(token0);
        spc.setMaxTimePriceValid(token0, 1 hours);
        spc.setMaxTimePriceValid(token1, 1 hours);
        // Pricing is not the subject here: price strictly above oracle so both knobs clear.
        spc.setOracleDiscountBps(-1);
        GPv2Order.Data memory rebalanceOrder =
            _order(token0, token1, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 rd, bytes memory re) = _sig(rebalanceOrder);

        // Not in flight: compound validates, rebalance does not.
        assertEq(module.isValidSignature(cd, ce), MAGIC);
        vm.expectRevert(bytes("no rebalance in flight"));
        module.validateRebalanceOrder(rd, re);

        // In flight: exactly the reverse.
        bal.setInFlight(true);
        vm.expectRevert(bytes("rebalance in flight"));
        module.isValidSignature(cd, ce);
        assertEq(module.validateRebalanceOrder(rd, re), MAGIC);
    }

    function test_isValidSignature_survivesSetPool() public {
        address newT0 = address(new MockERC20("New0", "N0"));
        address newT1 = address(new MockERC20("New1", "N1"));
        bal.setTokens(newT0, newT1);

        GPv2Order.Data memory o = _order(aero, newT0, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        assertEq(module.isValidSignature(d, e), MAGIC);

        // old token0 is no longer underlying
        GPv2Order.Data memory old = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 od, bytes memory oe) = _sig(old);
        vm.expectRevert(bytes("buyToken must be underlying"));
        module.isValidSignature(od, oe);
    }

    // --- isValidSignature reverts ---

    function test_isValidSignature_revertsBadDigest() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        (, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("bad digest"));
        module.isValidSignature(bytes32(uint256(1)), e);
    }

    function test_isValidSignature_revertsWrongSellToken() public {
        GPv2Order.Data memory o = _order(token0, token1, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("sellToken must be AERO"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsBuyTokenNotUnderlying() public {
        GPv2Order.Data memory o = _order(aero, address(0xBEEF), address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("buyToken must be underlying"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsReceiverNotBalancer() public {
        GPv2Order.Data memory o = _order(aero, token0, address(0xCAFE), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("bad receiver"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsFeeNonZero() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        o.feeAmount = 1;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("fee must be zero"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsBadAppData() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        o.appData = keccak256("wrong");
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("bad appData"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsExpiresTooSoon() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 1 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("expires too soon"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsExpiresTooFar() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 1 hours));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("expires too far"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsCheckPriceFails() public {
        spc.setPriceOk(false);
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("price check failed"));
        module.isValidSignature(d, e);
    }

    // --- setters / access control ---

    function test_setSlippage_bounds() public {
        vm.prank(admin);
        vm.expectRevert(bytes("slippage too high"));
        module.setSlippage(2501);
    }

    function test_setSlippage_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        module.setSlippage(100);
    }

    function test_setSlippagePriceChecker_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(LPCompoundModule.ZeroAddress.selector);
        module.setSlippagePriceChecker(address(0));
    }

    function test_approveCowSwap_setsAllowance() public view {
        assertEq(IERC20(aero).allowance(address(module), module.VAULT_RELAYER()), type(uint256).max);
    }

    function test_approveCowSwap_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        module.approveCowSwap();
    }

    // ---------- recoverERC20 ----------

    /// @notice AERO forwarded by compound() can only leave via a settled order; if the checker or
    ///         appData config goes bad, recoverERC20 is the admin escape hatch (mirrors the
    ///         balancer's own recoverERC20 — the module never custodies swap proceeds).
    function test_recoverERC20_sweepsStrandedToken() public {
        MockERC20(aero).mint(address(module), 5e18);
        vm.expectEmit(true, true, true, true);
        emit LPCompoundModule.TokensRecovered(aero, admin, 5e18);
        vm.prank(admin);
        module.recoverERC20(aero, admin, 5e18);
        assertEq(IERC20(aero).balanceOf(admin), 5e18);
        assertEq(IERC20(aero).balanceOf(address(module)), 0);
    }

    function test_recoverERC20_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LPCompoundModule.ZeroAddress.selector);
        module.recoverERC20(aero, address(0), 1);
    }

    function test_recoverERC20_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        module.recoverERC20(aero, admin, 1);
    }

    // ---------- validateRebalanceOrder ----------

    function _rebalanceOrder(address sell, address buy) internal view returns (GPv2Order.Data memory) {
        return _order(sell, buy, address(bal), uint32(block.timestamp + 10 minutes));
    }

    function test_validateRebalanceOrder_validBothDirections_whileInFlight() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);
        spc.setMaxTimePriceValid(token1, 1 hours);
        // Direction test, not a pricing test: price the order strictly above oracle so it clears
        // the default 0-bps knob (checkPrice is strict — an at-oracle order fails at 0 bps).
        spc.setOracleDiscountBps(-1);

        bal.setSellTokenInFlight(token0);
        GPv2Order.Data memory o01 = _rebalanceOrder(token0, token1);
        (bytes32 d01, bytes memory e01) = _sig(o01);
        assertEq(module.validateRebalanceOrder(d01, e01), bytes4(0x1626ba7e));

        bal.setSellTokenInFlight(token1);
        GPv2Order.Data memory o10 = _rebalanceOrder(token1, token0);
        (bytes32 d10, bytes memory e10) = _sig(o10);
        assertEq(module.validateRebalanceOrder(d10, e10), bytes4(0x1626ba7e));
    }

    function test_validateRebalanceOrder_revertsOutsideWindow() public {
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("no rebalance in flight");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsSameToken() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token0);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("tokens must be distinct underlying");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsAeroAsLeg() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(aero);
        spc.setMaxTimePriceValid(aero, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(aero, token1);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("tokens must be distinct underlying");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsWrongReceiver() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _order(token0, token1, makeAddr("attacker"), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("bad receiver");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsBadPrice() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0);
        spc.setPriceOk(false);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("price check failed");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsExpiresTooSoon() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _order(token0, token1, address(bal), uint32(block.timestamp + 1 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("expires too soon");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsExpiresTooFar() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0);
        spc.setMaxTimePriceValid(token0, 6 minutes);
        GPv2Order.Data memory o = _order(token0, token1, address(bal), uint32(block.timestamp + 30 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("expires too far");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsBadDigest() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (, bytes memory e) = _sig(o);
        vm.expectRevert("bad digest");
        module.validateRebalanceOrder(bytes32(uint256(1)), e);
    }

    // ---------- rebalanceSlippageBps (dedicated principal-order knob) ----------

    function test_setRebalanceSlippageBps_adminSetsAndEmits() public {
        vm.prank(admin);
        vm.expectEmit(address(module));
        emit LPCompoundModule.RebalanceSlippageUpdated(0, 50);
        module.setRebalanceSlippageBps(50);
        assertEq(module.rebalanceSlippageBps(), 50);
    }

    function test_setRebalanceSlippageBps_revertsAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(bytes("slippage too high"));
        module.setRebalanceSlippageBps(2501);
    }

    function test_setRebalanceSlippageBps_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        module.setRebalanceSlippageBps(50);
    }

    /// @notice The discriminating test: an order priced 150 bps below oracle. The compound knob
    ///         is 100 (setUp), so if validateRebalanceOrder used allowedSlippageInBps it would
    ///         fail regardless — it passes with rebalanceSlippageBps = 200 and fails at 50,
    ///         proving the principal path reads the dedicated knob.
    function test_validateRebalanceOrder_usesRebalanceKnob_notCompoundKnob() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0); // base 8fbfaea: order sellToken must match in-flight approval
        spc.setMaxTimePriceValid(token0, 1 hours);
        spc.setOracleDiscountBps(150);

        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (bytes32 d, bytes memory e) = _sig(o);

        vm.prank(admin);
        module.setRebalanceSlippageBps(200);
        assertEq(module.validateRebalanceOrder(d, e), MAGIC);

        vm.prank(admin);
        module.setRebalanceSlippageBps(50);
        vm.expectRevert(bytes("price check failed"));
        module.validateRebalanceOrder(d, e);
    }

    /// @notice Default (never set) is 0: any at-or-below-oracle pricing fails the check, so
    ///         rebalance orders cannot settle until the admin explicitly sets the knob —
    ///         safe-strict. Only an order priced strictly ABOVE oracle validates at 0 bps (the
    ///         window is not bricked); an exactly-at-oracle order is rejected, mirroring the real
    ///         checker's strict `>` boundary.
    function test_validateRebalanceOrder_defaultZeroRejectsBelowOracle() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0); // base 8fbfaea: order sellToken must match in-flight approval
        spc.setMaxTimePriceValid(token0, 1 hours);

        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (bytes32 d, bytes memory e) = _sig(o);

        spc.setOracleDiscountBps(1); // priced even 1 bp below oracle
        vm.expectRevert(bytes("price check failed"));
        module.validateRebalanceOrder(d, e);

        spc.setOracleDiscountBps(0); // priced exactly AT oracle — strict boundary still rejects
        vm.expectRevert(bytes("price check failed"));
        module.validateRebalanceOrder(d, e);

        spc.setOracleDiscountBps(-1); // priced strictly above oracle
        assertEq(module.validateRebalanceOrder(d, e), MAGIC);
    }

    /// @notice Regression: the compound path stays governed by allowedSlippageInBps (100 in
    ///         setUp) and is indifferent to the rebalance knob.
    function test_isValidSignature_compoundUnaffectedByRebalanceKnob() public {
        vm.prank(admin);
        module.setRebalanceSlippageBps(50);

        spc.setOracleDiscountBps(99); // just under the compound allowance (strict >), above the rebalance knob
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        assertEq(module.isValidSignature(d, e), MAGIC);

        spc.setOracleDiscountBps(100); // exactly AT the compound allowance — strict > rejects
        vm.expectRevert(bytes("price check failed"));
        module.isValidSignature(d, e);
    }

    function test_validateRebalanceOrder_revertsWrongSellToken() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0); // unwindForSwap approved token0 for this cycle
        spc.setMaxTimePriceValid(token1, 1 hours);
        // solver signs an order selling token1 instead -- must be rejected even though token1 IS
        // a valid underlying and the order is otherwise well-formed.
        GPv2Order.Data memory o = _rebalanceOrder(token1, token0);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("sellToken must match in-flight approval");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_validWhenSellTokenMatches() public {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0);
        spc.setMaxTimePriceValid(token0, 1 hours);
        // sellToken-binding test, not a pricing test: price strictly above oracle to clear the
        // default 0-bps knob (strict checkPrice rejects at-oracle at 0 bps).
        spc.setOracleDiscountBps(-1);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (bytes32 d, bytes memory e) = _sig(o);
        assertEq(module.validateRebalanceOrder(d, e), bytes4(0x1626ba7e));
    }

    // ---------- class disjointness (cross-contract invariant, documented) ----------

    /// @notice The compound class (sellToken == AERO) and the rebalance class (sellToken in
    ///         {token0, token1}) are structurally disjoint ONLY because LPAutoBalancerV2's
    ///         _validateAndStore refuses AERO as a pair token at registration. This test documents
    ///         that dependency: against a hypothetical balancer reporting AERO as token0 — a state
    ///         the real balancer makes unreachable — ONE order (AERO -> token1) satisfies BOTH
    ///         classes. The module imports its safety from the balancer's invariant; if that guard
    ///         is ever weakened, this is the failure shape to expect. DOCUMENTS the dependency —
    ///         it does not enforce the balancer's AERO-exclusion guard (that stays pinned in the
    ///         balancer's own suite).
    function test_documents_classDisjointness_dependsOnBalancerAeroExclusion() public {
        bal.setTokens(aero, token1); // unreachable on the real balancer (InvalidConfig at registration)
        bal.setInFlight(true);
        bal.setSellTokenInFlight(aero);
        spc.setMaxTimePriceValid(aero, 1 hours);
        spc.setOracleDiscountBps(-1); // pricing is not the subject here

        GPv2Order.Data memory o = _rebalanceOrder(aero, token1);
        (bytes32 d, bytes memory e) = _sig(o);

        // In flight, the rebalance class accepts the AERO leg — and the compound class is now
        // excluded, so the two never accept the SAME order at the SAME time even in this
        // impossible configuration.
        assertEq(module.validateRebalanceOrder(d, e), MAGIC, "rebalance class accepts the AERO leg");
        vm.expectRevert(bytes("rebalance in flight"));
        module.isValidSignature(d, e);

        // Out of flight the roles swap: the compound class accepts the very same order, the
        // rebalance class refuses it. The classes are now disjoint IN TIME as well as in shape —
        // but they still overlap in SHAPE, which is why the balancer's AERO-exclusion at
        // registration (_validateAndStore's InvalidConfig guard) remains load-bearing: without it
        // the same signed order would be replayable across the two windows.
        bal.setInFlight(false);
        assertEq(module.isValidSignature(d, e), MAGIC, "compound class accepts the SAME order out of flight");
        vm.expectRevert(bytes("no rebalance in flight"));
        module.validateRebalanceOrder(d, e);
    }

    // ---------- structural order-shape rejections (both validation paths) ----------
    // The classic CowSwap surface checks: a BUY-kind, partially-fillable, or Balancer-vault
    // internal/external-balance order changes settlement semantics on the whole approved
    // amount, so each shape must be rejected in BOTH validation paths.

    /// @dev Arm the in-flight window so validateRebalanceOrder reaches the structural checks.
    function _armRebalanceWindow() internal {
        bal.setInFlight(true);
        bal.setSellTokenInFlight(token0);
        spc.setMaxTimePriceValid(token0, 1 hours);
    }

    function test_isValidSignature_revertsBuyKind() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        o.kind = GPv2Order.KIND_BUY;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("must be sell"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsPartiallyFillable() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        o.partiallyFillable = true;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("must be fill-or-kill"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsSellBalanceNotErc20() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        o.sellTokenBalance = GPv2Order.BALANCE_EXTERNAL;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("sell must be erc20"));
        module.isValidSignature(d, e);
    }

    function test_isValidSignature_revertsBuyBalanceNotErc20() public {
        GPv2Order.Data memory o = _order(aero, token0, address(bal), uint32(block.timestamp + 10 minutes));
        o.buyTokenBalance = GPv2Order.BALANCE_INTERNAL;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("buy must be erc20"));
        module.isValidSignature(d, e);
    }

    function test_validateRebalanceOrder_revertsBuyKind() public {
        _armRebalanceWindow();
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        o.kind = GPv2Order.KIND_BUY;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("must be sell"));
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsPartiallyFillable() public {
        _armRebalanceWindow();
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        o.partiallyFillable = true;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("must be fill-or-kill"));
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsSellBalanceNotErc20() public {
        _armRebalanceWindow();
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        o.sellTokenBalance = GPv2Order.BALANCE_EXTERNAL;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("sell must be erc20"));
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsBuyBalanceNotErc20() public {
        _armRebalanceWindow();
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        o.buyTokenBalance = GPv2Order.BALANCE_INTERNAL;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("buy must be erc20"));
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsFeeNonZero() public {
        _armRebalanceWindow();
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        o.feeAmount = 1;
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("fee must be zero"));
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsBadAppData() public {
        _armRebalanceWindow();
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        o.appData = keccak256("wrong");
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert(bytes("bad appData"));
        module.validateRebalanceOrder(d, e);
    }
}
