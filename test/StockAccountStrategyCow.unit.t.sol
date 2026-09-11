// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";

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

        vm.expectRevert("Order hash does not match the provided digest");
        strategy.isValidSignature(keccak256("other"), abi.encode(order));
    }

    function testRevertsOnBuyOrder() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.kind = GPv2Order.KIND_BUY;

        vm.expectRevert("Order must be a sell order");
        _check(order);
    }

    function testRevertsOnPartiallyFillableOrder() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.partiallyFillable = true;

        vm.expectRevert("Order must be fill-or-kill");
        _check(order);
    }

    function testRevertsOnNonErc20SellBalance() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.sellTokenBalance = GPv2Order.BALANCE_INTERNAL;

        vm.expectRevert("Order balances must be ERC20");
        _check(order);
    }

    function testRevertsOnNonErc20BuyBalance() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.buyTokenBalance = GPv2Order.BALANCE_EXTERNAL;

        vm.expectRevert("Order balances must be ERC20");
        _check(order);
    }

    function testRevertsOnWrongReceiver() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.receiver = user;

        vm.expectRevert("Order receiver must be this strategy");
        _check(order);
    }

    function testRevertsOnNonZeroFee() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.feeAmount = 1;

        vm.expectRevert("Fee amount must be zero");
        _check(order);
    }

    function testRevertsOnWrongAppData() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.appData = keccak256("other app data");

        vm.expectRevert("Invalid app data");
        _check(order);
    }

    function testRevertsWhenOrderExpiresTooSoon() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.validTo = uint32(block.timestamp + 4 minutes);

        vm.expectRevert("Order expires too soon");
        _check(order);
    }

    function testRevertsWhenOrderExpiresTooFarInTheFuture() public {
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), 1e18, 199e18);
        order.validTo = uint32(block.timestamp + 31 minutes);

        vm.expectRevert("Order expires too far in the future");
        _check(order);
    }

    function testRevertsWhenTokensAreTheSame() public {
        vm.expectRevert("Tokens must differ");
        _check(_order(address(nvda), address(nvda), 1e18, 1e18));
    }

    function testRevertsWhenSellTokenIsHalted() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.Halted);

        vm.expectRevert("Sell token not sellable");
        _check(_order(address(nvda), address(usdc), 1e18, 199e18));
    }

    function testSellOnlyTokenCanBeSold() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.SellOnly);

        assertTrue(_check(_order(address(nvda), address(usdc), 1e18, 199e18)) == MAGIC_VALUE, "magic value");
    }

    function testRevertsWhenBuyTokenIsSellOnly() public {
        _setStatus(address(aapl), IStockAccountRegistry.TokenStatus.SellOnly);

        vm.expectRevert("Buy token not active");
        _check(_order(address(nvda), address(aapl), 1e18, 2e18));
    }

    function testRevertsWhenBuyTokenIsNotListed() public {
        MockERC20 other = new MockERC20("Other Coin", "OTHERc");

        vm.expectRevert("Buy token not active");
        _check(_order(address(nvda), address(other), 1e18, 2e18));
    }

    function testRevertsWhenSellAmountExceedsBalance() public {
        vm.expectRevert("Sell amount exceeds balance");
        _check(_order(address(nvda), address(usdc), 11e18, 2189e18));
    }

    function testRevertsWhenSellLeavesTokenBelowRange() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 4000, address(aapl), 1000), 5000);

        vm.expectRevert("Sell leaves token below range");
        _check(_order(address(nvda), address(usdc), 6e18, 1194e18));
    }

    function testRevertsWhenBuyLeavesTokenAboveRange() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 1000, address(aapl), 9000), 0);

        vm.expectRevert("Buy leaves token above range");
        _check(_order(address(nvda), address(usdc), 3e18, 597e18));
    }

    function testTokenWithZeroTargetCanBeSoldDown() public {
        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 5000), 5000);

        assertTrue(_check(_order(address(aapl), address(usdc), 20e18, 1990e18)) == MAGIC_VALUE, "magic value");
    }

    function testRevertsWhenPriceCheckFails() public {
        vm.expectRevert("Price check failed");
        _check(_order(address(nvda), address(usdc), 1e18, 197e18));
    }

    function _check(GPv2Order.Data memory order) internal view returns (bytes4) {
        return strategy.isValidSignature(order.hash(SEPARATOR), abi.encode(order));
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
