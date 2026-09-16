// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {GPv2Order} from "@libraries/GPv2Order.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@test/MockERC20.sol";
import {MockPriceChecker} from "@test/mocks/MockPriceChecker.sol";
import {MockStockAccountRegistry} from "@test/mocks/MockStockAccountRegistry.sol";
import {StockAccountStrategyTestBase} from "@test/utils/StockAccountStrategyTestBase.sol";

struct HandlerConfig {
    StockAccountStrategy strategy;
    MockStockAccountRegistry stockRegistry;
    MockPriceChecker priceChecker;
    address settlement;
    address user;
    address feeRecipient;
    bytes32 separator;
    address[4] tokens;
    uint256[4] prices;
}

contract StockAccountStrategyHandler is Test {
    using GPv2Order for GPv2Order.Data;

    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;
    uint256 internal constant TOTAL_BPS = 10_000;
    uint256 internal constant MIN_PRICE = 10e18;
    uint256 internal constant MAX_PRICE = 2_000e18;
    uint256 internal constant MIN_SELL = 1e15;

    /// @dev Rates are integers, so a swap may value out a few wei under the price checked floor
    uint256 internal constant VALUE_TOLERANCE = 1e9;

    uint256 internal constant WEIGHT_TOLERANCE_BPS = 1;

    StockAccountStrategy internal immutable strategy;
    MockStockAccountRegistry internal immutable stockRegistry;
    MockPriceChecker internal immutable priceChecker;
    address internal immutable settlement;
    address internal immutable relayer;
    address internal immutable user;
    address internal immutable feeRecipient;
    bytes32 internal immutable separator;
    bytes32 internal immutable appData;
    uint256 internal immutable cap;
    uint256 internal immutable minDeposit;

    address[4] public tokens;
    uint256[4] public prices;

    uint256 public callsDeposit;
    uint256 public callsDepositToken;
    uint256 public callsWithdrawToken;
    uint256 public callsWithdrawAllInKind;
    uint256 public callsSetBasket;
    uint256 public callsSetStatus;
    uint256 public callsMovePrice;
    uint256 public callsWarp;
    uint256 public callsPayFees;
    uint256 public callsSetFeeRate;
    uint256 public callsSubmitOrder;

    uint256 public acceptedOrders;
    uint256 public rejectedOrders;
    uint256 public rejectPriceCheck;
    uint256 public rejectSellBelowRange;
    uint256 public rejectBuyAboveRange;
    uint256 public rejectSellNotSellable;
    uint256 public rejectBuyNotActive;
    uint256 public rejectSellExceedsBalance;
    uint256 public rejectOther;

    uint16 public maxRateSeen;
    uint64 public lastFeePaidSeen;
    bool public feeClockWentBackwards;

    bool public rangeViolated;
    bool public fillCapViolated;
    bool public valueLossViolated;
    bool public statusViolated;
    bool public settlementFailed;
    string public lastViolation;

    bytes32 public basketHash;

    mapping(address => uint256) public maxBalanceSeen;
    mapping(address => uint256) public feeCollected;

    constructor(HandlerConfig memory config) {
        strategy = config.strategy;
        stockRegistry = config.stockRegistry;
        priceChecker = config.priceChecker;
        settlement = config.settlement;
        relayer = config.strategy.cowVaultRelayer();
        user = config.user;
        feeRecipient = config.feeRecipient;
        separator = config.separator;
        appData = config.strategy.appDataHash();
        cap = config.stockRegistry.maxStrategyDeposit();
        minDeposit = config.stockRegistry.minStrategyDeposit();
        maxRateSeen = config.stockRegistry.managementFeeBps();

        for (uint256 i = 0; i < 4; i++) {
            tokens[i] = config.tokens[i];
            prices[i] = config.prices[i];
        }

        _syncRates();
        _observe();

        (IStockAccountStrategy.BasketEntry[] memory entries, uint16 cashTargetBps) = config.strategy.getBasket();
        basketHash = keccak256(abi.encode(entries, cashTargetBps));
    }

    function deposit(uint256 amount) external {
        _observe();
        callsDeposit++;

        uint256 nav = strategy.getNAV();
        if (nav >= cap) return;

        uint256 max = cap - nav;
        uint256 min = nav >= minDeposit ? 1 : minDeposit - nav;
        if (min > max) return;

        amount = bound(amount, min, max);
        MockERC20(tokens[0]).mint(user, amount);

        vm.startPrank(user);
        IERC20(tokens[0]).approve(address(strategy), amount);
        try strategy.deposit(amount) {} catch {}
        vm.stopPrank();

        _observe();
    }

    function depositToken(uint8 tokenIdx, uint256 amount) external {
        _observe();
        callsDepositToken++;

        uint256 index = _stockIndex(tokenIdx);
        uint256 nav = strategy.getNAV();
        if (nav >= cap) return;

        uint256 max = ((cap - nav) * 1e18) / prices[index];
        uint256 min = nav >= minDeposit ? 1 : (((minDeposit - nav) * 1e18) / prices[index]) + 1;
        if (min > max) return;

        amount = bound(amount, min, max);
        MockERC20(tokens[index]).mint(user, amount);

        vm.startPrank(user);
        IERC20(tokens[index]).approve(address(strategy), amount);
        try strategy.depositToken(tokens[index], amount) {} catch {}
        vm.stopPrank();

        _observe();
    }

    function withdrawToken(uint8 tokenIdx, uint256 amount) external {
        _observe();
        callsWithdrawToken++;

        address token = tokens[tokenIdx % 4];
        uint256 available = IERC20(token).balanceOf(address(strategy));
        if (available == 0) return;

        amount = bound(amount, 1, available);

        vm.prank(user);
        try strategy.withdrawToken(token, amount) {} catch {}

        _observe();
    }

    function withdrawAllInKind(uint256 seed) external {
        _observe();
        callsWithdrawAllInKind++;

        if (seed % 16 != 0) return;

        vm.prank(user);
        try strategy.withdrawAllInKind() {} catch {}

        _observe();
    }

    function setBasket(uint256 seed) external {
        _observe();
        callsSetBasket++;

        uint16 minTargetBps = stockRegistry.minTargetBps();
        uint256 count;
        address[3] memory picked;

        for (uint256 i = 1; i < 4; i++) {
            bool active = stockRegistry.tokenConfig(tokens[i]).status == IStockAccountRegistry.TokenStatus.Active;
            if (active && (seed >> i) & 1 == 1) {
                picked[count++] = tokens[i];
            }
        }

        IStockAccountStrategy.BasketEntry[] memory entries = new IStockAccountStrategy.BasketEntry[](count);
        uint256 total;

        for (uint256 i = 0; i < count; i++) {
            uint256 share = uint256(keccak256(abi.encode(seed, i)));
            uint16 targetBps = uint16(bound(share, minTargetBps, 9_000 / count));

            entries[i] = IStockAccountStrategy.BasketEntry({token: picked[i], targetBps: targetBps});
            total += targetBps;
        }

        uint16 cashTargetBps = uint16(TOTAL_BPS - total);

        vm.prank(user);
        try strategy.setBasket(entries, cashTargetBps) {
            basketHash = keccak256(abi.encode(entries, cashTargetBps));
        } catch {}

        _observe();
    }

    function setStatus(uint8 tokenIdx, uint8 status) external {
        _observe();
        callsSetStatus++;

        uint256 index = _stockIndex(tokenIdx);
        uint256 draw = uint256(keccak256(abi.encode(tokenIdx, status))) % 4;

        IStockAccountRegistry.TokenStatus value = draw < 2
            ? IStockAccountRegistry.TokenStatus.Active
            : draw == 2 ? IStockAccountRegistry.TokenStatus.SellOnly : IStockAccountRegistry.TokenStatus.Halted;

        stockRegistry.setTokenConfig(
            tokens[index],
            IStockAccountRegistry.TokenConfig({
                status: value,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: address(0),
                chainlinkFeed: address(0)
            })
        );
    }

    function movePrice(uint8 tokenIdx, uint256 seed) external {
        _observe();
        callsMovePrice++;

        uint256 index = _stockIndex(tokenIdx);
        uint256 moved = (prices[index] * bound(seed, 5_000, 15_000)) / TOTAL_BPS;

        if (moved < MIN_PRICE) moved = MIN_PRICE;
        if (moved > MAX_PRICE) moved = MAX_PRICE;

        prices[index] = moved;
        _syncRates();
    }

    function warp(uint256 seconds_) external {
        _observe();
        callsWarp++;

        vm.warp(block.timestamp + bound(seconds_, 1, 60 days));

        _observe();
    }

    function payFees() external {
        _observe();
        callsPayFees++;

        strategy.payFees();

        _observe();
    }

    function setFeeRate(uint16 rate) external {
        _observe();
        callsSetFeeRate++;

        uint16 bounded = uint16(bound(rate, 0, stockRegistry.maxManagementFeeBps()));
        stockRegistry.setManagementFeeBps(bounded);

        if (bounded > maxRateSeen) maxRateSeen = bounded;
    }

    function submitOrder(uint8 sellIdx, uint8 buyIdx, uint256 sellAmount, uint256 buyAmountBps) external {
        _observe();
        callsSubmitOrder++;

        uint256 sell = sellIdx % 4;
        uint256 buy = buyIdx % 4;
        if (sell == buy) buy = (buy + 1) % 4;

        uint256 available = IERC20(tokens[sell]).balanceOf(address(strategy));
        if (available < MIN_SELL) return;

        uint256 mode = uint256(keccak256(abi.encode(sellIdx, buyIdx, sellAmount, buyAmountBps))) % 8;
        uint256 ceiling = mode == 0 ? available + available / 10 : available;

        if (mode > 1) {
            uint256 room = _roomToSell(tokens[sell], tokens[buy]);
            if (room >= MIN_SELL) ceiling = room < available ? room : available;
        }

        sellAmount = bound(sellAmount, MIN_SELL, ceiling);
        uint256 expectedOut = priceChecker.getExpectedOut(sellAmount, tokens[sell], tokens[buy]);
        uint256 buyAmount = (expectedOut * bound(buyAmountBps, 9_000, 10_500)) / TOTAL_BPS;
        if (buyAmount == 0) return;

        GPv2Order.Data memory order = _order(tokens[sell], tokens[buy], sellAmount, buyAmount);
        uint256 navBefore = strategy.getNAV();

        try strategy.isValidSignature(order.hash(separator), abi.encode(order)) returns (bytes4 value) {
            if (value != MAGIC_VALUE) {
                _latch("isValidSignature returned a value that is not the magic value");
                return;
            }

            acceptedOrders++;
            _checkStatuses(tokens[sell], tokens[buy]);
            _checkFillCap(expectedOut, buyAmount);

            if (!_settle(tokens[sell], tokens[buy], sellAmount, buyAmount)) return;

            _checkValue(navBefore);
            _checkRanges(tokens[sell], tokens[buy]);
        } catch (bytes memory err) {
            _recordReject(err);
        }

        _observe();
    }

    function violation() external view returns (bool) {
        return rangeViolated || fillCapViolated || valueLossViolated || statusViolated || settlementFailed
            || feeClockWentBackwards;
    }

    function _settle(address sellToken, address buyToken, uint256 sellAmount, uint256 buyAmount)
        internal
        returns (bool)
    {
        vm.prank(relayer);

        try IERC20(sellToken).transferFrom(address(strategy), settlement, sellAmount) {
            MockERC20(buyToken).mint(address(strategy), buyAmount);
            return true;
        } catch {
            settlementFailed = true;
            _latch("an accepted order could not be settled out of the account balance");
            return false;
        }
    }

    function _checkStatuses(address sellToken, address buyToken) internal {
        if (
            sellToken != tokens[0] && _status(sellToken) != IStockAccountRegistry.TokenStatus.Active
                && _status(sellToken) != IStockAccountRegistry.TokenStatus.SellOnly
        ) {
            statusViolated = true;
            _latch("an order selling a token that is not sellable was accepted");
        }

        if (buyToken != tokens[0] && _status(buyToken) != IStockAccountRegistry.TokenStatus.Active) {
            statusViolated = true;
            _latch("an order buying a token that is not active was accepted");
        }
    }

    function _status(address token) internal view returns (IStockAccountRegistry.TokenStatus) {
        return stockRegistry.tokenConfig(token).status;
    }

    function _checkFillCap(uint256 expectedOut, uint256 buyAmount) internal {
        uint256 floor = (expectedOut * (TOTAL_BPS - strategy.getAccountSlippage())) / TOTAL_BPS;

        if (buyAmount < floor) {
            fillCapViolated = true;
            _latch("an order priced under the account slippage cap was accepted");
        }
    }

    function _checkValue(uint256 navBefore) internal {
        uint256 floor = (navBefore * (TOTAL_BPS - strategy.getAccountSlippage())) / TOTAL_BPS;

        if (strategy.getNAV() + VALUE_TOLERANCE < floor) {
            valueLossViolated = true;
            _latch("an accepted order lost more account value than the slippage cap");
        }
    }

    function _checkRanges(address sellToken, address buyToken) internal {
        uint256 dev = stockRegistry.maxDeviationBps();
        (uint256 sellWeight, uint256 sellTarget) = _weight(sellToken);
        (uint256 buyWeight, uint256 buyTarget) = _weight(buyToken);

        if (sellWeight + dev + WEIGHT_TOLERANCE_BPS < sellTarget) {
            rangeViolated = true;
            _latch("an accepted order left the sell token below its range");
        }

        if (buyWeight > buyTarget + dev + WEIGHT_TOLERANCE_BPS) {
            rangeViolated = true;
            _latch("an accepted order left the buy token above its range");
        }
    }

    /// @dev Largest sell leaving both legs in the band, less a tenth to cover a fill above the reference
    function _roomToSell(address sellToken, address buyToken) internal view returns (uint256) {
        uint256 nav = strategy.getNAV();
        if (nav == 0) return 0;

        uint256 dev = stockRegistry.maxDeviationBps();
        (uint256 sellWeight, uint256 sellTarget) = _weight(sellToken);
        (uint256 buyWeight, uint256 buyTarget) = _weight(buyToken);

        uint256 sellRoomBps = sellWeight + dev > sellTarget ? sellWeight + dev - sellTarget : 0;
        uint256 buyRoomBps = buyTarget + dev > buyWeight ? buyTarget + dev - buyWeight : 0;
        uint256 roomValue = (nav * (sellRoomBps < buyRoomBps ? sellRoomBps : buyRoomBps)) / TOTAL_BPS;

        return (((roomValue * 9) / 10) * 1e18) / prices[_indexOf(sellToken)];
    }

    function _indexOf(address token) internal view returns (uint256) {
        for (uint256 i = 0; i < 4; i++) {
            if (tokens[i] == token) return i;
        }

        return 0;
    }

    function _weight(address token) internal view returns (uint256 weightBps, uint256 targetBps) {
        (address[] memory listed, uint256[] memory currentBps, uint256[] memory targets) = strategy.getWeights();

        if (token == tokens[0]) {
            uint256 nav = strategy.getNAV();
            uint256 balance = IERC20(token).balanceOf(address(strategy));

            return (nav == 0 ? 0 : (balance * TOTAL_BPS) / nav, strategy.cashTargetBps());
        }

        for (uint256 i = 0; i < listed.length; i++) {
            if (listed[i] == token) {
                return (currentBps[i], targets[i]);
            }
        }
    }

    function _recordReject(bytes memory err) internal {
        rejectedOrders++;
        bytes4 selector = err.length >= 4 ? bytes4(err) : bytes4(0);

        if (selector == IStockAccountStrategy.PriceCheckFailed.selector) {
            rejectPriceCheck++;
        } else if (selector == IStockAccountStrategy.SellLeavesTokenBelowRange.selector) {
            rejectSellBelowRange++;
        } else if (selector == IStockAccountStrategy.BuyLeavesTokenAboveRange.selector) {
            rejectBuyAboveRange++;
        } else if (selector == IStockAccountStrategy.SellTokenNotSellable.selector) {
            rejectSellNotSellable++;
        } else if (selector == IStockAccountStrategy.BuyTokenNotActive.selector) {
            rejectBuyNotActive++;
        } else if (selector == IStockAccountStrategy.SellExceedsBalance.selector) {
            rejectSellExceedsBalance++;
        } else {
            rejectOther++;
        }
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
            appData: appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _syncRates() internal {
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = 0; j < 4; j++) {
                if (i != j) {
                    priceChecker.setRate(tokens[i], tokens[j], (prices[i] * 1e18) / prices[j]);
                }
            }
        }
    }

    function _observe() internal {
        for (uint256 i = 0; i < 4; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(strategy));
            if (balance > maxBalanceSeen[tokens[i]]) {
                maxBalanceSeen[tokens[i]] = balance;
            }

            feeCollected[tokens[i]] = IERC20(tokens[i]).balanceOf(feeRecipient);
        }

        uint64 paidAt = strategy.lastFeePaid();

        if (paidAt < lastFeePaidSeen || paidAt > block.timestamp) {
            feeClockWentBackwards = true;
            _latch("the fee clock moved backwards or past the current block");
        }

        lastFeePaidSeen = paidAt;
    }

    function _stockIndex(uint8 tokenIdx) internal pure returns (uint256) {
        return 1 + (tokenIdx % 3);
    }

    function _latch(string memory reason) internal {
        lastViolation = reason;
    }
}

