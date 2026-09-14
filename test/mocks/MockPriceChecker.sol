// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

/// @notice Price checker with freely settable fixed rates, for use in tests
contract MockPriceChecker is ISlippagePriceChecker {
    mapping(address => mapping(address => uint256)) public rate;

    function setRate(address fromToken, address toToken, uint256 rate1e18) external {
        rate[fromToken][toToken] = rate1e18;
    }

    function getExpectedOut(uint256 amountIn, address fromToken, address toToken)
        public
        view
        override
        returns (uint256)
    {
        uint256 r = rate[fromToken][toToken];
        require(r != 0, "No rate");
        return (amountIn * r) / 1e18;
    }

    function checkPrice(uint256 amountIn, address fromToken, address toToken, uint256 minOut, uint256 slippageInBps)
        external
        view
        override
        returns (bool)
    {
        uint256 expected = getExpectedOut(amountIn, fromToken, toToken);
        return minOut >= (expected * (10_000 - slippageInBps)) / 10_000;
    }

    function tokenPairOracleInformation(address, address)
        external
        pure
        override
        returns (TokenFeedConfiguration[] memory)
    {
        return new TokenFeedConfiguration[](0);
    }

    function isRewardToken(address) external pure override returns (bool) {
        return false;
    }

    function maxTimePriceValid(address) external pure override returns (uint256) {
        return 0;
    }

    function addTokenConfiguration(address, address, TokenFeedConfiguration[] calldata) external override {}

    function removeTokenConfiguration(address, address) external override {}

    function setMaxTimePriceValid(address, uint256) external override {}

    function isTokenPairConfigured(address fromToken, address toToken) external view override returns (bool) {
        return rate[fromToken][toToken] != 0;
    }
}
