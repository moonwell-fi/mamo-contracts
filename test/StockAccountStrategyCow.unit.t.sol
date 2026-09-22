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

    bytes4 public constant MAGIC_VALUE = 0x1626ba7e;

    function setUp() public override {
        super.setUp();

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

    function testAppDataDocumentCarriesTheHookThatPaysInTheFeeToken() public {
        string memory document = strategy.appDataDocument(address(nvda));

        assertEq(keccak256(bytes(document)), strategy.appDataHash(address(nvda)), "document hash");
        assertTrue(
            vm.contains(document, vm.toLowercase(vm.toString(address(strategy)))), "document carries the account"
        );
        assertTrue(
            vm.contains(
                document, vm.toString(abi.encodeWithSelector(IStockAccountStrategy.payFees.selector, address(nvda)))
            ),
            "document carries the payFees call for the fee token"
        );
        assertTrue(
            vm.contains(document, string.concat('"gasLimit":"', vm.toString(strategy.HOOK_GAS_LIMIT()), '"')),
            "document carries the hook gas limit"
        );
    }

    function testAppDataDocumentDiffersPerFeeToken() public view {
        assertTrue(
            strategy.appDataHash(address(nvda)) != strategy.appDataHash(address(usdc)), "hashes differ per fee token"
        );
    }

    function testRevertsOnWrongAppData() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.appData = keccak256("other app data");

        vm.expectRevert(IStockAccountStrategy.InvalidAppData.selector);
        _check(order);
    }

    function testRevertsWhenAppDataPaysTheFeeInTheSellToken() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.appData = strategy.appDataHash(address(nvda));

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
        GPv2Order.Data memory order = _order(address(nvda), address(nvda), 1e18, 1e18);

        vm.expectRevert(IStockAccountStrategy.TokensMustDiffer.selector);
        _check(order);
    }

    function testRevertsWhenSellTokenIsHalted() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.Halted);

        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.SellTokenNotSellable.selector, address(nvda)));
        _check(order);
    }

    function testSellOnlyTokenCanBeSold() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.SellOnly);

        assertTrue(_check(_order(address(nvda), address(usdc), 1e18, 199e18)) == MAGIC_VALUE, "magic value");
    }

    function testRevertsWhenBuyTokenIsSellOnly() public {
        _setStatus(address(aapl), IStockAccountRegistry.TokenStatus.SellOnly);

        GPv2Order.Data memory order = _order(address(nvda), address(aapl), 1e18, 2e18);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.BuyTokenNotActive.selector, address(aapl)));
        _check(order);
    }

    function testRevertsWhenBuyTokenIsNotListed() public {
        MockERC20 other = new MockERC20("Other Coin", "OTHERc");

        GPv2Order.Data memory order = _order(address(nvda), address(other), 1e18, 2e18);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.BuyTokenNotActive.selector, address(other)));
        _check(order);
    }

    function testRevertsWhenSellAmountExceedsBalance() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 11e18, 2189e18);

        vm.expectRevert(IStockAccountStrategy.SellExceedsBalance.selector);
        _check(order);
    }

    function testRevertsWhenSellLeavesTokenBelowRange() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 4000, address(aapl), 1000), 5000);

        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 6e18, 1194e18);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.SellLeavesTokenBelowRange.selector, address(nvda)));
        _check(order);
    }

    function testRevertsWhenBuyLeavesTokenAboveRange() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 1000, address(aapl), 9000), 0);

        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 3e18, 597e18);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.BuyLeavesTokenAboveRange.selector, address(usdc)));
        _check(order);
    }

    function testRevertsWhenBuyingATokenOutsideTheBasket() public {
        MockERC20 msft = new MockERC20("MSFT Coin", "MSFTc");
        _setStatus(address(msft), IStockAccountRegistry.TokenStatus.Active);
        priceChecker.setRate(address(msft), address(usdc), 100e18);
        priceChecker.setRate(address(nvda), address(msft), 2e18);

        GPv2Order.Data memory order = _order(address(nvda), address(msft), 1e18, 2e18);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.BuyTokenNotInBasket.selector, address(msft)));
        _check(order);
    }

    function testSellOnlyTokenCanBeSoldBelowItsBasketTarget() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 4000, address(aapl), 4000), 2000);

        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.SellOnly);

        // nvda 50% -> 25%, past its basket target less the band, into cash at 25% of a 20% target
        assertTrue(_check(_order(address(nvda), address(usdc), 5e18, 1000e18)) == MAGIC_VALUE, "magic value");

        (address[] memory tokens,, uint256[] memory targetBps) = strategy.getWeights();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(nvda)) assertEq(targetBps[i], 0, "a SellOnly token targets zero");
        }
    }

    function testTokenWithZeroTargetCanBeSoldDown() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 5000), 5000);

        assertTrue(_check(_order(address(aapl), address(usdc), 20e18, 1990e18)) == MAGIC_VALUE, "magic value");
    }

    function testRevertsWhenPriceCheckFails() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 197e18);

        vm.expectRevert(IStockAccountStrategy.PriceCheckFailed.selector);
        _check(order);
    }

    function testHaltedHoldingIsNotPricedByOrderCheck() public {
        _setStatus(address(aapl), IStockAccountRegistry.TokenStatus.Halted);
        priceChecker.setRate(address(aapl), address(usdc), 0);

        assertTrue(_check(_order(address(nvda), address(usdc), 1e18, 199e18)) == MAGIC_VALUE, "magic value");

        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 2e18, 398e18);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.BuyLeavesTokenAboveRange.selector, address(usdc)));
        _check(order);
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

        GPv2Order.Data memory under = _order(address(nvda), address(usdc), 1e18, floor - 1);

        vm.expectRevert(IStockAccountStrategy.PriceCheckFailed.selector);
        _check(under);
    }

    function testRevertsWhenTheQuoteRoundsToZero() public {
        usdc.mint(address(strategy), 1_000e18);

        GPv2Order.Data memory order = _order(address(usdc), address(nvda), 1, 1);

        vm.expectRevert(IStockAccountStrategy.PriceCheckFailed.selector);
        _check(order);
    }

    function testRevertsOnZeroSellAmount() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 0, 0);

        vm.expectRevert(IStockAccountStrategy.ZeroAmount.selector);
        _check(order);
    }

    function testRevertsOnZeroBuyAmount() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 5000), 5000);
        priceChecker.setRate(address(aapl), address(usdc), 1);

        GPv2Order.Data memory order = _order(address(aapl), address(usdc), 1e18, 0);

        vm.expectRevert(IStockAccountStrategy.ZeroAmount.selector);
        _check(order);
    }

    /// @dev A cap of 10_000 would put the fair price floor at zero, so the strategy refuses it outright
    function testRevertsWhenTheSlippageCapIsTheFullRange() public {
        stockRegistry.setMaxBackendSlippageBps(10_000);

        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 3e18, 1);

        vm.expectRevert(IStockAccountStrategy.SlippageExceedsMaximum.selector);
        _check(order);
    }

    function testOneWeiBuyAmountIsRefusedAtTheHighestAcceptedCap() public {
        stockRegistry.setMaxBackendSlippageBps(9_999);
        assertEq(strategy.getAccountSlippage(), 9_999, "account slippage");

        GPv2Order.Data memory dust = _order(address(nvda), address(usdc), 3e18, 1);

        vm.expectRevert(IStockAccountStrategy.PriceCheckFailed.selector);
        _check(dust);

        assertTrue(
            _check(_order(address(nvda), address(usdc), 3e18, (600e18 * 1) / 10_000)) == MAGIC_VALUE, "magic value"
        );
    }

    function testRevertsWhenTheRegistryIsPaused() public {
        stockRegistry.setPaused(true);

        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);

        vm.expectRevert(IStockAccountStrategy.RegistryPaused.selector);
        _check(order);
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
            appData: strategy.appDataHash(buyToken),
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
