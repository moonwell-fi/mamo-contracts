// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MockCLPool} from "./mocks/MockCLPool.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {StockAccountStrategyTestBase} from "./utils/StockAccountStrategyTestBase.sol";

contract StockAccountStrategyWithdrawUnitTest is StockAccountStrategyTestBase {
    MockSwapRouter public router;
    MockCLPool public pool;

    function setUp() public override {
        super.setUp();

        router = new MockSwapRouter();
        router.setRate(address(nvda), address(usdc), 200e18);
        router.setRate(address(aapl), address(usdc), 100e18);
        usdc.mint(address(router), 1_000_000e18);

        pool = new MockCLPool(address(0), address(0), 100);
        _listWithPool(address(nvda));
        _listWithPool(address(aapl));

        stockRegistry.setAerodromeRouter(router);
        stockRegistry.setMaxWithdrawSlippageBps(500);

        _fundUsdc(funder, 500e18);
        vm.prank(funder);
        strategy.deposit(500e18);

        _fundToken(nvda, funder, 10e18);
        vm.prank(funder);
        strategy.depositToken(address(nvda), 10e18);

        _fundToken(aapl, funder, 20e18);
        vm.prank(funder);
        strategy.depositToken(address(aapl), 20e18);
    }

    function testWithdrawPaysFromIdleWithoutSelling() public {
        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.Withdraw(300e18, 0);

        vm.prank(user);
        strategy.withdraw(300e18, 100);

        assertEq(usdc.balanceOf(user), 300e18, "user asset");
        assertEq(usdc.balanceOf(address(strategy)), 200e18, "remaining idle");
        assertEq(nvda.balanceOf(address(strategy)), 10e18, "nvda untouched");
        assertEq(aapl.balanceOf(address(strategy)), 20e18, "aapl untouched");
    }

    function testWithdrawSellsProRataAboveIdle() public {
        (,, uint256 referenceValue,) = strategy.previewWithdraw(1_500e18, 100);
        // Every other assertion here measures the sale against itself
        assertApproxEqAbs(referenceValue, (uint256(1_000e18) * 10_000) / 9_900, 1e3, "grossed up by the cap");

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.Withdraw(1_500e18, referenceValue);

        vm.prank(user);
        strategy.withdraw(1_500e18, 100);

        uint256 nvdaSold = 10e18 - nvda.balanceOf(address(strategy));
        uint256 aaplSold = 20e18 - aapl.balanceOf(address(strategy));

        assertApproxEqAbs(nvdaSold * 200, aaplSold * 100, 1e3, "pro rata split");
        assertEq(usdc.balanceOf(user), 1_500e18, "user asset");
        assertEq(usdc.balanceOf(address(strategy)), 500e18 + referenceValue - 1_500e18, "leftover idle");
    }

    function testWithdrawRevertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(IStockAccountStrategy.ZeroAmount.selector);
        strategy.withdraw(0, 100);
    }

    function testWithdrawRevertsWhenSlippageAboveCap() public {
        vm.prank(user);
        vm.expectRevert(IStockAccountStrategy.SlippageExceedsMaximum.selector);
        strategy.withdraw(1_500e18, 501);
    }

    /// @dev A cap of 10_000 used to divide by zero in the gross up, taking every withdrawal down with it
    function testWithdrawSucceedsAtTheHighestAcceptedSlippageCap() public {
        stockRegistry.setMaxWithdrawSlippageBps(9_999);

        vm.prank(user);
        strategy.withdraw(1_500e18, 9_999);

        assertEq(usdc.balanceOf(user), 1_500e18, "user asset");
    }

    function testWithdrawRevertsWhenValueIsInsufficient() public {
        vm.prank(user);
        vm.expectRevert(IStockAccountStrategy.InsufficientBalance.selector);
        strategy.withdraw(5_000e18, 100);
    }

    function testWithdrawRevertsWhenRouterPaysBelowFloor() public {
        router.setRate(address(nvda), address(usdc), 180e18);
        router.setRate(address(aapl), address(usdc), 90e18);

        vm.prank(user);
        vm.expectRevert("Too little received");
        strategy.withdraw(1_500e18, 100);
    }

    function testWithdrawSucceedsWhenRouterPaysInsideFloor() public {
        router.setRate(address(nvda), address(usdc), 199e18);
        router.setRate(address(aapl), address(usdc), 99.5e18);

        vm.prank(user);
        strategy.withdraw(1_500e18, 100);

        assertEq(usdc.balanceOf(user), 1_500e18, "user asset");
    }

    function testWithdrawSkipsHaltedToken() public {
        _halt(address(aapl));

        vm.prank(user);
        strategy.withdraw(1_500e18, 100);

        assertEq(aapl.balanceOf(address(strategy)), 20e18, "halted token untouched");
        assertLt(nvda.balanceOf(address(strategy)), 10e18, "nvda sold");
        assertEq(usdc.balanceOf(user), 1_500e18, "user asset");
    }

    function testWithdrawAllSellsEverythingSellable() public {
        _halt(address(aapl));

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.Withdraw(2_500e18, 2_000e18);

        vm.prank(user);
        strategy.withdrawAll(100);

        assertEq(usdc.balanceOf(user), 2_500e18, "user asset");
        assertEq(usdc.balanceOf(address(strategy)), 0, "idle drained");
        assertEq(nvda.balanceOf(address(strategy)), 0, "nvda sold");
        assertEq(aapl.balanceOf(address(strategy)), 20e18, "halted token stays");
    }

    function testWithdrawAllRevertsWhenEmpty() public {
        vm.prank(user);
        strategy.withdrawAllInKind();

        vm.prank(user);
        vm.expectRevert(IStockAccountStrategy.EmptyBalance.selector);
        strategy.withdrawAll(100);
    }

    function testWithdrawAllRevertsWhenSlippageAboveCap() public {
        vm.prank(user);
        vm.expectRevert(IStockAccountStrategy.SlippageExceedsMaximum.selector);
        strategy.withdrawAll(501);
    }

    function testPreviewWithdrawReturnsEmptyWhenIdleCovers() public view {
        (address[] memory tokens, uint256[] memory amounts, uint256 referenceValue, uint256 minProceeds) =
            strategy.previewWithdraw(300e18, 100);

        assertEq(tokens.length, 0, "tokens length");
        assertEq(amounts.length, 0, "amounts length");
        assertEq(referenceValue, 0, "reference value");
        assertEq(minProceeds, 0, "min proceeds");
    }

    function testPreviewWithdrawMatchesExecutedSells() public {
        (address[] memory tokens, uint256[] memory amounts, uint256 referenceValue, uint256 minProceeds) =
            strategy.previewWithdraw(1_500e18, 100);

        assertEq(tokens.length, 2, "tokens length");
        assertEq(tokens[0], address(nvda), "token 0");
        assertEq(tokens[1], address(aapl), "token 1");
        assertApproxEqAbs(minProceeds, (referenceValue * 99) / 100, 2, "min proceeds");

        vm.prank(user);
        strategy.withdraw(1_500e18, 100);

        assertEq(nvda.balanceOf(address(strategy)), 10e18 - amounts[0], "nvda sold");
        assertEq(aapl.balanceOf(address(strategy)), 20e18 - amounts[1], "aapl sold");
    }

    function testWithdrawOnlyOwner() public {
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, funder));
        strategy.withdraw(1_500e18, 100);
    }

    function testWithdrawAllOnlyOwner() public {
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, funder));
        strategy.withdrawAll(100);
    }

    function _listWithPool(address token) internal {
        stockRegistry.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: address(pool),
                chainlinkFeed: address(0)
            })
        );
    }

    function _halt(address token) internal {
        stockRegistry.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Halted,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: address(pool),
                chainlinkFeed: address(0)
            })
        );
    }
}
