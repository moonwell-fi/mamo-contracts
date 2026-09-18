// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {GPv2Order} from "@libraries/GPv2Order.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./MockERC20.sol";
import {StockAccountStrategyTestBase} from "./utils/StockAccountStrategyTestBase.sol";

contract StockAccountStrategyCowUnitTest is StockAccountStrategyTestBase {
    using GPv2Order for GPv2Order.Data;

    bytes32 public constant APP_DATA = keccak256("appData");
    bytes4 public constant MAGIC_VALUE = 0x1626ba7e;

    function setUp() public override {
        super.setUp();

        stockRegistry.setRequiredAppDataHash(APP_DATA);
        priceChecker.setRate(address(usdc), address(nvda), 0.005e18);
        priceChecker.setRate(address(usdc), address(aapl), 0.01e18);
        priceChecker.setRate(address(nvda), address(aapl), 2e18);

        nvda.mint(address(strategy), 10e18);
        aapl.mint(address(strategy), 20e18);
    }

    function testValidSellOrderReturnsMagicValue() public view {
        assertTrue(_check(_order(address(nvda), address(usdc), 1e18, 199e18)) == MAGIC_VALUE, "magic value");
    }

    function testValidBuyOfTokenWithAssetReturnsMagicValue() public {
        usdc.mint(address(strategy), 1000e18);

        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 4000, address(aapl), 4000), 2000);

        assertTrue(_check(_order(address(usdc), address(nvda), 400e18, 2e18)) == MAGIC_VALUE, "magic value");
    }

    function testRevertsWhenDigestDoesNotMatch() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);

        vm.expectRevert(IStockAccountStrategy.OrderHashMismatch.selector);
        strategy.isValidSignature(keccak256("other"), abi.encode(order, _sign(keccak256("other"))));
    }

    function testRevertsWhenTheBackendSignatureIsMissing() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);

        vm.expectRevert(IStockAccountStrategy.InvalidBackendSignature.selector);
        strategy.isValidSignature(order.hash(SEPARATOR), abi.encode(order, bytes("")));
    }

    function testRevertsWhenTheBackendSignatureIsFromAnotherKey() public {
        (, uint256 otherKey) = makeAddrAndKey("otherSigner");
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        bytes32 digest = order.hash(SEPARATOR);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, digest);

        vm.expectRevert(IStockAccountStrategy.InvalidBackendSignature.selector);
        strategy.isValidSignature(digest, abi.encode(order, abi.encodePacked(r, s, v)));
    }

    function testRotatingTheOrderSignerInvalidatesASignedOrder() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        bytes32 digest = order.hash(SEPARATOR);
        bytes memory signature = _sign(digest);

        assertTrue(strategy.isValidSignature(digest, abi.encode(order, signature)) == MAGIC_VALUE, "magic value");

        stockRegistry.setOrderSigner(makeAddr("rotatedSigner"));

        vm.expectRevert(IStockAccountStrategy.InvalidBackendSignature.selector);
        strategy.isValidSignature(digest, abi.encode(order, signature));
    }

    function testRevertsOnBuyOrder() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.kind = GPv2Order.KIND_BUY;

        vm.expectRevert(IStockAccountStrategy.OrderMustBeSell.selector);
        _check(order);
    }

    function testRevertsOnPartiallyFillableOrder() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.partiallyFillable = true;

        vm.expectRevert(IStockAccountStrategy.OrderMustBeFillOrKill.selector);
        _check(order);
    }

    function testRevertsOnNonErc20SellBalance() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.sellTokenBalance = GPv2Order.BALANCE_INTERNAL;

        vm.expectRevert(IStockAccountStrategy.OrderBalancesMustBeErc20.selector);
        _check(order);
    }

    function testRevertsOnNonErc20BuyBalance() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.buyTokenBalance = GPv2Order.BALANCE_EXTERNAL;

        vm.expectRevert(IStockAccountStrategy.OrderBalancesMustBeErc20.selector);
        _check(order);
    }

    function testRevertsOnWrongReceiver() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.receiver = user;

        vm.expectRevert(IStockAccountStrategy.OrderReceiverMismatch.selector);
        _check(order);
    }

    function testRevertsOnNonZeroFee() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.feeAmount = 1;

        vm.expectRevert(IStockAccountStrategy.OrderFeeMustBeZero.selector);
        _check(order);
    }

    function testRevertsOnWrongAppData() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.appData = keccak256("other app data");

        vm.expectRevert(IStockAccountStrategy.InvalidAppData.selector);
        _check(order);
    }

    function testRevertsWhenOrderExpiresTooSoon() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.validTo = uint32(block.timestamp + 4 minutes);

        vm.expectRevert(IStockAccountStrategy.OrderExpiresTooSoon.selector);
        _check(order);
    }

    function testRevertsWhenOrderExpiresTooFarInTheFuture() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.validTo = uint32(block.timestamp + 31 minutes);

        vm.expectRevert(IStockAccountStrategy.OrderExpiresTooLate.selector);
        _check(order);
    }

    function testRevertsWhenTokensAreTheSame() public {
        vm.expectRevert(IStockAccountStrategy.TokensMustDiffer.selector);
        _check(_order(address(nvda), address(nvda), 1e18, 1e18));
    }

    function testRevertsWhenSellTokenIsHalted() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.Halted);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.SellTokenNotSellable.selector, address(nvda)));
        _check(_order(address(nvda), address(usdc), 1e18, 199e18));
    }

    function testSellOnlyTokenCanBeSold() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.SellOnly);

        assertTrue(_check(_order(address(nvda), address(usdc), 1e18, 199e18)) == MAGIC_VALUE, "magic value");
    }

    function testRevertsWhenBuyTokenIsSellOnly() public {
        _setStatus(address(aapl), IStockAccountRegistry.TokenStatus.SellOnly);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.BuyTokenNotActive.selector, address(aapl)));
        _check(_order(address(nvda), address(aapl), 1e18, 2e18));
    }

    function testRevertsWhenBuyTokenIsNotListed() public {
        MockERC20 other = new MockERC20("Other Coin", "OTHERc");

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.BuyTokenNotActive.selector, address(other)));
        _check(_order(address(nvda), address(other), 1e18, 2e18));
    }

    function testRevertsWhenSellAmountExceedsBalance() public {
        vm.expectRevert(IStockAccountStrategy.SellExceedsBalance.selector);
        _check(_order(address(nvda), address(usdc), 11e18, 2189e18));
    }

    function testRevertsWhenSellLeavesTokenBelowRange() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 4000, address(aapl), 1000), 5000);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.SellLeavesTokenBelowRange.selector, address(nvda)));
        _check(_order(address(nvda), address(usdc), 6e18, 1194e18));
    }

    function testRevertsWhenBuyLeavesTokenAboveRange() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 1000, address(aapl), 9000), 0);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.BuyLeavesTokenAboveRange.selector, address(usdc)));
        _check(_order(address(nvda), address(usdc), 3e18, 597e18));
    }

    function testTokenWithZeroTargetCanBeSoldDown() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 5000), 5000);

        assertTrue(_check(_order(address(aapl), address(usdc), 20e18, 1990e18)) == MAGIC_VALUE, "magic value");
    }

    function testRevertsWhenPriceCheckFails() public {
        vm.expectRevert(IStockAccountStrategy.PriceCheckFailed.selector);
        _check(_order(address(nvda), address(usdc), 1e18, 197e18));
    }

    function testHaltedHoldingIsNotPricedByOrderCheck() public {
        _setStatus(address(aapl), IStockAccountRegistry.TokenStatus.Halted);
        priceChecker.setRate(address(aapl), address(usdc), 0);

        assertTrue(_check(_order(address(nvda), address(usdc), 1e18, 199e18)) == MAGIC_VALUE, "magic value");

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.BuyLeavesTokenAboveRange.selector, address(usdc)));
        _check(_order(address(nvda), address(usdc), 2e18, 398e18));
    }

    function testValidOrderQuotesEveryHoldingPlusTheOrderOnce() public {
        vm.expectCall(address(priceChecker), abi.encodeWithSelector(ISlippagePriceChecker.getExpectedOut.selector), 3);
        vm.expectCall(address(priceChecker), abi.encodeWithSelector(ISlippagePriceChecker.checkPrice.selector), 0);

        assertTrue(_check(_order(address(nvda), address(aapl), 1e18, 2e18)) == MAGIC_VALUE, "magic value");
    }

    function testOrderExactlyOnTheSlippageFloorIsAcceptedAndOneWeiUnderIsNot() public {
        uint256 slippage = strategy.getAccountSlippage();
        uint256 floor = (200e18 * (10_000 - slippage)) / 10_000;

        assertTrue(_check(_order(address(nvda), address(usdc), 1e18, floor)) == MAGIC_VALUE, "magic value");

        vm.expectRevert(IStockAccountStrategy.PriceCheckFailed.selector);
        _check(_order(address(nvda), address(usdc), 1e18, floor - 1));
    }

    function testRevertsWhenTheQuoteRoundsToZero() public {
        usdc.mint(address(strategy), 1_000e18);

        vm.expectRevert(IStockAccountStrategy.PriceCheckFailed.selector);
        _check(_order(address(usdc), address(nvda), 1, 1));
    }

    function testRevertsOnZeroSellAmount() public {
        vm.expectRevert(IStockAccountStrategy.ZeroAmount.selector);
        _check(_order(address(nvda), address(usdc), 0, 0));
    }

    function testRevertsOnZeroBuyAmount() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 5000), 5000);
        priceChecker.setRate(address(aapl), address(usdc), 1);

        vm.expectRevert(IStockAccountStrategy.ZeroAmount.selector);
        _check(_order(address(aapl), address(usdc), 1e18, 0));
    }

    function testRevertsWhenTheRegistryIsPaused() public {
        stockRegistry.setPaused(true);

        vm.expectRevert(IStockAccountStrategy.RegistryPaused.selector);
        _check(_order(address(nvda), address(usdc), 1e18, 199e18));
    }

    function testUnpausingTheRegistryRestoresOrderValidation() public {
        stockRegistry.setPaused(true);
        stockRegistry.setPaused(false);

        assertTrue(_check(_order(address(nvda), address(usdc), 1e18, 199e18)) == MAGIC_VALUE, "magic value");
    }

    function _check(GPv2Order.Data memory order) internal view returns (bytes4) {
        bytes32 digest = order.hash(SEPARATOR);
        return strategy.isValidSignature(digest, abi.encode(order, _sign(digest)));
    }

    function _order(address sellToken, address buyToken, uint256 sellAmount, uint256 buyAmount)
        internal
        view
        returns (GPv2Order.Data memory)
    {
        return GPv2Order.Data({
            sellToken: IERC20(sellToken),
            buyToken: IERC20(buyToken),
            receiver: address(strategy),
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: uint32(block.timestamp + 10 minutes),
            appData: APP_DATA,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _setStatus(address token, IStockAccountRegistry.TokenStatus status) internal {
        stockRegistry.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: status,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: address(0),
                chainlinkFeed: address(0)
            })
        );
    }
}
