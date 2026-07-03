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
        vm.expectRevert(bytes("receiver must be balancer"));
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

    // ---------- validateRebalanceOrder ----------

    function _rebalanceOrder(address sell, address buy) internal view returns (GPv2Order.Data memory) {
        return _order(sell, buy, address(bal), uint32(block.timestamp + 10 minutes));
    }

    function test_validateRebalanceOrder_validBothDirections_whileInFlight() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);

        GPv2Order.Data memory o01 = _rebalanceOrder(token0, token1);
        (bytes32 d01, bytes memory e01) = _sig(o01);
        assertEq(module.validateRebalanceOrder(d01, e01), bytes4(0x1626ba7e));

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
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token0);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("tokens must be distinct underlying");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsAeroAsLeg() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(aero, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(aero, token1);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("tokens must be distinct underlying");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsWrongReceiver() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _order(token0, token1, makeAddr("attacker"), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("receiver must be balancer");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsBadPrice() public {
        bal.setInFlight(true);
        spc.setPriceOk(false);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("price check failed");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsExpiresTooSoon() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _order(token0, token1, address(bal), uint32(block.timestamp + 1 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("expires too soon");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsExpiresTooFar() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 6 minutes);
        GPv2Order.Data memory o = _order(token0, token1, address(bal), uint32(block.timestamp + 30 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("expires too far");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsBadDigest() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (, bytes memory e) = _sig(o);
        vm.expectRevert("bad digest");
        module.validateRebalanceOrder(bytes32(uint256(1)), e);
    }
}
