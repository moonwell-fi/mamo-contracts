// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";

import {IGPv2Settlement} from "@interfaces/IGPv2Settlement.sol";
import {IPool} from "@interfaces/IPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {GPv2Order} from "@libraries/GPv2Order.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title StockAccountStrategy
 * @notice A per-user account holding a cash asset and tokenized stock positions against a target basket
 * @dev This contract is designed to be used as an implementation for proxies
 */
contract StockAccountStrategy is BaseStrategy, IStockAccountStrategy {
    using GPv2Order for GPv2Order.Data;
    using SafeERC20 for IERC20;

    uint16 internal constant TOTAL_BPS = 10_000;

    /// @notice Gas the CoW settlement grants the fee post-hook
    uint256 public constant HOOK_GAS_LIMIT = 1_000_000;

    /// @notice Value returned to CoW when this account accepts an order, per EIP-1271
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    /// @notice Shortest time an order may stay valid for
    uint256 internal constant MIN_ORDER_VALIDITY = 5 minutes;

    /// @notice Longest time an order may stay valid for
    uint256 internal constant MAX_ORDER_VALIDITY = 30 minutes;

    /// @notice The cash leg of the account, also the unit of account for every valuation
    IERC20 public asset;

    /// @notice Registry holding the token allowlist and the account wide limits
    IStockAccountRegistry public stockRegistry;

    /// @notice EIP-712 domain separator read from the CoW settlement contract at initialization
    bytes32 public cowDomainSeparator;

    /// @notice CoW contract that pulls tokens out of this account when an order settles
    address public cowVaultRelayer;

    /// @notice Share of the account targeted to stay in the asset, in basis points
    uint16 public cashTargetBps;

    /// @notice Slippage override in basis points, zero means use the registry cap
    uint16 public accountSlippageBps;

    BasketEntry[] internal _entries;

    /// @notice Address the management fee is paid to
    address public feeRecipient;

    /// @notice Timestamp the fee was last paid at
    uint64 public override lastFeePaid;

    struct InitParams {
        address asset;
        uint16 cashTargetBps;
        address cowSettlement;
        BasketEntry[] entries;
        address feeRecipient;
        address mamoStrategyRegistry;
        address owner;
        address stockRegistry;
        uint256 strategyTypeId;
    }

    modifier onlyBackend() {
        if (msg.sender != mamoStrategyRegistry.getBackendAddress()) revert NotBackend();
        _;
    }

    /**
     * @notice Initializer that sets all the parameters and the initial basket
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        if (params.asset == address(0)) revert ZeroAddress();
        if (params.cowSettlement == address(0)) revert ZeroAddress();
        if (params.feeRecipient == address(0)) revert ZeroAddress();
        if (params.mamoStrategyRegistry == address(0)) revert ZeroAddress();
        if (params.stockRegistry == address(0)) revert ZeroAddress();
        if (params.strategyTypeId == 0) revert StrategyTypeIdNotSet();

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        asset = IERC20(params.asset);
        stockRegistry = IStockAccountRegistry(params.stockRegistry);
        cowDomainSeparator = IGPv2Settlement(params.cowSettlement).domainSeparator();
        cowVaultRelayer = IGPv2Settlement(params.cowSettlement).vaultRelayer();
        feeRecipient = params.feeRecipient;
        lastFeePaid = uint64(block.timestamp);

        _setBasket(params.entries, params.cashTargetBps);
    }

    /**
     * @notice Funds the account with the asset, callable by anyone
     * @param amount The amount of the asset to pull from the caller
     */
    function deposit(uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();

        asset.safeTransferFrom(msg.sender, address(this), amount);
        _checkAccountValue();

        emit Deposit(amount);
    }

    /**
     * @notice Funds the account with an active listed token, callable by anyone
     * @param token The token to pull from the caller
     * @param amount The amount of the token to pull from the caller
     */
    function depositToken(address token, uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        if (stockRegistry.tokenConfig(token).status != IStockAccountRegistry.TokenStatus.Active) {
            revert TokenNotActive(token);
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _checkAccountValue();

        emit DepositToken(token, amount);
    }

    /**
     * @notice Sends a token held by the account to the owner without selling anything
     * @param token The token to send, the asset included
     * @param amount The amount to send
     */
    function withdrawToken(address token, uint256 amount) external override onlyOwner {
        if (_isFeeToken(token)) {
            _payFees(token);
        } else {
            _payFeesFromAny();
        }

        if (amount == 0) revert ZeroAmount();
        if (amount > IERC20(token).balanceOf(address(this))) revert ExceedsBalance(token);

        IERC20(token).safeTransfer(owner(), amount);

        emit WithdrawToken(token, amount);
    }

    /// @notice Sends every balance held by the account to the owner without selling anything
    function withdrawAllInKind() external override onlyOwner {
        _payFeesFromAny();

        address to = owner();

        uint256 assetBalance = asset.balanceOf(address(this));
        if (assetBalance > 0) {
            asset.safeTransfer(to, assetBalance);
            emit WithdrawToken(address(asset), assetBalance);
        }

        address[] memory tokens = stockRegistry.allTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(tokens[i]).safeTransfer(to, balance);
                emit WithdrawToken(tokens[i], balance);
            }
        }
    }

    /**
     * @notice Replaces the target basket
     * @param entries The target weight of each token, tokens are removed by omitting them
     * @param newCashTargetBps The share targeted to stay in the asset, in basis points
     */
    function setBasket(BasketEntry[] calldata entries, uint16 newCashTargetBps) external override onlyOwner {
        _setBasket(entries, newCashTargetBps);
    }

    /**
     * @notice Sets the slippage this account tolerates on swaps
     * @param bps The slippage in basis points, zero to follow the registry cap
     */
    function setAccountSlippage(uint16 bps) external override onlyOwner {
        if (bps > stockRegistry.maxBackendSlippageBps()) revert SlippageExceedsMaximum();

        emit SlippageUpdated(accountSlippageBps, bps);

        accountSlippageBps = bps;
    }

    /**
     * @notice Sets the address the accrued fees are collected to
     * @param newRecipient The new fee recipient
     */
    function setFeeRecipient(address newRecipient) external override onlyBackend {
        if (newRecipient == address(0)) revert ZeroAddress();

        emit FeeRecipientUpdated(feeRecipient, newRecipient);

        feeRecipient = newRecipient;
    }

    /**
     * @notice Grants the CoW vault relayer an unlimited allowance so orders can settle, callable by anyone
     * @param token The asset or a listed token
     */
    function approveCowRelayer(address token) external override {
        if (
            token != address(asset) && stockRegistry.tokenConfig(token).status == IStockAccountRegistry.TokenStatus.None
        ) {
            revert TokenNotListed(token);
        }

        IERC20(token).forceApprove(cowVaultRelayer, type(uint256).max);
    }

    /**
     * @notice Pays the fee accrued since the last payment in one token, callable by anyone
     * @dev A payment the balance cuts short credits only the slice of the period it covers
     * @param token The asset or a listed token that is neither unlisted nor halted
     */
    function payFees(address token) external override {
        _payFees(token);
    }

    /**
     * @notice Accepts a CoW order the backend co-signed that keeps the account in range and prices it fairly
     * @param orderDigest The EIP-712 signing digest derived from the order
     * @param encodedOrder The abi encoded GPv2Order.Data the digest was derived from, and the backend signature over it
     */
    function isValidSignature(bytes32 orderDigest, bytes calldata encodedOrder) external view returns (bytes4) {
        (GPv2Order.Data memory order, bytes memory backendSig) = abi.decode(encodedOrder, (GPv2Order.Data, bytes));

        if (order.hash(cowDomainSeparator) != orderDigest) revert OrderHashMismatch();
        if (!SignatureChecker.isValidSignatureNow(stockRegistry.orderSigner(), orderDigest, backendSig)) {
            revert InvalidBackendSignature();
        }
        if (order.kind != GPv2Order.KIND_SELL) revert OrderMustBeSell();
        if (order.partiallyFillable) revert OrderMustBeFillOrKill();
        if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20 || order.buyTokenBalance != GPv2Order.BALANCE_ERC20) {
            revert OrderBalancesMustBeErc20();
        }
        if (order.receiver != address(this)) revert OrderReceiverMismatch();
        if (order.feeAmount != 0) revert OrderFeeMustBeZero();
        if (order.appData != keccak256(bytes(appDataDocument(address(order.buyToken))))) revert InvalidAppData();
        if (order.validTo < block.timestamp + MIN_ORDER_VALIDITY) revert OrderExpiresTooSoon();
        if (order.validTo > block.timestamp + MAX_ORDER_VALIDITY) revert OrderExpiresTooLate();

        address sellToken = address(order.sellToken);
        address buyToken = address(order.buyToken);
        if (sellToken == buyToken) revert TokensMustDiffer();
        if (order.sellAmount == 0) revert ZeroAmount();

        if (sellToken != address(asset)) {
            IStockAccountRegistry.TokenStatus status = stockRegistry.tokenConfig(sellToken).status;
            bool sellable = status == IStockAccountRegistry.TokenStatus.Active
                || status == IStockAccountRegistry.TokenStatus.SellOnly;

            if (!sellable) revert SellTokenNotSellable(sellToken);
        }

        if (buyToken != address(asset)) {
            if (stockRegistry.tokenConfig(buyToken).status != IStockAccountRegistry.TokenStatus.Active) {
                revert BuyTokenNotActive(buyToken);
            }
        }

        if (order.sellAmount > IERC20(sellToken).balanceOf(address(this))) revert SellExceedsBalance();

        uint256 expectedOut = stockRegistry.priceChecker().getExpectedOut(order.sellAmount, sellToken, buyToken);
        if (expectedOut == 0) revert PriceCheckFailed();

        uint256 slip = getAccountSlippage();
        if (slip > TOTAL_BPS) revert SlippageExceedsMaximum();
        if (order.buyAmount < (expectedOut * (TOTAL_BPS - slip)) / TOTAL_BPS) revert PriceCheckFailed();

        _checkRange(sellToken, buyToken, order.sellAmount, order.buyAmount, expectedOut);

        return MAGIC_VALUE;
    }

    function _checkRange(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 expectedOut
    ) internal view {
        (address[] memory tokens, uint256[] memory values, uint256 nav) = _valuation();

        uint256 sellHeld = _heldValue(tokens, values, sellToken);
        uint256 available = IERC20(sellToken).balanceOf(address(this));
        uint256 sellValue = sellToken == address(asset) ? sellAmount : (sellHeld * sellAmount) / available;
        uint256 buyValue = (sellValue * buyAmount) / expectedOut;

        uint256 navAfter = nav - sellValue + buyValue;
        uint256 dev = stockRegistry.maxDeviationBps();

        uint256 sellWeight = navAfter == 0 ? 0 : ((sellHeld - sellValue) * TOTAL_BPS) / navAfter;
        uint256 buyHeld = _heldValue(tokens, values, buyToken);
        uint256 buyWeight = navAfter == 0 ? 0 : ((buyHeld + buyValue) * TOTAL_BPS) / navAfter;

        if (sellWeight + dev < _targetOf(sellToken)) revert SellLeavesTokenBelowRange(sellToken);
        if (buyWeight > _targetOf(buyToken) + dev) revert BuyLeavesTokenAboveRange(buyToken);
    }

    function _valuation() internal view returns (address[] memory tokens, uint256[] memory values, uint256 nav) {
        tokens = stockRegistry.allTokens();
        values = new uint256[](tokens.length);
        nav = asset.balanceOf(address(this));

        ISlippagePriceChecker checker = stockRegistry.priceChecker();

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance == 0) {
                continue;
            }

            if (stockRegistry.tokenConfig(tokens[i]).status == IStockAccountRegistry.TokenStatus.Halted) {
                continue;
            }

            values[i] = checker.getExpectedOut(balance, tokens[i], address(asset));
            nav += values[i];
        }
    }

    function _heldValue(address[] memory tokens, uint256[] memory values, address token)
        internal
        view
        returns (uint256)
    {
        if (token == address(asset)) {
            return asset.balanceOf(address(this));
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) {
                return values[i];
            }
        }

        return 0;
    }

    function _targetOf(address token) internal view returns (uint16) {
        return token == address(asset) ? cashTargetBps : _targetBps(token);
    }

    /**
     * @notice Sends the asset to the owner, selling positions pro rata when the idle balance falls short
     * @param usdcAmount The amount of the asset the owner receives
     * @param maxSlippageBps The slippage each sell leg tolerates, in basis points
     */
    function withdraw(uint256 usdcAmount, uint16 maxSlippageBps) external override onlyOwner {
        if (usdcAmount == 0) revert ZeroAmount();
        if (maxSlippageBps > stockRegistry.maxWithdrawSlippageBps()) revert SlippageExceedsMaximum();

        uint256 idle = asset.balanceOf(address(this));
        uint256 sold;

        if (idle < usdcAmount) {
            (address[] memory tokens, uint256[] memory amounts,,) = _planSells(usdcAmount - idle, maxSlippageBps);
            sold = _executeSells(tokens, amounts, maxSlippageBps);
        }

        _payFees(address(asset));

        if (asset.balanceOf(address(this)) < usdcAmount) revert InsufficientProceeds();

        asset.safeTransfer(owner(), usdcAmount);

        emit Withdraw(usdcAmount, sold);
    }

    /**
     * @notice Sells every position that is not halted and sends all the asset to the owner
     * @param maxSlippageBps The slippage each sell leg tolerates, in basis points
     */
    function withdrawAll(uint16 maxSlippageBps) external override onlyOwner {
        if (maxSlippageBps > stockRegistry.maxWithdrawSlippageBps()) revert SlippageExceedsMaximum();

        (address[] memory tokens, uint256[] memory balances) = _sellable();
        uint256 sold = _executeSells(tokens, balances, maxSlippageBps);

        _payFees(address(asset));

        uint256 usdcOut = asset.balanceOf(address(this));
        if (usdcOut == 0) revert EmptyBalance();

        asset.safeTransfer(owner(), usdcOut);

        emit Withdraw(usdcOut, sold);
    }

    /**
     * @notice The sells a withdrawal of this size would execute, without executing them
     * @param usdcAmount The amount of the asset the owner would receive
     * @param maxSlippageBps The slippage each sell leg would tolerate, in basis points
     */
    function previewWithdraw(uint256 usdcAmount, uint16 maxSlippageBps)
        external
        view
        override
        returns (address[] memory tokensToSell, uint256[] memory amounts, uint256 referenceValue, uint256 minProceeds)
    {
        uint256 idle = asset.balanceOf(address(this));
        if (idle >= usdcAmount) {
            return (new address[](0), new uint256[](0), 0, 0);
        }

        return _planSells(usdcAmount - idle, maxSlippageBps);
    }

    /// @notice Value of everything the account holds, in asset units, at registry reference prices
    function getNAV() public view override returns (uint256 valueUsdc) {
        (,, valueUsdc) = _valuation();
    }

    /// @notice Current and target weight of every listed token, in basis points of the account value
    function getWeights()
        external
        view
        override
        returns (address[] memory tokens, uint256[] memory currentBps, uint256[] memory targetBps)
    {
        uint256[] memory values;
        uint256 nav;
        (tokens, values, nav) = _valuation();

        currentBps = new uint256[](tokens.length);
        targetBps = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            currentBps[i] = nav == 0 ? 0 : (values[i] * TOTAL_BPS) / nav;
            targetBps[i] = _targetBps(tokens[i]);
        }
    }

    /// @notice The target basket and the cash target
    function getBasket() external view override returns (BasketEntry[] memory entries, uint16) {
        return (_entries, cashTargetBps);
    }

    /// @notice The listed tokens this account currently holds a balance of
    function heldTokens() external view override returns (address[] memory) {
        address[] memory tokens = stockRegistry.allTokens();
        uint256 count;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (IERC20(tokens[i]).balanceOf(address(this)) > 0) {
                count++;
            }
        }

        address[] memory held = new address[](count);
        uint256 next;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (IERC20(tokens[i]).balanceOf(address(this)) > 0) {
                held[next++] = tokens[i];
            }
        }

        return held;
    }

    /// @notice The fee value this account owes right now, in asset units
    function feeDue() public view override returns (uint256) {
        return _feeDue(block.timestamp - lastFeePaid);
    }

    /// @notice The amount of a token that settles the fee owed right now
    /// @param token The asset or a listed token
    function feeDueIn(address token) external view override returns (uint256) {
        return _feeAmount(token, feeDue());
    }

    /// @notice The CoW app data document, carrying the post-hook that pays the fee, orders must reference
    /// @param feeToken The token the post-hook collects the fee in
    function appDataDocument(address feeToken) public view override returns (string memory) {
        string memory callData =
            string.concat("0x", _bytesToHexString(abi.encodeWithSelector(this.payFees.selector, feeToken)));

        return string(
            abi.encodePacked(
                '{"appCode":"Mamo","metadata":{"hooks":{"post":[{"callData":"',
                callData,
                '","gasLimit":"',
                Strings.toString(HOOK_GAS_LIMIT),
                '","target":"',
                Strings.toHexString(uint160(address(this)), 20),
                '"}],"version":"0.1.0"}},"version":"1.3.0"}'
            )
        );
    }

    /// @notice Hash of the app data document an order collecting the fee in this token must carry
    /// @param feeToken The token the post-hook collects the fee in
    function appDataHash(address feeToken) external view override returns (bytes32) {
        return keccak256(bytes(appDataDocument(feeToken)));
    }

    /// @notice The slippage that applies to this account, capped by the registry
    function getAccountSlippage() public view override returns (uint16) {
        uint16 cap = stockRegistry.maxBackendSlippageBps();
        return accountSlippageBps == 0 || accountSlippageBps > cap ? cap : accountSlippageBps;
    }

    function _setBasket(BasketEntry[] calldata entries, uint16 newCashTargetBps) internal {
        if (entries.length > stockRegistry.maxPositions()) revert TooManyPositions();

        uint16 minTargetBps = stockRegistry.minTargetBps();
        uint256 total;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].targetBps < minTargetBps) revert WeightBelowMinimum(entries[i].token);
            if (stockRegistry.tokenConfig(entries[i].token).status != IStockAccountRegistry.TokenStatus.Active) {
                revert TokenNotActive(entries[i].token);
            }

            for (uint256 j = 0; j < i; j++) {
                if (entries[j].token == entries[i].token) revert DuplicateToken(entries[i].token);
            }

            total += entries[i].targetBps;
        }

        if (total + newCashTargetBps != TOTAL_BPS) revert WeightsMustTotal(total + newCashTargetBps);

        delete _entries;

        for (uint256 i = 0; i < entries.length; i++) {
            _entries.push(entries[i]);
        }

        cashTargetBps = newCashTargetBps;

        emit BasketUpdated(entries, newCashTargetBps);
    }

    function _checkAccountValue() internal view {
        uint256 nav = getNAV();

        if (nav < stockRegistry.minStrategyDeposit()) revert AccountBelowMinimum(nav);
        if (nav > stockRegistry.maxStrategyDeposit()) revert DepositCapExceeded(nav);
    }

    function _payFees(address token) internal {
        uint256 elapsed = block.timestamp - lastFeePaid;
        if (elapsed == 0) {
            return;
        }

        if (!_isFeeToken(token)) revert FeeTokenNotAllowed(token);

        uint256 due = _feeDue(elapsed);
        if (due == 0) {
            lastFeePaid = uint64(block.timestamp);
            return;
        }

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NoBalanceForFee(token);

        uint256 full = _feeAmount(token, due);
        if (full == 0) revert FeeRoundsToZero(token);

        uint256 amount = full > balance ? balance : full;
        uint256 credited = amount == full ? elapsed : (elapsed * amount) / full;

        lastFeePaid = uint64(lastFeePaid + credited);

        IERC20(token).safeTransfer(feeRecipient, amount);

        emit FeesPaid(credited, token, amount);
    }

    function _isFeeToken(address token) internal view returns (bool) {
        if (token == address(asset)) return true;

        IStockAccountRegistry.TokenStatus status = stockRegistry.tokenConfig(token).status;

        return status != IStockAccountRegistry.TokenStatus.None && status != IStockAccountRegistry.TokenStatus.Halted;
    }

    function _payFeesFromAny() internal {
        if (asset.balanceOf(address(this)) > 0) {
            return _payFees(address(asset));
        }

        address[] memory tokens = stockRegistry.allTokens();

        for (uint256 i = 0; i < tokens.length; i++) {
            if (_isSellable(tokens[i])) {
                return _payFees(tokens[i]);
            }
        }

        lastFeePaid = uint64(block.timestamp);
    }

    function _feeDue(uint256 elapsed) internal view returns (uint256) {
        return (getNAV() * stockRegistry.managementFeeBps() * elapsed) / (uint256(TOTAL_BPS) * 365 days);
    }

    function _feeAmount(address token, uint256 due) internal view returns (uint256) {
        if (due == 0 || token == address(asset)) {
            return due;
        }

        return stockRegistry.priceChecker().getExpectedOut(due, address(asset), token);
    }

    function _bytesToHexString(bytes memory data) internal pure returns (string memory) {
        bytes memory hexString = new bytes(data.length * 2);
        bytes memory hexChars = "0123456789abcdef";

        for (uint256 i = 0; i < data.length; i++) {
            uint8 value = uint8(data[i]);
            hexString[i * 2] = hexChars[value >> 4];
            hexString[i * 2 + 1] = hexChars[value & 0xf];
        }

        return string(hexString);
    }

    function _targetBps(address token) internal view returns (uint16) {
        for (uint256 i = 0; i < _entries.length; i++) {
            if (_entries[i].token == token) {
                return _entries[i].targetBps;
            }
        }

        return 0;
    }

    function _sellable() internal view returns (address[] memory tokens, uint256[] memory balances) {
        address[] memory listed = stockRegistry.allTokens();
        uint256 count;

        for (uint256 i = 0; i < listed.length; i++) {
            if (_isSellable(listed[i])) {
                count++;
            }
        }

        tokens = new address[](count);
        balances = new uint256[](count);
        uint256 next;

        for (uint256 i = 0; i < listed.length; i++) {
            if (_isSellable(listed[i])) {
                tokens[next] = listed[i];
                balances[next++] = IERC20(listed[i]).balanceOf(address(this));
            }
        }
    }

    function _isSellable(address token) internal view returns (bool) {
        return IERC20(token).balanceOf(address(this)) > 0
            && stockRegistry.tokenConfig(token).status != IStockAccountRegistry.TokenStatus.Halted;
    }

    function _planSells(uint256 shortfall, uint16 maxSlippageBps)
        internal
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256 referenceValue, uint256 minProceeds)
    {
        (address[] memory sellable, uint256[] memory balances) = _sellable();
        ISlippagePriceChecker priceChecker = stockRegistry.priceChecker();

        uint256 total;
        for (uint256 i = 0; i < sellable.length; i++) {
            total += priceChecker.getExpectedOut(balances[i], sellable[i], address(asset));
        }

        if (shortfall > total) revert InsufficientBalance();

        if (total == 0) {
            return (new address[](0), new uint256[](0), 0, 0);
        }

        uint256 target = (shortfall * TOTAL_BPS) / (TOTAL_BPS - maxSlippageBps);
        if (target > total) {
            target = total;
        }

        uint256[] memory planned = new uint256[](sellable.length);
        uint256 count;

        for (uint256 i = 0; i < sellable.length; i++) {
            planned[i] = (balances[i] * target) / total;
            if (planned[i] > 0) {
                count++;
            }
        }

        tokens = new address[](count);
        amounts = new uint256[](count);
        uint256 next;

        for (uint256 i = 0; i < sellable.length; i++) {
            if (planned[i] == 0) {
                continue;
            }

            uint256 legValue = priceChecker.getExpectedOut(planned[i], sellable[i], address(asset));
            referenceValue += legValue;
            minProceeds += (legValue * (TOTAL_BPS - maxSlippageBps)) / TOTAL_BPS;

            tokens[next] = sellable[i];
            amounts[next++] = planned[i];
        }
    }

    function _executeSells(address[] memory tokens, uint256[] memory amounts, uint16 maxSlippageBps)
        internal
        returns (uint256 sold)
    {
        ISlippagePriceChecker priceChecker = stockRegistry.priceChecker();

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 legValue = priceChecker.getExpectedOut(amounts[i], tokens[i], address(asset));
            sold += _sell(tokens[i], amounts[i], (legValue * (TOTAL_BPS - maxSlippageBps)) / TOTAL_BPS);
        }
    }

    function _sell(address token, uint256 amountIn, uint256 minOut) internal returns (uint256 amountOut) {
        ISwapRouter router = stockRegistry.aerodromeRouter();

        IERC20(token).forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(asset),
                tickSpacing: IPool(stockRegistry.tokenConfig(token).pool).tickSpacing(),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
