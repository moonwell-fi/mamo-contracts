// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICLPool} from "@interfaces/ICLPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StockAccountPriceChecker
/// @notice Prices stock-account tokens by their registry `PriceSource` — an Aerodrome CL pool TWAP
///         over the registry's window, or the audited `SlippagePriceChecker` — routing every quote
///         through the quote asset (USDC).
/// @dev Immutable and unowned: replacement goes through `StockAccountRegistry.setPriceChecker`,
///      which every stock account reads live. That covers `existingChecker` too.
contract StockAccountPriceChecker is ISlippagePriceChecker {
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant INTERNAL_DECIMALS = 36;

    IStockAccountRegistry public immutable registry;
    address public immutable quoteAsset;
    /// @dev Prices every `PriceSource.Chainlink` token against `quoteAsset`; only `token -> quoteAsset`
    ///      needs configuring there, the reverse direction is derived here.
    ISlippagePriceChecker public immutable existingChecker;

    error ZeroAddress();
    error TokenNotListed(address token);
    error UnsupportedPriceSource(address token);
    error PoolNotAgainstQuoteAsset(address pool);
    error InsufficientObservations(address pool, uint32 window);
    error InvalidSlippage(uint256 slippageBps);
    error NotSupported();

    constructor(IStockAccountRegistry registry_, address quoteAsset_, ISlippagePriceChecker existingChecker_) {
        if (address(registry_) == address(0) || quoteAsset_ == address(0) || address(existingChecker_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        quoteAsset = quoteAsset_;
        existingChecker = existingChecker_;
    }

    /// @inheritdoc ISlippagePriceChecker
    /// @dev Returns false on a zero reference: it would otherwise accept any `_minOut`.
    function checkPrice(
        uint256 _amountIn,
        address _fromToken,
        address _toToken,
        uint256 _minOut,
        uint256 _slippageInBps
    ) external view override returns (bool) {
        if (_slippageInBps > MAX_BPS) revert InvalidSlippage(_slippageInBps);
        uint256 expectedOut = getExpectedOut(_amountIn, _fromToken, _toToken);
        if (expectedOut == 0) return false;
        return _minOut >= (expectedOut * (MAX_BPS - _slippageInBps)) / MAX_BPS;
    }

    /// @inheritdoc ISlippagePriceChecker
    /// @dev Composes `from -> quote -> to`. The intermediate is carried at 36 decimals; the final
    ///      floor into `_toToken` units is the only rounding that can move the result by a whole unit.
    function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken)
        public
        view
        override
        returns (uint256)
    {
        return _fromQuote(_toQuote(_amountIn, _fromToken), _toToken);
    }

    /// @inheritdoc ISlippagePriceChecker
    function isTokenPairConfigured(address fromToken, address toToken) external view override returns (bool) {
        return _isPriceable(fromToken) && _isPriceable(toToken);
    }

    /// @inheritdoc ISlippagePriceChecker
    function tokenPairOracleInformation(address, address)
        external
        pure
        override
        returns (TokenFeedConfiguration[] memory)
    {
        return new TokenFeedConfiguration[](0);
    }

    /// @notice Always false: this checker holds no oracle configuration of its own.
    function isRewardToken(address) external pure override returns (bool) {
        return false;
    }

    /// @inheritdoc ISlippagePriceChecker
    /// @dev A Chainlink token inherits the existing checker's feed-based bound; everything else is
    ///      bounded by the TWAP window, the only time-validity notion this checker has of its own.
    function maxTimePriceValid(address token) external view override returns (uint256) {
        if (token != quoteAsset) {
            IStockAccountRegistry.TokenConfig memory cfg = registry.tokenConfig(token);
            if (
                cfg.status != IStockAccountRegistry.TokenStatus.None
                    && cfg.source == IStockAccountRegistry.PriceSource.Chainlink
            ) {
                return existingChecker.maxTimePriceValid(token);
            }
        }
        return registry.twapWindow();
    }

    /// @notice Unsupported for everyone: token config lives in the registry.
    function addTokenConfiguration(address, address, TokenFeedConfiguration[] calldata) external pure override {
        revert NotSupported();
    }

    /// @notice Unsupported for everyone: token config lives in the registry.
    function removeTokenConfiguration(address, address) external pure override {
        revert NotSupported();
    }

    /// @notice Unsupported for everyone: the window is the registry's `twapWindow`.
    function setMaxTimePriceValid(address, uint256) external pure override {
        revert NotSupported();
    }

    /// @dev Value of `amountIn` raw `token` units in quote asset, scaled to 36 decimals. A Chainlink
    ///      token delegates with the real amount, so a pure `token -> quoteAsset` quote is exactly what
    ///      the existing checker returns.
    function _toQuote(uint256 amountIn, address token) internal view returns (uint256) {
        if (token == quoteAsset) return _scaleToInternal(amountIn);

        IStockAccountRegistry.TokenConfig memory cfg = registry.tokenConfig(token);
        if (cfg.status == IStockAccountRegistry.TokenStatus.None) revert TokenNotListed(token);
        if (cfg.source == IStockAccountRegistry.PriceSource.Chainlink) {
            return _scaleToInternal(existingChecker.getExpectedOut(amountIn, token, quoteAsset));
        }
        if (cfg.source == IStockAccountRegistry.PriceSource.PoolTwap) {
            return Math.mulDiv(amountIn, _twapQuotePerWholeToken(token, cfg), 10 ** IERC20Metadata(token).decimals());
        }
        revert UnsupportedPriceSource(token);
    }

    /// @dev Raw `token` units for a 36-decimal quote-asset value. The Chainlink price is inverted from a
    ///      one-whole-token probe, so it inherits that probe's floor at raw quote units
    ///      (<= 1e-6 USDC per whole token — far below any bps tolerance).
    function _fromQuote(uint256 quoteValue, address token) internal view returns (uint256) {
        if (token == quoteAsset) {
            return Math.mulDiv(quoteValue, 10 ** IERC20Metadata(quoteAsset).decimals(), 10 ** INTERNAL_DECIMALS);
        }

        IStockAccountRegistry.TokenConfig memory cfg = registry.tokenConfig(token);
        if (cfg.status == IStockAccountRegistry.TokenStatus.None) revert TokenNotListed(token);
        uint256 oneToken = 10 ** IERC20Metadata(token).decimals();
        if (cfg.source == IStockAccountRegistry.PriceSource.Chainlink) {
            uint256 pricePerWhole = _scaleToInternal(existingChecker.getExpectedOut(oneToken, token, quoteAsset));
            return Math.mulDiv(quoteValue, oneToken, pricePerWhole);
        }
        if (cfg.source == IStockAccountRegistry.PriceSource.PoolTwap) {
            return Math.mulDiv(quoteValue, oneToken, _twapQuotePerWholeToken(token, cfg));
        }
        revert UnsupportedPriceSource(token);
    }

    /// @dev Raw quote-asset units scaled to the 36-decimal internal representation.
    function _scaleToInternal(uint256 rawQuoteAmount) internal view returns (uint256) {
        return Math.mulDiv(rawQuoteAmount, 10 ** INTERNAL_DECIMALS, 10 ** IERC20Metadata(quoteAsset).decimals());
    }

    /// @dev Quote-asset units per one whole `token` from its pool TWAP, scaled to 36 decimals. The base
    ///      amount is scaled before the quote so the only floor is at 36 decimals, not at raw quote units.
    function _twapQuotePerWholeToken(address token, IStockAccountRegistry.TokenConfig memory cfg)
        internal
        view
        returns (uint256)
    {
        ICLPool pool = ICLPool(cfg.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        bool tokenIsToken0;
        if (token0 == token && token1 == quoteAsset) tokenIsToken0 = true;
        else if (token1 == token && token0 == quoteAsset) tokenIsToken0 = false;
        else revert PoolNotAgainstQuoteAsset(address(pool));

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(_twapTick(pool, registry.twapWindow()));
        uint256 quoteDecimals = IERC20Metadata(quoteAsset).decimals();
        uint256 oneTokenScaled = 10 ** (IERC20Metadata(token).decimals() + INTERNAL_DECIMALS - quoteDecimals);
        return _quoteAtSqrtPrice(sqrtP, oneTokenScaled, tokenIsToken0);
    }

    /// @dev Quote-asset raw units for `baseAmount` raw units of the base token at `sqrtP`
    ///      (OracleLibrary.getQuoteAtTick, kept in-line to avoid the 2^320 overflow of sqrtP^2).
    function _quoteAtSqrtPrice(uint160 sqrtP, uint256 baseAmount, bool baseIsToken0) internal pure returns (uint256) {
        if (sqrtP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtP) * sqrtP;
            return baseIsToken0
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtP, sqrtP, 1 << 64);
        return
            baseIsToken0 ? Math.mulDiv(ratioX128, baseAmount, 1 << 128) : Math.mulDiv(1 << 128, baseAmount, ratioX128);
    }

    /// @dev Mean tick over `window` seconds, floored toward -inf. Any `observe` revert (Slipstream
    ///      reverts "OLD" when history is shorter than the window) is surfaced as InsufficientObservations.
    function _twapTick(ICLPool pool, uint32 window) internal view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        try pool.observe(secondsAgos) returns (int56[] memory cum, uint160[] memory) {
            int56 delta = cum[1] - cum[0];
            int56 w = int56(uint56(window));
            tick = int24(delta / w);
            if (delta < 0 && delta % w != 0) tick--;
        } catch {
            revert InsufficientObservations(address(pool), window);
        }
    }

    function _isPriceable(address token) internal view returns (bool) {
        if (token == quoteAsset) return true;
        IStockAccountRegistry.TokenConfig memory cfg = registry.tokenConfig(token);
        if (cfg.status == IStockAccountRegistry.TokenStatus.None) return false;
        if (cfg.source == IStockAccountRegistry.PriceSource.Chainlink) {
            return existingChecker.isTokenPairConfigured(token, quoteAsset);
        }
        return cfg.source == IStockAccountRegistry.PriceSource.PoolTwap;
    }
}
