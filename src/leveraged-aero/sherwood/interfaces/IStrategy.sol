// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Position} from "./IPriceRouter.sol";

/**
 * @title IStrategy
 * @notice Interface for strategy contracts called by the vault via batch calls.
 *
 *   The vault executes strategy actions as part of its batch:
 *     Execute batch: [token.approve(strategy, amount), strategy.execute()]
 *     Settle batch:  [strategy.settle()]
 *
 *   The strategy pulls tokens from the vault, deploys into DeFi protocols,
 *   and returns tokens on settlement. It holds custody of position tokens
 *   (e.g., mUSDC, LP tokens) during the strategy period.
 *
 *   Lifecycle:
 *     1. Agent deploys strategy (cloned from template) with initial params
 *     2. Agent includes strategy calls in the proposal batch
 *     3. Vault calls execute() — strategy pulls tokens and deploys
 *     4. Proposer can updateParams() to tune slippage/amounts before settlement
 *     5. Vault calls settle() — strategy unwinds and returns tokens
 */
interface IStrategy {
    /// @notice Initialize the strategy (called once, typically after cloning)
    /// @param vault The vault this strategy operates on
    /// @param proposer The agent who created this strategy
    /// @param data ABI-encoded strategy-specific initialization parameters
    function initialize(address vault, address proposer, bytes calldata data) external;

    /// @notice Execute the strategy — pull tokens from vault, deploy into DeFi
    /// @dev Only callable by the vault (via batch call)
    function execute() external;

    /// @notice Settle the strategy — unwind positions, return tokens to vault
    /// @dev Only callable by the vault (via batch call)
    function settle() external;

    /// @notice Update tunable parameters (only proposer, only while executed)
    /// @param data ABI-encoded parameter updates (strategy-specific)
    function updateParams(bytes calldata data) external;

    /// @notice The vault this strategy operates on
    function vault() external view returns (address);

    /// @notice The agent who proposed this strategy
    function proposer() external view returns (address);

    /// @notice Whether the strategy has been executed
    function executed() external view returns (bool);

    /// @notice Human-readable name of the strategy template
    function name() external view returns (string memory);

    /// @notice The strategy's on-venue positions, for vault-side pricing (Lane A).
    /// @dev    Reports WHERE/WHAT the strategy holds (venue + kind + locator) —
    ///         never a self-reported value. The vault prices these via the
    ///         PriceRouter; the strategy is never trusted for value. The default
    ///         (BaseStrategy) returns an empty array (queue-only / Lane B);
    ///         strategies with on-chain-priceable positions override it.
    function positions() external view returns (Position[] memory);

    /// @notice true ⇒ the strategy self-manages fees; the governor skips settle-fee
    ///         distribution for its proposals.
    function selfManagesFees() external view returns (bool);
}
