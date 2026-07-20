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
    function borrowBalanceStored(address account) external view returns (uint256);
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
}
