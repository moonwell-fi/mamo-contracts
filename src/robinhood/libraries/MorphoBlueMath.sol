// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMorphoIrm, Market, MarketParams} from "@contracts/robinhood/interfaces/IMorphoBlue.sol";

/**
 * @title MorphoBlueMath
 * @notice The pieces of Morpho Blue's internal arithmetic a borrower needs in order to read its own debt
 *         honestly between blocks
 * @dev Blue stores debt as SHARES. Converting shares back to assets requires `totalBorrowAssets`, which grows
 *      every second and is only written to storage when someone touches the market. A vault that reads the
 *      raw storage value therefore UNDERSTATES its debt — and so overstates NAV — for as long as the market
 *      sits idle, which on a young chain can be hours.
 *
 *      `expectedBorrowAssets` reproduces `Morpho._accrueInterest` view-side (the "expectedMarketBalances"
 *      pattern from `morpho-org/morpho-blue`'s periphery): it asks the IRM for the current rate, compounds it
 *      over the elapsed time with the same third-order Taylor series Blue uses, and converts shares up. The
 *      result matches what `accrueInterest()` would write, so `BoostedUsdgVault.totalAssets()` reports the
 *      same NAV whether or not a keeper has poked the market.
 *
 *      Constants and rounding directions are copied from Blue (`SharesMathLib`, `MathLib`) deliberately:
 *      VIRTUAL_SHARES/VIRTUAL_ASSETS are its inflation-attack guard, and debt always rounds UP against the
 *      borrower. Diverging on either would make the vault's health checks disagree with the singleton's.
 */
library MorphoBlueMath {
    uint256 internal constant WAD = 1e18;

    /// @notice The scale Blue quotes oracle prices in: `collateral * price / ORACLE_PRICE_SCALE` is loan-token value
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    /// @dev Blue's share-math offsets. Do not change: they must match the singleton exactly.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    function wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y);
    }

    /// @notice Third-order Taylor expansion of e^(x*n) - 1, Blue's continuous-compounding approximation
    /// @dev Underestimates the exact exponential, which is the direction Blue chose; kept identical here so
    ///      the vault's projected debt never exceeds what the singleton will actually charge.
    function wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = mulDivDown(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = mulDivDown(secondTerm, firstTerm, 3 * WAD);

        return firstTerm + secondTerm + thirdTerm;
    }

    /// @notice Converts borrow shares to assets, rounding up (against the borrower), exactly as Blue does
    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return mulDivUp(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Converts assets to borrow shares, rounding up, exactly as Blue does
    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return mulDivUp(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @notice Converts shares to assets, rounding down, exactly as Blue does
    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return mulDivDown(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Converts assets to shares, rounding down, exactly as Blue does
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return mulDivDown(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /**
     * @notice `market.totalBorrowAssets` brought forward to the current block, without writing storage
     * @dev Mirrors `Morpho._accrueInterest`. The protocol fee is deliberately not modelled: it mints SUPPLY
     *      shares and leaves `totalBorrowAssets`/`totalBorrowShares` untouched, so it cannot move a
     *      borrower's debt. Robinhood Chain's Blue singleton currently runs with `feeRecipient` unset anyway.
     * @param marketParams The market being read
     * @param m The market's stored state (as returned by `IMorphoBlue.market`)
     * @return The interest-accrued total borrow assets
     */
    function expectedTotalBorrowAssets(MarketParams memory marketParams, Market memory m)
        internal
        view
        returns (uint256)
    {
        uint256 totalBorrowAssets = m.totalBorrowAssets;

        if (totalBorrowAssets == 0 || marketParams.irm == address(0)) return totalBorrowAssets;
        if (block.timestamp <= m.lastUpdate) return totalBorrowAssets;

        uint256 elapsed = block.timestamp - m.lastUpdate;
        uint256 borrowRate = IMorphoIrm(marketParams.irm).borrowRateView(marketParams, m);

        return totalBorrowAssets + wMulDown(totalBorrowAssets, wTaylorCompounded(borrowRate, elapsed));
    }

    /**
     * @notice A borrower's debt in loan-token assets, accrual-aware
     * @param marketParams The market being read
     * @param m The market's stored state
     * @param borrowShares The borrower's share balance
     */
    function expectedBorrowAssets(MarketParams memory marketParams, Market memory m, uint256 borrowShares)
        internal
        view
        returns (uint256)
    {
        if (borrowShares == 0) return 0;

        return toAssetsUp(borrowShares, expectedTotalBorrowAssets(marketParams, m), m.totalBorrowShares);
    }
}
