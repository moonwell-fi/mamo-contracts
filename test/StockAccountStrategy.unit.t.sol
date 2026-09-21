// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockFailingERC20} from "./MockFailingERC20.sol";
import {StockAccountStrategyTestBase} from "./utils/StockAccountStrategyTestBase.sol";

contract StockAccountStrategyUnitTest is StockAccountStrategyTestBase {
    function testInitializeStoresConfiguration() public view {
        assertEq(address(strategy.asset()), address(usdc), "asset");
        assertEq(address(strategy.stockRegistry()), address(stockRegistry), "stock registry");
        assertEq(address(strategy.mamoStrategyRegistry()), address(registry), "mamo registry");
        assertEq(strategy.strategyTypeId(), strategyTypeId, "strategy type id");
        assertEq(strategy.cowDomainSeparator(), SEPARATOR, "domain separator");
        assertEq(strategy.cowVaultRelayer(), relayer, "vault relayer");
        assertEq(strategy.owner(), user, "owner");
        assertEq(strategy.cashTargetBps(), 0, "cash target");
        assertEq(strategy.accountSlippageBps(), 0, "account slippage");
        assertEq(strategy.feeRecipient(), feeRecipient, "fee recipient");
        assertEq(strategy.lastFeePaid(), block.timestamp, "last fee paid");
        assertEq(
            strategy.appDataHash(address(nvda)),
            keccak256(bytes(strategy.appDataDocument(address(nvda)))),
            "app data hash"
        );

        (IStockAccountStrategy.BasketEntry[] memory entries, uint16 cashTargetBps) = strategy.getBasket();
        assertEq(entries.length, 2, "entries length");
        assertEq(entries[0].token, address(nvda), "entry 0 token");
        assertEq(entries[0].targetBps, 5000, "entry 0 weight");
        assertEq(entries[1].token, address(aapl), "entry 1 token");
        assertEq(entries[1].targetBps, 5000, "entry 1 weight");
        assertEq(cashTargetBps, 0, "returned cash target");
    }

    function testInitializeRevertsOnZeroAsset() public {
        StockAccountStrategy.InitParams memory params = _defaultParams();
        params.asset = address(0);

        vm.expectRevert(IStockAccountStrategy.ZeroAddress.selector);
        _deployProxy(params);
    }

    function testInitializeRevertsOnZeroSettlement() public {
        StockAccountStrategy.InitParams memory params = _defaultParams();
        params.cowSettlement = address(0);

        vm.expectRevert(IStockAccountStrategy.ZeroAddress.selector);
        _deployProxy(params);
    }

    function testInitializeRevertsOnZeroMamoRegistry() public {
        StockAccountStrategy.InitParams memory params = _defaultParams();
        params.mamoStrategyRegistry = address(0);

        vm.expectRevert(IStockAccountStrategy.ZeroAddress.selector);
        _deployProxy(params);
    }

    function testInitializeRevertsOnZeroStockRegistry() public {
        StockAccountStrategy.InitParams memory params = _defaultParams();
        params.stockRegistry = address(0);

        vm.expectRevert(IStockAccountStrategy.ZeroAddress.selector);
        _deployProxy(params);
    }

    function testInitializeRevertsOnZeroStrategyTypeId() public {
        StockAccountStrategy.InitParams memory params = _defaultParams();
        params.strategyTypeId = 0;

        vm.expectRevert(IStockAccountStrategy.StrategyTypeIdNotSet.selector);
        _deployProxy(params);
    }

    function testInitializeValidatesBasket() public {
        StockAccountStrategy.InitParams memory params = _defaultParams();
        params.entries = _entries(address(nvda), 4000, address(aapl), 5000);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.WeightsMustTotal.selector, 9000));
        _deployProxy(params);
    }

    function testInitializeCannotRunTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        strategy.initialize(_defaultParams());
    }

    function testDepositPullsAssetAndEmits() public {
        _fundUsdc(funder, 1_000e18);

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.Deposit(1_000e18);

        vm.prank(funder);
        strategy.deposit(1_000e18);

        assertEq(usdc.balanceOf(address(strategy)), 1_000e18, "strategy balance");
        assertEq(usdc.balanceOf(funder), 0, "funder balance");
        assertEq(strategy.getNAV(), 1_000e18, "nav");
    }

    function testDepositRevertsOnZeroAmount() public {
        vm.expectRevert(IStockAccountStrategy.ZeroAmount.selector);
        strategy.deposit(0);
    }

    function testDepositRevertsAboveCap() public {
        _fundUsdc(funder, CAP + 1);

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.DepositCapExceeded.selector, CAP + 1));
        strategy.deposit(CAP + 1);
    }

    function testDepositAtCapSucceeds() public {
        _fundUsdc(funder, CAP);

        vm.prank(funder);
        strategy.deposit(CAP);

        assertEq(strategy.getNAV(), CAP, "nav at cap");
    }

    function testDepositRevertsBelowMinimum() public {
        _fundUsdc(funder, MIN_DEPOSIT - 1);

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.AccountBelowMinimum.selector, MIN_DEPOSIT - 1));
        strategy.deposit(MIN_DEPOSIT - 1);
    }

    function testDepositAtMinimumSucceeds() public {
        _fundUsdc(funder, MIN_DEPOSIT);

        vm.prank(funder);
        strategy.deposit(MIN_DEPOSIT);

        assertEq(strategy.getNAV(), MIN_DEPOSIT, "nav at minimum");
    }

    function testTopUpBelowMinimumSucceedsOnFundedAccount() public {
        _fundUsdc(funder, MIN_DEPOSIT);
        vm.prank(funder);
        strategy.deposit(MIN_DEPOSIT);

        _fundUsdc(funder, 1e18);
        vm.prank(funder);
        strategy.deposit(1e18);

        assertEq(strategy.getNAV(), MIN_DEPOSIT + 1e18, "nav after top up");
    }

    function testDepositTokenRevertsBelowMinimum() public {
        _fundToken(nvda, funder, 0.4e18);

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.AccountBelowMinimum.selector, 80e18));
        strategy.depositToken(address(nvda), 0.4e18);
    }

    function testDepositTokenAtMinimumSucceeds() public {
        _fundToken(nvda, funder, 0.5e18);

        vm.prank(funder);
        strategy.depositToken(address(nvda), 0.5e18);

        assertEq(strategy.getNAV(), MIN_DEPOSIT, "nav at minimum");
    }

    function testDepositTokenPullsTokenAndEmits() public {
        _fundToken(nvda, funder, 10e18);

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.DepositToken(address(nvda), 10e18);

        vm.prank(funder);
        strategy.depositToken(address(nvda), 10e18);

        assertEq(nvda.balanceOf(address(strategy)), 10e18, "strategy balance");
        assertEq(strategy.getNAV(), 2_000e18, "nav");
    }

    function testDepositTokenRevertsOnUnlistedToken() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        _fundToken(other, funder, 1e18);

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.TokenNotActive.selector, address(other)));
        strategy.depositToken(address(other), 1e18);
    }

    function testDepositTokenRevertsOnZeroAmount() public {
        vm.expectRevert(IStockAccountStrategy.ZeroAmount.selector);
        strategy.depositToken(address(nvda), 0);
    }

    function testDepositTokenRevertsAboveCap() public {
        _fundToken(nvda, funder, 126e18);

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.DepositCapExceeded.selector, 25_200e18));
        strategy.depositToken(address(nvda), 126e18);
    }

    function testDepositTokenAtCapSucceeds() public {
        _fundToken(nvda, funder, 125e18);

        vm.prank(funder);
        strategy.depositToken(address(nvda), 125e18);

        assertEq(strategy.getNAV(), CAP, "nav at cap");
    }

    function testSetBasketReplacesEntriesAndEmits() public {
        IStockAccountStrategy.BasketEntry[] memory entries = _entries(address(nvda), 7000, address(aapl), 2000);

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.BasketUpdated(entries, 1000);

        vm.prank(user);
        strategy.setBasket(entries, 1000);

        (IStockAccountStrategy.BasketEntry[] memory stored, uint16 cashTargetBps) = strategy.getBasket();
        assertEq(stored.length, 2, "entries length");
        assertEq(stored[0].targetBps, 7000, "entry 0 weight");
        assertEq(stored[1].targetBps, 2000, "entry 1 weight");
        assertEq(cashTargetBps, 1000, "cash target");
    }

    function testSetBasketRevertsOnTooManyPositions() public {
        stockRegistry.setMaxPositions(1);

        vm.prank(user);
        vm.expectRevert(IStockAccountStrategy.TooManyPositions.selector);
        strategy.setBasket(_entries(address(nvda), 5000, address(aapl), 5000), 0);
    }

    function testSetBasketRevertsOnWeightBelowMinimum() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.WeightBelowMinimum.selector, address(aapl)));
        strategy.setBasket(_entries(address(nvda), 9950, address(aapl), 50), 0);
    }

    function testSetBasketRevertsOnZeroWeight() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.WeightBelowMinimum.selector, address(aapl)));
        strategy.setBasket(_entries(address(nvda), 10000, address(aapl), 0), 0);
    }

    function testSetBasketRevertsOnInactiveToken() public {
        MockERC20 other = new MockERC20("Other", "OTH");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.TokenNotActive.selector, address(other)));
        strategy.setBasket(_entries(address(nvda), 5000, address(other), 5000), 0);
    }

    function testSetBasketRevertsOnDuplicateToken() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.DuplicateToken.selector, address(nvda)));
        strategy.setBasket(_entries(address(nvda), 5000, address(nvda), 5000), 0);
    }

    function testSetBasketRevertsOnWrongTotal() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.WeightsMustTotal.selector, 9000));
        strategy.setBasket(_entries(address(nvda), 5000, address(aapl), 4000), 0);
    }

    function testSetBasketOnlyOwner() public {
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, funder));
        strategy.setBasket(_entries(address(nvda), 5000, address(aapl), 5000), 0);
    }

    function testDroppedTokenKeepsBalanceWithZeroTarget() public {
        _fundToken(nvda, funder, 10e18);
        _fundToken(aapl, funder, 20e18);

        vm.startPrank(funder);
        strategy.depositToken(address(nvda), 10e18);
        strategy.depositToken(address(aapl), 20e18);
        vm.stopPrank();

        vm.prank(user);
        strategy.setBasket(_entries(address(nvda), 10000), 0);

        (address[] memory tokens, uint256[] memory currentBps, uint256[] memory targetBps) = strategy.getWeights();
        assertEq(tokens[1], address(aapl), "aapl listed");
        assertEq(targetBps[1], 0, "dropped target");
        assertEq(currentBps[1], 5000, "dropped weight still held");
        assertEq(targetBps[0], 10000, "kept target");
        assertEq(aapl.balanceOf(address(strategy)), 20e18, "aapl still held");
    }

    function testSetAccountSlippageStoresAndEmits() public {
        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.SlippageUpdated(0, 50);

        vm.prank(user);
        strategy.setAccountSlippage(50);

        assertEq(strategy.accountSlippageBps(), 50, "stored slippage");
        assertEq(strategy.getAccountSlippage(), 50, "effective slippage");
    }

    function testSetAccountSlippageRevertsAboveCap() public {
        vm.prank(user);
        vm.expectRevert(IStockAccountStrategy.SlippageExceedsMaximum.selector);
        strategy.setAccountSlippage(101);
    }

    function testSetAccountSlippageOnlyOwner() public {
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, funder));
        strategy.setAccountSlippage(50);
    }

    function testGetAccountSlippageFallsBackToCap() public {
        assertEq(strategy.getAccountSlippage(), 100, "unset falls back to cap");

        vm.prank(user);
        strategy.setAccountSlippage(80);
        stockRegistry.setMaxBackendSlippageBps(25);

        assertEq(strategy.getAccountSlippage(), 25, "lowered cap wins");
    }

    function testWithdrawTokenMovesBalanceAndEmits() public {
        _fundToken(nvda, funder, 10e18);
        vm.prank(funder);
        strategy.depositToken(address(nvda), 10e18);

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.WithdrawToken(address(nvda), 4e18);

        vm.prank(user);
        strategy.withdrawToken(address(nvda), 4e18);

        assertEq(nvda.balanceOf(user), 4e18, "user balance");
        assertEq(nvda.balanceOf(address(strategy)), 6e18, "strategy balance");
    }

    function testWithdrawTokenRevertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(IStockAccountStrategy.ZeroAmount.selector);
        strategy.withdrawToken(address(nvda), 0);
    }

    function testWithdrawTokenOnlyOwner() public {
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, funder));
        strategy.withdrawToken(address(nvda), 1);
    }

    function testWithdrawTokenUnaffectedByFailingToken() public {
        MockFailingERC20 failing = new MockFailingERC20();
        _listActive(address(failing));
        priceChecker.setRate(address(failing), address(usdc), 1e18);
        failing.setBalance(address(strategy), 5e18);

        _fundToken(nvda, funder, 10e18);
        vm.prank(funder);
        strategy.depositToken(address(nvda), 10e18);

        vm.prank(user);
        vm.expectRevert("Transfer failed");
        strategy.withdrawToken(address(failing), 5e18);

        vm.prank(user);
        strategy.withdrawToken(address(nvda), 10e18);

        assertEq(nvda.balanceOf(user), 10e18, "user balance");
    }

    function testWithdrawAllInKindSweepsEverything() public {
        _fundUsdc(funder, 1_000e18);
        _fundToken(nvda, funder, 10e18);

        vm.startPrank(funder);
        strategy.deposit(1_000e18);
        strategy.depositToken(address(nvda), 10e18);
        vm.stopPrank();

        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.WithdrawToken(address(usdc), 1_000e18);
        vm.expectEmit(address(strategy));
        emit IStockAccountStrategy.WithdrawToken(address(nvda), 10e18);

        vm.prank(user);
        strategy.withdrawAllInKind();

        assertEq(usdc.balanceOf(user), 1_000e18, "user usdc");
        assertEq(nvda.balanceOf(user), 10e18, "user nvda");
        assertEq(strategy.getNAV(), 0, "nav emptied");
    }

    function testWithdrawAllInKindOnlyOwner() public {
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, funder));
        strategy.withdrawAllInKind();
    }

    function testApproveCowRelayerSetsMaxAllowance() public {
        strategy.approveCowRelayer(address(usdc));
        strategy.approveCowRelayer(address(nvda));

        assertEq(usdc.allowance(address(strategy), relayer), type(uint256).max, "usdc allowance");
        assertEq(nvda.allowance(address(strategy), relayer), type(uint256).max, "nvda allowance");
    }

    function testApproveCowRelayerRevertsOnUnlistedToken() public {
        MockERC20 other = new MockERC20("Other", "OTH");

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.TokenNotListed.selector, address(other)));
        strategy.approveCowRelayer(address(other));
    }

    function testViewsWithMixedPosition() public {
        _fundUsdc(funder, 1_000e18);
        _fundToken(nvda, funder, 10e18);

        vm.startPrank(funder);
        strategy.deposit(1_000e18);
        strategy.depositToken(address(nvda), 10e18);
        vm.stopPrank();

        assertEq(strategy.getNAV(), 3_000e18, "nav");

        address[] memory held = strategy.heldTokens();
        assertEq(held.length, 1, "held length");
        assertEq(held[0], address(nvda), "held token");

        (address[] memory tokens, uint256[] memory currentBps, uint256[] memory targetBps) = strategy.getWeights();
        assertEq(tokens.length, 2, "tokens length");
        assertEq(currentBps[0], 6666, "nvda current");
        assertEq(currentBps[1], 0, "aapl current");
        assertEq(targetBps[0], 5000, "nvda target");
        assertEq(targetBps[1], 5000, "aapl target");
    }

    function testHaltedTokenIsExcludedFromValuationButStaysHeld() public {
        _fundUsdc(funder, 1_000e18);
        _fundToken(nvda, funder, 10e18);
        _fundToken(aapl, funder, 20e18);

        vm.startPrank(funder);
        strategy.deposit(1_000e18);
        strategy.depositToken(address(nvda), 10e18);
        strategy.depositToken(address(aapl), 20e18);
        vm.stopPrank();

        _halt(address(aapl));
        priceChecker.setRate(address(aapl), address(usdc), 0);

        assertEq(strategy.getNAV(), 3_000e18, "nav excludes halted token");

        (address[] memory tokens, uint256[] memory currentBps,) = strategy.getWeights();
        assertEq(tokens[1], address(aapl), "halted token still listed");
        assertEq(currentBps[0], 6666, "nvda current");
        assertEq(currentBps[1], 0, "halted current");

        address[] memory held = strategy.heldTokens();
        assertEq(held.length, 2, "held length");
        assertEq(held[1], address(aapl), "halted token still held");

        vm.prank(user);
        strategy.withdrawAllInKind();

        assertEq(aapl.balanceOf(user), 20e18, "halted token swept in kind");
        assertEq(aapl.balanceOf(address(strategy)), 0, "halted token drained");
    }

    function testWeightsAreZeroOnEmptyAccount() public view {
        (, uint256[] memory currentBps,) = strategy.getWeights();
        assertEq(currentBps[0], 0, "nvda current");
        assertEq(currentBps[1], 0, "aapl current");
        assertEq(strategy.getNAV(), 0, "nav");
        assertEq(strategy.heldTokens().length, 0, "held length");
    }

    function _halt(address token) internal {
        stockRegistry.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Halted,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: address(0),
                chainlinkFeed: address(0)
            })
        );
    }
}
