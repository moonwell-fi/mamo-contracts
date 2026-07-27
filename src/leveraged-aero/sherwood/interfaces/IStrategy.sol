// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Position} from "./IPriceRouter.sol";

/**
 * @title IStrategy
 * @notice Interface for strategy contracts driven by the vault.
 *
 *   Lifecycle:
 *     1. The template is cloned (ERC-1167) and `initialize`d with vault + proposer + params
 *     2. The vault calls `execute()` — the strategy deploys the seeded capital into DeFi
 *     3. The proposer may `updateParams()` to tune slippage/amounts while executed
 *     4. The vault calls `settle()` — the strategy unwinds and pushes assets back to the vault
 */
interface IStrategy {
    /// @notice Initialize the strategy (called once, typically after cloning)
    /// @param vault The vault this strategy operates on
    /// @param proposer The agent who created this strategy
    /// @param data ABI-encoded strategy-specific initialization parameters
    function initialize(address vault, address proposer, bytes calldata data) external;

    /// @notice Execute the strategy — deploy seeded capital into DeFi
    /// @dev Only callable by the vault
    function execute() external;

    /// @notice Settle the strategy — unwind positions, return assets to the vault
    /// @dev Only callable by the vault
    function settle() external;

    /// @notice Update tunable parameters (only proposer, only while executed)
    /// @param data ABI-encoded parameter updates (strategy-specific)
    function updateParams(bytes calldata data) external;

    /// @notice The vault this strategy operates on
    function vault() external view returns (address);

    /// @notice The agent who proposed this strategy
    function proposer() external view returns (address);

    /// @notice Human-readable name of the strategy template
    function name() external view returns (string memory);

    /// @notice The strategy's on-venue positions (venue + kind + locator).
    /// @dev    Reports WHERE/WHAT the strategy holds — never a self-reported value. The default
    ///         (BaseStrategy) returns an empty array; strategies with locatable positions override
    ///         it for off-chain consumers.
    function positions() external view returns (Position[] memory);

    /// @notice true ⇒ the strategy crystallises its own management/performance/protocol fees.
    function selfManagesFees() external view returns (bool);
}
