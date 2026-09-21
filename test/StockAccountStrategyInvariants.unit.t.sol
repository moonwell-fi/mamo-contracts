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
    uint256 signerKey;
    address[4] tokens;
    uint256[4] prices;
}

struct FeeProbe {
    uint64 clock;
    uint256 elapsed;
    uint256 due;
    uint256 nav;
    uint256 collected;
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
    uint256 internal immutable signerKey;
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
    uint256 public callsSetSlippageCap;
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
    uint256 public maxNavSeen;
    uint256 public feeValueCollected;
    uint64 public lastFeePaidSeen;
    bool public feeClockWentBackwards;
    bool public feeCreditedTooMuch;
    bool public feeCreditWentUnbacked;

    uint256 public feePayments;
    uint256 public cappedPayments;
    uint256 public zeroConversionPayments;

    uint256 public maxSellValueDrift;

    bool public rangeViolated;
    bool public fillCapViolated;
    bool public zeroFloorViolated;
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
        signerKey = config.signerKey;
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

        FeeProbe memory probe = _probeFee();

        vm.prank(user);
        try strategy.withdrawToken(token, amount) {} catch {}

        _checkFeeValue(probe);

        _observe();
    }

    function withdrawAllInKind(uint256 seed) external {
        _observe();
        callsWithdrawAllInKind++;

        if (seed % 16 != 0) return;

        FeeProbe memory probe = _probeFee();

        vm.prank(user);
        try strategy.withdrawAllInKind() {} catch {}

        _checkFeeValue(probe);

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

    function payFees(uint256 seed) external {
        _observe();
        callsPayFees++;

        address token = _feeToken(seed);
        if (token != address(0)) {
            _payFeesChecked(token);
        }

        _observe();
    }

    /// @dev A long drought makes the fee outgrow any one balance, which is the branch that pays short
    function payFeesAfterALongDrought(uint256 seed) external {
        _observe();
        callsPayFees++;

        vm.warp(block.timestamp + bound(seed, 365 days, 50 * 365 days));

        address token = _thinnestBalance();
        if (token != address(0)) {
            _payFeesChecked(token);
        }

        _observe();
    }

    /// @dev One unit of the token priced above the fee is the branch where the conversion floors to nothing
    function payFeesTheFeeCannotBuy(uint256 seed) external {
        _observe();
        callsPayFees++;

        address token = tokens[_stockIndex(uint8(seed))];
        if (IERC20(token).balanceOf(address(strategy)) == 0) return;
        if (_status(token) == IStockAccountRegistry.TokenStatus.Halted) return;

        if (IERC20(tokens[0]).balanceOf(address(strategy)) > 0) {
            try strategy.payFees(tokens[0]) {} catch {}
        }

        vm.warp(block.timestamp + 1);
        priceChecker.setRate(tokens[0], token, 1);

        if (strategy.feeDueIn(token) == 0) {
            _payFeesChecked(token);
        }

        _syncRates();
        _observe();
    }

    function _payFeesChecked(address token) internal {
        uint256 elapsed = block.timestamp - strategy.lastFeePaid();
        uint256 full = strategy.feeDueIn(token);
        uint256 balance = IERC20(token).balanceOf(address(strategy));
        uint256 collectedBefore = IERC20(token).balanceOf(feeRecipient);
        FeeProbe memory probe = _probeFee();

        try strategy.payFees(token) {
            feePayments++;
            if (elapsed > 0 && probe.due > 0 && full == 0) zeroConversionPayments++;
            if (full > balance) cappedPayments++;

            _checkFeeCredit(
                elapsed,
                full,
                IERC20(token).balanceOf(feeRecipient) - collectedBefore,
                strategy.lastFeePaid() - probe.clock
            );
            _checkFeeValue(probe);
        } catch {}
    }

    function _checkFeeCredit(uint256 elapsed, uint256 full, uint256 amount, uint256 credited) internal {
        uint256 allowed = amount >= full ? elapsed : (elapsed * amount) / full;

        if (credited > allowed) {
            feeCreditedTooMuch = true;
            _latch("the fee clock advanced past the slice the payment covered");
        }
    }

    function _probeFee() internal returns (FeeProbe memory probe) {
        _observe();

        probe.clock = strategy.lastFeePaid();
        probe.elapsed = block.timestamp - probe.clock;
        probe.due = strategy.feeDue();
        probe.nav = strategy.getNAV();
        probe.collected = feeValueCollected;
    }

    /**
     * @dev Every second the clock moves has to be bought with value at the recipient. A call can pay out of
     * several balances and each payment values the fee on a NAV the previous one has already shrunk, so the
     * value collected can fall short of the opening rate by at most that shrink, which is collected x due / nav.
     * The reference rates are floored integers, which costs another 2e-15 of the fee on the round trip.
     */
    function _checkFeeValue(FeeProbe memory probe) internal {
        _observe();

        uint256 credited = strategy.lastFeePaid() - probe.clock;
        if (credited == 0 || probe.elapsed == 0 || probe.nav == 0) return;

        uint256 collected = feeValueCollected - probe.collected;
        uint256 paidFor = (probe.due * credited) / probe.elapsed;
        uint256 slack = (probe.due * collected) / probe.nav + probe.due / 1e12 + VALUE_TOLERANCE;

        if (collected + slack < paidFor) {
            feeCreditWentUnbacked = true;
            _latch("the fee clock moved further than the value collected pays for");
        }
    }

    function _thinnestBalance() internal view returns (address token) {
        uint256 least = type(uint256).max;

        for (uint256 i = 0; i < 4; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(strategy));
            if (balance == 0) continue;
            if (i > 0 && _status(tokens[i]) == IStockAccountRegistry.TokenStatus.Halted) continue;

            uint256 value = (balance * prices[i]) / 1e18;
            if (value < least) {
                least = value;
                token = tokens[i];
            }
        }
    }

    function payFeesOnTheAsset() external {
        _observe();

        if (IERC20(tokens[0]).balanceOf(address(strategy)) > 0) {
            strategy.payFees(tokens[0]);
        }

        _observe();
    }

    function _feeToken(uint256 seed) internal view returns (address) {
        for (uint256 i = 0; i < 4; i++) {
            address token = tokens[(seed % 4 + i) % 4];

            if (IERC20(token).balanceOf(address(strategy)) == 0) continue;
            if (token != tokens[0] && _status(token) == IStockAccountRegistry.TokenStatus.Halted) continue;

            return token;
        }

        return address(0);
    }

    function setFeeRate(uint16 rate) external {
        _observe();
        callsSetFeeRate++;

        uint16 bounded = uint16(bound(rate, 0, stockRegistry.maxManagementFeeBps()));
        stockRegistry.setManagementFeeBps(bounded);

        if (bounded > maxRateSeen) maxRateSeen = bounded;
    }

    function setSlippageCap(uint16 bps) external {
        _observe();
        callsSetSlippageCap++;

        stockRegistry.setMaxBackendSlippageBps(
            uint16(bound(uint256(bps), 0, stockRegistry.backendSlippageCeilingBps()))
        );
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
        bytes32 digest = order.hash(separator);
        uint256 navBefore = strategy.getNAV();

        try strategy.isValidSignature(digest, abi.encode(order, _sign(digest))) returns (bytes4 value) {
            if (value != MAGIC_VALUE) {
                _latch("isValidSignature returned a value that is not the magic value");
                return;
            }

            acceptedOrders++;
            _checkStatuses(tokens[sell], tokens[buy]);
            _checkFillCap(expectedOut, buyAmount);
            _recordSellReference(tokens[sell], sellAmount);

            if (!_settle(tokens[sell], tokens[buy], sellAmount, buyAmount)) return;

            _checkValue(navBefore);
            _checkRanges(tokens[sell], tokens[buy]);
        } catch (bytes memory err) {
            _recordReject(err);
        }

        _observe();
    }

    function violation() external view returns (bool) {
        return rangeViolated || fillCapViolated || zeroFloorViolated || valueLossViolated || statusViolated
            || settlementFailed || feeClockWentBackwards || feeCreditedTooMuch || feeCreditWentUnbacked;
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

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The asset leg is the unit of account, so only a stock leg has a reference to compare
    function _recordSellReference(address sellToken, uint256 sellAmount) internal {
        if (sellToken == tokens[0]) return;

        uint256 available = IERC20(sellToken).balanceOf(address(strategy));
        if (available == 0) return;

        uint256 held = priceChecker.getExpectedOut(available, sellToken, tokens[0]);
        uint256 derived = (held * sellAmount) / available;
        uint256 fresh = priceChecker.getExpectedOut(sellAmount, sellToken, tokens[0]);
        uint256 drift = derived > fresh ? derived - fresh : fresh - derived;

        if (drift > maxSellValueDrift) maxSellValueDrift = drift;
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

        if (expectedOut > 0 && floor == 0) {
            zeroFloorViolated = true;
            _latch("an order was accepted against a fair price floor of zero");
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
            appData: strategy.appDataHash(buyToken),
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

            uint256 collected = IERC20(tokens[i]).balanceOf(feeRecipient);
            if (collected > feeCollected[tokens[i]]) {
                feeValueCollected += ((collected - feeCollected[tokens[i]]) * prices[i]) / 1e18;
                feeCollected[tokens[i]] = collected;
            }
        }

        uint256 nav = strategy.getNAV();
        if (nav > maxNavSeen) {
            maxNavSeen = nav;
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

    /// @dev Reference rates are integers, so a fee paid in a stock values back a few wei under what was owed
    uint256 public constant FEE_VALUE_TOLERANCE = 1e12;

    MockERC20 public googl;
    StockAccountStrategyHandler public handler;

    uint256 public startTimestamp;

    function setUp() public override {
        super.setUp();

        googl = new MockERC20("GOOGL Coin", "GOOGLc");
        _listActive(address(googl));

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
                signerKey: orderSignerKey,
                tokens: [address(usdc), address(nvda), address(aapl), address(googl)],
                prices: [uint256(1e18), 200e18, 100e18, 150e18]
            })
        );

        startTimestamp = block.timestamp;

        bytes4[] memory selectors = new bytes4[](20);
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
        selectors[10] = StockAccountStrategyHandler.payFeesAfterALongDrought.selector;
        selectors[11] = StockAccountStrategyHandler.payFeesTheFeeCannotBuy.selector;
        selectors[12] = StockAccountStrategyHandler.setSlippageCap.selector;

        for (uint256 i = 13; i < selectors.length; i++) {
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

    function invariant_acceptedOrdersAlwaysHaveANonZeroFairPriceFloor() public view {
        assertFalse(handler.zeroFloorViolated(), handler.lastViolation());
    }

    function invariant_derivedSellReferenceMatchesAFreshQuote() public view {
        assertLe(
            handler.maxSellValueDrift(),
            2,
            "the derived sell reference differs from a fresh quote by more than the 2 wei its two floor divisions round"
        );
    }

    function invariant_acceptedOrdersKeepAccountValue() public view {
        assertFalse(handler.valueLossViolated(), handler.lastViolation());
    }

    function invariant_haltedIsNeverTradedAndSellOnlyIsNeverBought() public view {
        assertFalse(handler.statusViolated(), handler.lastViolation());
    }

    function invariant_feeStaysUnderTheAccruedRate() public view {
        uint256 elapsed = block.timestamp - startTimestamp;
        uint256 ceiling = (handler.maxNavSeen() * handler.maxRateSeen() * elapsed) / (TOTAL_BPS * 365 days);

        assertLe(
            handler.feeValueCollected(),
            ceiling + FEE_VALUE_TOLERANCE + _flooringSlack(),
            "fee value collected exceeds feeBps x the largest account value ever seen x the elapsed time"
        );
    }

    /// @dev Credited seconds floor, so every payment can leave up to a second of the period chargeable again
    function _flooringSlack() internal view returns (uint256) {
        uint256 payments = handler.callsPayFees() + handler.callsWithdrawToken() + handler.callsWithdrawAllInKind();

        return (payments * handler.maxNavSeen() * handler.maxRateSeen()) / (TOTAL_BPS * 365 days);
    }

    function invariant_theFeeClockOnlyEverMovesForward() public view {
        assertFalse(handler.feeClockWentBackwards(), handler.lastViolation());
        assertLe(strategy.lastFeePaid(), block.timestamp, "the fee clock is ahead of the current block");
    }

    function invariant_theFeeClockNeverOutrunsThePaymentThatMovedIt() public view {
        assertFalse(handler.feeCreditedTooMuch(), handler.lastViolation());
    }

    function invariant_everySecondTheClockMovesIsBoughtWithValue() public view {
        assertFalse(handler.feeCreditWentUnbacked(), handler.lastViolation());
    }

    function invariant_payFeesOnTheAssetNeverReverts() public {
        handler.payFeesOnTheAsset();
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
        emit log_named_uint("calls setSlippageCap", handler.callsSetSlippageCap());
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
        emit log_named_uint("max derived sell reference drift, wei", handler.maxSellValueDrift());
        emit log_named_uint("fee payments that went through", handler.feePayments());
        emit log_named_uint("of those, capped by the balance", handler.cappedPayments());
        emit log_named_uint("of those, a fee the token cannot express", handler.zeroConversionPayments());
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
        GPv2Order.Data memory order = _order(address(nvda), address(usdc), overEdge, overEdge * 200);

        vm.expectRevert(abi.encodeWithSelector(IStockAccountStrategy.SellLeavesTokenBelowRange.selector, address(nvda)));
        _check(order);
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
}
