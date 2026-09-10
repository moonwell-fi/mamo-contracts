// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

/**
 * @title StockAccountRegistry
 * @notice Per-chain rulebook that stock accounts read for token eligibility and global limits; the admin surface
 * that mutates it lands in a follow-up.
 */
contract StockAccountRegistry is IStockAccountRegistry {
    struct Config {
        ISwapRouter aerodromeRouter;
        uint16 maxBackendSlippageBps;
        uint16 maxDeviationBps;
        uint8 maxPositions;
        uint256 maxStrategyDeposit;
        uint16 maxWithdrawSlippageBps;
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
    uint256 public override maxStrategyDeposit;
    bytes32 public override requiredAppDataHash;

    mapping(address => TokenConfig) internal _tokenConfig;
    address[] internal _tokens;

    /// @param config The initial global configuration
    constructor(Config memory config) {
        require(address(config.aerodromeRouter) != address(0), "Invalid router address");
        require(address(config.priceChecker) != address(0), "Invalid price checker address");
        require(config.maxPositions > 0, "Invalid max positions");
        require(config.minTargetBps > 0 && config.minTargetBps <= 10_000, "Invalid min target");
        require(config.maxDeviationBps <= 10_000, "Invalid max deviation");
        require(config.maxBackendSlippageBps <= 10_000, "Invalid slippage cap");
        require(config.maxWithdrawSlippageBps <= 10_000, "Invalid slippage cap");
        require(config.twapWindow > 0, "Invalid twap window");

        aerodromeRouter = config.aerodromeRouter;
        priceChecker = config.priceChecker;
        maxPositions = config.maxPositions;
        minTargetBps = config.minTargetBps;
        maxDeviationBps = config.maxDeviationBps;
        maxBackendSlippageBps = config.maxBackendSlippageBps;
        maxWithdrawSlippageBps = config.maxWithdrawSlippageBps;
        twapWindow = config.twapWindow;
        maxStrategyDeposit = config.maxStrategyDeposit;
        requiredAppDataHash = config.requiredAppDataHash;
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
}
