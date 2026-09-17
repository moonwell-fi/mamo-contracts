// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Addresses} from "@fps/addresses/Addresses.sol";

/// @title LPPairConfig
/// @notice Single source of truth for the LPAutoBalancerV2 production pairs on Base.
/// @dev Deploy and the later Safe wiring/registration read the SAME struct, so a pool can never be
///      deployed under one config and registered under another.
library LPPairConfig {
    struct Pair {
        string key; // address-book suffix, e.g. "WETH_USDC"
        address pool;
        address gauge;
        address token0;
        address token1;
        uint8 decimals0;
        uint8 decimals1;
        address oracle0;
        address oracle1;
        int24 tickSpacing;
        uint24 minWidth;
        uint24 maxWidth;
        uint24 maxCenterDeviation;
        uint32 twapWindow;
        int24 maxTickDeviation;
        uint16 maxRebalanceLossBps;
        uint256 minRebalanceInterval;
        uint256 maxOracleDelay0;
        uint256 maxOracleDelay1;
    }

    // Shared rebalance envelope. minWidth/maxWidth must be multiples of 2*tickSpacing (=100 at
    // spacing 50) and minWidth must exceed the R7 branch-collision width, also 2*tickSpacing.
    uint24 internal constant MIN_WIDTH = 200;
    uint24 internal constant MAX_WIDTH = 20_000;
    uint24 internal constant MAX_CENTER_DEVIATION = 200;
    uint32 internal constant TWAP_WINDOW = 1800;
    int24 internal constant MAX_TICK_DEVIATION = 100;
    uint16 internal constant MAX_REBALANCE_LOSS_BPS = 100;
    uint256 internal constant MIN_REBALANCE_INTERVAL = 21_600; // 6h
    int24 internal constant TICK_SPACING = 50;

    // Chainlink staleness bounds, per feed cadence. ETH/USD and BTC/USD on Base publish on a ~1200s
    // heartbeat; USDC/USD is a low-deviation feed whose heartbeat is 24h, so anything tighter than
    // the heartbeat refuses to price on a quiet day. 86400 is also LPAutoBalancerV2.MAX_ORACLE_DELAY.
    uint256 internal constant DELAY_FAST_FEED = 3600;
    uint256 internal constant DELAY_USDC_FEED = 86_400;

    function wethUsdc(Addresses a) internal view returns (Pair memory) {
        return Pair({
            key: "WETH_USDC",
            pool: a.getAddress("WETH_USDC_CL_POOL"),
            gauge: a.getAddress("WETH_USDC_CL_GAUGE"),
            token0: a.getAddress("WETH"),
            token1: a.getAddress("USDC"),
            decimals0: 18,
            decimals1: 6,
            oracle0: a.getAddress("CHAINLINK_ETH_USD"),
            oracle1: a.getAddress("CHAINLINK_USDC_USD"),
            tickSpacing: TICK_SPACING,
            minWidth: MIN_WIDTH,
            maxWidth: MAX_WIDTH,
            maxCenterDeviation: MAX_CENTER_DEVIATION,
            twapWindow: TWAP_WINDOW,
            maxTickDeviation: MAX_TICK_DEVIATION,
            maxRebalanceLossBps: MAX_REBALANCE_LOSS_BPS,
            minRebalanceInterval: MIN_REBALANCE_INTERVAL,
            maxOracleDelay0: DELAY_FAST_FEED,
            maxOracleDelay1: DELAY_USDC_FEED
        });
    }

    function usdcCbbtc(Addresses a) internal view returns (Pair memory) {
        return Pair({
            key: "USDC_CBBTC",
            pool: a.getAddress("USDC_CBBTC_CL_POOL"),
            gauge: a.getAddress("USDC_CBBTC_CL_GAUGE"),
            token0: a.getAddress("USDC"),
            token1: a.getAddress("cbBTC"),
            decimals0: 6,
            decimals1: 8,
            oracle0: a.getAddress("CHAINLINK_USDC_USD"),
            oracle1: a.getAddress("CHAINLINK_BTC_USD"),
            tickSpacing: TICK_SPACING,
            minWidth: MIN_WIDTH,
            maxWidth: MAX_WIDTH,
            maxCenterDeviation: MAX_CENTER_DEVIATION,
            twapWindow: TWAP_WINDOW,
            maxTickDeviation: MAX_TICK_DEVIATION,
            maxRebalanceLossBps: MAX_REBALANCE_LOSS_BPS,
            minRebalanceInterval: MIN_REBALANCE_INTERVAL,
            maxOracleDelay0: DELAY_USDC_FEED,
            maxOracleDelay1: DELAY_FAST_FEED
        });
    }

    /// @notice Resolve a pair by its key. Reverts on an unknown key rather than defaulting.
    function byKey(Addresses a, string memory key) internal view returns (Pair memory) {
        bytes32 h = keccak256(bytes(key));
        if (h == keccak256("WETH_USDC")) return wethUsdc(a);
        if (h == keccak256("USDC_CBBTC")) return usdcCbbtc(a);
        revert("LPPairConfig: unknown pair key");
    }

    function balancerName(Pair memory p) internal pure returns (string memory) {
        return string.concat("MAMO_LP_AUTO_BALANCER_V2_", p.key);
    }

    function moduleName(Pair memory p) internal pure returns (string memory) {
        return string.concat("MAMO_LP_COMPOUND_MODULE_", p.key);
    }
}
