// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {MockCLPool} from "./mocks/MockCLPool.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {StockAccountStrategyTestBase} from "./utils/StockAccountStrategyTestBase.sol";

contract StockAccountStrategyFeesUnitTest is StockAccountStrategyTestBase {
    MockSwapRouter public router;
    MockCLPool public pool;

    uint256 public startTime;

    function setUp() public override {
        super.setUp();

        router = new MockSwapRouter();
        router.setRate(address(nvda), address(usdc), 200e18);
        router.setRate(address(aapl), address(usdc), 100e18);
        usdc.mint(address(router), 1_000_000e18);

        pool = new MockCLPool(100);
        _listWithPool(address(nvda));
        _listWithPool(address(aapl));

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

    function testPayFeesTransfersEveryTokenAndEmits() public {
        vm.warp(startTime + 30 days);

        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(nvda);
        tokens[2] = address(aapl);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = _fee(1_000e18, 30 days);
        amounts[1] = _fee(10e18, 30 days);
        amounts[2] = _fee(20e18, 30 days);

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.FeesPaid(30 days, tokens, amounts);

        strategy.payFees();

        assertEq(usdc.balanceOf(feeRecipient), amounts[0], "usdc fee");
        assertEq(nvda.balanceOf(feeRecipient), amounts[1], "nvda fee");
        assertEq(aapl.balanceOf(feeRecipient), amounts[2], "aapl fee");
        assertEq(usdc.balanceOf(address(strategy)), 1_000e18 - amounts[0], "usdc left");
        assertEq(nvda.balanceOf(address(strategy)), 10e18 - amounts[1], "nvda left");
        assertEq(aapl.balanceOf(address(strategy)), 20e18 - amounts[2], "aapl left");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testSecondPaymentInTheSameBlockIsANoOp() public {
        vm.warp(startTime + 30 days);
        strategy.payFees();

        uint256 paid = usdc.balanceOf(feeRecipient);

        strategy.payFees();

        assertEq(usdc.balanceOf(feeRecipient), paid, "recipient balance unchanged");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testHaltedTokenIsSkippedWhileTheOthersPay() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.Halted);

        vm.warp(startTime + 30 days);
        strategy.payFees();

        assertEq(nvda.balanceOf(feeRecipient), 0, "halted token not charged");
        assertEq(nvda.balanceOf(address(strategy)), 10e18, "halted balance untouched");
        assertEq(usdc.balanceOf(feeRecipient), _fee(1_000e18, 30 days), "usdc fee");
        assertEq(aapl.balanceOf(feeRecipient), _fee(20e18, 30 days), "aapl fee");
    }

    function testPromoRateChargesNothingAndStillAdvancesTheClock() public {
        stockRegistry.setManagementFeeBps(0);

        vm.warp(startTime + 30 days);
        strategy.payFees();

        assertEq(usdc.balanceOf(feeRecipient), 0, "nothing charged");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testRaisingTheRateDoesNotChargeThePromoPeriod() public {
        stockRegistry.setManagementFeeBps(0);

        vm.warp(startTime + 30 days);
        strategy.payFees();

        stockRegistry.setManagementFeeBps(100);

        vm.warp(startTime + 60 days);
        strategy.payFees();

        assertEq(usdc.balanceOf(feeRecipient), _fee(1_000e18, 30 days), "only the paid period is charged");
    }

    function testFeeDueMatchesWhatIsPaid() public {
        vm.warp(startTime + 45 days);

        uint256 usdcDue = strategy.feeDue(address(usdc));
        uint256 nvdaDue = strategy.feeDue(address(nvda));

        assertEq(usdcDue, _fee(1_000e18, 45 days), "usdc due");

        strategy.payFees();

        assertEq(usdc.balanceOf(feeRecipient), usdcDue, "usdc paid");
        assertEq(nvda.balanceOf(feeRecipient), nvdaDue, "nvda paid");
        assertEq(strategy.feeDue(address(usdc)), 0, "nothing due right after");
    }

    function testFeeDueIsZeroForHaltedAndUnlistedTokens() public {
        _setStatus(address(nvda), IStockAccountRegistry.TokenStatus.Halted);

        vm.warp(startTime + 30 days);

        assertEq(strategy.feeDue(address(nvda)), 0, "halted token");
        assertEq(strategy.feeDue(address(router)), 0, "unlisted token");
    }

    function testWithdrawPaysFeesFirst() public {
        vm.warp(startTime + 30 days);

        vm.prank(user);
        strategy.withdraw(100e18, 100);

        assertEq(usdc.balanceOf(feeRecipient), _fee(1_000e18, 30 days), "usdc fee");
        assertEq(nvda.balanceOf(feeRecipient), _fee(10e18, 30 days), "nvda fee");
        assertEq(usdc.balanceOf(user), 100e18, "user asset");
        assertEq(strategy.lastFeePaid(), startTime + 30 days, "last fee paid");
    }

    function testWithdrawTokenPaysFeesFirst() public {
        vm.warp(startTime + 30 days);

        uint256 fee = _fee(10e18, 30 days);

        vm.prank(user);
        strategy.withdrawToken(address(nvda), 10e18 - fee);

        assertEq(nvda.balanceOf(feeRecipient), fee, "nvda fee");
        assertEq(nvda.balanceOf(user), 10e18 - fee, "user balance");
        assertEq(nvda.balanceOf(address(strategy)), 0, "account emptied");
    }

    function testWithdrawTokenAboveBalanceReverts() public {
        vm.warp(startTime + 30 days);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.ExceedsBalance.selector, address(nvda)));
        strategy.withdrawToken(address(nvda), 10e18);
    }

    function testWithdrawAllInKindPaysFeesFirst() public {
        vm.warp(startTime + 30 days);

        uint256 usdcFee = _fee(1_000e18, 30 days);
        uint256 nvdaFee = _fee(10e18, 30 days);
        uint256 aaplFee = _fee(20e18, 30 days);

        vm.prank(user);
        strategy.withdrawAllInKind();

        assertEq(usdc.balanceOf(feeRecipient), usdcFee, "usdc fee");
        assertEq(nvda.balanceOf(feeRecipient), nvdaFee, "nvda fee");
        assertEq(aapl.balanceOf(feeRecipient), aaplFee, "aapl fee");
        assertEq(usdc.balanceOf(user), 1_000e18 - usdcFee, "user usdc");
        assertEq(nvda.balanceOf(user), 10e18 - nvdaFee, "user nvda");
        assertEq(aapl.balanceOf(user), 20e18 - aaplFee, "user aapl");
        assertEq(strategy.getNAV(), 0, "nav emptied");
    }

    function testWithdrawAllPaysFeesBeforeSelling() public {
        vm.warp(startTime + 365 days);

        vm.prank(user);
        strategy.withdrawAll(100);

        assertEq(usdc.balanceOf(feeRecipient), 10e18, "usdc fee");
        assertEq(nvda.balanceOf(feeRecipient), 0.1e18, "nvda fee");
        assertEq(aapl.balanceOf(feeRecipient), 0.2e18, "aapl fee");
        assertEq(usdc.balanceOf(user), 4_950e18, "user asset");
        assertEq(usdc.balanceOf(address(strategy)), 0, "idle drained");
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

    function _fee(uint256 balance, uint256 elapsed) internal view returns (uint256) {
        return (balance * stockRegistry.managementFeeBps() * elapsed) / (10_000 * 365 days);
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
}
