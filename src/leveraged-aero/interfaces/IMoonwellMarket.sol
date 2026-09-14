// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICToken} from "./ICToken.sol";

/// @notice Moonwell (Compound-fork) mToken interface — borrow / repay surface.
/// @dev All functions return a uint256 error code (0 = success), matching the
///      Compound-fork convention. They do NOT revert on protocol-level errors.
interface IMoonwellMarket is ICToken {
    /// @notice Borrows `borrowAmount` of the underlying asset from the market.
    /// @return 0 on success, otherwise a Compound error code.
    function borrow(uint256 borrowAmount) external returns (uint256);

    /// @notice Repays `repayAmount` of the outstanding borrow for the caller.
    /// @dev Pass `type(uint256).max` to repay the entire balance.
    /// @return 0 on success, otherwise a Compound error code.
    function repayBorrow(uint256 repayAmount) external returns (uint256);

    /// @notice Returns the borrow balance for `account` using the stored (non-accruing) index.
    /// @dev STALE BY CONSTRUCTION. `principal × borrowIndex / interestIndex` where `borrowIndex` is the
    ///      market's LAST-ACCRUED index, so interest accrued since the last `accrueInterest()` (by anyone)
    ///      is invisible here. Fine for the `view` paths that structurally cannot accrue (`nav()`,
    ///      `_assertHealthy`, `_readCollateralDebt`) and for the reads that immediately follow a
    ///      borrow/repay in the same tx (those calls accrue+capitalise first, so stored IS current).
    ///      Any path that MEASURES accrued interest must use `borrowBalanceCurrent` instead — see
    ///      `LeveragedAeroValuation._measureLeg`.
    function borrowBalanceStored(address account) external view returns (uint256);

    /// @notice Accrues interest to the current timestamp, then returns `account`'s borrow balance.
    /// @dev NON-VIEW — it advances the market's `borrowIndex`, `totalBorrows` and `totalReserves`. This is
    ///      the ONLY read that sees interest which no borrow/repay/liquidation has yet capitalised.
    ///
    ///      RETURN VALUE IS THE BALANCE, NOT A COMPOUND ERROR CODE — unlike every other function on this
    ///      interface. Moonwell's `MToken.borrowBalanceCurrent` is
    ///      `require(accrueInterest() == NO_ERROR, "accrue interest failed"); return borrowBalanceStored(account);`
    ///      so an accrual failure REVERTS rather than being reported. That is load-bearing and is why this
    ///      is preferred over calling `accrueInterest()` directly: `accrueInterest` returns a MATH_ERROR
    ///      code on its arithmetic-failure branches *without* writing the new index, so a caller that
    ///      ignored the code would silently go on reading the stale index — the exact failure mode this
    ///      function exists to remove. Verified against the deployed Base implementation (`MWethDelegate`
    ///      / `src/MToken.sol`, Moonwell fork of Compound v2).
    ///
    ///      Also `nonReentrant` on Moonwell's side; safe to call sequentially before `repayBorrow` (each
    ///      guard is per-call), and no Moonwell frame is ever open above our call sites.
    function borrowBalanceCurrent(address account) external returns (uint256);

    /// @notice The ERC-20 this market wraps (MErc20). Read once at init to bind a borrow leg to
    ///         its market — a mismatch means the caller wired a market for a different token.
    function underlying() external view returns (address);
}

/// @notice Moonwell/Compound Comptroller — market entry.
/// @dev `enterMarkets` is on the Comptroller, not on individual mTokens.
interface IComptroller {
    /// @notice Adds the caller into each listed mToken market.
    /// @param mTokens Array of mToken addresses to enter.
    /// @return Array of Compound error codes (0 = success per market).
    function enterMarkets(address[] calldata mTokens) external returns (uint256[] memory);

    /// @notice Returns the account's excess collateral or shortfall after the virtual borrow.
    ///         Used by `_assertHealthy` as an authoritative Moonwell liquidation-status check.
    /// @return err       0 on success; non-zero = Compound error code (treat as unhealthy).
    /// @return liquidity Excess USDC collateral above requirements (18dp scaled).
    /// @return shortfall USDC shortfall (18dp scaled); > 0 means the account is liquidatable.
    function getAccountLiquidity(address account)
        external
        view
        returns (uint256 err, uint256 liquidity, uint256 shortfall);

    /// @notice The price oracle `getAccountLiquidity` prices every entered market with.
    function oracle() external view returns (address);
}

/// @notice Moonwell's Comptroller price oracle — on Base a live Chainlink passthrough, NOT a $1 pin for
///         stables.
interface IMoonwellPriceOracle {
    /// @notice Underlying price of `mToken`, scaled `1e(36 − underlyingDecimals)` (USDC, 6dp ⇒ 1e30 at $1).
    function getUnderlyingPrice(address mToken) external view returns (uint256);
}
