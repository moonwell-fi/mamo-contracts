// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISyndicateVault
/// @notice The vault surface the vendored `LeveragedAerodromeCLStrategy` calls. Trimmed from the
///         upstream Sherwood interface to exactly the two functions the strategy uses.
/// @dev Implemented in this repo by `src/LeveragedAeroVault.sol`. The name is preserved because the
///      audited strategy imports this path/type verbatim; everything the strategy does NOT call
///      (governor batches, depositor whitelist, agent registry, async queue, ERC-4626 entrypoints)
///      is gone. The strategy also reads the vault as a plain `IERC20` / `IERC4626` / `Ownable`
///      elsewhere — those come from OpenZeppelin, not from here.
interface ISyndicateVault {
    /// @notice Mint `shares` to `to`. Active-strategy-only.
    function strategyMint(address to, uint256 shares) external;

    /// @notice Burn `shares` from the calling strategy's own balance. Active-strategy-only.
    function strategyBurn(uint256 shares) external;
}
