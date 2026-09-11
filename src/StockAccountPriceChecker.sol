// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICLPool} from "@interfaces/ICLPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StockAccountPriceChecker
/// @notice Prices stock-account tokens from their own Aerodrome CL pool, time-averaged over the
///         registry's window, and routes every quote through the quote asset (USDC).
contract StockAccountPriceChecker is ISlippagePriceChecker, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant INTERNAL_DECIMALS = 36;

    IStockAccountRegistry public registry;
    address public quoteAsset;

    uint256[48] private __gap;

    error ZeroAddress();
    error TokenNotListed(address token);
    error UnsupportedPriceSource(address token);
    error PoolNotAgainstQuoteAsset(address pool);
    error InsufficientObservations(address pool, uint32 window);
    error InvalidSlippage(uint256 slippageBps);
    error NotSupported();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, IStockAccountRegistry registry_, address quoteAsset_) external initializer {
        if (owner_ == address(0) || address(registry_) == address(0) || quoteAsset_ == address(0)) {
            revert ZeroAddress();
        }
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        registry = registry_;
        quoteAsset = quoteAsset_;
    }

    // ==================== ISlippagePriceChecker ====================

    /// @inheritdoc ISlippagePriceChecker
    function checkPrice(
        uint256 _amountIn,
        address _fromToken,
        address _toToken,
        uint256 _minOut,
        uint256 _slippageInBps
    ) external view override returns (bool) {
        if (_slippageInBps > MAX_BPS) revert InvalidSlippage(_slippageInBps);
        uint256 expectedOut = getExpectedOut(_amountIn, _fromToken, _toToken);
        // A zero reference would accept any minOut; refuse rather than fail open.
        if (expectedOut == 0) return false;
        return _minOut >= (expectedOut * (MAX_BPS - _slippageInBps)) / MAX_BPS;
    }

    /// @inheritdoc ISlippagePriceChecker
    /// @dev Composes `from -> quote -> to`. Every intermediate is carried at 36 decimals; the final
    ///      floor into `_toToken` units is the only rounding that can move the result by a whole unit.
    function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken)
        public
        view
        override
        returns (uint256)
    {
        uint256 quotePerFrom = _quotePerWholeToken(_fromToken);
        uint256 quotePerTo = _quotePerWholeToken(_toToken);
        uint256 value = Math.mulDiv(_amountIn, quotePerFrom, 10 ** IERC20Metadata(_fromToken).decimals());
        return Math.mulDiv(value, 10 ** IERC20Metadata(_toToken).decimals(), quotePerTo);
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
    /// @dev The TWAP window is the only time-validity notion this checker has.
    function maxTimePriceValid(address) external view override returns (uint256) {
        return registry.twapWindow();
    }

    /// @notice Unsupported for everyone, owner included: token config lives in the registry.
    function addTokenConfiguration(address, address, TokenFeedConfiguration[] calldata) external pure override {
        revert NotSupported();
    }

    /// @notice Unsupported for everyone, owner included: token config lives in the registry.
    function removeTokenConfiguration(address, address) external pure override {
        revert NotSupported();
    }

    /// @notice Unsupported for everyone, owner included: the window is the registry's `twapWindow`.
    function setMaxTimePriceValid(address, uint256) external pure override {
        revert NotSupported();
    }

    // ==================== Internal ====================

    /// @dev Quote-asset units per one whole `token`, scaled to 36 decimals. The quote asset itself is 1.
    function _quotePerWholeToken(address token) internal view returns (uint256) {
        if (token == quoteAsset) return 10 ** INTERNAL_DECIMALS;

        IStockAccountRegistry.TokenConfig memory cfg = registry.tokenConfig(token);
        if (cfg.status == IStockAccountRegistry.TokenStatus.None) revert TokenNotListed(token);
        if (cfg.source != IStockAccountRegistry.PriceSource.PoolTwap) revert UnsupportedPriceSource(token);

        ICLPool pool = ICLPool(cfg.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        bool tokenIsToken0;
        if (token0 == token && token1 == quoteAsset) tokenIsToken0 = true;
        else if (token1 == token && token0 == quoteAsset) tokenIsToken0 = false;
        else revert PoolNotAgainstQuoteAsset(address(pool));

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(_twapTick(pool, registry.twapWindow()));
        // Scale the base amount BEFORE the quote so the only floor is at 36 decimals, not at raw quote units.
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
        return cfg.status != IStockAccountRegistry.TokenStatus.None
            && cfg.source == IStockAccountRegistry.PriceSource.PoolTwap;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
