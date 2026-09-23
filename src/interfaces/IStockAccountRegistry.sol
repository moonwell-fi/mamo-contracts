// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

interface IStockAccountRegistry {
    enum TokenStatus {
        None,
        Active,
        SellOnly,
        Halted
    }

    enum PriceSource {
        PoolTwap,
        Chainlink
    }

    struct TokenConfig {
        TokenStatus status;
        PriceSource source;
        address pool;
        address chainlinkFeed;
    }

    error ZeroAddress();
    error InvalidMaxPositions();
    error InvalidMinTarget();
    error InvalidMaxDeviation();
    error InvalidSlippageCap();
    error InvalidTwapWindow();
    error AlreadySet();
    error InvalidManagementFee();
    error NotAContract(address account);
    error TokenAlreadyListed(address token);
    error MustListAsActive();
    error PoolIsToken();
    error FeedOnlyForChainlink();
    error TokenNotListed(address token);
    error TokenNotHalted(address token);
    error InvalidStatus();
    error NotAdminOrGuardian();
    error GuardianCanOnlyLower();
    error TokenNotPriceable(address token);
    error AssetNotListable();
    error PoolNotAgainstAsset(address pool);
    error InvalidDepositBounds();

    function asset() external view returns (address);

    function tokenConfig(address token) external view returns (TokenConfig memory);

    function allTokens() external view returns (address[] memory);

    function paused() external view returns (bool);

    function maxPositions() external view returns (uint8);

    function minTargetBps() external view returns (uint16);

    function maxDeviationBps() external view returns (uint16);

    function minStrategyDeposit() external view returns (uint256);

    function maxStrategyDeposit() external view returns (uint256);

    function twapWindow() external view returns (uint32);

    function maxBackendSlippageBps() external view returns (uint16);

    function maxWithdrawSlippageBps() external view returns (uint16);

    function managementFeeBps() external view returns (uint16);

    function maxManagementFeeBps() external view returns (uint16);

    function backendSlippageCeilingBps() external view returns (uint16);

    function withdrawSlippageCeilingBps() external view returns (uint16);

    function orderSigner() external view returns (address);

    function aerodromeRouter() external view returns (ISwapRouter);

    function priceChecker() external view returns (ISlippagePriceChecker);
}
