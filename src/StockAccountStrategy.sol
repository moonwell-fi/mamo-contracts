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

/**
 * @title StockAccountStrategy
 * @notice A per-user account holding a cash asset and tokenized stock positions against a target basket
 * @dev This contract is designed to be used as an implementation for proxies
 */
contract StockAccountStrategy is BaseStrategy, IStockAccountStrategy {
    using GPv2Order for GPv2Order.Data;
    using SafeERC20 for IERC20;

    uint16 internal constant TOTAL_BPS = 10_000;

    uint16 public constant MAX_MANAGEMENT_FEE_BPS = 200;

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

    /// @notice Annual management fee charged on the account value, in basis points
    uint16 public managementFeeBps;

    /// @notice Address the accrued fee slivers are collected to
    address public feeRecipient;

    /// @notice Timestamp fees were last accrued at
    uint256 public lastFeeAccrual;

    /// @notice Fee set aside per token, held by the account until it is collected
    mapping(address => uint256) public override feeOwed;

    struct InitParams {
        address asset;
        uint16 cashTargetBps;
        address cowSettlement;
        BasketEntry[] entries;
        address feeRecipient;
        address mamoStrategyRegistry;
        uint16 managementFeeBps;
        address owner;
        address stockRegistry;
        uint256 strategyTypeId;
    }

    modifier onlyBackend() {
        require(msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not backend");
        _;
    }

    /**
     * @notice Initializer that sets all the parameters and the initial basket
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.asset != address(0), "Invalid asset address");
        require(params.cowSettlement != address(0), "Invalid settlement address");
        require(params.feeRecipient != address(0), "Invalid fee recipient address");
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.managementFeeBps <= MAX_MANAGEMENT_FEE_BPS, "Fee exceeds maximum");
        require(params.stockRegistry != address(0), "Invalid stock registry address");
        require(params.strategyTypeId != 0, "Strategy type id not set");

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        asset = IERC20(params.asset);
        stockRegistry = IStockAccountRegistry(params.stockRegistry);
        cowDomainSeparator = IGPv2Settlement(params.cowSettlement).domainSeparator();
        cowVaultRelayer = IGPv2Settlement(params.cowSettlement).vaultRelayer();
        feeRecipient = params.feeRecipient;
        managementFeeBps = params.managementFeeBps;
        lastFeeAccrual = block.timestamp;

        _setBasket(params.entries, params.cashTargetBps);
    }

    /**
     * @notice Funds the account with the asset, callable by anyone
     * @param amount The amount of the asset to pull from the caller
     */
    function deposit(uint256 amount) external override {
        _accrueFees();

        require(amount > 0, "Amount must be greater than 0");

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
        _accrueFees();

        require(amount > 0, "Amount must be greater than 0");
        require(stockRegistry.tokenConfig(token).status == IStockAccountRegistry.TokenStatus.Active, "Token not active");

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
        _accrueFees();

        require(amount > 0, "Amount must be greater than 0");
        require(amount <= _available(token), "Amount exceeds available balance");

        IERC20(token).safeTransfer(owner(), amount);

        emit WithdrawToken(token, amount);
    }

    /// @notice Sends every balance held by the account to the owner without selling anything
    function withdrawAllInKind() external override onlyOwner {
        _accrueFees();

        address to = owner();

        uint256 assetBalance = _available(address(asset));
        if (assetBalance > 0) {
            asset.safeTransfer(to, assetBalance);
            emit WithdrawToken(address(asset), assetBalance);
        }

        address[] memory tokens = stockRegistry.allTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = _available(tokens[i]);
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
        _accrueFees();
        _setBasket(entries, newCashTargetBps);
    }

    /**
     * @notice Sets the slippage this account tolerates on swaps
     * @param bps The slippage in basis points, zero to follow the registry cap
     */
    function setAccountSlippage(uint16 bps) external override onlyOwner {
        require(bps <= stockRegistry.maxBackendSlippageBps(), "Slippage exceeds maximum");

        emit SlippageUpdated(accountSlippageBps, bps);

        accountSlippageBps = bps;
    }

    /**
     * @notice Sets the address the accrued fees are collected to
     * @param newRecipient The new fee recipient
     */
    function setFeeRecipient(address newRecipient) external override onlyBackend {
        require(newRecipient != address(0), "Invalid fee recipient address");

        emit FeeRecipientUpdated(feeRecipient, newRecipient);

        feeRecipient = newRecipient;
    }

    /**
     * @notice Grants the CoW vault relayer an unlimited allowance so orders can settle, callable by anyone
     * @param token The asset or a listed token
     */
    function approveCowRelayer(address token) external override {
        require(
            token == address(asset) || stockRegistry.tokenConfig(token).status != IStockAccountRegistry.TokenStatus.None,
            "Token not listed"
        );

        IERC20(token).forceApprove(cowVaultRelayer, type(uint256).max);
    }

    /// @notice Sets aside the fee owed on every token held since the last accrual, callable by anyone
    function accrueManagementFee() external override {
        _accrueFees();
    }

    /**
     * @notice Sends the fee set aside on a token to the fee recipient, callable by anyone
     * @param token The token to collect the fee of
     */
    function collectFees(address token) external override {
        _accrueFees();

        uint256 amount = feeOwed[token];
        require(amount > 0, "Nothing to collect");

        feeOwed[token] = 0;
        IERC20(token).safeTransfer(feeRecipient, amount);

        emit FeesCollected(token, amount);
    }

    /**
     * @notice Accepts a CoW order that keeps the account inside the basket ranges and prices it fairly
     * @param orderDigest The EIP-712 signing digest derived from the order
     * @param encodedOrder The abi encoded GPv2Order.Data the digest was derived from
     */
    function isValidSignature(bytes32 orderDigest, bytes calldata encodedOrder) external view returns (bytes4) {
        GPv2Order.Data memory order = abi.decode(encodedOrder, (GPv2Order.Data));

        require(order.hash(cowDomainSeparator) == orderDigest, "Order hash does not match the provided digest");
        require(order.kind == GPv2Order.KIND_SELL, "Order must be a sell order");
        require(!order.partiallyFillable, "Order must be fill-or-kill");
        require(
            order.sellTokenBalance == GPv2Order.BALANCE_ERC20 && order.buyTokenBalance == GPv2Order.BALANCE_ERC20,
            "Order balances must be ERC20"
        );
        require(order.receiver == address(this), "Order receiver must be this strategy");
        require(order.feeAmount == 0, "Fee amount must be zero");
        require(order.appData == stockRegistry.requiredAppDataHash(), "Invalid app data");
        require(order.validTo >= block.timestamp + MIN_ORDER_VALIDITY, "Order expires too soon");
        require(order.validTo <= block.timestamp + MAX_ORDER_VALIDITY, "Order expires too far in the future");

        address sellToken = address(order.sellToken);
        address buyToken = address(order.buyToken);
        require(sellToken != buyToken, "Tokens must differ");

        if (sellToken != address(asset)) {
            IStockAccountRegistry.TokenStatus status = stockRegistry.tokenConfig(sellToken).status;
            require(
                status == IStockAccountRegistry.TokenStatus.Active
                    || status == IStockAccountRegistry.TokenStatus.SellOnly,
                "Sell token not sellable"
            );
        }

        if (buyToken != address(asset)) {
            require(
                stockRegistry.tokenConfig(buyToken).status == IStockAccountRegistry.TokenStatus.Active,
                "Buy token not active"
            );
        }

        _checkRange(
            sellToken,
            buyToken,
            _referenceValue(sellToken, order.sellAmount),
            _referenceValue(buyToken, order.buyAmount)
        );

        require(
            stockRegistry.priceChecker().checkPrice(
                order.sellAmount, sellToken, buyToken, order.buyAmount, getAccountSlippage()
            ),
            "Price check failed"
        );

        return MAGIC_VALUE;
    }

    function _checkRange(address sellToken, address buyToken, uint256 sellValue, uint256 buyValue) internal view {
        uint256 sellHeld = _holdingValue(sellToken);
        require(sellValue <= sellHeld, "Sell amount exceeds balance");

        uint256 navAfter = getNAV() - sellValue + buyValue;
        uint256 dev = stockRegistry.maxDeviationBps();

        uint256 sellWeight = navAfter == 0 ? 0 : ((sellHeld - sellValue) * TOTAL_BPS) / navAfter;
        uint256 buyWeight = navAfter == 0 ? 0 : ((_holdingValue(buyToken) + buyValue) * TOTAL_BPS) / navAfter;

        require(sellWeight + dev >= _targetOf(sellToken), "Sell leaves token below range");
        require(buyWeight <= _targetOf(buyToken) + dev, "Buy leaves token above range");
    }

    function _holdingValue(address token) internal view returns (uint256) {
        return _referenceValue(token, _available(token));
    }

    function _referenceValue(address token, uint256 amount) internal view returns (uint256) {
        if (token == address(asset) || amount == 0) {
            return amount;
        }

        return stockRegistry.priceChecker().getExpectedOut(amount, token, address(asset));
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
        _accrueFees();

        require(usdcAmount > 0, "Amount must be greater than 0");
        require(maxSlippageBps <= stockRegistry.maxWithdrawSlippageBps(), "Slippage exceeds maximum");

        uint256 idle = _available(address(asset));
        uint256 sold;

        if (idle < usdcAmount) {
            (address[] memory tokens, uint256[] memory amounts,,) = _planSells(usdcAmount - idle, maxSlippageBps);
            sold = _executeSells(tokens, amounts, maxSlippageBps);

            require(_available(address(asset)) >= usdcAmount, "Insufficient proceeds");
        }

        asset.safeTransfer(owner(), usdcAmount);

        emit Withdraw(usdcAmount, sold);
    }

    /**
     * @notice Sells every position that is not halted and sends all the asset to the owner
     * @param maxSlippageBps The slippage each sell leg tolerates, in basis points
     */
    function withdrawAll(uint16 maxSlippageBps) external override onlyOwner {
        _accrueFees();

        require(maxSlippageBps <= stockRegistry.maxWithdrawSlippageBps(), "Slippage exceeds maximum");

        (address[] memory tokens, uint256[] memory balances) = _sellable();
        uint256 sold = _executeSells(tokens, balances, maxSlippageBps);

        uint256 usdcOut = _available(address(asset));
        require(usdcOut > 0, "Empty balance");

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
        uint256 idle = _available(address(asset));
        if (idle >= usdcAmount) {
            return (new address[](0), new uint256[](0), 0, 0);
        }

        return _planSells(usdcAmount - idle, maxSlippageBps);
    }

    /// @notice Value of everything the account holds, in asset units, at registry reference prices
    function getNAV() public view override returns (uint256 valueUsdc) {
        valueUsdc = _available(address(asset));

        address[] memory tokens = stockRegistry.allTokens();
        ISlippagePriceChecker priceChecker = stockRegistry.priceChecker();

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = _available(tokens[i]);
            if (balance > 0) {
                valueUsdc += priceChecker.getExpectedOut(balance, tokens[i], address(asset));
            }
        }
    }

    /// @notice Current and target weight of every listed token, in basis points of the account value
    function getWeights()
        external
        view
        override
        returns (address[] memory tokens, uint256[] memory currentBps, uint256[] memory targetBps)
    {
        tokens = stockRegistry.allTokens();
        currentBps = new uint256[](tokens.length);
        targetBps = new uint256[](tokens.length);

        ISlippagePriceChecker priceChecker = stockRegistry.priceChecker();
        uint256[] memory values = new uint256[](tokens.length);
        uint256 nav = _available(address(asset));

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = _available(tokens[i]);
            if (balance > 0) {
                values[i] = priceChecker.getExpectedOut(balance, tokens[i], address(asset));
                nav += values[i];
            }
        }

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
            if (_available(tokens[i]) > 0) {
                count++;
            }
        }

        address[] memory held = new address[](count);
        uint256 next;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (_available(tokens[i]) > 0) {
                held[next++] = tokens[i];
            }
        }

        return held;
    }

    /// @notice The slippage that applies to this account, capped by the registry
    function getAccountSlippage() public view override returns (uint16) {
        uint16 cap = stockRegistry.maxBackendSlippageBps();
        return accountSlippageBps == 0 || accountSlippageBps > cap ? cap : accountSlippageBps;
    }

    function _setBasket(BasketEntry[] calldata entries, uint16 newCashTargetBps) internal {
        require(entries.length <= stockRegistry.maxPositions(), "Too many positions");

        uint16 minTargetBps = stockRegistry.minTargetBps();
        uint256 total;

        for (uint256 i = 0; i < entries.length; i++) {
            require(entries[i].targetBps >= minTargetBps, "Weight below minimum");
            require(
                stockRegistry.tokenConfig(entries[i].token).status == IStockAccountRegistry.TokenStatus.Active,
                "Token not active"
            );

            for (uint256 j = 0; j < i; j++) {
                require(entries[j].token != entries[i].token, "Duplicate token");
            }

            total += entries[i].targetBps;
        }

        require(total + newCashTargetBps == TOTAL_BPS, "Weights must total 10000");

        delete _entries;

        for (uint256 i = 0; i < entries.length; i++) {
            _entries.push(entries[i]);
        }

        cashTargetBps = newCashTargetBps;

        emit BasketUpdated(entries, newCashTargetBps);
    }

    function _checkAccountValue() internal view {
        uint256 nav = getNAV();

        require(nav >= stockRegistry.minStrategyDeposit(), "Account below minimum");
        require(nav <= stockRegistry.maxStrategyDeposit(), "Deposit cap exceeded");
    }

    function _available(address token) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 owed = feeOwed[token];

        return balance > owed ? balance - owed : 0;
    }

    function _accrueFees() internal {
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        if (elapsed == 0) {
            return;
        }

        address[] memory tokens = stockRegistry.allTokens();
        uint256 total = _accrueToken(address(asset), elapsed);

        for (uint256 i = 0; i < tokens.length; i++) {
            total += _accrueToken(tokens[i], elapsed);
        }

        if (total == 0) {
            return;
        }

        lastFeeAccrual = block.timestamp;

        emit FeesAccrued(elapsed);
    }

    function _accrueToken(address token, uint256 elapsed) internal returns (uint256 accrued) {
        accrued = (_available(token) * managementFeeBps * elapsed) / (uint256(TOTAL_BPS) * 365 days);

        if (accrued > 0) {
            feeOwed[token] += accrued;
        }
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
                balances[next++] = _available(listed[i]);
            }
        }
    }

    function _isSellable(address token) internal view returns (bool) {
        return
            _available(token) > 0 && stockRegistry.tokenConfig(token).status != IStockAccountRegistry.TokenStatus.Halted;
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

        require(shortfall <= total, "Insufficient balance");

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
