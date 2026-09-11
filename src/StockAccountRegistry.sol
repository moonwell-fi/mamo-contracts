// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

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

    struct Config {
        address admin;
        ISwapRouter aerodromeRouter;
        address guardian;
        uint16 maxBackendSlippageBps;
        uint16 maxDeviationBps;
        uint8 maxPositions;
        uint256 maxStrategyDeposit;
        uint16 maxWithdrawSlippageBps;
        uint256 minStrategyDeposit;
        uint16 minTargetBps;
        ISlippagePriceChecker priceChecker;
        bytes32 requiredAppDataHash;
        uint32 twapWindow;
    }

    ISwapRouter public override aerodromeRouter;
    ISlippagePriceChecker public override priceChecker;

    uint8 public override maxPositions;
    uint16 public override minTargetBps;
    uint16 public override maxDeviationBps;
    uint16 public override maxBackendSlippageBps;
    uint16 public override maxWithdrawSlippageBps;
    uint32 public override twapWindow;
    uint256 public override minStrategyDeposit;
    uint256 public override maxStrategyDeposit;
    bytes32 public override requiredAppDataHash;

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
    event RequiredAppDataHashUpdated(bytes32 indexed oldHash, bytes32 indexed newHash);
    event TokenListed(address indexed token, TokenConfig cfg);
    event TokenStatusUpdated(address indexed token, TokenStatus oldStatus, TokenStatus newStatus);

    /// @param config The initial roles and global configuration
    constructor(Config memory config) {
        require(config.admin != address(0), "Invalid admin address");
        require(config.guardian != address(0), "Invalid guardian address");

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
        _setRequiredAppDataHash(config.requiredAppDataHash);
    }

    /// @notice Sets the Aerodrome router used by stock accounts
    function setAerodromeRouter(ISwapRouter newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(address(newRouter) != address(aerodromeRouter), "Already set");
        _setAerodromeRouter(newRouter);
    }

    /// @notice Sets the price checker used to validate swaps
    function setPriceChecker(ISlippagePriceChecker newPriceChecker)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        require(address(newPriceChecker) != address(priceChecker), "Already set");
        _setPriceChecker(newPriceChecker);
    }

    /// @notice Sets the maximum number of positions a stock account may hold
    function setMaxPositions(uint8 newMaxPositions) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(newMaxPositions != maxPositions, "Already set");
        _setMaxPositions(newMaxPositions);
    }

    /// @notice Sets the minimum per-position target weight in basis points
    function setMinTargetBps(uint16 newMinTargetBps) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(newMinTargetBps != minTargetBps, "Already set");
        _setMinTargetBps(newMinTargetBps);
    }

    /// @notice Sets the maximum tolerated drift from target weights in basis points
    function setMaxDeviationBps(uint16 newMaxDeviationBps) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(newMaxDeviationBps != maxDeviationBps, "Already set");
        _setMaxDeviationBps(newMaxDeviationBps);
    }

    /// @notice Sets the slippage cap in basis points for backend-initiated swaps
    function setMaxBackendSlippageBps(uint16 newSlippageBps) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(newSlippageBps != maxBackendSlippageBps, "Already set");
        _setMaxBackendSlippageBps(newSlippageBps);
    }

    /// @notice Sets the slippage cap in basis points for user withdrawals
    function setMaxWithdrawSlippageBps(uint16 newSlippageBps) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(newSlippageBps != maxWithdrawSlippageBps, "Already set");
        _setMaxWithdrawSlippageBps(newSlippageBps);
    }

    /// @notice Sets the TWAP observation window in seconds
    function setTwapWindow(uint32 newTwapWindow) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(newTwapWindow != twapWindow, "Already set");
        _setTwapWindow(newTwapWindow);
    }

    /// @notice Sets the minimum total value a single stock account must hold after a deposit
    function setMinStrategyDeposit(uint256 newMinDeposit) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(newMinDeposit != minStrategyDeposit, "Already set");
        _setMinStrategyDeposit(newMinDeposit);
    }

    /// @notice Sets the maximum total deposit a single stock account may hold
    function setMaxStrategyDeposit(uint256 newMaxDeposit) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(newMaxDeposit != maxStrategyDeposit, "Already set");
        _setMaxStrategyDeposit(newMaxDeposit);
    }

    /// @notice Sets the CowSwap app data hash that orders must carry
    function setRequiredAppDataHash(bytes32 newHash) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(newHash != requiredAppDataHash, "Already set");
        _setRequiredAppDataHash(newHash);
    }

    /// @notice Lists a new token as tradeable by stock accounts
    /// @param token The token to list
    /// @param cfg The pricing source and venue recorded for the token
    function listToken(address token, TokenConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(_tokenConfig[token].status == TokenStatus.None, "Token already listed");
        require(cfg.status == TokenStatus.Active, "Must list as active");
        require(token.code.length > 0, "Token must be a contract");
        require(cfg.pool.code.length > 0, "Pool must be a contract");
        require(cfg.pool != token, "Pool cannot be the token");

        if (cfg.source == PriceSource.Chainlink) {
            require(cfg.chainlinkFeed.code.length > 0, "Feed must be a contract");
        } else {
            require(cfg.chainlinkFeed == address(0), "Feed only for Chainlink source");
        }

        _tokenConfig[token] = cfg;
        _tokens.push(token);

        emit TokenListed(token, cfg);
    }

    /// @notice Changes the trading status of a listed token
    /// @param token The listed token to update
    /// @param status The new status; the guardian may only tighten it
    function setTokenStatus(address token, TokenStatus status) external whenNotPaused {
        bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        require(isAdmin || hasRole(GUARDIAN_ROLE, msg.sender), "Not admin or guardian");

        TokenStatus oldStatus = _tokenConfig[token].status;
        require(oldStatus != TokenStatus.None, "Token not listed");
        require(status != TokenStatus.None, "Invalid status");
        require(status != oldStatus, "Already set");
        if (!isAdmin) {
            require(status > oldStatus, "Guardian can only lower status");
        }

        _tokenConfig[token].status = status;

        emit TokenStatusUpdated(token, oldStatus, status);
    }

    /// @notice Pauses the configuration surface in case of emergency
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the configuration surface after an emergency is resolved
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

    function _setAerodromeRouter(ISwapRouter newRouter) internal {
        require(address(newRouter) != address(0), "Invalid router address");
        require(address(newRouter).code.length > 0, "Router must be a contract");

        address oldRouter = address(aerodromeRouter);
        aerodromeRouter = newRouter;

        emit AerodromeRouterUpdated(oldRouter, address(newRouter));
    }

    function _setPriceChecker(ISlippagePriceChecker newPriceChecker) internal {
        require(address(newPriceChecker) != address(0), "Invalid price checker address");
        require(address(newPriceChecker).code.length > 0, "Price checker must be a contract");

        address oldPriceChecker = address(priceChecker);
        priceChecker = newPriceChecker;

        emit PriceCheckerUpdated(oldPriceChecker, address(newPriceChecker));
    }

    function _setMaxPositions(uint8 newMaxPositions) internal {
        require(newMaxPositions > 0, "Invalid max positions");

        uint8 oldValue = maxPositions;
        maxPositions = newMaxPositions;

        emit MaxPositionsUpdated(oldValue, newMaxPositions);
    }

    function _setMinTargetBps(uint16 newMinTargetBps) internal {
        require(newMinTargetBps > 0 && newMinTargetBps <= 10_000, "Invalid min target");

        uint16 oldValue = minTargetBps;
        minTargetBps = newMinTargetBps;

        emit MinTargetBpsUpdated(oldValue, newMinTargetBps);
    }

    function _setMaxDeviationBps(uint16 newMaxDeviationBps) internal {
        require(newMaxDeviationBps <= 10_000, "Invalid max deviation");

        uint16 oldValue = maxDeviationBps;
        maxDeviationBps = newMaxDeviationBps;

        emit MaxDeviationBpsUpdated(oldValue, newMaxDeviationBps);
    }

    function _setMaxBackendSlippageBps(uint16 newSlippageBps) internal {
        require(newSlippageBps <= 10_000, "Invalid slippage cap");

        uint16 oldValue = maxBackendSlippageBps;
        maxBackendSlippageBps = newSlippageBps;

        emit MaxBackendSlippageBpsUpdated(oldValue, newSlippageBps);
    }

    function _setMaxWithdrawSlippageBps(uint16 newSlippageBps) internal {
        require(newSlippageBps <= 10_000, "Invalid slippage cap");

        uint16 oldValue = maxWithdrawSlippageBps;
        maxWithdrawSlippageBps = newSlippageBps;

        emit MaxWithdrawSlippageBpsUpdated(oldValue, newSlippageBps);
    }

    function _setTwapWindow(uint32 newTwapWindow) internal {
        require(newTwapWindow > 0, "Invalid twap window");

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

    function _setRequiredAppDataHash(bytes32 newHash) internal {
        bytes32 oldHash = requiredAppDataHash;
        requiredAppDataHash = newHash;

        emit RequiredAppDataHashUpdated(oldHash, newHash);
    }
}