contract StockAccountStrategyInvariantsUnitTest is StockAccountStrategyTestBase {
    using GPv2Order for GPv2Order.Data;

    bytes4 public constant MAGIC_VALUE = 0x1626ba7e;
    uint256 public constant TOTAL_BPS = 10_000;

    MockERC20 public googl;
    StockAccountStrategyHandler public handler;

    bytes32 public appData;

    uint256 public startTimestamp;

    function setUp() public override {
        super.setUp();

        googl = new MockERC20("GOOGL Coin", "GOOGLc");
        _listActive(address(googl));

        appData = strategy.appDataHash();

        _fundUsdc(user, 1_000e18);
        vm.prank(user);
        strategy.deposit(1_000e18);

        nvda.mint(address(strategy), 2e18);
        aapl.mint(address(strategy), 3e18);
        googl.mint(address(strategy), 2e18);

        IStockAccountStrategy.BasketEntry[] memory entries = new IStockAccountStrategy.BasketEntry[](3);
        entries[0] = IStockAccountStrategy.BasketEntry({token: address(nvda), targetBps: 2_000});
        entries[1] = IStockAccountStrategy.BasketEntry({token: address(aapl), targetBps: 1_500});
        entries[2] = IStockAccountStrategy.BasketEntry({token: address(googl), targetBps: 1_500});

        vm.prank(user);
        strategy.setBasket(entries, 5_000);

        strategy.approveCowRelayer(address(usdc));
        strategy.approveCowRelayer(address(nvda));
        strategy.approveCowRelayer(address(aapl));
        strategy.approveCowRelayer(address(googl));

        handler = new StockAccountStrategyHandler(
            HandlerConfig({
                strategy: strategy,
                stockRegistry: stockRegistry,
                priceChecker: priceChecker,
                settlement: address(settlement),
                user: user,
                feeRecipient: feeRecipient,
                separator: SEPARATOR,
                tokens: [address(usdc), address(nvda), address(aapl), address(googl)],
                prices: [uint256(1e18), 200e18, 100e18, 150e18]
            })
        );

        startTimestamp = block.timestamp;

        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = StockAccountStrategyHandler.deposit.selector;
        selectors[1] = StockAccountStrategyHandler.depositToken.selector;
        selectors[2] = StockAccountStrategyHandler.withdrawToken.selector;
        selectors[3] = StockAccountStrategyHandler.withdrawAllInKind.selector;
        selectors[4] = StockAccountStrategyHandler.setBasket.selector;
        selectors[5] = StockAccountStrategyHandler.setStatus.selector;
        selectors[6] = StockAccountStrategyHandler.movePrice.selector;
        selectors[7] = StockAccountStrategyHandler.warp.selector;
        selectors[8] = StockAccountStrategyHandler.payFees.selector;
        selectors[9] = StockAccountStrategyHandler.setFeeRate.selector;

        for (uint256 i = 10; i < selectors.length; i++) {
            selectors[i] = StockAccountStrategyHandler.submitOrder.selector;
        }

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_acceptedOrdersLeaveBothLegsInRange() public view {
        assertFalse(handler.rangeViolated(), handler.lastViolation());
    }

    function invariant_acceptedOrdersFillWithinTheSlippageCap() public view {
        assertFalse(handler.fillCapViolated(), handler.lastViolation());
    }

    function invariant_acceptedOrdersKeepAccountValue() public view {
        assertFalse(handler.valueLossViolated(), handler.lastViolation());
    }

    function invariant_haltedIsNeverTradedAndSellOnlyIsNeverBought() public view {
        assertFalse(handler.statusViolated(), handler.lastViolation());
    }

    function invariant_feeStaysUnderTheAccruedRate() public view {
        address[4] memory tokens = [address(usdc), address(nvda), address(aapl), address(googl)];
        uint256 elapsed = block.timestamp - startTimestamp;

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 charged = handler.feeCollected(tokens[i]);
            uint256 ceiling =
                (handler.maxBalanceSeen(tokens[i]) * handler.maxRateSeen() * elapsed) / (TOTAL_BPS * 365 days);

            assertLe(
                charged,
                ceiling,
                "fee charged on a token exceeds feeBps x the largest balance ever held x the elapsed time"
            );
        }
    }

    function invariant_theFeeClockOnlyEverMovesForward() public view {
        assertFalse(handler.feeClockWentBackwards(), handler.lastViolation());
        assertLe(strategy.lastFeePaid(), block.timestamp, "the fee clock is ahead of the current block");
    }

    function invariant_payFeesNeverReverts() public {
        handler.payFees();
    }

    function invariant_onlyTheOwnerEverChangesTheTargets() public view {
        (IStockAccountStrategy.BasketEntry[] memory entries, uint16 cashTargetBps) = strategy.getBasket();

        assertEq(keccak256(abi.encode(entries, cashTargetBps)), handler.basketHash(), "targets moved on their own");
    }

    function invariant_valuationNeverReverts() public view {
        strategy.getNAV();
        strategy.getWeights();
        strategy.heldTokens();
    }

    function invariant_navMatchesTheReferencePrices() public view {
        address[4] memory tokens = [address(usdc), address(nvda), address(aapl), address(googl)];

        assertFalse(handler.settlementFailed(), handler.lastViolation());

        uint256 expectedNav = usdc.balanceOf(address(strategy));

        for (uint256 i = 1; i < tokens.length; i++) {
            uint256 available = IERC20(tokens[i]).balanceOf(address(strategy));
            bool halted = stockRegistry.tokenConfig(tokens[i]).status == IStockAccountRegistry.TokenStatus.Halted;

            if (available > 0 && !halted) {
                expectedNav += priceChecker.getExpectedOut(available, tokens[i], address(usdc));
            }
        }

        assertEq(strategy.getNAV(), expectedNav, "NAV does not match the reference value of what the account holds");
    }

    function invariant_summary() public view {
        assertFalse(handler.violation(), handler.lastViolation());
    }

    /// @dev Ghost counters roll back with the state at the start of every run, so this reports the last run
    function afterInvariant() public {
        emit log_named_uint("calls deposit", handler.callsDeposit());
        emit log_named_uint("calls depositToken", handler.callsDepositToken());
        emit log_named_uint("calls withdrawToken", handler.callsWithdrawToken());
        emit log_named_uint("calls withdrawAllInKind", handler.callsWithdrawAllInKind());
        emit log_named_uint("calls setBasket", handler.callsSetBasket());
        emit log_named_uint("calls setStatus", handler.callsSetStatus());
        emit log_named_uint("calls movePrice", handler.callsMovePrice());
        emit log_named_uint("calls warp", handler.callsWarp());
        emit log_named_uint("calls payFees", handler.callsPayFees());
        emit log_named_uint("calls setFeeRate", handler.callsSetFeeRate());
        emit log_named_uint("calls submitOrder", handler.callsSubmitOrder());
        emit log_named_uint("orders accepted", handler.acceptedOrders());
        emit log_named_uint("orders rejected", handler.rejectedOrders());
        emit log_named_uint("rejected PriceCheckFailed", handler.rejectPriceCheck());
        emit log_named_uint("rejected SellLeavesTokenBelowRange", handler.rejectSellBelowRange());
        emit log_named_uint("rejected BuyLeavesTokenAboveRange", handler.rejectBuyAboveRange());
        emit log_named_uint("rejected SellTokenNotSellable", handler.rejectSellNotSellable());
        emit log_named_uint("rejected BuyTokenNotActive", handler.rejectBuyNotActive());
        emit log_named_uint("rejected SellExceedsBalance", handler.rejectSellExceedsBalance());
        emit log_named_uint("rejected other", handler.rejectOther());
    }

    function testFuzz_rangeRuleBoundary(uint16 targetBps, uint256 sellBps) public {
        uint256 dev = stockRegistry.maxDeviationBps();
        uint256 target = bound(targetBps, dev + 1, 9_000);
        uint256 weight = bound(sellBps, target, TOTAL_BPS);

        vm.startPrank(user);
        strategy.withdrawAllInKind();
        strategy.setBasket(_entries(address(nvda), uint16(target)), uint16(TOTAL_BPS - target));
        vm.stopPrank();

        priceChecker.setRate(address(nvda), address(usdc), 200e18);

        nvda.mint(address(strategy), weight * 5e15);
        usdc.mint(address(strategy), (TOTAL_BPS - weight) * 1e18);

        uint256 edge = (weight - (target - dev)) * 5e15;

        assertEq(_check(_order(address(nvda), address(usdc), edge, edge * 200)), MAGIC_VALUE, "sale at the band edge");

        uint256 overEdge = edge + 5e15;

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.SellLeavesTokenBelowRange.selector, address(nvda)));
        _check(_order(address(nvda), address(usdc), overEdge, overEdge * 200));
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
            appData: appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
}
