// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

/// @notice Freely settable stand-in for StockAccountRegistry, with no validation, for use in tests
contract MockStockAccountRegistry is IStockAccountRegistry {
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
    mapping(address => bool) internal _listed;
    address[] internal _tokens;

    function setMaxPositions(uint8 value) external {
        maxPositions = value;
    }

    function setMinTargetBps(uint16 value) external {
        minTargetBps = value;
    }

    function setMaxDeviationBps(uint16 value) external {
        maxDeviationBps = value;
    }

    function setMinStrategyDeposit(uint256 value) external {
        minStrategyDeposit = value;
    }

    function setMaxStrategyDeposit(uint256 value) external {
        maxStrategyDeposit = value;
    }

    function setTwapWindow(uint32 value) external {
        twapWindow = value;
    }

    function setMaxBackendSlippageBps(uint16 value) external {
        maxBackendSlippageBps = value;
    }

    function setMaxWithdrawSlippageBps(uint16 value) external {
        maxWithdrawSlippageBps = value;
    }

    function setRequiredAppDataHash(bytes32 value) external {
        requiredAppDataHash = value;
    }

    function setAerodromeRouter(ISwapRouter value) external {
        aerodromeRouter = value;
    }

    function setPriceChecker(ISlippagePriceChecker value) external {
        priceChecker = value;
    }

    /// @notice Stores a token configuration, appending the token to the list the first time it is set
    function setTokenConfig(address token, TokenConfig calldata cfg) external {
        if (!_listed[token]) {
            _listed[token] = true;
            _tokens.push(token);
        }
        _tokenConfig[token] = cfg;
    }

    function tokenConfig(address token) external view override returns (TokenConfig memory) {
        return _tokenConfig[token];
    }

    function allTokens() external view override returns (address[] memory) {
        return _tokens;
    }
}
