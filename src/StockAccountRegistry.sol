// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

/**
 * @title StockAccountRegistry
 * @notice Per-chain rulebook that stock accounts read for token eligibility and global limits
 */
contract StockAccountRegistry is AccessControlEnumerable, Pausable, IStockAccountRegistry {
    /// @notice Guardian role for emergency pause and for tightening token status
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Highest annual management fee the admin may set, in basis points
    uint16 public constant override maxManagementFeeBps = 200;

    /// @notice Highest backend slippage cap the admin may set, in basis points
    uint16 public constant override backendSlippageCeilingBps = 500;

    /// @notice Highest withdrawal slippage cap the admin may set, in basis points
    uint16 public constant override withdrawSlippageCeilingBps = 1_000;

    struct Config {
        address admin;
        ISwapRouter aerodromeRouter;
        address asset;
        address guardian;
        uint16 managementFeeBps;
        uint16 maxBackendSlippageBps;
        uint16 maxDeviationBps;
        uint8 maxPositions;
        uint256 maxStrategyDeposit;
        uint16 maxWithdrawSlippageBps;
        uint256 minStrategyDeposit;
        uint16 minTargetBps;
        address orderSigner;
        ISlippagePriceChecker priceChecker;
        uint32 twapWindow;
    }

    ISwapRouter public override aerodromeRouter;
    ISlippagePriceChecker public override priceChecker;
    address public override asset;

    uint8 public override maxPositions;
    uint16 public override minTargetBps;
    uint16 public override maxDeviationBps;
    uint16 public override maxBackendSlippageBps;
    uint16 public override maxWithdrawSlippageBps;
    uint16 public override managementFeeBps;
    uint32 public override twapWindow;
    address public override orderSigner;
    uint256 public override minStrategyDeposit;
    uint256 public override maxStrategyDeposit;

    mapping(address => TokenConfig) internal _tokenConfig;
    address[] internal _tokens;

    event AerodromeRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event PriceCheckerUpdated(address indexed oldPriceChecker, address indexed newPriceChecker);
    event MaxPositionsUpdated(uint8 oldValue, uint8 newValue);
    event MinTargetBpsUpdated(uint16 oldValue, uint16 newValue);
    event MaxDeviationBpsUpdated(uint16 oldValue, uint16 newValue);
    event MaxBackendSlippageBpsUpdated(uint16 oldValue, uint16 newValue);
    event MaxWithdrawSlippageBpsUpdated(uint16 oldValue, uint16 newValue);
    event TwapWindowUpdated(uint32 oldValue, uint32 newValue);
    event MinStrategyDepositUpdated(uint256 oldValue, uint256 newValue);
    event MaxStrategyDepositUpdated(uint256 oldValue, uint256 newValue);
    event ManagementFeeBpsUpdated(uint16 oldValue, uint16 newValue);
    event OrderSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event TokenListed(address indexed token, TokenConfig cfg);
    event TokenPoolUpdated(address indexed token, address indexed oldPool, address indexed newPool);
    event TokenStatusUpdated(address indexed token, TokenStatus oldStatus, TokenStatus newStatus);

    /// @param config The initial roles and global configuration
    constructor(Config memory config) {
        if (config.admin == address(0)) revert ZeroAddress();
        if (config.guardian == address(0)) revert ZeroAddress();
        if (config.asset == address(0)) revert ZeroAddress();

        asset = config.asset;

        _grantRole(DEFAULT_ADMIN_ROLE, config.admin);
        _grantRole(GUARDIAN_ROLE, config.guardian);

        _setAerodromeRouter(config.aerodromeRouter);
        _setPriceChecker(config.priceChecker);
        _setMaxPositions(config.maxPositions);
        _setMinTargetBps(config.minTargetBps);
        _setMaxDeviationBps(config.maxDeviationBps);
        _setMaxBackendSlippageBps(config.maxBackendSlippageBps);
        _setMaxWithdrawSlippageBps(config.maxWithdrawSlippageBps);
        _setTwapWindow(config.twapWindow);
        _setMinStrategyDeposit(config.minStrategyDeposit);
        _setMaxStrategyDeposit(config.maxStrategyDeposit);
        if (config.minStrategyDeposit > config.maxStrategyDeposit) revert InvalidDepositBounds();
        _setOrderSigner(config.orderSigner);
        _setManagementFeeBps(config.managementFeeBps);
    }

    /// @notice Sets the Aerodrome router used by stock accounts
    function setAerodromeRouter(ISwapRouter newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (address(newRouter) == address(aerodromeRouter)) revert AlreadySet();
        _setAerodromeRouter(newRouter);
    }

    /// @notice Sets the price checker used to validate swaps
    function setPriceChecker(ISlippagePriceChecker newPriceChecker)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        if (address(newPriceChecker) == address(priceChecker)) revert AlreadySet();
        _setPriceChecker(newPriceChecker);

        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokenConfig[_tokens[i]].status != TokenStatus.Halted) _requirePriceable(_tokens[i]);
        }
    }

    /// @notice Sets the maximum number of positions a stock account may hold
    function setMaxPositions(uint8 newMaxPositions) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newMaxPositions == maxPositions) revert AlreadySet();
        _setMaxPositions(newMaxPositions);
    }

    /// @notice Sets the minimum per-position target weight in basis points
    function setMinTargetBps(uint16 newMinTargetBps) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newMinTargetBps == minTargetBps) revert AlreadySet();
        _setMinTargetBps(newMinTargetBps);
    }

    /// @notice Sets the maximum tolerated drift from target weights in basis points
    function setMaxDeviationBps(uint16 newMaxDeviationBps) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newMaxDeviationBps == maxDeviationBps) revert AlreadySet();
        _setMaxDeviationBps(newMaxDeviationBps);
    }

    /// @notice Sets the slippage cap in basis points for backend-initiated swaps
    function setMaxBackendSlippageBps(uint16 newSlippageBps) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newSlippageBps == maxBackendSlippageBps) revert AlreadySet();
        _setMaxBackendSlippageBps(newSlippageBps);
    }

    /// @notice Sets the slippage cap in basis points for user withdrawals
    function setMaxWithdrawSlippageBps(uint16 newSlippageBps) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newSlippageBps == maxWithdrawSlippageBps) revert AlreadySet();
        _setMaxWithdrawSlippageBps(newSlippageBps);
    }

    /// @notice Sets the TWAP observation window in seconds
    /// @param newTwapWindow The new window; it takes effect first, so every non-halted token is re-probed
    ///        against it and a window no pool can serve is refused
    function setTwapWindow(uint32 newTwapWindow) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newTwapWindow == twapWindow) revert AlreadySet();
        _setTwapWindow(newTwapWindow);

        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokenConfig[_tokens[i]].status != TokenStatus.Halted) _requirePriceable(_tokens[i]);
        }
    }

    /// @notice Sets the minimum total value a single stock account must hold after a deposit
    function setMinStrategyDeposit(uint256 newMinDeposit) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newMinDeposit == minStrategyDeposit) revert AlreadySet();
        if (newMinDeposit > maxStrategyDeposit) revert InvalidDepositBounds();
        _setMinStrategyDeposit(newMinDeposit);
    }

    /// @notice Sets the maximum total deposit a single stock account may hold
    function setMaxStrategyDeposit(uint256 newMaxDeposit) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newMaxDeposit == maxStrategyDeposit) revert AlreadySet();
        if (newMaxDeposit < minStrategyDeposit) revert InvalidDepositBounds();
        _setMaxStrategyDeposit(newMaxDeposit);
    }

    /// @notice Sets the key the backend signs orders with, invalidating any order signed by the old one
    /// @dev Stays available while paused: rotating the key is a remediation lever
    function setOrderSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == orderSigner) revert AlreadySet();
        _setOrderSigner(newSigner);
    }

    /// @notice Sets the annual management fee every stock account charges, in basis points
    function setManagementFeeBps(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newFeeBps == managementFeeBps) revert AlreadySet();
        _setManagementFeeBps(newFeeBps);
    }

    /// @notice Lists a new token as tradeable by stock accounts
    /// @param token The token to list
    /// @param cfg The pricing source and venue recorded for the token. cfg.chainlinkFeed is advisory
    ///        bookkeeping only. A Chainlink token is priced through the audited SlippagePriceChecker,
    ///        whose feeds its own owner configures; this field is not read.
    function listToken(address token, TokenConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (token == asset) revert AssetNotListable();
        if (_tokenConfig[token].status != TokenStatus.None) revert TokenAlreadyListed(token);
        if (cfg.status != TokenStatus.Active) revert MustListAsActive();
        if (token.code.length == 0) revert NotAContract(token);
        if (cfg.pool.code.length == 0) revert NotAContract(cfg.pool);
        if (cfg.pool == token) revert PoolIsToken();
        _requireAssetPool(token, cfg.pool);

        if (cfg.source == PriceSource.Chainlink) {
            if (cfg.chainlinkFeed.code.length == 0) revert NotAContract(cfg.chainlinkFeed);
        } else {
            if (cfg.chainlinkFeed != address(0)) revert FeedOnlyForChainlink();
        }

        _tokenConfig[token] = cfg;
        _tokens.push(token);

        _requirePriceable(token);

        emit TokenListed(token, cfg);
    }

    /// @notice Repoints a halted token at a new pool, which re-activation then probes before the token counts again
    function setTokenPool(address token, address newPool) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        TokenConfig storage cfg = _tokenConfig[token];
        if (cfg.status == TokenStatus.None) revert TokenNotListed(token);
        if (cfg.status != TokenStatus.Halted) revert TokenNotHalted(token);
        if (newPool == cfg.pool) revert AlreadySet();
        if (newPool.code.length == 0) revert NotAContract(newPool);
        if (newPool == token) revert PoolIsToken();
        _requireAssetPool(token, newPool);

        address oldPool = cfg.pool;
        cfg.pool = newPool;

        emit TokenPoolUpdated(token, oldPool, newPool);
    }

    /// @notice Changes the trading status of a listed token
    /// @param token The listed token to update
    /// @param status The new status; the guardian may only tighten it, and any loosening re-probes the price
    /// @dev Tightening stays available while paused, because halting a token is a remediation lever;
    ///      loosening is frozen, because it is the action that puts a token back into every account's value
    function setTokenStatus(address token, TokenStatus status) external {
        bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        if (!isAdmin && !hasRole(GUARDIAN_ROLE, msg.sender)) revert NotAdminOrGuardian();

        TokenStatus oldStatus = _tokenConfig[token].status;
        if (oldStatus == TokenStatus.None) revert TokenNotListed(token);
        if (status == TokenStatus.None) revert InvalidStatus();
        if (status == oldStatus) revert AlreadySet();
        if (!isAdmin && status <= oldStatus) revert GuardianCanOnlyLower();

        _tokenConfig[token].status = status;

        if (status < oldStatus) {
            _requireNotPaused();
            _requirePriceable(token);
        }

        emit TokenStatusUpdated(token, oldStatus, status);
    }

    /// @notice Stops order validation and ordinary configuration changes in an emergency
    /// @dev Rotating the order signer and tightening a token status stay available while paused,
    ///      so that the guardian's pause does not lock out the remediation levers it exists to enable
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Resumes order validation and ordinary configuration changes after an emergency is resolved
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /// @notice Returns the full configuration recorded for a token
    /// @param token The token to look up
    function tokenConfig(address token) external view override returns (TokenConfig memory) {
        return _tokenConfig[token];
    }

    /// @notice Returns every token that has ever been configured
    function allTokens() external view override returns (address[] memory) {
        return _tokens;
    }

    /// @notice Returns whether stock accounts are barred from validating orders
    function paused() public view override(IStockAccountRegistry, Pausable) returns (bool) {
        return super.paused();
    }

    function _requireAssetPool(address token, address pool) internal view {
        (address a, address b) = (ICLPool(pool).token0(), ICLPool(pool).token1());
        if (!(a == token && b == asset) && !(a == asset && b == token)) revert PoolNotAgainstAsset(pool);
    }

    function _requirePriceable(address token) internal view {
        uint256 oneToken = 10 ** IERC20Metadata(token).decimals();
        try priceChecker.getExpectedOut(oneToken, token, asset) returns (uint256 quote) {
            if (quote == 0) revert TokenNotPriceable(token);
        } catch {
            revert TokenNotPriceable(token);
        }
    }

    function _setAerodromeRouter(ISwapRouter newRouter) internal {
        if (address(newRouter) == address(0)) revert ZeroAddress();
        if (address(newRouter).code.length == 0) revert NotAContract(address(newRouter));

        address oldRouter = address(aerodromeRouter);
        aerodromeRouter = newRouter;

        emit AerodromeRouterUpdated(oldRouter, address(newRouter));
    }

    function _setPriceChecker(ISlippagePriceChecker newPriceChecker) internal {
        if (address(newPriceChecker) == address(0)) revert ZeroAddress();
        if (address(newPriceChecker).code.length == 0) revert NotAContract(address(newPriceChecker));

        address oldPriceChecker = address(priceChecker);
        priceChecker = newPriceChecker;

        emit PriceCheckerUpdated(oldPriceChecker, address(newPriceChecker));
    }

    function _setMaxPositions(uint8 newMaxPositions) internal {
        if (newMaxPositions == 0) revert InvalidMaxPositions();

        uint8 oldValue = maxPositions;
        maxPositions = newMaxPositions;

        emit MaxPositionsUpdated(oldValue, newMaxPositions);
    }

    function _setMinTargetBps(uint16 newMinTargetBps) internal {
        if (newMinTargetBps == 0 || newMinTargetBps > 10_000) revert InvalidMinTarget();

        uint16 oldValue = minTargetBps;
        minTargetBps = newMinTargetBps;

        emit MinTargetBpsUpdated(oldValue, newMinTargetBps);
    }

    function _setMaxDeviationBps(uint16 newMaxDeviationBps) internal {
        if (newMaxDeviationBps > 10_000) revert InvalidMaxDeviation();

        uint16 oldValue = maxDeviationBps;
        maxDeviationBps = newMaxDeviationBps;

        emit MaxDeviationBpsUpdated(oldValue, newMaxDeviationBps);
    }

    function _setMaxBackendSlippageBps(uint16 newSlippageBps) internal {
        if (newSlippageBps > backendSlippageCeilingBps) revert InvalidSlippageCap();

        uint16 oldValue = maxBackendSlippageBps;
        maxBackendSlippageBps = newSlippageBps;

        emit MaxBackendSlippageBpsUpdated(oldValue, newSlippageBps);
    }

    function _setMaxWithdrawSlippageBps(uint16 newSlippageBps) internal {
        if (newSlippageBps > withdrawSlippageCeilingBps) revert InvalidSlippageCap();

        uint16 oldValue = maxWithdrawSlippageBps;
        maxWithdrawSlippageBps = newSlippageBps;

        emit MaxWithdrawSlippageBpsUpdated(oldValue, newSlippageBps);
    }

    function _setTwapWindow(uint32 newTwapWindow) internal {
        if (newTwapWindow == 0) revert InvalidTwapWindow();

        uint32 oldValue = twapWindow;
        twapWindow = newTwapWindow;

        emit TwapWindowUpdated(oldValue, newTwapWindow);
    }

    function _setMinStrategyDeposit(uint256 newMinDeposit) internal {
        uint256 oldValue = minStrategyDeposit;
        minStrategyDeposit = newMinDeposit;

        emit MinStrategyDepositUpdated(oldValue, newMinDeposit);
    }

    function _setMaxStrategyDeposit(uint256 newMaxDeposit) internal {
        uint256 oldValue = maxStrategyDeposit;
        maxStrategyDeposit = newMaxDeposit;

        emit MaxStrategyDepositUpdated(oldValue, newMaxDeposit);
    }

    function _setOrderSigner(address newSigner) internal {
        if (newSigner == address(0)) revert ZeroAddress();

        address oldSigner = orderSigner;
        orderSigner = newSigner;

        emit OrderSignerUpdated(oldSigner, newSigner);
    }

    function _setManagementFeeBps(uint16 newFeeBps) internal {
        if (newFeeBps > maxManagementFeeBps) revert InvalidManagementFee();

        uint16 oldValue = managementFeeBps;
        managementFeeBps = newFeeBps;

        emit ManagementFeeBpsUpdated(oldValue, newFeeBps);
    }
}
