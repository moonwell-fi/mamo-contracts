// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Morpho Blue market identifier: keccak256 of the abi-encoded MarketParams
type Id is bytes32;

/// @notice The five fields that immutably define a Morpho Blue market
/// @dev `lltv` is WAD-scaled (0.915e18 == 91.5%)
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Morpho Blue's per-market accounting
/// @dev Field order and packing match the singleton's storage exactly, so the generated
///      `market(Id)` getter's tuple return decodes straight into this struct.
struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

/// @notice Morpho Blue's per-user, per-market position
struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/**
 * @title IMorphoBlue
 * @notice The slice of the Morpho Blue singleton `BoostedUsdgVault` uses, restyled to repo conventions
 * @dev Vendored from the canonical `morpho-org/morpho-blue` `IMorpho`/`IMorphoBase` interfaces rather than
 *      imported, for the same reason the repo vendors `IUniswapV3SwapRouter`: only the surface actually used
 *      is carried, and the ABI is pinned in-tree where it can be read next to the code that depends on it.
 *
 *      Two upstream details worth knowing:
 *      1. Blue ships two interface shapes over the same ABI — `IMorphoStaticTyping` (flattened tuples) and
 *         `IMorpho` (structs). This is the struct-returning shape; it decodes identically on the wire.
 *      2. Every mutating entry point takes `MarketParams` by value, not an `Id`. Blue derives the id itself,
 *         so a caller can never operate on a market it did not fully name.
 *
 *      Blue's `supply`/`withdraw` (the lending side) and `flashLoan` are declared here for completeness of
 *      the port surface. The MVP vault calls neither: it is a borrower, and the loop converges iteratively
 *      (see `BoostedUsdgVault` NatSpec for why a flash-loan one-shot buys nothing at this size).
 */
interface IMorphoBlue {
    /// @notice Supplies `assets` (or `shares`) of loan token to a market
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    /// @notice Withdraws `assets` (or `shares`) of loan token from a market
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    /// @notice Borrows `assets` (or `shares`) of loan token against `onBehalf`'s collateral
    /// @dev Reverts if the resulting position is unhealthy, or if the market lacks free liquidity
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    /// @notice Repays `assets` (or `shares`) of debt
    /// @dev Passing `shares` repays an exact share amount, which is the only way to zero a position without
    ///      leaving rounding dust behind
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// @notice Supplies collateral. Never accrues interest and never checks health (it can only help it).
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;

    /// @notice Withdraws collateral, reverting if it would leave the position unhealthy
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;

    /// @notice Flash loans `assets` of `token` from the singleton's whole balance, free of fee
    function flashLoan(address token, uint256 assets, bytes calldata data) external;

    /// @notice Accrues interest on a market, bringing `lastUpdate` to the current timestamp
    function accrueInterest(MarketParams memory marketParams) external;

    /// @notice Creates a market. Only present so tests and deploy tooling can name the call.
    function createMarket(MarketParams memory marketParams) external;

    /// @notice The market's accounting state
    function market(Id id) external view returns (Market memory);

    /// @notice A user's position in a market
    function position(Id id, address user) external view returns (Position memory);

    /// @notice The market params behind an id (all-zero `loanToken` means the market does not exist)
    function idToMarketParams(Id id) external view returns (MarketParams memory);
}

/**
 * @title IMorphoOracle
 * @notice Morpho Blue's oracle surface: one function, one scale
 * @dev `price()` is quoted so that `collateral * price / 1e36` is the collateral's value in loan-token units.
 *      The 1e36 constant already absorbs the decimal difference between the two tokens, which is why a
 *      6-decimal-over-6-decimal market reads ~1e36 while an 18-decimal-over-6-decimal market reads ~1e24.
 */
interface IMorphoOracle {
    function price() external view returns (uint256);
}

/**
 * @title IMorphoIrm
 * @notice The interest rate model surface used for accrual-aware (view-side) debt reads
 * @dev `borrowRateView` returns the instantaneous borrow rate per second, WAD-scaled. The live Robinhood
 *      Chain deployment uses AdaptiveCurveIRM at `0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1`.
 */
interface IMorphoIrm {
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256);
}

/**
 * @title MarketParamsLib
 * @notice Derives a market's `Id` from its params, matching Blue's own derivation byte for byte
 */
library MarketParamsLib {
    /// @dev MarketParams is five words of memory, laid out contiguously
    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    function id(MarketParams memory marketParams) internal pure returns (Id marketParamsId) {
        assembly ("memory-safe") {
            marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH)
        }
    }
}
