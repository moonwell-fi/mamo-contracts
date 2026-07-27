// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Position} from "./interfaces/IPriceRouter.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BaseStrategy
 * @notice Abstract base for the vendored leveraged-Aero strategy: a three-state lifecycle
 *         (Pending → Executed → Settled) driven by the vault, plus a proposer role for tunable
 *         params.
 *
 *   Designed for Clones (ERC-1167) — deploy the template once, clone per position. The
 *   constructor permanently locks `initialize` on the template itself.
 *
 *   The vault owner drives the lifecycle through the vault
 *   (`LeveragedAeroVault.activateStrategy` → `execute()`, `settleStrategy()` → `settle()`); both
 *   are `onlyVault`, a raw `msg.sender == vault` compare. Between them the proposer tunes the
 *   position and the strategy holds custody of every position token; on settlement the realized
 *   asset balance is pushed back to the vault.
 */
abstract contract BaseStrategy is IStrategy {
    using SafeERC20 for IERC20;

    // ── Errors ──
    error AlreadyInitialized();
    error NotProposer();
    error NotVault();
    error NotExecuted();
    error AlreadyExecuted();
    error AlreadySettled();
    error ZeroAddress();

    // ── State ──
    enum State {
        Pending,
        Executed,
        Settled
    }

    address private _vault;
    address private _proposer;
    State internal _state;
    bool private _initialized;

    /**
     * @notice Disables `initialize` on the template itself so an attacker
     *         can't front-run a clone deploy with their own init.
     * @dev Constructors are NOT executed for ERC-1167 minimal proxies, so
     *      `Clones.clone(template)` produces a clone with `_initialized = false`,
     *      keeping atomic `cloneAndInit` flows working. Only the template
     *      contract — deployed via `new` — is permanently locked.
     */
    constructor() {
        _initialized = true;
    }

    modifier onlyProposer() {
        if (msg.sender != _proposer) revert NotProposer();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != _vault) revert NotVault();
        _;
    }

    /// @inheritdoc IStrategy
    function initialize(address vault_, address proposer_, bytes calldata data) external {
        if (_initialized) revert AlreadyInitialized();
        if (vault_ == address(0)) revert ZeroAddress();
        if (proposer_ == address(0)) revert ZeroAddress();
        _initialized = true;
        _vault = vault_;
        _proposer = proposer_;
        _state = State.Pending;

        _initialize(data);
    }

    /// @inheritdoc IStrategy
    function execute() external onlyVault {
        if (_state != State.Pending) revert AlreadyExecuted();
        _state = State.Executed;
        _execute();
    }

    /// @inheritdoc IStrategy
    function settle() external onlyVault {
        if (_state != State.Executed) revert NotExecuted();
        _state = State.Settled;
        _settle();
    }

    /// @inheritdoc IStrategy
    function updateParams(bytes calldata data) external virtual onlyProposer {
        if (_state != State.Executed) revert NotExecuted();
        _updateParams(data);
    }

    /// @inheritdoc IStrategy
    function vault() public view returns (address) {
        return _vault;
    }

    /// @inheritdoc IStrategy
    function proposer() public view returns (address) {
        return _proposer;
    }

    /// @notice Current lifecycle state
    function state() external view returns (State) {
        return _state;
    }

    /// @inheritdoc IStrategy
    /// @dev Default: no locatable positions. Strategies with on-venue positions override this.
    function positions() external view virtual returns (Position[] memory) {
        return new Position[](0);
    }

    /// @inheritdoc IStrategy
    /// @dev Default: fees are not self-managed. Self-fee'd strategies override to `true` and MUST
    ///      then collect the protocol fee themselves (see `LeveragedAerodromeCLStrategy`'s
    ///      `protocolFeeOwed` leg).
    function selfManagesFees() external view virtual returns (bool) {
        return false;
    }

    // ── Internal helpers ──

    /// @notice Push entire balance of a token back to the vault
    function _pushAllToVault(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(_vault, bal);
    }

    // ── Abstract hooks for concrete strategies ──

    /// @notice Strategy-specific initialization (decode params from data)
    function _initialize(bytes calldata data) internal virtual;

    /// @notice Execute the strategy — deploy seeded capital into DeFi
    function _execute() internal virtual;

    /// @notice Settle the strategy — unwind positions, push tokens back to vault
    function _settle() internal virtual;

    /// @notice Update tunable parameters (decode from data)
    function _updateParams(bytes calldata data) internal virtual;
}
