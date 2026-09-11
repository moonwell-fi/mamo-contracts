// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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

    function testAccrualSetsFeeOwedPerTokenAndEmits() public {
        vm.warp(startTime + 30 days);

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.FeesAccrued(30 days);

        strategy.accrueManagementFee();

        assertEq(strategy.feeOwed(address(usdc)), _fee(1_000e18, 30 days), "usdc fee");
        assertEq(strategy.feeOwed(address(nvda)), _fee(10e18, 30 days), "nvda fee");
        assertEq(strategy.feeOwed(address(aapl)), _fee(20e18, 30 days), "aapl fee");
        assertEq(strategy.lastFeeAccrual(), startTime + 30 days, "accrual timestamp");
    }

    function testAccrualWithoutElapsedTimeIsNoOp() public {
        strategy.accrueManagementFee();

        assertEq(strategy.feeOwed(address(usdc)), 0, "usdc fee");
        assertEq(strategy.feeOwed(address(nvda)), 0, "nvda fee");
        assertEq(strategy.lastFeeAccrual(), startTime, "accrual timestamp");
    }

    function testDustAccrualKeepsAccrualTimestamp() public {
        StockAccountStrategy dust = StockAccountStrategy(payable(_deployProxy(_defaultParams())));
        usdc.mint(address(dust), 1);

        vm.warp(startTime + 1);
        dust.accrueManagementFee();

        assertEq(dust.feeOwed(address(usdc)), 0, "usdc fee");
        assertEq(dust.lastFeeAccrual(), startTime, "accrual timestamp");
    }

    function testNavAndWeightsExcludeFeesOwed() public {
        vm.warp(startTime + 30 days);
        strategy.accrueManagementFee();

        uint256 cash = 1_000e18 - strategy.feeOwed(address(usdc));
        uint256 nvdaValue = (10e18 - strategy.feeOwed(address(nvda))) * 200;
        uint256 aaplValue = (20e18 - strategy.feeOwed(address(aapl))) * 100;
        uint256 nav = cash + nvdaValue + aaplValue;

        assertEq(strategy.getNAV(), nav, "nav");

        (, uint256[] memory currentBps,) = strategy.getWeights();
        assertEq(currentBps[0], (nvdaValue * 10_000) / nav, "nvda weight");
        assertEq(currentBps[1], (aaplValue * 10_000) / nav, "aapl weight");
    }

    function testWithdrawAllInKindLeavesFeesBehind() public {
        vm.warp(startTime + 30 days);
        strategy.accrueManagementFee();

        uint256 usdcFee = strategy.feeOwed(address(usdc));
        uint256 nvdaFee = strategy.feeOwed(address(nvda));
        uint256 aaplFee = strategy.feeOwed(address(aapl));

        vm.prank(user);
        strategy.withdrawAllInKind();

        assertEq(usdc.balanceOf(address(strategy)), usdcFee, "usdc left behind");
        assertEq(nvda.balanceOf(address(strategy)), nvdaFee, "nvda left behind");
        assertEq(aapl.balanceOf(address(strategy)), aaplFee, "aapl left behind");
        assertEq(usdc.balanceOf(user), 1_000e18 - usdcFee, "user usdc");
        assertEq(nvda.balanceOf(user), 10e18 - nvdaFee, "user nvda");
        assertEq(aapl.balanceOf(user), 20e18 - aaplFee, "user aapl");
        assertEq(strategy.getNAV(), 0, "nav emptied");
    }

    function testWithdrawAllSellsOnlyAvailableBalance() public {
        vm.warp(startTime + 365 days);

        vm.prank(user);
        strategy.withdrawAll(100);

        assertEq(strategy.feeOwed(address(usdc)), 10e18, "usdc fee");
        assertEq(strategy.feeOwed(address(nvda)), 0.1e18, "nvda fee");
        assertEq(strategy.feeOwed(address(aapl)), 0.2e18, "aapl fee");
        assertEq(usdc.balanceOf(address(strategy)), 10e18, "usdc left behind");
        assertEq(nvda.balanceOf(address(strategy)), 0.1e18, "nvda left behind");
        assertEq(aapl.balanceOf(address(strategy)), 0.2e18, "aapl left behind");
        assertEq(usdc.balanceOf(user), 4_950e18, "user asset");
    }

    function testWithdrawTokenAboveAvailableReverts() public {
        vm.warp(startTime + 30 days);

        vm.prank(user);
        vm.expectRevert("Amount exceeds available balance");
        strategy.withdrawToken(address(nvda), 10e18);
    }

    function testCollectFeesTransfersAndZeroes() public {
        vm.warp(startTime + 30 days);
        strategy.accrueManagementFee();

        uint256 usdcFee = strategy.feeOwed(address(usdc));

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.FeesCollected(address(usdc), usdcFee);

        strategy.collectFees(address(usdc));

        assertEq(usdc.balanceOf(feeRecipient), usdcFee, "recipient balance");
        assertEq(usdc.balanceOf(address(strategy)), 1_000e18 - usdcFee, "strategy balance");
        assertEq(strategy.feeOwed(address(usdc)), 0, "fee owed cleared");
    }

    function testCollectFeesRevertsWhenNothingOwed() public {
        vm.warp(startTime + 30 days);
        strategy.accrueManagementFee();
        strategy.collectFees(address(nvda));

        vm.expectRevert("Nothing to collect");
        strategy.collectFees(address(nvda));
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
        vm.expectRevert("Not backend");
        strategy.setFeeRecipient(makeAddr("newFeeRecipient"));
    }

    function testSetFeeRecipientRevertsOnZeroAddress() public {
        vm.prank(backend);
        vm.expectRevert("Invalid fee recipient address");
        strategy.setFeeRecipient(address(0));
    }

    function testInitializeRevertsOnZeroFeeRecipient() public {
        StockAccountStrategy.InitParams memory params = _defaultParams();
        params.feeRecipient = address(0);

        vm.expectRevert("Invalid fee recipient address");
        _deployProxy(params);
    }

    function testInitializeRevertsOnFeeAboveMaximum() public {
        StockAccountStrategy.InitParams memory params = _defaultParams();
        params.managementFeeBps = strategy.MAX_MANAGEMENT_FEE_BPS() + 1;

        vm.expectRevert("Fee exceeds maximum");
        _deployProxy(params);
    }

    function _fee(uint256 balance, uint256 elapsed) internal view returns (uint256) {
        return (balance * strategy.managementFeeBps() * elapsed) / (10_000 * 365 days);
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
}
