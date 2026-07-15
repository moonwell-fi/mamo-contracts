// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal Compound/Moonwell cToken interface
interface ICToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256);
    /// @notice Last-accrued exchange rate between the cToken and underlying.
    /// @dev    Stored = cheap view (no accrual); Current would re-accrue at call time.
    ///         The underlying per cToken formula is:
    ///           underlying = cTokenBalance * exchangeRateStored / 1e18
    function exchangeRateStored() external view returns (uint256);
}
