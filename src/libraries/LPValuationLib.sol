// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {LPGeometryLib} from "@libraries/LPGeometryLib.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LPValuationLib
/// @notice USD valuation for LPAutoBalancerV2: Chainlink feed reads and the 1e8-scale pricing of
///         token amounts, position principal, and loose contract balances. Shared invariant of
///         every function here: needs oracles + `maxOracleDelay` + token decimals; an unfunded leg
///         never consults its feed. Deployed as an EXTERNAL (linked) library so its bytecode lives
///         off the balancer — keeping the balancer under the EIP-170 24,576-byte limit. Functions
///         are `public`/`external` on purpose: internal library functions would inline back into
///         the balancer and defeat the size reduction.
/// @dev Errors are redeclared here; a Solidity error's 4-byte selector depends only on its
///      signature, so `LPValuationLib.StaleOracle.selector == LPAutoBalancerV2.StaleOracle.selector`
///      and existing `vm.expectRevert(...)` matchers keep working.
library LPValuationLib {
    error StaleOracle();

    /// @dev Read a Chainlink-style feed, validating positivity + freshness against `maxOracleDelay`.
    function readFeed(address feed, uint256 maxOracleDelay) public view returns (uint256 price, uint8 decimals) {
        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(feed).latestRoundData();
        if (answer <= 0) revert StaleOracle();
        if (block.timestamp - updatedAt > maxOracleDelay) revert StaleOracle();
        price = uint256(answer);
        decimals = IPriceFeed(feed).decimals();
    }

    /// @notice Value token amounts in USD scaled to 1e8. Only consults a leg's feed when funded.
    function valueInUsd(
        uint256 amount0,
        uint256 amount1,
        address oracle0,
        address oracle1,
        uint8 dec0,
        uint8 dec1,
        uint256 maxOracleDelay
    ) public view returns (uint256 usd) {
        if (amount0 > 0) {
            (uint256 p0, uint8 fd0) = readFeed(oracle0, maxOracleDelay);
            usd += FullMath.mulDiv(amount0, p0, 10 ** dec0) * (10 ** 8) / (10 ** fd0);
        }
        if (amount1 > 0) {
            (uint256 p1, uint8 fd1) = readFeed(oracle1, maxOracleDelay);
            usd += FullMath.mulDiv(amount1, p1, 10 ** dec1) * (10 ** 8) / (10 ** fd1);
        }
    }

    /// @notice USD value of the principal tokens locked in `tokenId` at sqrt price `sqrtP`. Returns
    ///         0 for tokenId == 0 (no position). Never counts tokensOwed (fees) — only liquidity.
    function principalValue(
        address positionManager,
        uint256 tokenId,
        uint160 sqrtP,
        address oracle0,
        address oracle1,
        uint8 dec0,
        uint8 dec1,
        uint256 maxOracleDelay
    ) public view returns (uint256) {
        if (tokenId == 0) return 0;
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);
        (uint256 a0, uint256 a1) = LPGeometryLib.amountsForLiquidityAtTicks(sqrtP, tl, tu, liq);
        return valueInUsd(a0, a1, oracle0, oracle1, dec0, dec1, maxOracleDelay);
    }

    /// @notice USD value of `holder`'s current (non-position) balances of `token0`/`token1`.
    function contractPairValue(
        address token0,
        address token1,
        address holder,
        address oracle0,
        address oracle1,
        uint8 dec0,
        uint8 dec1,
        uint256 maxOracleDelay
    ) public view returns (uint256) {
        return valueInUsd(
            IERC20(token0).balanceOf(holder),
            IERC20(token1).balanceOf(holder),
            oracle0,
            oracle1,
            dec0,
            dec1,
            maxOracleDelay
        );
    }
}
