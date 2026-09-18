// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {StockAccountStrategyTestBase} from "./utils/StockAccountStrategyTestBase.sol";

contract StockAccountStrategyFeesUnitTest is StockAccountStrategyTestBase {
    MockSwapRouter public router;
    MockCLPool public pool;
    MockERC20 public msft;

    uint256 public startTime;

    function setUp() public override {
        super.setUp();

        router = new MockSwapRouter();
        router.setRate(address(nvda), address(usdc), 200e18);
        router.setRate(address(aapl), address(usdc), 100e18);
        usdc.mint(address(router), 1_000_000e18);

        msft = new MockERC20("MSFT Coin", "MSFTc");
        priceChecker.setRate(address(msft), address(usdc), 50e18);
        priceChecker.setRate(address(usdc), address(msft), 2e16);

        pool = new MockCLPool(100);
        _listWithPool(address(nvda));
        _listWithPool(address(aapl));
        _listWithPool(address(msft));

        stockRegistry.setAerodromeRouter(router);
        stockRegistry.setMaxWithdrawSlippageBps(500);

        _fundUsdc(funder, 1_000e18);
        vm.prank(funder);
        strategy.deposit(1_000e18);

        _fundToken(nvda, funder, 10e18);
        vm.prank(funder);
        strategy.depositToken(address(nvda), 10e18);

        _fundToken(aapl, funder, 20e18);
        vm.prank(funder);
        strategy.depositToken(address(aapl), 20e18);

        startTime = block.timestamp;
    }

    function testFeeDueIsTheRateOnTheAccountValueOverTheElapsedTime() public {
        vm.warp(startTime + 30 days);

        assertEq(strategy.getNAV(), 5_000e18, "nav");
        assertEq(strategy.feeDue(), _feeValue(5_000e18, 30 days), "fee due");
        assertEq(strategy.feeDueIn(address(usdc)), strategy.feeDue(), "fee due in the asset");
        assertEq(strategy.feeDueIn(address(nvda)), strategy.feeDue() / 200, "fee due in nvda");
        assertEq(strategy.feeDueIn(address(aapl)), strategy.feeDue() / 100, "fee due in aapl");
    }

    function testPayFeesInAStockSendsOnlyThatToken() public {
        vm.warp(startTime + 30 days);

        uint256 amount = strategy.feeDueIn(address(nvda));

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.FeesPaid(30 days, address(nvda), amount);

        strategy.payFees(address(nvda));

        assertEq(nvda.balanceOf(feeRecipient), amount, "nvda fee");
        assertEq(nvda.balanceOf(address(strategy)), 10e18 - amount, "nvda left");
        assertEq(usdc.balanceOf(feeRecipient), 0, "asset untouched");
        assertEq(aapl.balanceOf(feeRecipient), 0, "aapl untouched");
        assertEq(usdc.balanceOf(address(strategy)), 1_000e18, "asset balance unchanged");
        assertEq(aapl.balanceOf(address(strategy)), 20e18, "aapl balance unchanged");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
        assertEq(strategy.feeDue(), 0, "nothing due right after");
    }

    function testPayFeesInTheAssetSendsOnlyTheAsset() public {
        vm.warp(startTime + 30 days);

        uint256 amount = strategy.feeDue();

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.FeesPaid(30 days, address(usdc), amount);

        strategy.payFees(address(usdc));

        assertEq(usdc.balanceOf(feeRecipient), amount, "asset fee");
        assertEq(usdc.balanceOf(address(strategy)), 1_000e18 - amount, "asset left");
        assertEq(nvda.balanceOf(feeRecipient), 0, "nvda untouched");
        assertEq(aapl.balanceOf(feeRecipient), 0, "aapl untouched");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testSecondPaymentInTheSameBlockIsANoOp() public {
        vm.warp(startTime + 30 days);
        strategy.payFees(address(usdc));

        uint256 paid = usdc.balanceOf(feeRecipient);

        strategy.payFees(address(usdc));

        assertEq(usdc.balanceOf(feeRecipient), paid, "recipient balance unchanged");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testPayFeesInAHaltedTokenReverts() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.Halted);

        vm.warp(startTime + 30 days);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.FeeTokenNotAllowed.selector, address(nvda)));
        strategy.payFees(address(nvda));

        assertEq(strategy.lastFeePaid(), startTime, "last fee paid");
    }

    function testPayFeesInAnUnlistedTokenReverts() public {
        vm.warp(startTime + 30 days);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.FeeTokenNotAllowed.selector, address(router)));
        strategy.payFees(address(router));

        assertEq(strategy.lastFeePaid(), startTime, "last fee paid");
    }

    function testPayFeesInAListedTokenWithNoBalanceReverts() public {
        vm.warp(startTime + 30 days);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.NoBalanceForFee.selector, address(msft)));
        strategy.payFees(address(msft));

        assertEq(strategy.lastFeePaid(), startTime, "the clock does not move");
        assertEq(strategy.feeDue(), _feeValue(5_000e18, 30 days), "the fee is still owed");
    }

    function testPromoRateChargesNothingAndStillAdvancesTheClock() public {
        stockRegistry.setManagementFeeBps(0);

        vm.warp(startTime + 30 days);
        strategy.payFees(address(nvda));

        assertEq(nvda.balanceOf(feeRecipient), 0, "nothing charged");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testPromoRateAdvancesTheClockOnATokenWithNoBalance() public {
        stockRegistry.setManagementFeeBps(0);

        vm.warp(startTime + 30 days);
        strategy.payFees(address(msft));

        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testRaisingTheRateDoesNotChargeThePromoPeriod() public {
        stockRegistry.setManagementFeeBps(0);

        vm.warp(startTime + 30 days);
        strategy.payFees(address(usdc));

        stockRegistry.setManagementFeeBps(100);

        vm.warp(startTime + 60 days);
        strategy.payFees(address(usdc));

        assertEq(usdc.balanceOf(feeRecipient), _feeValue(5_000e18, 30 days), "only the paid period is charged");
    }

    function testFeeIsCappedByTheChosenTokenBalance() public {
        vm.warp(startTime + 40_000 days);

        assertGt(strategy.feeDueIn(address(nvda)), 10e18, "the fee is larger than the balance");

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.FeesPaid(40_000 days, address(nvda), 10e18);

        strategy.payFees(address(nvda));

        assertEq(nvda.balanceOf(feeRecipient), 10e18, "the whole balance is paid");
        assertEq(nvda.balanceOf(address(strategy)), 0, "nvda emptied");
        assertEq(strategy.lastFeePaid(), startTime + 40_000 days, "last fee paid");
    }

    function testWithdrawPaysTheFeeInTheAssetAfterSelling() public {
        vm.warp(startTime + 30 days);

        uint256 due = strategy.feeDue();

        vm.prank(user);
        strategy.withdraw(1_500e18, 100);

        assertEq(usdc.balanceOf(feeRecipient), due, "asset fee");
        assertEq(nvda.balanceOf(feeRecipient), 0, "nvda untouched");
        assertEq(aapl.balanceOf(feeRecipient), 0, "aapl untouched");
        assertEq(usdc.balanceOf(user), 1_500e18, "user asset");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testWithdrawPaysTheFeeWhenTheIdleBalanceIsEnough() public {
        vm.warp(startTime + 30 days);

        uint256 due = strategy.feeDue();

        vm.prank(user);
        strategy.withdraw(100e18, 100);

        assertEq(usdc.balanceOf(feeRecipient), due, "asset fee");
        assertEq(usdc.balanceOf(user), 100e18, "user asset");
        assertEq(nvda.balanceOf(address(strategy)), 10e18, "no position sold");
    }

    function testWithdrawAllPaysTheFeeInTheAssetAfterSelling() public {
        vm.warp(startTime + 365 days);

        vm.prank(user);
        strategy.withdrawAll(100);

        assertEq(usdc.balanceOf(feeRecipient), 50e18, "asset fee");
        assertEq(nvda.balanceOf(feeRecipient), 0, "nvda untouched");
        assertEq(aapl.balanceOf(feeRecipient), 0, "aapl untouched");
        assertEq(usdc.balanceOf(user), 4_950e18, "user asset");
        assertEq(usdc.balanceOf(address(strategy)), 0, "idle drained");
    }

    function testWithdrawTokenPaysTheFeeInThatToken() public {
        vm.warp(startTime + 30 days);

        uint256 fee = strategy.feeDueIn(address(nvda));

        vm.prank(user);
        strategy.withdrawToken(address(nvda), 10e18 - fee);

        assertEq(nvda.balanceOf(feeRecipient), fee, "nvda fee");
        assertEq(nvda.balanceOf(user), 10e18 - fee, "user balance");
        assertEq(nvda.balanceOf(address(strategy)), 0, "account emptied");
        assertEq(usdc.balanceOf(feeRecipient), 0, "asset untouched");
    }

    function testWithdrawTokenAboveBalanceReverts() public {
        vm.warp(startTime + 30 days);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.ExceedsBalance.selector, address(nvda)));
        strategy.withdrawToken(address(nvda), 10e18);
    }

    function testWithdrawAllInKindPaysTheFeeInTheAssetWhenItIsHeld() public {
        vm.warp(startTime + 30 days);

        uint256 due = strategy.feeDue();

        vm.prank(user);
        strategy.withdrawAllInKind();

        assertEq(usdc.balanceOf(feeRecipient), due, "asset fee");
        assertEq(nvda.balanceOf(feeRecipient), 0, "nvda untouched");
        assertEq(aapl.balanceOf(feeRecipient), 0, "aapl untouched");
        assertEq(usdc.balanceOf(user), 1_000e18 - due, "user asset");
        assertEq(nvda.balanceOf(user), 10e18, "user nvda");
        assertEq(aapl.balanceOf(user), 20e18, "user aapl");
        assertEq(strategy.getNAV(), 0, "nav emptied");
    }

    function testWithdrawAllInKindPaysInTheFirstStockWithoutTheAsset() public {
        vm.prank(user);
        strategy.withdrawToken(address(usdc), 1_000e18);

        vm.warp(startTime + 30 days);

        uint256 fee = strategy.feeDueIn(address(nvda));

        vm.prank(user);
        strategy.withdrawAllInKind();

        assertEq(nvda.balanceOf(feeRecipient), fee, "nvda fee");
        assertEq(usdc.balanceOf(feeRecipient), 0, "asset untouched");
        assertEq(aapl.balanceOf(feeRecipient), 0, "aapl untouched");
        assertEq(nvda.balanceOf(user), 10e18 - fee, "user nvda");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testWithdrawAllInKindOnAnEmptyAccountOnlyAdvancesTheClock() public {
        vm.prank(user);
        strategy.withdrawAllInKind();

        vm.warp(startTime + 30 days);

        vm.prank(user);
        strategy.withdrawAllInKind();

        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testDepositDoesNotPayFees() public {
        vm.warp(startTime + 30 days);

        _fundUsdc(funder, 100e18);
        vm.prank(funder);
        strategy.deposit(100e18);

        assertEq(usdc.balanceOf(feeRecipient), 0, "nothing paid");
        assertEq(strategy.lastFeePaid(), startTime, "last fee paid");
    }

    function testSetFeeRecipientStoresAndEmits() public {
        address newRecipient = makeAddr("newFeeRecipient");

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.FeeRecipientUpdated(feeRecipient, newRecipient);

        vm.prank(backend);
        strategy.setFeeRecipient(newRecipient);

        assertEq(strategy.feeRecipient(), newRecipient, "fee recipient");
    }

    function testSetFeeRecipientOnlyBackend() public {
        vm.prank(user);
        vm.expectRevert(IStockAccountStrategy.NotBackend.selector);
        strategy.setFeeRecipient(makeAddr("newFeeRecipient"));
    }

    function testSetFeeRecipientRevertsOnZeroAddress() public {
        vm.prank(backend);
        vm.expectRevert(IStockAccountStrategy.ZeroAddress.selector);
        strategy.setFeeRecipient(address(0));
    }

    function testInitializeRevertsOnZeroFeeRecipient() public {
        StockAccountStrategy.InitParams memory params = _defaultParams();
        params.feeRecipient = address(0);

        vm.expectRevert(IStockAccountStrategy.ZeroAddress.selector);
        _deployProxy(params);
    }

    function _feeValue(uint256 nav, uint256 elapsed) internal view returns (uint256) {
        return (nav * stockRegistry.managementFeeBps() * elapsed) / (10_000 * 365 days);
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

    function _setStatus(address token, IStockAccountRegistry.TokenStatus status) internal {
        stockRegistry.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: status,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: address(pool),
                chainlinkFeed: address(0)
            })
        );
    }

    function testWithdrawTokenOfHaltedTokenPaysFeeFromUsdcAndExits() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.Halted);
        vm.warp(block.timestamp + 30 days);

        uint256 due = strategy.feeDue();
        uint256 held = nvda.balanceOf(address(strategy));
        uint256 recipientBefore = usdc.balanceOf(feeRecipient);

        vm.prank(user);
        strategy.withdrawToken(address(nvda), held);

        assertEq(nvda.balanceOf(user), held, "halted token not withdrawn");
        assertEq(usdc.balanceOf(feeRecipient) - recipientBefore, due, "fee not paid from USDC");
    }
}
