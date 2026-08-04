// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";

import {IERC4626} from "@interfaces/IERC4626.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {IUniswapV3SwapRouter} from "@contracts/robinhood/interfaces/IUniswapV3SwapRouter.sol";

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StockBasketStrategy
 * @notice Per-user strategy holding a curated basket of tokenized stocks plus a USDG yield sleeve
 * @notice IMPORTANT: This contract does not support fee-on-transfer tokens.
 * @dev The differentiated Robinhood Chain product: "own a slice of the market, and the idle half earns".
 *      Position = one ERC4626 yield sleeve on the base asset (e.g. a Morpho USDG vault) + N tokenized
 *      stocks at basis-point target weights. The backend adjusts weights and rebalances; every swap is
 *      routed through a Uniswap V3 style router with an oracle-derived minimum out, so the agent decides
 *      WHEN to trade but can never trade at a worse price than the oracle-bounded slippage allows.
 *
 *      Scoping mirrors the Boosted USDC governance model:
 *      - The stock set and the yield sleeve are fixed at initialization (factory/admin decision).
 *      - The total stock allocation is bounded by maxTotalStockBps, set at initialization — the backend
 *        can tilt within the band but can never push equity exposure past the product's mandate.
 *
 *      Deposits land in the yield sleeve first ("deposit is cheap"); the agent's next rebalance buys the
 *      basket to target. Withdrawals drain idle + sleeve first and only sell stocks when needed, so the
 *      common exit path never touches equity markets.
 */
contract StockBasketStrategy is Initializable, UUPSUpgradeable, BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice Total basis points used for weight calculations (100%)
    uint256 public constant WEIGHT_TOTAL = 10000;

    /// @notice The maximum allowed slippage in basis points
    uint256 public constant MAX_SLIPPAGE_IN_BPS = 2500;

    /// @notice Maximum number of stocks in a basket, keeps loops bounded
    uint256 public constant MAX_STOCKS = 12;

    /// @notice The base asset (e.g. USDG)
    IERC20 public token;

    /// @notice The ERC4626 yield sleeve on the base asset
    IERC4626 public yieldVault;

    /// @notice The curated stock tokens, fixed at initialization
    address[] public stockTokens;

    /// @notice Target basis-point weight per stock, parallel to stockTokens
    uint256[] public stockWeightsBps;

    /// @notice Upper bound on the summed stock weights, fixed at initialization
    uint256 public maxTotalStockBps;

    /// @notice Oracle-based price checker used to value stocks and bound swaps
    ISlippagePriceChecker public slippagePriceChecker;

    /// @notice Uniswap V3 style router used for basket trades
    IUniswapV3SwapRouter public dexRouter;

    /// @notice Uniswap V3 fee tier used for stock/base-asset pools
    uint24 public poolFee;

    /// @notice The allowed slippage for basket trades in basis points
    uint256 public allowedSlippageInBps;

    event Deposit(address indexed asset, uint256 amount);
    event Withdraw(address indexed asset, uint256 amount);
    event WeightsUpdated(uint256[] stockWeightsBps);
    event Rebalanced(uint256 navBefore, uint256 navAfter);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event StockSold(address indexed stock, uint256 amountIn, uint256 amountOut);
    event StockBought(address indexed stock, uint256 amountIn, uint256 amountOut);

    /// @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address mamoStrategyRegistry;
        address token;
        address yieldVault;
        address slippagePriceChecker;
        address dexRouter;
        uint256 strategyTypeId;
        address owner;
        uint256 allowedSlippageInBps;
        uint256 maxTotalStockBps;
        uint24 poolFee;
        address[] stockTokens;
        uint256[] stockWeightsBps;
    }

    /**
     * @notice Restricts function access to the backend address only
     */
    modifier onlyBackend() {
        require(msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not backend");
        _;
    }

    // ==================== INITIALIZER ====================

    /**
     * @notice Initializer function that sets all the parameters
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.token != address(0), "Invalid token address");
        require(params.yieldVault != address(0), "Invalid yieldVault address");
        require(params.slippagePriceChecker != address(0), "Invalid slippagePriceChecker address");
        require(params.dexRouter != address(0), "Invalid dexRouter address");
        require(params.strategyTypeId != 0, "Strategy type id not set");
        require(params.allowedSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");
        require(params.maxTotalStockBps <= WEIGHT_TOTAL, "Max stock bps exceeds total");
        require(IERC4626(params.yieldVault).asset() == params.token, "Vault asset mismatch");
        require(params.stockTokens.length > 0, "Empty stock set");
        require(params.stockTokens.length <= MAX_STOCKS, "Too many stocks");

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        token = IERC20(params.token);
        yieldVault = IERC4626(params.yieldVault);
        slippagePriceChecker = ISlippagePriceChecker(params.slippagePriceChecker);
        dexRouter = IUniswapV3SwapRouter(params.dexRouter);
        allowedSlippageInBps = params.allowedSlippageInBps;
        maxTotalStockBps = params.maxTotalStockBps;
        poolFee = params.poolFee;

        for (uint256 i = 0; i < params.stockTokens.length; i++) {
            require(params.stockTokens[i] != address(0), "Invalid stock address");
            require(params.stockTokens[i] != params.token, "Stock cannot be base asset");

            for (uint256 j = 0; j < i; j++) {
                require(params.stockTokens[j] != params.stockTokens[i], "Duplicate stock");
            }
        }
        stockTokens = params.stockTokens;

        _setStockWeights(params.stockWeightsBps);
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @notice Sets a new slippage tolerance value
     * @param _newSlippageInBps The new slippage tolerance in basis points
     */
    function setSlippage(uint256 _newSlippageInBps) external onlyOwner {
        require(_newSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");

        emit SlippageUpdated(allowedSlippageInBps, _newSlippageInBps);
        allowedSlippageInBps = _newSlippageInBps;
    }

    /**
     * @notice Withdraws base-asset value from the strategy
     * @dev Drains idle balance, then the yield sleeve, and only then sells stocks pro-rata. Selling
     *      through the router is oracle-bounded; if equity pools are stale (markets closed) the sale —
     *      and only then the withdrawal — reverts rather than filling at a bad price.
     * @param amount The amount of base asset to withdraw
     */
    function withdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");

        uint256 idleBalance = token.balanceOf(address(this));

        if (idleBalance < amount) {
            uint256 remaining = amount - idleBalance;

            // pull from the yield sleeve first
            // NOTE: Morpho Vault V2 (the intended sleeve) returns 0 from maxWithdraw by design, so
            // available liquidity is derived from the share balance instead of the max* views
            uint256 sleeveAvailable = yieldVault.convertToAssets(yieldVault.balanceOf(address(this)));
            if (sleeveAvailable > 0) {
                uint256 fromSleeve = remaining > sleeveAvailable ? sleeveAvailable : remaining;
                yieldVault.withdraw(fromSleeve, address(this), address(this));
                remaining -= fromSleeve;
            }

            // sell stocks pro-rata for whatever is still missing
            if (remaining > 0) {
                _sellStocksForExactBase(remaining);
            }
        }

        require(token.balanceOf(address(this)) >= amount, "Withdrawal failed: insufficient funds");

        token.safeTransfer(msg.sender, amount);

        emit Withdraw(address(token), amount);
    }

    /**
     * @notice Withdraws everything: sells the full basket and drains the sleeve
     */
    function withdrawAll() external onlyOwner {
        for (uint256 i = 0; i < stockTokens.length; i++) {
            uint256 stockBalance = IERC20(stockTokens[i]).balanceOf(address(this));
            if (stockBalance > 0) {
                _swap(stockTokens[i], address(token), stockBalance);
                emit StockSold(stockTokens[i], stockBalance, 0);
            }
        }

        uint256 sleeveShares = yieldVault.balanceOf(address(this));
        if (sleeveShares > 0) {
            yieldVault.redeem(sleeveShares, address(this), address(this));
        }

        uint256 finalBalance = token.balanceOf(address(this));
        require(finalBalance > 0, "No tokens to withdraw");

        token.safeTransfer(msg.sender, finalBalance);

        emit Withdraw(address(token), finalBalance);
    }

    // ==================== BACKEND FUNCTIONS ====================

    /**
     * @notice Updates the target stock weights within the immutable stock set and exposure band
     * @param newStockWeightsBps New basis-point weights, parallel to stockTokens
     */
    function setStockWeights(uint256[] calldata newStockWeightsBps) external onlyBackend {
        _setStockWeights(newStockWeightsBps);

        emit WeightsUpdated(newStockWeightsBps);
    }

    /**
     * @notice Rebalances holdings to the target weights
     * @dev Two passes: sell every overweight stock into the base asset, then buy every underweight
     *      stock, then push the remaining base asset into the yield sleeve. Trades below minTradeValue
     *      are skipped so dust never burns gas or spread.
     * @param minTradeValue Minimum base-asset value of a trade worth executing
     */
    function rebalance(uint256 minTradeValue) external onlyBackend {
        uint256 navBefore = getTotalBalance();
        require(navBefore > 0, "Nothing to rebalance");

        // Pass 1: sell overweights
        for (uint256 i = 0; i < stockTokens.length; i++) {
            uint256 currentValue = _stockValue(stockTokens[i]);
            uint256 targetValue = (navBefore * stockWeightsBps[i]) / WEIGHT_TOTAL;

            if (currentValue > targetValue + minTradeValue) {
                uint256 excessValue = currentValue - targetValue;
                uint256 stockBalance = IERC20(stockTokens[i]).balanceOf(address(this));
                uint256 amountToSell = (stockBalance * excessValue) / currentValue;

                if (amountToSell > 0) {
                    uint256 received = _swap(stockTokens[i], address(token), amountToSell);
                    emit StockSold(stockTokens[i], amountToSell, received);
                }
            }
        }

        // Pass 2: buy underweights with idle + sleeve funds
        for (uint256 i = 0; i < stockTokens.length; i++) {
            uint256 currentValue = _stockValue(stockTokens[i]);
            uint256 targetValue = (navBefore * stockWeightsBps[i]) / WEIGHT_TOTAL;

            if (targetValue > currentValue + minTradeValue) {
                uint256 needed = targetValue - currentValue;

                uint256 idleBalance = token.balanceOf(address(this));
                if (idleBalance < needed) {
                    // same no-max* rule as in withdraw(): Vault V2 hardcodes maxWithdraw to 0
                    uint256 sleeveAvailable = yieldVault.convertToAssets(yieldVault.balanceOf(address(this)));
                    uint256 fromSleeve = needed - idleBalance;
                    if (fromSleeve > sleeveAvailable) fromSleeve = sleeveAvailable;
                    if (fromSleeve > 0) {
                        yieldVault.withdraw(fromSleeve, address(this), address(this));
                    }
                }

                uint256 spendable = token.balanceOf(address(this));
                uint256 toSpend = needed > spendable ? spendable : needed;

                if (toSpend > 0) {
                    uint256 received = _swap(address(token), stockTokens[i], toSpend);
                    emit StockBought(stockTokens[i], toSpend, received);
                }
            }
        }

        // Park whatever base asset remains in the yield sleeve
        uint256 remainder = token.balanceOf(address(this));
        if (remainder > 0) {
            token.forceApprove(address(yieldVault), remainder);
            yieldVault.deposit(remainder, address(this));
        }

        emit Rebalanced(navBefore, getTotalBalance());
    }

    // ==================== PERMISSIONLESS FUNCTIONS ====================

    /**
     * @notice Deposits base asset into the strategy
     * @dev Lands in the yield sleeve; the agent's next rebalance buys the basket to target. This keeps
     *      user deposits cheap and keeps equity trading on the agent's schedule (market hours aware).
     * @param amount The amount of base asset to deposit
     */
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        token.safeTransferFrom(msg.sender, address(this), amount);

        token.forceApprove(address(yieldVault), amount);
        yieldVault.deposit(amount, address(this));

        emit Deposit(address(token), amount);
    }

    // ======================= VIEW FUNCTIONS ==========================

    /**
     * @notice Net asset value in base-asset terms: idle + sleeve + oracle value of every stock holding
     */
    function getTotalBalance() public view returns (uint256) {
        uint256 total = token.balanceOf(address(this));

        uint256 sleeveShares = yieldVault.balanceOf(address(this));
        if (sleeveShares > 0) {
            total += yieldVault.convertToAssets(sleeveShares);
        }

        for (uint256 i = 0; i < stockTokens.length; i++) {
            total += _stockValue(stockTokens[i]);
        }

        return total;
    }

    /**
     * @notice Returns the stock set and current target weights
     */
    function getBasket() external view returns (address[] memory, uint256[] memory) {
        return (stockTokens, stockWeightsBps);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Values a stock holding in base-asset terms via the oracle
     */
    function _stockValue(address stock) internal view returns (uint256) {
        uint256 balance = IERC20(stock).balanceOf(address(this));
        if (balance == 0) return 0;

        return slippagePriceChecker.getExpectedOut(balance, stock, address(token));
    }

    /**
     * @notice Validates and stores new stock weights
     */
    function _setStockWeights(uint256[] memory newWeights) internal {
        require(newWeights.length == stockTokens.length, "Weights length mismatch");

        uint256 totalStockBps;
        for (uint256 i = 0; i < newWeights.length; i++) {
            totalStockBps += newWeights[i];
        }
        require(totalStockBps <= maxTotalStockBps, "Stock allocation exceeds mandate");

        stockWeightsBps = newWeights;
    }

    /**
     * @notice Sells stocks pro-rata to their current value until `baseNeeded` of base asset is raised
     */
    function _sellStocksForExactBase(uint256 baseNeeded) internal {
        uint256 totalStockValue;
        for (uint256 i = 0; i < stockTokens.length; i++) {
            totalStockValue += _stockValue(stockTokens[i]);
        }
        require(totalStockValue > 0, "Withdrawal amount exceeds available balance in strategy");

        // sell slightly above the exact need so slippage can't leave the withdrawal short
        uint256 grossNeeded = (baseNeeded * (WEIGHT_TOTAL + allowedSlippageInBps)) / WEIGHT_TOTAL;
        if (grossNeeded > totalStockValue) grossNeeded = totalStockValue;

        for (uint256 i = 0; i < stockTokens.length; i++) {
            uint256 stockValue = _stockValue(stockTokens[i]);
            if (stockValue == 0) continue;

            uint256 valueToSell = (grossNeeded * stockValue) / totalStockValue;
            uint256 stockBalance = IERC20(stockTokens[i]).balanceOf(address(this));
            uint256 amountToSell = (stockBalance * valueToSell) / stockValue;

            if (amountToSell > 0) {
                uint256 received = _swap(stockTokens[i], address(token), amountToSell);
                emit StockSold(stockTokens[i], amountToSell, received);
            }
        }
    }

    /**
     * @notice Swaps through the router with an oracle-derived minimum out
     */
    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, tokenIn, tokenOut);
        require(expectedOut > 0, "No oracle price for pair");

        uint256 minOut = (expectedOut * (WEIGHT_TOTAL - allowedSlippageInBps)) / WEIGHT_TOTAL;

        IERC20(tokenIn).forceApprove(address(dexRouter), amountIn);

        return dexRouter.exactInputSingle(
            IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
